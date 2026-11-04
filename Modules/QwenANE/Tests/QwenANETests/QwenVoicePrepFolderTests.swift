import XCTest
import GVoiceKit
@testable import QwenANE

/// `prepareEngineFolder`: a master past the encoder gets its section chosen ONCE and stored in
/// `engines/qwen3-0.6b/`; every later call reads the stored folder and cuts nothing.
final class QwenVoicePrepFolderTests: XCTestCase {
    private let limit = 480_000   // 20 s
    private var voiceDir: URL!
    private var cache: URL!

    override func setUpWithError() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("qwen-folder-\(UUID().uuidString)")
        voiceDir = root.appendingPathComponent("voice"); cache = root.appendingPathComponent("cache")
        try FileManager.default.createDirectory(at: voiceDir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    }

    private func master(seconds: Double) -> Data {
        ReferenceSection.wavData(Self.speech(seconds: seconds), sampleRate: 24_000)
    }
    private static func speech(seconds: Double) -> [Float] {
        (0 ..< Int(seconds * 24_000)).map { i in
            let t = Double(i) / 24_000
            return t.truncatingRemainder(dividingBy: 0.9) < 0.6 ? 0.3 * Float(sin(2 * .pi * 180 * t)) : 0
        }
    }

    /// Stands in for the Core ML encoders; counts its runs.
    private final class Encoder { var runs = 0 }
    private func fake(_ e: Encoder) -> (Data, String) throws -> QwenVoiceFiles {
        { wav, text in
            e.runs += 1
            let all = try QwenVoicePrep.samples(of: wav)
            let T = QwenVoicePrep.codeFrames(samples: ReferenceTail.end(of: all, sampleRate: 24_000))
            return QwenVoiceFiles(refText: text, refCodes: (0..<16).map { g in (0..<T).map { ($0 * 7 + g) % 2048 } },
                                  spkEmbedding: [Float](repeating: 0.25, count: 1024))
        }
    }
    private func run(_ master: Data, _ e: Encoder, words: String = String(repeating: "alpha beta gamma. delta epsilon zeta. eta theta iota. ", count: 8)
                         .trimmingCharacters(in: .whitespaces),
                     heard: String? = nil) async throws -> QwenVoicePrep.Prepared {
        try await QwenVoicePrep.prepareEngineFolder(
            voiceDir: voiceDir, masterWAV: master, transcript: words, cacheDirectory: cache,
            transcribe: { _ in heard }, limitSamples: limit, encode: fake(e))
    }
    private var sectionURL: URL { voiceDir.appendingPathComponent(QwenVoicePrep.sectionMember) }

    /// Qwen reads the reference text and the script as one stream, so a transcript that stops mid-sentence
    /// ("...West Coast crew") runs into the script: every render opened "Crew Hi, it's Jeff". The text the
    /// encoder gets, and the one stored, always end a sentence.
    func testAnUnfinishedTranscriptIsEndedBeforeItIsUsed() async throws {
        var seen: [String] = []
        let e = Encoder(), encode = fake(e)
        _ = try await QwenVoicePrep.prepareEngineFolder(
            voiceDir: voiceDir, masterWAV: master(seconds: 10), transcript: "Big shout to the West Coast crew ",
            cacheDirectory: cache, transcribe: nil, limitSamples: limit,
            encode: { wav, text in seen.append(text); return try encode(wav, text) })
        XCTAssertEqual(seen, ["Big shout to the West Coast crew."])
        XCTAssertEqual(try XCTUnwrap(QwenVoicePrep.storedFolder(in: voiceDir)).text, "Big shout to the West Coast crew.")
    }

