// SPDX-License-Identifier: AGPL-3.0-only
import DesignSystem
import PDFKit
import SwiftUI

@Observable
final class PDFReflowJob {
    var isWorking = false
    var progress: Double = 0
    var document: PDFReflowDocument?
    var errorMessage: String?
}

/// Finds a query in the reflowed page text, keeping the original page index.
func reflowSearchMatches(for query: String, in document: PDFReflowDocument) -> [ReaderSearchMatch] {
    var matches: [ReaderSearchMatch] = []
    for page in document.pages {
        for match in ReaderSearch.matches(for: query, in: [page.canonicalLayout.text]) {
            matches.append(ReaderSearchMatch(chapterIndex: page.pageIndex, range: match.range))
            if matches.count >= ReaderSearch.maximumMatches { return matches }
        }
    }
    return matches
}

enum PDFReadingMode: String, CaseIterable, Identifiable {
    case original = "Original PDF"
    case intelligent = "Intelligent Reading"
    var id: String { rawValue }
}

// MARK: - Container

struct PDFReaderContainer: View {
    @Environment(LibraryService.self) private var library
    @Environment(ReaderPreferences.self) private var preferences

    let book: Book
    let url: URL
    let theme: ReaderTheme
    @Binding var pdfPageIndex: Int
    @Binding var pdfPageCount: Int
    @Binding var jumpToPage: Int?
    /// Owned by the reader so opening a PDF note can switch to Intelligent
    /// Reading, where notes are shown.
    @Binding var mode: PDFReadingMode
    @Binding var narrationReturnTarget: ReaderNavigationTarget?
    var search: ReaderSearchModel?
    @State private var searchDocument: PDFReflowDocument?
    /// Starts Read & Listen at (page, offset in the page's canonical text).
    var onStartNarration: (Int, Int) -> Void = { _, _ in }
    var onAnnotate: (Int, NSRange, String, AnnotationColor) -> Void = { _, _, _, _ in }

    @State private var width: CGFloat = 0
    /// The original page opens as a sheet when there is no room for the panel.
    @State private var showSourceSheet = false
    @State private var sourceAvailable = false

