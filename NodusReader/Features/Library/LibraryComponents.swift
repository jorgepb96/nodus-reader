// SPDX-License-Identifier: AGPL-3.0-only
import DesignSystem
import PhotosUI
import SwiftData
import SwiftUI

// MARK: - Grid cell

struct BookGridCell: View {
    @Environment(\.nodusPalette) private var palette
    let book: Book
    var selectionMode: Bool
    var isSelected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 7) {
                BookCoverView(book: book, selected: selectionMode && isSelected)
                    .overlay(alignment: .topLeading) {
                        if selectionMode {
                            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundStyle(isSelected ? palette.accent : Color.white)
                                .background(Circle().fill(palette.background.opacity(0.75)).padding(2))
                                .padding(6)
                        }
                    }
                BookProgressLine(progress: book.progress)
                VStack(alignment: .leading, spacing: 1) {
                    Text(book.title)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(palette.text)
                        .lineLimit(1)
                    Text(book.displayAuthor)
                        .font(.caption2)
                        .foregroundStyle(palette.muted)
                        .lineLimit(1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(book.title), by \(book.displayAuthor)")
        .accessibilityValue(book.status.label)
    }
}

// MARK: - List row

struct BookListRow: View {
    @Environment(\.nodusPalette) private var palette
    let book: Book

    var body: some View {
        HStack(spacing: 14) {
            BookCoverView(book: book)
                .frame(width: 46, height: 69)
            VStack(alignment: .leading, spacing: 3) {
                Text(book.title)
                    .font(.system(size: 17, design: .serif))
                    .foregroundStyle(palette.text)
                    .lineLimit(1)
                Text(book.displayAuthor)
                    .font(.footnote)
                    .foregroundStyle(palette.muted)
                    .lineLimit(1)
                Text(statusLine)
                    .font(.caption2)
                    .foregroundStyle(palette.accent)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            NodusProgressBar(value: book.progress)
                .frame(width: 44)
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var statusLine: String {
        switch book.status {
        case .finished: String(localized: "\(book.format.badge) · Finished")
        case .toRead: String(localized: "\(book.format.badge) · To read")
        case .inProgress: String(localized: "\(book.format.badge) · \(Int((book.progress * 100).rounded()))%")
        }
    }
}

// MARK: - Filters

struct LibraryFilterBar: View {
    @Environment(\.nodusPalette) private var palette

    @Binding var selection: LibraryFilter.Kind
    var includesEPUB: Bool = false

    private var kinds: [LibraryFilter.Kind] {
        includesEPUB
            ? [.all, .inProgress, .toRead, .finished, .favorites, .epub, .pdf]
            : [.all, .inProgress, .toRead, .finished, .favorites, .pdf]
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(kinds) { kind in
                    CapsuleChip(kind.title, isSelected: selection == kind) {
                        selection = kind
                    }
                }
            }
        }
        .scrollClipDisabled()
    }
}

// MARK: - Sort menu

struct LibrarySortMenu: View {
    @Environment(\.nodusPalette) private var palette
    @Binding var sort: LibrarySort

    var body: some View {
        Menu {
            Picker("Sort", selection: $sort) {
                ForEach(LibrarySort.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.up.arrow.down")
                Text("Sort")
            }
            .font(.footnote)
            .foregroundStyle(palette.muted)
        }
        .nodusMenuLabelStyle()
        .fixedSize()
        .accessibilityLabel("Sort books")
    }
}

// MARK: - Context actions

struct BookContextActions: View {
    @Environment(LibraryService.self) private var library
    @Environment(CloudSyncService.self) private var sync
    @Environment(ImportCoordinator.self) private var imports
    let book: Book
    var onOpen: () -> Void
    var onReadAndListen: () -> Void
    var onAddToCollection: () -> Void
    var onEditInfo: (() -> Void)?
    var onDelete: () -> Void

    var body: some View {
        Button {
            onOpen()
        } label: {
            Label("Open", systemImage: "book")
        }
        Button {
            onReadAndListen()
        } label: {
            Label("Read & Listen", systemImage: "headphones")
        }
        Button {
            onAddToCollection()
        } label: {
            Label("Add to Collection…", systemImage: "folder.badge.plus")
        }
        if let onEditInfo {
            Button {
                onEditInfo()
            } label: {
                Label("Edit Info…", systemImage: "pencil")
            }
        }
        Divider()
        Button {
            library.setFavorite(book, isFavorite: !book.isFavorite)
        } label: {
            Label(book.isFavorite ? "Remove from Favorites" : "Add to Favorites",
                  systemImage: book.isFavorite ? "star.slash" : "star")
        }
        Menu {
            ForEach(ReadingStatus.allCases) { status in
                Button {
                    library.setStatus(book, status: status)
                } label: {
                    Label(status.label, systemImage: book.status == status ? "checkmark" : "circle")
                }
            }
        } label: {
            Label("Mark as", systemImage: "checkmark.circle")
        }
        if sync.isEnabled, book.downloadState == .downloaded {
            Button {
                Task {
                    await sync.removeLocalDownload(book)
                    reportDownloadError(title: String(localized: "Download not removed"))
                }
            } label: {
                Label("Remove Download", systemImage: "icloud.and.arrow.up")
            }
        }
        if sync.isEnabled, book.downloadState == .cloudOnly {
            Button {
                Task {
                    await sync.download(book)
                    reportDownloadError(title: String(localized: "Download failed"))
                }
            } label: {
                Label("Download from iCloud", systemImage: "icloud.and.arrow.down")
            }
        }
        Divider()
        Button(role: .destructive) {
            onDelete()
        } label: {
            Label("Delete from Library…", systemImage: "trash")
        }
    }

    /// The context menu is gone by the time the iCloud call returns, so a
    /// failure would otherwise be visible only in Settings.
    private func reportDownloadError(title: String) {
        guard let message = sync.downloadError else { return }
        imports.alert = LibraryAlert(title: title, message: message)
    }
}

// MARK: - Add to collection

struct AddToCollectionSheet: View {
    @Environment(LibraryService.self) private var library
    @Environment(\.dismiss) private var dismiss
    @Environment(\.nodusPalette) private var palette

    let books: [Book]

    @Query(sort: \LibraryCollection.sortIndex) private var collections: [LibraryCollection]
    @State private var newCollectionName = ""
    @State private var showNewCollection = false

    private struct DepthCollection: Identifiable {
        let collection: LibraryCollection
        let depth: Int
        var id: UUID { collection.id }
    }

    private var flattened: [DepthCollection] {
        var result: [DepthCollection] = []
        func visit(_ parentID: UUID?, depth: Int) {
            let children = collections
                .filter { $0.parentID == parentID }
                .sorted {
                    $0.sortIndex == $1.sortIndex
                        ? $0.name.localizedStandardCompare($1.name) == .orderedAscending
                        : $0.sortIndex < $1.sortIndex
                }
            for child in children {
                result.append(DepthCollection(collection: child, depth: depth))
                visit(child.id, depth: depth + 1)
            }
        }
        visit(nil, depth: 0)
        return result
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if flattened.isEmpty {
                        Text("No collections yet. Create one to group documents without duplicating them.")
                            .font(.footnote)
                            .foregroundStyle(palette.muted)
                    }
                    ForEach(flattened) { entry in
                        Button {
                            toggle(entry.collection)
                        } label: {
                            HStack(spacing: 8) {
                                if entry.depth > 0 {
                                    Color.clear.frame(width: CGFloat(entry.depth) * 16, height: 1)
                                }
                                Image(systemName: stateSymbol(for: entry.collection))
                                    .foregroundStyle(palette.accent)
                                    .frame(width: 22)
                                Text(entry.collection.name)
                                    .foregroundStyle(palette.text)
                                    .lineLimit(1)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("Collections")
                }
            }
            .navigationTitle(books.count == 1 ? "Add to Collection" : "Add \(books.count) Books")
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("New Collection") { showNewCollection = true }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("New Collection", isPresented: $showNewCollection) {
                TextField("Name", text: $newCollectionName)
                Button("Create") {
                    if let collection = library.createCollection(name: newCollectionName) {
                        for book in books { library.add(book, to: collection) }
                    }
                    newCollectionName = ""
                }
                Button("Cancel", role: .cancel) { newCollectionName = "" }
            }
        }
        #if os(iOS)
        .presentationDetents([.medium, .large])
        #endif
    }

    private func stateSymbol(for collection: LibraryCollection) -> String {
        let contained = books.filter { book in
            collection.memberships.contains { $0.book?.id == book.id }
        }.count
        if contained == books.count { return "checkmark.circle.fill" }
        if contained > 0 { return "minus.circle.fill" }
        return "circle"
    }

    private func toggle(_ collection: LibraryCollection) {
        let allContained = books.allSatisfy { book in
            collection.memberships.contains { $0.book?.id == book.id }
        }
        for book in books {
            if allContained {
                library.remove(book, from: collection)
            } else {
                library.add(book, to: collection)
            }
        }
    }
}

// MARK: - Metadata editor

struct BookInfoSheet: View {
    @Environment(LibraryService.self) private var library
    @Environment(\.dismiss) private var dismiss
    @Environment(\.nodusPalette) private var palette

    let book: Book

    @State private var title: String
    @State private var author: String
    @State private var language: String
    @State private var published: String
    @State private var summary: String
    @State private var photoItem: PhotosPickerItem?

    init(book: Book) {
        self.book = book
        _title = State(initialValue: book.title)
        _author = State(initialValue: book.author)
        _language = State(initialValue: book.language)
        _published = State(initialValue: book.published)
        _summary = State(initialValue: book.bookDescription)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Cover") {
                    HStack {
                        Spacer()
                        BookCoverView(book: book, showBadges: false)
                            .frame(width: 118, height: 177)
                        Spacer()
                    }
                    PhotosPicker(selection: $photoItem, matching: .images) {
                        Label("Choose custom cover…", systemImage: "photo")
                    }
                    if book.coverFileName != nil {
                        Button("Use generated cover", role: .destructive) {
                            library.clearCustomCover(book)
                        }
                    }
                }

                Section("Metadata") {
                    TextField("Title", text: $title)
                    TextField("Author", text: $author)
                    TextField("Language", text: $language)
                    TextField("Published", text: $published)
                    TextEditor(text: $summary)
                        .frame(minHeight: 88)
                        .overlay(alignment: .topLeading) {
                            if summary.isEmpty {
                                Text("Description")
                                    .foregroundStyle(palette.muted)
                                    .padding(.top, 8)
                                    .allowsHitTesting(false)
                            }
                        }
                }

                Section("File") {
                    LabeledContent("Format", value: book.format.label)
                    LabeledContent("Size", value: ByteCountFormatter.string(fromByteCount: book.fileSize, countStyle: .file))
                    LabeledContent("File name", value: book.fileName)
                    LabeledContent("Status", value: book.status.label)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Edit Info")
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        library.updateMetadata(book, title: title, author: author,
                                               language: language, published: published, summary: summary)
                        dismiss()
                    }
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onChange(of: photoItem) { _, item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self) {
                        _ = library.setCustomCover(book, imageData: data)
                    }
                    photoItem = nil
                }
            }
        }
        #if os(iOS)
        .presentationDetents([.large])
        #endif
    }
}

