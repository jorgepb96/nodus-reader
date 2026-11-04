import CoreML
import Foundation

/// Result of one talker pass.
struct GenResult {
    var codes: [Int64]          // frames x 16, frame-major
    var frames: Int
    var stop: QwenStopReason
    var promptLen: Int
    var prefillWall: Double
    var loopWall: Double
    /// Prompt rows whose KV came from the voice's cached prefix instead of a prefill.
    var prefixRowsReused: Int = 0
    /// Prediction wall times within the loop (prefill is reported separately).
    var talkerWall: Double = 0
    var codePredictorWall: Double = 0
}

/// Talker + code predictor on the Neural Engine, a Swift port of tools/qcoreml.py.
///
/// * talker{0..<n}.mlmodelc: `layers / n` layers each (2 x 14 for 0.6B, 4 x 7 for 1.7B; the host config says
///   which), multifunction ("decode" T=1 / "prefill" T=64) sharing one MLState per chunk (k/v buffers
///   (8, LMAX, 128) fp16). A row is written by a one-hot blend
///   (`keep`, `place` inputs) because the ANE has no scatter and slice_update on a state ignores a
///   dynamic begin. Each chunk hands its residual to the next as (x_out, lo_out): a compensated fp16
///   stream (TwoSum), which keeps the g0 logits within ~0.3% of the fp32 reference.
/// * cp_ane.mlmodelc: one call per frame, 15 greedy sub-codes unrolled (argmax on the ANE). Its `hidden` and `e0`
///   inputs are 1024 wide; a 1.7B talker (2048) goes through the host's small_to_mtp_projection first.
/// Host side per frame (fp32): next talker input = codec[g0] + sum cp[k][code] + tts_pad, the RoPE
/// row and the mask/one-hot rows. CPU cost is ~1 ms per 80 ms frame on the Mac.
#if arch(arm64)
@available(iOS 18.0, macOS 15.0, *)
final class ANETalkerEngine {
    static let LMAX = 1024, P = 64, HD = 128
    /// Talker width, chunks and layers per chunk (from the host config).
    private let H: Int, chunks: Int, layersPerChunk: Int
    private let dec: [MLModel], pre: [MLModel], cp: MLModel
    private let host: HostTables
    private let ttsPad: [Float]
    private let experimentalNoise: MLMultiArray?
    private var states: [MLState]
    // persistent decode inputs (mutated in place each step)
    private let x, cosA, sinA, mask, place, keep, e0, cpHiddenIn: MLMultiArray
    // prefill inputs
    private let px, pcos, psin, pmask, pplace, pkeep: MLMultiArray
    private var logits = [Float](repeating: 0, count: 3072)
    /// Teacher forcing for parity tests: frames x 16 codes to feed instead of the engine's own (no EOS
    /// stop); the engine's own picks (sampler g0, code-predictor sub-codes) land in `forcedPicks`.
    /// Free-running sampling diverges after the first fp16 near-tie flip, so per-frame agreement is
    /// only meaningful when both sides see the same history.
    var forced: [[Int]]? = nil
    private(set) var forcedPicks: [[Int]] = []
    /// Restore / fill the voice's KV prefix (see `KVPrefix`). Off = every line prefills from row 0.
    var usePrefixCache = true
    /// Also stop when the raw (unsampled) argmax is EOS, not only when EOS is drawn.
    var eosOnArgmax = true