    private var showsSourceButton: Bool {
        mode == .intelligent && width > 0 && width <= PDFReflowView.sourcePanelMinWidth
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Picker("PDF reading mode", selection: $mode) {
                    ForEach(PDFReadingMode.allCases) { mode in
                        Text(LocalizedStringKey(mode.rawValue)).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                // macOS draws a segmented picker's label beside it.
                .labelsHidden()
                .frame(maxWidth: 360)
                // Beside the picker, so it never covers the first line of text.
                if showsSourceButton {
                    Button {
                        showSourceSheet = true
                    } label: {
                        Image(systemName: "rectangle.righthalf.inset.filled")
                            .font(.system(size: 16))
                            .foregroundStyle(theme.text)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!sourceAvailable)
                    .accessibilityLabel("Original page panel")
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
            .padding(.vertical, showsSourceButton ? 0 : 8)
            .frame(minHeight: 48)
            .background(theme.background)

            Rectangle().fill(theme.line).frame(height: 0.5)

            switch mode {
            case .original:
                PDFKitReader(url: url, pageIndex: $pdfPageIndex, pageCount: $pdfPageCount,
                             jumpToPage: $jumpToPage, background: theme.background,
                             search: search, externalSearch: true)
                    .ignoresSafeArea(edges: .bottom)
            case .intelligent:
                PDFReflowView(book: book, url: url, theme: theme,
                              pdfPageIndex: $pdfPageIndex, jumpToPage: $jumpToPage,
                              narrationReturnTarget: $narrationReturnTarget,
                              showSourceSheet: $showSourceSheet,
                              sourceAvailable: $sourceAvailable,
                              search: search,
                              onStartNarration: onStartNarration,
                              onAnnotate: onAnnotate)
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .task(id: originalSearchKey) { await runOriginalSearch() }
    }

    private var originalSearchKey: String {
        guard mode == .original, let search, search.isPresented else { return "" }
        return search.query + "|" + book.contentHash
    }

    private var searchStore: PDFReflowStore {
        PDFReflowStore(fileStore: library.fileStore)
    }

    /// PDFKit cannot search a garbled text layer. In Original view the search
    /// therefore uses the same reflow page text as Intelligent Reading and
    /// jumps the PDFView to the matching page.
    private func runOriginalSearch() async {
        guard mode == .original, let search, search.isPresented else { return }
        let query = search.query
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            search.setMatches([], startingAt: nil)
            search.isSearching = false
            return
        }
        search.isSearching = true
        var document = searchDocument
        if document == nil {
            document = searchStore.load(bookID: book.id, contentHash: book.contentHash)
        }
        if document == nil {
            let bookID = book.id
            let contentHash = book.contentHash
            let store = searchStore
            let work = Task.detached(priority: .userInitiated) {
                try PDFReflowExtractor.extract(
                    url: url, bookID: bookID, contentHash: contentHash, store: store
                )
            }
            do {
                document = try await withTaskCancellationHandler {
                    try await work.value
                } onCancel: {
                    work.cancel()
                }
            } catch {
                if !Task.isCancelled {
                    search.setMatches([], startingAt: nil)
                    search.isSearching = false
                }
                return
            }
        }
        guard !Task.isCancelled, let document else { return }
        searchDocument = document
        let matches = reflowSearchMatches(for: query, in: document)
        let start = ReaderSearch.firstIndex(in: matches, fromChapter: pdfPageIndex, offset: 0)
        search.setMatches(matches, startingAt: start)
        search.isSearching = false
    }
}

// MARK: - Reflow

/// The analysed page shown for an original page: the page itself, or the
/// nearest analysed one in the direction of travel (blank pages are skipped).
private func reflowPage(for page: Int, forward: Bool, in document: PDFReflowDocument) -> Int? {
    let target = forward
        ? document.pages.first(where: { $0.pageIndex >= page }) ?? document.pages.last
        : document.pages.last(where: { $0.pageIndex <= page }) ?? document.pages.first
    return target?.pageIndex
}

/// Scrolls the reflow to `page`, or the nearest analysed page.
private func scroll(_ proxy: ScrollViewProxy, to page: Int, forward: Bool = false,
                    in document: PDFReflowDocument) {
    guard let target = reflowPage(for: page, forward: forward, in: document) else { return }
    proxy.scrollTo(target, anchor: .top)
}

struct PDFReflowView: View {
    @Environment(LibraryService.self) private var library
    @Environment(ReaderPreferences.self) private var preferences
    @Environment(PlaybackController.self) private var playback

    let book: Book
    let url: URL
    let theme: ReaderTheme
    @Binding var pdfPageIndex: Int
    /// Contents, bookmarks and "go to page" requests from the reader chrome.
    @Binding var jumpToPage: Int?
    @Binding var narrationReturnTarget: ReaderNavigationTarget?
    /// The original page as a sheet, opened from the reader's mode bar.
    @Binding var showSourceSheet: Bool
    @Binding var sourceAvailable: Bool
    /// The reader's find state; the reflow runs it over its canonical page text.
    var search: ReaderSearchModel?
    /// Tap a word: Read & Listen from there (page, canonical offset).
    var onStartNarration: (Int, Int) -> Void = { _, _ in }
    /// A highlight or note on (original page, canonical range, quote, colour).
    var onAnnotate: (Int, NSRange, String, AnnotationColor) -> Void = { _, _, _, _ in }

    @State private var job = PDFReflowJob()
    @State private var showImages = true
    @State private var skipHeaders = true
    /// Page at the top of the reflow, used by the reader bar, the original
    /// page panel and the scrollbar.
    @State private var scrollPosition: Int?

    /// The book's own typography when it has one, the global one otherwise.
    private var typography: ReaderTypography {
        ReaderAppearanceResolver.typography(for: book, preferences: preferences)
    }

    private var store: PDFReflowStore {
        PDFReflowStore(fileStore: library.fileStore)
    }

    /// Narrower readers open the original page as a sheet instead of a panel.
    static let sourcePanelMinWidth: CGFloat = 820

    var body: some View {
        GeometryReader { proxy in
            let showPanel = proxy.size.width > Self.sourcePanelMinWidth
            HStack(spacing: 0) {
                reflowContent(viewportHeight: proxy.size.height)
                    .frame(maxWidth: .infinity)
                if showPanel, let document = job.document {
                    Rectangle().fill(theme.line).frame(width: 0.5)
                    PDFSourcePanel(
                        book: book,
                        url: url,
                        document: document,
                        pageIndex: pdfPageIndex,
                        showImages: $showImages,
                        skipHeaders: $skipHeaders,
                        onGoToPage: { jumpToPage = $0 }
                    )
                    .frame(width: 300)
                }
            }
        }
        .background(theme.background)
        .task { await loadReflow() }
        .onChange(of: job.document != nil, initial: true) { _, loaded in sourceAvailable = loaded }
        .task(id: reflowSearchKey) { await runReflowSearch() }
        .onChange(of: search?.current) { _, _ in
            guard let page = search?.currentMatch?.chapterIndex else { return }
            if page != pdfPageIndex { jumpToPage = page }
        }
        // Playback uses an index into readable chapters; PDF navigation uses
        // the original page ID (blank pages may have no narration chapter).
        .onChange(of: playback.chapterIndex) { _, chapter in
            guard isNarratingHere, playback.mode == .readAndListen,
                  playback.isPlaying, typography.autoScrollNarration,
                  playback.chapters.indices.contains(chapter),
                  let document = job.document else { return }
            // The next page is already on screen and its text follows the
            // narrated line. Snapping it to the top as well fought that follow
            // and made the reflow bounce until the reader scrolled by hand;
            // only a seek to a distant page needs a jump.
            let page = playback.chapters[chapter].id
            let pages = document.pages
            guard let narrated = pages.firstIndex(where: { $0.pageIndex == page }) else { return }
            let visible = pages.lastIndex(where: { $0.pageIndex <= pdfPageIndex }) ?? 0
            if abs(narrated - visible) > 1 { jumpToPage = page }
        }
        .sheet(isPresented: $showSourceSheet) {
            NavigationStack {
                if let document = job.document {
                    PDFSourcePanel(book: book, url: url, document: document,
                                   pageIndex: pdfPageIndex,
                                   showImages: $showImages,
                                   skipHeaders: $skipHeaders,
                                   onGoToPage: { jumpToPage = $0 })
                        .navigationTitle("Original page")
                        .inlineNavigationTitle()
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { showSourceSheet = false }
                            }
                        }
                }
            }
            .readerPresentation(theme)
        }
    }

    @ViewBuilder
    private func reflowContent(viewportHeight: CGFloat) -> some View {
        if job.isWorking {
            VStack(spacing: 14) {
                ProgressView(value: job.progress)
                    .tint(theme.accent)
                    .frame(width: 220)
                Text("Analysing the PDF on this device…")
                    .font(.footnote)
                    .foregroundStyle(theme.muted)
                Text("\(Int(job.progress * 100))%")
                    .font(.caption2)
                    .foregroundStyle(theme.muted)
                    .monospacedDigit()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = job.errorMessage {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 24))
                    .foregroundStyle(theme.accent)
                Text("Intelligent Reading could not be prepared")
                    .font(.system(.headline, design: .serif))
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(theme.muted)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
                Button("Try again") {
                    Task { await loadReflow(force: true) }
                }
                .foregroundStyle(theme.accent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(24)
        } else if let document = job.document {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 22) {
                        ForEach(document.pages) { page in
                            pageView(page)
                                .id(page.pageIndex)
                        }
                        if document.pageCount < document.totalPageCount {
                            Text("This build has analysed the first \(document.pageCount) of \(document.totalPageCount) pages. The original PDF remains available in full.")
                                .font(.caption)
                                .foregroundStyle(theme.muted)
                                .padding(.top, 20)
                        }
                        if document.usedOCR {
                            Text("Some pages had no readable text layer and were read with on-device OCR. OCR can make mistakes; compare with the original page.")
                                .font(.caption2)
                                .foregroundStyle(theme.muted)
                                .padding(.top, 6)
                        }
                    }
                    .frame(maxWidth: 620)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, max(20, typography.margin))
                    .padding(.top, 20)
                    .padding(.bottom, typography.autoScrollNarration && isNarratingHere && playback.mode == .readAndListen
                             ? max(60, viewportHeight * 0.6) : 60)
                    .scrollTargetLayout()
                }
                .scrollPosition(id: $scrollPosition, anchor: .top)
                .scrollIndicators(.hidden)
                .overlay(alignment: .trailing) {
                    if !job.isWorking, document.pages.count > 1 {
                        PDFReflowScrollbar(
                            pages: document.pages.map(\.pageIndex),
                            current: pdfPageIndex,
                            theme: theme
                        ) { page in
                            pdfPageIndex = page
                            jumpToPage = nil
                            scroll(proxy, to: page, in: document)
                        }
                        .padding(.vertical, 74)
                        .padding(.trailing, 4)
                    }
                }
                .onChange(of: scrollPosition) { _, page in
                    guard let page, page != pdfPageIndex else { return }
                    pdfPageIndex = page
                }
                .onAppear {
                    // Switching from Original keeps the reading position.
                    scrollPosition = reflowPage(for: pdfPageIndex, forward: false, in: document)
                    scroll(proxy, to: pdfPageIndex, in: document)
                }
                .onChange(of: jumpToPage, initial: true) { _, target in
                    // One scroll per jump: also writing `scrollPosition` made
                    // two programmatic scrolls race over the lazy page heights.
                    guard let target else { return }
                    let forward = target > pdfPageIndex
                    scroll(proxy, to: target, forward: forward, in: document)
                    pdfPageIndex = reflowPage(for: target, forward: forward, in: document) ?? target
                    jumpToPage = nil
                }
            }
        } else {
            ProgressView().tint(theme.accent)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func pageView(_ page: PDFReflowPage) -> some View {
        let blocks = page.blocks.filter { block in
            (!skipHeaders || !block.isHeaderFooter) &&
            (showImages || (block.kind != .figure && block.kind != .tableImage))
        }
        if !blocks.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                Button {
                    pdfPageIndex = page.pageIndex
                } label: {
                    Eyebrow("Page \(page.pageIndex + 1)", color: theme.accent)
                }
                .buttonStyle(.plain)

                let layout = page.canonicalLayout
                let highlights = pageHighlights(page: page.pageIndex, text: layout.text)
                ForEach(blocks) { block in
                    blockView(block, base: layout.bases[block.id], highlights: highlights)
                }
            }
            .padding(.bottom, 6)
        }
    }

    /// Saved highlights for one original page, located in its canonical text.
    /// This book is being narrated (listening or Read & Listen).
    private var isNarratingHere: Bool {
        playback.activeBook?.id == book.id && playback.mode != .read
    }

    private var narratedPage: Int? {
        guard playback.chapters.indices.contains(playback.chapterIndex) else { return nil }
        return playback.chapters[playback.chapterIndex].id
    }

    private func narrationFollowRange(page: Int, text: String) -> NSRange? {
        guard typography.autoScrollNarration, isNarratingHere,
              playback.mode == .readAndListen, playback.isPlaying,
              narratedPage == page,
              (playback.chapters[playback.chapterIndex].text as NSString).length == (text as NSString).length else { return nil }
        return playback.currentWordChapterRange ?? playback.currentSentenceChapterRange
    }

    /// The narrated sentence and word on `page`, when narration reads this
    /// page's reflowed text (same length as the canonical text).
    private func narrationSpans(page: Int, text: String) -> [ReaderPageHighlightSpan] {
        guard isNarratingHere, narratedPage == page,
              (playback.chapters[playback.chapterIndex].text as NSString).length == (text as NSString).length else { return [] }
        return ReaderPageHighlights.narration(
            sentence: playback.currentSentenceChapterRange,
            word: playback.currentWordChapterRange,
            style: typography.narrationHighlight,
            theme: theme
        )
    }

    private func pageHighlights(page: Int, text: String) -> ReaderPageHighlights {
        let isDark = theme.isDark
        var spans = narrationSpans(page: page, text: text) + book.annotations.filter { $0.chapterIndex == page }.compactMap { annotation -> ReaderPageHighlightSpan? in
            guard let range = ReflowAnnotationAnchor.resolve(start: annotation.startOffset,
                                                             end: annotation.endOffset,
                                                             quote: annotation.quote,
                                                             in: text) else { return nil }
            return ReaderPageHighlightSpan(
                range: range,
                fill: PlatformColor(hex: annotation.color.pageFill(isDark: isDark).hex,
                                    alpha: annotation.color.pageFill(isDark: isDark).alpha),
                underline: PlatformColor(hex: annotation.color.underlineHex),
                underlineWidth: 1.5,
                rounded: true
            )
        }
        if let search, search.isPresented,
           let ranges = search.rangesByChapter[page] {
            for range in ranges {
                let isCurrent = search.currentMatch
                    == ReaderSearchMatch(chapterIndex: page, range: range)
                spans.append(ReaderPageHighlightSpan(
                    range: range,
                    fill: isCurrent
                        ? PlatformColor(hex: NodusHex.searchCurrent,
                                        alpha: isDark ? 0.55 : 0.9)
                        : PlatformColor(hex: isDark ? NodusHex.searchMatchDark : NodusHex.searchMatch,
                                        alpha: isDark ? 0.45 : 0.55),
                    underline: isCurrent ? PlatformColor(hex: NodusHex.searchCurrentUnderline) : nil,
                    underlineWidth: isCurrent ? 2 : 0,
                    rounded: true
                ))
            }
        }
        return ReaderPageHighlights(spans: spans)
    }

    /// Selectable text for one block: Highlight / Add Note in the selection
    /// menu, anchored at `base` in the page's canonical text.
    private func selectableText(_ block: PDFReflowBlock, base: Int?,
                                highlights: ReaderPageHighlights) -> some View {
        let pageIndex = block.pageIndex
        let length = (block.text as NSString).length
        let pageText = pageCanonicalText(pageIndex)
        return SelectableReaderText(
            text: attributedText(for: block),
            mapping: base.map { .block(base: $0, length: length) }
                ?? ReaderTextMapping(anchorOffset: { _ in nil }, localRange: { _ in nil }),
            highlights: highlights,
            accessibilityLabel: nil,
            narrationFollowRange: narrationFollowRange(page: pageIndex, text: pageText),
            scrollRequest: narrationReturnTarget.flatMap { target in
                guard target.chapterIndex == pageIndex, let offset = target.characterOffset else { return nil }
                return ReaderTextScrollRequest(id: target.id, range: NSRange(location: offset, length: 1))
            },
            onScrollRequestHandled: { id in
                if narrationReturnTarget?.id == id { narrationReturnTarget = nil }
            },
            onWordTap: { offset in onStartNarration(pageIndex, offset) },
            onHighlight: { range, color in
                onAnnotate(pageIndex, range, quote(range, in: pageText), color)
            },
            onNote: { range in
                onAnnotate(pageIndex, range, quote(range, in: pageText), .yellow)
            }
        )
    }

    private func pageCanonicalText(_ pageIndex: Int) -> String {
        job.document?.pages.first { $0.pageIndex == pageIndex }?.canonicalLayout.text ?? ""
    }

    private func quote(_ range: NSRange, in text: String) -> String {
        let ns = text as NSString
        guard range.location >= 0, NSMaxRange(range) <= ns.length else { return "" }
        return ns.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func attributedText(for block: PDFReflowBlock) -> NSAttributedString {
        let style = ReaderPageStyle(theme: theme, typography: typography)
        var attributes = style.bodyAttributes
        switch block.kind {
        case .heading1:
            attributes[.font] = Self.serifFont(size: 27, weight: .regular)
            attributes[.paragraphStyle] = NSParagraphStyle.default
        case .heading2:
            attributes[.font] = Self.serifFont(size: 21, weight: .medium)
            attributes[.paragraphStyle] = NSParagraphStyle.default
        case .quote:
            attributes[.foregroundColor] = PlatformColor(theme.muted)
            let paragraph = (style.flushParagraphStyle.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
            paragraph.alignment = .natural
            attributes[.paragraphStyle] = paragraph
        case .list:
            let paragraph = (style.flushParagraphStyle.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
            paragraph.alignment = .natural
            attributes[.paragraphStyle] = paragraph
        case .body, .figure, .tableImage:
            break
        }
        return NSAttributedString(string: block.text, attributes: attributes)
    }

    private static func serifFont(size: CGFloat, weight: PlatformFont.Weight) -> PlatformFont {
        let base = PlatformFont.systemFont(ofSize: size, weight: weight)
        guard let descriptor = base.fontDescriptor.withDesign(.serif) else { return base }
        return PlatformFont(descriptor: descriptor, size: size) ?? base
    }

    @ViewBuilder
    private func blockView(_ block: PDFReflowBlock, base: Int?,
                           highlights: ReaderPageHighlights) -> some View {
        switch block.kind {
        case .heading1:
            selectableText(block, base: base, highlights: highlights)
                .padding(.top, 8)
        case .heading2:
            selectableText(block, base: base, highlights: highlights)
                .padding(.top, 4)
        case .body:
            selectableText(block, base: base, highlights: highlights)
        case .quote:
            HStack(alignment: .top, spacing: 10) {
                Rectangle().fill(theme.accent).frame(width: 2)
                selectableText(block, base: base, highlights: highlights)
            }
        case .list:
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("•").foregroundStyle(theme.accent)
                selectableText(block, base: base, highlights: highlights)
            }
        case .figure, .tableImage:
            if let name = block.imageFileName, showImages {
                VStack(alignment: .leading, spacing: 6) {
                    ReflowImage(url: store.imageURL(for: book.id, name: name), theme: theme)
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(theme.line, lineWidth: 1)
                        )
                    HStack(spacing: 6) {
                        Text(block.kind == .tableImage ? "Table" : "Page image")
                            .font(.caption2)
                            .foregroundStyle(theme.muted)
                        Spacer()
                        Button("Compare with page \(block.pageIndex + 1)") {
                            pdfPageIndex = block.pageIndex
                            if !isWide { showSourceSheet = true }
                        }
                        .font(.caption2)
                        .foregroundStyle(theme.accent)
                    }
                }
            }
        }
    }

    private var isWide: Bool {
        #if os(macOS)
        true
        #else
        DeviceInfo.isPad
        #endif
    }

    private var reflowSearchKey: String {
        let query = search?.isPresented == true ? search?.query ?? "" : ""
        return query + "|" + (job.document?.contentHash ?? "")
    }

    private func runReflowSearch() async {
        guard let search, search.isPresented, let document = job.document else { return }
        let query = search.query
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            search.setMatches([], startingAt: nil)
            search.isSearching = false
            return
        }
        search.isSearching = true
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return }
        let matches = reflowSearchMatches(for: query, in: document)
        guard !Task.isCancelled else { return }
        let start = ReaderSearch.firstIndex(in: matches, fromChapter: pdfPageIndex, offset: 0)
        search.setMatches(matches, startingAt: start)
        search.isSearching = false
        if let page = search.currentMatch?.chapterIndex, page != pdfPageIndex {
            jumpToPage = page
        }
    }

    private func loadReflow(force: Bool = false) async {
        if !force, let cached = store.load(bookID: book.id, contentHash: book.contentHash) {
            job.document = cached
            return
        }
        job.isWorking = true
        job.errorMessage = nil
        job.progress = 0
        let bookID = book.id
        let contentHash = book.contentHash
        let store = self.store
        let url = self.url
        let work = Task.detached(priority: .userInitiated) {
            try PDFReflowExtractor.extract(
                url: url,
                bookID: bookID,
                contentHash: contentHash,
                store: store
            ) { fraction in
                Task { @MainActor in
                    job.progress = fraction
                }
            }
        }
        do {
            let document = try await withTaskCancellationHandler {
                try await work.value
            } onCancel: {
                work.cancel()
            }
            job.document = document
            job.progress = 1
        } catch {
            if !Task.isCancelled {
                job.errorMessage = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
            }
        }
        job.isWorking = false
    }
}

