// SPDX-License-Identifier: AGPL-3.0-only
#if os(macOS)
import SwiftData
import SwiftUI

/// The dedicated macOS reader window. It fills the window instead of appearing
/// as a modal sheet inside the library and can be taken full screen natively.
struct ReaderWindowHost: View {
    @Environment(\.dismissWindow) private var dismissWindow
    @Query private var books: [Book]

    private let bookID: UUID

    init(bookID: UUID) {
        self.bookID = bookID
        _books = Query(filter: #Predicate<Book> { $0.id == bookID })
    }

    var body: some View {
        Group {
            if let book = books.first {
                ReaderView(book: book) {
                    dismissWindow(id: "reader", value: bookID)
                }
            } else {
                ContentUnavailableView(
                    "Book unavailable",
                    systemImage: "book.closed",
                    description: Text("This document was removed from the library.")
                )
            }
        }
        .frame(minWidth: 900, minHeight: 680)
        .background(Color.black)
    }
}
#endif
