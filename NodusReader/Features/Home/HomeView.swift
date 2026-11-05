// SPDX-License-Identifier: AGPL-3.0-only
import DesignSystem
import SwiftData
import SwiftUI

struct HomeView: View {
    @Environment(ImportCoordinator.self) private var imports
    @Environment(PlaybackController.self) private var playback
    @Environment(\.nodusPalette) private var palette
    @Environment(\.usesPadLayout) private var usesPadLayout

    @Query(sort: \Book.addedAt, order: .reverse) private var books: [Book]

    var titleSize: CGFloat = 36
    var showsBrand: Bool = true

    @State private var readingBook: Book?
    @State private var showPlayer = false

    private var continueBook: Book? {
        let opened = books
            .filter { $0.lastOpenedAt != nil }
            .sorted { ($0.lastOpenedAt ?? .distantPast) > ($1.lastOpenedAt ?? .distantPast) }
        return opened.first { $0.status != .finished && $0.progress < 0.999 } ?? opened.first
    }

    private var shelves: [HomeFormatShelf] {
        HomeFormatShelf.make(from: books)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                if let continueBook {
                    continueCard(continueBook)
                } else if books.isEmpty {
                    emptyCard
                }
                ForEach(shelves) { shelf in
                    shelfSection(shelf)
                }
            }
            .frame(maxWidth: usesPadLayout ? 900 : .infinity, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: usesPadLayout ? .center : .leading)
            .padding(.horizontal, usesPadLayout ? 40 : 20)
            .padding(.top, 12)
            .padding(.bottom, 120)
        }
        .background(palette.background)
        .toolbar {
            if showsBrand {
                ToolbarItem(placement: .principal) {
                    BrandToolbar()
                }.nodusPlainBackground()
            }
            #if os(macOS)
            ToolbarItem(placement: .nodusTrailing) {
                MacImportToolbarButton()
            }
            .nodusPlainBackground()
            #else
            ToolbarItem(placement: .nodusTrailing) {
                ImportMenu {
                    Image(systemName: "plus")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(palette.text)
                        .frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel("Import documents")
            }
            #endif
        }
        .inlineNavigationTitle()
        .readerCover(item: $readingBook)
        .playerSheet(isPresented: $showPlayer)
        .onChange(of: playback.activeBook?.id) { _, newValue in
            if newValue != nil, playback.errorMessage != nil {
                showPlayer = true
            }
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            DisplayTitle("Reading now", size: titleSize)
            Text("Pick up where you left off, on any device.")
                .font(.subheadline)
                .foregroundStyle(palette.muted)
        }
        .padding(.top, 4)
    }

    // MARK: Continue card

    private var continueCoverSize: CGSize {
        if usesPadLayout { return CGSize(width: 120, height: 180) }
        #if os(macOS)
        return CGSize(width: 112, height: 168)
        #else
        return CGSize(width: 96, height: 144)
        #endif
    }

    /// Read and Listen keep the iPad width on the Mac instead of filling it.
    private var wideButtonWidth: CGFloat? {
        #if os(macOS)
        190
        #else
        usesPadLayout ? 190 : nil
        #endif
    }

    private func continueCard(_ book: Book) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Button {
                open(book)
            } label: {
                BookCoverView(book: book)
                    .frame(width: continueCoverSize.width, height: continueCoverSize.height)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Read \(book.title)")

            VStack(alignment: .leading, spacing: 4) {
                if let eyebrow = continueEyebrow(for: book) {
                    Eyebrow(eyebrow, color: palette.accent)
                        .lineLimit(1)
                        .padding(.bottom, 1)
                }
                Text(book.title)
                    .font(.system(size: 23, weight: .regular, design: .serif))
                    .tracking(-0.3)
                    .lineLimit(2)
                    .foregroundStyle(palette.text)
                Text(book.displayAuthor)
                    .font(.footnote)
                    .foregroundStyle(palette.muted)
                    .lineLimit(1)
                Text(chapterLine(for: book))
                    .font(.footnote)
                    .foregroundStyle(palette.text)
                    .lineLimit(1)
                    .padding(.top, 2)
                HStack(spacing: 8) {
                    NodusProgressBar(value: book.progress)
                    Text("\(Int((book.progress * 100).rounded()))%")
                        .font(.caption2)
                        .foregroundStyle(palette.muted)
                        .monospacedDigit()
                }
                .padding(.top, 4)

                HStack(spacing: 8) {
                    PrimaryPillButton("Read") { open(book) }
                        .frame(maxWidth: wideButtonWidth ?? .infinity)
                    OutlinePillButton("Listen", systemImage: "headphones") {
                        listen(to: book)
                    }
                    .frame(maxWidth: wideButtonWidth ?? .infinity)
                    if wideButtonWidth != nil { Spacer(minLength: 0) }
                }
                .padding(.top, 6)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .panelCard(radius: 22)
    }

    private var emptyCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Eyebrow("Your library", color: palette.accent)
            Text("Import your first document")
                .font(.system(.title2, design: .serif))
            Text("EPUB, PDF, Markdown, text, HTML and RTF stay on this device. Nothing is uploaded.")
                .font(.subheadline)
                .foregroundStyle(palette.muted)
            VStack(spacing: 14) {
                PrimaryPillButton("Import documents", systemImage: "plus") {
                    imports.beginImport()
                }
                OutlinePillButton("Paste text", systemImage: "doc.on.clipboard") {
                    imports.beginPasteText()
                }
            }
            .frame(maxWidth: 280)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelCard(radius: 22)
    }

    // MARK: Format shelves

    private var shelfCoverWidth: CGFloat {
        if usesPadLayout { return 132 }
        #if os(macOS)
        return 120
        #else
        return 104
        #endif
    }

    private var shelfSpacing: CGFloat {
        usesPadLayout ? 16 : 14
    }

    private func shelfSection(_ shelf: HomeFormatShelf) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                SectionHeading(shelf.format.homeShelfTitle)
                Spacer()
                NavigationLink {
                    HomeFormatBooksView(format: shelf.format)
                } label: {
                    Text("See all")
                }
                .font(.subheadline)
                .foregroundStyle(palette.accent)
                .nodusTextButtonStyle()
                .accessibilityIdentifier("HomeShelfSeeAll-\(shelf.format.rawValue)")
            }
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: shelfSpacing) {
                    ForEach(shelf.books.prefix(8)) { book in
                        Button {
                            open(book)
                        } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                BookCoverView(book: book)
                                    .frame(width: shelfCoverWidth, height: shelfCoverWidth * 1.5)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(book.title)
                                        .font(.footnote.weight(.medium))
                                        .foregroundStyle(palette.text)
                                        .lineLimit(1)
                                    Text(metaLine(for: book))
                                        .font(.caption2)
                                        .foregroundStyle(palette.muted)
                                        .lineLimit(1)
                                }
                            }
                            .frame(width: shelfCoverWidth, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(book.title) by \(book.displayAuthor)")
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    // MARK: Actions

    private func open(_ book: Book) {
        readingBook = book
    }

    private func listen(to book: Book) {
        showPlayer = true
        Task { await playback.start(book: book, mode: .listen) }
    }

    private func continueEyebrow(for book: Book) -> String? {
        let source = book.lastPositionDevice
        guard !source.isEmpty, source != DeviceInfo.name else { return String(localized: "Continue") }
        let label: String
        if source.localizedCaseInsensitiveContains("mac") {
            label = String(localized: "your Mac")
        } else if source.localizedCaseInsensitiveContains("ipad") {
            label = String(localized: "your iPad")
        } else if source.localizedCaseInsensitiveContains("iphone") {
            label = String(localized: "your iPhone")
        } else {
            label = source
        }
        return String(localized: "Continue · from \(label)")
    }

    private func chapterLine(for book: Book) -> String {
        let titles = book.chapterTitles
        let index = min(max(book.locator.chapterIndex, 0), max(titles.count - 1, 0))
        if titles.indices.contains(index) {
            return String(localized: "Chapter \(index + 1) · \(titles[index])")
        }
        return book.format == .pdf ? "PDF" : String(localized: "Chapter \(index + 1)")
    }

    private func metaLine(for book: Book) -> String {
        switch book.status {
        case .finished: String(localized: "\(book.format.badge) · Finished")
        case .toRead: String(localized: "\(book.format.badge) · To read")
        case .inProgress: String(localized: "\(book.format.badge) · \(Int((book.progress * 100).rounded()))%")
        }
    }
}

