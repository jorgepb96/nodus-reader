import Foundation
import XCTest
@testable import QwenANE

/// `QwenReadRules`, `QwenCarry` and `QwenTalkSession.renderBreak`: the one shared way to render a talk
/// break (split, one session, join, a report per part). The render test needs QWEN_ANE_MODELS.
@available(macOS 15.0, iOS 18.0, *)
final class QwenBreakTests: XCTestCase {
    // MARK: split

    func testTextThatFitsIsOnePartUnchanged() {
        XCTAssertEqual(QwenReadRules.split("  Good evening.  "), ["Good evening."])
        XCTAssertEqual(QwenReadRules.split(""), [])
    }

    func testSentencesAreGroupedUpToTheLimit() {
        let text = "One two three. Four five six! Seven eight nine? Ten eleven twelve."
        let parts = QwenReadRules.split(text, maxPartChars: 30)
        XCTAssertEqual(parts, ["One two three. Four five six!", "Seven eight nine?", "Ten eleven twelve."])
    }

    func testALongSentenceSplitsAtClausesThenWords() {
        let clause = "the rain came down on the tin roof all night long"
        let text = "\(clause), \(clause); \(clause)."
        let parts = QwenReadRules.split(text, maxPartChars: 60)
        XCTAssertTrue(parts.allSatisfy { $0.count <= 60 }, "\(parts)")
        XCTAssertEqual(parts.joined(separator: " "), text)
        let words = String(repeating: "word ", count: 50).trimmingCharacters(in: .whitespaces)
        let wordParts = QwenReadRules.split(words, maxPartChars: 40)
        XCTAssertTrue(wordParts.allSatisfy { $0.count <= 40 })
        XCTAssertEqual(wordParts.joined(separator: " "), words)
    }

    func testEveryWordSurvivesAndNoPartIsLongerThanTheLimit() {
        let text = """
            Good evening, night owls. You're locked into the midnight frequency, where the coffee is strong and \
            the tempo stays low. "Tonight," he said, "we start slow." Then we climb... toward something brighter, \
            as the hours pass; and nobody minds. ¿Qué tal? ¡Muy bien!
            """
        let parts = QwenReadRules.split(text, maxPartChars: 80)
        XCTAssertGreaterThan(parts.count, 1)
        XCTAssertTrue(parts.allSatisfy { !$0.isEmpty && $0.count <= 80 }, "\(parts)")
        XCTAssertEqual(parts.joined(separator: " ").split(separator: " "), text.split(separator: " "))
        XCTAssertTrue(parts.contains { $0.hasPrefix("\"Tonight,\" he said, \"we start slow.\"") }, "\(parts)")
    }

    // MARK: rules

    func testDerailedAndBadnessAreTheSessionRules() {
        XCTAssertFalse(QwenReadRules.derailed(hitFrameCap: false, longestPause: 2.0))
        XCTAssertTrue(QwenReadRules.derailed(hitFrameCap: false, longestPause: 2.01))
        XCTAssertTrue(QwenReadRules.derailed(hitFrameCap: true, longestPause: 0))
        XCTAssertLessThan(QwenReadRules.badness(hitFrameCap: false, longestPause: 9),
                          QwenReadRules.badness(hitFrameCap: true, longestPause: 0))
        XCTAssertEqual(QwenReadRules.maxRedraws, 2)
        XCTAssertEqual(QwenTalkSession.maxPauseSeconds, QwenReadRules.maxPauseSeconds)
    }

    func testOnlyACleanUnflaggedTakeCarries() {
        XCTAssertTrue(QwenReadRules.carries(frames: 10, derailed: false))
        XCTAssertFalse(QwenReadRules.carries(frames: 0, derailed: false))
        XCTAssertFalse(QwenReadRules.carries(frames: 10, derailed: true))
        XCTAssertFalse(QwenReadRules.carries(frames: 10, derailed: false, flagged: true))
    }

