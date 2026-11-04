import Foundation
import GVoiceKit
import XCTest
@testable import QwenANE

/// One QwenANE runtime, two model sizes (0.6B: 1024-wide talker, 2 chunks of 14 layers, 4-bit text table;
/// 1.7B: 2048-wide, 4 chunks of 7, 8-bit text table, a host-side small_to_mtp_projection). The size is read from
/// the model set's `host/config.json`; a 0.6B set's config predates those keys and must read as 0.6B.
///
/// The model-backed suites (prefix cache, talk sessions, streaming, hardening, language, ...) run against
/// whichever set `QWEN_ANE_MODELS` names; run them once per size (scripts/test-qwen-ane-sizes.sh).
final class QwenSizeTests: XCTestCase {
    private func tempConfig(_ json: String) throws -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("qwen-size-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("config.json")
        try json.write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    private let base = """
    "tts_bos": 151672, "tts_eos": 151673, "tts_pad": 151671, "codec_bos": 2149, "codec_eos": 2150, "codec_pad": 2148,
    "codec_think": 2154, "codec_nothink": 2155, "codec_think_bos": 2156, "codec_think_eos": 2157,
    "codec_language_id": {"spanish": 2054}, "vocab": 3072, "num_code_groups": 16
    """

    func testAnOldHostConfigReadsAs06B() throws {
        let c = try HostConfig(path: try tempConfig("{\(base)}"))
        XCTAssertEqual(c.hidden, 1024); XCTAssertEqual(c.textHidden, 2048); XCTAssertEqual(c.cpHidden, 1024)
        XCTAssertEqual(c.layers, 28); XCTAssertEqual(c.talkerChunks, 2); XCTAssertEqual(c.textEmbeddingBits, 4)
    }

    func testA17BHostConfigReads17B() throws {
        let c = try HostConfig(path: try tempConfig("""
        {\(base), "hidden": 2048, "text_hidden": 2048, "cp_hidden": 1024, "layers": 28, "talker_chunks": 4, "text_embedding_bits": 8}
        """))
        XCTAssertEqual(c.hidden, 2048); XCTAssertEqual(c.talkerChunks, 4); XCTAssertEqual(c.textEmbeddingBits, 8)
        XCTAssertEqual(c.layers / c.talkerChunks, 7)
    }

    func testAnInconsistentHostConfigIsRefused() throws {
        for bad in ["\"talker_chunks\": 5", "\"text_embedding_bits\": 6", "\"hidden\": 0"] {
            XCTAssertThrowsError(try HostConfig(path: try tempConfig("{\(base), \(bad)}")), bad)
        }
    }

    func testEngineKindsKeepTheirOwnFolderAndSpeakerSize() {
        XCTAssertEqual(QwenEngineFiles.Kind.qwen06.directory, "engines/qwen3-0.6b")
        XCTAssertEqual(QwenEngineFiles.Kind.qwen17.directory, "engines/qwen3-1.7b")
        XCTAssertEqual(QwenEngineFiles.Kind.qwen06.speakerDimension, 1024)
        XCTAssertEqual(QwenEngineFiles.Kind.qwen17.speakerDimension, 2048)
        XCTAssertEqual(QwenEngineFiles.Kind.forEngine("qwen3-1.7b"), .qwen17)
        XCTAssertNil(QwenEngineFiles.Kind.forEngine("lux-tts"))
        // the original statics are the 0.6B folder's
        XCTAssertEqual(QwenEngineFiles.directory, QwenEngineFiles.Kind.qwen06.directory)
    }

    func testAVoiceFolderIsOnlyValidForItsOwnSize() throws {
        let voice = QwenVoiceFiles(refText: "Come in.", refCodes: (0..<16).map { _ in [1, 2, 3, 4] },
                                   spkEmbedding: [Float](repeating: 0.25, count: 2048))
        let p17 = try QwenVoicePrep.enginePayload(for: voice, audioSHA256: String(repeating: "a", count: 64), kind: .qwen17)
        XCTAssertEqual(p17.kind, .qwen17)
        XCTAssertEqual(Set(try p17.members().keys.map { ($0 as NSString).deletingLastPathComponent }), ["engines/qwen3-1.7b"])
        XCTAssertThrowsError(try QwenVoicePrep.enginePayload(for: voice, audioSHA256: String(repeating: "a", count: 64), kind: .qwen06),
                             "a 2048-wide x-vector is not a 0.6B voice")
        // the same bytes read as the other size do not validate
        var wrong = p17; wrong.kind = .qwen06
        XCTAssertThrowsError(try wrong.validate())
    }

    func testPrepCacheAndFolderDoNotMixSizes() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("qwen-kind-\(UUID().uuidString)", isDirectory: true)
        let voice = QwenVoiceFiles(refText: "Come in.", refCodes: (0..<16).map { _ in [1, 2, 3, 4] },
                                   spkEmbedding: (0..<2048).map { Float($0) / 2048 })
        try QwenVoicePrep.write(voice, sha: "abc", to: dir)
        XCTAssertNotNil(QwenVoicePrep.cached(directory: dir, sha: "abc", text: "Come in.", kind: .qwen17))
        XCTAssertNil(QwenVoicePrep.cached(directory: dir, sha: "abc", text: "Come in.", kind: .qwen06),
                     "a 1.7B cache entry must not be taken for a 0.6B voice")
        // folder round trip in a voice directory: each size has its own, neither sees the other
        let vdir = FileManager.default.temporaryDirectory.appendingPathComponent("qwen-voice-\(UUID().uuidString)", isDirectory: true)
        let payload = try QwenVoicePrep.enginePayload(for: voice, audioSHA256: String(repeating: "b", count: 64), kind: .qwen17)
        QwenVoicePrep.writeFolder(payload, in: vdir)
        XCTAssertEqual(QwenVoicePrep.storedFolder(in: vdir, kind: .qwen17), payload)
        XCTAssertNil(QwenVoicePrep.storedFolder(in: vdir, kind: .qwen06))
        XCTAssertEqual(QwenVoicePrep.sectionMember(.qwen17), "engines/qwen3-1.7b/ref.wav")
        XCTAssertTrue(QwenVoicePrep.isSectionAudio("engines/qwen3-1.7b/ref-es.wav", kind: .qwen17))
        XCTAssertFalse(QwenVoicePrep.isSectionAudio("engines/qwen3-1.7b/ref.wav", kind: .qwen06))
    }

