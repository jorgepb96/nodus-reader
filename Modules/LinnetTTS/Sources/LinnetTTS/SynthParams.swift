import CLinnetTTS

/// Sampling parameters of one utterance (same defaults as the C, Python and Kotlin APIs).
public struct SynthParams: Equatable, Sendable {
    /// Variance of the flow start noise; 0 is deterministic.
    public var temp: Float
    /// Classifier-free guidance weight; 1 disables the unconditional stream (faster).
    public var cfg: Float
    /// Upper bound on LM steps (80 ms each); 300 = 24 s.
    public var maxFrames: Int
    /// Stop when the end-of-speech logit exceeds this value.
    public var eosThreshold: Float
    /// Seed of the noise generator; the same seed gives the same audio.
    public var seed: UInt64
    /// Threads the model uses while this utterance runs: 1 = single-threaded, 0 = automatic
    /// (one thread on iOS/macOS, where a second core does not pay off). Applied to the model when the session is created
    /// (`LinnetModel.threads`). The audio is identical for every value.
    public var threads: Int

    public init(
        temp: Float = 0.3,
        cfg: Float = 2.0,
        maxFrames: Int = 300,
        eosThreshold: Float = -1.0,
        seed: UInt64 = 0,
        threads: Int = 0
    ) {
        precondition(maxFrames >= 1, "maxFrames must be >= 1")
        precondition(threads >= 0, "threads must be >= 0")
        precondition(temp >= 0 && temp.isFinite, "temp must be finite and >= 0")
        precondition(cfg.isFinite, "cfg must be finite")
        self.temp = temp
        self.cfg = cfg
        self.maxFrames = maxFrames
        self.eosThreshold = eosThreshold
        self.seed = seed
        self.threads = threads
    }

    var cParams: linnet_params {
        linnet_params(temp: temp, cfg: cfg, eos_threshold: eosThreshold, max_frames: UInt32(maxFrames), seed: seed)
    }
}
