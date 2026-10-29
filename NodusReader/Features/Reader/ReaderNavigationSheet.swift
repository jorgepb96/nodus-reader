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
    @State private var chapterSearch = ""

    private var chapterQuery: String {
        chapterSearch.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var matchingChapterIndices: [Int] {
        chapters.indices.filter { index in
            chapterQuery.isEmpty
                || chapters[index].title.localizedStandardContains(chapterQuery)
                || String(index + 1) == chapterQuery
        }
    }

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
        .presentationContentInteraction(.scrolls)
        #endif
    }

    private var contentsList: some View {
        VStack(spacing: 0) {
            LibrarySearchField(text: $chapterSearch, prompt: "Search chapters",
                               accessibilityLabel: "Search chapters")
                .autocorrectionDisabled()
                .padding(.horizontal, ReaderContentsLayout.horizontalInset)
                .padding(.bottom, ReaderContentsLayout.searchBottomInset)

            if matchingChapterIndices.isEmpty {
                emptyState(icon: "magnifyingglass", title: "No matching chapters",
                           message: "Try another chapter title or number.")
            } else {
                chapterResults
                    .id(chapterQuery)
            }
        }
    }

    private var chapterResults: some View {
        ReaderContentsScrollView(ids: matchingChapterIndices) {
            ForEach(matchingChapterIndices, id: \.self) { index in
                let chapter = chapters[index]
                Button {
                    pageIndex = firstPageByChapter[index] ?? 0
                    dismiss()
                } label: {
                    HStack(spacing: 10) {
                        Text("\(index + 1)")
                            .font(.caption)
                            .foregroundStyle(palette.muted)
                            .monospacedDigit()
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .frame(minWidth: 22, alignment: .trailing)
                            .layoutPriority(1)
                            .accessibilityIdentifier("ContentsNumber-\(index + 1)")
                        Text(chapter.title)
                            .foregroundStyle(palette.text)
                            .lineLimit(2)
                        Spacer(minLength: 6)
                        if index == currentChapterIndex {
                            Image(systemName: "checkmark").foregroundStyle(palette.accent)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, ReaderContentsLayout.rowVerticalInset)
                    .frame(minHeight: ReaderContentsLayout.minimumRowHeight)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .id(index)
                Divider().overlay(palette.line)
            }
        }
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
                        .listRowBackground(Color.clear)
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
                        .listRowBackground(Color.clear)
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

// MARK: - Fast contents scrolling

/// Follows normal scrolling, but targets stable chapter IDs for fast jumps.
/// Pixel offsets into a large lazy stack can land in unmaterialised content.
struct ReaderContentsScrollView<Content: View>: View {
    let ids: [Int]
    @State private var metrics = ContentsScrollMetrics()
    @ViewBuilder var content: Content

    var body: some View {
        ScrollViewReader { proxy in
            HStack(spacing: 0) {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        content
                    }
                    .padding(.horizontal, ReaderContentsLayout.horizontalInset)
                }
                .scrollIndicators(.hidden)
                .onScrollGeometryChange(for: ContentsScrollMetrics.self) { geometry in
                    ContentsScrollMetrics(
                        contentHeight: geometry.contentSize.height,
                        viewportHeight: geometry.containerSize.height,
                        offset: geometry.contentOffset.y
                    )
                } action: { _, value in
                    metrics = value
                }

                if metrics.maximumOffset > 0 {
                    ContentsScrollbar(metrics: metrics) { fraction in
                        guard !ids.isEmpty else { return }
                        let index = min(Int((fraction * CGFloat(ids.count - 1)).rounded()), ids.count - 1)
                        proxy.scrollTo(ids[index], anchor: fraction >= 1 ? .bottom : .top)
                    }
                    .padding(.vertical, ReaderContentsLayout.scrollbarInset)
                }
            }
        }
    }
}

private struct ContentsScrollMetrics: Equatable {
    var contentHeight: CGFloat = 0
    var viewportHeight: CGFloat = 0
    var offset: CGFloat = 0

    var maximumOffset: CGFloat { max(0, contentHeight - viewportHeight) }
    var progress: CGFloat { maximumOffset > 0 ? min(max(offset / maximumOffset, 0), 1) : 0 }
}

private struct ContentsScrollbar: View {
    @Environment(\.nodusPalette) private var palette
    let metrics: ContentsScrollMetrics
    let onScroll: (CGFloat) -> Void
    @State private var grabOffset: CGFloat?
    @State private var dragProgress: CGFloat?

    var body: some View {
        GeometryReader { proxy in
            let height = max(1, proxy.size.height)
            let thumbHeight = min(height, max(ReaderContentsLayout.minimumThumbHeight,
                height * metrics.viewportHeight / max(metrics.contentHeight, 1)))
            let travel = max(0, height - thumbHeight)
            let offset = (dragProgress ?? metrics.progress) * travel

            ZStack(alignment: .top) {
                Capsule()
                    .fill(palette.muted.opacity(0.15))
                    .frame(width: ReaderContentsLayout.trackWidth)
                Capsule()
                    .fill(grabOffset == nil ? palette.muted : palette.accent)
                    .frame(width: ReaderContentsLayout.thumbWidth, height: thumbHeight)
                    .offset(y: offset)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .contentShape(Rectangle())
            .highPriorityGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if grabOffset == nil {
                            let start = value.startLocation.y
                            grabOffset = (offset...offset + thumbHeight).contains(start)
                                ? start - offset : thumbHeight / 2
                        }
                        guard travel > 0 else { return }
                        let fraction = min(max((value.location.y - (grabOffset ?? 0)) / travel, 0), 1)
                        dragProgress = fraction
                        onScroll(fraction)
                    }
                    .onEnded { _ in
                        grabOffset = nil
                        dragProgress = nil
                    }
            )
        }
        .frame(width: ReaderContentsLayout.scrollbarTouchWidth)
        .accessibilityElement()
        .accessibilityIdentifier("ReaderContentsScrollbar")
        .accessibilityLabel("Scroll through contents")
        .accessibilityValue(Text(Double(metrics.progress), format: .percent.precision(.fractionLength(0))))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onScroll(min(metrics.progress + 0.1, 1))
            case .decrement: onScroll(max(metrics.progress - 0.1, 0))
            @unknown default: break
            }
        }
    }
}
