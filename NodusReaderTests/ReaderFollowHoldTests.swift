// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Testing
@testable import Nodus_Reader

struct ReaderFollowHoldTests {
    let start = Date(timeIntervalSinceReferenceDate: 0)

    @Test func aFingerOnTheTextHoldsTheNarrationScroll() {
        var hold = ReaderFollowHold()
        #expect(hold.allowsFollow(now: start, hasSelection: false))
        hold.touchBegan()
        // A long press waiting to select: the text must not move under it.
        #expect(!hold.allowsFollow(now: start.addingTimeInterval(5), hasSelection: false))
    }

    @Test func followingResumesShortlyAfterTheFingerLifts() {
        var hold = ReaderFollowHold()
        hold.touchBegan()
        hold.touchEnded(at: start)
        #expect(!hold.allowsFollow(now: start.addingTimeInterval(0.5), hasSelection: false))
        #expect(hold.allowsFollow(now: start.addingTimeInterval(ReaderFollowHold.afterTouch), hasSelection: false))
    }

    @Test func aSelectionHoldsTheScrollUntilItIsDismissed() {
        var hold = ReaderFollowHold()
        hold.touchBegan()
        hold.touchEnded(at: start)
        #expect(!hold.allowsFollow(now: start.addingTimeInterval(60), hasSelection: true))
        #expect(hold.allowsFollow(now: start.addingTimeInterval(60), hasSelection: false))
    }

    @Test func overlappingTouchesHoldUntilTheLastLifts() {
        var hold = ReaderFollowHold()
        hold.touchBegan()
        hold.touchBegan()
        hold.touchEnded(at: start)
        #expect(!hold.allowsFollow(now: start.addingTimeInterval(10), hasSelection: false))
        hold.touchEnded(at: start.addingTimeInterval(10))
        #expect(hold.allowsFollow(now: start.addingTimeInterval(12), hasSelection: false))
    }
}