    // MARK: host maths against Python (1.7B set only)

    private func fixture(_ name: String) throws -> [Float] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "npy", subdirectory: "Fixtures"))
        let d = try Data(contentsOf: url)
        let hlen = Int(d[8]) | Int(d[9]) << 8
        return d.dropFirst(10 + hlen).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    private func host17() throws -> HostTables {
        let p = try QwenTestModels.directory().appendingPathComponent("host").path
        let h = try HostTables(dir: p)
        try XCTSkipUnless(h.cfg.hidden == 2048, "the model set is not the 1.7B one")
        return h
    }

    /// 8-bit text embedding + 2048-wide projection: the Swift host agrees with qonnx.Host.text_proj.
    func testTextProjectionMatchesPythonOn17B() throws {
        let host = try host17()
        let ids = [151672, 151673, 151671, 100, 5000]
        let got = host.textProj(ids), want = try fixture("host17_textproj_ref")
        XCTAssertEqual(got.count, want.count)
        var worst: Float = 0
        for i in 0..<got.count { worst = max(worst, abs(got[i] - want[i])) }
        XCTAssertLessThan(worst, 1e-3, "max |swift - python| text projection")
    }

    /// small_to_mtp_projection of codec rows (what the code predictor's hidden / e0 inputs are made of).
    func testCodePredictorInputProjectionMatchesPythonOn17B() throws {
        let host = try host17()
        XCTAssertTrue(host.projectsForCodePredictor)
        let want = try fixture("host17_cpin_ref")
        for (r, id) in [2149, 2150].enumerated() {
            let got = host.cpInput(host.codecRow(id))
            XCTAssertEqual(got.count, 1024)
            var worst: Float = 0
            for i in 0..<1024 { worst = max(worst, abs(got[i] - want[r * 1024 + i])) }
            XCTAssertLessThan(worst, 1e-3, "row \(id)")
        }
    }

    /// 0.6B is untouched: no projection, identity.
    func testNo06BProjection() throws {
        let p = try QwenTestModels.directory().appendingPathComponent("host").path
        let h = try HostTables(dir: p)
        try XCTSkipUnless(h.cfg.hidden == 1024, "the model set is not the 0.6B one")
        XCTAssertFalse(h.projectsForCodePredictor)
        let v = h.codecRow(2149)
        XCTAssertEqual(h.cpInput(v), v)
    }
}