// MARK: - Source panel

struct PDFSourcePanel: View {
    @Environment(LibraryService.self) private var library
    let book: Book
    let url: URL
    let document: PDFReflowDocument
    /// The page on screen in the reflow.
    let pageIndex: Int
    @Binding var showImages: Bool
    @Binding var skipHeaders: Bool
    /// Turns the reflow to an original page; the panel follows it.
    var onGoToPage: (Int) -> Void

    @State private var image: PlatformImage?
    @State private var isLoading = true

    private var page: PDFReflowPage? {
        document.pages.first { $0.pageIndex == pageIndex }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Spacer()
                    Text("\(pageIndex + 1) / \(document.totalPageCount)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.white)
                    if let image {
                        Image(platformImage: image)
                            .resizable()
                            .scaledToFit()
                    } else if isLoading {
                        ProgressView()
                    }
                    if let page {
                        GeometryReader { proxy in
                            let fitted = fittedPageRect(page: page, in: proxy.size)
                            ForEach(page.regions) { region in
                                regionOverlay(region, fittedRect: fitted)
                            }
                        }
                    }
                }
                .aspectRatio(0.77, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.black.opacity(0.12), lineWidth: 1))

                HStack(spacing: 8) {
                    Button {
                        onGoToPage(max(0, pageIndex - 1))
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 15, weight: .semibold))
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .disabled(pageIndex <= 0)
                    .accessibilityLabel("Previous page")
                    Spacer()
                    Text((page?.regions.count ?? 0) == 0 ? "No regions" : "\(page?.regions.count ?? 0) regions")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        onGoToPage(min(document.pageCount - 1, pageIndex + 1))
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 15, weight: .semibold))
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .disabled(pageIndex >= document.pageCount - 1)
                    .accessibilityLabel("Next page")
                    .accessibilityIdentifier("PDFSourceNextPage")
                }
                .buttonStyle(.plain)

                Toggle("Show images", isOn: $showImages)
                    .font(.footnote)
                Toggle("Skip headers, footnotes & page numbers", isOn: $skipHeaders)
                    .font(.footnote)

                if let page {
                    VStack(alignment: .leading, spacing: 6) {
                        legend(NodusColors.lavender, "Text")
                        legend(NodusColors.violet, "Heading")
                        legend(NodusColors.slateBlue, "Table")
                        legend(NodusColors.sage, "Image")
                        legend(Color.gray.opacity(0.6), "Header / footer")
                    }
                    .padding(.top, 4)
                }

                Text("Regions are detected locally. Nothing is uploaded.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
            .padding(14)
            .padding(.bottom, 28)
        }
        .background(uiBackground)
        .task(id: pageIndex) { await loadImage() }
    }

    private var uiBackground: Color {
        #if os(macOS)
        Color(nsColor: .windowBackgroundColor)
        #else
        Color(uiColor: .systemBackground)
        #endif
    }

    private func fittedPageRect(page: PDFReflowPage, in size: CGSize) -> CGRect {
        guard page.width > 1, page.height > 1 else {
            return CGRect(origin: .zero, size: size)
        }
        let pageAspect = page.width / page.height
        let boxAspect = size.width / max(size.height, 1)
        let fitted: CGSize
        if pageAspect > boxAspect {
            fitted = CGSize(width: size.width, height: size.width / pageAspect)
        } else {
            fitted = CGSize(width: size.height * pageAspect, height: size.height)
        }
        return CGRect(x: (size.width - fitted.width) / 2,
                      y: (size.height - fitted.height) / 2,
                      width: fitted.width,
                      height: fitted.height)
    }

    private func regionOverlay(_ region: PDFReflowRegion, fittedRect: CGRect) -> some View {
        let rect = CGRect(x: fittedRect.minX + region.rect.minX * fittedRect.width,
                          y: fittedRect.minY + region.rect.minY * fittedRect.height,
                          width: region.rect.width * fittedRect.width,
                          height: region.rect.height * fittedRect.height)
        let color: Color = switch region.kind {
        case .text: NodusColors.lavender
        case .heading: NodusColors.violet
        case .table: NodusColors.slateBlue
        case .figure: NodusColors.sage
        case .headerFooter: Color.gray.opacity(0.6)
        case .narrating: NodusColors.gold
        }
        return Rectangle()
            .stroke(color, lineWidth: 1)
            .background(color.opacity(0.08))
            .frame(width: max(1, rect.width), height: max(1, rect.height))
            .offset(x: rect.minX, y: rect.minY)
    }

    private func legend(_ color: Color, _ text: LocalizedStringKey) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 10, height: 8)
            Text(text).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func loadImage() async {
        isLoading = true
        image = nil
        let index = min(max(pageIndex, 0), document.totalPageCount - 1)
        let rendered = await Task.detached(priority: .userInitiated) { () -> PlatformImage? in
            guard let pdf = PDFDocument(url: url), let page = pdf.page(at: index) else { return nil }
            return page.thumbnail(of: CGSize(width: 900, height: 1200), for: .cropBox)
        }.value
        guard !Task.isCancelled else { return }
        self.image = rendered
        isLoading = false
    }
}

