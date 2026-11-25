// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// The chapters CarPlay lists for the book being narrated. Only chapters with
/// something to say are listed, each starting at its first sentence; a car
/// shows a limited number of rows, so a long book lists the chapters around
/// the one playing.
struct CarPlayChapters: Equatable {
    struct Entry: Equatable {
        let chapterIndex: Int
        let title: String
        let firstSentence: Int
    }

    let entries: [Entry]
    /// Position in `entries` of the chapter playing, if it is listed.
    let currentEntry: Int?

    init(chapters: [ExtractedChapter], sentences: [NarrationSentence],
         currentChapter: Int, limit: Int) {
        var firstSentence: [Int: Int] = [:]
        for sentence in sentences where firstSentence[sentence.chapterIndex] == nil {
            firstSentence[sentence.chapterIndex] = sentence.id
        }
        let all = chapters.indices.compactMap { index -> Entry? in
            guard let first = firstSentence[index] else { return nil }
            let title = chapters[index].title.trimmingCharacters(in: .whitespacesAndNewlines)
            return Entry(chapterIndex: index,
                         title: title.isEmpty ? String(localized: "Chapter \(index + 1)") : title,
                         firstSentence: first)
        }
        let window = Self.window(count: all.count,
                                 around: all.lastIndex { $0.chapterIndex <= currentChapter } ?? 0,
                                 limit: limit)
        entries = Array(all[window])
        currentEntry = entries.firstIndex { $0.chapterIndex == currentChapter }
    }

    /// `limit` consecutive positions of `count`, with `center` in the middle
    /// when it can be.
    static func window(count: Int, around center: Int, limit: Int) -> Range<Int> {
        let limit = max(limit, 1)
        guard count > limit else { return 0..<count }
        let start = min(max(center - limit / 2, 0), count - limit)
        return start..<(start + limit)
    }
}
