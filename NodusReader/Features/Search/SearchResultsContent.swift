// SPDX-License-Identifier: AGPL-3.0-only
import DesignSystem
import SwiftData
import SwiftUI

struct SearchResultsContent: View {
    @Environment(LibraryService.self) private var library
    @Environment(PlaybackController.self) private var playback
    @Environment(\.nodusPalette) private var palette
    @Environment(\.usesPadLayout) private var usesPadLayout

    let query: String

    @Query(sort: \Book.addedAt, order: .reverse) private var books: [Book]

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
            return query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? books : []
        }
        return books.filter { searchMatches.contains($0.id) }
    }

    var body: some View {
        content
            .task(id: SearchKey(query: query, count: books.count)) {
                let matches = await SearchKey.debouncedMatches(query, books: books, library: library)
                guard !Task.isCancelled else { return }
                searchMatches = matches
            }
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Eyebrow("Search")
                    DisplayTitle("Results", size: usesPadLayout ? 44 : 36)
                    Text(results.count == 1 ? "1 match for “\(query)”" : "\(results.count) matches for “\(query)”")
                        .font(.footnote)
                        .foregroundStyle(palette.muted)
                }

                if results.isEmpty {
                    NodusEmptyState(
                        icon: "magnifyingglass",
                        title: "No matches",
                        message: "Try a different title, author or passage."
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
                            }
                            .buttonStyle(.plain)
                            .contextMenu { contextMenu(for: book) }
                            Divider().overlay(palette.line)
                        }
                    }
                }
            }
            .frame(maxWidth: 900)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, usesPadLayout ? 40 : 20)
            .padding(.top, 8)
            .padding(.bottom, 110)
        }
        .background(palette.background)
        .readerCover(item: $readingBook)
        .playerSheet(isPresented: $showPlayer)
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
