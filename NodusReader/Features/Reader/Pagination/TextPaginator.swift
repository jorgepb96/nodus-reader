// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Paginates chapter text with TextKit. The same attributed string is sliced into
/// pages, so selection, word offsets and annotations map back to the chapter text.
/// Safe to call off the main thread: every call creates its own TextKit objects.
enum TextPaginator {
    /// The style values that move page breaks. Colours do not: a theme change
    /// only recolours the existing pages (`recolored`).
    static func layoutSignature(_ style: ReaderPageStyle, pageSize: CGSize) -> String {
        "\(Int(pageSize.width))x\(Int(pageSize.height))-\(style.fontSize)-\(style.lineSpacing)-" +
            "\(style.margin)-\(style.justified)-\(style.useSerif)-\(style.weightIndex)"
    }

    static func paginate(chapters: [ExtractedChapter], style: ReaderPageStyle,
                         pageSize: CGSize) -> PaginatedBook {
        var pagesByChapter: [[ReaderPage]] = []
        for index in chapters.indices {
            if Task.isCancelled { return .empty }
            pagesByChapter.append(paginateChapter(chapters[index], index: index, style: style, pageSize: pageSize))
        }
        return assemble(pagesByChapter)
    }

    /// Chapters are independent TextKit layouts, so a long book is laid out on
    /// every core at once. `known` holds chapters already paginated with the
    /// same style and size (the chapter on screen), which are reused.
    static func paginateConcurrently(chapters: [ExtractedChapter], style: ReaderPageStyle,
                                     pageSize: CGSize,
                                     known: [Int: [ReaderPage]] = [:]) async -> PaginatedBook {
        let results = await withTaskGroup(of: (Int, [ReaderPage]).self) { group in
            var next = 0
            var results = known
            let width = max(2, ProcessInfo.processInfo.activeProcessorCount)
            func addNext() {
                while next < chapters.count, known[next] != nil { next += 1 }
                guard next < chapters.count else { return }
                let index = next
                let chapter = chapters[index]
                next += 1
                group.addTask {
                    if Task.isCancelled { return (index, []) }
                    return (index, paginateChapter(chapter, index: index, style: style, pageSize: pageSize))
                }
            }
            for _ in 0..<width { addNext() }
            for await (index, pages) in group {
                results[index] = pages
                addNext()
            }
            return results
        }
        guard !Task.isCancelled else { return .empty }
        return assemble(chapters.indices.map { results[$0] ?? [] })
    }

    /// The pages of one chapter, with ids starting at zero. `assemble` gives
    /// them their book-wide ids.
    static func paginateChapter(_ chapter: ExtractedChapter, index chapterIndex: Int,
                                style: ReaderPageStyle, pageSize: CGSize) -> [ReaderPage] {
        guard pageSize.width > 120, pageSize.height > 120 else { return [] }
        let (full, prefixLength) = chapterString(chapter, index: chapterIndex, style: style)
        let chapterLength = (chapter.text as NSString).length
        guard full.length > prefixLength else { return [] }

        let storage = NSTextStorage(attributedString: full)
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let ns = full.string as NSString
        var pages: [ReaderPage] = []
        var location = 0

        while location < full.length {
            if Task.isCancelled { return [] }
            let container = NSTextContainer(size: pageSize)
            container.lineFragmentPadding = 0
            container.widthTracksTextView = false
            container.heightTracksTextView = false
            layout.addTextContainer(container)
            layout.ensureLayout(for: container)
            let glyphRange = layout.glyphRange(for: container)
            var characterRange = layout.characterRange(forGlyphRange: glyphRange,
                                                       actualGlyphRange: nil)
            if characterRange.length <= 0 { break }
            // Do not let a page begin with a leading newline left by the slice.
            while characterRange.length > 0,
                  ns.character(at: characterRange.location) == 10,
                  location + characterRange.length < full.length {
                characterRange.location += 1
                characterRange.length -= 1
            }
            guard characterRange.length > 0 else { break }
            pages.append(ReaderPage(
                id: pages.count,
                chapterIndex: chapterIndex,
                chapterTitle: chapter.title,
                chapterLength: chapterLength,
                prefixLength: prefixLength,
                fullRange: characterRange,
                attributed: full.attributedSubstring(from: characterRange),
                pageIndexInChapter: pages.count,
                pagesInChapter: 0
            ))
            location = NSMaxRange(characterRange)
        }
        let count = pages.count
        return pages.map { $0.with(id: $0.id, pagesInChapter: count) }
    }

    /// The same pages drawn with another theme's colours. Fonts and sizes are
    /// unchanged, so every page keeps its exact text range.
    static func recolored(_ book: PaginatedBook, chapters: [ExtractedChapter],
                          style: ReaderPageStyle) -> PaginatedBook {
        var current: (chapter: Int, string: NSAttributedString)?
        var pages: [ReaderPage] = []
        pages.reserveCapacity(book.pages.count)
        for page in book.pages {
            if Task.isCancelled { return book }
            guard chapters.indices.contains(page.chapterIndex) else { return book }
            if current?.chapter != page.chapterIndex {
                current = (page.chapterIndex,
                           chapterString(chapters[page.chapterIndex], index: page.chapterIndex, style: style).0)
            }
            guard let full = current?.string, NSMaxRange(page.fullRange) <= full.length else { return book }
            pages.append(page.with(attributed: full.attributedSubstring(from: page.fullRange)))
        }
        return PaginatedBook(pages: pages, firstPageByChapter: book.firstPageByChapter)
    }

    private static func chapterString(_ chapter: ExtractedChapter, index: Int,
                                      style: ReaderPageStyle) -> (NSAttributedString, Int) {
        let header = EditorialChapterHeader(eyebrow: "CHAPTER \(index + 1)",
                                            title: chapter.title, style: style)
        let full = NSMutableAttributedString(attributedString: header.attributed)
        full.append(NSAttributedString(string: chapter.text, attributes: style.bodyAttributes))
        return (full, header.length)
    }

    private static func assemble(_ pagesByChapter: [[ReaderPage]]) -> PaginatedBook {
        var pages: [ReaderPage] = []
        var firstPageByChapter: [Int: Int] = [:]
        for chapterPages in pagesByChapter where !chapterPages.isEmpty {
            firstPageByChapter[chapterPages[0].chapterIndex] = pages.count
            for page in chapterPages {
                pages.append(page.with(id: pages.count, pagesInChapter: page.pagesInChapter))
            }
        }
        return PaginatedBook(pages: pages, firstPageByChapter: firstPageByChapter)
    }
}

private extension ReaderPage {
    func with(id: Int, pagesInChapter: Int) -> ReaderPage {
        ReaderPage(id: id, chapterIndex: chapterIndex, chapterTitle: chapterTitle,
                   chapterLength: chapterLength, prefixLength: prefixLength, fullRange: fullRange,
                   attributed: attributed, pageIndexInChapter: pageIndexInChapter,
                   pagesInChapter: pagesInChapter)
    }

    func with(attributed: NSAttributedString) -> ReaderPage {
        ReaderPage(id: id, chapterIndex: chapterIndex, chapterTitle: chapterTitle,
                   chapterLength: chapterLength, prefixLength: prefixLength, fullRange: fullRange,
                   attributed: attributed, pageIndexInChapter: pageIndexInChapter,
                   pagesInChapter: pagesInChapter)
    }
}
