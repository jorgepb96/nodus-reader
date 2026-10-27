// SPDX-License-Identifier: AGPL-3.0-only
import DesignSystem
import PDFKit
import SwiftData
import SwiftUI

private enum ReaderContent {
    case loading
    case chapters([ExtractedChapter])
    case pdf(URL)
    case failed(String)
}

struct ReaderView: View {
    @Environment(LibraryService.self) private var library
    @Environment(ReaderPreferences.self) private var preferences
    @Environment(ThemeManager.self) private var themeManager
    @Environment(PlaybackController.self) private var playback
    @Environment(CloudSyncService.self) private var sync
    @Environment(\.colorScheme) private var colorScheme

    let book: Book
    private let onClose: () -> Void

    @State private var content: ReaderContent = .loading
    @State private var pdfPageIndex: Int
    @State private var pdfPageCount = 0
    @State private var pdfJumpPage: Int?
    @State private var pdfChapterSelection = 0
    @State private var pdfMode: PDFReadingMode = .original
    @State private var pageIndex = 0
    @State private var pageInfo = ReaderPageInfo()
    @State private var firstPageByChapter: [Int: Int] = [:]
    @State private var readerPages: [ReaderPage] = []
    @State private var pageStep = 1
    /// False until the reader moves away from the restored page. Restoring a
    /// position is not reading: it must not rewrite progress, and a document
    /// that fits on the first page must not become Finished just by opening.
    @State private var hasTurnedPage = false
    @State private var chromeVisible = true
    @State private var progressSaveTask: Task<Void, Never>?
    @State private var showContents = false
    @State private var showAppearance = false
    @State private var showAppearanceSheet = false
    @State private var showPlayer = false
    @State private var annotationDraft: ReaderAnnotationDraft?
    @State private var search = ReaderSearchModel()

    init(book: Book, onClose: @escaping () -> Void) {
        self.book = book
        self.onClose = onClose
        _pdfPageIndex = State(initialValue: max(book.locator.pageIndex ?? 0, 0))
    }

    private func closeReader() {
        onClose()
    }

    private var readerTheme: ReaderTheme {
        ReaderAppearanceResolver.theme(for: book, themeManager: themeManager, colorScheme: colorScheme)
    }

    /// The book's own typography when it has one, the global one otherwise.
    private var typography: ReaderTypography {
        ReaderAppearanceResolver.typography(for: book, preferences: preferences)
    }

    private var chapters: [ExtractedChapter] {
        if case .chapters(let chapters) = content { return chapters }
        return []
    }

    private var pdfURL: URL? {
        if case .pdf(let url) = content { return url }
        return nil
    }

    private var narrationActive: Bool {
        playback.activeBook?.id == book.id && playback.mode != .read
    }

    private var paginationColumns: Int {
        #if os(macOS)
        2
        #else
        1
        #endif
    }

    private var pageBuildKey: String {
        let selection = ReaderAppearanceResolver.themeSelection(for: book, themeManager: themeManager)
        let custom = themeManager.customThemes.first { "custom:\($0.id.uuidString)" == selection }.map {
            "\($0.backgroundHex)-\($0.textHex)-\($0.accentHex)-\($0.isDark)"
        } ?? ""
        let type = typography
        return "\(book.id.uuidString)-\(selection)-\(custom)-\(colorScheme.hashValue)-\(type.fontScale)-\(type.lineSpacing)-\(type.margin)-\(type.justify)-\(type.useSerif)-\(type.weightIndex)-\(type.flow.rawValue)"
    }

