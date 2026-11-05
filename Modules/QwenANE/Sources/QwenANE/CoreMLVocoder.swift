import CoreML
import Foundation

/// Split streaming vocoder (the "final gated path" of render_fast.py --vocoder ane):
///   head     codes -> hidden, Swift/Accelerate on the CPU, exact streaming (VocoderHead)
///   upF      Core ML fp32, CPU only: hidden window (1,1024,W) -> (1,1536,4W)   [W = 12 first chunk, 20 after]
///   upMall   Core ML fp16, ANE (cpuAndNeuralEngine): (1,1536,4W) -> waveform (1,1,W*1920)
/// Both are fixed-shape multifunction models ("w12", "w20"). Core ML's CPU (BNNS) path traps on
/// enumerated shapes, and the CPU is all the iOS Simulator has and what a device falls back to; an
/// older enumerated-shape upMall (no functions) still loads, as one model serving both widths.
/// A chunk is 12 frames with 8 frames of left context (the upsampler's receptive field), so each
/// chunk is decoded the moment its 12th frame exists and the result is exact. The last chunk is
/// zero-padded on the right (causal, no effect on the kept samples).
///
/// `begin(context:)` primes the head with the voice's reference codes (their audio is dropped), the
/// way upstream's ICL decode does. Without it the vocoder starts cold and the first word comes out
/// wrong: a first word pitched an octave high, heard as a voice crack. The primed state is cached
/// per voice, so only the first line of a voice pays for it.
@available(iOS 18.0, macOS 15.0, *)
final class ANEVocoder {
    static let C = 12, L = 8
    private let head: VocoderHead
    private let upF12: MLModel, upF20: MLModel, upMall12: MLModel, upMall20: MLModel
    private let in12: MLMultiArray, in20: MLMultiArray
    private var hist = [Float](repeating: 0, count: 1024 * ANEVocoder.L)    // (1024 x 8) channel-major
    private var pending: [Int64] = []          // caller thread only (frames not yet submitted as a chunk)
    /// Frames per chunk, in order; the last entry repeats. Every entry is 1...12 (a window holds 12 new frames and
    /// a short chunk is zero-padded on the right, which is causal and changes none of its samples). The default is
    /// whole 12-frame chunks. Set between lines; caller thread only.
    var chunkSchedule: [Int] = [ANEVocoder.C]
    private var chunkIndex = 0                 // caller thread only: chunks submitted this line
    private var unprimedFirstChunk = false     // caller thread only: the next chunk has no left context
    private var wantFrames: Int {
        if unprimedFirstChunk { return Self.C }   // that window needs the full 12 frames

        return min(Self.C, max(1, chunkSchedule[min(chunkIndex, chunkSchedule.count - 1)]))
    }
    private var first = true
    private var wav: [Float] = []
    private var primed: [[Int64]: (head: VocoderHead.State, hist: [Float])] = [:]   // per voice reference
    private var primedOrder: [[Int64]] = []    // least recently used first; `primed` never holds more than `maxPrimed`
    static let maxPrimed = 4
    /// Number of primed voice states held (read on the vocoder queue).
    var primedCount: Int { queue.sync { primed.count } }
    /// Wall seconds spent decoding (head + upsamplers) since `resetStats`; read after `finish()`/`drain()`.
    private(set) var wall = 0.0
    /// When true, chunks decode on `queue` while the caller keeps generating. Every touch of the head,
    /// `hist`, `first`, `wav`, `primed` and `wall` happens on that queue (or inline when false).
    var overlap = true
    private let queue = DispatchQueue(label: "qwen.ane.vocoder", qos: .userInitiated)
    private let errLock = NSLock()
    private var firstError: Error?
    private(set) var waitWall = 0.0
    /// Streaming hook: each decoded chunk (up to 12 x 1920 samples, the exact samples `finish()` later returns)
    /// right after it is decoded, in order, on the vocoder queue (or inline when `overlap` is off). Set it
    /// between lines; it must not block. nil (the default) changes nothing about the returned audio.
    var onChunk: (([Float]) -> Void)?

