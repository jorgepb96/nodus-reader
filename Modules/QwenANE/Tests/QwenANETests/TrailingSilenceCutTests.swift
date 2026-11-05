import XCTest
@testable import QwenANE

final class TrailingSilenceCutTests: XCTestCase {
    private func tone(_ s: Double) -> [Float] { (0..<Int(s * 24000)).map { 0.3 * sinf(Float($0) * 0.05) } }
    private func quiet(_ s: Double) -> [Float] { [Float](repeating: 0, count: Int(s * 24000)) }
    private func frames(_ w: [Float]) -> ([Float], Int) {
        let n = w.count / 1920; return (Array(w[0..<(n * 1920)]), n)
    }

    func testMidLinePauseIsNeverACutPoint() {
        let (w, n) = frames(tone(2) + quiet(2) + tone(2) + quiet(0.5))
        XCTAssertEqual(trailingSilenceCut(w, frames: n), n, "speech after a long pause must be kept")
    }

    func testLongTrueTrailingSilenceIsCut() {
        let (w, n) = frames(tone(2) + quiet(2) + tone(2) + quiet(4))
        let cut = trailingSilenceCut(w, frames: n)
        XCTAssertLessThan(cut, n)
        XCTAssertGreaterThanOrEqual(cut * 1920, Int(6 * 24000), "all speech kept")
    }

    @available(iOS 18.0, macOS 15.0, *)
    func testTrimmingRunawaySilenceStillRejectsTakeAndPreventsCarry() {
        for stop in [QwenStopReason.maxTokens, .contextFull] {
            var r = render(tone(2) + quiet(4), stop: stop)
            let generated = r.frames
            r.trimSilence(capPauses: true)
            XCTAssertLessThan(r.frames, generated)
            XCTAssertEqual(r.generatedFrames, generated)
            XCTAssertEqual(r.stopReason, stop)
            XCTAssertTrue(QwenTalkSession.derailed(r), "trimming cannot make an unfinished take acceptable")
            XCTAssertFalse(QwenReadRules.carries(frames: r.frames, derailed: QwenTalkSession.derailed(r)))
            XCTAssertEqual(r.codes.count, r.frames * 16)
        }
    }

    func testNaturalEndingCanTrimSilenceWithoutLosingSpeech() {
        var r = render(tone(2) + quiet(4), stop: .eos)
        let speech = Array(r.samples.prefix(2 * 24000))
        r.trimSilence(capPauses: false)
        XCTAssertEqual(r.stopReason, .trailingSilence)
        XCTAssertEqual(Array(r.samples.prefix(speech.count)), speech)
        XCTAssertEqual(r.samples.count, r.frames * 1920)
        XCTAssertEqual(r.codes.count, r.frames * 16)
    }

    private func render(_ samples: [Float], stop: QwenStopReason) -> QwenRender {
        let (pcm, n) = frames(samples)
        var r = QwenRender(samples: pcm, sampleRate: 24000, frames: n,
                           codes: [Int64](repeating: 0, count: n * 16), stopReason: stop,
                           timings: QwenTimings(prompt: 0, prefill: 0, loop: 0, vocoder: 0, vocoderWait: 0, total: 0))
        r.generatedFrames = n
        return r
    }
}
