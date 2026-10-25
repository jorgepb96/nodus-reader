// SPDX-License-Identifier: AGPL-3.0-only
import DesignSystem
import SwiftData
import SwiftUI

struct CollectionDetailView: View {
    @Environment(LibraryService.self) private var library
    @Environment(PlaybackController.self) private var playback
    @Environment(NavigationModel.self) private var navigation
    @Environment(\.dismiss) private var dismiss
    @Environment(\.nodusPalette) private var palette

    let collectionID: UUID
    var showsBrand: Bool = true

    @Query private var collections: [LibraryCollection]
    @Query private var memberships: [CollectionMembership]

    @State private var readingBook: Book?
    @State private var showPlayer = false
    @State private var editingBook: Book?
    @State private var collectionBooks: [Book] = []
    @State private var showCollectionSheet = false
    @State private var pendingDeletion: [Book] = []
    @State private var showDeleteBookConfirmation = false
    @State private var showDeleteCollection = false
    @State private var showRename = false
    @State private var showNewSubcollection = false
    @State private var showManualOrder = false
    @State private var showAddBooks = false
    @State private var textFieldValue = ""
    @State private var searchText = ""

    private var query: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var collection: LibraryCollection? {
        collections.first { $0.id == collectionID }
    }

    private var children: [LibraryCollection] {
        collections
            .filter { $0.parentID == collectionID }
            .filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
            .sorted {
                $0.sortIndex == $1.sortIndex
                    ? $0.name.localizedStandardCompare($1.name) == .orderedAscending
                    : $0.sortIndex < $1.sortIndex
            }
    }

    private var collectionMemberships: [CollectionMembership] {
        memberships
            .filter { $0.collection?.id == collectionID }
            .sorted { $0.sortIndex < $1.sortIndex }
    }

    private var books: [Book] {
        let all = collectionMemberships.compactMap(\.book)
        return query.isEmpty ? all : library.search(query, among: all)
    }

    private var path: [LibraryCollection] {
        guard let collection else { return [] }
        return library.collectionPath(for: collection)
    }

    private var totalBookCount: Int {
        guard let collection else { return 0 }
        let ids = Set([collection.id] + library.descendantIDs(of: collection))
        let bookIDs = memberships
            .filter { membership in membership.collection.map { ids.contains($0.id) } ?? false }
            .compactMap { $0.book?.id }
        return Set(bookIDs).count
    }