    init(coreMLDirectory dir: URL, host: HostTables, experimentalCodePredictor: URL? = nil) throws {
        self.host = host
        H = host.hidden; chunks = host.cfg.talkerChunks; layersPerChunk = host.cfg.layers / host.cfg.talkerChunks
        func load(_ name: String, _ fn: String?) throws -> MLModel {
            let c = MLModelConfiguration()
            c.computeUnits = .cpuAndNeuralEngine
            if let fn { c.functionName = fn }
            return try MLModel(contentsOf: dir.appendingPathComponent(name + ".mlmodelc"), configuration: c)
        }
        let n = host.cfg.talkerChunks
        dec = try (0..<n).map { try load("talker\($0)", "decode") }
        pre = try (0..<n).map { try load("talker\($0)", "prefill") }
        if let experimentalCodePredictor {
            guard H == 1024, host.cfg.cpHidden == 1024 else {
                throw QwenANEError.invalid("the experimental INT8 predictor only supports 0.6B")
            }
            let configuration = MLModelConfiguration()
            configuration.computeUnits = .cpuAndNeuralEngine
            cp = try MLModel(contentsOf: experimentalCodePredictor, configuration: configuration)
            if cp.modelDescription.inputDescriptionsByName["hidden"]?.multiArrayConstraint?.shape.map(\.intValue) == [1, 1024],
               cp.modelDescription.inputDescriptionsByName["e0"]?.multiArrayConstraint?.shape.map(\.intValue) == [1, 1024],
               cp.modelDescription.outputDescriptionsByName["codes"]?.multiArrayConstraint?.shape.map(\.intValue) == [15] {
                // A graph-preserving INT8 rewrite of our pinned predictor.
                experimentalNoise = nil
            } else {
                let expected = ["hidden_states": [1, 1024, 1, 1], "code_embeds": [1, 1024, 1, 1], "noise": [15, 2048]]
                for (name, shape) in expected {
                    guard let constraint = cp.modelDescription.inputDescriptionsByName[name]?.multiArrayConstraint,
                          constraint.dataType == .float16, constraint.shape.map(\.intValue) == shape else {
                        throw QwenANEError.invalid("unexpected experimental predictor input: \(name)")
                    }
                }
                guard cp.modelDescription.outputDescriptionsByName["codes"]?.multiArrayConstraint?.shape.map(\.intValue) == [1, 15] else {
                    throw QwenANEError.invalid("unexpected experimental predictor codes")
                }
                let noise = try MLMultiArray(shape: [15, 2048], dataType: .float16)
                // This export adds Gumbel noise to temperature-scaled top-k logits.
                // Zero noise keeps greedy sub-codes, matching the shipped runtime's
                // sampling policy rather than silently changing it for a speed test.
                memset(noise.dataPointer, 0, noise.count * 2)
                experimentalNoise = noise
            }
        } else {
            cp = try load("cp_ane", nil)
            experimentalNoise = nil
        }
        ttsPad = host.textProj([host.cfg.ttsPad])
        states = dec.map { $0.makeState() }
        func f16(_ shape: [Int]) throws -> MLMultiArray {
            let a = try MLMultiArray(shape: shape.map { NSNumber(value: $0) }, dataType: .float16)
            memset(a.dataPointer, 0, shape.reduce(1, *) * 2)
            return a
        }
        let H = host.hidden, L = Self.LMAX, P = Self.P, HD = Self.HD
        let CH = host.cfg.cpHidden
        x = try f16([1, H]); cosA = try f16([1, HD]); sinA = try f16([1, HD]); mask = try f16([1, L])
        place = try f16([L, 1]); keep = try f16([L, 1]); e0 = try f16([1, CH]); cpHiddenIn = try f16([1, CH])
        px = try f16([P, H]); pcos = try f16([P, HD]); psin = try f16([P, HD]); pmask = try f16([P, L])
        pplace = try f16([L, P]); pkeep = try f16([L, 1])
        // zero the KV states once (masked rows are multiplied by 0; they must not hold NaN bit patterns)
        for (c, s) in states.enumerated() { Self.zero(s, layers: (layersPerChunk * c)..<(layersPerChunk * c + layersPerChunk)) }
    }

    private static func zero(_ s: MLState, layers: Range<Int>) {
        for i in layers {
            for kv in ["k", "v"] {
                let name = "\(kv)\(i)"
                s.withMultiArray(for: name) { a in memset(a.dataPointer, 0, a.count * 2) }
            }
        }
    }

