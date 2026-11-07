// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// While narration plays the text follows the spoken word. A finger resting
/// on the text (a long press about to select) or a selection must not have
/// the text move or the page turn under it: the selection landed elsewhere
/// or never formed. Following resumes shortly after the finger lifts and the
/// selection is dismissed.
struct ReaderFollowHold {
    static let afterTouch: TimeInterval = 1.5

    private var touches = 0
    private var lastTouchEnd: Date?

    mutating func touchBegan() {
        touches += 1
    }

    mutating func touchEnded(at date: Date) {
        touches = max(0, touches - 1)
        if touches == 0 { lastTouchEnd = date }
    }

    func allowsFollow(now: Date, hasSelection: Bool) -> Bool {
        guard touches == 0, !hasSelection else { return false }
        guard let lastTouchEnd else { return true }
        return now.timeIntervalSince(lastTouchEnd) >= Self.afterTouch
    }
}
