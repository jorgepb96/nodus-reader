import Foundation
import XCTest
@testable import QwenANE

/// Failure-path tests: corrupt caches read as misses, bad codes throw instead of indexing out of
/// bounds, a NaN from the Neural Engine abandons the line and leaves the engine usable. The model-backed
/// ones need `QWEN_ANE_MODELS` and skip otherwise.
@available(macOS 15.0, iOS 18.0, *)
final class QwenANEHardeningTests: XCTestCase {
    private func tempDir() -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("qwen-hard-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: u) }
        return u
    }

    private func modelsDirectory() throws -> URL {
        guard let p = ProcessInfo.processInfo.environment["QWEN_ANE_MODELS"], !p.isEmpty else {
            throw XCTSkip("QWEN_ANE_MODELS is not set")
        }
        return URL(fileURLWithPath: p)
    }

    /// A v1 .npy with `header` verbatim (padded) and `payload` bytes.
    private func npy(header: String, payload: Data) -> Data {
        var h = header
        while (10 + h.utf8.count + 1) % 64 != 0 { h += " " }
        h += "\n"
        var d = Data([0x93]) + Data("NUMPY".utf8) + Data([1, 0])
        d.append(UInt8(h.utf8.count & 0xff)); d.append(UInt8(h.utf8.count >> 8))
        return d + Data(h.utf8) + payload
    }

    private func int32s(_ v: [Int32]) -> Data { v.withUnsafeBytes { Data($0) } }

    private func writeVoice(codes: [Int32], T: Int, to dir: URL) throws {
        try Data(#"{"ref_text":"hello"}"#.utf8).write(to: dir.appendingPathComponent("voice.json"))
        try npy(header: "{'descr': '<i4', 'fortran_order': False, 'shape': (1, 16, \(T)), }", payload: int32s(codes))
            .write(to: dir.appendingPathComponent("ref_codes.npy"))
        try npy(header: "{'descr': '<f4', 'fortran_order': False, 'shape': (1024,), }",
                payload: [Float](repeating: 0.5, count: 1024).withUnsafeBytes { Data($0) })
            .write(to: dir.appendingPathComponent("spk_embed.npy"))
    }

    // MARK: NPY

    func testCorruptNPYHeadersThrowInsteadOfTrapping() throws {
        let dir = tempDir()
        let body = Data(count: 64)
        let cases: [(String, Data)] = [
            ("unterminated descr", npy(header: "{'descr': '<f4", payload: body)),
            ("unterminated shape", npy(header: "{'descr': '<f4', 'fortran_order': False, 'shape': (4, ", payload: body)),
            ("no shape", npy(header: "{'descr': '<f4', 'fortran_order': False}", payload: body)),
            ("truncated payload", npy(header: "{'descr': '<f4', 'fortran_order': False, 'shape': (1000,), }", payload: body)),
            ("not npy", Data("hello world, definitely not numpy".utf8)),
            ("empty", Data()),
            ("header longer than file", Data([0x93]) + Data("NUMPY".utf8) + Data([1, 0, 0xff, 0xff, 0, 0, 0, 0])),
        ]
        for (name, data) in cases {
            let url = dir.appendingPathComponent("bad.npy")
            try data.write(to: url)
            XCTAssertThrowsError(try NPY(path: url.path), name)
        }
        // a good one still reads
        let good = dir.appendingPathComponent("good.npy")
        try npy(header: "{'descr': '<f4', 'fortran_order': False, 'shape': (4,), }", payload: [Float]([1, 2, 3, 4]).withUnsafeBytes { Data($0) }).write(to: good)
        let n = try NPY(path: good.path)
        XCTAssertEqual(n.shape, [4]); XCTAssertEqual(n.f32[3], 4)
    }

    // MARK: code ranges

    func testReferenceCodesOutsideCodebookAreRejected() throws {
        let T = 9
        var ok = [[Int]](repeating: [Int](repeating: 5, count: T), count: 16)
        XCTAssertNoThrow(try QwenVoiceFiles.validate(refCodes: ok))
        ok[7][3] = 2048
        XCTAssertThrowsError(try QwenVoiceFiles.validate(refCodes: ok))
        ok[7][3] = -1
        XCTAssertThrowsError(try QwenVoiceFiles.validate(refCodes: ok))
        XCTAssertThrowsError(try QwenVoiceFiles.validate(refCodes: Array(ok.prefix(15))))

        let dir = tempDir()
        var codes = [Int32](repeating: 7, count: 16 * T)
        try writeVoice(codes: codes, T: T, to: dir)
        let v = try QwenVoiceFiles(directory: dir)
        XCTAssertEqual(v.spkEmbedding.count, 1024); XCTAssertEqual(v.refCodes[15][8], 7)
        codes[20] = 2_000_000
        try writeVoice(codes: codes, T: T, to: dir)
        XCTAssertThrowsError(try QwenVoiceFiles(directory: dir))
    }

    func testAllFinite() {
        XCTAssertTrue(ANETalkerEngine.allFinite([0, 1, -3]))
        XCTAssertFalse(ANETalkerEngine.allFinite([0, .nan]))
        XCTAssertFalse(ANETalkerEngine.allFinite([.infinity]))
    }

    // MARK: models

    func testPrimedCacheIsBounded() throws {
        let voc = try ANEVocoder(modelsDirectory: try modelsDirectory())
        voc.overlap = false
        for i in 0..<(ANEVocoder.maxPrimed + 3) {
            let ctx = (0..<(16 * 10)).map { Int64(($0 + i) % 2048) }
            voc.begin(context: ctx)
            XCTAssertLessThanOrEqual(voc.primedCount, ANEVocoder.maxPrimed)
        }
        XCTAssertEqual(voc.primedCount, ANEVocoder.maxPrimed)
        voc.dropCaches()
        XCTAssertEqual(voc.primedCount, 0)
    }

    func testNonFiniteOutputThrowsAndEngineRecovers() throws {
        let engine = try QwenTestModels.engine()
        let voice = try engine.loadVoice(named: "jeff")
        let text = "Good evening, you are tuned in."
        let base = try engine.render(text: text, voice: voice, seed: 3, maxFrames: 20)
        XCTAssertGreaterThan(base.frames, 0)
        for inject in [\ANETalkerEngine.injectNaNLogitsAtFrame, \ANETalkerEngine.injectNaNSubCodesAtFrame] {
            engine.talker[keyPath: inject] = 4
            XCTAssertThrowsError(try engine.render(text: text, voice: voice, seed: 3, maxFrames: 20)) { e in
                guard case QwenANEError.nonFinite = e else { return XCTFail("wrong error \(e)") }
            }
            engine.talker[keyPath: inject] = nil
            let after = try engine.render(text: text, voice: voice, seed: 3, maxFrames: 20)
            XCTAssertEqual(after.codes, base.codes, "KV state was not reset after a non-finite line")
        }
    }

    func testMaxFramesReportsTheKVWindow() throws {
        let engine = try QwenTestModels.engine()
        let voice = try engine.loadVoice(named: "jeff")
        let short = try engine.maxFrames(text: "Hello there.", voice: voice)
        XCTAssertEqual(short, 75)
        let long = try engine.maxFrames(text: String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 60), voice: voice)
        XCTAssertLessThan(long, 4096)
        XCTAssertGreaterThan(long, 100)
        XCTAssertLessThanOrEqual(long, ANETalkerEngine.LMAX)
    }
}