    @inline(__always) private static func p16(_ a: MLMultiArray) -> UnsafeMutablePointer<Float16> {
        a.dataPointer.assumingMemoryBound(to: Float16.self)
    }

    private static func rope(_ pos: Int, _ c: UnsafeMutablePointer<Float16>, _ s: UnsafeMutablePointer<Float16>) {
        for i in 0..<(HD / 2) {
            let inv = 1.0 / pow(1e6, Double(2 * i) / Double(HD))
            let a = Double(pos) * inv
            let cv = Float16(cos(a)), sv = Float16(sin(a))          // one rounding, like numpy float64 -> float16
            c[i] = cv; c[i + HD / 2] = cv; s[i] = sv; s[i + HD / 2] = sv
        }
    }

    /// Runs every chunk on the inputs already placed in `inputs` (each later chunk also gets the x_out/lo_out of the one before).
    private func runChunks(_ models: [MLModel], _ inputs: [String: MLMultiArray]) throws -> MLFeatureProvider {
        var feed = inputs.mapValues { MLFeatureValue(multiArray: $0) }
        var out: MLFeatureProvider! = nil
        for (c, m) in models.enumerated() {
            out = try m.prediction(from: try MLDictionaryFeatureProvider(dictionary: feed), using: states[c])
            if let xo = out.featureValue(for: "x_out")?.multiArrayValue, let lo = out.featureValue(for: "lo_out")?.multiArrayValue {
                feed["x"] = MLFeatureValue(multiArray: xo); feed["lo"] = MLFeatureValue(multiArray: lo)
            }
        }
        return out
    }

    /// Whole prefill chunks that lie inside the prompt's voice-only prefix (the rows cannot be reused at a
    /// finer grain: the chunk grid is what keeps a restored prefix bit-identical to a fresh prefill).
    static func cacheableRows(_ p: Prompt) -> Int { min(p.prefixRows, p.T - 1) / P * P }

    /// Prefills rows 0..<T-1. With a usable cached prefix (`kv`) the first `kv.rows` rows are restored
    /// instead of computed; returns how many rows that was, and, when `p.voice` has none yet, a fresh
    /// snapshot of them for the caller to keep once the line proves finite.
    private func prefill(_ p: Prompt) throws -> (reused: Int, fresh: KVPrefix?) {
        let H = self.H, L = Self.LMAX, P = Self.P, HD = Self.HD
        let n = p.T - 1                                   // the last row goes through decode
        let aligned = usePrefixCache && p.voice != nil ? Self.cacheableRows(p) : 0
        var s = 0
        var reused = 0
        if aligned > 0, let hit = p.voice?.kv, hit.rows == aligned, hit.matches(p.embeds), restoreKV(hit) {
            s = aligned; reused = aligned
        }
        while s < n {
            let rows = min(P, n - s)
            let xp = Self.p16(px), mp = Self.p16(pmask), pl = Self.p16(pplace), kp = Self.p16(pkeep)
            memset(px.dataPointer, 0, P * H * 2); memset(pplace.dataPointer, 0, L * P * 2)
            for i in 0..<(L) { kp[i] = 1 }
            p.embeds.withUnsafeBufferPointer { e in
                for i in 0..<(rows * H) { xp[i] = Float16(e[s * H + i]) }
            }
            for t in 0..<P {
                let pos = s + t
                Self.rope(pos, Self.p16(pcos) + t * HD, Self.p16(psin) + t * HD)
                for j in 0..<L { mp[t * L + j] = j <= pos ? 0 : -10000 }
                if pos < L { pl[pos * P + t] = 1; kp[pos] = 0 }
            }
            _ = try runChunks(pre, ["x": px, "cos": pcos, "sin": psin, "mask": pmask, "place": pplace, "keep": pkeep])
            s += P
        }
        var fresh: KVPrefix? = nil
        if aligned > 0, reused == 0 {
            // Rows < aligned are never rewritten by later chunks (their one-hot `place` is 0 there), so the
            // state still holds exactly what the first chunks produced.
            fresh = snapshotKV(rows: aligned, embeds: Array(p.embeds[0..<(aligned * H)]))
        }
        return (reused, fresh)
    }

