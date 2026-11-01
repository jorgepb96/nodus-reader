// SPDX-License-Identifier: AGPL-3.0-only
#if os(macOS)
import DesignSystem
import SwiftData
import SwiftUI

/// The macOS reader, shown in the library window in place of the library.
/// It fills the window, takes the title bar strip beside the window buttons
/// and can be taken full screen with the window.
struct MacReaderHost: View {
    @Environment(ThemeManager.self) private var theme
    @Environment(\.colorScheme) private var colorScheme
    @Query private var books: [Book]

    private let onClose: () -> Void

    init(bookID: UUID, onClose: @escaping () -> Void) {
        self.onClose = onClose
        _books = Query(filter: #Predicate<Book> { $0.id == bookID })
    }

    private var palette: NodusPalette {
        theme.palette(colorScheme: colorScheme)
    }

    var body: some View {
        Group {
            if let book = books.first {
                // The reader sets the window's colour scheme from the book's
                // theme; a second, app-level preference here competed with it.
                ReaderView(book: book, onClose: onClose)
                    .id(book.id)
            } else {
                ContentUnavailableView {
                    Label("Book unavailable", systemImage: "book.closed")
                } description: {
                    Text("This document was removed from the library.")
                } actions: {
                    Button("Close", action: onClose)
                }
                .preferredColorScheme(theme.appTheme.preferredColorScheme)
            }
        }
        .frame(minWidth: 900, minHeight: 680)
        .background(palette.background)
        .nodusPalette(palette)
        .tint(palette.accent)
        // No library toolbar or window title over the reader: its own bar
        // takes that strip.
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .navigationTitle(books.first?.title ?? "")
    }
}
#endif
