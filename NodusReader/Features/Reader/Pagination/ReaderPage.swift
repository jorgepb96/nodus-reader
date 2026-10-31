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

    /// The page ends in the middle of a paragraph: its text carries the next
    /// word, hidden, after `fullRange`.
    var continuesParagraph: Bool { attributed.length > fullRange.length }

    func chapterOffset(forLocalIndex index: Int) -> Int? {
        guard index < fullRange.length else { return nil }
        let fullIndex = fullRange.location + index
        let offset = fullIndex - prefixLength
        guard offset >= 0, offset < chapterLength else { return nil }
        return offset
    }

    func localRange(forChapterRange range: NSRange) -> NSRange? {
        let clippedStart = max(range.location, chapterStartOffset)
        let clippedEnd = min(NSMaxRange(range), chapterEndOffset)
        guard clippedEnd > clippedStart else { return nil }
        let start = clippedStart + prefixLength - fullRange.location
        let length = clippedEnd - clippedStart
        guard start >= 0, start + length <= attributed.length else { return nil }
        return NSRange(location: start, length: length)
    }
}

extension NSAttributedString.Key {
    /// Marks the hidden word a page carries from the next page (see
    /// `TextPaginator.pageText`). It is laid out but never shown or measured.
    static let readerContinuation = NSAttributedString.Key("NodusReaderContinuation")
}

extension NSAttributedString {
    /// The length of the text a reader page shows, without its hidden
    /// continuation word.
    var readerVisibleLength: Int {
        var visible = length
        enumerateAttribute(.readerContinuation, in: NSRange(location: 0, length: length)) { value, range, stop in
            if value != nil {
                visible = range.location
                stop.pointee = true
            }
        }
        return visible
    }
}

struct PaginatedBook {
    var pages: [ReaderPage]
    var firstPageByChapter: [Int: Int]

    static let empty = PaginatedBook(pages: [], firstPageByChapter: [:])
}

/// Maps between a text view's local character indexes and the stable anchor
/// space used by annotations, narration and word taps: chapter offsets for
/// paginated and continuous text, canonical page offsets for PDF reflow.
struct ReaderTextMapping {
    var anchorOffset: (Int) -> Int?
    var localRange: (NSRange) -> NSRange?

    /// The anchor range covered by a local selection.
    func anchorRange(for local: NSRange) -> NSRange? {
        guard local.length > 0, let start = anchorOffset(local.location) else { return nil }
        guard let end = anchorOffset(NSMaxRange(local) - 1) else { return nil }
        return NSRange(location: start, length: max(1, end - start + 1))
    }

    static func page(_ page: ReaderPage) -> ReaderTextMapping {
        ReaderTextMapping(anchorOffset: { page.chapterOffset(forLocalIndex: $0) },
                          localRange: { page.localRange(forChapterRange: $0) })
    }

    /// A block whose text starts at `base` in the anchor space.
    static func block(base: Int, length: Int) -> ReaderTextMapping {
        ReaderTextMapping(
            anchorOffset: { index in index >= 0 && index < length ? base + index : nil },
            localRange: { range in
                let start = max(range.location, base)
                let end = min(NSMaxRange(range), base + length)
                guard end > start else { return nil }
                return NSRange(location: start - base, length: end - start)
            }
        )
    }
}