    // MARK: KV prefix snapshots (MLState read/write)

    private func stateNames() -> [(chunk: Int, name: String)] {
        let per = layersPerChunk
        return (0..<(per * chunks)).flatMap { i in ["k", "v"].map { (chunk: i / per, name: "\($0)\(i)") } }
    }

    /// Copies rows 0..<rows of every k/v state buffer into compact blocks; nil when a buffer's layout is not the
    /// expected fp16 (heads, slots, head dim) with a contiguous head dimension (the cache is then simply off).
    private func snapshotKV(rows: Int, embeds: [Float]) -> KVPrefix? {
        var blocks: [Data] = []
        for (c, name) in stateNames() {
            let block: Data? = states[c].withMultiArray(for: name) { a in
                let nd = a.shape.count
                guard nd >= 3, a.dataType == .float16 else { return nil }
                let heads = a.shape[nd - 3].intValue, slots = a.shape[nd - 2].intValue, hd = a.shape[nd - 1].intValue
                let sh = a.strides[nd - 3].intValue, sr = a.strides[nd - 2].intValue
                guard a.strides[nd - 1].intValue == 1, a.count == heads * slots * hd, rows <= slots else { return nil }
                var d = Data(count: heads * rows * hd * 2)
                d.withUnsafeMutableBytes { dst in
                    let out = dst.bindMemory(to: Float16.self).baseAddress!, src = Self.p16(a)
                    for h in 0..<heads { for r in 0..<rows { memcpy(out + (h * rows + r) * hd, src + h * sh + r * sr, hd * 2) } }
                }
                return d
            }
            guard let block else { return nil }
            blocks.append(block)
        }
        return KVPrefix(rows: rows, embeds: embeds, buffers: blocks)
    }

    /// Writes a snapshot back into rows 0..<rows of the state buffers. False (and nothing trusted) on a layout surprise.
    private func restoreKV(_ kv: KVPrefix) -> Bool {
        let names = stateNames()
        guard kv.buffers.count == names.count else { return false }
        for (i, (c, name)) in names.enumerated() {
            let ok: Bool = states[c].withMultiArray(for: name) { a in
                let nd = a.shape.count
                guard nd >= 3, a.dataType == .float16 else { return false }
                let heads = a.shape[nd - 3].intValue, slots = a.shape[nd - 2].intValue, hd = a.shape[nd - 1].intValue
                let sh = a.strides[nd - 3].intValue, sr = a.strides[nd - 2].intValue
                guard a.strides[nd - 1].intValue == 1, a.count == heads * slots * hd, kv.rows <= slots,
                      kv.buffers[i].count == heads * kv.rows * hd * 2 else { return false }
                kv.buffers[i].withUnsafeBytes { src in
                    let inp = src.bindMemory(to: Float16.self).baseAddress!, dst = Self.p16(a)
                    for h in 0..<heads { for r in 0..<kv.rows { memcpy(dst + h * sh + r * sr, inp + (h * kv.rows + r) * hd, hd * 2) } }
                }
                return true
            }
            if !ok { return false }
        }
        return true
    }

    /// One decode step of the row in `x` at position `pos`; fills `logits`, returns the hidden array.
    private func step(_ pos: Int, _ prevPos: Int?) throws -> MLMultiArray {
        let mp = Self.p16(mask), pl = Self.p16(place), kp = Self.p16(keep)
        if let q = prevPos { pl[q] = 0; kp[q] = 1 }
        mp[pos] = 0; pl[pos] = 1; kp[pos] = 0
        Self.rope(pos, Self.p16(cosA), Self.p16(sinA))
        let o = try runChunks(dec, ["x": x, "cos": cosA, "sin": sinA, "mask": mask, "place": place, "keep": keep])
        guard let lg = o.featureValue(for: "logits")?.multiArrayValue, let hid = o.featureValue(for: "hidden")?.multiArrayValue
        else { throw QwenANEError.invalid("talker outputs missing") }
        Self.read(lg, into: &logits)
        return hid
    }

