import Foundation
import MLX

/// Text-to-audio generation with Stable Audio 3 Small on MLX.
///
/// Adapted from `StableAudioPipeline` in kellyvv/StableAudio3-IOS (MIT): files are read
/// from a directory instead of the app bundle, the conditioner comes from the DiT file,
/// audio is returned as PCM, and every stage is timed and memory-sampled.
///
/// `staged` residency loads each network only for its stage and frees it afterwards
/// (T5Gemma → DiT → SAME-S), as the upstream MLX runtime's `--free-models` does; peak
/// memory is then the largest single stage. `resident` keeps everything loaded to measure
/// warm generation.
public actor SA3Engine {
    public enum Residency: String, Sendable, Codable {
        case staged
        case resident
    }

    public struct Request: Sendable {
        public var kind: SA3ModelKind
        public var prompt: String
        public var seconds: Float
        public var steps: Int
        public var seed: UInt64

        public init(kind: SA3ModelKind, prompt: String, seconds: Float, steps: Int = 8, seed: UInt64 = 20_261_106) {
            self.kind = kind
            self.prompt = prompt
            self.seconds = seconds
            self.steps = steps
            self.seed = seed
        }
    }

    /// Audio to keep while the rest is generated: continuation (keep the start, generate
    /// the end) or seam repair (keep both ends, regenerate the middle).
    public struct InpaintSource: Sendable {
        /// Stereo PCM at 44.1 kHz; trimmed or zero-padded to the requested length.
        public var channels: [[Float]]
        /// Regions to keep, in seconds; everything else is generated.
        public var keep: [ClosedRange<Double>]

        public init(channels: [[Float]], keep: [ClosedRange<Double>]) {
            self.channels = channels
            self.keep = keep
        }
    }

    public struct Output: Sendable {
        /// Stereo PCM, one array per channel, at `sampleRate`.
        public let channels: [[Float]]
        public let sampleRate: Int
        public let measurement: SA3Measurement
    }

    public enum EngineError: Error, CustomStringConvertible {
        case missingFile(String)
        case cancelled
        case unsupportedDevice

        public var description: String {
            switch self {
            case .unsupportedDevice: "MLX cannot run in the iOS Simulator; use a device"
            case .missingFile(let name): "\(name) is missing"
            case .cancelled: "cancelled"
            }
        }
    }

    public static let sampleRate = 44_100
    static let samplesPerLatent = 4_096
    /// Small DiTs are trained up to 120 s.
    public static let maximumSeconds: Float = 120

    private let directory: SA3ModelDirectory
    public var residency: Residency

    private var tokenizer: SentencePieceBPE?
    private var t5: T5GemmaEncoder?
    private var ditWeights: [SA3ModelKind: [String: MLXArray]] = [:]
    private var decoder: SAMESDecoder?
    private var encoder: SAMESEncoder?

    /// MLX aborts the process (SIGABRT in `metal::Device::Device()`) in the iOS
    /// Simulator, so nothing may touch MLX there. Measured on 2026-11-06 (Xcode 27.1,
    /// iOS 26.5 Simulator).
    /// MLX's own accounting, for diagnostics: active and cached megabytes.
    public static var memoryReport: String {
        guard isSupported else { return "unsupported" }
        return "active \(Memory.activeMemory / 1_000_000) MB, cache \(Memory.cacheMemory / 1_000_000) MB"
    }

    public static var isSupported: Bool {
        #if targetEnvironment(simulator)
        false
        #else
        true
        #endif
    }

    public init(directory: SA3ModelDirectory, residency: Residency = .staged, cacheLimitBytes: Int? = nil) {
        self.directory = directory
        self.residency = residency
        // The app sets MLX's cache limit once (ModelManager); the bench sets its own.
        if Self.isSupported, let cacheLimitBytes { Memory.cacheLimit = cacheLimitBytes }
    }

    public func setResidency(_ residency: Residency) {
        self.residency = residency
        if residency == .staged { unloadAll() }
    }

    /// Frees every network and MLX's buffer cache.
    public func unloadAll() {
        guard Self.isSupported else { return }
        tokenizer = nil
        t5 = nil
        ditWeights.removeAll()
        decoder = nil
        encoder = nil
        Memory.clearCache()
    }

    public var isAnythingLoaded: Bool {
        t5 != nil || decoder != nil || encoder != nil || !ditWeights.isEmpty
    }

    /// Lets the interface take the GPU back: while the reader scrolls, generation waits
    /// between diffusion steps (a step is a fraction of a second), so scrolling stays
    /// smooth and the piece continues where it was.
    public final class GPUYield: @unchecked Sendable {
        private let lock = NSLock()
        private var until = Date.distantPast
        public init() {}
        /// Holds generation for `seconds` from now (extended by each call).
        public func hold(for seconds: TimeInterval) {
            lock.withLock { until = max(until, Date().addingTimeInterval(seconds)) }
        }
        var isHeld: Bool { lock.withLock { Date() < until } }
    }
    public static let yield = GPUYield()

    /// MLX errors raised during the current generation (a GPU fault, work refused in
    /// the background, an allocation failure): checked between steps.
    private var mlxErrors: ErrorBox?

    /// MLX reports errors through a handler whose default ends the process. Here they
    /// become a thrown error, so a failed piece never closes the app.
    public func generate(_ request: Request, inpaint: InpaintSource? = nil,
                         progress: (@Sendable (String) -> Void)? = nil) throws -> Output {
        guard Self.isSupported else { throw EngineError.unsupportedDevice }
        do {
            return try withError { box in
                mlxErrors = box
                defer { mlxErrors = nil }
                return try generateChecked(request, inpaint: inpaint, progress: progress)
            }
        } catch {
            // Arrays from a failed evaluation must not stay in the cache.
            unloadAll()
            throw error
        }
    }

    private func generateChecked(_ request: Request, inpaint: InpaintSource?,
                                 progress: (@Sendable (String) -> Void)?) throws -> Output {
        let seconds = min(max(request.seconds, 0.5), Self.maximumSeconds)
        let sampler = PeakFootprintSampler()
        let baseline = ProcessMemory.footprint()
        Memory.peakMemory = 0
        sampler.start()
        let thermalStart = ThermalStateName.current
        var timings = SA3Timings()
        let started = Date()
        defer { _ = sampler.stop() }

        func timed<T>(_ keyPath: WritableKeyPath<SA3Timings, Double>, _ body: () throws -> T) rethrows -> T {
            let start = Date()
            let value = try body()
            timings[keyPath: keyPath] += Date().timeIntervalSince(start)
            return value
        }

        // 0. Inpainting: encode the audio to keep (FP32) and build the local condition,
        // as Stability's runtime does (`scripts/sa3_mlx.py`): mask 1 = keep, 0 = generate;
        // condition = [mask, latents × mask] → [1, T_lat, 257]; kept latents are pasted
        // back after sampling.
        let latentLength = Self.latentLength(for: seconds)
        var inpaintCondition: (local: MLXArray, latents: MLXArray, mask: MLXArray)?
        if let inpaint {
            progress?("encoding")
            inpaintCondition = try encodeForInpainting(inpaint, latentLength: latentLength, timings: &timings)
            if residency == .staged {
                encoder = nil
                Memory.clearCache()
            }
            try checkCancellation()
        }

        // 1. Text conditioning.
        progress?("text")
        let tokens = try timed(\.tokenizerLoad) { try loadTokenizer() }
        let batch = try tokenize(request.prompt, tokenizer: tokens, maxLength: 256)
        let encoder = try timed(\.t5Load) { try loadT5() }
        let promptEncoding = timed(\.t5Encode) { () -> T5PromptEncoding in
            Stream.withNewDefaultStream(device: .gpu) {
                let embeddings = encoder.encodeTokenIDs(batch.ids, attentionMask: batch.mask)
                eval(embeddings)
                return T5PromptEncoding(embeddings: embeddings, mask: batch.mask, tokenCount: batch.count)
            }
        }
        let conditioner = try timed(\.t5Load) { SA3Conditioning(weights: try load(directory.conditioner(request.kind))) }
        let (crossAttention, globalCondition) = timed(\.t5Encode) { () -> (MLXArray, MLXArray) in
            Stream.withNewDefaultStream(device: .gpu) {
                let conditioned = conditioner.makeConditioning(promptEncoding: promptEncoding, seconds: seconds)
                let cross = conditioned.crossAttention.asType(.float16)
                let global = conditioned.globalCondition.asType(.float16)
                eval(cross, global)
                return (cross, global)
            }
        }
        if residency == .staged {
            t5 = nil
            tokenizer = nil
            Memory.clearCache()
        }
        try checkCancellation()

        // 2. Diffusion.
        progress?("diffusion")
        let weights = try timed(\.ditLoad) { try loadDiTWeights(request.kind) }
        let latents = try Stream.withNewDefaultStream(device: .gpu) { () throws -> MLXArray in
            var dit = DiTSmallMusic(weights: weights, latentLength: latentLength)
            dit.localAddCondition = inpaintCondition?.local
            let samplingStart = Date()
            let result = try sample(dit: dit, latentLength: latentLength, steps: request.steps, seed: request.seed,
                                    crossAttention: crossAttention, globalCondition: globalCondition,
                                    timings: &timings, progress: progress)
            timings.sampling = Date().timeIntervalSince(samplingStart)
            guard let inpaintCondition else { return result }
            let mask = inpaintCondition.mask.asType(result.dtype)
            let pasted = inpaintCondition.latents.asType(result.dtype) * mask + result * (1 - mask)
            eval(pasted)
            try mlxErrors?.check()
            return pasted
        }
        if residency == .staged {
            ditWeights.removeAll()
            Memory.clearCache()
        }
        try checkCancellation()

        // 3. Decoding.
        progress?("decoding")
        let decoder = try timed(\.decoderLoad) { try loadDecoder() }
        let audio = timed(\.decode) { () -> MLXArray in
            Stream.withNewDefaultStream(device: .gpu) {
                let patches = decoder.decodeChunked(latents: latents.asType(.float32))
                let audio = Self.patchedDecode(patches).asType(.float32)
                eval(audio)
                return audio
            }
        }
        // A failed decode must not be read back.
        try mlxErrors?.check()
        let requestedSamples = Int((seconds * Float(Self.sampleRate)).rounded())
        let trimmed = audio[0, 0..., 0 ..< min(requestedSamples, audio.dim(2))]
        let left = trimmed[0].asArray(Float.self)
        let right = trimmed[1].asArray(Float.self)
        if residency == .staged {
            timed(\.unload) {
                self.decoder = nil
                Memory.clearCache()
            }
        }
        timings.total = Date().timeIntervalSince(started)
        let peak = sampler.stop()
        progress?("done")

        let measurement = SA3Measurement(
            model: request.kind.rawValue,
            prompt: request.prompt,
            seconds: Double(seconds),
            steps: request.steps,
            seed: request.seed,
            residency: residency.rawValue,
            timings: timings,
            peakFootprintBytes: peak,
            baselineFootprintBytes: baseline,
            endFootprintBytes: ProcessMemory.footprint(),
            mlxPeakBytes: Int64(Memory.peakMemory),
            thermalStart: thermalStart,
            thermalEnd: ThermalStateName.current
        )
        return Output(channels: [left, right], sampleRate: Self.sampleRate, measurement: measurement)
    }

    // MARK: - Sampling (pingpong, rf_denoiser distilled for 8 steps)

    private func sample(
        dit: DiTSmallMusic, latentLength: Int, steps: Int, seed: UInt64,
        crossAttention: MLXArray, globalCondition: MLXArray,
        timings: inout SA3Timings, progress: (@Sendable (String) -> Void)?
    ) throws -> MLXArray {
        let schedule = Self.buildSchedule(steps: steps)
        // Same keys as Stability's MLX runtime (sa3_mlx.py): the initial noise uses
        // `seed`, the per-step noise of the pingpong sampler `seed + 1`.
        var x = MLXRandom.normal([1, 256, latentLength], dtype: .float16, key: MLXRandom.key(seed))
        var key = MLXRandom.key(seed &+ 1)
        eval(x)
        for index in 0 ..< steps {
            try checkCancellation()
            let stepStart = Date()
            progress?("step \(index + 1)/\(steps)")
            let current = schedule[index]
            let next = schedule[index + 1]
            let t = MLXArray([current], [1]).asType(.float16)
            let velocity = dit(x, timestep: t, crossAttention: crossAttention, globalCondition: globalCondition)
            let denoised = x - MLXArray(current, dtype: x.dtype) * velocity
            if index < steps - 1 && next > 0 {
                let split = MLXRandom.split(key: key)
                key = split.0
                let noise = MLXRandom.normal(x.shape, dtype: x.dtype, key: split.1)
                x = (1.0 - next) * denoised + next * noise
            } else {
                x = denoised
            }
            eval(x)
            timings.steps.append(Date().timeIntervalSince(stepStart))
        }
        return x
    }

    private func checkCancellation() throws {
        try mlxErrors?.check()
        // Give way to the interface, at most a few seconds per step.
        var waited = 0
        while Self.yield.isHeld, waited < 60, !Task.isCancelled {
            Thread.sleep(forTimeInterval: 0.05)
            waited += 1
        }
        if Task.isCancelled { throw EngineError.cancelled }
    }

    // MARK: - Loading

    private func loadTokenizer() throws -> SentencePieceBPE {
        if let tokenizer { return tokenizer }
        guard FileManager.default.fileExists(atPath: directory.tokenizer.path) else {
            throw EngineError.missingFile("tokenizer.model")
        }
        let loaded = try SentencePieceBPE(modelURL: directory.tokenizer)
        tokenizer = loaded
        return loaded
    }

    private func loadT5() throws -> T5GemmaEncoder {
        if let t5 { return t5 }
        let weights = try load(directory.t5)
        let encoder = try T5GemmaEncoder(weights: weights)
        t5 = encoder
        return encoder
    }

    private func loadDiTWeights(_ kind: SA3ModelKind) throws -> [String: MLXArray] {
        if let weights = ditWeights[kind] { return weights }
        if residency == .staged { ditWeights.removeAll() }
        let weights = try load(directory.dit(kind))
        ditWeights[kind] = weights
        return weights
    }

    /// Encodes the audio to keep and builds the inpainting condition. A separate scope so
    /// that nothing from the encoder outlives this stage.
    private func encodeForInpainting(_ inpaint: InpaintSource, latentLength: Int, timings: inout SA3Timings)
        throws -> (local: MLXArray, latents: MLXArray, mask: MLXArray) {
        let loadStart = Date()
        let encoder = try loadEncoder()
        timings.encoderLoad += Date().timeIntervalSince(loadStart)
        let encodeStart = Date()
        defer { timings.encode += Date().timeIntervalSince(encodeStart) }
        return Stream.withNewDefaultStream(device: .gpu) {
            // The encoder attends within chunks of ~2 latents, and generated regions are
            // masked to zero, so only the kept audio is encoded (each kept range on its
            // own, padded to the encoder's grid with a 2-latent margin). Encoding the whole
            // zero-padded clip, as the reference does, costs more time and memory for the
            // same kept latents.
            var mask = [Float](repeating: 0, count: latentLength)
            var latents = MLXArray.zeros([1, SAMESEncoder.latentDimension, latentLength], dtype: .float32)
            for range in inpaint.keep {
                let start = max(0, Int((range.lowerBound * Double(Self.sampleRate) / Double(Self.samplesPerLatent)).rounded()))
                let end = min(latentLength, Int((range.upperBound * Double(Self.sampleRate) / Double(Self.samplesPerLatent)).rounded()))
                guard start < end else { continue }
                for index in start ..< end { mask[index] = 1 }
                let margin = 2
                let windowStart = max(0, start - margin)
                var windowEnd = min(latentLength, end + margin)
                if (windowEnd - windowStart) % 2 != 0 { windowEnd = min(latentLength, windowEnd + 1) }
                if (windowEnd - windowStart) % 2 != 0 { windowEnd -= 1 }
                let count = windowEnd - windowStart
                let samples = count * Self.samplesPerLatent
                let audio = MLXArray(Self.fit(inpaint.channels, from: windowStart * Self.samplesPerLatent, samples: samples), [1, 2, samples])
                let encoded = encoder(SAMESEncoder.patchAudio(audio))[0..., 0..., 0 ..< count]
                let offset = start - windowStart
                var piece = encoded[0..., 0..., offset ..< min(offset + end - start, encoded.dim(2))]
                // At the edge of the audio the encoder can return a frame less than asked:
                // that frame is generated instead of kept (it broke the concatenation).
                let got = piece.dim(2)
                if got < end - start {
                    piece = concatenated([piece, MLXArray.zeros([1, piece.dim(1), end - start - got], dtype: piece.dtype)],
                                         axis: 2)
                    for index in (start + got) ..< end { mask[index] = 0 }
                }
                latents = concatenated([latents[0..., 0..., 0 ..< start], piece, latents[0..., 0..., end...]], axis: 2)
                eval(latents)
            }
            let maskArray = MLXArray(mask, [1, 1, latentLength])
            let local = concatenated([maskArray, latents * maskArray], axis: 1).transposed(0, 2, 1).asType(.float16)
            let kept = latents.asType(.float16)
            eval(local, kept, maskArray)
            return (local, kept, maskArray)
        }
    }

    private func loadEncoder() throws -> SAMESEncoder {
        if let encoder { return encoder }
        let loaded = SAMESEncoder(weights: try load(directory.encoder))
        encoder = loaded
        return loaded
    }

    /// `samples` frames from `from` of a stereo clip as `[2, samples]` row-major,
    /// zero-padded past its end. A mono clip is duplicated.
    static func fit(_ channels: [[Float]], from: Int = 0, samples: Int) -> [Float] {
        var out = [Float](repeating: 0, count: 2 * samples)
        for c in 0 ..< 2 {
            let source = channels.indices.contains(c) ? channels[c] : (channels.first ?? [])
            let count = max(0, min(samples, source.count - from))
            for i in 0 ..< count { out[c * samples + i] = source[from + i] }
        }
        return out
    }

    private func loadDecoder() throws -> SAMESDecoder {
        if let decoder { return decoder }
        let loaded = SAMESDecoder(weights: try load(directory.decoder))
        decoder = loaded
        return loaded
    }

    private func load(_ url: URL) throws -> [String: MLXArray] {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw EngineError.missingFile(url.lastPathComponent)
        }
        let arrays = try loadArrays(url: url, stream: .cpu)
        eval(Array(arrays.values))
        return arrays
    }

    private func tokenize(_ prompt: String, tokenizer: SentencePieceBPE, maxLength: Int) throws -> (ids: MLXArray, mask: MLXArray, count: Int) {
        let clipped = Array(tokenizer.encode(prompt).prefix(maxLength)).map(Int32.init)
        let tokens = clipped.isEmpty ? [Int32(1)] : clipped
        var ids = Array(repeating: Int32(0), count: maxLength)
        var mask = Array(repeating: Int32(0), count: maxLength)
        for index in tokens.indices {
            ids[index] = tokens[index]
            mask[index] = 1
        }
        return (MLXArray(ids, [1, maxLength]), MLXArray(mask, [1, maxLength]), tokens.count)
    }

    /// Token count of a prompt, to keep prompts short.
    public func tokenCount(_ prompt: String) throws -> Int {
        try loadTokenizer().encode(prompt).count
    }

    // MARK: - Helpers

    static func latentLength(for seconds: Float) -> Int {
        var length = max(1, Int(ceil(seconds * Float(sampleRate) / Float(samplesPerLatent))))
        if length % 2 != 0 { length += 1 }
        return length
    }

    static func buildSchedule(steps: Int) -> [Float] {
        (0 ... steps).map { index in
            if index == 0 { return 1 }
            if index == steps { return 0 }
            let t = 1.0 - Float(index) / Float(steps)
            let logSNR: Float = 2.0 - t * (2.0 - -6.2)
            return 1.0 / (1.0 + exp(logSNR))
        }
    }

    static func patchedDecode(_ patches: MLXArray) -> MLXArray {
        let batch = patches.dim(0)
        let length = patches.dim(2)
        var x = patches.reshaped(batch, 2, 256, length)
        x = x.transposed(0, 1, 3, 2)
        return x.reshaped(batch, 2, length * 256)
    }
}

func linear(_ x: MLXArray, weight: MLXArray, bias: MLXArray? = nil) -> MLXArray {
    var y = matmul(x, weight.T)
    if let bias { y = y + bias }
    return y
}

func silu(_ x: MLXArray) -> MLXArray {
    x * sigmoid(x)
}
