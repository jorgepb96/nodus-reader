import CLinnetTTS
import Foundation

/// Loaded weights and tokenizer.
///
/// The model is immutable apart from ``threads`` and may be shared by any number of threads
/// and sessions. A session holds a strong reference to its model, so the weights live as long
/// as any session does. Loading takes a few hundred milliseconds; keep it and the synthesis
/// calls off the main thread.
///
/// Audio is mono Float32 at ``sampleRate`` (24 kHz), in `[-1, 1]`.
public final class LinnetModel: @unchecked Sendable {
    let handle: OpaquePointer

    /// Output sample rate in Hz (24000).
    public let sampleRate: Int
    /// Samples produced per LM step (two codec frames, 1920 = 80 ms). Largest chunk a session returns.
    public let samplesPerStep: Int
    /// Delay compensated by a streaming session, in samples (720): the first chunk is this much
    /// shorter and the final chunk is this many zeros (see `docs/streaming-contract.md`).
    public let outputDelay = 720
    /// Width of one LM latent and of a voice row (48).
    public let latentDim = 48

    /// Load `weightsPath` (safetensors, fp16 or fp32) and `tokenizerPath` (SentencePiece `.model`).
    public init(weightsPath: String, tokenizerPath: String) throws {
        var h: OpaquePointer?
        try check(linnet_model_load(weightsPath, tokenizerPath, &h))
        guard let h else { throw LinnetError.internalError("model handle is null") }
        handle = h
        sampleRate = Int(linnet_sample_rate(h))
        samplesPerStep = Int(linnet_samples_per_step(h))
    }

    public convenience init(weightsURL: URL, tokenizerURL: URL) throws {
        try self.init(weightsPath: weightsURL.path, tokenizerPath: tokenizerURL.path)
    }

    deinit {
        linnet_model_free(handle)
    }

    /// Version of the native runtime.
    public static var version: String { String(cString: linnet_version()) }

    /// Threads the model uses: set 1 for single-threaded, 0 for automatic (one thread on
    /// iOS/macOS, where a second core does not pay off); the getter returns the resolved count. The audio is identical for
    /// every value; only the speed changes. Applies to existing and future sessions; change it
    /// between utterances, not while a session steps.
    public var threads: Int {
        get { Int(linnet_threads(handle)) }
        set {
            precondition(newValue >= 0, "threads must be >= 0")
            _ = linnet_set_threads(handle, Int32(newValue))
        }
    }

    /// Load `[T, 48]` latents from a NumPy `.npy` file.
    public func loadVoice(path: String) throws -> Voice {
        let v = try Voice.load(path: path)
        if v.dim != latentDim {
            throw LinnetError.invalidArgument("voice latents have width \(v.dim), the model expects \(latentDim)")
        }
        return v
    }

    public func loadVoice(url: URL) throws -> Voice { try loadVoice(path: url.path) }

    /// Whole utterance in one call. Blocks for the full synthesis; the result is
    /// `steps * samplesPerStep` samples and equals the concatenation of the chunks a
    /// ``LinnetSession`` with the same `params` produces.
    public func synthesize(text: String, voice: Voice, params: SynthParams = SynthParams()) throws -> [Float] {
        threads = params.threads
        var p = params.cParams
        var cap = params.maxFrames * samplesPerStep
        while true {
            var out = [Float](repeating: 0, count: cap)
            var written = 0
            let rc = out.withUnsafeMutableBufferPointer { buf in
                linnet_synthesize(handle, voice.handle, text, &p, buf.baseAddress, buf.count, &written)
            }
            withExtendedLifetime(voice) {}
            if rc == LinnetError.bufferTooSmall("").code, written > cap {
                cap = written
                continue
            }
            try check(rc)
            out.removeSubrange(written...)
            return out
        }
    }

    /// Streaming session bound to `voice`. Call ``LinnetSession/prime(text:)`` before stepping.
    public func session(voice: Voice, params: SynthParams = SynthParams()) throws -> LinnetSession {
        threads = params.threads
        var p = params.cParams
        var h: OpaquePointer?
        try check(linnet_session_new(handle, voice.handle, &p, &h))
        guard let h else { throw LinnetError.internalError("session handle is null") }
        return LinnetSession(handle: h, model: self, voice: voice)
    }
}
