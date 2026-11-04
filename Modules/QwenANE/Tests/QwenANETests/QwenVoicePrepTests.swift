import Foundation
import XCTest
@testable import QwenANE

/// Model-backed tests need the compiled encoders under `$QWEN_ANE_MODELS/coreml/`
/// (QwenSpeechEncoder.mlmodelc, QwenSpeakerEncoder.mlmodelc) and the pack source clips; they skip otherwise:
///   QWEN_ANE_MODELS=/path/to/Models swift test --filter QwenVoicePrepTests
final class QwenVoicePrepTests: XCTestCase {
    /// `$QWEN_ANE_PACKS`: the Packs directory (`<slug>/source/ref.wav`); `$QWEN_ANE_VOICE_TEXTS`: the
    /// reference transcripts (`<slug>/ref_text.txt`). Parity tests skip when either is unset.
    static var packs: String { ProcessInfo.processInfo.environment["QWEN_ANE_PACKS"] ?? "" }
    static var texts: String { ProcessInfo.processInfo.environment["QWEN_ANE_VOICE_TEXTS"] ?? "" }
    static func requirePacks() throws {
        guard !packs.isEmpty, !texts.isEmpty else {
            throw XCTSkip("set QWEN_ANE_PACKS (Packs dir) and QWEN_ANE_VOICE_TEXTS (voices dir with <slug>/ref_text.txt) to run this test")
        }
    }
    static let slugs = ["jeff", "benson", "cruz", "billie-frost"]

    // MARK: helpers

