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
    /// A very long book: only the chapters around the reader are laid out,
    /// so `pageIndex` and `pageCount` count the pages of that window and the
    /// position in the book is `bookFraction`.
    var isPartial = false
    /// How much of the book lies before the end of the last page on screen.
    var bookFraction: Double = 0
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
    /// Find results by chapter, and the one the reader is on.
    let searchRanges: [Int: [NSRange]]
    let currentSearchMatch: ReaderSearchMatch?
    let columns: Int
    let followNarration: Bool
    let usesNarrationScrolling: Bool
    var onWordTap: (Int, Int) -> Void
    var onHighlight: (Int, NSRange, AnnotationColor) -> Void
    var onNote: (Int, NSRange) -> Void

    @Binding var navigationTarget: ReaderNavigationTarget?
    @Binding var narrationReturnTarget: ReaderNavigationTarget?
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
    @State private var appliedNavigationID: UUID?
    @State private var extent: ReaderBookExtent?
    /// Very long books: the chapters the pages on screen cover. Nil when the
    /// pages cover the whole book.
    @State private var shownWindow: Range<Int>?
    /// Very long books: the chapter the reader (or the narration it follows)
    /// reached at the edge of the window, or outside it. Setting it lays out
    /// the chapters around that one.
    @State private var windowAnchor: Int?
    /// The first or last chapter laid out, while the reader is in it. It
    /// becomes the anchor only once they have stayed there for a moment: a
    /// continuous column reports its first slices for an instant while it is
    /// being built, which is not the reader arriving at the edge.
    @State private var edgeChapter: Int?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var pageTurn: PageTurnStyle {
        reduceMotion && typography.pageTurn == .curl ? .slide : typography.pageTurn
    }

    private var flow: ReadingFlow { usesNarrationScrolling ? .scrollVertical : typography.flow }

    private var narrationScrollRange: NSRange? {
        guard followNarration, typography.autoScrollNarration, flow == .scrollVertical,
              navigationTarget == nil else { return nil }
        return narrationWordRange ?? narrationSentenceRange
    }

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
                    // About 70 characters per line at any text size.
                    let readableWidth = min(760, style.fontSize * 34)
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
                        narrationChapterIndex: narrationChapterIndex,
                        narrationRange: narrationScrollRange,
                        narrationReturnTarget: $narrationReturnTarget,
                        narrationBottomPadding: usesNarrationScrolling ? proxy.size.height * 0.6 : 0,
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
            // A requested chapter takes priority over the background book
            // layout, so a long book does not make contents navigation wait.
            .task(id: "\(key)-\(navigationTarget?.id.uuidString ?? "")-\(windowAnchor.map(String.init) ?? "")") {
                await buildPages(size: size, key: key, columns: columnCount, style: pageStyle)
            }
        }
        .onChange(of: pageIndex) { _, _ in
            updatePageInfo()
        }
        .task(id: edgeChapter) {
            await requestWindow(aroundEdge: edgeChapter)
        }
        .onChange(of: navigationTarget) { _, _ in
            applyNavigationTarget()
            if navigationTarget == nil { followNarrationIfNeeded() }
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
        let chapters = self.chapters
        let layout = "\(book.id.uuidString)-\(chapters.count)-" +
            TextPaginator.layoutSignature(style, pageSize: size)
        let bookExtent: ReaderBookExtent
        if let extent, extent.lengths.count == chapters.count {
            bookExtent = extent
        } else {
            bookExtent = await Self.offMain { ReaderBookExtent(chapters: chapters) }
            guard !Task.isCancelled else { return }
            extent = bookExtent
        }
        if bookExtent.isLarge {
            pageStep = max(1, columns)
            await buildWindow(size: size, key: key, style: style, layout: layout, extent: bookExtent)
            return
        }
        guard key != builtKey || pages.isEmpty else { return }
        pageStep = max(1, columns)

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
        let targetChapter = min(max(navigationTarget?.chapterIndex ?? (hadPages ? pageInfo.chapterIndex : initialChapterIndex), 0),
                                max(chapters.count - 1, 0))
        let targetFraction: Double = {
            if let target = navigationTarget, appliedNavigationID != target.id {
                return min(max(target.fraction, 0), 1)
            }
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

    /// A very long book: lays out the chapter the reader is going to and
    /// then the chapters around it, never the whole book. The window follows
    /// the reader: when they reach its first or last chapter (`windowAnchor`)
    /// it grows in that direction, reusing every chapter already laid out, so
    /// the pages on screen keep their place.
    private func buildWindow(size: CGSize, key: String, style: ReaderPageStyle,
                             layout: String, extent: ReaderBookExtent) async {
        let chapters = self.chapters
        let hadPages = !pages.isEmpty
        let sameLayout = hadPages && layout == shownLayout
        let pendingTarget = navigationTarget.flatMap { appliedNavigationID == $0.id ? nil : $0 }
        let requestedAnchor = windowAnchor
        // An anchor left by an earlier position is ignored.
        let anchor = requestedAnchor.flatMap { chapter in
            (hadPages && chapter == pageInfo.chapterIndex) ||
                (followNarration && chapter == narrationChapterIndex) ? chapter : nil
        }
        let focus = min(max(pendingTarget?.chapterIndex ?? anchor
                                ?? (hadPages ? pageInfo.chapterIndex : initialChapterIndex), 0),
                        max(chapters.count - 1, 0))

        if sameLayout, shownComplete, let window = shownWindow,
           window.contains(focus), !extent.isEdge(focus, of: window) {
            // The chapters on screen already surround it.
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
            if windowAnchor != nil, windowAnchor == requestedAnchor { windowAnchor = nil }
            return
        }

        let targetFraction: Double = {
            if let pendingTarget { return min(max(pendingTarget.fraction, 0), 1) }
            guard hadPages else { return max(0, min(initialFraction, 1)) }
            guard focus == pageInfo.chapterIndex, pageInfo.pagesInChapter > 1 else { return 0 }
            return Double(pageInfo.pageIndexInChapter) / Double(pageInfo.pagesInChapter - 1)
        }()

        // Chapters already laid out with this size, font and colours.
        let reusable = sameLayout && shownStyle == style
        var known: [Int: [ReaderPage]] = [:]
        if reusable {
            for page in pages { known[page.chapterIndex, default: []].append(page) }
        }
        let shown = reusable && shownComplete ? shownWindow : nil
        let window = extent.window(around: focus, extending: shown)
        let appends = shown.map { $0.lowerBound == window.lowerBound } ?? false

        // 1. The chapter the reader is going to, so it appears at once.
        if known[focus] == nil, chapters.indices.contains(focus) {
            let chapter = chapters[focus]
            let first = await Self.offMain {
                TextPaginator.paginateChapter(chapter, index: focus, style: style, pageSize: size)
            }
            guard !Task.isCancelled else { return }
            if !first.isEmpty {
                known[focus] = first
                if window.count > 1 {
                    show(PaginatedBook(pages: first, firstPageByChapter: [focus: 0]),
                         chapter: focus, fraction: targetFraction,
                         layout: layout, style: style, complete: false, window: focus..<(focus + 1))
                }
            }
        }

        // 2. The chapters around it.
        let reused = known
        let paginated = await Self.offMain {
            await TextPaginator.paginateConcurrently(chapters: chapters, style: style, pageSize: size,
                                                     known: reused, only: window)
        }
        guard !Task.isCancelled else { return }
        if layout == shownLayout, !pages.isEmpty, window.contains(pageInfo.chapterIndex) {
            // Keep the exact page the reader is on (they may have turned
            // pages meanwhile): that chapter's pages are identical.
            show(paginated, chapter: pageInfo.chapterIndex, pageInChapter: pageInfo.pageIndexInChapter,
                 layout: layout, style: style, complete: true, window: window, keepsPageIndexes: appends)
        } else {
            show(paginated, chapter: focus, fraction: targetFraction,
                 layout: layout, style: style, complete: true, window: window)
        }
        builtKey = key
        // Served, unless the reader reached another edge meanwhile.
        if windowAnchor != nil, windowAnchor == requestedAnchor { windowAnchor = nil }
    }

    private func show(_ paginated: PaginatedBook, chapter: Int, fraction: Double,
                      layout: String, style: ReaderPageStyle, complete: Bool,
                      window: Range<Int>? = nil) {
        let chapterPages = paginated.pages.lazy.filter { $0.chapterIndex == chapter }.count
        let offset = Int((fraction * Double(max(chapterPages - 1, 0))).rounded())
        show(paginated, chapter: chapter, pageInChapter: offset,
             layout: layout, style: style, complete: complete, window: window)
    }

    /// - Parameter keepsPageIndexes: the new pages only add chapters after
    ///   the ones on screen, so a continuous column keeps scrolling instead
    ///   of being rebuilt.
    private func show(_ paginated: PaginatedBook, chapter: Int, pageInChapter: Int,
                      layout: String, style: ReaderPageStyle, complete: Bool,
                      window: Range<Int>? = nil, keepsPageIndexes: Bool = false) {
        pages = paginated.pages
        readerPages = paginated.pages
        firstPageByChapter = paginated.firstPageByChapter
        generation = UUID()
        if !keepsPageIndexes { layoutGeneration = UUID() }
        shownLayout = layout
        shownStyle = style
        shownComplete = complete
        shownWindow = window
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
        if !applyNavigationTarget() {
            followNarrationIfNeeded()
        }
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
        var info = ReaderPageInfo(pageIndex: pageIndex, pageCount: pages.count,
                                  chapterIndex: page.chapterIndex,
                                  chapterTitle: page.chapterTitle,
                                  pageIndexInChapter: page.pageIndexInChapter,
                                  pagesInChapter: page.pagesInChapter,
                                  isProvisional: !shownComplete)
        if shownWindow != nil, let extent {
            let last = pages[min(pageIndex + max(pageStep, 1) - 1, pages.count - 1)]
            info.isPartial = true
            info.bookFraction = extent.fraction(chapter: last.chapterIndex, offset: last.chapterEndOffset)
        }
        if pageInfo != info {
            pageInfo = info
        }
        // The reader reached the first or last chapter laid out: the ones
        // beyond it are laid out before they get to its last page.
        var edge: Int?
        if shownComplete, let window = shownWindow, let extent, extent.isEdge(page.chapterIndex, of: window) {
            edge = page.chapterIndex
        }
        if edgeChapter != edge { edgeChapter = edge }
    }

    private func requestWindow(aroundEdge chapter: Int?) async {
        guard let chapter else { return }
        try? await Task.sleep(for: .milliseconds(350))
        guard !Task.isCancelled, edgeChapter == chapter, shownComplete, pageInfo.chapterIndex == chapter,
              let window = shownWindow, let extent, extent.isEdge(chapter, of: window),
              windowAnchor != chapter else { return }
        windowAnchor = chapter
    }

    /// The narration the reader follows moved to a chapter that is not laid
    /// out (a very long book): lay out the chapters around it.
    private func followNarrationWindowIfNeeded() {
        guard followNarration, navigationTarget == nil, shownComplete,
              let window = shownWindow, let narrationChapterIndex,
              chapters.indices.contains(narrationChapterIndex),
              !window.contains(narrationChapterIndex),
              windowAnchor != narrationChapterIndex else { return }
        windowAnchor = narrationChapterIndex
    }

    /// A chapter can be absent from the provisional pages. Keep the request
    /// until it exists. After applying it, preserve any page turns the reader
    /// makes while full pagination finishes remapping the chapter's pages.
    @discardableResult
    private func applyNavigationTarget() -> Bool {
        guard let target = navigationTarget else { return false }
        guard chapters.indices.contains(target.chapterIndex) else {
            navigationTarget = nil
            return false
        }
        if appliedNavigationID == target.id {
            if shownComplete { navigationTarget = nil }
            return true
        }
        let indices = pages.indices.filter { pages[$0].chapterIndex == target.chapterIndex }
        guard let first = indices.first else { return false }
        let destination: Int
        if let offset = target.characterOffset {
            destination = indices.first { index in
                let page = pages[index]
                return offset >= page.chapterStartOffset &&
                    offset < max(page.chapterEndOffset, page.chapterStartOffset + 1)
            } ?? first
        } else {
            let fraction = min(max(target.fraction, 0), 1)
            let offset = Int((fraction * Double(indices.count - 1)).rounded())
            destination = indices[offset]
        }
        pageIndex = destination
        updatePageInfo()
        if flow.isContinuous, narrationReturnTarget == nil {
            narrationReturnTarget = ReaderNavigationTarget(chapterIndex: target.chapterIndex,
                                                          characterOffset: target.characterOffset ?? pages[destination].chapterStartOffset)
        }
        if flow == .paged { narrationReturnTarget = nil }
        appliedNavigationID = target.id
        if shownComplete { navigationTarget = nil }
        return true
    }

    private func followNarrationIfNeeded() {
        followNarrationWindowIfNeeded()
        // Continuous narration follows the actual line, independently of the
        // slice at the viewport's top edge. Page jumps would fight that scroll.
        if flow == .scrollVertical, typography.autoScrollNarration { return }
        #if os(iOS)
        // Never turn the page under a finger or a selection.
        guard ReaderTextInteraction.allowsFollow else { return }
        #endif
        guard navigationTarget == nil || appliedNavigationID == navigationTarget?.id,
              followNarration,
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
                fill: PlatformColor(hex: annotation.color.pageFill(isDark: style.isDark).hex,
                                    alpha: annotation.color.pageFill(isDark: style.isDark).alpha),
                underline: PlatformColor(hex: annotation.color.underlineHex),
                underlineWidth: 1.5,
                rounded: true
            ))
        }

        for range in searchRanges[page.chapterIndex] ?? []
        where range.location < page.chapterEndOffset && NSMaxRange(range) > page.chapterStartOffset {
            let isCurrent = currentSearchMatch == ReaderSearchMatch(chapterIndex: page.chapterIndex, range: range)
            spans.append(ReaderPageHighlightSpan(
                range: range,
                fill: isCurrent
                    ? PlatformColor(hex: NodusHex.searchCurrent, alpha: style.isDark ? 0.55 : 0.9)
                    : PlatformColor(hex: style.isDark ? NodusHex.searchMatchDark : NodusHex.searchMatch,
                                    alpha: style.isDark ? 0.45 : 0.55),
                underline: isCurrent ? PlatformColor(hex: NodusHex.searchCurrentUnderline) : nil,
                underlineWidth: isCurrent ? 2 : 0,
                rounded: true
            ))
        }

        if narrationChapterIndex == page.chapterIndex {
            spans += ReaderPageHighlights.narration(
                sentence: narrationSentenceRange.flatMap { trimmedHighlightRange($0, chapterIndex: page.chapterIndex) },
                word: narrationWordRange.flatMap { trimmedHighlightRange($0, chapterIndex: page.chapterIndex) },
                style: typography.narrationHighlight,
                theme: theme
            )
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
