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

/// The length of every chapter of a book (UTF-16). Progress through a very
/// long book is measured in text, and only the chapters around the reader
/// are laid out: a serial novel of 2,000 chapters is some 40,000 pages, which
/// took minutes on every core and stayed in memory.
struct ReaderBookExtent: Equatable, Sendable {
    let lengths: [Int]
    private let starts: [Int]
    let total: Int

    /// Beyond this (War and Peace is about 3.2 million characters) the book
    /// is laid out in a window around the reader instead of whole.
    static let largeBookCharacters = debugOverride("NodusLargeBookCharacters") ?? 4_000_000
    /// Text laid out on each side of the reader's chapter.
    static let windowCharacters = debugOverride("NodusWindowCharacters") ?? 150_000
    /// The window grows as the reader advances, so pages already laid out
    /// keep their place; past this it is centred on the reader again.
    static let maximumWindowCharacters = debugOverride("NodusMaximumWindowCharacters") ?? 1_200_000

    /// `-NodusLargeBookCharacters 20000` and friends: UI tests exercise the
    /// window on a small fixture.
    private static func debugOverride(_ key: String) -> Int? {
        #if DEBUG
        let value = UserDefaults.standard.integer(forKey: key)
        return value > 0 ? value : nil
        #else
        return nil
        #endif
    }

    init(chapters: [ExtractedChapter]) {
        self.init(lengths: chapters.map { $0.text.utf16.count })
    }

    init(lengths: [Int]) {
        self.lengths = lengths
        var starts: [Int] = []
        starts.reserveCapacity(lengths.count)
        var total = 0
        for length in lengths {
            starts.append(total)
            total += length
        }
        self.starts = starts
        self.total = total
    }

    var isLarge: Bool { total > Self.largeBookCharacters }

    func characters(in range: Range<Int>) -> Int {
        guard !range.isEmpty, lengths.indices.contains(range.lowerBound) else { return 0 }
        let end = range.upperBound < lengths.count ? starts[range.upperBound] : total
        return end - starts[range.lowerBound]
    }

    /// The chapters around `chapter`: at least its neighbours, and as many
    /// more on each side as fit in `windowCharacters`.
    func window(around chapter: Int) -> Range<Int> {
        guard !lengths.isEmpty else { return 0..<0 }
        let chapter = min(max(chapter, 0), lengths.count - 1)
        var lower = chapter
        var before = 0
        while lower > 0, lower == chapter || before < Self.windowCharacters {
            lower -= 1
            before += lengths[lower]
        }
        var upper = chapter + 1
        var after = 0
        while upper < lengths.count, upper == chapter + 1 || after < Self.windowCharacters {
            after += lengths[upper]
            upper += 1
        }
        return lower..<upper
    }

    /// The window to lay out when the reader reaches `chapter`: the one on
    /// screen grown to surround it, or a new one centred on it when that
    /// would keep too much of the book laid out or the chapter is elsewhere.
    func window(around chapter: Int, extending shown: Range<Int>?) -> Range<Int> {
        let centred = window(around: chapter)
        guard let shown, shown.contains(chapter) else { return centred }
        let grown = min(shown.lowerBound, centred.lowerBound)..<max(shown.upperBound, centred.upperBound)
        return characters(in: grown) <= Self.maximumWindowCharacters ? grown : centred
    }

    /// The reader is in the first or last chapter laid out and the book
    /// continues beyond it.
    func isEdge(_ chapter: Int, of window: Range<Int>) -> Bool {
        (chapter == window.lowerBound && window.lowerBound > 0) ||
            (chapter == window.upperBound - 1 && window.upperBound < lengths.count)
    }

    /// How much of the book lies before `offset` in `chapter`, from 0 to 1.
    func fraction(chapter: Int, offset: Int) -> Double {
        guard total > 0, lengths.indices.contains(chapter) else { return 0 }
        let position = starts[chapter] + min(max(offset, 0), lengths[chapter])
        return min(1, Double(position) / Double(total))
    }
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
