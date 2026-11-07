// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI

extension View {
    /// Confirms deleting `book` from a dialog attached to this view (the
    /// book's cover or row), so it opens beside the book rather than at the
    /// bottom or top of the screen. `deleting` names the book being asked about.
    func confirmsDeletion(of book: Book, deleting: Binding<Book?>,
                          perform: @escaping (Book) -> Void) -> some View {
        confirmationDialog("Delete from Library?",
                           isPresented: Binding(get: { deleting.wrappedValue?.id == book.id },
                                                set: { if !$0, deleting.wrappedValue?.id == book.id { deleting.wrappedValue = nil } }),
                           titleVisibility: .visible) {
            Button("Delete from Library", role: .destructive) {
                deleting.wrappedValue = nil
                perform(book)
            }
            Button("Cancel", role: .cancel) { deleting.wrappedValue = nil }
        } message: {
            Text("This removes “\(book.title)” and its local file from Nodus Reader.")
        }
    }
}
