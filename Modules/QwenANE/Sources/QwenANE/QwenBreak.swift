import Foundation

/// The rules one read (a talk break, a long line) follows on every Qwen backend: the Neural Engine
/// (`QwenTalkSession`) and the iPhone's MLX path (gloam-voice-studio-ios `QwenMLXEngine`). Pure and
/// model-free, so a host on either backend applies the same split, the same derail test and the same
/// carry decision.
public enum QwenReadRules {
    /// Extra takes drawn for a part whose take derailed. Not when streaming: its chunks are already out.
    public static let maxRedraws = 2
    /// A silent run longer than this between two stretches of speech makes a take derailed.
    public static let maxPauseSeconds = 2.0
    /// The part size a break is split into: ~10 s of speech, the size the radio and the iPhone render.
    public static let defaultMaxPartChars = 160

    /// A take that derailed: it ran to the frame cap without ending, or it holds a silent run of more than
    /// `maxPauseSeconds` between two stretches of speech. Measured on Bad Bunny and Benson Spanish parts
    /// (360 renders, Whisper large-v3 turbo as the judge): it catches 34 of the 53 unintelligible takes and
    /// fires on 3 of the 307 intelligible ones (1 %), whose redraw only costs time.
    public static func derailed(hitFrameCap: Bool, longestPause: Double) -> Bool {
        hitFrameCap || longestPause > maxPauseSeconds
    }

    /// Orders takes when none is clean: one that ended beats one that hit the cap, then the shorter dead air.
    public static func badness(hitFrameCap: Bool, longestPause: Double) -> Double {
        (hitFrameCap ? 100 : 0) + longestPause
    }

    /// Whether the next part may continue this take. Only a finished take with frames that did not derail
    /// AND was not flagged by any check that ran before the next part starts: carrying a bad part spreads
    /// it (a bad reference's undetected bad part 1 made part 2 bad 8/30 times carried vs 1/30 not).
    public static func carries(frames: Int, derailed: Bool, flagged: Bool = false) -> Bool {
        frames > 0 && !derailed && !flagged
    }

    /// Frames of a take worth carrying (24 kHz audio, 1920 samples a frame): true trailing silence past
    /// 1.5 s is cut, as the Neural Engine path cuts its renders, so the next part does not continue a
    /// long silence. `floorDb` is what counts as silent (-35 dBFS, or the reference's noise-bed floor).
    public static func keptFrames(samples24k: [Float], frames: Int, floorDb: Float = -35) -> Int {
        let total = min(frames, samples24k.count / samplesPerFrame)
        guard total > 0 else { return 0 }
        return trailingSilenceCut(samples24k, frames: total, floorDb: floorDb)
    }

    // MARK: Runaway frame cap

    /// The fixed cap rate: a take may run 6 frames (80 ms each) per token of its text. A 160-character part
    /// (~44 tokens) stops at 264 frames (21.1 s), which cuts a slow or pause-heavy voice off mid-sentence.
    public static let baseFramesPerToken = 6
    /// The cap never drops under this many frames (6 s), whatever the text length.
    public static let minFrameCap = 75
    /// The cap never exceeds this many frames.
    public static let maxFrameCap = 4096
    /// The voice-following cap allows this many times the voice's own pace.
    public static let voicePaceMargin = 2.0
    /// A measured voice pace (frames per token) is clamped to this range, so a broken reference (a
    /// transcript of one word, or of a different clip) cannot give an absurd cap.
    public static let voiceFramesPerTokenRange: ClosedRange<Double> = 3...20
    /// The highest frames-per-token rate `frameCap` can give (`voicePaceMargin` x the range's top, 40).
    /// A backend whose own length clamp multiplies the text's tokens by a fixed factor (the MLX fork's
    /// `framesPerTextToken`) sets that factor to this, so the cap passed in is the one that binds.
    public static let maxFramesPerToken = Int((voicePaceMargin * voiceFramesPerTokenRange.upperBound).rounded(.up))

    /// The voice's pace from its own reference: codec frames per transcript token (the same tokenizer that
    /// counts a line's text tokens), clamped to `voiceFramesPerTokenRange`. Nil when either count is not
    /// positive (no reference to measure).
    public static func voiceFramesPerToken(referenceFrames: Int, referenceTokens: Int) -> Double? {
        guard referenceFrames > 0, referenceTokens > 0 else { return nil }
        let r = Double(referenceFrames) / Double(referenceTokens)
        return min(voiceFramesPerTokenRange.upperBound, max(voiceFramesPerTokenRange.lowerBound, r))
    }

