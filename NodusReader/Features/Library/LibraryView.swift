// SPDX-License-Identifier: AGPL-3.0-only
import DesignSystem
import SwiftData
import SwiftUI

struct LibraryView: View {
    @Environment(LibraryService.self) private var library
    @Environment(ImportCoordinator.self) private var imports
    @Environment(PlaybackController.self) private var playback
    @Environment(\.nodusPalette) private var palette

    @Query(sort: \Book.addedAt, order: .reverse) private var books: [Book]
    @Query(sort: \LibraryCollection.sortIndex) private var collections: [LibraryCollection]
    @Query private var memberships: [CollectionMembership]

    @State private var searchText = ""
    @State private var filter: LibraryFilter.Kind = .all
    @State private var sort: LibrarySort = .recentlyOpened
    @State private var isGrid = true
    @State private var selectionMode = false
    @State private var selectedIDs: Set<UUID> = []

    @State private var readingBook: Book?
    @State private var showPlayer = false
    @State private var editingBook: Book?
    @State private var collectionBooks: [Book] = []
    @State private var showCollectionSheet = false
    @State private var pendingDeletion: [Book] = []
    @State private var showDeleteConfirmation = false
    @State private var searchMatches: Set<UUID>?
    @State private var showNewCollection = false
    @State private var newCollectionName = ""

    private var filteredBooks: [Book] {
        let filtered = books.filter {
            LibraryFilter.matches($0, kind: filter) && (searchMatches?.contains($0.id) ?? true)
        }
        return sorted(filtered)
    }

