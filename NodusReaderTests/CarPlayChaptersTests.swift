// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Testing
@testable import Nodus_Reader

@Suite("CarPlay chapter list")
struct CarPlayChaptersTests {
    private func book(chapters titles: [String], sentencesPerChapter counts: [Int]) -> ([ExtractedChapter], [NarrationSentence]) {
        let chapters = titles.enumerated().map { ExtractedChapter(id: $0.offset, title: $0.element, text: "Text.") }
        var sentences: [NarrationSentence] = []
        for (chapter, count) in counts.enumerated() {
            for offset in 0..<count {
                sentences.append(NarrationSentence(id: sentences.count, chapterIndex: chapter, text: "Sentence.",
                                                   chapterOffset: offset * 10, chapterLength: 9))
            }
        }
        return (chapters, sentences)
    }

    @Test func listsChaptersWithTextAtTheirFirstSentence() {
        let (chapters, sentences) = book(chapters: ["One", "Blank", "Three"], sentencesPerChapter: [2, 0, 3])
        let list = CarPlayChapters(chapters: chapters, sentences: sentences, currentChapter: 2, limit: 100)
        #expect(list.entries.map(\.title) == ["One", "Three"])
        #expect(list.entries.map(\.firstSentence) == [0, 2])
        #expect(list.currentEntry == 1)
    }

    @Test func untitledChaptersAreNumbered() {
        let (chapters, sentences) = book(chapters: ["  "], sentencesPerChapter: [1])
        let list = CarPlayChapters(chapters: chapters, sentences: sentences, currentChapter: 0, limit: 100)
        #expect(list.entries.first?.title == String(localized: "Chapter \(1)"))
    }

    @Test func aLongBookListsTheChaptersAroundTheOnePlaying() {
        let count = 2_400
        let (chapters, sentences) = book(chapters: (1...count).map { "Chapter \($0)" },
                                         sentencesPerChapter: Array(repeating: 1, count: count))
        let middle = CarPlayChapters(chapters: chapters, sentences: sentences, currentChapter: 1_000, limit: 100)
        #expect(middle.entries.count == 100)
        #expect(middle.entries.first?.chapterIndex == 950)
        #expect(middle.currentEntry == 50)

        let end = CarPlayChapters(chapters: chapters, sentences: sentences, currentChapter: count - 1, limit: 100)
        #expect(end.entries.last?.chapterIndex == count - 1)
        #expect(end.entries.count == 100)
    }

    @Test func windowStaysInsideTheList() {
        #expect(CarPlayChapters.window(count: 5, around: 2, limit: 10) == 0..<5)
        #expect(CarPlayChapters.window(count: 10, around: 0, limit: 4) == 0..<4)
        #expect(CarPlayChapters.window(count: 10, around: 9, limit: 4) == 6..<10)
    }
}