    func testSectionEndsAtASentenceEnd() async throws {
        let words = (0 ..< 12).map { "uno dos tres cuatro cinco seis siete ocho nueve diez once doce\($0 == 11 ? "" : ".")" }
            .joined(separator: " ") + " y luego"
        let e = Encoder()
        _ = try await run(master(seconds: 40), e, words: words)
        let stored = try XCTUnwrap(QwenVoicePrep.storedFolder(in: voiceDir))
        XCTAssertTrue(ReferenceSection.endsSentence(stored.text), stored.text)
        let seconds = Double(try QwenVoicePrep.samples(of: try Data(contentsOf: sectionURL)).count) / 24_000
        XCTAssertLessThanOrEqual(seconds, 20.48)
        XCTAssertEqual(try XCTUnwrap(stored.derivedFrom.endSeconds) - XCTUnwrap(stored.derivedFrom.startSeconds), seconds, accuracy: 0.01)
    }

    /// The character clock puts a sentence end in the wrong pause when word lengths vary (here long words
    /// first, short ones after), so the section kept words its transcript did not have: Bad Bunny's Spanish
    /// section ended "en especifico." while its audio went on "Yo creo que". With a recogniser the cut whose
    /// words match its transcript is the one stored. The fake recogniser hears one word per burst (the
    /// master's own words, punctuation and all), as a real one hears the audio, not the transcript.
    func testSectionAudioAndTranscriptEndTogether() async throws {
        let long = ["extraordinariamente", "particularmente", "responsabilidades", "internacionalmente"]
        let short = ["a", "y", "o", "si", "no", "te"]
        var words: [String] = []
        for i in 0 ..< 46 {
            var w = i < 14 ? long[i % long.count] : short[i % short.count]
            if i % 3 == 2 { w += "." }
            words.append(w)
        }
        let transcript = words.joined(separator: " ")
        let heardWords = words
        let recognizer: @Sendable (Data) async -> String? = { wav in
            guard let x = try? QwenVoicePrep.samples(of: wav) else { return nil }
            return heardWords.prefix(Self.bursts(x)).joined(separator: " ")
        }
        let r = try await QwenVoicePrep.prepareEngineFolder(
            voiceDir: voiceDir, masterWAV: master(seconds: 41.4), transcript: transcript, cacheDirectory: cache,
            transcribe: recognizer, limitSamples: limit, encode: fake(Encoder()))
        let section = try QwenVoicePrep.samples(of: try Data(contentsOf: sectionURL))
        let stored = r.files.refText
        XCTAssertTrue(ReferenceSection.endsSentence(stored), stored)
        XCTAssertEqual(stored.split(separator: " ").count, Self.bursts(section), "every word the audio says is in its transcript, and no other")

        // The same master without a recogniser keeps the character clock's guess: the bug, for contrast.
        try? FileManager.default.removeItem(at: voiceDir); try? FileManager.default.removeItem(at: cache)
        try FileManager.default.createDirectory(at: voiceDir, withIntermediateDirectories: true)
        let guess = try await QwenVoicePrep.prepareEngineFolder(
            voiceDir: voiceDir, masterWAV: master(seconds: 41.4), transcript: transcript, cacheDirectory: cache,
            transcribe: nil, limitSamples: limit, encode: fake(Encoder()))
        let guessSection = try QwenVoicePrep.samples(of: try Data(contentsOf: sectionURL))
        XCTAssertNotEqual(guess.files.refText.split(separator: " ").count, Self.bursts(guessSection),
                          "the fixture really does fool the character clock")
    }

    /// Speech bursts (runs of 20 ms windows above -30 dBFS) in a clip.
    private static func bursts(_ x: [Float]) -> Int {
        let w = 480
        var n = 0, inBurst = false
        for i in 0 ..< x.count / w {
            var s: Float = 0
            for j in (i * w) ..< ((i + 1) * w) { s += x[j] * x[j] }
            let loud = 10 * log10(s / Float(w) + 1e-12) > -30
            if loud && !inBurst { n += 1 }
            inBurst = loud
        }
        return n
    }