struct HomeFormatShelf: Identifiable {
    let format: BookFormat
    let books: [Book]
    var id: BookFormat { format }

    static func make(from books: [Book]) -> [HomeFormatShelf] {
        let firstFormats: [BookFormat] = [.epub, .txt, .pdf]
        let order = firstFormats + BookFormat.allCases.filter { !firstFormats.contains($0) }
        let grouped = Dictionary(grouping: books, by: \.format)
        return order.compactMap { format in
            guard let documents = grouped[format], !documents.isEmpty else { return nil }
            // Include finished documents and the Continue book: a format gets
            // a shelf whenever the library contains any document of that kind.
            return HomeFormatShelf(format: format, books: documents.sorted {
                ($0.lastOpenedAt ?? $0.addedAt) > ($1.lastOpenedAt ?? $1.addedAt)
            })
        }
    }
}

private extension BookFormat {
    var homeShelfTitle: String {
        // Pasted text and imported plain-text files share the TXT format.
        self == .txt ? String(localized: "Texts") : label
    }
}

/// "See all" belongs to its format, including documents beyond the preview.
private struct HomeFormatBooksView: View {
    @Environment(\.nodusPalette) private var palette
    @Query private var books: [Book]
    @State private var readingBook: Book?
    let format: BookFormat

    init(format: BookFormat) {
        self.format = format
        let rawFormat = format.rawValue
        _books = Query(filter: #Predicate<Book> { $0.formatRaw == rawFormat },
                       sort: \Book.addedAt, order: .reverse)
    }

