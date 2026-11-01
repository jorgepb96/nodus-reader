// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// Classifies how the reading position moved since the last update, so the
/// director can tell reading on from browsing.
struct PositionTracker: Sendable {
    /// Forward moves up to this many UTF-16 units are reading (about a page
    /// turn or a few sentences); farther moves are jumps.
    static let naturalForward = 1_500
    /// Backward moves up to this far (previous sentence, page back) are ignored.
    static let smallBack = 1_500

    private(set) var position: Int?
    private(set) var chapter: Int?

    /// `text` checks whether a paragraph or scene break lies between two
    /// positions (a natural place to change the atmosphere).
    mutating func update(position new: Int, chapter newChapter: Int,
                         text: NSString?) -> (movement: AmbienceDirector.Movement, crossedSite: Bool) {
        defer {
            position = new
            chapter = newChapter
        }
        guard let old = position else { return (.natural, false) }
        let delta = new - old
        let chapterChanged = chapter != nil && chapter != newChapter
        if delta >= 0, delta <= Self.naturalForward {
            let crossed = chapterChanged || (text.map { Self.containsBreak($0, from: old, to: new) } ?? false)
            return (.natural, crossed)
        }
        if delta < 0, -delta <= Self.smallBack, !chapterChanged {
            return (.smallBack, false)
        }
        return (.jump(chapterChanged: chapterChanged), true)
    }

    static func containsBreak(_ text: NSString, from: Int, to: Int) -> Bool {
        guard to > from, from >= 0, to <= text.length else { return false }
        return text.range(of: "\n", range: NSRange(location: from, length: to - from)).location != NSNotFound
    }
}

/// Seconds Immersive Audio has actually been playing. Pauses, the app in the
/// background and closed books do not count, so a book left open overnight
/// does not "use up" the minimum time on an atmosphere.
struct EngagedClock: Sendable {
    private(set) var engaged: TimeInterval = 0
    private var lastTick: TimeInterval?
    /// Gaps longer than this (the app suspended) are not counted.
    static let maximumGap: TimeInterval = 5

    mutating func tick(at wall: TimeInterval, playing: Bool) -> TimeInterval {
        if playing, let last = lastTick {
            engaged += min(max(wall - last, 0), Self.maximumGap)
        }
        lastTick = playing ? wall : nil
        return engaged
    }
}
