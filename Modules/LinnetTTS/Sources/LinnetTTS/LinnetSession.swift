import CLinnetTTS
import Foundation

/// One utterance in progress: streaming synthesis one LM step (80 ms) at a time.
///
/// Not thread-safe: drive a session from one thread at a time (typically a dedicated synthesis
/// queue that feeds a ``LinnetPlayer``). Different sessions of the same model may run on
/// different threads concurrently. The session keeps the model alive until it is released, and
/// holds KV caches sized by `maxFrames` (about 20 MB with the defaults, half without guidance).
///
/// Chunk layout (see `docs/streaming-contract.md`): the first chunk is
/// `samplesPerStep - outputDelay` samples (1200), later ones `samplesPerStep` (1920), the last
/// one `outputDelay` (720) zeros; concatenated they equal ``LinnetModel/synthesize(text:voice:params:)``
/// with the same parameters sample for sample.
public final class LinnetSession {
    let handle: OpaquePointer
    /// The model this session runs on (kept alive by the session).
    public let model: LinnetModel
    let voice: Voice
    /// Largest chunk ``step()`` returns.
    public let samplesPerStep: Int
    /// True once ``step()`` has returned `nil` (the Rust, Python and Kotlin APIs set their flag one call
    /// earlier, when the final zero chunk is returned). Reset by ``prime(text:)``.
    public private(set) var finished = false
    /// Chunks returned so far for the current text (including the final zero chunk).
    public private(set) var chunksEmitted = 0
    private var buffer: [Float]

    init(handle: OpaquePointer, model: LinnetModel, voice: Voice) {
        self.handle = handle
        self.model = model
        self.voice = voice
        samplesPerStep = model.samplesPerStep
        buffer = [Float](repeating: 0, count: model.samplesPerStep)
    }

    deinit {
        linnet_session_free(handle)
    }

    /// Tokenize `text` and run the prefix. Resets any previous utterance; may be called again for a new text.
    public func prime(text: String) throws {
        try check(linnet_session_prime(handle, text))
        finished = false
        chunksEmitted = 0
    }

    /// Next chunk of 24 kHz Float32 audio, or `nil` once the utterance is over (after the final
    /// zero chunk). Allocation-free alternative: ``step(into:)``.
    public func step() throws -> [Float]? {
        let n = try buffer.withUnsafeMutableBufferPointer { try stepInto($0) }
        if n == 0 { return nil }
        return Array(buffer[0..<n])
    }

    /// Next chunk into `out` (`out.count >= samplesPerStep`). Returns the number of samples
    /// written, 0 when the utterance is over.
    public func step(into out: UnsafeMutableBufferPointer<Float>) throws -> Int {
        guard out.count >= samplesPerStep else {
            throw LinnetError.invalidArgument("out must hold at least \(samplesPerStep) samples")
        }
        return try stepInto(out)
    }

    private func stepInto(_ out: UnsafeMutableBufferPointer<Float>) throws -> Int {
        var written = 0
        try check(linnet_session_step(handle, out.baseAddress, out.count, &written))
        if written == 0 {
            finished = true
        } else {
            chunksEmitted += 1
        }
        return written
    }

    /// Drain the remaining chunks into one array (the offline result for the primed text).
    public func remaining() throws -> [Float] {
        var all: [Float] = []
        while let c = try step() { all.append(contentsOf: c) }
        return all
    }
}
