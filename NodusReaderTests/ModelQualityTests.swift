// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Testing
@testable import Nodus_Reader

@Suite struct ModelQualityTests {
    @Test @MainActor func voiceFiltersCombineAlternativesAndKeepDimensionsIndependent() {
        let spanish = VoiceCatalog.Voice(id: "es", name: "Spanish", language: "es-MX", languageName: "Spanish", quality: 1,
                                         gender: .female, engineRaw: "kokoro", modelID: "kokoro")
        var english = spanish
        english.id = "en"
        english.language = "en-GB"
        english.modelID = "phonon"
        var french = english
        french.language = "fr-FR"
        var otherModel = spanish
        otherModel.modelID = "other"
        var male = english
        male.gender = .male
        let filters = VoiceFilterSelection(models: ["kokoro", "phonon"], languages: ["es", "en"], genders: ["female"])
        #expect(filters.matches(spanish))
        #expect(filters.matches(english))
        #expect(!filters.matches(french))
        #expect(!filters.matches(otherModel))
        #expect(!filters.matches(male))
        male.gender = nil
        #expect(!filters.matches(male))
        #expect(VoiceFilterSelection(genders: [VoiceFilterSelection.unspecifiedGender]).matches(male))
        #expect(VoiceFilterSelection().matches(french))
    }

    @Test func voiceFilterPersistenceDistinguishesExplicitAllFromNoPreference() throws {
        let selection = VoiceFilterSelection(models: ["kokoro", "phonon"], languages: ["es", "en"], genders: ["male", "female"])
        #expect(VoiceFilterSelection.decode(try #require(selection.encoded)) == selection)
        let all = VoiceFilterSelection()
        #expect(VoiceFilterSelection.decode(try #require(all.encoded)) == all)
        #expect(!all.isActive)
        #expect(VoiceFilterSelection.decode("") == nil)
        #expect(VoiceFilterSelection.decode("invalid") == nil)
    }

    @Test func speechQualityDistinguishesUnavailableFromEmptyRecognition() {
        let signal = (0..<2400).map { Float(sin(Double($0) * 0.1) * 0.2) }
        #expect(SpeechQuality.accepts(samples: signal, text: "Hello world", recognized: nil))
        #expect(!SpeechQuality.accepts(samples: signal, text: "Hello world", recognized: []))
        #expect(!SpeechQuality.accepts(samples: signal, text: "Hello world", recognized: [.init(text: "unrelated", start: 0, end: 0.1)]))
        let recognized = ["Hello", "world"].map { SpeechWordAligner.RecognizedWord(text: $0, start: 0, end: 0.1) }
        #expect(SpeechQuality.accepts(samples: signal, text: "Hello world", recognized: recognized))
        let decimal = ["nineteen", "point", "five"].map { SpeechWordAligner.RecognizedWord(text: $0, start: 0, end: 0.1) }
        #expect(SpeechQuality.accepts(samples: signal, text: "19.5", recognized: decimal))
        let chinese = ["你", "好", "世", "界"].map { SpeechWordAligner.RecognizedWord(text: $0, start: 0, end: 0.1) }
        #expect(SpeechQuality.accepts(samples: signal, text: "你好世界", recognized: chinese, language: "zh-CN"))
        #expect(!SpeechQuality.accepts(samples: [Float](repeating: 0, count: 2400), text: "Hello", recognized: nil))
        #expect(!SpeechQuality.accepts(samples: [Float](repeating: .nan, count: 2400), text: "Hello", recognized: nil))
    }

    @Test func speedBarsHaveDefinedBoundaries() {
        #expect([0.9, 1, 2, 4, 8].map(ModelPerformance.bars) == [1, 2, 3, 4, 5])
    }

    @Test @MainActor func measuredSpeedRequiresEnoughRealAudio() {
        let suite = "model-tests-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ModelPerformance(defaults: defaults)
        let model = ModelManager.qwenModel
        #expect(!store.speed(model).measured)
        store.record(model: model, seconds: 5, audio: 10)
        store.record(model: model, seconds: 5, audio: 10)
        #expect(!store.speed(model).measured)
        store.record(model: model, seconds: 5, audio: 10)
        #expect(store.speed(model).measured)
        #expect(store.speed(model).value == 2)
        #expect(ModelPerformance(defaults: defaults).speed(model).measured)
        #expect(ModelManager.macOnlyModels.first?.metadata.languages.count ?? 7 == 7)
        let manager = ModelManager(voices: VoiceCatalog(defaults: defaults), defaults: defaults, discoverSystemVoices: false)
        #expect(manager.model(forVoiceID: "linnet:linnet-en-f1")?.model.id == LinnetModels.id)
        #expect(manager.model(forVoiceID: "linnet:linnet-en-m1")?.name == "linnet-en-m1")
        #expect(manager.model(forVoiceID: "linnet:custom") == nil)
    }

    @Test func qwenQualityInvalidatesBothCacheKeyVariants() {
        let cache = NarrationAudioCache(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        for pronunciation in ["", "rule"] {
            let key = cache.key(text: "Hello", engine: "qwen", voice: "Dave", pronunciation: pronunciation)
            #expect(key == cache.key(text: "Hello", engine: "qwen-quality-v2", voice: "Dave", pronunciation: pronunciation))
            #expect(key != cache.key(text: "Hello", engine: "qwen-quality-v1", voice: "Dave", pronunciation: pronunciation))
        }
    }

    @Test func linnetNormalizesNumbersAndProjectsHighlight() {
        let original = "Pay $19.99 at 9:30 for 24 books."
        let prepared = PronunciationTransformer.prepare(original, rules: LinnetText.rules(original))
        #expect(!prepared.spoken.contains("19.99"))
        #expect(prepared.spoken.contains("dollars"))
        #expect(prepared.spoken.contains("twenty-four"))
        let words = AudioWordAligner.words(in: prepared.spoken).enumerated().map { index, word in
            NarrationWordTiming(location: word.range.location, length: word.range.length, start: Double(index), end: Double(index + 1))
        }
        #expect(prepared.project(words).allSatisfy { $0.location + $0.length <= (original as NSString).length })
        #expect(LinnetModels.manifest?.files.count == 6)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["NODUS_LINNET_ASSETS"] != nil))
    func linnetRealSynthesisBothVoices() async throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["NODUS_LINNET_ASSETS"]!)
        let engine = try LinnetSpeech(directory: root)
        for voice in ["linnet-en-f1", "linnet-en-m1"] {
            let audio = try await engine.synthesize("Good morning. There are 24 books, and the total is $19.99.", voice: voice)
            #expect(audio.samples.count > 24_000)
            #expect(audio.samples.allSatisfy { $0.isFinite })
            #expect(audio.samples.contains { abs($0) > 0.01 })
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["NODUS_QWEN_ASSETS"] != nil))
    func qwenRealQualityWrapper() async throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["NODUS_QWEN_ASSETS"]!)
        let engine = try await QwenSpeech.load(directory: root)
        let audio = try await engine.synthesize("Esta es una prueba de lectura en voz alta.", referenceID: "es-dave", language: "es-ES")
        #expect(audio.samples.count > 24_000)
        #expect(audio.checkedWords)
        #expect(audio.verification != .defective)
    }
}
