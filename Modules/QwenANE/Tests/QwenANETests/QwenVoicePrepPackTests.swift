import Foundation
import GVoiceKit
import XCTest
@testable import QwenANE

/// Pack-provided prepared voices: valid files skip the encoders, anything stale is recomputed.
/// No Core ML models needed: the encoder is a counting stand-in.
final class QwenVoicePrepPackTests: XCTestCase {
    private func wav(seconds: Double) -> Data {
        let n = Int(seconds * 24000)
        var d = Data("RIFF".utf8)
        func u32(_ v: Int) { withUnsafeBytes(of: UInt32(v).littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: Int) { withUnsafeBytes(of: UInt16(v).littleEndian) { d.append(contentsOf: $0) } }
        u32(36 + n * 2); d.append(Data("WAVEfmt ".utf8)); u32(16); u16(1); u16(1); u32(24000); u32(48000); u16(2); u16(16)
        d.append(Data("data".utf8)); u32(n * 2)
        for i in 0..<n { u16(Int(UInt16(bitPattern: Int16(0.3 * sin(2 * .pi * 220 * Float(i) / 24000) * 32767)))) }
        return d
    }

    private func tempDir() -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("qwen-pack-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: u) }
        return u
    }

    private func frames(_ wav: Data) throws -> Int {
        let all = try QwenVoicePrep.samples(of: wav)
        return QwenVoicePrep.codeFrames(samples: ReferenceTail.end(of: all, sampleRate: 24000))
    }

    private func fake(_ wav: Data, text: String) throws -> QwenVoiceFiles {
        let T = try frames(wav)
        return QwenVoiceFiles(refText: text,
                              refCodes: (0..<16).map { g in (0..<T).map { ($0 * 7 + g * 13) % 2048 } },
                              spkEmbedding: (0..<1024).map { Float($0) / 1024 })
    }

    private final class Counter { var runs = 0 }

    private func prepare(_ pack: QwenEngineFiles?, _ ref: Data, _ text: String, dir: URL, counter: Counter,
                         file: StaticString = #filePath, line: UInt = #line) throws -> QwenVoicePrep.Prepared {
        try QwenVoicePrep.prepared(fromPack: pack, referenceWAV: ref, transcript: text, cacheDirectory: dir) { w, t in
            counter.runs += 1
            return try self.fake(w, text: t)
        }
    }

    func testValidPackRunsNoEncoderAndSeedsCache() throws {
        let ref = wav(seconds: 2), text = "hello world"
        let payload = try QwenVoicePrep.enginePayload(for: try fake(ref, text: text), referenceWAV: ref)
        let dir = tempDir(), c = Counter()
        let r = try prepare(payload, ref, "  hello world\n", dir: dir, counter: c)
        XCTAssertEqual(c.runs, 0)
        XCTAssertEqual(r.origin, .pack)
        XCTAssertEqual(r.files.refText, text)
        XCTAssertEqual(r.files.refCodes, try fake(ref, text: text).refCodes)
        XCTAssertEqual(r.files.spkEmbedding.count, 1024)
        // The local cache was seeded: a second call with no pack is a cache hit, still no encoder.
        let again = try prepare(nil, ref, text, dir: dir, counter: c)
        XCTAssertEqual(again.origin, .cache)
        XCTAssertEqual(c.runs, 0)
        XCTAssertEqual(try QwenVoiceFiles(directory: dir).refCodes, r.files.refCodes)
    }

    func testStaleSHARecomputes() throws {
        let ref = wav(seconds: 2), text = "hello world"
        let payload = try QwenVoicePrep.enginePayload(for: try fake(ref, text: text), referenceWAV: ref)
        let edited = wav(seconds: 3)
        let c = Counter()
        let r = try prepare(payload, edited, text, dir: tempDir(), counter: c)
        XCTAssertEqual(c.runs, 1)
        XCTAssertEqual(r.origin, .computed)
    }

    func testWrongPrepVersionOrMelRecomputes() throws {
        let ref = wav(seconds: 2), text = "hello world"
        var payload = try QwenVoicePrep.enginePayload(for: try fake(ref, text: text), referenceWAV: ref)
        var c = Counter()
        payload.derivedFrom.prepVersion = QwenVoicePrep.prepVersion + 1
        XCTAssertEqual(try prepare(payload, ref, text, dir: tempDir(), counter: c).origin, .computed)
        XCTAssertEqual(c.runs, 1)
        c = Counter()
        payload.derivedFrom.prepVersion = QwenVoicePrep.prepVersion
        payload.derivedFrom.mel = "librosa"
        XCTAssertEqual(try prepare(payload, ref, text, dir: tempDir(), counter: c).origin, .computed)
        XCTAssertEqual(c.runs, 1)
    }

    func testDifferentTranscriptOrInvalidFilesRecompute() throws {
        let ref = wav(seconds: 2), text = "hello world"
        let payload = try QwenVoicePrep.enginePayload(for: try fake(ref, text: text), referenceWAV: ref)
        var c = Counter()
        XCTAssertEqual(try prepare(payload, ref, "other words", dir: tempDir(), counter: c).origin, .computed)
        XCTAssertEqual(c.runs, 1)

        // A folder whose frame count disagrees with the audio is ignored.
        c = Counter()
        var short = try fake(ref, text: text)
        short.refCodes = short.refCodes.map { Array($0.dropLast()) }
        let wrongT = try QwenVoicePrep.enginePayload(for: short, referenceWAV: ref)
        XCTAssertEqual(try prepare(wrongT, ref, text, dir: tempDir(), counter: c).origin, .computed)
        XCTAssertEqual(c.runs, 1)

        // Corrupt arrays are ignored, not trusted.
        c = Counter()
        var junk = payload; junk.spkEmbedding = Data("nope".utf8)
        XCTAssertEqual(try prepare(junk, ref, text, dir: tempDir(), counter: c).origin, .computed)
        XCTAssertEqual(c.runs, 1)
    }

    func testComputedResultProducesPayloadThatRoundTripsThroughAPack() throws {
        let ref = wav(seconds: 2), text = "hello world"
        let c = Counter()
        let r = try prepare(nil, ref, text, dir: tempDir(), counter: c)
        XCTAssertEqual(r.origin, .computed)
        let payload = try r.enginePayload(audio: "engines/lux-tts/ref.wav", window: (1, 3))
        XCTAssertEqual(payload.derivedFrom.sha256, GVoiceKitSHA.hex(ref))
        XCTAssertEqual(payload.derivedFrom.by, "QwenVoicePrep")
        XCTAssertEqual(payload.derivedFrom.prepVersion, QwenVoicePrep.prepVersion)
        XCTAssertEqual(payload.derivedFrom.mel, "upstream")
        XCTAssertEqual(payload.derivedFrom.endSeconds, 3)
        // decode(files:) of the written folder yields the same voice with zero encoder runs.
        let decoded = try QwenEngineFiles.decode(files: payload.files())
        let c2 = Counter()
        let r2 = try prepare(decoded, ref, text, dir: tempDir(), counter: c2)
        XCTAssertEqual(c2.runs, 0)
        XCTAssertEqual(r2.files.refCodes, r.files.refCodes)
        XCTAssertEqual(r2.files.spkEmbedding, r.files.spkEmbedding)
    }

    func testPayloadRejectsOutOfRangeCodes() throws {
        let ref = wav(seconds: 2)
        var v = try fake(ref, text: "x")
        v.refCodes[3][0] = 2048
        XCTAssertThrowsError(try QwenVoicePrep.enginePayload(for: v, referenceWAV: ref))
    }

    /// Needs the real encoders: a pack payload must be the same voice the encoders produce.
    func testPayloadMatchesRealEncoders() throws {
        guard let m = ProcessInfo.processInfo.environment["QWEN_ANE_MODELS"], !m.isEmpty else { throw XCTSkip("QWEN_ANE_MODELS is not set") }
        let ref = wav(seconds: 3), text = "a tone"
        let models = URL(fileURLWithPath: m)
        // the model set's own size: a 1.7B set's speaker encoder makes 2048-wide x-vectors
        let kind: QwenEngineFiles.Kind = ((try? HostConfig(path: models.appendingPathComponent("host/config.json").path))?.hidden ?? 1024) == 2048 ? .qwen17 : .qwen06
        let first = try QwenVoicePrep.prepared(fromPack: nil, referenceWAV: ref, transcript: text,
                                               cacheDirectory: tempDir(), modelsDirectory: models, kind: kind)
        XCTAssertEqual(first.origin, .computed)
        let payload = try first.enginePayload(kind: kind)
        let second = try QwenVoicePrep.prepared(fromPack: payload, referenceWAV: ref, transcript: text, cacheDirectory: tempDir(),
                                                modelsDirectory: URL(fileURLWithPath: "/nonexistent"), kind: kind)   // would throw if it prepared
        XCTAssertEqual(second.origin, .pack)
        XCTAssertEqual(second.files.refCodes, first.files.refCodes)
        XCTAssertEqual(second.files.spkEmbedding, first.files.spkEmbedding)
    }
}

enum GVoiceKitSHA {
    static func hex(_ d: Data) -> String { QwenEngineFiles.sha256Hex(d) }
}
