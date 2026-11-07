// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Testing
@testable import Nodus_Reader

@Suite("Saving the narration position")
struct ProgressSaveThrottleTests {
    /// Which of the saves, made `seconds` after the first, go through.
    private func saves(_ steps: [(playing: Bool, seconds: TimeInterval)]) -> [Bool] {
        var throttle = ProgressSaveThrottle()
        let start = Date()
        return steps.map { throttle.shouldSave(playing: $0.playing, now: start.addingTimeInterval($0.seconds)) }
    }

    @Test func playingSavesAtMostEveryFifteenSeconds() {
        #expect(saves([(true, 0), (true, 3), (true, 14), (true, 15)]) == [true, false, false, true])
    }

    @Test func pausesAndOtherStopsAlwaysSave() {
        // After a pause, the first sentence played saves again at once.
        #expect(saves([(true, 0), (false, 1), (true, 2)]) == [true, true, true])
    }
}