    private var selectedBooks: [Book] {
        books.filter { selectedIDs.contains($0.id) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                titleRow
                searchField
                if !visibleCollections.isEmpty || searchText.isEmpty {
                    collectionsSection
                }
                LibraryFilterBar(selection: $filter)
                sortRow
                if filteredBooks.isEmpty {
                    emptyState
                } else if isGrid {
                    grid
                } else {
                    list
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 110)
        }
        .background(palette.background)
        .task(id: SearchKey(query: searchText, count: books.count)) {
            let matches = await SearchKey.debouncedMatches(searchText, books: books, library: library)
            guard !Task.isCancelled else { return }
            searchMatches = matches
        }
        .toolbar {
            ToolbarItem(placement: .nodusLeading) {
                // Icon only, like the other toolbar buttons; VoiceOver reads
                // "Select" / "Done".
                Button {
                    selectionMode.toggle()
                    if !selectionMode { selectedIDs.removeAll() }
                } label: {
                    Image(systemName: selectionMode ? "checkmark.circle.fill" : "checkmark.circle")
                        .font(.system(size: 17, weight: .medium))
                }
                .foregroundStyle(selectionMode ? palette.accent : palette.text)
                .accessibilityLabel(selectionMode ? "Done" : "Select")
            }
            ToolbarItem(placement: .principal) {
                BrandToolbar()
            }
            // One trailing item so the NODUS / READER wordmark fits on
            // iPhone; the grid/list switch sits next to Sort.
            ToolbarItem(placement: .nodusTrailing) {
                Button {
                    imports.beginImport()
                } label: {
                    Image(systemName: "plus")
                        .frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel("Import documents")
            }
        }
        .inlineNavigationTitle()
        .navigationBarBackground(palette.background)
        .safeAreaInset(edge: .bottom) {
            if selectionMode, !selectedIDs.isEmpty {
                selectionBar
            }
        }
        .navigationDestination(for: UUID.self) { id in
            CollectionDetailView(collectionID: id)
        }
        .alert("New Collection", isPresented: $showNewCollection) {
            TextField("Name", text: $newCollectionName)
            Button("Create") {
                _ = library.createCollection(name: newCollectionName)
                newCollectionName = ""
            }
            Button("Cancel", role: .cancel) { newCollectionName = "" }
        } message: {
            Text("Collections can contain subcollections and documents.")
        }
        .readerCover(item: $readingBook)
        .sheet(isPresented: $showPlayer) {
            PlayerView().presentationDragIndicator(.hidden)
        }
        .sheet(item: $editingBook) { book in
            BookInfoSheet(book: book)
        }
        .sheet(isPresented: $showCollectionSheet) {
            AddToCollectionSheet(books: collectionBooks)
        }
        .confirmationDialog("Delete from Library?", isPresented: $showDeleteConfirmation,
                            titleVisibility: .visible) {
            Button("Delete from Library", role: .destructive) {
                library.deleteBooks(pendingDeletion)
                selectedIDs.subtract(pendingDeletion.map(\.id))
                if selectedIDs.isEmpty { selectionMode = false }
                pendingDeletion = []
            }
            Button("Cancel", role: .cancel) { pendingDeletion = [] }
        } message: {
            Text(pendingDeletion.count == 1
                 ? "This removes “\(pendingDeletion.first?.title ?? "")” and its local file from Nodus Reader."
                 : "This removes \(pendingDeletion.count) documents and their local files from Nodus Reader.")
        }
    }

    // MARK: Header

    private var titleRow: some View {
        HStack(alignment: .firstTextBaseline) {
            DisplayTitle("Library")
            Spacer()
            Text("\(filteredBooks.count) books")
                .font(.footnote)
                .foregroundStyle(palette.muted)
        }
    }

    private var sortRow: some View {
        HStack {
            Text(sort.title)
                .font(.footnote)
                .foregroundStyle(palette.muted)
            Spacer()
            Button {
                isGrid.toggle()
            } label: {
                Image(systemName: isGrid ? "list.bullet" : "square.grid.2x2")
                    .font(.system(size: 16))
                    .foregroundStyle(palette.muted)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isGrid ? "Show as list" : "Show as grid")
            LibrarySortMenu(sort: $sort)
        }
    }

    private var searchField: some View {
        LibrarySearchField(text: $searchText, prompt: "Books, collections, text and notes",
                           accessibilityLabel: "Search library")
    }

    // MARK: Collections (folders)

    /// Top-level collections; while searching, every collection whose name
    /// matches, at any depth.
    private var visibleCollections: [LibraryCollection] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = query.isEmpty
            ? collections.filter { $0.parentID == nil }
            : collections.filter { $0.name.localizedCaseInsensitiveContains(query) }
        return source.sorted {
            $0.sortIndex == $1.sortIndex
                ? $0.name.localizedStandardCompare($1.name) == .orderedAscending
                : $0.sortIndex < $1.sortIndex
        }
    }

    private func bookCount(for collection: LibraryCollection) -> Int {
        let ids = Set([collection.id] + library.descendantIDs(of: collection))
        let bookIDs = memberships
            .filter { membership in membership.collection.map { ids.contains($0.id) } ?? false }
            .compactMap { $0.book?.id }
        return Set(bookIDs).count
    }

