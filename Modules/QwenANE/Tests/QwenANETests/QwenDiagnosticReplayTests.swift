import XCTest
@testable import QwenANE

@available(iOS 18.0, macOS 15.0, *)
final class QwenDiagnosticReplayTests: XCTestCase {
    func testCancelledLoadDoesNotOpenAnyModelFile() {
        XCTAssertThrowsError(try QwenANEEngine(modelsDirectory: URL(fileURLWithPath: "/missing-qwen-models"),
                                             cancelled: { true })) { error in
            XCTAssertTrue(error is CancellationError)
        }
    }

    /// Fixed generated codes isolate chunking from sampling. Run on physical iOS too; a Mac pass
    /// only establishes the Mac vocoder route, which uses a different backend for upMall.
    func testRawCaptureAndFixedCodeReplayKeepSamplesAcrossChunkBoundaries() throws {
        try QwenTestModels.requireSlow()
        guard let path = ProcessInfo.processInfo.environment["QWEN_ANE_VOICE"] else {
            throw XCTSkip("Set QWEN_ANE_VOICE to a prepared reference directory")
        }
        let engine = try QwenTestModels.engine()
        let voice = try QwenVoiceFiles(directory: URL(fileURLWithPath: path))
        engine.options.capPauses = false
        var captured: QwenRender?
        let result = try engine.render(text: "La lluvia caía sobre la plaza mientras cerrábamos la biblioteca.",
                                       voice: voice, seed: 7, language: "es", onRawRender: { captured = $0 })
        let raw = try XCTUnwrap(captured)
        XCTAssertEqual(raw.samples.count, raw.frames * 1920)
        XCTAssertEqual(raw.codes.count, raw.frames * 16)
        XCTAssertEqual(result.generatedFrames, raw.frames)
        XCTAssertEqual(result.codes, Array(raw.codes.prefix(result.frames * 16)))
        XCTAssertFalse(QwenTalkSession.derailed(result))
        for (schedule, overlap) in [([12], false), ([1], true), ([4, 8, 12], true)] {
            let pcm = try engine.decodeCodesForDiagnostics(raw.codes, voice: voice,
                                                          chunkFrames: schedule, overlap: overlap)
            XCTAssertEqual(pcm.count, raw.samples.count, "lost samples for \(schedule)")
            XCTAssertTrue(pcm.allSatisfy(\.isFinite))
            let signal = raw.samples.reduce(0.0) { $0 + Double($1) * Double($1) }
            let error = zip(pcm, raw.samples).reduce(0.0) { $0 + pow(Double($1.0) - Double($1.1), 2) }
            let snr = 10 * log10(max(1e-30, signal) / max(1e-30, error))
            print("Fixed-code replay schedule=\(schedule) overlap=\(overlap) SNR=\(snr) exact=\(pcm == raw.samples)")
            XCTAssertGreaterThan(snr, 45, "chunk grouping changed the waveform materially")
        }
    }
}
