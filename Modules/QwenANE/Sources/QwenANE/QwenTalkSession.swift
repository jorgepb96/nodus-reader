import Foundation

/// One talk break spoken as one performance.
///
/// A break longer than one render (the talker's 1024-slot window holds the reference, the text and the
/// generated frames) is split into parts. Rendered as independent lines, every part restarts from the
/// reference with a fresh random seed, so delivery, pace and energy jump at every join. A session instead:
///
/// * draws every part from ONE sampler stream, seeded once per break (deterministic: the same break, voice
///   and seed give the same audio);
/// * conditions each part on the part before it: the previous part's transcript and codec frames follow the
///   reference in the ICL prompt, the way Qwen continues its reference, so part N carries on from where part
///   N-1 stopped (dropped for a part whose frame budget it would shrink);
/// * starts the vocoder on the previous part's frames, so the decoder continues what was just played.
///
/// Parts are rendered in order with `render(_:)`; the engine lock is held per part, so other renders can
/// interleave between parts.
@available(iOS 18.0, macOS 15.0, *)
public final class QwenTalkSession {
    public let engine: QwenANEEngine
    public let voice: QwenVoiceFiles
    public let language: String?
    public let seed: UInt64
    /// Condition each part on the previous one (on by default). Off renders every part from the reference
    /// alone, still from the one sampler stream.
    public var carryContext: Bool {
        get { carry.enabled }
        set { carry.enabled = newValue }
    }
    private var sampler: Sampler
    private var carry = QwenCarry<QwenContinuation>()
    /// Parts rendered so far.
    public private(set) var partsRendered = 0

    /// `seed` nil derives one from the voice and `seedText` (pass the whole break), so a break is reproducible.
    public init(engine: QwenANEEngine, voice: QwenVoiceFiles, language: String? = nil, seed: UInt64? = nil,
                seedText: String = "") {
        self.engine = engine; self.voice = voice; self.language = language
        self.seed = seed ?? Self.stableSeed(voice.refText + "\u{1F}" + (language ?? "") + "\u{1F}" + seedText)
        sampler = engine.makeSampler(seed: self.seed)
    }

    /// FNV-1a 64 of the UTF-8 bytes: stable across launches and platforms (`Hasher` is randomly seeded).
    public static func stableSeed(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in s.utf8 { h ^= UInt64(b); h = h &* 0x0000_0100_0000_01b3 }
        return h
    }

    /// Extra takes drawn for a part whose take derailed (see `derailed`). 0 turns the guard off.
    public var maxRedraws = QwenReadRules.maxRedraws

    /// A take that derailed: it ran to the frame cap without ending (`maxTokens` / `contextFull`), or it holds a
    /// silent run of more than `maxPauseSeconds` between two stretches of speech. Measured on Bad Bunny and Benson
    /// Spanish parts (360 renders, Whisper large-v3 turbo as the judge): it catches 34 of the 53 unintelligible
    /// takes and fires on 3 of the 307 intelligible ones (1 %), whose redraw only costs time.
    /// The rule itself is `QwenReadRules.derailed`, shared with the iPhone's MLX path.
    public static func derailed(_ r: QwenRender) -> Bool {
        QwenReadRules.derailed(hitFrameCap: hitFrameCap(r), longestPause: r.silenceBefore.longestPause)
    }
    public static let maxPauseSeconds = QwenReadRules.maxPauseSeconds
    static func hitFrameCap(_ r: QwenRender) -> Bool { r.stopReason == .maxTokens || r.stopReason == .contextFull }

    /// Renders the next part of the break. Same contract as `QwenANEEngine.render` (blocks, honours
    /// `cancelled` and `pace`). A take that `derailed` is drawn again, from the same sampler stream, up to
    /// `maxRedraws` times; the first clean take is kept (`QwenRender.takes` counts the draws), else the least bad.
    /// A good take costs nothing extra: the check runs after it is finished, and only a derailed take is redrawn.
    /// With `onAudio` there is no redraw (its chunks are already out), only the one take.
    public func render(_ text: String, chunkFrames: [Int]? = nil, cancelled: () -> Bool = { false },
                       pace: () -> Void = {}, onAudio: (([Float]) -> Void)? = nil) throws -> QwenRender {
        let context = carry.context
        var best: QwenRender? = nil
        var takes = 0
        while true {
            let r: QwenRender = try engine.withLock {
                try engine.renderLocked(text: text, voice: voice, sampler: &sampler, maxFrames: nil, chunkFrames: chunkFrames,
                                        language: language, continuation: context,
                                        cancelled: cancelled, pace: pace, onAudio: onAudio)
            }
            takes += 1
            if r.stopReason == .cancelled { best = r; break }
            if best == nil || Self.badness(r) < Self.badness(best!) { best = r }
            if !Self.derailed(r) || onAudio != nil || takes > maxRedraws || cancelled() { break }
        }
        var r = best!
        r.takes = takes
        partsRendered += 1
        // Never continue a derailed take: the next part starts from the reference.
        carry.partEnded(cancelled: r.stopReason == .cancelled,
                        take: QwenReadRules.carries(frames: r.frames, derailed: Self.derailed(r))
                            ? QwenContinuation(textIds: engine.transcriptIds(text), codes: r.codes) : nil)
        return r
    }

    /// Orders takes when none is clean: one that ended beats one that hit the cap, then the shorter dead air.
    static func badness(_ r: QwenRender) -> Double {
        QwenReadRules.badness(hitFrameCap: hitFrameCap(r), longestPause: r.silenceBefore.longestPause)
    }
}

@available(iOS 18.0, macOS 15.0, *)
extension QwenANEEngine {
    func transcriptIds(_ text: String) -> [Int] { VoicePrompt.transcriptIds(host, text) }
}
