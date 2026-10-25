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
    static func paginate(chapters: [ExtractedChapter], style: ReaderPageStyle,
                         pageSize: CGSize) -> PaginatedBook {
        guard pageSize.width > 120, pageSize.height > 120 else { return .empty }
        var pages: [ReaderPage] = []
        var firstPageByChapter: [Int: Int] = [:]

        for (chapterIndex, chapter) in chapters.enumerated() {
            if Task.isCancelled { return .empty }
            let header = EditorialChapterHeader(eyebrow: "CHAPTER \(chapterIndex + 1)",
                                                title: chapter.title, style: style)
            let full = NSMutableAttributedString(attributedString: header.attributed)
            let body = NSMutableAttributedString(string: chapter.text, attributes: style.bodyAttributes)
            full.append(body)
            let prefixLength = header.length
            let chapterLength = (chapter.text as NSString).length
            guard full.length > prefixLength else { continue }

            let storage = NSTextStorage(attributedString: full)
            let layout = NSLayoutManager()
            storage.addLayoutManager(layout)
            let chapterPagesStart = pages.count
            var location = 0
            var pageInChapter = 0

            while location < full.length {
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
                let ns = full.string as NSString
                while characterRange.length > 0,
                      ns.character(at: characterRange.location) == 10,
                      location + characterRange.length < full.length {
                    characterRange.location += 1
                    characterRange.length -= 1
                }
                guard characterRange.length > 0 else { break }
                let pageString = full.attributedSubstring(from: characterRange)
                pages.append(ReaderPage(
                    id: pages.count,
                    chapterIndex: chapterIndex,
                    chapterTitle: chapter.title,
                    chapterLength: chapterLength,
                    prefixLength: prefixLength,
                    fullRange: characterRange,
                    attributed: pageString,
                    pageIndexInChapter: pageInChapter,
                    pagesInChapter: 0
                ))
                pageInChapter += 1
                location = NSMaxRange(characterRange)
            }

            if !pages.isEmpty {
                firstPageByChapter[chapterIndex] = chapterPagesStart
                let count = pages.count - chapterPagesStart
                if count > 0 {
                    for index in chapterPagesStart..<pages.count {
                        let old = pages[index]
                        pages[index] = ReaderPage(
                            id: old.id, chapterIndex: old.chapterIndex,
                            chapterTitle: old.chapterTitle, chapterLength: old.chapterLength,
                            prefixLength: old.prefixLength, fullRange: old.fullRange,
                            attributed: old.attributed,
                            pageIndexInChapter: old.pageIndexInChapter,
                            pagesInChapter: count
                        )
                    }
                }
            }
        }
        return PaginatedBook(pages: pages, firstPageByChapter: firstPageByChapter)
    }
}