    var body: some View {
        Group {
            if let collection {
                content(collection)
            } else {
                NodusEmptyState(icon: "folder", title: "Collection not found",
                                message: "It may have been deleted on another device.")
            }
        }
        .background(palette.background)
        .toolbar {
            if showsBrand {
                ToolbarItem(placement: .principal) { BrandToolbar() }
            }
            ToolbarItem(placement: .nodusTrailing) {
                Menu {
                    Button {
                        textFieldValue = ""
                        showNewSubcollection = true
                    } label: {
                        Label("New Subcollection", systemImage: "folder.badge.plus")
                    }
                    Button {
                        showAddBooks = true
                    } label: {
                        Label("Add Books…", systemImage: "plus.circle")
                    }
                    Divider()
                    Button {
                        textFieldValue = collection?.name ?? ""
                        showRename = true
                    } label: {
                        Label("Rename…", systemImage: "pencil")
                    }
                    Divider()
                    Button(role: .destructive) {
                        showDeleteCollection = true
                    } label: {
                        Label("Delete Collection…", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 17, weight: .medium))
                        .frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel("Collection actions")
            }
        }
        .inlineNavigationTitle()
        .navigationBarBackground(palette.background)
        .navigationDestination(for: UUID.self) { id in
            CollectionDetailView(collectionID: id, showsBrand: showsBrand)
        }
        .readerCover(item: $readingBook)
        .sheet(isPresented: $showPlayer) { PlayerView().presentationDragIndicator(.hidden) }
        .sheet(item: $editingBook) { BookInfoSheet(book: $0) }
        .sheet(isPresented: $showCollectionSheet) { AddToCollectionSheet(books: collectionBooks) }
        .sheet(isPresented: $showManualOrder) {
            if let collection {
                ManualOrderSheet(collectionID: collection.id)
            }
        }
        .sheet(isPresented: $showAddBooks) {
            AddBooksToCollectionSheet(collectionID: collectionID)
        }
        .alert("Rename Collection", isPresented: $showRename) {
            TextField("Name", text: $textFieldValue)
            Button("Save") {
                if let collection { library.renameCollection(collection, to: textFieldValue) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("New Subcollection", isPresented: $showNewSubcollection) {
            TextField("Name", text: $textFieldValue)
            Button("Create") {
                _ = library.createCollection(name: textFieldValue, parentID: collectionID)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Subcollections can be nested as deeply as you need.")
        }
        .confirmationDialog("Delete Collection?", isPresented: $showDeleteCollection, titleVisibility: .visible) {
            Button("Delete Collection", role: .destructive) {
                if let collection {
                    let deletedID = collection.id
                    library.deleteCollection(collection)
                    if case .collection(let id) = navigation.sidebarSelection, id == deletedID {
                        navigation.sidebarSelection = .allBooks
                    } else {
                        dismiss()
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The collection and its subcollections are removed. The documents stay in your library.")
        }
        .confirmationDialog("Delete from Library?", isPresented: $showDeleteBookConfirmation,
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

    private func content(_ collection: LibraryCollection) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header(collection)
                LibrarySearchField(text: $searchText, prompt: "Search in \(collection.name)",
                                   accessibilityLabel: "Search this collection")
                if !children.isEmpty {
                    subcollectionCard
                }
                actionRow
                bookList(collection)
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 110)
        }
    }

    private func header(_ collection: LibraryCollection) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Eyebrow(([String(localized: "Library")] + path.map(\.name)).joined(separator: " / "))
            DisplayTitle(collection.name, size: DeviceInfo.isPad ? 44 : 36)
            Text("\(children.count) subcollections · \(totalBookCount) books")
                .font(.footnote)
                .foregroundStyle(palette.muted)
        }
    }

    private var subcollectionCard: some View {
        VStack(spacing: 0) {
            ForEach(children) { child in
                NavigationLink(value: child.id) {
                    CollectionSummaryRow(
                        collection: child,
                        subcollectionCount: collections.filter { $0.parentID == child.id }.count,
                        bookCount: childBookCount(child)
                    )
                }
                .buttonStyle(.plain)
                if child.id != children.last?.id {
                    Divider().overlay(palette.line)
                }
            }
        }
        .panelCard(radius: 20)
    }

    private var actionRow: some View {
        HStack(spacing: 8) {
            Button {
                textFieldValue = ""
                showNewSubcollection = true
            } label: {
                Label("New subcollection", systemImage: "plus")
                    .font(.footnote)
                    .foregroundStyle(palette.text)
                    .padding(.horizontal, 14)
                    .frame(height: 40)
                    .overlay(
                        Capsule().stroke(palette.isHighContrast ? palette.text : palette.accent.opacity(0.35),
                                         lineWidth: palette.isHighContrast ? 1.5 : 1)
                    )
            }
            .buttonStyle(.plain)

            Button {
                showManualOrder = true
            } label: {
                Label("Manual order", systemImage: "arrow.up.arrow.down")
                    .font(.footnote)
                    .foregroundStyle(palette.text)
                    .padding(.horizontal, 14)
                    .frame(height: 40)
                    .background(palette.panel, in: Capsule())
                    .overlay(Capsule().stroke(palette.line, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .disabled(books.isEmpty)
            .opacity(books.isEmpty ? 0.5 : 1)
        }
    }

    @ViewBuilder
    private func bookList(_ collection: LibraryCollection) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionHeading("In \(collection.name)")
                .padding(.bottom, 4)

            if books.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("No documents here yet.")
                        .font(.subheadline)
                        .foregroundStyle(palette.muted)
                    Button("Add Books…") { showAddBooks = true }
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(palette.accent)
                }
                .padding(.vertical, 12)
            }

            ForEach(books) { book in
                Button {
                    open(book)
                } label: {
                    HStack(spacing: 14) {
                        BookCoverView(book: book)
                            .frame(width: 46, height: 69)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(book.title)
                                .font(.system(size: 17, design: .serif))
                                .foregroundStyle(palette.text)
                                .lineLimit(1)
                            Text(book.displayAuthor)
                                .font(.caption)
                                .foregroundStyle(palette.muted)
                                .lineLimit(1)
                            Text(statusLine(for: book, in: collection))
                                .font(.caption2)
                                .foregroundStyle(palette.accent)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        Image(systemName: "ellipsis")
                            .font(.system(size: 15))
                            .foregroundStyle(palette.muted)
                            .frame(width: 32, height: 44)
                    }
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contextMenu {
                    BookContextActions(
                        book: book,
                        onOpen: { open(book) },
                        onReadAndListen: {
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
                            showDeleteBookConfirmation = true
                        }
                    )
                }
                Divider().overlay(palette.line)
            }
        }
    }

    private func childBookCount(_ child: LibraryCollection) -> Int {
        let ids = Set([child.id] + library.descendantIDs(of: child))
        let bookIDs = memberships
            .filter { membership in membership.collection.map { ids.contains($0.id) } ?? false }
            .compactMap { $0.book?.id }
        return Set(bookIDs).count
    }

    private func statusLine(for book: Book, in collection: LibraryCollection) -> String {
        var parts: [String] = []
        switch book.status {
        case .finished: parts.append(String(localized: "Finished"))
        case .toRead: parts.append("\(book.format.badge) · To read")
        case .inProgress: parts.append("\(book.format.badge) · \(Int((book.progress * 100).rounded()))%")
        }
        let others = library.otherCollectionNames(for: book, excluding: collection)
        if !others.isEmpty {
            parts.append("Also in \(others.joined(separator: ", "))")
        }
        return parts.joined(separator: " · ")
    }

    private func open(_ book: Book) {
        library.open(book)
        readingBook = book
    }
}

// MARK: - Manual order

struct ManualOrderSheet: View {
    @Environment(LibraryService.self) private var library
    @Environment(\.dismiss) private var dismiss

    let collectionID: UUID

    @Query private var memberships: [CollectionMembership]
    @State private var order: [Book] = []

    var body: some View {
        NavigationStack {
            List {
                ForEach(order) { book in
                    BookListRow(book: book)
                }
                .onMove { offsets, destination in
                    order.move(fromOffsets: offsets, toOffset: destination)
                    for (index, book) in order.enumerated() {
                        if let membership = memberships.first(where: {
                            $0.collection?.id == collectionID && $0.book?.id == book.id
                        }) {
                            membership.sortIndex = index
                        }
                    }
                    library.save()
                }
            }
            .manualEditMode()
            .navigationTitle("Manual Order")
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                #if os(iOS)
                ToolbarItem(placement: .primaryAction) {
                    EditButton()
                }
                #endif
            }
            .onAppear { reload() }
        }
    }

    private func reload() {
        guard let collection = memberships.first(where: { $0.collection?.id == collectionID })?.collection else {
            order = []
            return
        }
        order = library.books(in: collection)
    }
}

// MARK: - Add books

struct AddBooksToCollectionSheet: View {
    @Environment(LibraryService.self) private var library
    @Environment(\.dismiss) private var dismiss
    @Environment(\.nodusPalette) private var palette

    let collectionID: UUID

    @Query(sort: \Book.addedAt, order: .reverse) private var books: [Book]
    @Query private var collections: [LibraryCollection]
    @Query private var memberships: [CollectionMembership]
    @State private var searchText = ""

    private var collection: LibraryCollection? {
        collections.first { $0.id == collectionID }
    }

    private var filtered: [Book] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return books }
        return books.filter {
            $0.title.localizedCaseInsensitiveContains(trimmed)
                || $0.author.localizedCaseInsensitiveContains(trimmed)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(filtered) { book in
                    Button {
                        guard let collection else { return }
                        if isInCollection(book) {
                            library.remove(book, from: collection)
                        } else {
                            library.add(book, to: collection)
                        }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: isInCollection(book) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(isInCollection(book) ? palette.accent : palette.muted)
                            BookListRow(book: book)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .librarySearchable(text: $searchText, prompt: "Search books")
            .navigationTitle(collection?.name ?? String(localized: "Add Books"))
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        #if os(iOS)
        .presentationDetents([.large])
        #endif
    }

    private func isInCollection(_ book: Book) -> Bool {
        memberships.contains { $0.collection?.id == collectionID && $0.book?.id == book.id }
    }
}
