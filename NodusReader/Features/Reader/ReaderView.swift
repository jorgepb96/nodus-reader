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
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    let book: Book

    @State private var content: ReaderContent = .loading
    @State private var chapterIndex: Int
    @State private var scrollFraction: Double = 0
    @State private var pdfPageIndex: Int
    @State private var pdfPageCount = 0
    @State private var pdfJumpPage: Int?
    @State private var chromeVisible = true
    @State private var showContents = false
    @State private var showAppearance = false
    @State private var showPlayer = false
    @State private var pendingSave: Task<Void, Never>?

    init(book: Book) {
        self.book = book
        _chapterIndex = State(initialValue: max(book.locator.chapterIndex, 0))
        _pdfPageIndex = State(initialValue: max(book.locator.pageIndex ?? 0, 0))
    }

    private var readerTheme: ReaderTheme {
        themeManager.readerTheme(colorScheme: colorScheme)
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
        .onDisappear {
            pendingSave?.cancel()
            saveProgress()
        }
        .onChange(of: chapterIndex) { _, _ in
            scrollFraction = 0
            saveProgress()
        }
        .onChange(of: pdfPageIndex) { _, _ in
            saveProgress()
        }
        .onChange(of: playback.chapterIndex) { _, newValue in
            guard playback.activeBook?.id == book.id,
                  playback.mode == .readAndListen,
                  case .chapters(let chapters) = content,
                  chapters.indices.contains(newValue),
                  newValue != chapterIndex else { return }
            chapterIndex = newValue
        }
        .sheet(isPresented: $showContents) {
            ReaderContentsSheet(
                bookTitle: book.title,
                chapters: chapters,
                currentChapter: $chapterIndex,
                pdfURL: pdfURL,
                pageCount: pdfPageCount,
                currentPage: $pdfPageIndex,
                jumpToPage: $pdfJumpPage
            )
        }
        .sheet(isPresented: $showAppearance) {
            ReaderAppearanceSheet()
        }
        .sheet(isPresented: $showPlayer) {
            PlayerView().presentationDragIndicator(.hidden)
        }
    }

    // MARK: Content

    @ViewBuilder
    private func contentView(_ theme: ReaderTheme) -> some View {
        switch content {
        case .loading:
            loadingView(theme)
        case .chapters(let chapters):
            textReader(chapters, theme: theme)
        case .pdf(let url):
            PDFKitReader(
                url: url,
                pageIndex: $pdfPageIndex,
                pageCount: $pdfPageCount,
                jumpToPage: $pdfJumpPage,
                background: theme.background
            )
            .ignoresSafeArea(edges: .bottom)
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
            Button("Close") { dismiss() }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(theme.accent)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func textReader(_ chapters: [ExtractedChapter], theme: ReaderTheme) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Color.clear.frame(height: 1).id("top")
                    chapterOpener(theme)
                    ForEach(Array(paragraphs.enumerated()), id: \.offset) { index, paragraph in
                        let ranges = highlightRanges(for: paragraph)
                        JustifiedText(
                            text: paragraph,
                            size: preferences.baseFontSize,
                            weight: textWeight,
                            useSerif: preferences.useSerif,
                            color: theme.text,
                            lineSpacing: preferences.lineSpacing,
                            justified: preferences.justify,
                            sentenceHighlight: ranges.sentence,
                            sentenceHighlightColor: theme.narration,
                            wordHighlight: ranges.word,
                            wordHighlightColor: wordHighlightColor(theme),
                            onWordTap: { range in
                                startNarration(from: paragraph, range: range)
                            }
                        )
                        .id(index)
                    }
                }
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, readingMargin)
                .padding(.top, 18)
                .padding(.bottom, 44)
            }
            .scrollIndicators(.hidden)
            .onScrollGeometryChange(for: Double.self) { geometry in
                let scrollable = max(geometry.contentSize.height - geometry.containerSize.height, 1)
                return min(max(geometry.contentOffset.y / scrollable, 0), 1)
            } action: { _, newValue in
                scrollFraction = newValue
                scheduleSave()
            }
            .onChange(of: chapterIndex) { _, _ in
                withAnimation(.easeInOut(duration: 0.2)) {
                    proxy.scrollTo("top", anchor: .top)
                }
            }
            .onChange(of: playback.currentIndex) { _, _ in
                scrollToNarration(proxy)
            }
        }
    }

    private func chapterOpener(_ theme: ReaderTheme) -> some View {
        let chapter = currentChapter
        return VStack(spacing: 5) {
            Text("CHAPTER \(chapterIndex + 1)")
                .font(.system(size: 10, weight: .medium))
                .tracking(2.4)
                .foregroundStyle(theme.muted)
            Text(chapter?.title ?? "")
                .font(.system(size: DeviceInfo.isPad ? 36 : 32, weight: .regular, design: .serif))
                .italic()
                .foregroundStyle(theme.text)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
        .padding(.bottom, 2)
        .accessibilityElement(children: .combine)
    }

    // MARK: Bars

    private func topBar(_ theme: ReaderTheme) -> some View {
        HStack(spacing: 6) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(theme.text)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back to library")

            Spacer(minLength: 4)

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

            Spacer(minLength: 4)

            Button {
                showContents = true
            } label: {
                Image(systemName: "list.bullet")
                    .font(.system(size: 17))
                    .foregroundStyle(theme.text)
                    .frame(width: 40, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Contents")

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
        .padding(.horizontal, 8)
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
                            goToChapter(chapterIndex - 1)
                        } label: {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(chapterIndex > 0 ? theme.text : theme.muted.opacity(0.4))
                                .frame(width: 44, height: 32)
                        }
                        .buttonStyle(.plain)
                        .disabled(chapterIndex <= 0)
                        .accessibilityLabel("Previous chapter")
                    }

                    Spacer()

                    Text(progressLine)
                        .font(.system(size: 11))
                        .foregroundStyle(theme.muted)
                        .monospacedDigit()

                    Spacer()

                    if book.format != .pdf {
                        Button {
                            goToChapter(chapterIndex + 1)
                        } label: {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(canAdvanceChapter ? theme.text : theme.muted.opacity(0.4))
                                .frame(width: 44, height: 32)
                        }
                        .buttonStyle(.plain)
                        .disabled(!canAdvanceChapter)
                        .accessibilityLabel("Next chapter")
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
        if book.format == .pdf {
            let url = library.fileStore.documentURL(for: book)
            guard FileManager.default.fileExists(atPath: url.path) else {
                content = .failed("The PDF file is not available on this device.")
                return
            }
            content = .pdf(url)
            return
        }

        do {
            let loaded = try await BookTextLoader.loadChapters(for: book, fileStore: library.fileStore)
            guard !loaded.isEmpty else {
                content = .failed("This document does not contain readable text.")
                return
            }
            chapterIndex = min(max(chapterIndex, 0), loaded.count - 1)
            content = .chapters(loaded)
        } catch {
            content = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    private func saveProgress() {
        switch content {
        case .chapters(let chapters):
            guard !chapters.isEmpty else { return }
            let fraction = min(max(scrollFraction, 0), 1)
            let overall = min(1, (Double(chapterIndex) + fraction) / Double(chapters.count))
            library.updateProgress(
                book,
                locator: ReadingLocator(chapterIndex: chapterIndex, scrollFraction: fraction),
                progress: overall
            )
        case .pdf:
            let total = max(pdfPageCount, 1)
            let overall = min(1, Double(pdfPageIndex + 1) / Double(total))
            library.updateProgress(
                book,
                locator: ReadingLocator(chapterIndex: pdfPageIndex, scrollFraction: overall, pageIndex: pdfPageIndex),
                progress: overall
            )
        default:
            break
        }
    }

    private func scheduleSave() {
        pendingSave?.cancel()
        pendingSave = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(650))
            guard !Task.isCancelled else { return }
            saveProgress()
        }
    }

    // MARK: Helpers

    private var chapters: [ExtractedChapter] {
        if case .chapters(let chapters) = content { return chapters }
        return []
    }

    private var pdfURL: URL? {
        if case .pdf(let url) = content { return url }
        return nil
    }

    private var currentChapter: ExtractedChapter? {
        guard chapters.indices.contains(chapterIndex) else { return nil }
        return chapters[chapterIndex]
    }

    private var paragraphs: [String] {
        guard let text = currentChapter?.text else { return [] }
        var blocks = text.components(separatedBy: "\n\n")
        if blocks.count == 1 {
            blocks = text.components(separatedBy: "\n")
        }
        return blocks
            .map { $0.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private var canAdvanceChapter: Bool {
        chapterIndex + 1 < chapters.count
    }

    private var readingMargin: CGFloat {
        DeviceInfo.isPad ? max(preferences.margin, 40) : preferences.margin
    }

    private var textWeight: JustifiedText.Weight {
        switch preferences.weightIndex {
        case 2: .semibold
        case 1: .medium
        default: .regular
        }
    }

    private var currentChapterLabel: String {
        if book.format == .pdf {
            return pdfPageCount > 0 ? "Page \(min(pdfPageIndex + 1, pdfPageCount)) of \(pdfPageCount)" : "PDF"
        }
        return currentChapter?.title ?? "Chapter \(chapterIndex + 1)"
    }

    private var progressLine: String {
        if book.format == .pdf {
            let total = max(pdfPageCount, 1)
            let percent = Int(((Double(pdfPageIndex + 1) / Double(total)) * 100).rounded())
            return "Page \(min(pdfPageIndex + 1, total)) of \(total) · \(percent)%"
        }
        let count = max(chapters.count, 1)
        let overall: Double
        if playback.activeBook?.id == book.id, playback.mode != .read {
            overall = playback.overallProgress
        } else {
            let fraction = min(max(scrollFraction, 0), 1)
            overall = (Double(chapterIndex) + fraction) / Double(count)
        }
        let percent = Int((overall * 100).rounded())
        return "Chapter \(min(chapterIndex + 1, count)) of \(count) · \(percent)%"
    }

    private func highlightRanges(for paragraph: String) -> (sentence: NSRange?, word: NSRange?) {
        guard playback.activeBook?.id == book.id,
              playback.mode != .read,
              playback.chapterIndex == chapterIndex else { return (nil, nil) }
        let sentence = playback.currentSentence
        guard !sentence.isEmpty else { return (nil, nil) }
        let ns = paragraph as NSString
        var range = ns.range(of: sentence)
        if range.location == NSNotFound {
            range = ns.range(of: String(sentence.prefix(48)))
        }
        guard range.location != NSNotFound else { return (nil, nil) }

        var wordRange: NSRange?
        if let word = playback.currentWordRange,
           word.location >= 0,
           word.location + word.length <= (sentence as NSString).length {
            let candidate = NSRange(location: range.location + word.location, length: word.length)
            if candidate.location + candidate.length <= ns.length {
                wordRange = candidate
            }
        }
        return (range, wordRange)
    }

    private func wordHighlightColor(_ theme: ReaderTheme) -> Color {
        theme.isDark ? Color(hex: 0xC4B5FD, opacity: 0.65) : Color(hex: 0x7C3AED, opacity: 0.42)
    }

    /// Tapping a word starts narration from that sentence and word, the
    /// ElevenReader-style interaction requested for Read & Listen.
    private func startNarration(from paragraph: String, range: NSRange) {
        let ns = paragraph as NSString
        guard ns.length > 0 else { return }
        let location = min(max(range.location, 0), ns.length - 1)
        let spans = sentenceSpans(in: paragraph)
        let span = spans.first(where: { NSLocationInRange(location, $0) })
            ?? NSRange(location: 0, length: ns.length)
        let sentence = ns.substring(with: span)
        let wordOffset = max(0, location - span.location)
        Task {
            await playback.start(book: book, mode: .readAndListen,
                                 startingSentence: sentence, wordOffset: wordOffset)
        }
    }

    private func sentenceSpans(in paragraph: String) -> [NSRange] {
        var spans: [NSRange] = []
        let ns = paragraph as NSString
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length),
                               options: [.bySentences, .substringNotRequired]) { _, range, _, _ in
            spans.append(range)
        }
        return spans
    }

    private func scrollToNarration(_ proxy: ScrollViewProxy) {
        guard playback.activeBook?.id == book.id,
              playback.chapterIndex == chapterIndex else { return }
        let sentence = playback.currentSentence
        guard !sentence.isEmpty,
              let index = paragraphs.firstIndex(where: {
                  $0.contains(sentence) || $0.contains(String(sentence.prefix(48)))
              }) else { return }
        withAnimation(.easeInOut(duration: 0.35)) {
            proxy.scrollTo(index, anchor: .center)
        }
    }

    private func goToChapter(_ newIndex: Int) {
        guard chapters.indices.contains(newIndex) else { return }
        chapterIndex = newIndex
        scrollFraction = 0
        saveProgress()
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