    /// Frames a take of a line with `textTokens` tokens may generate before the runaway cap stops it:
    /// the larger of `baseFramesPerToken` x tokens and `voicePaceMargin` x the voice's pace x tokens
    /// (rounded up), at least `minFrameCap`, at most `maxFrameCap`, and never past `window` (the frames
    /// that fit the KV window after the prompt). A nil pace is the fixed 6-per-token cap. Every Qwen
    /// backend (the Neural Engine, the iPhone's MLX path) stops a take here; EOS, the trailing-silence
    /// stop and the derail rules are unchanged.
    public static func frameCap(textTokens: Int, voiceFramesPerToken: Double?, window: Int = .max) -> Int {
        let n = max(0, textTokens)
        var cap = baseFramesPerToken * n
        if let r = voiceFramesPerToken, r.isFinite {
            let clamped = min(voiceFramesPerTokenRange.upperBound, max(voiceFramesPerTokenRange.lowerBound, r))
            cap = max(cap, Int((voicePaceMargin * clamped * Double(n)).rounded(.up)))
        }
        return max(0, min(window, min(maxFrameCap, max(minFrameCap, cap))))
    }

    /// A fresh seed for a read nobody asked to reproduce (Regenerate must give a new take).
    public static func randomSeed() -> UInt64 { UInt64.random(in: 0...UInt64.max) }

    /// The read split into parts of at most `maxPartChars` characters: whole sentences grouped while they
    /// fit, a longer sentence split at its clauses, then at words. Text that fits is one part, unchanged.
    public static func split(_ text: String, maxPartChars: Int = defaultMaxPartChars) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let limit = max(20, maxPartChars)
        if trimmed.count <= limit { return [trimmed] }
        var parts: [String] = []
        var current = ""
        func flush() { if !current.isEmpty { parts.append(current); current = "" } }
        func add(_ piece: String) {
            if current.isEmpty { current = piece }
            else if current.count + 1 + piece.count <= limit { current += " " + piece }
            else { flush(); current = piece }
        }
        for sentence in pieces(trimmed, endingAt: sentenceEnds) {
            if sentence.count <= limit { add(sentence); continue }
            for clause in pieces(sentence, endingAt: clauseEnds) {
                if clause.count <= limit { add(clause); continue }
                for word in clause.split(whereSeparator: \.isWhitespace) { add(String(word)) }
            }
        }
        flush()
        return parts
    }

    static let sentenceEnds: Set<Character> = [".", "!", "?", "…", "。", "！", "？"]
    static let clauseEnds: Set<Character> = [",", ";", ":", "—", "–", "，", "；"]
    static let closers: Set<Character> = ["\"", "'", "”", "’", ")", "]", "»"]

    /// `text` cut after each run of `ends` (plus closing quotes/brackets) that is followed by whitespace.
    static func pieces(_ text: String, endingAt ends: Set<Character>) -> [String] {
        var out: [String] = []
        var cur = ""
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            cur.append(chars[i])
            if ends.contains(chars[i]) {
                var j = i + 1
                while j < chars.count, ends.contains(chars[j]) || closers.contains(chars[j]) { cur.append(chars[j]); j += 1 }
                i = j
                if i >= chars.count || chars[i].isWhitespace {
                    let s = cur.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !s.isEmpty { out.append(s) }
                    cur = ""
                }
                continue
            }
            i += 1
        }
        let s = cur.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.isEmpty { out.append(s) }
        return out
    }
}

/// What the next part of a read continues: the last part that `QwenReadRules.carries`, or nothing (the
/// next part starts from the reference). Generic over what a backend keeps (the Neural Engine keeps
/// transcript ids and Int64 codes, MLX an `MLXArray`).
public struct QwenCarry<Context> {
    public private(set) var previous: Context?
    /// Off renders every part from the reference alone (still from the read's one sampler stream).
    public var enabled: Bool

    public init(enabled: Bool = true) { self.enabled = enabled }

    /// What the next part is conditioned on.
    public var context: Context? { enabled ? previous : nil }

    /// A part ended. `take` is what it would hand on, nil when it must not be carried (derailed, flagged,
    /// empty): the next part then starts from the reference. A cancelled part changes nothing.
    public mutating func partEnded(cancelled: Bool, take: Context?) {
        guard !cancelled else { return }
        previous = take
    }
}

/// One part of a rendered break, for logs.
public struct QwenBreakPart: Sendable, Equatable {
    public var index: Int
    public var text: String
    public var frames: Int
    /// Takes drawn (more than 1 when a take derailed and was redrawn).
    public var takes: Int
    public var stopReason: QwenStopReason
    /// Frames of the previous part this one continued (0: the reference alone).
    public var contextFrames: Int
    public var longestPause: Double
    public var derailed: Bool
    public var audioSeconds: Double
    public var renderSeconds: Double
    /// The most frames the part could generate (`QwenRender.frameCap`).
    public var frameCap: Int = 0
    /// Engine stage timings of the take that was kept (prompt, prefill, loop, vocoder busy/wait), for hosts
    /// that log where render time went. Nil when built outside `renderBreak`.
    public var timings: QwenTimings? = nil
    public var generatedFrames: Int = 0

    public var logLine: String {
        String(format: "part %d: %d frames (cap %d), %.2f s audio in %.2f s, stop %@, takes %d, context %d frames, longest pause %.2f s%@ -- %@",
               index + 1, frames, frameCap, audioSeconds, renderSeconds, stopReason.rawValue, takes, contextFrames, longestPause,
               derailed ? " (derailed)" : "", String(text.prefix(48)))
    }
}

