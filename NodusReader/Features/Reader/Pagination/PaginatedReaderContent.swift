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
    /// Only the chapter on screen is laid out yet (the rest of the book is
    /// still being paginated), so book-wide page numbers are not known.
    var isProvisional = false
}

/// Owns TextKit pagination and turns a chapter list into page-curl (iOS), a
/// two-page spread (Mac) or a continuous scroll (vertical column or horizontal
/// strip of columns). Continuous modes reuse the same TextKit slices, so
/// progress, bookmarks, narration follow and highlights work identically.
/// Highlights are drawn as an overlay, so narration and annotations never
/// invalidate the pagination.
struct PaginatedReaderContent: View {
    let book: Book
    let chapters: [ExtractedChapter]
    let style: ReaderPageStyle
    let theme: ReaderTheme
    let typography: ReaderTypography
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
    /// Layout signature and style of the pages on screen, and whether they
    /// cover the whole book or only the chapter laid out first.
    @State private var shownLayout = ""
    @State private var shownStyle: ReaderPageStyle?
    @State private var shownComplete = false
    /// Changes only when page breaks change, so the scroll view is rebuilt
    /// at the right slice instead of animating across the book.
    @State private var layoutGeneration = UUID()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var pageTurn: PageTurnStyle {
        reduceMotion && typography.pageTurn == .curl ? .slide : typography.pageTurn
    }

    private var flow: ReadingFlow { typography.flow }

    /// Pages shown side by side: the Mac spread in paged mode, otherwise one.
    private var visibleColumns: Int {
        flow == .paged ? max(1, columns) : 1
    }

    /// Width of one column in the horizontal strip: a readable measure, never
    /// wider than the window.
    private static func stripColumnWidth(for width: CGFloat) -> CGFloat {
        min(width, 560)
    }

    var body: some View {
        GeometryReader { proxy in
            let columnCount = visibleColumns
            let separator: CGFloat = columnCount > 1 ? 1 : 0
            let availableWidth = flow == .scrollHorizontal
                ? Self.stripColumnWidth(for: proxy.size.width)
                : (proxy.size.width - separator) / CGFloat(columnCount)
            // Keep a comfortable measure on iPad/Mac instead of stretching
            // lines across the whole window. The page host uses the same
            // margin, so selection and tap coordinates stay aligned.
            let pageStyle: ReaderPageStyle = {
                var adjusted = style
                if columnCount == 1, flow != .scrollHorizontal {
                    let readableWidth: CGFloat = 720
                    adjusted.margin = max(style.margin, (availableWidth - readableWidth) / 2)
                }
                return adjusted
            }()
            let pageWidth = availableWidth - pageStyle.margin * 2
            // Continuous slices are page-sized, so "Page x of y", bookmarks
            // and progress mean the same thing in every mode.
            let pageHeight = proxy.size.height - 16
            let size = CGSize(width: max(120, pageWidth), height: max(120, pageHeight))
            let key = "\(buildKey)-\(flow.rawValue)-\(Int(size.width))x\(Int(size.height))-\(Int(pageStyle.margin))-\(columnCount)-\(chapters.count)"

            ZStack {
                if pages.isEmpty {
                    ProgressView()
                        .controlSize(.large)
                        .tint(Color(theme.accent))
                        .accessibilityLabel("Laying out pages")
                } else if flow.isContinuous {
                    ContinuousReaderContent(
                        pages: pages,
                        axis: flow == .scrollHorizontal ? .horizontal : .vertical,
                        columnWidth: flow == .scrollHorizontal ? availableWidth : nil,
                        columnHeight: flow == .scrollHorizontal ? proxy.size.height : nil,
                        pageIndex: $pageIndex,
                        style: pageStyle,
                        highlightsProvider: highlights(for:),
                        onWordTap: onWordTap,
                        onHighlight: onHighlight,
                        onNote: onNote
                    )
                    .id(layoutGeneration)
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
                        onNote: onNote,
                        turn: pageTurn
                    )
                    // The transition style is fixed when the page controller
                    // is created, so a page-turn or Reduce Motion change
                    // rebuilds it.
                    .id(pageTurn)
                    #endif
                }
            }
            // GeometryReader places content at its top-leading corner; the
            // first-open progress indicator belongs in the middle of the page.
            .frame(width: proxy.size.width, height: proxy.size.height)
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
        .onChange(of: narrationChapterIndex) { _, _ in
            followNarrationIfNeeded()
        }
        .onChange(of: followNarration) { _, _ in
            followNarrationIfNeeded()
        }
        .onAppear {
            pageStep = visibleColumns
            updatePageInfo()
        }
        .onChange(of: visibleColumns) { _, newValue in
            pageStep = max(1, newValue)
        }
    }

