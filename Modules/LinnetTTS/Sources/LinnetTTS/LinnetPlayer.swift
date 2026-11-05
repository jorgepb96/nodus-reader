import AVFoundation
import Foundation

/// Minimal streaming playback helper: an `AVAudioEngine` with one `AVAudioPlayerNode` that
/// accepts the chunks of a ``LinnetSession`` as they are produced.
///
/// Usage, on a background queue:
/// ```swift
/// let session = try model.session(voice: voice)
/// let player = try LinnetPlayer(sampleRate: model.sampleRate)
/// try session.prime(text: text)
/// while let chunk = try session.step() { try player.write(chunk) }
/// player.drain()
/// ```
/// ``write(_:)`` blocks while more than `bufferMillis` of audio is queued. The default keeps 8 s ahead,
/// so a typical utterance is synthesised in one burst at full speed and playback drains behind it. Do not
/// pace synthesis to real time with a small buffer: a thread that sleeps 70 ms of every 80 ms is clocked
/// down and moved to efficiency cores by iOS, and each step then takes 3-4 times longer (measured 22 ms
/// instead of 6.7 ms on an A13). The player is not thread-safe; use it from the thread that drives the
/// session (``stop()`` may be called from any thread).
///
/// - Parameters:
///   - sampleRate: output rate, ``LinnetModel/sampleRate``.
///   - bufferMillis: audio kept queued ahead of playback (default 8000). Smaller values only make
///     ``stop()`` drop less audio; they do not reduce latency to the first chunk.
public final class LinnetPlayer {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let format: AVAudioFormat
    private let sampleRate: Int
    private let maxQueuedSamples: Int
    private let lock = NSCondition()
    private var queuedSamples = 0
    private var generation = 0
    private var started = false

    public init(sampleRate: Int, bufferMillis: Int = 8000) throws {
        guard let f = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate), channels: 1,
                                    interleaved: false)
        else { throw LinnetError.invalidArgument("unsupported sample rate \(sampleRate)") }
        format = f
        self.sampleRate = sampleRate
        maxQueuedSamples = max(1, bufferMillis) * sampleRate / 1000
        #if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio)
            try session.setActive(true)
        #endif
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
    }

    /// Queue `chunk` (blocking while the queue is full). Playback starts on the first call.
    public func write(_ chunk: [Float]) throws {
        if chunk.isEmpty { return }
        if !started {
            try engine.start()
            node.play()
            started = true
        }
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chunk.count)) else {
            throw LinnetError.internalError("AVAudioPCMBuffer allocation failed")
        }
        buf.frameLength = AVAudioFrameCount(chunk.count)
        chunk.withUnsafeBufferPointer { src in
            buf.floatChannelData![0].update(from: src.baseAddress!, count: chunk.count)
        }
        lock.lock()
        while started, queuedSamples > 0, queuedSamples + chunk.count > maxQueuedSamples {
            lock.wait()
        }
        if !started {  // stopped while waiting: drop the chunk
            lock.unlock()
            return
        }
        let myGeneration = generation
        queuedSamples += chunk.count
        lock.unlock()
        node.scheduleBuffer(buf, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            guard let self else { return }
            self.lock.lock()
            if self.generation == myGeneration {
                self.queuedSamples = max(0, self.queuedSamples - chunk.count)
                self.lock.broadcast()
            }
            self.lock.unlock()
        }
    }

    /// Block until everything queued so far has been played, then stop the node.
    public func drain() {
        lock.lock()
        let deadline = Date(timeIntervalSinceNow: Double(queuedSamples) / Double(sampleRate) + 1.0)
        while started, queuedSamples > 0, lock.wait(until: deadline) {}
        lock.unlock()
        stop()
    }

    /// Drop whatever is queued and stop immediately. May be called from any thread.
    public func stop() {
        lock.lock()
        generation += 1
        queuedSamples = 0
        let wasStarted = started
        started = false
        lock.broadcast()
        lock.unlock()
        if wasStarted {
            node.stop()
            engine.stop()
        }
    }

    deinit {
        stop()
    }
}
