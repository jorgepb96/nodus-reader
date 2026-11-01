// SPDX-License-Identifier: AGPL-3.0-only
import DesignSystem
import SwiftUI

/// Whether recaps and characters can be offered: Apple Intelligence on
/// iOS/macOS 26 or later, on an eligible device, turned on and ready.
enum StoryCompanionAvailability: Equatable {
    case available
    case notEnabled
    case notReady
    /// Older system or a device without Apple Intelligence: nothing is shown.
    case unsupported

    static var current: StoryCompanionAvailability {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) {
            switch StoryCompanionEngine.availability {
            case .available: return .available
            case .notEnabled: return .notEnabled
            case .notReady: return .notReady
            case .deviceNotEligible: return .unsupported
            }
        }
        #endif
        return .unsupported
    }
}

/// The reader's recap and character list for one open book. Runs the
/// companion engine, keeps its cache on disk and, while the book is open,
/// summarises the pages already read in the background so the next recap
/// is quick and covers the whole book.
@MainActor
@Observable
final class ReaderStoryModel {
    enum Phase: Equatable {
        case idle
        case working
        case done(String)
        /// Nothing to show yet, with the reason.
        case empty(String)
        case failed(String)
    }

    struct Character: Identifiable, Equatable {
        var id: String { name }
        let name: String
        let description: String
        let firstChapter: Int
        let firstOffset: Int
    }

    private(set) var whereYouLeftOff: Phase = .idle
    private(set) var storySoFar: Phase = .idle
    /// Passages summarised out of those the story so far needs.
    private(set) var storyProgress: (done: Int, total: Int)?
    private(set) var characters: [Character] = []
    private(set) var charactersPhase: Phase = .idle
    private(set) var charactersProgress: (done: Int, total: Int)?
    private(set) var isLoadingText = false

    /// Where the reader is, as an offset in the book's text: the end of the
    /// page on screen, which the reader has in front of them.
    @ObservationIgnored private(set) var position = 0
    @ObservationIgnored private var chapter = 0
    @ObservationIgnored private var chapterOffset = 0
    @ObservationIgnored private var bookID: UUID?
    @ObservationIgnored private var story: StoryText?
    /// A `StoryCompanionEngine`, kept untyped because the reader also runs
    /// on systems without Foundation Models.
    @ObservationIgnored private var engine: AnyObject?
    @ObservationIgnored private let store = StoryCompanionStore()
    @ObservationIgnored private var recapTask: Task<Void, Never>?
    @ObservationIgnored private var charactersTask: Task<Void, Never>?
    @ObservationIgnored private var preparation: Task<Void, Never>?
    @ObservationIgnored private var preparedUpTo = -1
    /// Recaps or descriptions in progress; the background work waits for them.
    @ObservationIgnored private var interactive = 0

    var isReady: Bool { engine != nil }

