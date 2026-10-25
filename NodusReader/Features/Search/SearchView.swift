// SPDX-License-Identifier: AGPL-3.0-only
import DesignSystem
import SwiftData
import SwiftUI

struct SearchView: View {
    @Environment(LibraryService.self) private var library
    @Environment(PlaybackController.self) private var playback
    @Environment(\.nodusPalette) private var palette

    @Query(sort: \Book.addedAt, order: .reverse) private var books: [Book]
    @State private var searchText = ""

    @State private var readingBook: Book?
    @State private var showPlayer = false
    @State private var editingBook: Book?
    @State private var collectionBooks: [Book] = []
    @State private var showCollectionSheet = false
    @State private var pendingDeletion: [Book] = []
    @State private var showDeleteConfirmation = false

    @State private var searchMatches: Set<UUID>?

    private var results: [Book] {
        guard let searchMatches else {
            return searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? books : []
        }
        return books.filter { searchMatches.contains($0.id) }
    }

    var body: some View {
        content
            .task(id: SearchKey(query: searchText, count: books.count)) {
                let matches = await SearchKey.debouncedMatches(searchText, books: books, library: library)
                guard !Task.isCancelled else { return }
                searchMatches = matches
            }
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    emptyPrompt
                } else {
                    Text("\(results.count) \(results.count == 1 ? "result" : "results")")
                        .font(.caption)
                        .foregroundStyle(palette.muted)
                        .padding(.horizontal, 20)

                    if results.isEmpty {
                        NodusEmptyState(
                            icon: "magnifyingglass",
                            title: "No matches",
                            message: "Search across titles, authors and the text of your documents."
                        )
                        .frame(minHeight: 320)
                    } else {
                        LazyVStack(spacing: 0) {
                            ForEach(results) { book in
                                Button {
                                    library.open(book)
                                    readingBook = book
                                } label: {
                                    BookListRow(book: book)
                                        .padding(.horizontal, 20)
                                }
                                .buttonStyle(.plain)
                                .contextMenu { contextMenu(for: book) }
                                Divider().overlay(palette.line).padding(.leading, 80)
                            }
                        }
                    }
                }
            }
            .padding(.top, 8)
            .padding(.bottom, 110)
        }
        .background(palette.background)
        .librarySearchable(text: $searchText, prompt: "Titles, authors, text and notes")
        .toolbar {
            ToolbarItem(placement: .principal) { BrandToolbar() }
        }
        .inlineNavigationTitle()
        .navigationBarBackground(palette.background)
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

    private var emptyPrompt: some View {
        VStack(alignment: .leading, spacing: 10) {
            DisplayTitle("Search")
            Text("Find a title, an author or a passage across your library.")
                .font(.subheadline)
                .foregroundStyle(palette.muted)
            VStack(alignment: .leading, spacing: 10) {
                searchHint("text.book.closed", "Titles and authors")
                searchHint("text.magnifyingglass", "Full text of imported documents")
                searchHint("folder", "Collection names")
                searchHint("note.text", "Notes and highlighted passages")
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .panelCard(radius: 20)
            .padding(.top, 4)
        }
        .padding(.horizontal, 20)
    }

    private func searchHint(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(palette.accent)
                .frame(width: 22)
            Text(text)
                .font(.footnote)
                .foregroundStyle(palette.muted)
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
