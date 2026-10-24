// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// One paginated page. `fullRange` is a range in the chapter string that includes
/// the editorial header; `chapterOffset` maps a local page index back to the
/// original chapter text so annotations and narration keep stable positions.
struct ReaderPage: Identifiable, Equatable {
    let id: Int
    let chapterIndex: Int
    let chapterTitle: String
    let chapterLength: Int
    let prefixLength: Int
    let fullRange: NSRange
    let attributed: NSAttributedString
    let pageIndexInChapter: Int
    let pagesInChapter: Int

    var chapterStartOffset: Int {
        max(0, fullRange.location - prefixLength)
    }

    var chapterEndOffset: Int {
        min(chapterLength, max(0, NSMaxRange(fullRange) - prefixLength))
    }

    func chapterOffset(forLocalIndex index: Int) -> Int? {
        let fullIndex = fullRange.location + index
        let offset = fullIndex - prefixLength
        guard offset >= 0, offset < chapterLength else { return nil }
        return offset
    }

    func localRange(forChapterRange range: NSRange) -> NSRange? {
        let start = range.location + prefixLength - fullRange.location
        let end = start + range.length
        guard end > start, start >= 0, end <= attributed.length else { return nil }
        return NSRange(location: start, length: range.length)
    }
}

struct PaginatedBook {
    var pages: [ReaderPage]
    var firstPageByChapter: [Int: Int]

    static let empty = PaginatedBook(pages: [], firstPageByChapter: [:])
}
