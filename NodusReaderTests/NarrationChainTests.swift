// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Testing
@testable import Nodus_Reader

private let chapter = "First sentence. Second one.\n\nNew paragraph here. Last."

private func sentence(_ id: Int, _ text: String, chapter index: Int = 0) -> NarrationSentence {
    let location = (chapter as NSString).range(of: text).location
    return NarrationSentence(id: id, chapterIndex: index, text: text, chapterOffset: location,
                             chapterLength: (text as NSString).length)
}

@Suite("Gapless narration chain")
struct NarrationChainTests {
    let first = sentence(0, "First sentence.")
    let second = sentence(1, "Second one.")
    let third = sentence(2, "New paragraph here.")

    @Test func chainsWithinAParagraphWithoutSilence() {
        #expect(NarrationChain.plan(current: first, next: second, chapterText: chapter, nextReady: true,
                                    stopsAtChapterEnd: false) == .chain(silence: 0))
    }

    @Test func paragraphBreakAddsAShortSilence() {
        #expect(NarrationChain.plan(current: second, next: third, chapterText: chapter, nextReady: true,
                                    stopsAtChapterEnd: false) == .chain(silence: NarrationChain.paragraphPause))
        #expect(NarrationChain.paragraphPause == 0.2)
    }

    @Test func waitsWhenTheNextSentenceIsNotReady() {
        #expect(NarrationChain.plan(current: first, next: second, chapterText: chapter, nextReady: false,
                                    stopsAtChapterEnd: false) == .none)
    }

    @Test func neverChainsAcrossChapters() {
        let other = sentence(3, "Last.", chapter: 1)
        #expect(NarrationChain.plan(current: first, next: other, chapterText: chapter, nextReady: true,
                                    stopsAtChapterEnd: false) == .none)
    }

    @Test func timelineSubtractsWhatAlreadyPlayed() {
        var timeline = NarrationTimeline()
        #expect(timeline.heard(rendered: 1.5, latency: 0.1) == 1.4)
        // A 3 s sentence and a 0.2 s pause played before the chained one.
        timeline.advance(past: 3, silence: 0.2)
        #expect(abs(timeline.heard(rendered: 4.0, latency: 0.1) - 0.7) < 1e-9)
        timeline.reset()
        #expect(timeline.offset == 0)
    }
}