    /// The language recaps are written in: the app's, when the model writes it.
    private static var outputLanguage: String {
        let language = Bundle.main.preferredLocalizations.first ?? "en"
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *), StoryCompanionEngine.supports(languageCode: language) {
            return language
        }
        #endif
        return "en"
    }

    /// Prepares the model for `book` from its chapters. Safe to call again.
    func configure(book: Book, chapters: [ExtractedChapter]) async {
        guard engine == nil, !chapters.isEmpty, StoryCompanionAvailability.current == .available else { return }
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, macOS 26.0, *) else { return }
        let texts = chapters.map(\.text)
        let titles = chapters.map(\.title)
        let story = await Task.detached(priority: .utility) { StoryText(chapters: texts, titles: titles) }.value
        let contentKey = "\(book.contentHash)-\(story.length)"
        let language = Self.outputLanguage
        let saved = store.load(bookID: book.id) ?? StoryCompanionCache()
        bookID = book.id
        self.story = story
        engine = StoryCompanionEngine(story: story, outputLanguageCode: language,
                                      cache: saved.adapted(contentKey: contentKey, language: language))
        updatePosition(chapter: chapter, offset: chapterOffset)
        #endif
    }

    /// For a PDF, the text comes from Intelligent Reading or PDFKit; it is
    /// loaded only when the recap is asked for.
    func configureIfNeeded(book: Book) async {
        guard engine == nil, !isLoadingText else { return }
        isLoadingText = true
        defer { isLoadingText = false }
        guard let chapters = try? await BookTextLoader.loadChapters(for: book) else { return }
        await configure(book: book, chapters: chapters)
    }

    func updatePosition(chapter: Int, offset: Int) {
        self.chapter = chapter
        chapterOffset = offset
        guard let story else { return }
        position = story.offset(chapter: chapter, characterOffset: offset)
        if preparation == nil, story.completePassages(before: position) > preparedUpTo {
            startPreparing(after: .seconds(preparedUpTo < 0 ? 20 : 2))
        }
    }

    /// Whether enough of the story has been read for a recap.
    var hasReadEnough: Bool {
        guard let story else { return false }
        return position - story.storyStart >= 2_000
    }

    // MARK: Recap

    /// Writes the recap; with `includingStory` false, only "where you left
    /// off", which is quick (a welcome-back card prepares it in advance).
    func loadRecap(includingStory: Bool = true) {
        guard recapTask == nil else { return }
        recapTask = Task {
            await runRecap(includingStory: includingStory)
            recapTask = nil
        }
    }

    private func runRecap(includingStory: Bool) async {
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, macOS 26.0, *), let engine = engine as? StoryCompanionEngine else { return }
        interactive += 1
        defer { interactive -= 1 }
        let position = position
        if case .done = whereYouLeftOff {} else { whereYouLeftOff = .working }
        do {
            let part = try await engine.whereYouLeftOff(upTo: position)
            whereYouLeftOff = .done(part.text)
        } catch {
            whereYouLeftOff = Self.phase(for: error)
            storySoFar = .idle
            return
        }
        guard includingStory else { return }
        if case .done = storySoFar {} else { storySoFar = .working }
        do {
            let part = try await engine.storySoFar(upTo: position) { done, total in
                Task { @MainActor [weak self] in self?.storyProgress = (done, total) }
            }
            storySoFar = part.map { .done($0.text) }
                ?? .empty(String(localized: "Once you have read further, the story so far will appear here."))
        } catch {
            storySoFar = Self.phase(for: error)
        }
        storyProgress = nil
        await save()
        #endif
    }

    // MARK: Characters

    func loadCharacters() {
        guard charactersTask == nil else { return }
        charactersTask = Task {
            await runCharacters()
            charactersTask = nil
        }
    }

    private func runCharacters() async {
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, macOS 26.0, *), let engine = engine as? StoryCompanionEngine,
              let story else { return }
        interactive += 1
        defer { interactive -= 1 }
        let position = position
        guard hasReadEnough else {
            charactersPhase = .empty(String(localized: "Read a few more pages and the people in the story will appear here."))
            return
        }
        charactersPhase = .working
        let found = await Task.detached(priority: .userInitiated) {
            StoryCharacterFinder.characters(in: story, upTo: position)
        }.value
        var described: [Character] = []
        for (index, candidate) in found.enumerated() {
            charactersProgress = (index, found.count)
            do {
                guard let text = try await engine.describe(candidate, upTo: position) else { continue }
                let first = story.location(of: candidate.firstOffset)
                described.append(Character(name: candidate.name, description: text,
                                           firstChapter: first.chapter, firstOffset: first.characterOffset))
                characters = described
            } catch {
                charactersPhase = Self.phase(for: error)
                charactersProgress = nil
                return
            }
        }
        characters = described
        charactersProgress = nil
        charactersPhase = described.isEmpty
            ? .empty(String(localized: "No named characters in the pages read so far."))
            : .done("")
        await save()
        #endif
    }

    // MARK: Background

    /// Summarises the read passages a few seconds after the reader settles,
    /// one at a time and at background priority, giving way to recaps and
    /// stopping in Low Power Mode or when the book closes.
    private func startPreparing(after delay: Duration) {
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, macOS 26.0, *), engine is StoryCompanionEngine else { return }
        preparation = Task(priority: .background) { [weak self] in
            try? await Task.sleep(for: delay)
            var count = 0
            while !Task.isCancelled, !ProcessInfo.processInfo.isLowPowerModeEnabled {
                guard let self, let engine = self.engine as? StoryCompanionEngine else { return }
                if self.interactive > 0 {
                    try? await Task.sleep(for: .seconds(2))
                    continue
                }
                let target = self.position
                guard let more = try? await engine.prepareNext(upTo: target), more else {
                    self.preparedUpTo = self.story?.completePassages(before: target) ?? self.preparedUpTo
                    break
                }
                count += 1
                if count.isMultiple(of: 4) { await self.save() }
            }
            await self?.save()
            self?.preparation = nil
        }
        #endif
    }

    /// Stops the work for this book and saves what was done.
    func stop() {
        preparation?.cancel()
        preparation = nil
        recapTask?.cancel()
        charactersTask?.cancel()
        Task { await save() }
    }

    private func save() async {
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, macOS 26.0, *), let engine = engine as? StoryCompanionEngine,
              let bookID else { return }
        let cache = await engine.cache
        let store = store
        await Task.detached(priority: .utility) { store.save(cache, bookID: bookID) }.value
        #endif
    }

    private static func phase(for error: Error) -> Phase {
        switch error as? StoryCompanionError {
        case .notEnoughText:
            return .empty(String(localized: "Read a few more pages and a recap will be ready here."))
        case .unsupportedLanguage:
            return .failed(String(localized: "Apple Intelligence can’t read this book’s language yet."))
        case .unavailable:
            return .failed(String(localized: "Apple Intelligence isn’t ready on this device right now. Try again later."))
        case .blocked, nil:
            if error is CancellationError { return .idle }
            return .failed(String(localized: "The recap could not be written. Try again."))
        }
    }
}