    func testALongMasterGetsItsSectionStoredInThePack() async throws {
        let m = master(seconds: 50), e = Encoder()
        let r = try await run(m, e)
        XCTAssertEqual(e.runs, 1)
        let stored = try XCTUnwrap(QwenVoicePrep.storedFolder(in: voiceDir))
        let d = stored.derivedFrom
        XCTAssertEqual(d.audio, QwenVoicePrep.sectionMember)
        XCTAssertEqual(d.sourceSha256, ReferenceSection.sha256Hex(m))
        let wav = try Data(contentsOf: sectionURL)
        XCTAssertEqual(d.sha256, ReferenceSection.sha256Hex(wav), "the codes are computed FROM the stored section")
        let seconds = Double(try QwenVoicePrep.samples(of: wav).count) / 24_000
        XCTAssertLessThanOrEqual(seconds, 20); XCTAssertGreaterThan(seconds, 12)
        XCTAssertEqual(try XCTUnwrap(d.endSeconds) - XCTUnwrap(d.startSeconds), seconds, accuracy: 0.01)
        XCTAssertFalse(stored.text.isEmpty)
        XCTAssertEqual(r.files.refText, stored.text)
    }

    func testALaterRenderReadsTheStoredFolderAndCutsNothing() async throws {
        let m = master(seconds: 50)
        let heard = (0 ..< 40).map { "heard\($0)" }.joined(separator: " ")   // a plausible rate for the cut
        let first = try await run(m, Encoder(), heard: heard)
        let wav = try Data(contentsOf: sectionURL)
        let voiceJSON = try Data(contentsOf: voiceDir.appendingPathComponent("engines/qwen3-0.6b/voice.json"))
        // Fresh in-process state: no cache directory, an encoder and a recognizer that would give different answers.
        try? FileManager.default.removeItem(at: cache)
        let e = Encoder()
        let again = try await run(m, e, words: "completely different words now", heard: "different heard words")
        XCTAssertEqual(e.runs, 0, "the encoders did not run")
        XCTAssertEqual(again.origin, .pack)
        XCTAssertEqual(again.files.refCodes, first.files.refCodes)
        XCTAssertEqual(again.files.refText, heard, "the stored transcript, not a new one")
        XCTAssertEqual(try Data(contentsOf: sectionURL), wav, "the section is byte-identical")
        XCTAssertEqual(try Data(contentsOf: voiceDir.appendingPathComponent("engines/qwen3-0.6b/voice.json")), voiceJSON)
    }

    func testAReplacedMasterReplacesTheSection() async throws {
        _ = try await run(master(seconds: 50), Encoder())
        let before = try Data(contentsOf: sectionURL)
        let other = ReferenceSection.wavData(Self.speech(seconds: 44).map { $0 * 0.5 }, sampleRate: 24_000)
        _ = try await run(other, Encoder())
        XCTAssertNotEqual(try Data(contentsOf: sectionURL), before)
        XCTAssertEqual(QwenVoicePrep.storedFolder(in: voiceDir)?.derivedFrom.sourceSha256, ReferenceSection.sha256Hex(other))
    }

    func testAMasterThatFitsStoresNoSection() async throws {
        let m = master(seconds: 12)
        _ = try await run(m, Encoder())
        XCTAssertFalse(FileManager.default.fileExists(atPath: sectionURL.path))
        XCTAssertEqual(QwenVoicePrep.storedFolder(in: voiceDir)?.derivedFrom.audio, "source/ref.wav")
    }

