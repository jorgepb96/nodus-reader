// SPDX-License-Identifier: AGPL-3.0-only
import DesignSystem
import SwiftData
import SwiftUI

struct HomeView: View {
    @Environment(NavigationModel.self) private var navigation
    @Environment(ImportCoordinator.self) private var imports
    @Environment(PlaybackController.self) private var playback
    @Environment(\.nodusPalette) private var palette

    @Query(sort: \Book.addedAt, order: .reverse) private var books: [Book]

    var titleSize: CGFloat = DeviceInfo.isPad ? 44 : 36
    var showsBrand: Bool = true

    @State private var readingBook: Book?
    @State private var showPlayer = false

    private var continueBook: Book? {
        let opened = books
            .filter { $0.lastOpenedAt != nil }
            .sorted { ($0.lastOpenedAt ?? .distantPast) > ($1.lastOpenedAt ?? .distantPast) }
        return opened.first { $0.status != .finished && $0.progress < 0.999 } ?? opened.first
    }

    private var upNext: [Book] {
        let currentID = continueBook?.id
        return books
            .filter { $0.id != currentID && $0.status != .finished }
            .sorted {
                let lhs = $0.lastOpenedAt ?? $0.addedAt
                let rhs = $1.lastOpenedAt ?? $1.addedAt
                return lhs > rhs
            }
            .prefix(8)
            .map { $0 }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                if let continueBook {
                    continueCard(continueBook)
                } else {
                    emptyCard
                }
                if !upNext.isEmpty {
                    upNextSection
                }
            }
            .frame(maxWidth: DeviceInfo.isPad ? 900 : .infinity, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: DeviceInfo.isPad ? .center : .leading)
            .padding(.horizontal, DeviceInfo.isPad ? 40 : 20)
            .padding(.top, 12)
            .padding(.bottom, 120)
        }
        .background(palette.background)
        .toolbar {
            if showsBrand {
                ToolbarItem(placement: .principal) {
                    BrandToolbar()
                }
            }
            ToolbarItem(placement: .nodusTrailing) {
                Button {
                    imports.beginImport()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(palette.text)
                        .frame(width: 44, height: 44)
                        .background(palette.panel, in: Circle())
                        .overlay(Circle().stroke(palette.line, lineWidth: 1))
                }
                .accessibilityLabel("Import documents")
            }
        }
        .inlineNavigationTitle()
        .readerCover(item: $readingBook)
        .sheet(isPresented: $showPlayer) {
            PlayerView()
                .presentationDragIndicator(.hidden)
        }
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

    private func continueCard(_ book: Book) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Button {
                open(book)
            } label: {
                BookCoverView(book: book)
                    .frame(width: 96, height: 144)
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
                    OutlinePillButton("Listen", systemImage: "headphones") {
                        listen(to: book)
                    }
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
            PrimaryPillButton("Import documents", systemImage: "plus") {
                imports.beginImport()
            }
            .frame(maxWidth: 280)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelCard(radius: 22)
    }

    // MARK: Up next

    private var upNextSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                SectionHeading("Up next")
                Spacer()
                Button("See all") {
                    seeAll()
                }
                .font(.subheadline)
                .foregroundStyle(palette.accent)
                .accessibilityHint("Shows the whole library")
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(upNext) { book in
                        Button {
                            open(book)
                        } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                BookCoverView(book: book)
                                    .frame(width: 104, height: 156)
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
                            .frame(width: 104, alignment: .leading)
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

    private func seeAll() {
        if DeviceInfo.isPad {
            navigation.sidebarSelection = .allBooks
        } else {
            navigation.phoneTab = .library
        }
    }

    private func continueEyebrow(for book: Book) -> String? {
        let source = book.lastPositionDevice
        guard !source.isEmpty, source != DeviceInfo.name else { return nil }
        let label: String
        if source.localizedCaseInsensitiveContains("mac") {
            label = "your Mac"
        } else if source.localizedCaseInsensitiveContains("ipad") {
            label = "your iPad"
        } else if source.localizedCaseInsensitiveContains("iphone") {
            label = "your iPhone"
        } else {
            label = source
        }
        return "Continue · from \(label)"
    }

    private func chapterLine(for book: Book) -> String {
        let titles = book.chapterTitles
        let index = min(max(book.locator.chapterIndex, 0), max(titles.count - 1, 0))
        if titles.indices.contains(index) {
            return "Chapter \(index + 1) · \(titles[index])"
        }
        return book.format == .pdf ? "PDF" : "Chapter \(index + 1)"
    }

    private func metaLine(for book: Book) -> String {
        switch book.status {
        case .finished: "\(book.format.badge) · Finished"
        case .toRead: "\(book.format.badge) · To read"
        case .inProgress: "\(book.format.badge) · \(Int((book.progress * 100).rounded()))%"
        }
    }
}

// MARK: - Reader presentation

extension View {
    @ViewBuilder
    func readerCover(item: Binding<Book?>) -> some View {
        #if os(macOS)
        sheet(item: item) { book in
            ReaderView(book: book)
                .frame(minWidth: 980, minHeight: 720)
        }
        #else
        fullScreenCover(item: item) { book in
            ReaderView(book: book)
        }
        #endif
    }
}