    /// Rebuilds the pages for a new size, font or theme without ever blanking
    /// the reader: the current pages stay on screen until their replacement
    /// is ready. A colour-only change recolours the pages in place; a layout
    /// change lays out the chapter on screen first (a fraction of a second)
    /// and then the whole book, every chapter in parallel. A newer change
    /// cancels this pass through `.task(id:)`.
    private func buildPages(size: CGSize, key: String, columns: Int,
                            style: ReaderPageStyle) async {
        guard key != builtKey || pages.isEmpty else { return }
        pageStep = max(1, columns)
        let chapters = self.chapters
        let layout = "\(book.id.uuidString)-\(chapters.count)-" +
            TextPaginator.layoutSignature(style, pageSize: size)

        if layout == shownLayout, shownComplete, !pages.isEmpty {
            if shownStyle != style {
                let current = PaginatedBook(pages: pages, firstPageByChapter: firstPageByChapter)
                let recolored = await Self.offMain {
                    TextPaginator.recolored(current, chapters: chapters, style: style)
                }
                guard !Task.isCancelled else { return }
                pages = recolored.pages
                readerPages = recolored.pages
                generation = UUID()
                shownStyle = style
            }
            builtKey = key
            return
        }

        let hadPages = !pages.isEmpty
        let targetChapter = min(max(hadPages ? pageInfo.chapterIndex : initialChapterIndex, 0),
                                max(chapters.count - 1, 0))
        let targetFraction: Double = {
            guard hadPages else { return max(0, min(initialFraction, 1)) }
            return pageInfo.pagesInChapter > 1
                ? Double(pageInfo.pageIndexInChapter) / Double(pageInfo.pagesInChapter - 1)
                : 0
        }()

        // 1. The chapter on screen, so the new layout appears at once.
        var known: [Int: [ReaderPage]] = [:]
        var showedFirst = false
        if chapters.indices.contains(targetChapter) {
            let chapter = chapters[targetChapter]
            let first = await Self.offMain {
                TextPaginator.paginateChapter(chapter, index: targetChapter, style: style, pageSize: size)
            }
            guard !Task.isCancelled else { return }
            if !first.isEmpty {
                known[targetChapter] = first
                if chapters.count > 1 {
                    show(PaginatedBook(pages: first, firstPageByChapter: [targetChapter: 0]),
                         chapter: targetChapter, fraction: targetFraction,
                         layout: layout, style: style, complete: false)
                    showedFirst = true
                }
            }
        }

        // 2. The whole book.
        let paginated = await Self.offMain {
            await TextPaginator.paginateConcurrently(chapters: chapters, style: style,
                                                     pageSize: size, known: known)
        }
        guard !Task.isCancelled else { return }
        if showedFirst, pageInfo.isProvisional {
            // Keep the exact page the reader turned to while the book was
            // being laid out: the chapter's pages are identical.
            show(paginated, chapter: pageInfo.chapterIndex, pageInChapter: pageInfo.pageIndexInChapter,
                 layout: layout, style: style, complete: true)
        } else {
            show(paginated, chapter: targetChapter, fraction: targetFraction,
                 layout: layout, style: style, complete: true)
        }
        builtKey = key
    }

    private func show(_ paginated: PaginatedBook, chapter: Int, fraction: Double,
                      layout: String, style: ReaderPageStyle, complete: Bool) {
        let chapterPages = paginated.pages.lazy.filter { $0.chapterIndex == chapter }.count
        let offset = Int((fraction * Double(max(chapterPages - 1, 0))).rounded())
        show(paginated, chapter: chapter, pageInChapter: offset,
             layout: layout, style: style, complete: complete)
    }

    private func show(_ paginated: PaginatedBook, chapter: Int, pageInChapter: Int,
                      layout: String, style: ReaderPageStyle, complete: Bool) {
        pages = paginated.pages
        readerPages = paginated.pages
        firstPageByChapter = paginated.firstPageByChapter
        generation = UUID()
        layoutGeneration = UUID()
        shownLayout = layout
        shownStyle = style
        shownComplete = complete
        guard !paginated.pages.isEmpty else {
            pageIndex = 0
            updatePageInfo()
            return
        }
        let start = paginated.firstPageByChapter[chapter] ?? 0
        let chapterPages = paginated.pages.lazy.filter { $0.chapterIndex == chapter }.count
        let offset = min(max(pageInChapter, 0), max(chapterPages - 1, 0))
        pageIndex = min(start + offset, paginated.pages.count - 1)
        updatePageInfo()
        followNarrationIfNeeded()
    }

    /// TextKit layout of a whole book takes seconds on long books; it runs off
    /// the main actor (each pass owns its own text storage and layout manager)
    /// so the reader stays responsive, and is cancelled with the calling task.
    private static func offMain<T>(_ work: @escaping @Sendable () async -> T) async -> T {
        let job = Task.detached(priority: .userInitiated) { await work() }
        return await withTaskCancellationHandler {
            await job.value
        } onCancel: {
            job.cancel()
        }
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
                                  pagesInChapter: page.pagesInChapter,
                                  isProvisional: !shownComplete)
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
                        ? PlatformColor(hex: NodusHex.lavender, alpha: 0.55)
                        : PlatformColor(hex: NodusHex.violet, alpha: 0.38),
                    underline: style.isDark ? PlatformColor(hex: NodusHex.lavender) : PlatformColor(hex: NodusHex.violet),
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
