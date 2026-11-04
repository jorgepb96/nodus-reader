import Foundation

/// Why a render stopped.
public enum QwenStopReason: String, Sendable {
    /// The talker emitted its end-of-speech token.
    case eos
    /// The frame cap (6 frames per text token, at least 75, at most 4096) was reached.
    case maxTokens
    /// `cancelled()` returned true; `QwenRender.samples` is empty.
    case cancelled
    /// The line ended in 1.5 s of silence, which was cut (the order render_onnx.py uses).
    case trailingSilence
    /// The talker's 1024-row KV window filled before the end-of-speech token, so the line is cut short
    /// (the audio is a truncated line). Split the text first: see `QwenANEEngine.maxFrames(text:voice:)`.
    case contextFull
}

public enum QwenANEError: Error, LocalizedError {
    case invalid(String)
    /// The Neural Engine produced NaN/Inf (or a code outside the codebook). The line is abandoned, the
    /// KV state is reset, and the engine is usable for the next line.
    case nonFinite(String)

    public var errorDescription: String? {
        switch self {
        case .invalid(let m): return "QwenANE: \(m)"
        case .nonFinite(let m): return "QwenANE: non-finite output (\(m))"
        }
    }
}

/// Per-line wall-clock timings, in seconds.
public struct QwenTimings: Sendable, Equatable {
    /// Prompt build: text projection, tokenizer, ICL rows.
    public var prompt: Double
    /// Talker prefill plus the first decode step.
    public var prefill: Double
    /// Talker + code predictor loop (`generate` wall; with the vocoder overlapped it contains no vocoder wait).
    public var loop: Double
    /// Vocoder busy time: head + upsamplers (+ reference priming on a voice's first line), wherever it ran.
    /// When `overlapVocoder` is on this runs beside `loop`, so it is not added to the wall time.
    public var vocoder: Double
    /// Time `finish()` blocked on the vocoder queue after the last frame (0 inline).
    public var vocoderWait: Double
    /// Whole `render` call.
    public var total: Double
    /// Prediction time inside `loop`, excluding prefill and host-side sampling/embedding work.
    public var talker: Double = 0
    public var codePredictor: Double = 0
}

/// The result of one rendered line.
public struct QwenRender: Sendable {
    /// Mono float samples at `sampleRate` (frames x 1920). Empty when cancelled.
    public var samples: [Float]
    public var sampleRate: Int
    /// Audio frames kept (80 ms each), after any trailing-silence cut.
    public var frames: Int
    /// The codec codes for the kept frames, frame-major (frames x 16).
    public var codes: [Int64]
    public var stopReason: QwenStopReason
    public var timings: QwenTimings
    /// Silence in the vocoder output, before `Options.capPauses` ran (`.empty` when cancelled).
    /// Prompt rows whose talker KV came from the voice's cached prefix (0 on a voice's first line, or with
    /// `Options.prefixCache` off); those rows were not prefilled again.
    public var prefixRowsReused: Int = 0
    /// Silence in the vocoder output, before `Options.capPauses` ran (`.empty` when cancelled).
    public var silenceBefore: SilenceReport = .empty
    /// Silence in `samples` as returned (equals `silenceBefore` when capping is off or nothing was cut).
    public var silence: SilenceReport = .empty
    /// Internal pauses shortened by `Options.capPauses`.
    public var pausesCapped: Int = 0
    /// Frames of the previous part of the same break the line was conditioned on (0: the reference alone).
    public var contextFrames: Int = 0
    /// Takes drawn for this line (`QwenTalkSession` draws again when a take derails; 1 otherwise).
    public var takes: Int = 1
    /// The most frames this line could generate: the runaway cap (`QwenReadRules.frameCap`, which follows the
    /// voice's pace) or the caller's `maxFrames`, within the KV window left after the prompt.
    public var frameCap: Int = 0
    /// Frames predicted before trailing silence is removed. Useful for
    /// comparing compute per frame when two takes have different silent tails.
    public var generatedFrames: Int = 0
    /// Seconds of audio. `frames` and `codes` describe the uncapped render; `samples` is capped.
    public var audioSeconds: Double { Double(samples.count) / Double(sampleRate) }
}