    private func fixture(_ name: String) throws -> (descr: String, shape: [Int], body: Data) {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "npy", subdirectory: "Fixtures"))
        let d = try Data(contentsOf: url)
        let hlen = Int(d[8]) | Int(d[9]) << 8
        let header = String(decoding: d[10..<(10 + hlen)], as: UTF8.self)
        let descr = header.components(separatedBy: "'descr': '")[1].components(separatedBy: "'")[0]
        let inner = header.components(separatedBy: "'shape': (")[1].components(separatedBy: ")")[0]
        let shape = inner.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        return (descr, shape, Data(d.dropFirst(10 + hlen)))
    }

    private func modelsDirectory() throws -> URL {
        guard let p = ProcessInfo.processInfo.environment["QWEN_ANE_MODELS"], !p.isEmpty else {
            throw XCTSkip("QWEN_ANE_MODELS is not set")
        }
        return URL(fileURLWithPath: p)
    }

    private func wav(samples: [Float], rate: Int = 24000, channels: Int = 1) -> Data {
        var d = Data("RIFF".utf8)
        func u32(_ v: Int) { withUnsafeBytes(of: UInt32(v).littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: Int) { withUnsafeBytes(of: UInt16(v).littleEndian) { d.append(contentsOf: $0) } }
        u32(36 + samples.count * 2); d.append(Data("WAVEfmt ".utf8)); u32(16); u16(1); u16(channels)
        u32(rate); u32(rate * 2 * channels); u16(2 * channels); u16(16)
        d.append(Data("data".utf8)); u32(samples.count * 2)
        for s in samples { u16(Int(UInt16(bitPattern: Int16(max(-1, min(1, s)) * 32767)))) }
        return d
    }

    private func tone(seconds: Double) -> [Float] {
        (0..<Int(seconds * 24000)).map { 0.3 * sin(2 * .pi * 220 * Float($0) / 24000) }
    }

    private func tempDir() -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("qwen-prep-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: u) }
        return u
    }

    // MARK: no models needed

    func testFrameMath() {
        XCTAssertEqual(QwenVoicePrep.codeFrames(samples: 358080), 187)
        XCTAssertEqual(QwenMel.frameCount(samples: 358080), 1 + (358080 + 768 - 1024) / 256)
        let (mel, frames) = QwenMel.logMel(tone(seconds: 1))
        XCTAssertEqual(frames, QwenMel.frameCount(samples: 24000))
        XCTAssertEqual(mel.count, frames * 128)
        XCTAssertTrue(mel.allSatisfy { $0.isFinite && $0 >= Float(log(1e-5)) - 1e-3 })
    }

    func testRejectsTooLongWindowBeforeLoadingModels() {
        let long = wav(samples: tone(seconds: 41))
        XCTAssertThrowsError(try QwenVoicePrep.prepare(referenceWAV: long, transcript: "x",
                                                       modelsDirectory: URL(fileURLWithPath: "/nonexistent"))) {
            guard case .referenceTooLong(let s)? = $0 as? QwenVoicePrepError else { return XCTFail("\($0)") }
            XCTAssertEqual(s, 41, accuracy: 0.01)
        }
    }

    func testAnySampleRateIsConvertedNotRefused() throws {
        // 44.1 kHz mono used to be refused as "need mono 24 kHz"; it is converted now, so prep gets as far
        // as the (absent) models.
        XCTAssertThrowsError(try QwenVoicePrep.prepare(referenceWAV: wav(samples: tone(seconds: 2), rate: 44100),
                                                       transcript: "x", modelsDirectory: URL(fileURLWithPath: "/x"))) {
            guard case .modelMissing? = $0 as? QwenVoicePrepError else { return XCTFail("\($0)") }
        }
    }

    func testA48kStereoReferenceBecomes24kMono() throws {
        // 3 s, 48 kHz, two channels (left a 220 Hz tone, right silent): 72 000 mono 24 kHz samples, tone intact.
        let rate = 48_000, n = 3 * rate
        var pcm = Data()
        for i in 0..<n {
            var l = Int16((0.5 * sin(2 * Double.pi * 220 * Double(i) / Double(rate))) * 32767).littleEndian
            var r = Int16(0).littleEndian
            withUnsafeBytes(of: &l) { pcm.append(contentsOf: $0) }; withUnsafeBytes(of: &r) { pcm.append(contentsOf: $0) }
        }
        func le<T: FixedWidthInteger>(_ v: T) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        var d = Data("RIFF".utf8); d += le(UInt32(36 + pcm.count)); d += Data("WAVEfmt ".utf8)
        d += le(UInt32(16)); d += le(UInt16(1)); d += le(UInt16(2)); d += le(UInt32(rate)); d += le(UInt32(rate * 4))
        d += le(UInt16(4)); d += le(UInt16(16)); d += Data("data".utf8); d += le(UInt32(pcm.count)); d += pcm
        let out = try QwenVoicePrep.samples(of: d)
        XCTAssertEqual(out.count, 72_000, accuracy: 4)
        let rms = (out[2000..<70000].reduce(0) { $0 + $1 * $1 } / Float(68000)).squareRoot()
        XCTAssertEqual(rms, 0.5 / 2 / Float(2).squareRoot(), accuracy: 0.03, "channels averaged, level kept")
        // And prep proceeds to the encoders (absent here) instead of refusing the format.
        XCTAssertThrowsError(try QwenVoicePrep.prepare(referenceWAV: d, transcript: "x", modelsDirectory: URL(fileURLWithPath: "/x"))) {
            guard case .modelMissing? = $0 as? QwenVoicePrepError else { return XCTFail("\($0)") }
        }
    }

    func testNotAudioIsStillRefused() {
        XCTAssertThrowsError(try QwenVoicePrep.samples(of: Data("not a wav".utf8))) {
            guard case .unsupportedWAV? = $0 as? QwenVoicePrepError else { return XCTFail("\($0)") }
        }
    }

    /// Cache hit/miss without models: a hit never touches the model directory, a miss does.
    func testCacheHitAndMiss() throws {
        let ref = wav(samples: tone(seconds: 2))
        let dir = tempDir()
        let models = URL(fileURLWithPath: "/nonexistent-models")
        let seeded = QwenVoiceFiles(refText: "hello world",
                                    refCodes: (0..<16).map { g in (0..<25).map { ($0 * 7 + g) % 2048 } },
                                    spkEmbedding: (0..<1024).map { Float($0) / 1024 })
        // Seed exactly what `prepared` writes, via a hit-compatible voice.json.
        let sha = QwenVoicePrep.sha256Hex(ref)
        try seedCache(seeded, sha: sha, dir: dir)

        let hit = try QwenVoicePrep.prepared(referenceWAV: ref, transcript: "  hello world\n", cacheDirectory: dir, modelsDirectory: models)
        XCTAssertEqual(hit.refCodes, seeded.refCodes)
        XCTAssertEqual(hit.spkEmbedding, seeded.spkEmbedding)

        for (name, wavBytes, text) in [("transcript", ref, "hello there"),
                                       ("audio", wav(samples: tone(seconds: 3)), "hello world")] {
            XCTAssertThrowsError(try QwenVoicePrep.prepared(referenceWAV: wavBytes, transcript: text, cacheDirectory: dir, modelsDirectory: models),
                                 "\(name) change must miss") {
                guard case .modelMissing? = $0 as? QwenVoicePrepError else { return XCTFail("\($0)") }
            }
        }

        // A stale prep version misses too.
        let url = dir.appendingPathComponent("voice.json")
        var j = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        j["prep_version"] = QwenVoicePrep.prepVersion + 1
        try JSONSerialization.data(withJSONObject: j).write(to: url)
        XCTAssertThrowsError(try QwenVoicePrep.prepared(referenceWAV: ref, transcript: "hello world", cacheDirectory: dir, modelsDirectory: models))
    }

    private func seedCache(_ v: QwenVoiceFiles, sha: String, dir: URL) throws {
        // Go through the real writer using the file-level helper.
        try QwenVoicePrepTestSupport.write(v, sha: sha, to: dir)
    }

    // MARK: with models

    func testParityAgainstCoreMLPythonReference() throws {
        try QwenTestModels.requireSlow()
        try Self.requirePacks()
        let models = try modelsDirectory()
        for slug in Self.slugs {
            let refURL = URL(fileURLWithPath: "\(Self.packs)/\(slug)/source/ref.wav")
            let textURL = URL(fileURLWithPath: "\(Self.texts)/\(slug)/ref_text.txt")
            guard let ref = try? Data(contentsOf: refURL), let text = try? String(contentsOf: textURL, encoding: .utf8) else {
                throw XCTSkip("pack source clip or transcript missing for \(slug)")
            }
            let t0 = Date()
            let voice = try QwenVoicePrep.prepare(referenceWAV: ref, transcript: text, modelsDirectory: models)
            let secs = Date().timeIntervalSince(t0)

            let want = try fixture("\(slug)_enc_codes")
            XCTAssertEqual(want.descr, "<i2")
            let w = want.body.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
            let T = want.shape[1]
            XCTAssertEqual(voice.refCodes.count, 16)
            XCTAssertEqual(voice.refCodes[0].count, T, slug)
            var same = 0
            for g in 0..<16 { for t in 0..<T where voice.refCodes[g][t] == Int(w[g * T + t]) { same += 1 } }
            let pct = 100 * Double(same) / Double(16 * T)

            let sp = try fixture("\(slug)_spk_ref")
            let r = sp.body.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            var dot: Float = 0, na: Float = 0, nb: Float = 0
            for i in 0..<1024 { dot += voice.spkEmbedding[i] * r[i]; na += voice.spkEmbedding[i] * voice.spkEmbedding[i]; nb += r[i] * r[i] }
            let cos = dot / (na.squareRoot() * nb.squareRoot())
            print("VOICEPREP \(slug): codes \(String(format: "%.3f", pct))% identical (\(16 * T - same) of \(16 * T) differ), spk cos \(String(format: "%.6f", cos)), prep \(String(format: "%.2f", secs)) s")
            XCTAssertGreaterThanOrEqual(pct, 99.5, slug)
            XCTAssertGreaterThanOrEqual(cos, 0.999, slug)
        }
    }

    func testCacheRoundTripWithModels() throws {
        try QwenTestModels.requireSlow()
        try Self.requirePacks()
        let models = try modelsDirectory()
        guard let ref = try? Data(contentsOf: URL(fileURLWithPath: "\(Self.packs)/benson/source/ref.wav")) else { throw XCTSkip("no benson clip") }
        let dir = tempDir()
        let a = try QwenVoicePrep.prepared(referenceWAV: ref, transcript: "text a", cacheDirectory: dir, modelsDirectory: models)
        let b = try QwenVoicePrep.prepared(referenceWAV: ref, transcript: "text a", cacheDirectory: dir,
                                           modelsDirectory: URL(fileURLWithPath: "/nonexistent"))   // hit: no models needed
        XCTAssertEqual(a.refCodes, b.refCodes)
        XCTAssertEqual(a.spkEmbedding, b.spkEmbedding)
        let loaded = try QwenVoiceFiles(directory: dir)
        XCTAssertEqual(loaded.refCodes, a.refCodes)
        let c = try QwenVoicePrep.prepared(referenceWAV: ref, transcript: "text b", cacheDirectory: dir, modelsDirectory: models)
        XCTAssertEqual(c.refText, "text b")
        XCTAssertEqual(c.refCodes, a.refCodes)
    }
}

enum QwenVoicePrepTestSupport {
    static func write(_ v: QwenVoiceFiles, sha: String, to dir: URL) throws {
        try QwenVoicePrep.write(v, sha: sha, to: dir)
    }
}