/// A rendered break: the joined audio (empty when streamed through `onAudio`) and one report per part.
public struct QwenBreak: Sendable {
    public var seed: UInt64
    public var sampleRate: Int
    public var samples: [Float]
    public var parts: [QwenBreakPart]
}

@available(iOS 18.0, macOS 15.0, *)
extension QwenTalkSession {
    /// Splits `text` (`QwenReadRules.split`) and renders it as one break. See `renderBreak(parts:…)`.
    public func renderBreak(_ text: String, maxPartChars: Int = QwenReadRules.defaultMaxPartChars,
                            gapSeconds: Double = 0.15, firstChunkFrames: [Int]? = nil,
                            cancelled: () -> Bool = { false }, pace: () -> Void = {},
                            onAudio: (([Float]) -> Void)? = nil,
                            onPart: ((QwenBreakPart) -> Void)? = nil) throws -> QwenBreak {
        try renderBreak(parts: QwenReadRules.split(text, maxPartChars: maxPartChars), gapSeconds: gapSeconds,
                        firstChunkFrames: firstChunkFrames, cancelled: cancelled, pace: pace,
                        onAudio: onAudio, onPart: onPart)
    }

    /// Renders `parts` in order through this session (one sampler stream, each part continuing the one
    /// before it, a derailed take redrawn unless streaming) with `gapSeconds` of silence between parts.
    /// With `onAudio` the audio (gaps included) goes there as it is made and `QwenBreak.samples` is empty;
    /// `firstChunkFrames` is the first part's vocoder chunk schedule. Stops between parts once `cancelled`.
    public func renderBreak(parts: [String], gapSeconds: Double = 0.15, firstChunkFrames: [Int]? = nil,
                            cancelled: () -> Bool = { false }, pace: () -> Void = {},
                            onAudio: (([Float]) -> Void)? = nil,
                            onPart: ((QwenBreakPart) -> Void)? = nil) throws -> QwenBreak {
        var out = QwenBreak(seed: seed, sampleRate: sampleRate, samples: [], parts: [])
        for (i, part) in parts.enumerated() {
            if cancelled() { break }
            let stop = try renderPart(i, part, into: &out, gapSeconds: gapSeconds, firstChunkFrames: firstChunkFrames,
                                      cancelled: cancelled, pace: pace, onAudio: onAudio, onPart: onPart)
            if stop { break }
        }
        return out
    }

    /// `renderBreak(parts:…)` with a hook between parts: `beforePart(i)` runs (awaited) before every part after
    /// the first, while this session holds no engine lock. A caller that serialises renders hands the engine to
    /// an urgent line there (an iPhone "Hey DJ" reply waited 25 s behind a four-part news break, 2026-10-08) and
    /// resumes this break after it; the session's own stream (carry, sampler) is untouched in between.
    public func renderBreak(parts: [String], gapSeconds: Double = 0.15, firstChunkFrames: [Int]? = nil,
                            cancelled: () -> Bool = { false }, pace: () -> Void = {},
                            onAudio: (([Float]) -> Void)? = nil,
                            onPart: ((QwenBreakPart) -> Void)? = nil,
                            beforePart: (Int) async throws -> Void) async throws -> QwenBreak {
        var out = QwenBreak(seed: seed, sampleRate: sampleRate, samples: [], parts: [])
        for (i, part) in parts.enumerated() {
            if i > 0 { try await beforePart(i) }
            if cancelled() { break }
            let stop = try renderPart(i, part, into: &out, gapSeconds: gapSeconds, firstChunkFrames: firstChunkFrames,
                                      cancelled: cancelled, pace: pace, onAudio: onAudio, onPart: onPart)
            if stop { break }
        }
        return out
    }

    /// One part of a break into `out` (its leading gap, its audio, its report). True = stop the break.
    private func renderPart(_ i: Int, _ part: String, into out: inout QwenBreak, gapSeconds: Double,
                            firstChunkFrames: [Int]?, cancelled: () -> Bool, pace: () -> Void,
                            onAudio: (([Float]) -> Void)?, onPart: ((QwenBreakPart) -> Void)?) throws -> Bool {
        let gap = [Float](repeating: 0, count: Int((gapSeconds * Double(sampleRate)).rounded()))
        if i > 0 { if let onAudio { onAudio(gap) } else { out.samples += gap } }
        let t0 = ProcessInfo.processInfo.systemUptime
        let r = try render(part, chunkFrames: i == 0 ? firstChunkFrames : nil, cancelled: cancelled,
                           pace: pace, onAudio: onAudio)
        if onAudio == nil { out.samples += r.samples }
        let report = QwenBreakPart(index: i, text: part, frames: r.frames, takes: r.takes, stopReason: r.stopReason,
                                   contextFrames: r.contextFrames, longestPause: r.silenceBefore.longestPause,
                                   derailed: Self.derailed(r), audioSeconds: r.audioSeconds,
                                   renderSeconds: (ProcessInfo.processInfo.systemUptime - t0), frameCap: r.frameCap,
                                   timings: r.timings, generatedFrames: r.generatedFrames)
        out.parts.append(report)
        onPart?(report)
        return r.stopReason == .cancelled
    }
}