    var body: some View {
        let theme = readerTheme
        ZStack {
            theme.background.ignoresSafeArea()
            contentView(theme)
                // The search keyboard covers the page instead of shrinking it:
                // a smaller page would lay out the whole book again.
                .ignoresSafeArea(.keyboard)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if search.isPresented {
                ReaderSearchBar(model: search, theme: theme)
            } else if chromeVisible {
                topBar(theme)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if chromeVisible {
                bottomBar(theme)
            }
        }
        .preferredColorScheme(theme.isDark ? .dark : .light)
        // Sheets and popovers presented from the reader use its colour scheme,
        // so they take the matching palette: never dark labels on a dark
        // panel, or light labels on a light list.
        .nodusPalette(theme.isDark ? .dark : .light)
        .tint((theme.isDark ? NodusPalette.dark : NodusPalette.light).accent)
        .animation(.easeInOut(duration: 0.2), value: chromeVisible)
        .task { await load() }
        .task(id: search.isPresented ? search.query : "") {
            await runSearch()
        }
        .onDisappear {
            progressSaveTask?.cancel()
            saveProgress()
        }
        .onChange(of: pageInfo) { old, new in
            // Same pagination, different page: the reader turned a page (or
            // Read & Listen followed the narration). A new page count is a
            // repagination after a font, theme or window change.
            if old.pageCount > 0, old.pageCount == new.pageCount, old.pageIndex != new.pageIndex {
                hasTurnedPage = true
            }
            // Saved once the reader settles: a database save on every turn
            // lands right as the next curl starts and makes it stutter.
            progressSaveTask?.cancel()
            progressSaveTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(700))
                guard !Task.isCancelled else { return }
                saveProgress()
            }
        }
        .onChange(of: pdfPageIndex) { _, _ in saveProgress() }
        .sheet(isPresented: $showContents) {
            Group {
            if book.format == .pdf {
                ReaderContentsSheet(
                    bookTitle: book.title,
                    chapters: [],
                    currentChapter: $pdfChapterSelection,
                    pdfURL: pdfURL,
                    pageCount: pdfPageCount,
                    currentPage: $pdfPageIndex,
                    jumpToPage: $pdfJumpPage,
                    annotations: library.annotations(for: book),
                    onOpenAnnotation: { annotation in
                        // Notes are shown in Intelligent Reading.
                        pdfMode = .intelligent
                        pdfJumpPage = annotation.chapterIndex
                        pdfPageIndex = annotation.chapterIndex
                    },
                    onEditAnnotation: editAnnotation
                )
            } else {
                ReaderNavigationSheet(
                    book: book,
                    chapters: chapters,
                    pages: readerPages,
                    firstPageByChapter: firstPageByChapter,
                    pageIndex: $pageIndex,
                    onEditAnnotation: editAnnotation
                )
            }
            }
            .readerPresentation(readerTheme)
        }
        .sheet(isPresented: $showAppearanceSheet) {
            ReaderAppearanceSheet(book: book)
                .readerPresentation(readerTheme)
        }
        .sheet(isPresented: $showPlayer) {
            PlayerView().presentationDragIndicator(.hidden)
                .readerPresentation(readerTheme)
        }
        .sheet(item: $annotationDraft) { draft in
            AnnotationEditorSheet(book: book, draft: draft)
                .readerPresentation(readerTheme)
        }
        #if os(iOS)
        .statusBarHidden(true)
        #endif
    }

    // MARK: Content

    @ViewBuilder
    private func contentView(_ theme: ReaderTheme) -> some View {
        switch content {
        case .loading:
            loadingView(theme)
        case .chapters(let chapters):
            PaginatedReaderContent(
                book: book,
                chapters: chapters,
                style: ReaderPageStyle(theme: theme, typography: typography),
                theme: theme,
                typography: typography,
                buildKey: pageBuildKey,
                initialChapterIndex: max(book.locator.chapterIndex, 0),
                initialFraction: min(max(book.locator.scrollFraction, 0), 1),
                annotations: book.annotations,
                narrationChapterIndex: narrationActive ? playback.chapterIndex : nil,
                narrationSentenceRange: narrationActive ? playback.currentSentenceChapterRange : nil,
                narrationWordRange: narrationActive ? playback.currentWordChapterRange : nil,
                searchRanges: search.isPresented ? search.rangesByChapter : [:],
                currentSearchMatch: search.isPresented ? search.currentMatch : nil,
                columns: paginationColumns,
                followNarration: playback.mode == .readAndListen,
                onWordTap: { chapter, offset in startNarration(chapter: chapter, offset: offset) },
                onHighlight: { chapter, range, color in
                    presentAnnotation(chapter: chapter, range: range, color: color, note: false)
                },
                onNote: { chapter, range in
                    presentAnnotation(chapter: chapter, range: range, color: .yellow, note: true)
                },
                pageIndex: $pageIndex,
                pageInfo: $pageInfo,
                firstPageByChapter: $firstPageByChapter,
                pageStep: $pageStep,
                readerPages: $readerPages
            )
        case .pdf(let url):
            PDFReaderContainer(
                book: book,
                url: url,
                theme: theme,
                pdfPageIndex: $pdfPageIndex,
                pdfPageCount: $pdfPageCount,
                jumpToPage: $pdfJumpPage,
                mode: $pdfMode,
                search: search,
                onStartNarration: { page, offset in startNarration(chapter: page, offset: offset) },
                onAnnotate: { page, range, quote, color in
                    presentPDFAnnotation(page: page, range: range, quote: quote, color: color)
                }
            )
        case .failed(let message):
            failureView(message, theme: theme)
        }
    }

    private func loadingView(_ theme: ReaderTheme) -> some View {
        VStack(spacing: 14) {
            ProgressView().tint(theme.accent)
            Text("Opening \(book.title)…")
                .font(.footnote)
                .foregroundStyle(theme.muted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func failureView(_ message: String, theme: ReaderTheme) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 26))
                .foregroundStyle(theme.accent)
            Text("This document could not be opened")
                .font(.system(.title3, design: .serif))
                .foregroundStyle(theme.text)
            Text(message)
                .font(.footnote)
                .foregroundStyle(theme.muted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            Button("Close") { closeReader() }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(theme.accent)
            Button("Try Again") {
                content = .loading
                Task { await load() }
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(theme.muted)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Search

    private func openSearch() {
        // PDFKit searches the original pages; the reflow view runs the same
        // query over its page text, so the current PDF mode is preserved.
        search.isPresented = true
    }

    /// Finds the query in the chapters, off the main thread and a moment after
    /// the last keystroke. PDFs are searched by PDFKit in the page view.
    private func runSearch() async {
        guard search.isPresented, book.format != .pdf else { return }
        let query = search.query
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            search.setMatches([], startingAt: nil)
            search.isSearching = false
            return
        }
        search.isSearching = true
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return }
        let texts = chapters.map(\.text)
        let matches = await Task.detached(priority: .userInitiated) {
            ReaderSearch.matches(for: query, in: texts)
        }.value
        guard !Task.isCancelled else { return }
        let offset = readerPages.indices.contains(pageIndex) ? readerPages[pageIndex].chapterStartOffset : 0
        search.setMatches(matches, startingAt: ReaderSearch.firstIndex(in: matches,
                                                                        fromChapter: pageInfo.chapterIndex,
                                                                        offset: offset))
        search.isSearching = false
    }

    // MARK: Bars

    private func topBar(_ theme: ReaderTheme) -> some View {
        HStack(spacing: 2) {
            Button {
                closeReader()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(theme.text)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back to library")

            Spacer(minLength: 2)

            VStack(spacing: 1) {
                Text(book.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.text)
                    .lineLimit(1)
                Text(currentChapterLabel)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.muted)
                    .lineLimit(1)
            }
            .accessibilityElement(children: .combine)

            Spacer(minLength: 2)

            Button {
                openSearch()
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 17))
                    .foregroundStyle(theme.text)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .keyboardShortcut("f", modifiers: .command)
            .accessibilityLabel("Search in book")
            .accessibilityIdentifier("ReaderSearchButton")

            Button {
                showContents = true
            } label: {
                Image(systemName: "list.bullet")
                    .font(.system(size: 17))
                    .foregroundStyle(theme.text)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Contents, bookmarks and notes")

            Button {
                toggleBookmark()
            } label: {
                Image(systemName: isCurrentPageBookmarked ? "bookmark.fill" : "bookmark")
                    .font(.system(size: 17))
                    .foregroundStyle(isCurrentPageBookmarked ? theme.accent : theme.text)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isCurrentPageBookmarked ? "Remove bookmark from this page" : "Bookmark this page")

            Button {
                showAppearance = true
            } label: {
                Text("Aa")
                    .font(.system(size: 18, design: .serif))
                    .foregroundStyle(theme.text)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Appearance and typography")
            .popover(isPresented: $showAppearance, arrowEdge: .top) {
                ReaderAppearancePopover(book: book, readerTheme: theme) {
                    showAppearance = false
                    // Present the sheet once the popover has gone.
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(350))
                        showAppearanceSheet = true
                    }
                }
                .readerPresentation(theme)
                #if os(iOS)
                .presentationCompactAdaptation(.popover)
                #endif
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 44)
        .background(theme.background)
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.line).frame(height: 0.5)
        }
    }

    private func bottomBar(_ theme: ReaderTheme) -> some View {
        VStack(spacing: 8) {
            if playback.activeBook?.id == book.id, playback.mode != .read {
                ReaderNarrationCapsule(theme: theme) {
                    showPlayer = true
                }
            } else {
                HStack {
                    if book.format != .pdf {
                        Button {
                            goToPage(pageIndex - pageStep)
                        } label: {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(canGoPreviousPage ? theme.text : theme.muted.opacity(0.4))
                                .frame(width: 44, height: 44)
                        }
                        .buttonStyle(.plain)
                        .disabled(!canGoPreviousPage)
                        .accessibilityLabel("Previous page")
                    }

                    Spacer()

                    Text(progressLine)
                        .font(.system(size: 11))
                        .foregroundStyle(theme.muted)
                        .monospacedDigit()

                    Spacer()

                    if book.format != .pdf {
                        Button {
                            goToPage(pageIndex + pageStep)
                        } label: {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(canGoNextPage ? theme.text : theme.muted.opacity(0.4))
                                .frame(width: 44, height: 44)
                        }
                        .buttonStyle(.plain)
                        .disabled(!canGoNextPage)
                        .accessibilityLabel("Next page")
                    }
                }
                .padding(.horizontal, 4)
            }

            if playback.activeBook?.id == book.id, playback.mode != .read {
                Text(progressLine)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.muted)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .background(theme.background)
        .overlay(alignment: .top) {
            Rectangle().fill(theme.line).frame(height: 0.5)
        }
    }

    // MARK: Load and save

    private func load() async {
        let localURL = library.fileStore.documentURL(for: book)
        if !FileManager.default.fileExists(atPath: localURL.path) {
            if sync.isEnabled {
                await sync.download(book)
            }
            guard FileManager.default.fileExists(atPath: localURL.path) else {
                let hint = sync.isEnabled
                    ? (sync.downloadError ?? String(localized: "The document could not be downloaded from iCloud."))
                    : String(localized: "This book is stored in iCloud. Enable iCloud sync in Settings to download it on this device.")
                content = .failed(hint)
                return
            }
        }
        // Only a document that can actually be read becomes "in progress" and
        // the Home Continue card; a failed iCloud download must not.
        library.open(book)
        Task { await library.refreshExtractedTextIfNeeded(book) }

        if book.format == .pdf {
            content = .pdf(localURL)
            return
        }

        do {
            let loaded = try await BookTextLoader.loadChapters(for: book, fileStore: library.fileStore)
            guard !loaded.isEmpty else {
                content = .failed(String(localized: "This document does not contain readable text."))
                return
            }
            content = .chapters(loaded)
        } catch {
            content = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    private func saveProgress() {
        switch content {
        case .chapters(let chapters):
            guard hasTurnedPage, pageInfo.pageCount > 0, !chapters.isEmpty else { return }
            let chapterFraction = pageInfo.pagesInChapter > 1
                ? Double(pageInfo.pageIndexInChapter) / Double(pageInfo.pagesInChapter - 1)
                : 0
            // Count every visible page: on the Mac spread the right-hand page
            // is read too, so the last spread reaches 100 %.
            let lastVisible = min(pageInfo.pageIndex + max(pageStep, 1), pageInfo.pageCount)
            let overall = min(1, Double(lastVisible) / Double(pageInfo.pageCount))
            library.updateProgress(
                book,
                locator: ReadingLocator(chapterIndex: pageInfo.chapterIndex,
                                        scrollFraction: chapterFraction,
                                        pageIndex: pageInfo.pageIndex),
                progress: overall
            )
        case .pdf:
            guard pdfPageCount > 0 else { return }
            let total = max(pdfPageCount, 1)
            let overall = min(1, Double(pdfPageIndex + 1) / Double(total))
            library.updateProgress(
                book,
                locator: ReadingLocator(chapterIndex: pdfPageIndex, scrollFraction: overall,
                                        pageIndex: pdfPageIndex),
                progress: overall
            )
        default:
            break
        }
    }

    // MARK: Page helpers

    private var canGoPreviousPage: Bool {
        pageIndex > 0
    }

    private var canGoNextPage: Bool {
        pageInfo.pageCount > 0 && pageIndex + pageStep < pageInfo.pageCount
    }

    private func goToPage(_ index: Int) {
        guard pageInfo.pageCount > 0 else { return }
        pageIndex = min(max(index, 0), pageInfo.pageCount - 1)
    }

    private var currentChapterLabel: String {
        if book.format == .pdf {
            return pdfPageCount > 0 ? String(localized: "Page \(min(pdfPageIndex + 1, pdfPageCount)) of \(pdfPageCount)") : "PDF"
        }
        if !pageInfo.chapterTitle.isEmpty {
            return pageInfo.chapterTitle
        }
        return String(localized: "Chapter \(pageInfo.chapterIndex + 1)")
    }

    private var progressLine: String {
        if book.format == .pdf {
            guard pdfPageCount > 0 else { return String(localized: "Loading PDF…") }
            let total = pdfPageCount
            let percent = Int(((Double(pdfPageIndex + 1) / Double(total)) * 100).rounded())
            return String(localized: "Page \(min(pdfPageIndex + 1, total)) of \(total) · \(percent)%")
        }
        guard pageInfo.pageCount > 0 else { return String(localized: "Paginating…") }
        if pageInfo.isProvisional {
            // Only this chapter is laid out yet; book-wide numbers follow.
            return String(localized: "Page \(pageInfo.pageIndexInChapter + 1) of \(pageInfo.pagesInChapter) in this chapter")
        }
        let percent = Int((Double(pageInfo.pageIndex + 1) / Double(pageInfo.pageCount) * 100).rounded())
        return String(localized: "Page \(pageInfo.pageIndex + 1) of \(pageInfo.pageCount) · \(percent)%")
    }

    // MARK: Bookmarks and annotations

    private var currentPageFraction: Double {
        guard readerPages.indices.contains(pageIndex) else { return 0 }
        let page = readerPages[pageIndex]
        return page.pagesInChapter > 1
            ? Double(page.pageIndexInChapter) / Double(page.pagesInChapter - 1)
            : 0
    }

    private var bookmarkMatchTolerance: Double {
        guard readerPages.indices.contains(pageIndex) else { return 0.015 }
        let pages = readerPages[pageIndex].pagesInChapter
        return min(0.015, 0.45 / Double(max(pages - 1, 1)))
    }

    private var isCurrentPageBookmarked: Bool {
        if book.format == .pdf {
            return book.bookmarks.contains { $0.locator.pageIndex == pdfPageIndex }
        }
        guard readerPages.indices.contains(pageIndex) else { return false }
        let chapter = readerPages[pageIndex].chapterIndex
        let fraction = currentPageFraction
        return book.bookmarks.contains {
            $0.locator.chapterIndex == chapter &&
            abs($0.locator.scrollFraction - fraction) < bookmarkMatchTolerance
        }
    }

    private func toggleBookmark() {
        if book.format == .pdf,
           let existing = book.bookmarks.first(where: { $0.locator.pageIndex == pdfPageIndex }) {
            library.deleteBookmark(existing)
            return
        }
        if book.format != .pdf, let page = readerPages.indices.contains(pageIndex) ? readerPages[pageIndex] : nil,
           let existing = book.bookmarks.first(where: {
               $0.locator.chapterIndex == page.chapterIndex &&
               abs($0.locator.scrollFraction - currentPageFraction) < bookmarkMatchTolerance
           }) {
            library.deleteBookmark(existing)
            return
        }

        if book.format == .pdf {
            library.addBookmark(
                book,
                title: String(localized: "Page \(pdfPageIndex + 1)"),
                chapterTitle: "PDF page \(pdfPageIndex + 1)",
                locator: ReadingLocator(chapterIndex: pdfPageIndex,
                                        scrollFraction: Double(pdfPageIndex + 1) / Double(max(pdfPageCount, 1)),
                                        pageIndex: pdfPageIndex)
            )
        } else {
            guard readerPages.indices.contains(pageIndex) else { return }
            let page = readerPages[pageIndex]
            library.addBookmark(
                book,
                title: String(localized: "Page \(pageIndex + 1)"),
                chapterTitle: page.chapterTitle,
                locator: ReadingLocator(chapterIndex: page.chapterIndex,
                                        scrollFraction: page.pagesInChapter > 1
                                            ? Double(page.pageIndexInChapter) / Double(page.pagesInChapter - 1) : 0,
                                        pageIndex: pageIndex)
            )
        }
    }

    private func startNarration(chapter: Int, offset chapterOffset: Int) {
        Task {
            await playback.start(book: book, mode: .readAndListen,
                                 startingChapterIndex: chapter,
                                 startingChapterOffset: chapterOffset)
        }
    }

    private func presentAnnotation(chapter: Int, range: NSRange,
                                   color: AnnotationColor, note: Bool) {
        guard chapters.indices.contains(chapter) else { return }
        let ns = chapters[chapter].text as NSString
        guard range.length > 0, range.location >= 0, NSMaxRange(range) <= ns.length else { return }
        let quote = ns.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !quote.isEmpty else { return }
        annotationDraft = ReaderAnnotationDraft(
            chapterIndex: chapter,
            range: range,
            quote: quote,
            color: color,
            note: "",
            existing: nil
        )
        _ = note
    }

    /// Highlights in PDF Intelligent Reading: `page` is the original page and
    /// `range` is in that page's canonical reflow text.
    private func presentPDFAnnotation(page: Int, range: NSRange, quote: String, color: AnnotationColor) {
        guard range.length > 0, !quote.isEmpty else { return }
        annotationDraft = ReaderAnnotationDraft(
            chapterIndex: page,
            range: range,
            quote: quote,
            color: color,
            note: "",
            existing: nil
        )
    }

    private func editAnnotation(_ annotation: Annotation) {
        let draft = ReaderAnnotationDraft(
            chapterIndex: annotation.chapterIndex,
            range: NSRange(location: annotation.startOffset,
                           length: max(1, annotation.endOffset - annotation.startOffset)),
            quote: annotation.quote,
            color: annotation.color,
            note: annotation.note,
            existing: annotation
        )
        showContents = false
        Task { @MainActor in
            // Let the navigation sheet finish dismissing before presenting the
            // editor; iOS cannot stack two sheets on the same host.
            try? await Task.sleep(for: .milliseconds(220))
            annotationDraft = draft
        }
    }
}

// MARK: - Narration capsule

struct ReaderNarrationCapsule: View {
    @Environment(PlaybackController.self) private var playback

    let theme: ReaderTheme
    var onOpenPlayer: () -> Void

    private var playForeground: Color {
        theme.isDark ? NodusColors.onAccent : .white
    }

    var body: some View {
        HStack(spacing: 2) {
            Button {
                playback.previousSentence()
            } label: {
                Image(systemName: "backward.end")
                    .font(.system(size: 18))
                    .foregroundStyle(theme.text)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Previous sentence")

            Button {
                playback.toggle()
            } label: {
                Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .offset(x: playback.isPlaying ? 0 : 1)
                    .foregroundStyle(playForeground)
                    .frame(width: 52, height: 52)
                    .background(theme.accent, in: Circle())
                    .overlay {
                        if playback.isLoading {
                            LoadingRing(color: playForeground, lineWidth: 3).padding(3)
                        }
                    }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(playback.isPlaying ? "Pause narration" : "Play narration")

            Button {
                playback.nextSentence()
            } label: {
                Image(systemName: "forward.end")
                    .font(.system(size: 18))
                    .foregroundStyle(theme.text)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Next sentence")

            Button(action: onOpenPlayer) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(playback.mode.label.uppercased())
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(1.4)
                        .foregroundStyle(theme.accent)
                    Text("\(playback.voiceLabel) · \(playback.speedLabel)")
                        .font(.system(size: 13))
                        .foregroundStyle(theme.text)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open player")

            Menu {
                ForEach(SleepTimerOption.allCases) { option in
                    Button(option.label) { playback.setSleepTimer(option) }
                }
            } label: {
                Image(systemName: "moon")
                    .font(.system(size: 17))
                    .foregroundStyle(playback.sleepTimer == .off ? theme.text : theme.accent)
                    .frame(width: 42, height: 44)
            }
            .accessibilityLabel("Sleep timer")
        }
        .padding(.horizontal, 6)
        .frame(height: 62)
        .background(
            (theme.isDark ? Color.white.opacity(0.07) : Color.white.opacity(0.88)),
            in: Capsule()
        )
        .overlay(Capsule().stroke(theme.line, lineWidth: 1))
        .shadow(color: theme.isDark ? Color.black.opacity(0.35) : Color.black.opacity(0.12),
                radius: 18, y: 8)
    }
}