enum ReaderStoryTab: String, CaseIterable, Identifiable {
    case recap
    case characters
    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .recap: "Recap"
        case .characters: "Characters"
        }
    }
}

/// "Previously in…" and the people met so far, from the pages already read.
struct ReaderStorySheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.nodusPalette) private var palette

    let book: Book
    /// The page number of a chapter offset, when the reader knows it.
    let pageNumber: (_ chapter: Int, _ offset: Int) -> Int?
    let model: ReaderStoryModel
    @Binding var tab: ReaderStoryTab

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Recap or characters", selection: $tab) {
                    ForEach(ReaderStoryTab.allCases) { tab in
                        Text(tab.title).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if !model.isReady {
                            if model.isLoadingText {
                                progressRow("Preparing the book’s text…")
                            } else {
                                message(String(localized: "Recaps aren’t available for this book."))
                            }
                        } else {
                            switch tab {
                            case .recap: recap
                            case .characters: characterList
                            }
                        }
                        footnote
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 6)
                    .padding(.bottom, 28)
                    .frame(maxWidth: 680, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
                .scrollIndicators(.never)
            }
            .background(palette.background)
            .navigationTitle(book.title)
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task(id: "\(tab.rawValue)-\(model.isReady)") {
            guard model.isReady else { return }
            switch tab {
            case .recap: model.loadRecap()
            case .characters: model.loadCharacters()
            }
        }
        #if os(iOS)
        .presentationDetents([.medium, .large])
        .presentationContentInteraction(.scrolls)
        #else
        .frame(minWidth: 520, idealWidth: 580, minHeight: 520, idealHeight: 640)
        #endif
    }

    // MARK: Recap

    @ViewBuilder
    private var recap: some View {
        section("Where you left off", phase: model.whereYouLeftOff,
                working: "Reading the last pages…", progress: nil)
        if model.storySoFar != .idle {
            section("The story so far", phase: model.storySoFar,
                    working: "Going over the earlier chapters…", progress: model.storyProgress)
        }
    }

    @ViewBuilder
    private func section(_ title: LocalizedStringResource, phase: ReaderStoryModel.Phase,
                         working: LocalizedStringKey, progress: (done: Int, total: Int)?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Eyebrow(title)
            switch phase {
            case .idle, .working:
                progressRow(working, progress: progress)
            case .done(let text):
                Text(text)
                    .font(.system(.body, design: .serif))
                    .foregroundStyle(palette.text)
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            case .empty(let reason):
                message(reason)
            case .failed(let reason):
                failure(reason) { model.loadRecap() }
            }
        }
    }

    // MARK: Characters

    @ViewBuilder
    private var characterList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(model.characters) { character in
                VStack(alignment: .leading, spacing: 4) {
                    Text(character.name)
                        .font(.headline)
                        .foregroundStyle(palette.text)
                    Text(character.description)
                        .font(.subheadline)
                        .foregroundStyle(palette.text.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                    if let page = pageNumber(character.firstChapter, character.firstOffset) {
                        Text("First appears on page \(page)")
                            .font(.caption)
                            .foregroundStyle(palette.muted)
                    }
                }
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                Divider().overlay(palette.line)
            }
            switch model.charactersPhase {
            case .idle, .working:
                if let progress = model.charactersProgress {
                    progressRow("Describing the people you have met…", progress: progress)
                        .padding(.top, 12)
                } else {
                    progressRow("Finding the people you have met…")
                        .padding(.top, 12)
                }
            case .empty(let reason):
                message(reason)
            case .failed(let reason):
                failure(reason) { model.loadCharacters() }
                    .padding(.top, 12)
            case .done:
                EmptyView()
            }
        }
    }

    // MARK: Pieces

    private func progressRow(_ title: LocalizedStringKey, progress: (done: Int, total: Int)? = nil) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(palette.muted)
            }
            if let progress, progress.total > 0 {
                ProgressView(value: Double(progress.done), total: Double(progress.total))
                    .tint(palette.accent)
                    .accessibilityLabel(Text(title))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(palette.muted)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func failure(_ text: String, retry: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            message(text)
            Button("Try Again", action: retry)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(palette.accent)
                .nodusTextButtonStyle()
        }
    }

    private var footnote: some View {
        Label {
            Text("Written on this device by Apple Intelligence from the pages you have read (\(book.progress.formatted(.percent.precision(.fractionLength(0))))), so nothing ahead is given away. It can make mistakes.")
        } icon: {
            Image(systemName: "lock")
        }
        .font(.caption)
        .foregroundStyle(palette.muted)
        .padding(.top, 6)
    }
}