// MARK: - Images

struct ReflowImage: View {
    let url: URL
    let theme: ReaderTheme
    @State private var image: PlatformImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                Image(platformImage: image)
                    .resizable()
                    .scaledToFit()
            } else if failed {
                RoundedRectangle(cornerRadius: 8)
                    .fill(theme.panelFallback)
                    .frame(height: 120)
                    .overlay(
                        Label("Image unavailable", systemImage: "photo.badge.exclamationmark")
                            .font(.caption)
                            .foregroundStyle(theme.muted)
                    )
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(theme.panelFallback)
                    .frame(height: 120)
                    .overlay(ProgressView())
            }
        }
        .task(id: url) {
            failed = false
            image = nil
            let decoded = await Task.detached(priority: .userInitiated, operation: { () -> PlatformImage? in
                guard let data = try? Data(contentsOf: url),
                      let platform = PlatformImage(data: data) else { return nil }
                #if os(iOS)
                return platform.preparingForDisplay() ?? platform
                #else
                return platform
                #endif
            }).value
            guard !Task.isCancelled else { return }
            guard let decoded else {
                failed = true
                return
            }
            image = decoded
        }
    }
}

private extension ReaderTheme {
    var panelFallback: Color {
        isDark ? Color.white.opacity(0.06) : Color.black.opacity(0.05)
    }
}