    init(modelsDirectory: URL, cancelled: () -> Bool = { false }) throws {
        if cancelled() { throw CancellationError() }
        head = try VocoderHead(dir: modelsDirectory.appendingPathComponent("vochead").path)
        let dir = modelsDirectory.appendingPathComponent("coreml")
        func load(_ n: String, _ units: MLComputeUnits, function: String? = nil) throws -> MLModel {
            if cancelled() { throw CancellationError() }
            let c = MLModelConfiguration(); c.computeUnits = units
            if let function { c.functionName = function }
            let model = try MLModel(contentsOf: dir.appendingPathComponent("\(n).mlmodelc"), configuration: c)
            if cancelled() { throw CancellationError() }
            return model
        }
        // One multifunction upF.mlmodelc ("w12", "w20": same weights, two window widths); the older
        // layout shipped the weights twice as upF_12 / upF_20.
        if FileManager.default.fileExists(atPath: dir.appendingPathComponent("upF.mlmodelc").path) {
            upF12 = try load("upF", .cpuOnly, function: "w12"); upF20 = try load("upF", .cpuOnly, function: "w20")
        } else {
            upF12 = try load("upF_12", .cpuOnly); upF20 = try load("upF_20", .cpuOnly)
        }
        // macOS 27.0.1 / M2 falls back to a BNNS path that traps for the
        // published upMall model. Metal is available to a background Mac app.
        // iOS keeps the ANE placement: Metal is unavailable to locked phones.
        #if os(macOS)
        let upMallUnits: MLComputeUnits = .cpuAndGPU
        #else
        let upMallUnits: MLComputeUnits = .cpuAndNeuralEngine
        #endif
        if Self.functions(of: dir.appendingPathComponent("upMall.mlmodelc")).isSuperset(of: ["w12", "w20"]) {
            upMall12 = try load("upMall", upMallUnits, function: "w12")
            upMall20 = try load("upMall", upMallUnits, function: "w20")
        } else {
            upMall12 = try load("upMall", upMallUnits); upMall20 = upMall12
        }
        in12 = try MLMultiArray(shape: [1, 1024, 12], dataType: .float32)
        in20 = try MLMultiArray(shape: [1, 1024, 20], dataType: .float32)
        // warm-up: first predictions compile / specialise the graphs (ANE) and are cached by the system
        if cancelled() { throw CancellationError() }
        _ = try predict(window: in12, first: true)
        if cancelled() { throw CancellationError() }
        _ = try predict(window: in20, first: false)
        if cancelled() { throw CancellationError() }
    }

    /// Drops the primed per-voice states; the next line of each voice primes again.
    func dropCaches() { queue.sync { primed.removeAll(); primedOrder.removeAll() } }

    func resetStats() { drain(); wall = 0; waitWall = 0 }

    /// Runs `work` on the vocoder queue (overlap) or inline, in submission order; the first error is kept.
    private func submit(_ work: @escaping () throws -> Void) {
        let run = { [self] in
            errLock.lock(); let failed = firstError != nil; errLock.unlock()
            if failed { return }
            do { try work() } catch { errLock.lock(); firstError = error; errLock.unlock() }
        }
        if overlap { queue.async(execute: run) } else { run() }
    }

    /// Blocks until everything submitted so far has run.
    func drain() { if overlap { queue.sync {} } }

    private func takeError() -> Error? {
        errLock.lock(); defer { errLock.unlock() }
        let e = firstError; firstError = nil; return e
    }

    /// Starts a line. `context` is the voice's reference codes, frame-major (T x 16). With `overlap`
    /// the (possibly slow, first-line) priming runs on the vocoder queue, ahead of the first chunk.
    ///
    /// `continuation` (frame-major codes, the part just before this line in the same break) is streamed through
    /// the head after the voice's primed state, its audio dropped: the line then decodes as the next frames of
    /// what was just played, the way upstream decodes a continuation [reference ; previous ; line] in one pass.
    func begin(context: [Int64]?, continuation: [Int64]? = nil) {
        drain(); _ = takeError()
        pending = []; pending.reserveCapacity(Self.C * 16)
        chunkIndex = 0
        unprimedFirstChunk = (context?.count ?? 0) / 16 + (continuation?.count ?? 0) / 16 < Self.L
        waitWall = 0
        submit { [self] in
            beginOnQueue(context: context)
            if let cont = continuation, cont.count >= 16 { continueOnQueue(cont) }
        }
    }