    /// fp16 (or fp32) output array -> Float buffer
    private static func read(_ a: MLMultiArray, into out: inout [Float]) {
        let n = min(out.count, a.count)
        if a.dataType == .float16 {
            let p = p16(a); for i in 0..<n { out[i] = Float(p[i]) }
        } else {
            let p = a.dataPointer.assumingMemoryBound(to: Float.self); for i in 0..<n { out[i] = p[i] }
        }
    }

    private func setX(_ v: [Float]) {
        let xp = Self.p16(x)
        for i in 0..<H { xp[i] = Float16(v[i]) }
    }

    private func predictCodes(hidden: MLMultiArray) throws -> MLFeatureProvider {
        guard let noise = experimentalNoise else {
            return try cp.prediction(from: try MLDictionaryFeatureProvider(dictionary: [
                "hidden": MLFeatureValue(multiArray: hidden), "e0": MLFeatureValue(multiArray: e0)]))
        }
        func view(_ array: MLMultiArray) throws -> MLMultiArray {
            guard array.count == 1024, array.dataType == .float16,
                  array.strides.last?.intValue == 1 else {
                throw QwenANEError.invalid("experimental predictor needs contiguous FP16 input")
            }
            return try MLMultiArray(dataPointer: array.dataPointer, shape: [1, 1024, 1, 1], dataType: .float16,
                                    strides: [1024, 1, 1, 1], deallocator: nil)
        }
        // The backing arrays live through the synchronous prediction.
        return try withExtendedLifetime(hidden) {
            try cp.prediction(from: try MLDictionaryFeatureProvider(dictionary: [
                "hidden_states": MLFeatureValue(multiArray: view(hidden)),
                "code_embeds": MLFeatureValue(multiArray: view(e0)), "noise": MLFeatureValue(multiArray: noise)]))
        }
    }

    /// True when every value is a finite number (no NaN / Inf).
    static func allFinite(_ v: [Float]) -> Bool {
        for x in v where !x.isFinite { return false }
        return true
    }

    /// Zeroes every chunk's KV states. A NaN/Inf written into a cache row would survive into every
    /// later line (masked rows are multiplied by 0, and 0 * NaN is NaN), so a bad line resets them.
    func resetStates() {
        for (c, s) in states.enumerated() { Self.zero(s, layers: (layersPerChunk * c)..<(layersPerChunk * c + layersPerChunk)) }
    }

    /// Test seam: poison the talker logits with NaN right after the step that follows this frame index.
    var injectNaNLogitsAtFrame: Int? = nil
    /// Test seam: poison the code predictor's sub-codes with NaN at this frame index.
    var injectNaNSubCodesAtFrame: Int? = nil

    /// Frames the KV window leaves after `promptRows` prompt rows.
    static func windowFrames(promptRows T: Int) -> Int { max(0, LMAX - T) }

    /// Generates frames until EOS, the cap, or `cancelled()`; `onFrame` gets each frame's 16 codes as they exist.
    /// A non-finite talker or code-predictor output zeroes the KV states and throws `QwenANEError.nonFinite`;
    /// any thrown error leaves the engine ready for the next line.
    func generate(prompt: Prompt, sampler: inout Sampler, eos: Int, maxNew: Int?,
                  cancelled: () -> Bool, onFrame: (Int, ArraySlice<Int64>) throws -> Void) throws -> GenResult {
        do {
            return try generateUnguarded(prompt: prompt, sampler: &sampler, eos: eos, maxNew: maxNew,
                                         cancelled: cancelled, onFrame: onFrame)
        } catch {
            resetStates()
            throw error
        }
    }

