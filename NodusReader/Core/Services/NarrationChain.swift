// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// Gapless narration: the next sentence is queued on the player behind the one playing
/// when it is already made, so there is no stop–schedule–start gap between sentences.
enum NarrationChain: Equatable {
    case none
    /// Queue the next sentence after `silence` seconds.
    case chain(silence: TimeInterval)

    /// A short breath where the text starts a new paragraph.
    static let paragraphPause: TimeInterval = 0.2

    /// Whether to queue `next` behind `current`. Never across chapters: the chapter
    /// change (and the end-of-chapter sleep timer) keeps its own path.
    static func plan(current: NarrationSentence, next: NarrationSentence, chapterText: String,
                     nextReady: Bool, stopsAtChapterEnd: Bool) -> NarrationChain {
        guard nextReady, next.chapterIndex == current.chapterIndex, next.id == current.id + 1 else { return .none }
        if stopsAtChapterEnd, next.chapterIndex != current.chapterIndex { return .none }
        let text = chapterText as NSString
        let gapStart = min(current.chapterOffset + current.chapterLength, text.length)
        let gapEnd = min(max(next.chapterOffset, gapStart), text.length)
        let gap = text.substring(with: NSRange(location: gapStart, length: gapEnd - gapStart))
        return .chain(silence: gap.contains(where: \.isNewline) ? paragraphPause : 0)
    }
}

/// The player's clock keeps running across queued sentences; the sentence playing
/// starts `offset` seconds into it.
struct NarrationTimeline: Equatable {
    private(set) var offset: TimeInterval = 0

    /// Seconds of the current sentence already heard.
    func heard(rendered: TimeInterval, latency: TimeInterval) -> TimeInterval {
        rendered - latency - offset
    }

    mutating func advance(past duration: TimeInterval, silence: TimeInterval) {
        offset += duration + silence
    }

    mutating func reset() {
        offset = 0
    }
}

/// What the end of a sentence's audio does to narration.
///
/// The end is reported by the player once the audio has been heard, which can be
/// after a pause has been pressed: the last few hundred milliseconds of a sentence
/// are still in the output (longer over Bluetooth) when the reader pauses. That end
/// must still move the cursor on, or the queued sentence plays on resume while the
/// highlight stays one sentence behind until the book is reopened.
enum NarrationSentenceEnd: Equatable {
    /// A stale report (narration stopped or restarted since) or nothing is playing.
    case ignore
    /// The engine stopped under a playing sentence (a route or device change).
    case engineStopped
    /// The book's last sentence ended.
    case finishBook
    /// The next sentence is already queued behind this one: move the cursor to it.
    case advanceChained
    /// Nothing is queued: move to the next sentence and speak it (on resume, when paused).
    case advance

    static func resolve(isCurrent: Bool, isPlaying: Bool, isPaused: Bool, engineRunning: Bool,
                        hasNext: Bool, nextIsChained: Bool) -> NarrationSentenceEnd {
        guard isCurrent, isPlaying || isPaused else { return .ignore }
        // A paused engine is not running either: that is not a stopped engine.
        if !isPaused, !engineRunning { return .engineStopped }
        guard hasNext else { return .finishBook }
        return nextIsChained ? .advanceChained : .advance
    }
}