    /// Runs `codes` through the head from the current state and makes their last hidden frames the upsampler's
    /// left context. Their audio is never produced.
    private func continueOnQueue(_ codes: [Int64]) {
        let T = codes.count / 16, L = Self.L
        if first && T < L { return }      // no primed history to extend: the line starts cold, as without it
        let h = codes.withUnsafeBufferPointer { head.process(codes: $0.baseAddress!, frames: T) }
        if T >= L {
            for c in 0..<1024 { for j in 0..<L { hist[c * L + j] = h[(T - L + j) * 1024 + c] } }
        } else {
            // fewer than 8 new frames: shift the history left and append them
            for c in 0..<1024 {
                for j in 0..<(L - T) { hist[c * L + j] = hist[c * L + j + T] }
                for j in 0..<T { hist[c * L + L - T + j] = h[j * 1024 + c] }
            }
        }
        first = false
    }

    private func beginOnQueue(context: [Int64]?) {
        wav = []
        if let ctx = context, ctx.count / 16 >= Self.L {
            let p: (head: VocoderHead.State, hist: [Float])
            if let hit = primed[ctx] {
                p = hit
                if let i = primedOrder.firstIndex(of: ctx) { primedOrder.remove(at: i) }
            } else {
                p = prime(ctx); primed[ctx] = p
                while primed.count >= Self.maxPrimed + 1, let old = primedOrder.first {
                    primedOrder.removeFirst(); primed[old] = nil
                }
            }
            primedOrder.append(ctx)
            head.state = p.head; hist = p.hist; first = false
            return
        }
        head.reset()
        hist = [Float](repeating: 0, count: 1024 * Self.L)
        first = true
    }

    /// Runs the reference codes through the head once (no upsampler: their audio is never kept) and
    /// returns the state a line then starts from: head K/V + conv history, and the upsampler's
    /// 8-frame left context = the reference's last 8 hidden frames. Identical to streaming the
    /// reference ahead of the line and dropping its audio.
    private func prime(_ ctx: [Int64]) -> (head: VocoderHead.State, hist: [Float]) {
        let T = ctx.count / 16, L = Self.L
        head.reset()
        let h = ctx.withUnsafeBufferPointer { head.process(codes: $0.baseAddress!, frames: T) }
        var hs = [Float](repeating: 0, count: 1024 * L)
        for c in 0..<1024 { for j in 0..<L { hs[c * L + j] = h[(T - L + j) * 1024 + c] } }
        return (head.state, hs)
    }

    /// Adds one frame's 16 codes; a chunk is decoded as soon as its 12th frame exists.
    func push(frame: ArraySlice<Int64>) throws {
        if let e = takeErrorIfAny() { throw e }
        guard frame.count == 16, frame.allSatisfy({ $0 >= 0 && $0 < QwenVoiceFiles.codebookSize }) else {
            throw QwenANEError.invalid("vocoder frame has a code outside 0..<\(QwenVoiceFiles.codebookSize)")
        }
        pending.append(contentsOf: frame)
        if pending.count == wantFrames * 16 { submitPending() }
    }

    private func takeErrorIfAny() -> Error? {
        errLock.lock(); defer { errLock.unlock() }
        return firstError
    }

    private func submitPending() {
        let codes = pending
        pending.removeAll(keepingCapacity: true)
        chunkIndex += 1
        unprimedFirstChunk = false
        submit { [self] in try chunk(codes) }
    }

