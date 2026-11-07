// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Testing
#if os(iOS)
import AVFoundation
#endif
@testable import Nodus_Reader

@Suite @MainActor struct VoiceAvailabilityTests {
    func voice(_ id: String, _ engine: String = "phonon", _ gender: VoiceGender? = .female, language: String = "es-ES") -> VoiceCatalog.Voice {
        .init(id: id, name: id, language: language, languageName: language, quality: 1, gender: gender, engineRaw: engine)
    }
    @Test func replacementOrderAndRegionalTieBreak() {
        let a = voice("download-male", "phonon", .male)
        let b = voice("system-female", "system")
        #expect(VoiceCatalog.replacement(in: [b, a], language: "es-ES", gender: .female, defaultID: b.id)?.id == a.id)
        let c = voice("download-female")
        #expect(VoiceCatalog.replacement(in: [a, b, c], language: "es-ES", gender: .female, defaultID: a.id)?.id == c.id)
        let regional = voice("mexican", language: "es-MX")
        #expect(VoiceCatalog.replacement(in: [regional, c], language: "es-MX", gender: nil, defaultID: c.id)?.id == regional.id)
        #expect(VoiceCatalog.replacement(in: [a,b,c], language: "ja-JP", gender: nil, defaultID: a.id) == nil)
    }
    /// No voice chosen for the book: the book's language decides. The default voice
    /// reads it when it speaks that language; a voice saved for another situation never
    /// reads a Spanish book in English.
    @Test func bookWithoutItsOwnVoiceFollowsItsLanguage() {
        let suite = "voice-language-\(UUID())"; let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let catalog = VoiceCatalog(defaults: defaults)
        let english = voice("fred", language: "en-US")
        let spanish = voice("monica", language: "es-ES")
        catalog.setNeuralVoices([english, spanish])
        catalog.defaultVoiceID = english.id
        let book = Book(title: "Quijote", author: "", format: .txt, language: "es", fileName: "q.txt",
                        relativePath: "q.txt", fileSize: 0, contentHash: "q")
        let resolver = VoiceSelectionResolver(defaults: defaults)
        #expect(resolver.resolve(book: book, catalog: catalog, commit: true)?.id == spanish.id)
        #expect(catalog.narrationVoice(preferredID: nil, language: book.language)?.id == spanish.id)
        // An English book keeps the default voice.
        let novel = Book(title: "Dracula", author: "", format: .txt, language: "en", fileName: "d.txt",
                         relativePath: "d.txt", fileSize: 0, contentHash: "d")
        #expect(resolver.resolve(book: novel, catalog: catalog, commit: false)?.id == english.id)
        #expect(catalog.narrationVoice(preferredID: nil, language: novel.language)?.id == english.id)
    }

    @Test func localReplacementSurvivesRestartAndDoesNotRestoreOriginal() {
        let suite = "voice-fallback-\(UUID())"; let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let catalog = VoiceCatalog(defaults: defaults)
        let substitute = voice("replacement")
        catalog.setNeuralVoices([substitute])
        let book = Book(title: "Test", author: "", format: .txt, language: "es", fileName: "test.txt", relativePath: "test.txt", fileSize: 0, contentHash: "test")
        book.preferredVoiceID = "missing"
        let resolver = VoiceSelectionResolver(defaults: defaults)
        #expect(resolver.resolve(book: book, catalog: catalog, commit: true)?.id == substitute.id)
        #expect(book.preferredVoiceID == "missing")
        let restored = voice("missing")
        catalog.setNeuralVoices([restored, substitute])
        #expect(VoiceSelectionResolver(defaults: defaults).resolve(book: book, catalog: catalog, commit: false)?.id == substitute.id)
        book.preferredVoiceID = restored.id
        book.preferredVoiceSnapshotJSON = String(data: try! JSONEncoder().encode(VoiceSelectionSnapshot.capture(restored.id, voice: restored)), encoding: .utf8)!
        #expect(resolver.resolve(book: book, catalog: catalog, commit: false)?.id == restored.id)
    }
    @Test func platformPolicy() {
        #if os(iOS)
        #expect(!ModelManager.Engine.qwen.isEnabled)
        #expect(ModelManager.Engine.system.isEnabled)
        #expect(!ModelManager.qwenModel.isAvailable)
        #expect(!VoicesMode.available.contains(.studio))
        #else
        #expect(ModelManager.Engine.qwen.isEnabled)
        #expect(!ModelManager.Engine.system.isEnabled)
        #endif
    }
    #if os(iOS)
    @Test func systemConverterAcceptsPrimingAndFlushesTheTail() throws {
        for rate in [16_000.0, 22_050.0, 44_100.0] {
            let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
            let converter = SystemPCMConverter()
            var output: [Float] = []
            for count in [1, 1, 1024, 1024, 1024] {
                let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
                input.frameLength = AVAudioFrameCount(count)
                for index in 0..<count { input.floatChannelData![0][index] = Float(sin(Double(index) * 0.08) * 0.2) }
                output += try converter.convert(input)
            }
            let end = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1)!
            output += try converter.convert(end)
            #expect(output.count > Int(3074 * 24_000 / rate) - 100)
            #expect(output.allSatisfy { $0.isFinite })
        }
    }

    @Test func systemSpeechProducesFinitePCM() async throws {
        let catalog = VoiceCatalog(); await catalog.loadIfNeeded()
        guard let voice = catalog.systemVoices.first(where: { $0.language == "en-US" }) else {
            return // Simulator runtimes can ship without voice assets.
        }
        for text in ["Call me Ishmael.", "Some years ago.", "Hello.", "19.5 dollars."] {
            let sentence = try await SystemSpeech.shared.synthesize(text, voiceID: voice.id)
            #expect(sentence.samples.count > 1_200)
        }
        let audio = try await SystemSpeech.shared.synthesize("Hello. This is a reading test.", voiceID: voice.id)
        #expect(audio.sampleRate == 24_000)
        #expect(audio.samples.count > 2_400)
        #expect(audio.samples.allSatisfy { $0.isFinite })
        #expect(audio.checkedWords)
        let task = Task { try await SystemSpeech.shared.synthesize(String(repeating: "Hello world. ", count: 30), voiceID: voice.id) }
        await Task.yield()
        task.cancel()
        do { _ = try await task.value; Issue.record("Cancelled speech completed") }
        catch is CancellationError {} catch { Issue.record("Unexpected cancellation error: \(error)") }
    }
    #endif

}