    private var orderedBooks: [Book] {
        books.sorted { ($0.lastOpenedAt ?? $0.addedAt) > ($1.lastOpenedAt ?? $1.addedAt) }
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: LibraryView.gridColumns, alignment: .leading, spacing: 20) {
                ForEach(orderedBooks) { book in
                    BookGridCell(book: book, selectionMode: false, isSelected: false) {
                        readingBook = book
                    }
                }
            }
            .padding(20)
            .padding(.bottom, 110)
        }
        .background(palette.background)
        .navigationTitle(format.homeShelfTitle)
        .inlineNavigationTitle()
        .navigationBarBackground(palette.background)
        .readerCover(item: $readingBook)
    }
}

// MARK: - Reader presentation

extension View {
    @ViewBuilder
    func readerCover(item: Binding<Book?>) -> some View {
        #if os(macOS)
        modifier(MacReaderWindowPresenter(item: item))
        #else
        fullScreenCover(item: item) { book in
            ReaderCoverHost(book: book)
        }
        #endif
    }
}

#if !os(macOS)
private struct ReaderCoverHost: View {
    @Environment(\.dismiss) private var dismiss
    /// Absent for the cover the scene root presents for imported books.
    @Environment(NavigationModel.self) private var navigation: NavigationModel?
    let book: Book

    var body: some View {
        ReaderView(book: book) { dismiss() }
            .onAppear { navigation?.openReaders += 1 }
            .onDisappear { navigation.map { $0.openReaders = max(0, $0.openReaders - 1) } }
    }
}
#endif

#if os(macOS)
/// On macOS the reader replaces the library in the same window (see
/// `MacReaderHost`) instead of opening a window of its own.
private struct MacReaderWindowPresenter: ViewModifier {
    @Environment(NavigationModel.self) private var navigation: NavigationModel?
    @Binding var item: Book?

    func body(content: Content) -> some View {
        content.onChange(of: item?.id) { _, _ in
            guard let book = item else { return }
            item = nil
            navigation?.macReaderBookID = book.id
        }
    }
}
#endif