    /// Flushes the partial last chunk and returns the whole line (frames * 1920 samples).
    /// Waits for the queue to drain (`waitWall` is how long that took) and rethrows the first decode error.
    func finish() throws -> [Float] {
        if !pending.isEmpty { submitPending() }
        let w0 = ProcessInfo.processInfo.systemUptime
        drain()
        waitWall = ProcessInfo.processInfo.systemUptime - w0
        if let e = takeError() { throw e }
        var out: [Float] = []
        queue.sync { out = wav; wav = [] }      // hands the buffer over on the owning queue
        return out
    }

    /// `codes` is frame-major (frames x 16). Returns 24 kHz mono float samples (frames * 1920).
    func decode(codes: [Int64], frames n: Int, context: [Int64]? = nil) throws -> [Float] {
        begin(context: context)
        for f in 0..<n { try push(frame: codes[(f * 16)..<(f * 16 + 16)]) }
        return try finish()
    }

    // MARK: one chunk

    private func chunk(_ codes: [Int64]) throws {
        let w0 = ProcessInfo.processInfo.systemUptime
        let n = codes.count / 16, C = Self.C, L = Self.L
        let h = codes.withUnsafeBufferPointer { head.process(codes: $0.baseAddress!, frames: n) }    // n x 1024
        let win = first ? in12 : in20
        let ctx = first ? 0 : L
        // window (1, 1024, W): channel-major, [8 history frames][12 new frames, zero padded]
        let s1 = win.strides[1].intValue, s2 = win.strides[2].intValue
        win.withUnsafeMutableBytes { raw, _ in
            let p = raw.bindMemory(to: Float.self).baseAddress!
            for c in 0..<1024 {
                for j in 0..<ctx { p[c * s1 + j * s2] = hist[c * L + j] }
                for t in 0..<C { p[c * s1 + (ctx + t) * s2] = t < n ? h[t * 1024 + c] : 0 }
            }
        }
        // history = the last 8 REAL frames of the window (a short chunk's zero padding is not history)
        win.withUnsafeBytes { raw in
            let p = raw.bindMemory(to: Float.self)
            for c in 0..<1024 { for j in 0..<L { hist[c * L + j] = p[c * s1 + (ctx + n - L + j) * s2] } }
        }
        let out = try predict(window: win, first: first)          // the C*1920 samples of the new frames
        wav.append(contentsOf: out[0..<(n * 1920)])
        if let onChunk { onChunk(Array(out[0..<(n * 1920)])) }
        first = false
        wall += ProcessInfo.processInfo.systemUptime - w0
    }

    /// The function names a compiled model declares (its metadata.json `functions`); empty for a
    /// single-function model.
    static func functions(of model: URL) -> Set<String> {
        guard let d = try? Data(contentsOf: model.appendingPathComponent("metadata.json")),
              let j = (try? JSONSerialization.jsonObject(with: d)) as? [[String: Any]],
              let fs = j.first?["functions"] as? [[String: Any]] else { return [] }
        return Set(fs.compactMap { $0["name"] as? String })
    }

    /// The C*1920 waveform samples belonging to the 12 newest frames of the window.
    private func predict(window: MLMultiArray, first: Bool) throws -> [Float] {
        try autoreleasepool {
            let ctx = first ? 0 : Self.L
            let f = first ? upF12 : upF20
            let x = try f.prediction(from: MLDictionaryFeatureProvider(dictionary: ["hidden": window]))
            guard let xv = x.featureValue(for: "x") else { throw QwenANEError.invalid("upF: no output x") }
            let y = try (first ? upMall12 : upMall20).prediction(from: MLDictionaryFeatureProvider(dictionary: ["x": xv]))
            guard let wv = y.featureValue(for: "wav")?.multiArrayValue else { throw QwenANEError.invalid("upMall: no output wav") }
            guard wv.dataType == .float32 else { throw QwenANEError.invalid("upMall wav is not float32") }
            let st = wv.strides.last!.intValue
            var out = [Float](repeating: 0, count: Self.C * 1920)
            wv.withUnsafeBytes { raw in
                let p = raw.bindMemory(to: Float.self)
                for i in 0..<out.count { out[i] = p[(ctx * 1920 + i) * st] }
            }
            return out
        }
    }
}
