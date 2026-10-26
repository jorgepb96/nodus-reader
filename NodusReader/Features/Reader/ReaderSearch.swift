// SPDX-License-Identifier: AGPL-3.0-only
import DesignSystem
import Foundation
import Observation
import SwiftUI

/// One occurrence of the search text: a range of a chapter's text.
struct ReaderSearchMatch: Hashable, Sendable {
    let chapterIndex: Int
    let range: NSRange
}

enum ReaderSearch {
    /// Enough for any real search; a one-letter query in a long book stops here.
    static let maximumMatches = 5_000

    /// Every occurrence of `query` in reading order, ignoring case and accents
    /// ("accion" finds "acción").
    static func matches(for query: String, in chapters: [String]) -> [ReaderSearchMatch] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        var results: [ReaderSearchMatch] = []
        for (chapterIndex, text) in chapters.enumerated() {
            let ns = text as NSString
            var searchRange = NSRange(location: 0, length: ns.length)
            while searchRange.length > 0 {
                if Task.isCancelled { return results }
                let found = ns.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive],
                                     range: searchRange)
                guard found.location != NSNotFound, found.length > 0 else { break }
                results.append(ReaderSearchMatch(chapterIndex: chapterIndex, range: found))
                if results.count >= maximumMatches { return results }
                let next = NSMaxRange(found)
                searchRange = NSRange(location: next, length: ns.length - next)
            }
        }
        return results
    }

    /// The match to show first: the first one at or after the reading
    /// position, or the first in the book when the position is past them all.
    static func firstIndex(in matches: [ReaderSearchMatch], fromChapter chapter: Int, offset: Int) -> Int? {
        guard !matches.isEmpty else { return nil }
        return matches.firstIndex {
            $0.chapterIndex > chapter || ($0.chapterIndex == chapter && $0.range.location >= offset)
        } ?? 0
    }
}

/// The reader's find state, shared by the search bar and the content that
/// highlights and scrolls to the matches.
@MainActor
@Observable
final class ReaderSearchModel {
    var isPresented = false
    var query = ""
    /// Matches in chapter text (EPUB and documents). PDFs report only their
    /// count, from PDFKit.
    private(set) var matches: [ReaderSearchMatch] = []
    var count = 0
    var current: Int?
    var isSearching = false

    var currentMatch: ReaderSearchMatch? {
        guard let current, matches.indices.contains(current) else { return nil }
        return matches[current]
    }

    /// Matches grouped by chapter, for the highlight overlay.
    private(set) var rangesByChapter: [Int: [NSRange]] = [:]

    func setMatches(_ matches: [ReaderSearchMatch], startingAt index: Int?) {
        self.matches = matches
        rangesByChapter = Dictionary(grouping: matches, by: \.chapterIndex).mapValues { $0.map(\.range) }
        count = matches.count
        current = index
    }

    /// The result count of a search run elsewhere (PDFKit).
    func setCount(_ count: Int, startingAt index: Int?) {
        self.count = count
        current = count == 0 ? nil : min(max(index ?? 0, 0), count - 1)
    }

    func next() {
        guard count > 0 else { return }
        current = ((current ?? -1) + 1) % count
    }

    func previous() {
        guard count > 0 else { return }
        current = ((current ?? count) - 1 + count) % count
    }

    func dismiss() {
        isPresented = false
        query = ""
        setMatches([], startingAt: nil)
        isSearching = false
    }
}

/// The find bar that replaces the reader's top bar while searching.
struct ReaderSearchBar: View {
    @Bindable var model: ReaderSearchModel
    let theme: ReaderTheme
    @FocusState private var focused: Bool

    private var counter: String {
        if model.query.trimmingCharacters(in: .whitespaces).isEmpty { return "" }
        if model.isSearching { return String(localized: "Searching…") }
        guard model.count > 0 else { return String(localized: "No results") }
        let shown = (model.current ?? 0) + 1
        return model.count >= ReaderSearch.maximumMatches
            ? String(localized: "\(shown) of \(model.count)+")
            : String(localized: "\(shown) of \(model.count)")
    }

    var body: some View {
        HStack(spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14))
                    .foregroundStyle(theme.muted)
                    .accessibilityHidden(true)
                TextField("Search in book", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .foregroundStyle(theme.text)
                    .focused($focused)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .submitLabel(.search)
                    #endif
                    .onSubmit {
                        #if os(macOS)
                        model.next()
                        #else
                        // The Search key shows the results: the keyboard
                        // would cover half the page. The arrows step on.
                        focused = false
                        #endif
                    }
                    .accessibilityIdentifier("ReaderSearchField")
                Text(counter)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.muted)
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
                    .accessibilityIdentifier("ReaderSearchCounter")
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(theme.text.opacity(0.07), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            Button {
                model.previous()
            } label: {
                Image(systemName: "chevron.up")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .foregroundStyle(model.count > 0 ? theme.text : theme.muted.opacity(0.4))
            .disabled(model.count == 0)
            .keyboardShortcut("g", modifiers: [.command, .shift])
            .accessibilityLabel("Previous match")

            Button {
                model.next()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .foregroundStyle(model.count > 0 ? theme.text : theme.muted.opacity(0.4))
            .disabled(model.count == 0)
            .keyboardShortcut("g", modifiers: .command)
            .accessibilityLabel("Next match")

            Button("Done") {
                model.dismiss()
            }
            .buttonStyle(.plain)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(theme.accent)
            .frame(minWidth: 44, minHeight: 44)
            .keyboardShortcut(.cancelAction)
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        // The reader's top bar height: opening the search must not change the
        // page size, or the whole book would be laid out again.
        .frame(height: 44)
        .background(theme.background)
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.line).frame(height: 0.5)
        }
        .onAppear { focused = true }
    }
}