    func testA48kStereoMasterGetsA24kMonoSection() async throws {
        let rate = 48_000
        let mono = Self.speech(seconds: 50)
        var pcm = Data()
        for i in 0 ..< 50 * rate {
            var v = Int16(mono[min(mono.count - 1, i / 2)] * 32767).littleEndian   // 24 kHz source, doubled to 48 kHz
            withUnsafeBytes(of: &v) { pcm.append(contentsOf: $0); pcm.append(contentsOf: $0) }   // L and R
        }
        func le<T: FixedWidthInteger>(_ v: T) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        var m = Data("RIFF".utf8); m += le(UInt32(36 + pcm.count)); m += Data("WAVEfmt ".utf8)
        m += le(UInt32(16)); m += le(UInt16(1)); m += le(UInt16(2)); m += le(UInt32(rate)); m += le(UInt32(rate * 4))
        m += le(UInt16(4)); m += le(UInt16(16)); m += Data("data".utf8); m += le(UInt32(pcm.count)); m += pcm
        let r = try await run(m, Encoder())
        XCTAssertEqual(r.origin, .computed)
        let wav = try Data(contentsOf: sectionURL)
        let section = try QwenVoicePrep.samples(of: wav)   // the stored section is already 24 kHz mono
        XCTAssertEqual(RefLoudness.dataChunk(in: wav)?.sampleRate, 24_000)
        XCTAssertEqual(RefLoudness.dataChunk(in: wav)?.channels, 1)
        XCTAssertLessThanOrEqual(section.count, limit); XCTAssertGreaterThan(section.count, 12 * 24_000)
        let d = try XCTUnwrap(QwenVoicePrep.storedFolder(in: voiceDir)?.derivedFrom)
        XCTAssertEqual(d.sourceSha256, ReferenceSection.sha256Hex(m))
    }

    // MARK: the section's words are in the take's language

    private static let spanish = (0 ..< 8).map { _ in "yo creo que no hay nada que te pueda decir, lo más complicado es por eso." }
        .joined(separator: " ")
    private static let englishRendering = (0 ..< 8).map { _ in "I think there is nothing that I can say to you." }
        .joined(separator: " ")

    /// 2026-10-06: Whisper with no language told decoded Bad Bunny's Spanish as English, at a plausible
    /// rate, and that English was stored as the Spanish take's section transcript (Qwen then rendered static).
    func testAnEnglishRenderingOfASpanishTakeIsNeverStored() async throws {
        let e = Encoder()
        let r = try await QwenVoicePrep.prepareEngineFolder(
            voiceDir: voiceDir, masterWAV: master(seconds: 40), transcript: Self.spanish, cacheDirectory: cache,
            language: "es", transcribe: { _ in Self.englishRendering }, limitSamples: limit, encode: fake(e))
        let stored = try XCTUnwrap(QwenVoicePrep.storedFolder(in: voiceDir))
        XCTAssertTrue(ReferenceSection.textIsPlausibleIn(language: "es", stored.text), stored.text)
        XCTAssertFalse(stored.text.contains("nothing"), stored.text)
        XCTAssertTrue(ReferenceSection.textIsPlausibleIn(language: "es", r.files.refText))
    }

    /// A section already stored with the wrong language (written before this check) is chosen again.
    func testAStoredSectionInTheWrongLanguageIsReplaced() async throws {
        let e = Encoder()
        let m = master(seconds: 40)
        _ = try await QwenVoicePrep.prepareEngineFolder(
            voiceDir: voiceDir, masterWAV: m, transcript: Self.spanish, cacheDirectory: cache,
            transcribe: { _ in Self.englishRendering }, limitSamples: limit, encode: fake(e))   // no language: old behaviour
        XCTAssertFalse(ReferenceSection.textIsPlausibleIn(language: "es", try XCTUnwrap(QwenVoicePrep.storedFolder(in: voiceDir)).text))
        _ = try await QwenVoicePrep.prepareEngineFolder(
            voiceDir: voiceDir, masterWAV: m, transcript: Self.spanish, cacheDirectory: cache,
            language: "es", transcribe: { _ in nil }, limitSamples: limit, encode: fake(e))
        XCTAssertTrue(ReferenceSection.textIsPlausibleIn(language: "es", try XCTUnwrap(QwenVoicePrep.storedFolder(in: voiceDir)).text))
    }

    /// A master transcript that is itself in the wrong language is used for the render but not stored.
    func testASectionInTheWrongLanguageIsNotStoredAtAll() async throws {
        let e = Encoder()
        _ = try await QwenVoicePrep.prepareEngineFolder(
            voiceDir: voiceDir, masterWAV: master(seconds: 40), transcript: Self.englishRendering, cacheDirectory: cache,
            language: "es", transcribe: { _ in nil }, limitSamples: limit, encode: fake(e))
        XCTAssertNil(QwenVoicePrep.storedFolder(in: voiceDir))
    }
}
