// SPDX-License-Identifier: AGPL-3.0-only
import DesignSystem
import Foundation
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct ReaderPageInfo: Equatable {
    var pageIndex: Int = 0
    var pageCount: Int = 0
    var chapterIndex: Int = 0
    var chapterTitle: String = ""
    var pageIndexInChapter: Int = 0
    var pagesInChapter: Int = 0
}

/// Owns TextKit pagination and turns a chapter list into page-curl (iOS) or a
/// two-page spread (Mac). Highlights are drawn as an overlay, so narration and
/// annotations never invalidate the pagination.
struct PaginatedReaderContent: View {
    let book: Book
    let chapters: [ExtractedChapter]
    let style: ReaderPageStyle
    let theme: ReaderTheme
    let buildKey: String
    let initialChapterIndex: Int
    let initialFraction: Double
    let annotations: [Annotation]
    let narrationChapterIndex: Int?
    let narrationSentenceRange: NSRange?
    let narrationWordRange: NSRange?
    let columns: Int
    let followNarration: Bool
    var onWordTap: (Int, Int) -> Void
    var onHighlight: (Int, NSRange, AnnotationColor) -> Void
    var onNote: (Int, NSRange) -> Void

    @Binding var pageIndex: Int
    @Binding var pageInfo: ReaderPageInfo
    @Binding var firstPageByChapter: [Int: Int]
    @Binding var pageStep: Int
    @Binding var readerPages: [ReaderPage]

    @State private var pages: [ReaderPage] = []
    @State private var generation = UUID()
    @State private var builtKey = ""
    @State private var isBuilding = true

    var body: some View {
        GeometryReader { proxy in
            let columnCount = max(1, columns)
            let separator: CGFloat = columnCount > 1 ? 1 : 0
            let availableWidth = (proxy.size.width - separator) / CGFloat(columnCount)
            // Keep a comfortable measure on iPad/Mac instead of stretching
            // lines across the whole window. The page host uses the same
            // margin, so selection and tap coordinates stay aligned.
            let pageStyle: ReaderPageStyle = {
                var adjusted = style
                if columnCount == 1 {
                    let readableWidth: CGFloat = 720
                    adjusted.margin = max(style.margin, (availableWidth - readableWidth) / 2)
                }
                return adjusted
            }()
            let pageWidth = availableWidth - pageStyle.margin * 2
            let pageHeight = proxy.size.height - 16
            let size = CGSize(width: max(120, pageWidth), height: max(120, pageHeight))
            let key = "\(buildKey)-\(Int(size.width))x\(Int(size.height))-\(Int(pageStyle.margin))-\(columnCount)-\(chapters.count)"

            ZStack {
                if isBuilding || pages.isEmpty {
                    ProgressView()
                        .tint(Color(theme.accent))
                } else {
                    #if os(macOS)
                    MacPageSpread(
                        pages: pages,
                        pageIndex: $pageIndex,
                        style: pageStyle,
                        highlightsProvider: highlights(for:),
                        onWordTap: onWordTap,
                        onHighlight: onHighlight,
                        onNote: onNote
                    )
                    #else
                    PageCurlReader(
                        pages: pages,
                        pageIndex: $pageIndex,
                        generation: generation,
                        style: pageStyle,
                        highlightsProvider: highlights(for:),
                        onWordTap: onWordTap,
                        onHighlight: onHighlight,
                        onNote: onNote
                    )
                    #endif
                }
            }
            .task(id: key) {
                await buildPages(size: size, key: key, columns: columnCount, style: pageStyle)
            }
        }
        .onChange(of: pageIndex) { _, _ in
            updatePageInfo()
        }
        .onChange(of: narrationSentenceRange) { _, _ in
            followNarrationIfNeeded()
        }
        .onAppear {
            pageStep = columns
            updatePageInfo()
        }
        .onChange(of: columns) { _, newValue in
            pageStep = max(1, newValue)
        }
    }

    private func buildPages(size: CGSize, key: String, columns: Int,
                            style: ReaderPageStyle) async {
        guard key != builtKey || pages.isEmpty else { return }
        isBuilding = true
        // Let the progress indicator appear before TextKit does its work.
        await Task.yield()

        let previousChapter = pageInfo.chapterIndex
        let previousPagesInChapter = pageInfo.pagesInChapter
        let previousPageInChapter = pageInfo.pageIndexInChapter
        let hadPages = !pages.isEmpty
        let previousFraction = previousPagesInChapter > 1
            ? Double(previousPageInChapter) / Double(previousPagesInChapter - 1)
            : 0

        let paginated = TextPaginator.paginate(chapters: chapters, style: style, pageSize: size)
        guard !paginated.pages.isEmpty else {
            pages = []
            isBuilding = false
            builtKey = key
            return
        }

        let targetChapter = hadPages ? previousChapter : initialChapterIndex
        let targetFraction = hadPages ? previousFraction : max(0, min(initialFraction, 1))

        pages = paginated.pages
        readerPages = paginated.pages
        firstPageByChapter = paginated.firstPageByChapter
        generation = UUID()
        builtKey = key
        pageStep = max(1, columns)

        let chapter = min(max(targetChapter, 0), max(chapters.count - 1, 0))
        let start = paginated.firstPageByChapter[chapter] ?? 0
        let chapterPages = pages.filter { $0.chapterIndex == chapter }.count
        let offset = Int((targetFraction * Double(max(chapterPages - 1, 0))).rounded())
        let clampedOffset = min(max(offset, 0), max(chapterPages - 1, 0))
        pageIndex = min(start + clampedOffset, pages.count - 1)
        isBuilding = false
        updatePageInfo()
        followNarrationIfNeeded()
    }