    private func generateUnguarded(prompt: Prompt, sampler: inout Sampler, eos: Int, maxNew: Int?,
                  cancelled: () -> Bool, onFrame: (Int, ArraySlice<Int64>) throws -> Void) throws -> GenResult {
        let H = self.H, L = Self.LMAX
        let T = prompt.T
        guard T < L - 8 else { throw QwenANEError.invalid("prompt \(T) rows exceeds the ANE talker's \(L) KV slots") }
        let requested = maxNew ?? effectiveMaxTokens(prompt.nTextTokens)
        let window = Self.windowFrames(promptRows: T)
        let cap = min(requested, window)
        let t0 = ProcessInfo.processInfo.systemUptime
        let (reused, freshPrefix) = try prefill(prompt)
        // decode mask: rows 0..T-2 visible, the rest hidden until written
        let mp = Self.p16(mask), pl = Self.p16(place), kp = Self.p16(keep)
        for j in 0..<L { mp[j] = j < T - 1 ? 0 : -10000; pl[j] = 0; kp[j] = 1 }
        setX(Array(prompt.embeds[((T - 1) * H)..<(T * H)]))
        var hidden = try step(T - 1, nil)
        let prefillWall = (ProcessInfo.processInfo.systemUptime - t0)
        guard Self.allFinite(logits) else { throw QwenANEError.nonFinite("talker logits after prefill") }
        if let freshPrefix { prompt.voice?.kv = freshPrefix }      // only a prefix that produced finite logits is kept

        var pos = T
        var codes: [Int64] = []; codes.reserveCapacity(cap * 16)
        var hist: [Int] = []
        var stop = QwenStopReason.maxTokens
        var frames = 0
        var e = [Float](repeating: 0, count: H)
        let t1 = ProcessInfo.processInfo.systemUptime
        var talkerWall = 0.0, codePredictorWall = 0.0
        forcedPicks = []
        let capF = forced.map { min(cap, $0.count) } ?? cap
        for f in 0..<capF {
            // one autoreleasepool per frame: Core ML outputs and feature providers are autoreleased
            let done: Bool = try autoreleasepool {
                if cancelled() { stop = .cancelled; return true }
                var g0 = logits.withUnsafeBufferPointer { sampler.sample($0.baseAddress!, history: hist) }
                let ownG0 = g0
                if let fc = forced { g0 = fc[f][0] }
                var am = 0; var av = logits[0]
                for i in 1..<3072 where logits[i] > av { av = logits[i]; am = i }   // raw argmax (eosGreedyStop)
                if forced == nil && (g0 == eos || (eosOnArgmax && am == eos)) { stop = .eos; return true }
                guard g0 >= 0, g0 < QwenVoiceFiles.codebookSize else { throw QwenANEError.nonFinite("first-codebook code \(g0) outside the vocoder's range") }
                // code predictor: hidden + codec[g0] -> 15 sub-codes
                let ep = Self.p16(e0), cr = host.codecRow(g0)
                let cpHidden: MLMultiArray
                if host.projectsForCodePredictor {
                    // 1.7B: small_to_mtp_projection (2048 -> 1024) of the talker's hidden state and of codec[g0], in fp32
                    var hv = [Float](repeating: 0, count: H)
                    Self.read(hidden, into: &hv)
                    let hp = host.cpInput(hv), er = host.cpInput(cr)
                    let hq = Self.p16(cpHiddenIn)
                    for i in 0..<hp.count { hq[i] = Float16(hp[i]); ep[i] = Float16(er[i]) }
                    cpHidden = cpHiddenIn
                } else {
                    for i in 0..<H { ep[i] = Float16(cr[i]) }
                    cpHidden = hidden
                }
                let cpStarted = ProcessInfo.processInfo.systemUptime
                let co = try predictCodes(hidden: cpHidden)
                codePredictorWall += ProcessInfo.processInfo.systemUptime - cpStarted
                guard let ca = co.featureValue(for: "codes")?.multiArrayValue else { throw QwenANEError.invalid("cp codes missing") }
                var cf = [Float](repeating: 0, count: 15)
                Self.read(ca, into: &cf)
                if injectNaNSubCodesAtFrame == f { cf[3] = .nan }
                guard Self.allFinite(cf) else { throw QwenANEError.nonFinite("code predictor output at frame \(f)") }
                var subs = (0..<15).map { Int(min(Float(QwenVoiceFiles.codebookSize - 1), max(0, cf[$0])).rounded()) }
                if let fc = forced { forcedPicks.append([ownG0] + subs); subs = Array(fc[f][1...]) }
                guard subs.allSatisfy({ $0 >= 0 && $0 < QwenVoiceFiles.codebookSize }) else { throw QwenANEError.nonFinite("sub-code outside the vocoder's range") }
                // next talker input (fp32 sum, one fp16 rounding)
                // same fp32 summation order as qonnx.Host.code_sum(g0, subs) + tts_pad
                for i in 0..<H { e[i] = cr[i] }
                for k in 0..<15 { let r = host.cpRow(k, subs[k]); for i in 0..<H { e[i] += r[i] } }
                for i in 0..<H { e[i] += ttsPad[i] }
                setX(e)
                let talkerStarted = ProcessInfo.processInfo.systemUptime
                hidden = try step(pos, pos - 1)
                talkerWall += ProcessInfo.processInfo.systemUptime - talkerStarted
                if injectNaNLogitsAtFrame == f { logits[5] = .nan }
                guard Self.allFinite(logits) else { throw QwenANEError.nonFinite("talker logits at frame \(f)") }
                codes.append(Int64(g0)); for k in 0..<15 { codes.append(Int64(subs[k])) }
                hist.append(g0)
                pos += 1; frames += 1
                try onFrame(frames, codes[(codes.count - 16)...])
                return false
            }
            if done { break }
        }
        if stop == .maxTokens && forced == nil && cap < requested { stop = .contextFull }   // the KV window, not the token cap, ended it
        return GenResult(codes: codes, frames: frames, stop: stop, promptLen: T,
                         prefillWall: prefillWall, loopWall: (ProcessInfo.processInfo.systemUptime - t1), prefixRowsReused: reused,
                         talkerWall: talkerWall, codePredictorWall: codePredictorWall)
    }
}
#else
/// x86_64 macOS slice: Xcode compiles package targets for Intel even when the app is arm64-only,
/// and Float16 (the ANE models' I/O type) doesn't exist there. There's no Neural Engine on Intel
/// either, so the engine simply refuses to load.
@available(iOS 18.0, macOS 15.0, *)
final class ANETalkerEngine {
    static let LMAX = 1024
    var forced: [[Int]]? = nil
    private(set) var forcedPicks: [[Int]] = []
    var injectNaNLogitsAtFrame: Int? = nil
    var injectNaNSubCodesAtFrame: Int? = nil
    var usePrefixCache = true
    /// Also stop when the raw (unsampled) argmax is EOS, not only when EOS is drawn.
    var eosOnArgmax = true
    init(coreMLDirectory dir: URL, host: HostTables, experimentalCodePredictor: URL? = nil) throws {
        throw QwenANEError.invalid("the Neural Engine voice needs a Mac with Apple silicon")
    }
    static func allFinite(_ v: [Float]) -> Bool { v.allSatisfy { $0.isFinite } }
    func resetStates() {}
    static func windowFrames(promptRows T: Int) -> Int { max(0, LMAX - T) }
    static func cacheableRows(_ p: Prompt) -> Int { 0 }
    func generate(prompt: Prompt, sampler: inout Sampler, eos: Int, maxNew: Int?,
                  cancelled: () -> Bool, onFrame: (Int, ArraySlice<Int64>) throws -> Void) throws -> GenResult {
        throw QwenANEError.invalid("the Neural Engine voice needs a Mac with Apple silicon")
    }
}
#endif
