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
}