/// Offered over the page when a book is reopened after a break.
struct ReaderWelcomeRecapCard: View {
    let theme: ReaderTheme
    let onOpen: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "text.book.closed")
                .font(.system(size: 18))
                .foregroundStyle(theme.accent)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Welcome back")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(theme.text)
                Text("A reminder of where you left off.")
                    .font(.caption)
                    .foregroundStyle(theme.muted)
            }
            Spacer(minLength: 8)
            Button("Recap", action: onOpen)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(theme.accent)
                .frame(minHeight: 44)
                .nodusTextButtonStyle()
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.muted)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(.leading, 16)
        .padding(.trailing, 4)
        .background(theme.background, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(theme.line, lineWidth: 1))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        .frame(maxWidth: 520)
        .padding(.horizontal, 16)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

#if DEBUG
/// Launch hooks for trying recaps on real books in the sample library.
@MainActor
enum StoryCompanionDebug {
    static func importAndPlace(path: String, library: LibraryService) async -> Book? {
        let url = URL(fileURLWithPath: path)
        let result = await library.importFiles([url], into: nil) { _ in }
        let hash = try? ContentHash.sha256(of: url)
        guard let book = result.imported.first
                ?? library.allBooks().first(where: { $0.contentHash == hash }) else { return nil }
        let fraction = UserDefaults.standard.double(forKey: "NodusOpenBookAt")
        if let chapters = try? await BookTextLoader.loadChapters(for: book, fileStore: library.fileStore),
           !chapters.isEmpty {
            let lengths = chapters.map { ($0.text as NSString).length }
            var target = Int(Double(lengths.reduce(0, +)) * fraction)
            var index = 0
            while index < lengths.count - 1, target > lengths[index] {
                target -= lengths[index]
                index += 1
            }
            var locator = ReadingLocator()
            locator.chapterIndex = index
            locator.scrollFraction = lengths[index] > 0 ? Double(target) / Double(lengths[index]) : 0
            library.updateProgress(book, locator: locator, progress: fraction, preservingNarrationPosition: false)
        }
        let days = UserDefaults.standard.double(forKey: "NodusBookBreakDays")
        book.lastPositionDate = Date().addingTimeInterval(-days * 86_400)
        library.save()
        return book
    }

    /// `-NodusOpenStory recap|characters` opens the sheet once the book is in.
    static var initialTab: ReaderStoryTab? {
        UserDefaults.standard.string(forKey: "NodusOpenStory").flatMap(ReaderStoryTab.init(rawValue:))
    }
}
#endif
