// SPDX-License-Identifier: AGPL-3.0-only
import DesignSystem
import SwiftUI

struct ReaderAnnotationDraft: Identifiable {
    let id = UUID()
    let chapterIndex: Int
    let range: NSRange
    let quote: String
    var color: AnnotationColor
    var note: String
    let existing: Annotation?
}

struct AnnotationEditorSheet: View {
    @Environment(LibraryService.self) private var library
    @Environment(\.dismiss) private var dismiss
    @Environment(\.nodusPalette) private var palette

    let book: Book
    let draft: ReaderAnnotationDraft

    @State private var color: AnnotationColor
    @State private var note: String

    init(book: Book, draft: ReaderAnnotationDraft) {
        self.book = book
        self.draft = draft
        _color = State(initialValue: draft.color)
        _note = State(initialValue: draft.note)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Passage") {
                    Text("“\(draft.quote)”")
                        .font(.system(.body, design: .serif))
                        .italic()
                        .foregroundStyle(palette.text)
                        .lineLimit(5)
                }

                Section("Highlight colour") {
                    HStack(spacing: 14) {
                        ForEach(AnnotationColor.allCases) { option in
                            Button {
                                color = option
                            } label: {
                                Circle()
                                    .fill(Color(hex: option.fillHex))
                                    .frame(width: 34, height: 34)
                                    .overlay(
                                        Circle().strokeBorder(
                                            color == option ? Color(hex: option.underlineHex) : palette.line,
                                            lineWidth: color == option ? 3 : 1
                                        )
                                    )
                                    .overlay {
                                        if color == option {
                                            Image(systemName: "checkmark")
                                                .font(.system(size: 12, weight: .bold))
                                                .foregroundStyle(Color(hex: option.underlineHex))
                                        }
                                    }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(option.title)
                            .accessibilityAddTraits(color == option ? [.isSelected] : [])
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section("Note") {
                    TextEditor(text: $note)
                        .accessibilityIdentifier("annotationNoteEditor")
                        .frame(minHeight: 100)
                        .overlay(alignment: .topLeading) {
                            if note.isEmpty {
                                Text("Write a note…")
                                    .foregroundStyle(palette.muted)
                                    .padding(.top, 8)
                                    .allowsHitTesting(false)
                            }
                        }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(draft.existing == nil ? "Add Highlight" : "Edit Highlight")
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                if let existing = draft.existing {
                    ToolbarItem(placement: .destructiveAction) {
                        Button("Delete", role: .destructive) {
                            library.deleteAnnotation(existing)
                            dismiss()
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                }
            }
        }
        #if os(iOS)
        .presentationDetents([.medium, .large])
        #endif
    }

    private func save() {
        if let existing = draft.existing {
            library.updateAnnotation(existing, note: note, color: color)
        } else {
            library.addAnnotation(
                book,
                chapterIndex: draft.chapterIndex,
                startOffset: draft.range.location,
                endOffset: NSMaxRange(draft.range),
                quote: draft.quote,
                color: color,
                note: note
            )
        }
        dismiss()
    }
}

private enum ReaderNavigationTab: String, CaseIterable, Identifiable {
    case contents = "Contents"
    case bookmarks = "Bookmarks"
    case notes = "Notes"
    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .contents: "Contents"
        case .bookmarks: "Bookmarks"
        case .notes: "Notes"
        }
    }
}

struct ReaderNavigationSheet: View {
    @Environment(LibraryService.self) private var library
    @Environment(\.dismiss) private var dismiss
    @Environment(\.nodusPalette) private var palette

    let book: Book
    let chapters: [ExtractedChapter]
    let pages: [ReaderPage]
    let firstPageByChapter: [Int: Int]
    @Binding var pageIndex: Int
    var onEditAnnotation: (Annotation) -> Void

    @State private var tab: ReaderNavigationTab = .contents

    private var currentChapterIndex: Int {
        pages.indices.contains(pageIndex) ? pages[pageIndex].chapterIndex : 0
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Reader navigation", selection: $tab) {
                    ForEach(ReaderNavigationTab.allCases) { tab in
                        Text(tab.title).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

                switch tab {
                case .contents:
                    contentsList
                case .bookmarks:
                    bookmarksList
                case .notes:
                    notesList
                }
            }
            .background(palette.background)
            .navigationTitle(book.title)
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    ShareLink(item: library.exportNotes(for: book)) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel("Export bookmarks and notes")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        #if os(iOS)
        .presentationDetents([.medium, .large])
        #endif
    }

    private var contentsList: some View {
        List {
            ForEach(Array(chapters.enumerated()), id: \.element.id) { index, chapter in
                Button {
                    pageIndex = firstPageByChapter[index] ?? 0
                    dismiss()
                } label: {
                    HStack(spacing: 10) {
                        Text("\(index + 1)")
                            .font(.caption)
                            .foregroundStyle(palette.muted)
                            .frame(width: 22, alignment: .trailing)
                            .monospacedDigit()
                        Text(chapter.title)
                            .foregroundStyle(palette.text)
                            .lineLimit(2)
                        Spacer(minLength: 6)
                        if index == currentChapterIndex {
                            Image(systemName: "checkmark").foregroundStyle(palette.accent)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private var bookmarksList: some View {
        Group {
            if book.bookmarks.isEmpty {
                emptyState(icon: "bookmark", title: "No bookmarks yet",
                           message: "Tap the bookmark button in the reader to save the current page.")
            } else {
                List {
                    ForEach(book.bookmarks.sorted { $0.createdAt > $1.createdAt }) { bookmark in
                        Button {
                            let chapter = max(bookmark.locator.chapterIndex, 0)
                            let chapterPages = pages.filter { $0.chapterIndex == chapter }.count
                            let fraction = min(max(bookmark.locator.scrollFraction, 0), 1)
                            let offset = Int((fraction * Double(max(chapterPages - 1, 0))).rounded())
                            let start = firstPageByChapter[chapter] ?? 0
                            pageIndex = min(start + max(0, offset), max(pages.count - 1, 0))
                            dismiss()
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "bookmark.fill")
                                    .foregroundStyle(palette.accent)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(bookmark.title)
                                        .foregroundStyle(palette.text)
                                        .lineLimit(1)
                                    Text(bookmark.chapterTitle.isEmpty
                                         ? String(localized: "Chapter \(bookmark.locator.chapterIndex + 1)")
                                         : bookmark.chapterTitle)
                                        .font(.caption)
                                        .foregroundStyle(palette.muted)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 6)
                                Text(bookmark.createdAt, style: .date)
                                    .font(.caption2)
                                    .foregroundStyle(palette.muted)
                            }
                        }
                        .buttonStyle(.plain)
                        .swipeActions {
                            Button("Delete", role: .destructive) {
                                library.deleteBookmark(bookmark)
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
    }

    private var notesList: some View {
        Group {
            if book.annotations.isEmpty {
                emptyState(icon: "note.text", title: "No highlights or notes",
                           message: "Select text in the reader to highlight it or add a note.")
            } else {
                List {
                    ForEach(book.annotations.sorted {
                        $0.chapterIndex == $1.chapterIndex
                            ? $0.startOffset < $1.startOffset
                            : $0.chapterIndex < $1.chapterIndex
                    }) { annotation in
                        Button {
                            if let index = page(for: annotation) {
                                pageIndex = index
                            }
                            dismiss()
                        } label: {
                            HStack(alignment: .top, spacing: 10) {
                                Circle()
                                    .fill(Color(hex: annotation.color.fillHex))
                                    .frame(width: 12, height: 12)
                                    .overlay(Circle().stroke(Color(hex: annotation.color.underlineHex), lineWidth: 1))
                                    .padding(.top, 4)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("“\(annotation.quote)”")
                                        .font(.system(.subheadline, design: .serif))
                                        .italic()
                                        .foregroundStyle(palette.text)
                                        .lineLimit(3)
                                    if annotation.isNote {
                                        Text(annotation.note)
                                            .font(.caption)
                                            .foregroundStyle(palette.muted)
                                            .lineLimit(3)
                                    }
                                    Text("Chapter \(annotation.chapterIndex + 1)")
                                        .font(.caption2)
                                        .foregroundStyle(palette.muted)
                                }
                                Spacer(minLength: 6)
                                Image(systemName: "chevron.right")
                                    .font(.caption2)
                                    .foregroundStyle(palette.muted)
                            }
                        }
                        .buttonStyle(.plain)
                        .swipeActions {
                            Button("Delete", role: .destructive) {
                                library.deleteAnnotation(annotation)
                            }
                            Button("Edit") { onEditAnnotation(annotation) }
                                .tint(palette.accent)
                        }
                        .contextMenu {
                            Button {
                                onEditAnnotation(annotation)
                            } label: {
                                Label("Edit…", systemImage: "pencil")
                            }
                            Button(role: .destructive) {
                                library.deleteAnnotation(annotation)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
    }

    private func page(for annotation: Annotation) -> Int? {
        pages.firstIndex { page in
            page.chapterIndex == annotation.chapterIndex &&
            annotation.startOffset >= page.chapterStartOffset &&
            annotation.startOffset < max(page.chapterEndOffset, page.chapterStartOffset + 1)
        }
    }

    private func emptyState(icon: String, title: LocalizedStringKey, message: LocalizedStringKey) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(palette.accent)
            Text(title).font(.system(.headline, design: .serif))
            Text(message)
                .font(.footnote)
                .foregroundStyle(palette.muted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}