// MARK: - Reflow scrollbar

/// A draggable page bar for the continuous reflow. It maps the track to
/// original page indices, so moving the thumb jumps directly to a page instead
/// of requiring a long fling through the whole thesis.
struct PDFReflowScrollbar: View {
    let pages: [Int]
    let current: Int
    let theme: ReaderTheme
    let onSelect: (Int) -> Void
    @State private var dragging = false

    var body: some View {
        GeometryReader { proxy in
            let height = max(1, proxy.size.height)
            let thumbHeight = min(height, max(44, height / CGFloat(max(pages.count, 1)) * 3))
            let travel = max(0, height - thumbHeight)
            let index = pages.firstIndex(of: current) ?? 0
            let progress = pages.count > 1
                ? CGFloat(index) / CGFloat(pages.count - 1)
                : 0
            let offset = travel * progress

            ZStack(alignment: .top) {
                Capsule()
                    .fill(theme.text.opacity(0.12))
                    .frame(width: 4, height: height)
                Capsule()
                    .fill(theme.accent.opacity(dragging ? 1 : 0.86))
                    .frame(width: 10, height: thumbHeight)
                    .overlay {
                        if thumbHeight >= 44 {
                            Text("\(current + 1)")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(theme.background)
                                .monospacedDigit()
                        }
                    }
                    .offset(y: offset)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        dragging = true
                        guard pages.count > 1, travel > 0 else { return }
                        let y = min(max(0, value.location.y - thumbHeight / 2), travel)
                        let fraction = y / travel
                        let target = Int((fraction * CGFloat(pages.count - 1)).rounded())
                        guard pages.indices.contains(target) else { return }
                        onSelect(pages[target])
                    }
                    .onEnded { _ in dragging = false }
            )
        }
        .frame(width: 30)
        .accessibilityElement()
        .accessibilityIdentifier("PDFReflowScrollbar")
        .accessibilityLabel("Scroll through pages")
        .accessibilityValue("Page \(current + 1) of \(pages.count)")
        .accessibilityAdjustableAction { direction in
            let index = pages.firstIndex(of: current) ?? 0
            let next: Int
            switch direction {
            case .increment: next = min(index + 1, pages.count - 1)
            case .decrement: next = max(index - 1, 0)
            @unknown default: return
            }
            if pages.indices.contains(next) { onSelect(pages[next]) }
        }
    }
}