    private func pagesInChapter(_ book: PaginatedBook, chapter: Int) -> Int {
        book.pages.filter { $0.chapterIndex == chapter }.count
    }

    private func updatePageInfo() {
        guard pages.indices.contains(pageIndex) else {
            pageInfo = ReaderPageInfo()
            return
        }
        let page = pages[pageIndex]
        let info = ReaderPageInfo(pageIndex: pageIndex, pageCount: pages.count,
                                  chapterIndex: page.chapterIndex,
                                  chapterTitle: page.chapterTitle,
                                  pageIndexInChapter: page.pageIndexInChapter,
                                  pagesInChapter: page.pagesInChapter)
        if pageInfo != info {
            pageInfo = info
        }
    }

    private func followNarrationIfNeeded() {
        guard followNarration,
              let narrationChapterIndex,
              let narrationSentenceRange,
              !pages.isEmpty else { return }
        guard pageInfo.chapterIndex != narrationChapterIndex ||
              !pageContainsCurrentNarration() else { return }
        if let index = pages.firstIndex(where: { page in
            page.chapterIndex == narrationChapterIndex &&
            narrationSentenceRange.location >= page.chapterStartOffset &&
            narrationSentenceRange.location < max(page.chapterEndOffset, page.chapterStartOffset + 1)
        }) {
            pageIndex = index
        }
    }

    private func pageContainsCurrentNarration() -> Bool {
        guard let narrationChapterIndex, let narrationSentenceRange,
              pages.indices.contains(pageIndex) else { return false }
        let page = pages[pageIndex]
        return page.chapterIndex == narrationChapterIndex &&
            narrationSentenceRange.location >= page.chapterStartOffset &&
            narrationSentenceRange.location < max(page.chapterEndOffset, page.chapterStartOffset + 1)
    }

    private func highlights(for page: ReaderPage) -> ReaderPageHighlights {
        var spans: [ReaderPageHighlightSpan] = []

        for annotation in annotations where annotation.chapterIndex == page.chapterIndex {
            let range = NSRange(location: max(0, annotation.startOffset),
                                length: max(0, annotation.endOffset - annotation.startOffset))
            guard range.length > 0 else { continue }
            spans.append(ReaderPageHighlightSpan(
                range: range,
                fill: PlatformColor(hex: annotation.color.fillHex, alpha: style.isDark ? 0.45 : 0.65),
                underline: PlatformColor(hex: annotation.color.underlineHex),
                underlineWidth: 1.5,
                rounded: true
            ))
        }

        if narrationChapterIndex == page.chapterIndex {
            if let sentence = narrationSentenceRange,
               let trimmed = trimmedHighlightRange(sentence, chapterIndex: page.chapterIndex) {
                spans.append(ReaderPageHighlightSpan(
                    range: trimmed,
                    fill: PlatformColor(theme.narration),
                    underline: nil,
                    underlineWidth: 0,
                    rounded: true
                ))
            }
            if let word = narrationWordRange,
               let trimmed = trimmedHighlightRange(word, chapterIndex: page.chapterIndex) {
                spans.append(ReaderPageHighlightSpan(
                    range: trimmed,
                    fill: style.isDark
                        ? PlatformColor(hex: 0xC4B5FD, alpha: 0.55)
                        : PlatformColor(hex: 0x7C3AED, alpha: 0.38),
                    underline: style.isDark ? PlatformColor(hex: 0xC4B5FD) : PlatformColor(hex: 0x7C3AED),
                    underlineWidth: 2,
                    rounded: true
                ))
            }
        }
        return ReaderPageHighlights(spans: spans)
    }

    /// A highlight that ends in whitespace paints through the end of the line in
    /// TextKit. Trim it so the sentence background stops at the last glyph.
    private func trimmedHighlightRange(_ range: NSRange, chapterIndex: Int) -> NSRange? {
        guard chapters.indices.contains(chapterIndex) else { return nil }
        let text = chapters[chapterIndex].text as NSString
        var start = min(max(range.location, 0), text.length)
        var end = min(NSMaxRange(range), text.length)
        while end > start, Self.isHighlightWhitespace(text.character(at: end - 1)) {
            end -= 1
        }
        while start < end, Self.isHighlightWhitespace(text.character(at: start)) {
            start += 1
        }
        guard end > start else { return nil }
        return NSRange(location: start, length: end - start)
    }

    private static func isHighlightWhitespace(_ character: unichar) -> Bool {
        character == 0x20 || character == 0x09 || character == 0x0A ||
            character == 0x0D || character == 0xA0 || character == 0x2028 ||
            character == 0x2029
    }
}
