// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import QwenANE
import OSLog

/// All Core ML work stays off the main actor. A single actor serializes the
/// stateful engine; only one voice representation is kept in memory.
actor QwenSpeech {
    static let sampleRate: Double = 24_000
    static let languages = ["es-ES", "en-US", "fr-FR", "de-DE", "zh-CN", "ja-JP", "ko-KR", "it-IT", "pt-PT", "ru-RU"]
    static let clonePrefix = "qwen-clone:"
    private let engine: QwenANEEngine
    private let directory: URL
    private var preparedVoiceID: String?
    private var preparedVoice: QwenVoiceFiles?
    private static let loadQueue = DispatchQueue(label: "ai.nodus.reader.qwen-load", qos: .userInitiated)

    private init(directory: URL, cancelled: () -> Bool) throws {
        self.directory = directory
        engine = try QwenANEEngine(modelsDirectory: directory, cancelled: cancelled)
    }

    static func load(directory: URL) async throws -> QwenSpeech {
        let cancellation = QwenLoadCancellation()
        let work = Task<QwenSpeech, Error> {
            try await withCheckedThrowingContinuation { continuation in
                // A serial dispatch queue bounds compilation without blocking Swift's cooperative
                // executor with a lock when several rapid model changes arrive together.
                loadQueue.async {
                    do {
                        if cancellation.isCancelled { throw CancellationError() }
                        let loaded = try QwenSpeech(directory: directory, cancelled: { cancellation.isCancelled })
                        if cancellation.isCancelled { throw CancellationError() }
                        continuation.resume(returning: loaded)
                    } catch { continuation.resume(throwing: error) }
                }
            }
        }
        return try await withTaskCancellationHandler {
            try await CancellableTaskValue.value(of: work)
        } onCancel: { cancellation.cancel(); work.cancel() }
    }

    func synthesize(_ text: String, referenceID: String, language: String) async throws -> NarrationSynthesis {
        try Task.checkCancellation()
        let voice: QwenVoiceFiles
        if preparedVoiceID == referenceID, let preparedVoice {
            voice = preparedVoice
            Logger(subsystem: "ai.nodus.reader", category: "QwenQuality").debug("reference_reused voice=\(referenceID, privacy: .private)")
        } else {
            let preparationStart = ProcessInfo.processInfo.systemUptime
            Logger(subsystem: "ai.nodus.reader", category: "QwenQuality").info("reference_prepare_begin voice=\(referenceID, privacy: .private)")
            guard let recording = StudioVoiceStore.voice(id: referenceID),
                  let url = StudioVoiceStore.referenceURL(for: recording) else {
                throw StudioVoiceStore.StoreError.unreadableAudio
            }
            let cache = QwenModels.voiceCache.appendingPathComponent(QwenModels.revision)
                .appendingPathComponent(referenceID, isDirectory: true)
            voice = try QwenVoicePrep.prepared(referenceWAV: Data(contentsOf: url), transcript: recording.transcript,
                                               cacheDirectory: cache, modelsDirectory: directory)
            ModelManager.excludeQwenFromBackup(QwenModels.voiceCache)
            preparedVoice = voice
            preparedVoiceID = referenceID
            Logger(subsystem: "ai.nodus.reader", category: "QwenQuality").info("reference_ready seconds=\(ProcessInfo.processInfo.systemUptime - preparationStart)")
        }
        try Task.checkCancellation()
        let parts = QwenReadRules.split(text, maxPartChars: 160)
        let baseSeed = QwenTalkSession.stableSeed(referenceID + language + text)
        var samples: [Float] = []
        var heard: [SpeechWordAligner.RecognizedWord] = []
        var verified = true
        var session = QwenTalkSession(engine: engine, voice: voice, language: language, seed: baseSeed)
        for (index, part) in parts.enumerated() {
            var accepted = false
            for attempt in 0..<3 {
                try Task.checkCancellation()
                let seed = attempt == 0 ? session.seed : baseSeed &+ UInt64(index * 3 + attempt)
                if attempt > 0 {
                    session = QwenTalkSession(engine: engine, voice: voice, language: language, seed: seed)
                }
                session.maxRedraws = 0 // This loop owns the entire three-take budget.
                let start = ProcessInfo.processInfo.systemUptime
                let result = try session.render(part, cancelled: { Task.isCancelled })
                try Task.checkCancellation()
                let basicValid = !QwenTalkSession.derailed(result) && SpeechQuality.accepts(samples: result.samples, text: part, recognized: nil)
                let recognition = basicValid
                    ? await SpeechWordAligner.inspect(samples: result.samples, sampleRate: Self.sampleRate, language: language) : nil
                let valid = basicValid && SpeechQuality.accepts(samples: result.samples,
                    text: part, recognized: recognition, language: language)
                Logger(subsystem: "ai.nodus.reader", category: "QwenQuality").info("part=\(index) take=\(attempt + 1) seed=\(seed) voice=\(referenceID, privacy: .private) stop=\(String(describing: result.stopReason)) pause=\(result.silenceBefore.longestPause) seconds=\(ProcessInfo.processInfo.systemUptime - start) valid=\(valid) verified=\(recognition != nil)")
                guard valid else { continue }
                if index > 0 { samples += [Float](repeating: 0, count: 3600) }
                let offset = Double(samples.count) / Self.sampleRate
                if let recognition {
                    heard += recognition.map { .init(text: $0.text, start: $0.start + offset, end: $0.end + offset) }
                } else { verified = false }
                samples += result.samples
                accepted = true
                break
            }
            guard accepted else { throw QwenSpeechError.incompleteSpeech }
        }
        try Task.checkCancellation()
        guard !samples.isEmpty else { throw QwenSpeechError.incompleteSpeech }
        let words = verified ? SpeechWordAligner.place(words: AudioWordAligner.words(in: text), recognized: heard,
                                                       duration: Double(samples.count) / Self.sampleRate) : nil
        return NarrationSynthesis(samples: samples, sampleRate: Self.sampleRate, words: words, checkedWords: true, verification: verified ? .valid : .unavailable)

    }
}

private final class QwenLoadCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
}

extension ModelManager {
    /// Reference recordings are prepared once, cached locally and never synced.
    nonisolated static func excludeQwenFromBackup(_ url: URL) {
        var folder = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? folder.setResourceValues(values)
    }

    static var qwenModel: Model {
        Model(id: QwenModels.id, engine: .qwen, name: "Qwen3-TTS 0.6B",
              detail: String(localized: "Experimental narration in ten languages, with voices you create from a short recording."),
              language: String(localized: "Multilingual"), sizeText: String(localized: "About 2.1 GB download"),
              license: "Apache-2.0", source: URL(string: "https://huggingface.co/\(QwenModels.repository)")!,
              voices: QwenSpeech.languages.map { language in
                  Voice(id: "qwen:\(language)", name: "Dave", language: language, engine: .qwen, gender: .male)
              }, availability: {
                  #if targetEnvironment(simulator)
                  .unavailable(String(localized: "Qwen needs a real iPhone, iPad or Mac with a Neural Engine."))
                  #else
                  .available
                  #endif
              }(), installNote: String(localized: "Includes on-device voice creation. The first model load can take over a minute. On iPhone, use Generate for this book in Offline audio before listening to avoid pauses. Generation speed and memory use depend on your device."))
    }

    static func qwenVoice(from clone: StudioVoiceStore.ClonedVoice) -> Voice {
        Voice(id: QwenSpeech.clonePrefix + clone.id, name: clone.name, language: clone.language, engine: .qwen)
    }
}