/// How the talker draws each frame's first-codebook token.
public struct QwenSampling: Sendable, Equatable {
    public var temperature: Double
    /// Tokens kept before the draw (0 = all).
    public var topK: Int
    /// Penalty on every first-codebook token already generated in the line.
    public var repetition: Float
    /// Also stop when the most likely token is end-of-speech even though another token was drawn.
    public var eosOnArgmax: Bool
    public init(temperature: Double = 0.9, topK: Int = 0, repetition: Float = 1.05, eosOnArgmax: Bool = true) {
        self.temperature = temperature; self.topK = topK; self.repetition = repetition; self.eosOnArgmax = eosOnArgmax
    }
}

@available(iOS 18.0, macOS 15.0, *)
extension QwenANEEngine {
    public struct Options: Sendable {
        /// Decode vocoder chunks on a serial queue beside the talker loop (same samples, less wall time).
        public var overlapVocoder = true
        /// Shorten dead air in the finished line (see `QwenSilence.cap`): internal pauses over 0.7 s down
        /// to 0.45 s, leading silence to 0.05 s, trailing to 0.1 s.
        public var capPauses = true
        /// Keep each voice's prompt rows and the talker's KV for its leading prompt rows (the role, think and
        /// speaker rows and the reference transcript), and reuse them on every later line of the voice. The
        /// codes are identical to a render without it; off is the way to prove that.
        public var prefixCache = true
        /// Frames (80 ms each) in each vocoder chunk, in order, the last entry repeating; each is 1...12. The
        /// default, whole 12-frame chunks, delivers the first audio after 12 frames. A short first chunk
        /// (`[4, 8, 12]`) delivers it sooner, at the cost of a thinner audio buffer ahead of playback: it only
        /// plays gaplessly while the render stays faster than real time (RTF < 1) and later chunks grow. The samples
        /// are the same either way; only where the chunk boundaries fall changes.
        public var chunkFrames: [Int] = [12]
        /// First-codebook sampling.
        public var sampling = QwenSampling()
        public init(overlapVocoder: Bool = true, capPauses: Bool = true, prefixCache: Bool = true,
                    chunkFrames: [Int] = [12]) {
            self.overlapVocoder = overlapVocoder; self.capPauses = capPauses; self.prefixCache = prefixCache
            self.chunkFrames = chunkFrames
        }
    }
}

/// Text to speech with Qwen3-TTS (0.6B or 1.7B, the model set says which) on the Neural Engine: talker + code predictor and the
/// vocoder upsampler run as Core ML models, the rest (text projection, vocoder head) on the CPU.
/// No MLX, no ONNX Runtime. See the README next to this file for the model directory layout.
///
/// One engine renders one line at a time: `render` is serialised by an internal lock, so a second
/// caller waits. Create one engine per process and share it; building it loads about 1.3 GB of
/// models and warms the vocoder, which takes seconds. `render` blocks for the whole line (about
/// real time), so call it from a background queue.
@available(iOS 18.0, macOS 15.0, *)
public final class QwenANEEngine: @unchecked Sendable {
    let host: HostTables
    let talker: ANETalkerEngine
    private let vocoder: ANEVocoder
    private let lock = NSLock()
    /// The directory the engine was loaded from; `loadVoice(named:)` reads `voices/<name>` under it.
    public let modelsDirectory: URL
    /// The talker's width, which is also the size of the x-vector a voice must carry: 1024 (0.6B) or 2048 (1.7B).
    public var speakerDimension: Int { host.hidden }

    /// Frames (80 ms each) the talker can generate for `text` in `voice` before its KV window fills: the
    /// runaway cap that follows the voice's pace (`QwenReadRules.frameCap`), within the window left after
    /// the prompt (reference + text). A line that hits the window ends with `.contextFull`; hosts split
    /// text so this stays above the frames the line needs. Throws for a voice that fails validation.
    public func maxFrames(text: String, voice: QwenVoiceFiles, language: String? = nil) throws -> Int {
        try QwenVoiceFiles.validate(refCodes: voice.refCodes)
        let p = buildICLPrompt(host: host, voice: voice, text: text, language: language)
        return frameCap(p, voice: voice, window: ANETalkerEngine.windowFrames(promptRows: p.T))
    }