// MARK: - Shared modifier

extension View {
    @ViewBuilder
    func inlineNavigationTitle() -> some View {
        #if os(iOS)
        navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }

    @ViewBuilder
    func navigationBarBackground(_ color: Color) -> some View {
        #if os(iOS)
        toolbarBackground(color, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        #else
        self
        #endif
    }

    @ViewBuilder
    func librarySearchable(text: Binding<String>, prompt: LocalizedStringKey) -> some View {
        #if os(iOS)
        searchable(text: text, placement: .navigationBarDrawer(displayMode: .always), prompt: Text(prompt))
        #else
        searchable(text: text, prompt: Text(prompt))
        #endif
    }
}


extension View {
    /// A text button drawn as an accent link. On the Mac the default style
    /// would draw a push-button bezel behind it.
    @ViewBuilder
    func nodusTextButtonStyle() -> some View {
        #if os(macOS)
        self.buttonStyle(.plain)
        #else
        self
        #endif
    }

    /// A menu that shows its custom label as drawn. AppKit otherwise wraps it
    /// in a bordered pop-up button (a white box with its own chevron).
    @ViewBuilder
    func nodusMenuLabelStyle() -> some View {
        #if os(macOS)
        self.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
        #else
        self
        #endif
    }
}

extension ToolbarItemPlacement {
    static var nodusLeading: ToolbarItemPlacement {
        #if os(macOS)
        .navigation
        #else
        ToolbarItemPlacement.topBarLeading
        #endif
    }

