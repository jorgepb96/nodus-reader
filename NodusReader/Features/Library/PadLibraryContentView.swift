// SPDX-License-Identifier: AGPL-3.0-only
import DesignSystem
import SwiftData
import SwiftUI

struct PadLibraryContentView: View {
    @Environment(LibraryService.self) private var library
    @Environment(ImportCoordinator.self) private var imports
    @Environment(PlaybackController.self) private var playback
    @Environment(\.nodusPalette) private var palette

    let selection: SidebarDestination

    @Query(sort: \Book.addedAt, order: .reverse) private var books: [Book]

    @State private var filter: LibraryFilter.Kind = .all
    @State private var sort: LibrarySort = .recentlyOpened
    @State private var isGrid = true
    @State private var readingBook: Book?
    @State private var showPlayer = false
    @State private var editingBook: Book?
    @State private var collectionBooks: [Book] = []
    @State private var showCollectionSheet = false
    @State private var pendingDeletion: [Book] = []
    @State private var showDeleteConfirmation = false

    private var title: String {
        selection.smartList?.title ?? "Library"
    }

    private var filteredBooks: [Book] {
        let inList = books.filter { book in
            guard let list = selection.smartList else { return true }
            switch list {
            case .home, .allBooks: return true
            case .favorites: return book.isFavorite
            case .toRead: return book.status == .toRead
            case .finished: return book.status == .finished
            case .inbox: return book.memberships.isEmpty
            }
        }
        let filtered = inList.filter { LibraryFilter.matches($0, kind: filter) }
        return sorted(filtered)
    }

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 26), count: 5)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                LibraryFilterBar(selection: $filter, includesEPUB: true)
                HStack {
                    Text(sort.title)
                        .font(.footnote)
                        .foregroundStyle(palette.muted)
                    Spacer()
                    LibrarySortMenu(sort: $sort)
                }
                if filteredBooks.isEmpty {
                    emptyState
                } else if isGrid {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 26) {
                        ForEach(filteredBooks) { book in
                            BookGridCell(book: book, selectionMode: false, isSelected: false) {
                                open(book)
                            }
                            .contextMenu { contextMenu(for: book) }
                        }
                    }
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredBooks) { book in
                            Button {
                                open(book)
                            } label: {
                                BookListRow(book: book)
                            }
                            .buttonStyle(.plain)
                            .contextMenu { contextMenu(for: book) }
                            Divider().overlay(palette.line)
                        }
                    }
                }
            }
            .padding(.horizontal, 40)
            .padding(.top, 18)
            .padding(.bottom, 110)
        }
        .background(palette.background)
        .navigationTitle("")
        .readerCover(item: $readingBook)
        .sheet(isPresented: $showPlayer) { PlayerView().presentationDragIndicator(.hidden) }
        .sheet(item: $editingBook) { BookInfoSheet(book: $0) }
        .sheet(isPresented: $showCollectionSheet) { AddToCollectionSheet(books: collectionBooks) }
        .confirmationDialog("Delete from Library?", isPresented: $showDeleteConfirmation,
                            titleVisibility: .visible) {
            Button("Delete from Library", role: .destructive) {
                library.deleteBooks(pendingDeletion)
                pendingDeletion = []
            }
            Button("Cancel", role: .cancel) { pendingDeletion = [] }
        } message: {
            Text(pendingDeletion.count == 1
                 ? "This removes “\(pendingDeletion.first?.title ?? "")” and its local file from Nodus Reader."
                 : "This removes \(pendingDeletion.count) documents and their local files from Nodus Reader.")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Eyebrow("Library / \(title)")
                Spacer()
                HStack(spacing: 8) {
                    Button {
                        isGrid = true
                    } label: {
                        Image(systemName: "square.grid.2x2")
                            .frame(width: 44, height: 44)
                            .foregroundStyle(isGrid ? palette.accent : palette.text)
                            .background(isGrid ? palette.selection : palette.panel, in: Circle())
                            .overlay(Circle().stroke(isGrid ? Color.clear : palette.line, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Grid view")

                    Button {
                        isGrid = false
                    } label: {
                        Image(systemName: "list.bullet")
                            .frame(width: 44, height: 44)
                            .foregroundStyle(!isGrid ? palette.accent : palette.text)
                            .background(!isGrid ? palette.selection : palette.panel, in: Circle())
                            .overlay(Circle().stroke(!isGrid ? Color.clear : palette.line, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("List view")

                    Button {
                        imports.beginImport()
                    } label: {
                        Label("Import", systemImage: "plus")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(palette.onAccent)
                            .padding(.horizontal, 16)
                            .frame(height: 44)
                            .background(palette.accent, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack(alignment: .firstTextBaseline) {
                DisplayTitle(title, size: 44)
                Spacer()
                Text("\(filteredBooks.count) books")
                    .font(.footnote)
                    .foregroundStyle(palette.muted)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            NodusEmptyState(
                icon: "books.vertical",
                title: filteredBooks.isEmpty ? "No books here yet" : "No matches",
                message: "Import a document or change the filters."
            )
            PrimaryPillButton("Import documents", systemImage: "plus") {
                imports.beginImport()
            }
            .frame(maxWidth: 260)
        }
        .frame(minHeight: 420)
        .frame(maxWidth: .infinity)
    }

    private func open(_ book: Book) {
        library.open(book)
        readingBook = book
    }

    private func sorted(_ books: [Book]) -> [Book] {
        switch sort {
        case .recentlyOpened:
            return books.sorted { ($0.lastOpenedAt ?? .distantPast) > ($1.lastOpenedAt ?? .distantPast) }
        case .recentlyAdded:
            return books.sorted { $0.addedAt > $1.addedAt }
        case .title:
            return books.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .author:
            return books.sorted { $0.author.localizedStandardCompare($1.author) == .orderedAscending }
        }
    }

    @ViewBuilder
    private func contextMenu(for book: Book) -> some View {
        BookContextActions(
            book: book,
            onOpen: { open(book) },
            onReadAndListen: {
                library.open(book)
                readingBook = book
                Task { await playback.start(book: book, mode: .readAndListen) }
            },
            onAddToCollection: {
                collectionBooks = [book]
                showCollectionSheet = true
            },
            onEditInfo: { editingBook = book },
            onDelete: {
                pendingDeletion = [book]
                showDeleteConfirmation = true
            }
        )
    }
}
