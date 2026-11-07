// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI

/// A search field types into a draft that only the field reads, so each key
/// redraws the field alone. The screen's query, which filters a long list,
/// follows once typing pauses: rebuilding the list on every key held each
/// letter back until the whole screen had been redrawn.
enum SearchCommit {
    static let pause: Duration = .milliseconds(250)

    /// How long to wait before the query follows the draft; nil when it
    /// already does. Clearing the field applies at once.
    static func delay(draft: String, applied: String) -> Duration? {
        guard draft != applied else { return nil }
        return draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .zero : pause
    }
}

extension View {
    /// Applies `draft` to `query` after a pause in typing, and copies a query
    /// set elsewhere (a Clear button, a reset) back into the field. The view
    /// that owns both must read only `query` in its body.
    func committingSearch(_ draft: Binding<String>, to query: Binding<String>) -> some View {
        background(SearchCommitter(draft: draft, query: query))
    }
}

/// Reads the draft in its own body, so keystrokes invalidate this empty view
/// instead of the screen that owns the text.
private struct SearchCommitter: View {
    @Binding var draft: String
    @Binding var query: String

    var body: some View {
        Color.clear
            .accessibilityHidden(true)
            .task(id: draft) {
                guard let delay = SearchCommit.delay(draft: draft, applied: query) else { return }
                if delay > .zero {
                    try? await Task.sleep(for: delay)
                    guard !Task.isCancelled else { return }
                }
                query = draft
            }
            .onChange(of: query) { _, newValue in
                // Only a change made elsewhere: a commit already equals the draft.
                if newValue != draft { draft = newValue }
            }
    }
}

/// Owns the text being typed, so a keystroke redraws only `content` (the
/// field) and not the screen that holds `query`. Build just the field here.
struct DraftSearchText<Content: View>: View {
    @Binding var query: String
    @ViewBuilder let content: (Binding<String>) -> Content
    @State private var draft: String

    init(query: Binding<String>, @ViewBuilder content: @escaping (Binding<String>) -> Content) {
        _query = query
        self.content = content
        _draft = State(initialValue: query.wrappedValue)
    }

    var body: some View {
        content($draft)
            .committingSearch($draft, to: $query)
    }
}

extension View {
    /// `.searchable` whose typing stays in the search bar: the modified view
    /// sees `query` only once typing pauses.
    func searchableDraft(_ query: Binding<String>, prompt: LocalizedStringKey) -> some View {
        modifier(SearchableDraft(query: query, prompt: prompt))
    }
}

private struct SearchableDraft: ViewModifier {
    @Binding var query: String
    let prompt: LocalizedStringKey
    @State private var draft = ""

    func body(content: Content) -> some View {
        // A modifier's own state does not re-evaluate `content`.
        content
            .searchable(text: $draft, prompt: prompt)
            .committingSearch($draft, to: $query)
    }
}
