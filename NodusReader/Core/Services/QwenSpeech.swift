// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import QwenANE

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

    private init(directory: URL) throws {
        self.directory = directory
        engine = try QwenANEEngine(modelsDirectory: directory)
    }

    static func load(directory: URL) async throws -> QwenSpeech {
        let work = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let loaded = try QwenSpeech(directory: directory)
            try Task.checkCancellation()
            return loaded
        }
        return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }

    func synthesize(_ text: String, referenceID: String, language: String) throws -> [Float] {
        try Task.checkCancellation()
        let voice: QwenVoiceFiles
        if preparedVoiceID == referenceID, let preparedVoice {
            voice = preparedVoice
        } else {
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
        }
        try Task.checkCancellation()
        let session = QwenTalkSession(engine: engine, voice: voice, language: language, seedText: text)
        let result = try session.renderBreak(text, cancelled: { Task.isCancelled })
        try Task.checkCancellation()
        guard !result.samples.isEmpty, result.samples.allSatisfy(\.isFinite),
              result.samples.contains(where: { abs($0) > 0.001 }),
              !result.parts.isEmpty, result.parts.allSatisfy({ !$0.derailed }) else {
            throw QwenSpeechError.incompleteSpeech
        }
        return result.samples
    }
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