    /// `voice`'s pace: reference codec frames per reference transcript token, clamped
    /// (`QwenReadRules.voiceFramesPerToken`). Nil for a voice without a reference.
    public func voiceFramesPerToken(_ voice: QwenVoiceFiles) -> Double? {
        QwenReadRules.voiceFramesPerToken(referenceFrames: voice.refCodes.first?.count ?? 0,
                                          referenceTokens: VoicePrompt.transcriptIds(host, voice.refText).count)
    }

    /// The runaway cap for `prompt`'s line in `voice`, within `window`.
    func frameCap(_ prompt: Prompt, voice: QwenVoiceFiles, window: Int = .max) -> Int {
        let pace = QwenReadRules.voiceFramesPerToken(referenceFrames: voice.refCodes.first?.count ?? 0,
                                                     referenceTokens: prompt.refTextIds.count)
        return QwenReadRules.frameCap(textTokens: prompt.nTextTokens, voiceFramesPerToken: pace, window: window)
    }

    /// Drops every cache that can be rebuilt: the vocoder's primed per-voice states (the next line of a
    /// voice re-primes, about a second). Call on a memory warning.
    public func dropCaches() {
        lock.lock(); defer { lock.unlock() }
        vocoder.dropCaches()
        voicePrompts.removeAll(); voicePromptOrder.removeAll()
    }

    /// Voices whose prompt rows and talker KV prefix are kept (least recently used out).
    public static let maxCachedVoices = 4
    private struct VoiceKey: Hashable {
        let refText: String, refCodes: [[Int]], spk: [Float], language: String?
        init(_ v: QwenVoiceFiles, language: String?) {
            refText = v.refText; refCodes = v.refCodes; spk = v.spkEmbedding
            self.language = QwenLanguage.codecName(for: language)
        }
    }
    private var voicePrompts: [VoiceKey: VoicePrompt] = [:]
    private var voicePromptOrder: [VoiceKey] = []      // least recently used first
    /// Number of voices with cached prompt rows (for tests and diagnostics).
    public var cachedVoiceCount: Int { lock.lock(); defer { lock.unlock() }; return voicePrompts.count }
    /// Caller holds `lock`.
    private func voicePrompt(for voice: QwenVoiceFiles, language: String? = nil) -> VoicePrompt {
        let key = VoiceKey(voice, language: language)
        if let hit = voicePrompts[key] {
            if let i = voicePromptOrder.firstIndex(of: key) { voicePromptOrder.remove(at: i) }
            voicePromptOrder.append(key)
            return hit
        }
        let vp = VoicePrompt(host: host, voice: voice, language: language)
        voicePrompts[key] = vp; voicePromptOrder.append(key)
        while voicePrompts.count > Self.maxCachedVoices, let old = voicePromptOrder.first {
            voicePromptOrder.removeFirst(); voicePrompts[old] = nil
        }
        return vp
    }

    /// Gets `voice` ready so its next line starts fast: builds its prompt rows, primes the vocoder with its
    /// reference, fills the talker KV prefix, and runs a few frames so every Core ML function (prefill, decode,
    /// code predictor, vocoder) has been through its first, slow, call. Renders no audio the caller sees.
    /// Returns the seconds it took. Blocks like `render`; honors `cancelled`.
    @discardableResult
    public func warm(voice: QwenVoiceFiles, cancelled: () -> Bool = { false }) throws -> Double {
        let t0 = ProcessInfo.processInfo.systemUptime
        _ = try render(text: "Ready.", voice: voice, seed: 1, maxFrames: 3, cancelled: cancelled)
        return (ProcessInfo.processInfo.systemUptime - t0)
    }

    /// Read at the start of each `render`; set between renders.
    public var options = Options()

    /// Loads host tables, the vocoder head and the compiled Core ML models (`.mlmodelc`).
    /// The vocoder loads first: the Core ML models before anything that maps big files.
    /// `experimentalCodePredictor` is a probe-only override for a separately
    /// pinned INT8 export. App callers leave it nil; the installed model set
    /// and the full 1024-slot ICL talker remain unchanged.
    public init(modelsDirectory: URL, experimentalCodePredictor: URL? = nil) throws {
        self.modelsDirectory = modelsDirectory
        host = try HostTables(dir: modelsDirectory.appendingPathComponent("host").path)
        vocoder = try ANEVocoder(modelsDirectory: modelsDirectory)
        talker = try ANETalkerEngine(coreMLDirectory: modelsDirectory.appendingPathComponent("coreml"), host: host,
                                    experimentalCodePredictor: experimentalCodePredictor)
    }

