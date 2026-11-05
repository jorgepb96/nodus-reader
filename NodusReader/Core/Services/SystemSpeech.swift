// SPDX-License-Identifier: AGPL-3.0-only
#if os(iOS)
import AVFoundation
import Foundation

/// One writer at a time; playback, previews and offline generation share the synthesis gate.
@MainActor
final class SystemSpeech {
    static let shared = SystemSpeech()
    private let synthesizer = AVSpeechSynthesizer()
    private var continuation: CheckedContinuation<NarrationSynthesis, Error>?
    private var generation = UUID()
    private var samples: [Float] = []
    private var words: [NarrationWordTiming] = []
    private var bufferStart: Double = 0
    private var sourceRate: Double = 24_000
    private var sourceBytesPerFrame: Double = 4
    private var watchdog: Task<Void, Never>?

    func cancel() {
        generation = UUID()
        watchdog?.cancel(); watchdog = nil
        synthesizer.stopSpeaking(at: .immediate)
        let pending = continuation; continuation = nil
        pending?.resume(throwing: CancellationError())
    }

    func synthesize(_ text: String, voiceID: String) async throws -> NarrationSynthesis {
        try Task.checkCancellation()
        cancel()
        guard let voice = AVSpeechSynthesisVoice(identifier: voiceID) else {
            throw NeuralNarrationError.engineNotLoaded(String(localized: "iOS voices"))
        }
        let token = UUID(); generation = token
        samples = []; words = []; bufferStart = 0
        let pcmConverter = SystemPCMConverter()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { pending in
                continuation = pending
                armWatchdog(token)
                synthesizer.write(utterance, toBufferCallback: { [weak self] buffer in
                    // The callback owns this buffer only during the callback. Copy before hopping actors.
                    guard let pcm = buffer as? AVAudioPCMBuffer else { return }
                    let count = pcm.frameLength
                    let rate = pcm.format.sampleRate
                    let bytes = Double(pcm.format.streamDescription.pointee.mBytesPerFrame)
                    let conversion = Result { try pcmConverter.convert(pcm) }
                    Task { @MainActor [weak self] in
                        guard let self, self.generation == token, self.continuation != nil else { return }
                        guard case .success(let captured) = conversion else { self.fail(token); return }
                        if count == 0 { self.samples += captured; self.finish(token); return }
                        // A resampler may consume an initial short buffer without emitting samples.
                        // Empty output is priming, not an unsupported audio format.
                        self.bufferStart = Double(self.samples.count) / 24_000
                        self.sourceRate = rate; self.sourceBytesPerFrame = max(1, bytes)
                        self.samples += captured
                        self.armWatchdog(token)
                    }
                }, toMarkerCallback: { [weak self] markers in
                    let values = markers.filter { $0.mark == .word }.map { ($0.textRange, $0.byteSampleOffset) }
                    Task { @MainActor [weak self] in
                        guard let self, self.generation == token, self.continuation != nil else { return }
                        for (range, offset) in values {
                            let start = self.bufferStart + Double(offset) / self.sourceBytesPerFrame / self.sourceRate
                            self.words.append(.init(location: range.location, length: range.length, start: start, end: start))
                        }
                    }
                })
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                if self?.generation == token { self?.cancel() }
            }
        }
    }

    private func armWatchdog(_ token: UUID) {
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
            self?.fail(token)
        }
    }
    private func fail(_ token: UUID) {
        guard generation == token else { return }
        let pending = continuation; continuation = nil
        cancel()
        pending?.resume(throwing: NeuralNarrationError.invalidAudio)
    }
    private func finish(_ token: UUID) {
        guard generation == token else { return }
        guard !samples.isEmpty, samples.allSatisfy(\.isFinite), samples.contains(where: { abs($0) > 0.0001 }) else { fail(token); return }
        watchdog?.cancel(); watchdog = nil
        let duration = Double(samples.count) / 24_000
        words = words.filter { $0.start >= 0 && $0.start < duration }.sorted { $0.start < $1.start }
        for i in words.indices { words[i].end = i + 1 < words.count ? words[i + 1].start : duration }
        let result = NarrationSynthesis(samples: samples, sampleRate: 24_000, words: words.isEmpty ? nil : words, checkedWords: true)
        let pending = continuation; continuation = nil
        pending?.resume(returning: result)
    }
}
/// Keep the sample-rate converter alive across callbacks so filter history and tail samples survive.
final class SystemPCMConverter: @unchecked Sendable {
    private let lock = NSLock()
    private var converter: AVAudioConverter?
    func convert(_ pcm: AVAudioPCMBuffer) throws -> [Float] {
        lock.lock(); defer { lock.unlock() }
        if converter == nil, pcm.frameLength > 0 {
            guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000, channels: 1, interleaved: false) else { throw NeuralNarrationError.invalidAudio }
            converter = AVAudioConverter(from: pcm.format, to: format)
        }
        guard let converter, let output = AVAudioPCMBuffer(pcmFormat: converter.outputFormat,
            frameCapacity: max(4096, AVAudioFrameCount(ceil(Double(pcm.frameLength) * 24_000 / max(1, pcm.format.sampleRate))) + 64)) else { throw NeuralNarrationError.invalidAudio }
        var supplied = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if pcm.frameLength == 0 { status.pointee = .endOfStream; return nil }
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true; status.pointee = .haveData; return pcm
        }
        if let error { throw error }
        guard let data = output.floatChannelData?[0] else { throw NeuralNarrationError.invalidAudio }
        return Array(UnsafeBufferPointer(start: data, count: Int(output.frameLength)))
    }
}

#endif
