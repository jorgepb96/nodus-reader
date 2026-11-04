import Foundation
import XCTest
@testable import QwenANE

/// `QwenTalkSession`: one sampler stream per break, each part conditioned on the previous one, a derailed take
/// drawn again. The render tests need QWEN_ANE_MODELS like the rest of this target:
///   QWEN_ANE_MODELS=/path/to/Models swift test --filter QwenTalkSessionTests
@available(macOS 15.0, iOS 18.0, *)
final class QwenTalkSessionTests: XCTestCase {
    private func engine() throws -> QwenANEEngine {
        try QwenTestModels.engine()
    }

    static let parts = [
        "Good evening, and welcome back to the late show on Gloam F M.",
        "That was a slow one, and there is another just like it coming up after the news.",
    ]

    private func take(_ stop: QwenStopReason, pause: Double) -> QwenRender {
        var r = QwenRender(samples: [0], sampleRate: 24000, frames: 1, codes: [], stopReason: stop,
                           timings: QwenTimings(prompt: 0, prefill: 0, loop: 0, vocoder: 0, vocoderWait: 0, total: 0))
        r.silenceBefore = SilenceReport(leading: 0, trailing: 0, longestPause: pause, longestPauseAt: 0,
                                        pausesOverThreshold: 0, speechLevelDB: -20)
        return r
    }

    func testDerailedIsTheCapOrDeadAirInsideTheLine() {
        XCTAssertFalse(QwenTalkSession.derailed(take(.eos, pause: 0.6)))
        XCTAssertFalse(QwenTalkSession.derailed(take(.trailingSilence, pause: 2.0)))
        XCTAssertTrue(QwenTalkSession.derailed(take(.eos, pause: 2.1)))
        XCTAssertTrue(QwenTalkSession.derailed(take(.maxTokens, pause: 0)))
        XCTAssertTrue(QwenTalkSession.derailed(take(.contextFull, pause: 0)))
        XCTAssertLessThan(QwenTalkSession.badness(take(.eos, pause: 5)), QwenTalkSession.badness(take(.maxTokens, pause: 0)))
    }

    func testStableSeedDoesNotDependOnTheProcess() {
        // FNV-1a 64 of "a": a fixed number, unlike Hasher.
        XCTAssertEqual(QwenTalkSession.stableSeed("a"), 0xaf63_dc4c_8601_ec8c)
    }

    func testABreakIsReproducibleAndEachPartContinuesThePreviousOne() throws {
        try QwenTestModels.requireSlow()
        let e = try engine()
        let voice = try e.loadVoice(named: "jeff")
        func renderBreak(carry: Bool) throws -> [QwenRender] {
            let s = QwenTalkSession(engine: e, voice: voice, seed: 42)
            s.carryContext = carry
            s.maxRedraws = 0
            return try Self.parts.map { try s.render($0) }
        }
        let a = try renderBreak(carry: true), b = try renderBreak(carry: true)
        XCTAssertEqual(a.map(\.codes), b.map(\.codes), "same voice, parts and seed: same audio")
        XCTAssertEqual(a[0].contextFrames, 0, "the first part starts from the reference")
        XCTAssertGreaterThan(a[1].contextFrames, 0)
        // The kept frames of part 1 are what part 2 continues.
        XCTAssertEqual(a[1].contextFrames, a[0].frames)
        let cold = try renderBreak(carry: false)
        XCTAssertEqual(cold[1].contextFrames, 0)
        XCTAssertEqual(cold[0].codes, a[0].codes, "the first part does not depend on carrying")
        XCTAssertNotEqual(cold[1].codes, a[1].codes, "carrying the previous part changes what the next one says it with")
    }

    func testAPlainRenderIsUnchangedBySessions() throws {
        try QwenTestModels.requireSlow()
        let e = try engine()
        let voice = try e.loadVoice(named: "jeff")
        let before = try e.render(text: Self.parts[1], voice: voice, seed: 7)
        let s = QwenTalkSession(engine: e, voice: voice, seed: 1)
        _ = try s.render(Self.parts[0])
        let after = try e.render(text: Self.parts[1], voice: voice, seed: 7)
        XCTAssertEqual(before.codes, after.codes)
        XCTAssertEqual(after.contextFrames, 0)
    }
}
