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
    @State private var pageIndex = 0
    @State private var pageInfo = ReaderPageInfo()
    @State private var firstPageByChapter: [Int: Int] = [:]
    @State private var readerPages: [ReaderPage] = []
    @State private var pageStep = 1
    @State private var chromeVisible = true
    @State private var showContents = false
    @State private var showAppearance = false
    @State private var showPlayer = false
    @State private var annotationDraft: ReaderAnnotationDraft?

    init(book: Book, onClose: @escaping () -> Void) {
        self.book = book
        self.onClose = onClose
        _pdfPageIndex = State(initialValue: max(book.locator.pageIndex ?? 0, 0))
    }

    private func closeReader() {
        onClose()
    }

    private var readerTheme: ReaderTheme {
        themeManager.readerTheme(colorScheme: colorScheme)
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
        "\(book.id.uuidString)-\(themeManager.readerThemeSelection)-\(colorScheme.hashValue)-\(preferences.fontScale)-\(preferences.lineSpacing)-\(preferences.margin)-\(preferences.justify)-\(preferences.useSerif)-\(preferences.weightIndex)"
    }

    var body: some View {
        let theme = readerTheme
        ZStack {
            theme.background.ignoresSafeArea()
            contentView(theme)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if chromeVisible {
                topBar(theme)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if chromeVisible {
                bottomBar(theme)
            }
        }
        .preferredColorScheme(theme.isDark ? .dark : .light)
        .animation(.easeInOut(duration: 0.2), value: chromeVisible)
        .task { await load() }
        .onDisappear { saveProgress() }
        .onChange(of: pageInfo.pageIndex) { _, _ in saveProgress() }
        .onChange(of: pageInfo.chapterIndex) { _, _ in saveProgress() }
        .onChange(of: pdfPageIndex) { _, _ in saveProgress() }
        .sheet(isPresented: $showContents) {
            if book.format == .pdf {
                ReaderContentsSheet(
                    bookTitle: book.title,
                    chapters: [],
                    currentChapter: $pdfChapterSelection,
                    pdfURL: pdfURL,
                    pageCount: pdfPageCount,
                    currentPage: $pdfPageIndex,
                    jumpToPage: $pdfJumpPage
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
        .sheet(isPresented: $showAppearance) {
            ReaderAppearanceSheet()
        }
        .sheet(isPresented: $showPlayer) {
            PlayerView().presentationDragIndicator(.hidden)
        }
        .sheet(item: $annotationDraft) { draft in
            AnnotationEditorSheet(book: book, draft: draft)
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
                style: ReaderPageStyle(theme: theme, preferences: preferences),
                theme: theme,
                buildKey: pageBuildKey,
                initialChapterIndex: max(book.locator.chapterIndex, 0),
                initialFraction: min(max(book.locator.scrollFraction, 0), 1),
                annotations: book.annotations,
                narrationChapterIndex: narrationActive ? playback.chapterIndex : nil,
                narrationSentenceRange: narrationActive ? playback.currentSentenceChapterRange : nil,
                narrationWordRange: narrationActive ? playback.currentWordChapterRange : nil,
                columns: paginationColumns,
                followNarration: playback.mode == .readAndListen,
                onWordTap: startNarration(at:),
                onHighlight: { range, color in presentAnnotation(range: range, color: color, note: false) },
                onNote: { range in presentAnnotation(range: range, color: .yellow, note: true) },
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
                jumpToPage: $pdfJumpPage
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
                showContents = true
            } label: {
                Image(systemName: "list.bullet")
                    .font(.system(size: 17))
                    .foregroundStyle(theme.text)
                    .frame(width: 40, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Contents, bookmarks and notes")

            Button {
                toggleBookmark()
            } label: {
                Image(systemName: isCurrentPageBookmarked ? "bookmark.fill" : "bookmark")
                    .font(.system(size: 17))
                    .foregroundStyle(isCurrentPageBookmarked ? theme.accent : theme.text)
                    .frame(width: 40, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isCurrentPageBookmarked ? "Remove bookmark from this page" : "Bookmark this page")

            Button {
                showAppearance = true
            } label: {
                Text("Aa")
                    .font(.system(size: 18, design: .serif))
                    .foregroundStyle(theme.text)
                    .frame(width: 40, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Appearance and typography")
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
                                .frame(width: 44, height: 32)
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
                                .frame(width: 44, height: 32)
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
        library.open(book)

        let localURL = library.fileStore.documentURL(for: book)
        if !FileManager.default.fileExists(atPath: localURL.path) {
            if sync.isEnabled {
                await sync.download(book)
            }
            guard FileManager.default.fileExists(atPath: localURL.path) else {
                let hint = sync.isEnabled
                    ? (sync.downloadError ?? "The document could not be downloaded from iCloud.")
                    : "This book is stored in iCloud. Enable iCloud sync in Settings to download it on this device."
                content = .failed(hint)
                return
            }
        }

        if book.format == .pdf {
            content = .pdf(localURL)
            return
        }

        do {
            let loaded = try await BookTextLoader.loadChapters(for: book, fileStore: library.fileStore)
            guard !loaded.isEmpty else {
                content = .failed("This document does not contain readable text.")
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
            guard pageInfo.pageCount > 0, !chapters.isEmpty else { return }
            let chapterFraction = pageInfo.pagesInChapter > 0
                ? Double(pageInfo.pageIndexInChapter) / Double(pageInfo.pagesInChapter)
                : 0
            let overall = min(1, Double(pageInfo.pageIndex + 1) / Double(pageInfo.pageCount))
            library.updateProgress(
                book,
                locator: ReadingLocator(chapterIndex: pageInfo.chapterIndex,
                                        scrollFraction: chapterFraction,
                                        pageIndex: pageInfo.pageIndex),
                progress: overall
            )
        case .pdf:
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
            return pdfPageCount > 0 ? "Page \(min(pdfPageIndex + 1, pdfPageCount)) of \(pdfPageCount)" : "PDF"
        }
        if !pageInfo.chapterTitle.isEmpty {
            return pageInfo.chapterTitle
        }
        return "Chapter \(pageInfo.chapterIndex + 1)"
    }

    private var progressLine: String {
        if book.format == .pdf {
            let total = max(pdfPageCount, 1)
            let percent = Int(((Double(pdfPageIndex + 1) / Double(total)) * 100).rounded())
            return "Page \(min(pdfPageIndex + 1, total)) of \(total) · \(percent)%"
        }
        guard pageInfo.pageCount > 0 else { return "Paginating…" }
        let percent = Int((Double(pageInfo.pageIndex + 1) / Double(pageInfo.pageCount) * 100).rounded())
        return "Page \(pageInfo.pageIndex + 1) of \(pageInfo.pageCount) · \(percent)%"
    }

    // MARK: Bookmarks and annotations

    private var isCurrentPageBookmarked: Bool {
        if book.format == .pdf {
            return book.bookmarks.contains { $0.locator.pageIndex == pdfPageIndex }
        }
        return book.bookmarks.contains { $0.locator.pageIndex == pageIndex }
    }

    private func toggleBookmark() {
        if let existing = book.bookmarks.first(where: {
            book.format == .pdf ? $0.locator.pageIndex == pdfPageIndex : $0.locator.pageIndex == pageIndex
        }) {
            library.deleteBookmark(existing)
            return
        }

        if book.format == .pdf {
            library.addBookmark(
                book,
                title: "Page \(pdfPageIndex + 1)",
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
                title: "Page \(pageIndex + 1)",
                chapterTitle: page.chapterTitle,
                locator: ReadingLocator(chapterIndex: page.chapterIndex,
                                        scrollFraction: page.pagesInChapter > 0
                                            ? Double(page.pageIndexInChapter) / Double(page.pagesInChapter) : 0,
                                        pageIndex: pageIndex)
            )
        }
    }

    private func startNarration(at chapterOffset: Int) {
        let chapter = readerPages.indices.contains(pageIndex)
            ? readerPages[pageIndex].chapterIndex
            : pageInfo.chapterIndex
        Task {
            await playback.start(book: book, mode: .readAndListen,
                                 startingChapterIndex: chapter,
                                 startingChapterOffset: chapterOffset)
        }
    }

    private func presentAnnotation(range: NSRange, color: AnnotationColor, note: Bool) {
        let chapter = readerPages.indices.contains(pageIndex)
            ? readerPages[pageIndex].chapterIndex
            : pageInfo.chapterIndex
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

    private func editAnnotation(_ annotation: Annotation) {
        annotationDraft = ReaderAnnotationDraft(
            chapterIndex: annotation.chapterIndex,
            range: NSRange(location: annotation.startOffset,
                           length: max(1, annotation.endOffset - annotation.startOffset)),
            quote: annotation.quote,
            color: annotation.color,
            note: annotation.note,
            existing: annotation
        )
    }
}

// MARK: - Narration capsule

struct ReaderNarrationCapsule: View {
    @Environment(PlaybackController.self) private var playback

    let theme: ReaderTheme
    var onOpenPlayer: () -> Void

    private var playForeground: Color {
        theme.isDark ? Color(hex: 0x16121F) : .white
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
                Group {
                    if playback.isLoading {
                        ProgressView().tint(playForeground)
                    } else {
                        Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 17, weight: .semibold))
                            .offset(x: playback.isPlaying ? 0 : 1)
                    }
                }
                .foregroundStyle(playForeground)
                .frame(width: 52, height: 52)
                .background(theme.accent, in: Circle())
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