    func testCarryKeepsTheLastCarryablePartAndIgnoresCancels() {
        var c = QwenCarry<String>()
        XCTAssertNil(c.context)
        c.partEnded(cancelled: false, take: "part 1")
        XCTAssertEqual(c.context, "part 1")
        c.partEnded(cancelled: true, take: nil)
        XCTAssertEqual(c.context, "part 1", "a cancel changes nothing")
        c.partEnded(cancelled: false, take: nil)
        XCTAssertNil(c.context, "a derailed part is never continued; the next starts from the reference")
        c.partEnded(cancelled: false, take: "part 3")
        c.enabled = false
        XCTAssertNil(c.context)
    }

    func testKeptFramesCutsOnlyTrueTrailingSilence() {
        let frame = 1920
        let loud = [Float](repeating: 0.3, count: 10 * frame)
        let quiet = [Float](repeating: 0, count: 40 * frame) // 3.2 s
        XCTAssertEqual(QwenReadRules.keptFrames(samples24k: loud, frames: 10), 10)
        // 1.5 s of the silence is kept (19 frames), as the streaming stop would have.
        let kept = QwenReadRules.keptFrames(samples24k: loud + quiet, frames: 50)
        XCTAssertEqual(kept, 10 + 19, accuracy: 1)
        // Speech after a long pause: nothing is cut.
        XCTAssertEqual(QwenReadRules.keptFrames(samples24k: loud + quiet + loud, frames: 60), 60)
        XCTAssertEqual(QwenReadRules.keptFrames(samples24k: [], frames: 5), 0)
    }

    // MARK: render

    func testRenderBreakJoinsThePartsAndReportsEach() throws {
        try QwenTestModels.requireSlow()
        let e = try QwenTestModels.engine()
        let voice = try e.loadVoice(named: "jeff")
        let parts = QwenTalkSessionTests.parts
        let s = QwenTalkSession(engine: e, voice: voice, seed: 42)
        var logged: [QwenBreakPart] = []
        let b = try s.renderBreak(parts: parts, gapSeconds: 0.15, onPart: { logged.append($0) })
        XCTAssertEqual(b.parts.count, 2)
        XCTAssertEqual(logged, b.parts)
        XCTAssertEqual(b.parts[0].contextFrames, 0)
        XCTAssertGreaterThan(b.parts[1].contextFrames, 0)
        for p in b.parts {
            let t = try XCTUnwrap(p.timings, "part \(p.index + 1) carries its engine stage timings")
            XCTAssertGreaterThan(t.loop, 0)
            XCTAssertGreaterThan(t.total, 0)
        }
        let partSamples = b.parts.map { Int(($0.audioSeconds * 24000).rounded()) }.reduce(0, +)
        XCTAssertEqual(b.samples.count, partSamples + 3600)
        var streamed: [Float] = []
        let s2 = QwenTalkSession(engine: e, voice: voice, seed: 42)
        let b2 = try s2.renderBreak(parts: parts, onAudio: { streamed += $0 })
        XCTAssertTrue(b2.samples.isEmpty)
        XCTAssertFalse(streamed.isEmpty)
    }

    func testAnotherLineBetweenPartsLeavesTheBreakUnchanged() async throws {
        // The iPhone hands the engine to a "Hey DJ" reply between a break's parts (beforePart). The break's own
        // stream (carry, sampler) must not notice: same seed, same frames as an uninterrupted render.
        try QwenTestModels.requireSlow()
        let e = try QwenTestModels.engine()
        let voice = try e.loadVoice(named: "sonny-vale")
        let other = try e.loadVoice(named: "benson")
        let parts = QwenTalkSessionTests.parts
        let plain = try QwenTalkSession(engine: e, voice: voice, seed: 42).renderBreak(parts: parts)
        var hooks: [Int] = []
        let interrupted = try await QwenTalkSession(engine: e, voice: voice, seed: 42).renderBreak(parts: parts, beforePart: { i in
            hooks.append(i)
            _ = try QwenTalkSession(engine: e, voice: other, seed: 7).renderBreak(parts: ["One moment, let me check that for you."])
        })
        XCTAssertEqual(hooks, [1], "the hook runs between parts, never before the first")
        XCTAssertEqual(interrupted.parts.map(\.frames), plain.parts.map(\.frames), "the break is frame-for-frame the same")
        XCTAssertEqual(interrupted.samples.count, plain.samples.count)
    }
}