    private var collectionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Eyebrow("Collections")
                Spacer()
                Button {
                    newCollectionName = ""
                    showNewCollection = true
                } label: {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 17))
                        .foregroundStyle(palette.accent)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("New collection")
            }
            if visibleCollections.isEmpty {
                Text("Group books into folders and subfolders. A book can be in several collections without being copied.")
                    .font(.footnote)
                    .foregroundStyle(palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            } else if isGrid {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                    ForEach(visibleCollections) { collection in
                        NavigationLink(value: collection.id) {
                            CollectionFolderTile(collection: collection, bookCount: bookCount(for: collection))
                        }
                        .buttonStyle(.plain)
                    }
                }
            } else {
                VStack(spacing: 0) {
                    ForEach(visibleCollections) { collection in
                        NavigationLink(value: collection.id) {
                            CollectionSummaryRow(
                                collection: collection,
                                subcollectionCount: collections.filter { $0.parentID == collection.id }.count,
                                bookCount: bookCount(for: collection)
                            )
                        }
                        .buttonStyle(.plain)
                        if collection.id != visibleCollections.last?.id {
                            Divider().overlay(palette.line)
                        }
                    }
                }
                .panelCard(radius: 20)
            }
            Eyebrow("All books")
                .padding(.top, 6)
        }
    }

    // MARK: Grid and list

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 14), count: 3)
    }

    private var grid: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
            ForEach(filteredBooks) { book in
                BookGridCell(
                    book: book,
                    selectionMode: selectionMode,
                    isSelected: selectedIDs.contains(book.id)
                ) {
                    handleTap(book)
                }
                .contextMenu {
                    contextMenu(for: book)
                }
            }
        }
    }

    private var list: some View {
        LazyVStack(spacing: 0) {
            ForEach(filteredBooks) { book in
                Button {
                    handleTap(book)
                } label: {
                    HStack(spacing: 10) {
                        if selectionMode {
                            Image(systemName: selectedIDs.contains(book.id) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selectedIDs.contains(book.id) ? palette.accent : palette.muted)
                        }
                        BookListRow(book: book)
                    }
                }
                .buttonStyle(.plain)
                .contextMenu {
                    contextMenu(for: book)
                }
                Divider().overlay(palette.line)
            }
        }
    }

    private var emptyState: some View {
        let libraryEmpty = books.isEmpty
        let isSearching = !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let filterEmpty = !libraryEmpty && !isSearching
        return VStack(spacing: 14) {
            NodusEmptyState(
                icon: libraryEmpty ? "books.vertical" : isSearching ? "magnifyingglass" : "line.3.horizontal.decrease.circle",
                title: libraryEmpty ? "Your library is empty" : isSearching ? "No matches" : "No books here",
                message: libraryEmpty
                    ? "Import an EPUB, PDF, Markdown, text, HTML or RTF document to begin."
                    : isSearching
                        ? "Try a different title, author or passage."
                        : "No books match this filter. Try another one."
            )
            if libraryEmpty {
                PrimaryPillButton("Import documents", systemImage: "plus") {
                    imports.beginImport()
                }
                .frame(maxWidth: 260)
            } else if filterEmpty {
                Button("Show all books") {
                    filter = .all
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(palette.accent)
            }
        }
        .frame(minHeight: 380)
    }

    // MARK: Selection bar

    private var selectionBar: some View {
        HStack(spacing: 10) {
            Text("\(selectedIDs.count) selected")
                .font(.footnote.weight(.medium))
                .foregroundStyle(palette.text)
            Spacer()
            Button {
                collectionBooks = selectedBooks
                showCollectionSheet = true
            } label: {
                Label("Collection", systemImage: "folder.badge.plus")
                    .font(.footnote.weight(.medium))
            }
            .foregroundStyle(palette.accent)
            Button {
                pendingDeletion = selectedBooks
                showDeleteConfirmation = true
            } label: {
                Label("Delete", systemImage: "trash")
                    .font(.footnote.weight(.medium))
            }
            .foregroundStyle(palette.destructive)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(palette.panelRaised, in: Capsule())
        .overlay(Capsule().stroke(palette.line, lineWidth: 1))
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
    }

    // MARK: Actions

    private func handleTap(_ book: Book) {
        if selectionMode {
            if selectedIDs.contains(book.id) {
                selectedIDs.remove(book.id)
            } else {
                selectedIDs.insert(book.id)
            }
        } else {
            library.open(book)
            readingBook = book
        }
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
            onOpen: {
                library.open(book)
                readingBook = book
            },
            onReadAndListen: {
                library.open(book)
                readingBook = book
                Task { await playback.start(book: book, mode: .readAndListen) }
            },
            onAddToCollection: {
                collectionBooks = [book]
                showCollectionSheet = true
            },
            onEditInfo: {
                editingBook = book
            },
            onDelete: {
                pendingDeletion = [book]
                showDeleteConfirmation = true
            }
        )
    }
}