    static var nodusTrailing: ToolbarItemPlacement {
        #if os(macOS)
        .primaryAction
        #else
        ToolbarItemPlacement.topBarTrailing
        #endif
    }
}

extension ToolbarContent {
    /// Draws the item as it is, without the glass capsule iOS and macOS 26
    /// put behind toolbar items: the wordmark and the accent Import capsule
    /// would otherwise sit inside a second, grey one.
    @ToolbarContentBuilder
    func nodusPlainBackground() -> some ToolbarContent {
        if #available(iOS 26, macOS 26, *) {
            sharedBackgroundVisibility(.hidden)
        } else {
            self
        }
    }
}

extension View {
    @ViewBuilder
    func manualEditMode() -> some View {
        #if os(iOS)
        environment(\.editMode, .constant(.active))
        #else
        self
        #endif
    }
}

// MARK: - Search field

/// The capsule search field used by the Library and by each collection.
struct LibrarySearchField: View {
    @Environment(\.nodusPalette) private var palette
    @Binding var text: String
    var prompt: LocalizedStringKey
    var accessibilityLabel: LocalizedStringKey

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 17))
                .foregroundStyle(palette.muted)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(.subheadline)
                .foregroundStyle(palette.text)
                .accessibilityLabel(accessibilityLabel)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(palette.muted)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .background(palette.panel, in: Capsule())
        .overlay(Capsule().stroke(palette.line, lineWidth: 1))
    }
}

// MARK: - Collection folders

/// A collection shown as a folder tile in grid layouts.
struct CollectionFolderTile: View {
    @Environment(\.nodusPalette) private var palette
    let collection: LibraryCollection
    let bookCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: "folder.fill")
                .font(.system(size: 30))
                .foregroundStyle(palette.accent)
                .frame(maxWidth: .infinity, minHeight: 64)
                .background(palette.selection, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            Text(collection.name)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(palette.text)
                .lineLimit(2)
            Text(bookCount == 1 ? "1 book" : "\(bookCount) books")
                .font(.caption2)
                .foregroundStyle(palette.muted)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(bookCount == 1 ? "\(collection.name), collection, 1 book" : "\(collection.name), collection, \(bookCount) books")
    }
}