    /// Reads `voices/<name>/{voice.json, ref_codes.npy, spk_embed.npy}` from the models directory.
    public func loadVoice(named name: String) throws -> QwenVoiceFiles {
        try QwenVoiceFiles(directory: modelsDirectory.appendingPathComponent("voices").appendingPathComponent(name))
    }

    /// Renders one line in `voice`.
    ///
    /// - Parameters:
    ///   - seed: sampler seed. The same seed draws numpy's `default_rng(seed)` stream, which makes
    ///     a render reproducible and comparable to the Python reference. `nil` picks a random one.
    ///   - maxFrames: optional cap on generated frames (80 ms each), below the built-in cap (which follows
    ///     the voice's pace, `QwenReadRules.frameCap`).
    ///   - chunkFrames: this line's vocoder chunk schedule (see `Options.chunkFrames`); nil uses the option.
    ///   - language: BCP-47 tag ("es", "es-MX", "en-US") that sets Qwen's codec language token. Nil (the
    ///     default) or "auto" is language auto-detect, bit-identical to a render without the parameter.
    ///   - cancelled: polled once per frame; return true to stop. The render then returns no samples.
    ///   - pace: called between stages and after every frame, on the rendering thread. A host app
    ///     can sleep in it to hold a duty cycle (thermal / battery); a sleep adds directly to wall time.
    ///   - onAudio: streaming hook. Called with each decoded vocoder chunk (12 frames, 0.96 s) as soon as it
    ///     is ready, in order, from the vocoder queue (`overlapVocoder`) or the rendering thread (inline), so it
    ///     must return quickly (yield to a stream, never wait on the network). The audio is trimmed with
    ///     `QwenStreamTrimmer`: leading silence is capped at 0.05 s, trailing silence is held back (at most
    ///     0.1 s is delivered at the end), and internal pauses are NOT shortened. The delivered samples are
    ///     a contiguous slice, bit for bit, of the un-capped line; `QwenRender.samples` is unchanged by
    ///     this hook (it still gets `Options.capPauses`). Nothing is delivered for a cancelled render.
    public func render(text: String, voice: QwenVoiceFiles, seed: UInt64? = nil, maxFrames: Int? = nil,
                       chunkFrames: [Int]? = nil, language: String? = nil,
                       cancelled: () -> Bool = { false }, pace: () -> Void = {},
                       onAudio: (([Float]) -> Void)? = nil) throws -> QwenRender {
        lock.lock(); defer { lock.unlock() }
        var sampler = makeSampler(seed: seed ?? UInt64.random(in: 0...UInt64.max))
        return try renderLocked(text: text, voice: voice, sampler: &sampler, maxFrames: maxFrames, chunkFrames: chunkFrames,
                                language: language, continuation: nil, cancelled: cancelled, pace: pace, onAudio: onAudio)
    }

    func makeSampler(seed: UInt64) -> Sampler {
        let sm = options.sampling
        return Sampler(temperature: sm.temperature, repetition: sm.repetition, topK: sm.topK,
                       vocab: host.cfg.vocab, eos: host.cfg.codecEos, seed: seed)
    }

    /// Serialises a session's part with every other render.
    func withLock<T>(_ body: () throws -> T) rethrows -> T { lock.lock(); defer { lock.unlock() }; return try body() }

