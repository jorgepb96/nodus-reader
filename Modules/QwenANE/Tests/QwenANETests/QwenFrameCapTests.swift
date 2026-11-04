import XCTest
@testable import QwenANE

/// The runaway frame cap that follows the voice (`QwenReadRules.frameCap`): pure, synthetic numbers.
final class QwenFrameCapTests: XCTestCase {
    func testNoPaceIsTheFixedSixPerTokenCap() {
        XCTAssertEqual(QwenReadRules.frameCap(textTokens: 44, voiceFramesPerToken: nil), 264)   // 21.1 s
        XCTAssertEqual(QwenReadRules.frameCap(textTokens: 5, voiceFramesPerToken: nil), 75)     // floor
        XCTAssertEqual(QwenReadRules.frameCap(textTokens: 10_000, voiceFramesPerToken: nil), 4096)
        XCTAssertEqual(QwenReadRules.frameCap(textTokens: 0, voiceFramesPerToken: nil), 75)
        XCTAssertEqual(effectiveMaxTokens(44), 264)
        XCTAssertEqual(effectiveMaxTokens(44, maxTokens: 100), 100)
    }

    func testFastVoiceKeepsTodaysCap() {
        // 2 x 2.5 frames a token is under 6: the old cap stands.
        XCTAssertEqual(QwenReadRules.frameCap(textTokens: 44, voiceFramesPerToken: 3), 264)
        XCTAssertEqual(QwenReadRules.frameCap(textTokens: 44, voiceFramesPerToken: 2.5), 264)
    }

    func testSlowVoiceGetsTwiceItsPace() {
        // 4.5 frames a token -> 9 a token -> 396 frames (31.7 s) for 44 tokens.
        XCTAssertEqual(QwenReadRules.frameCap(textTokens: 44, voiceFramesPerToken: 4.5), 396)
        // rounded up: 2 x 3.31 x 44 = 291.28 -> 292
        XCTAssertEqual(QwenReadRules.frameCap(textTokens: 44, voiceFramesPerToken: 3.31), 292)
    }

    func testPaceIsClampedAndWindowBinds() {
        XCTAssertEqual(QwenReadRules.frameCap(textTokens: 44, voiceFramesPerToken: 100), 2 * 20 * 44)
        XCTAssertEqual(QwenReadRules.frameCap(textTokens: 44, voiceFramesPerToken: .infinity), 264)
        XCTAssertEqual(QwenReadRules.frameCap(textTokens: 44, voiceFramesPerToken: 4.5, window: 300), 300)
        XCTAssertEqual(QwenReadRules.frameCap(textTokens: 44, voiceFramesPerToken: nil, window: 40), 40)
        XCTAssertEqual(QwenReadRules.frameCap(textTokens: 44, voiceFramesPerToken: nil, window: -5), 0)
        XCTAssertEqual(QwenReadRules.frameCap(textTokens: 10_000, voiceFramesPerToken: 20), 4096)
        XCTAssertEqual(QwenReadRules.maxFramesPerToken, 40)
    }

    func testVoicePaceFromTheReference() {
        XCTAssertEqual(QwenReadRules.voiceFramesPerToken(referenceFrames: 150, referenceTokens: 30), 5)
        XCTAssertEqual(QwenReadRules.voiceFramesPerToken(referenceFrames: 30, referenceTokens: 30), 3)    // clamped up
        XCTAssertEqual(QwenReadRules.voiceFramesPerToken(referenceFrames: 900, referenceTokens: 2), 20)   // clamped down
        XCTAssertNil(QwenReadRules.voiceFramesPerToken(referenceFrames: 0, referenceTokens: 30))
        XCTAssertNil(QwenReadRules.voiceFramesPerToken(referenceFrames: 150, referenceTokens: 0))
    }

    /// A backend whose own clamp is `max(75, tokens x factor)` with the factor at `maxFramesPerToken`
    /// never cuts under the rule's cap (the iPhone's MLX fork).
    func testMaxFramesPerTokenNeverBindsUnderTheRule() {
        for n in 0...300 {
            for pace in stride(from: 3.0, through: 20.0, by: 0.37) {
                let cap = QwenReadRules.frameCap(textTokens: n, voiceFramesPerToken: pace)
                XCTAssertLessThanOrEqual(cap, max(75, n * QwenReadRules.maxFramesPerToken))
            }
        }
    }
}