    /// `render`'s body; the caller holds `lock`. `sampler` carries on from wherever the caller's stream is
    /// (a session draws every part of a break from one stream). `continuation` is the previous part of the
    /// same break; it is dropped when it would leave the line fewer frames than it would get without it.
    func renderLocked(text: String, voice: QwenVoiceFiles, sampler: inout Sampler, maxFrames: Int?,
                      chunkFrames: [Int]?, language: String?, continuation: QwenContinuation?,
                      cancelled: () -> Bool, pace: () -> Void,
                      onAudio: (([Float]) -> Void)?) throws -> QwenRender {
        try QwenVoiceFiles.validate(refCodes: voice.refCodes)
        guard voice.spkEmbedding.count == host.hidden else {
            throw QwenANEError.invalid("spkEmbedding must have \(host.hidden) values (this model set's x-vector size)")
        }
        let t0 = ProcessInfo.processInfo.systemUptime
        talker.usePrefixCache = options.prefixCache
        talker.eosOnArgmax = options.sampling.eosOnArgmax
        let vp = options.prefixCache ? voicePrompt(for: voice, language: language) : nil
        func build(_ c: QwenContinuation?) -> Prompt {
            buildICLPrompt(host: host, voice: voice, text: text, language: language, voicePrompt: vp,
                           keepVoicePrompt: options.prefixCache, continuation: c)
        }
        var prompt = build(continuation)
        var carried = continuation?.frames ?? 0
        // The runaway cap follows the voice's pace (the continuation does not change it).
        let cap = frameCap(prompt, voice: voice)
        if carried > 0 {
            let want = min(maxFrames ?? Int.max, cap)
            if ANETalkerEngine.windowFrames(promptRows: prompt.T) < want || prompt.T >= ANETalkerEngine.LMAX - 8 {
                prompt = build(nil); carried = 0
            }
        }
        let requested = maxFrames ?? cap
        let promptS = (ProcessInfo.processInfo.systemUptime - t0)
        pace()
        let voc = vocoder
        voc.overlap = options.overlapVocoder
        let schedule = chunkFrames ?? options.chunkFrames
        voc.chunkSchedule = schedule.isEmpty ? [12] : schedule
        let overlapped = voc.overlap
        voc.resetStats()
        let trimmer = onAudio.map { _ in QwenStreamTrimmer(sampleRate: sampleRate) }
        voc.onChunk = onAudio.map { deliver in
            { chunk in let out = trimmer!.push(chunk); if !out.isEmpty { deliver(out) } }
        }
        defer { voc.onChunk = nil }
        voc.begin(context: voice.referenceFrames, continuation: carried > 0 ? continuation?.codes : nil)
        let g: GenResult
        do {
            g = try talker.generate(prompt: prompt, sampler: &sampler, eos: host.cfg.codecEos, maxNew: requested,
                                    cancelled: cancelled, onFrame: { _, codes in try voc.push(frame: codes); pace() })
        } catch { voc.drain(); throw error }
        var n = g.frames
        func result(_ wav: [Float], _ stop: QwenStopReason, _ codes: [Int64]) -> QwenRender {
            QwenRender(samples: wav, sampleRate: sampleRate, frames: n, codes: codes, stopReason: stop,
                       timings: QwenTimings(prompt: promptS, prefill: g.prefillWall,
                                            loop: overlapped ? g.loopWall : max(0, g.loopWall - voc.wall),
                                            vocoder: voc.wall, vocoderWait: voc.waitWall, total: (ProcessInfo.processInfo.systemUptime - t0),
                                            talker: g.talkerWall, codePredictor: g.codePredictorWall))
        }
        guard n > 0, g.stop != .cancelled else { voc.drain(); n = 0; return result([], g.stop, []) }
        pace()
        var wav: [Float]
        do { wav = try voc.finish() } catch { voc.drain(); throw error }   // flushes the partial last chunk, waits for the queue
        if let onAudio, let trimmer { let tail = trimmer.finish(); if !tail.isEmpty { onAudio(tail) } }
        pace()
        var stop = g.stop
        var codes = g.codes
        let cut = trailingSilenceCut(wav, frames: n)
        if cut < n {
            n = cut; wav = Array(wav[0..<(cut * samplesPerFrame)]); codes = Array(codes[0..<(cut * 16)])
            if stop != .contextFull { stop = .trailingSilence }
        }
        var out = result(wav, stop, codes)
        out.generatedFrames = g.frames
        out.prefixRowsReused = g.prefixRowsReused
        out.contextFrames = carried
        out.frameCap = min(requested, ANETalkerEngine.windowFrames(promptRows: prompt.T))
        out.silenceBefore = QwenSilence.analyze(samples: wav, sampleRate: sampleRate)
        out.silence = out.silenceBefore
        if options.capPauses {
            let c = QwenSilence.cap(samples: wav, sampleRate: sampleRate)
            if c.samples.count != wav.count {
                out.samples = c.samples; out.pausesCapped = c.pausesCapped
                out.silence = QwenSilence.analyze(samples: c.samples, sampleRate: sampleRate)
            }
        }
        return out
    }
}
