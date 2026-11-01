// SPDX-License-Identifier: AGPL-3.0-only
#if os(macOS)
import DesignSystem
import PhotosUI
import SwiftData
import SwiftUI

enum LibraryViewMode: String, CaseIterable, Identifiable {
    case grid
    case list
    var id: String { rawValue }
    var systemImage: String { self == .grid ? "square.grid.2x2" : "list.bullet" }
}

struct MacLibraryContentView: View {
    @Environment(LibraryService.self) private var library
    @Environment(ImportCoordinator.self) private var imports
    @Environment(PlaybackController.self) private var playback
    @Environment(\.nodusPalette) private var palette

    let selection: SidebarDestination

    @Query(sort: \Book.addedAt, order: .reverse) private var books: [Book]

    @State private var viewMode: LibraryViewMode = .list
    @State private var selectedBookID: Book.ID?
    @State private var fallbackBookID: Book.ID?
    @State private var sortOrder: [KeyPathComparator<Book>] = [
        KeyPathComparator(\Book.lastOpenedSort, order: .reverse)
    ]
    @State private var showInspector = true
    @State private var readingBook: Book?
    @State private var editingBook: Book?
    @State private var collectionBooks: [Book] = []
    @State private var showCollectionSheet = false
    @State private var pendingDeletion: [Book] = []
    @State private var showDeleteConfirmation = false

    private var title: String {
        selection.smartList?.title ?? String(localized: "Library")
    }

    private var shownBooks: [Book] {
        guard let list = selection.smartList else { return books }
        switch list {
        case .home, .allBooks: return books
        case .favorites: return books.filter(\.isFavorite)
        case .toRead: return books.filter { $0.status == .toRead }
        case .finished: return books.filter { $0.status == .finished }
        case .inbox: return books.filter { $0.memberships.isEmpty }
        }
    }

    private var selectedBook: Book? {
        guard let selectedBookID else { return nil }
        return books.first { $0.id == selectedBookID }
    }

    private var inspectorBook: Book? {
        if let selectedBook { return selectedBook }
        guard let fallbackBookID else { return nil }
        return books.first { $0.id == fallbackBookID }
    }

    var body: some View {
        Group {
            if viewMode == .list {
                table
            } else {
                grid
            }
        }
        .navigationTitle(title)
        .navigationSubtitle(shownBooks.count == 1 ? String(localized: "1 book") : String(localized: "\(shownBooks.count) books"))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                MacImportToolbarButton()
            }
            .nodusPlainBackground()
            ToolbarItem(placement: .primaryAction) {
                Picker("View", selection: $viewMode) {
                    ForEach(LibraryViewMode.allCases) { mode in
                        Image(systemName: mode.systemImage).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 84)
                .help("Grid or list view")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showInspector.toggle()
                } label: {
                    Image(systemName: "sidebar.right")
                }
                .help("Show or hide the inspector")
            }
        }
        .inspector(isPresented: $showInspector) {
            if let inspectorBook {
                BookInspector(
                    book: inspectorBook,
                    onOpen: {
                        library.open(inspectorBook)
                        readingBook = inspectorBook
                    },
                    onReadAndListen: {
                        library.open(inspectorBook)
                        readingBook = inspectorBook
                        Task { await playback.start(book: inspectorBook, mode: .readAndListen) }
                    },
                    onDelete: {
                        pendingDeletion = [inspectorBook]
                        showDeleteConfirmation = true
                    }
                )
            } else {
                inspectorEmpty
            }
        }
        .inspectorColumnWidth(min: 280, ideal: 320, max: 380)
        .readerCover(item: $readingBook)
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
        .onChange(of: selectedBookID) { _, newValue in
            if newValue != nil { showInspector = true }
        }
        .onAppear { selectDefaultBookIfNeeded() }
        .onChange(of: shownBooks.count) { _, _ in selectDefaultBookIfNeeded() }
    }

    private func selectDefaultBookIfNeeded() {
        guard fallbackBookID == nil, !shownBooks.isEmpty else { return }
        let newest = shownBooks.max {
            ($0.lastOpenedAt ?? .distantPast) < ($1.lastOpenedAt ?? .distantPast)
        }
        if let newest { fallbackBookID = newest.id }
    }

    // MARK: Table

    private var table: some View {
        // The column headers set `sortOrder`; the rows must follow it.
        Table(shownBooks.sorted(using: sortOrder), selection: $selectedBookID, sortOrder: $sortOrder) {
            TableColumn("Title", value: \.title) { book in
                HStack(spacing: 9) {
                    BookCoverView(book: book, showBadges: false)
                        .frame(width: 34, height: 51)
                    Text(book.title)
                        .font(.system(size: 14, design: .serif))
                        .lineLimit(1)
                }
            }
            .width(min: 180, ideal: 280)

            TableColumn("Author", value: \.author) { book in
                Text(book.displayAuthor)
                    .foregroundStyle(palette.muted)
                    .lineLimit(1)
            }
            .width(min: 110, ideal: 170)

            TableColumn("Format", value: \.formatRaw) { book in
                Text(book.format.label)
                    .font(.caption)
                    .foregroundStyle(palette.muted)
            }
            .width(60)

            TableColumn("Progress", value: \.progress) { book in
                HStack(spacing: 8) {
                    NodusProgressBar(value: book.progress)
                        .frame(width: 64)
                    Text("\(Int((book.progress * 100).rounded()))%")
                        .font(.caption2)
                        .foregroundStyle(palette.muted)
                        .monospacedDigit()
                }
            }
            .width(min: 100, ideal: 120)

            TableColumn("Collections") { book in
                Text(book.collectionNames.joined(separator: ", "))
                    .foregroundStyle(palette.muted)
                    .lineLimit(1)
            }
            .width(min: 120, ideal: 180)

            TableColumn("Last opened", value: \.lastOpenedSort) { book in
                Text(relativeDate(book.lastOpenedAt))
                    .foregroundStyle(palette.muted)
            }
            .width(min: 90, ideal: 120)

            TableColumn("") { book in
                if book.downloadState == .cloudOnly {
                    Image(systemName: "icloud.and.arrow.down")
                        .font(.caption)
                        .foregroundStyle(palette.muted)
                        .help("In iCloud, not downloaded")
                } else {
                    Color.clear
                }
            }
            .width(24)
        }
        // Empty alternating rows drew a column of grey bars under short lists.
        .alternatingRowBackgrounds(.disabled)
        .contextMenu(forSelectionType: Book.ID.self) { ids in
            if let book = selected(from: ids) {
                BookContextActions(
                    book: book,
                    onOpen: { open(book) },
                    onReadAndListen: {
                        library.open(book)
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
        } primaryAction: { ids in
            if let book = selected(from: ids) { open(book) }
        }
        // The window's colour, not the grey of a system table.
        .scrollContentBackground(.hidden)
        .background(palette.background)
        .overlay {
            if shownBooks.isEmpty {
                emptyState
            }
        }
    }

    // MARK: Grid

    private var grid: some View {
        ScrollView {
            if shownBooks.isEmpty {
                emptyState
                    .frame(minHeight: 420)
                    .padding(40)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 138), spacing: 24)],
                          alignment: .leading, spacing: 26) {
                    ForEach(shownBooks) { book in
                        BookGridCell(book: book, selectionMode: false, isSelected: false) {
                            open(book)
                        }
                        .contextMenu {
                            BookContextActions(
                                book: book,
                                onOpen: { open(book) },
                                onReadAndListen: {
                                    library.open(book)
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
                }
                .padding(20)
            }
        }
        .background(palette.background)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            NodusEmptyState(
                icon: "books.vertical",
                title: "No books here yet",
                message: "Import an EPUB, PDF, Markdown, text, HTML or RTF document."
            )
            PrimaryPillButton("Import documents", systemImage: "plus") {
                imports.beginImport()
            }
            .frame(maxWidth: 260)
        }
        .frame(maxWidth: .infinity)
        .padding(40)
    }

    private var inspectorEmpty: some View {
        VStack(spacing: 12) {
            Image(systemName: "sidebar.right")
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(palette.muted)
            Text("Select a book")
                .font(.system(.headline, design: .serif))
            Text("Metadata, collections, status and the book's voice appear here.")
                .font(.caption)
                .foregroundStyle(palette.muted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 200)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
    }

    private func open(_ book: Book) {
        library.open(book)
        readingBook = book
    }

    private func selected(from ids: Set<Book.ID>) -> Book? {
        guard let id = ids.first else { return nil }
        return books.first { $0.id == id }
    }

    private func relativeDate(_ date: Date?) -> String {
        guard let date else { return "—" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        if Calendar.current.isDateInToday(date) { return String(localized: "Today") }
        if Calendar.current.isDateInYesterday(date) { return String(localized: "Yesterday") }
        let components = Calendar.current.dateComponents([.day], from: date, to: Date())
        if let days = components.day, days < 7 {
            return formatter.localizedString(for: date, relativeTo: Date())
        }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }
}

// MARK: - Inspector

struct BookInspector: View {
    @Environment(LibraryService.self) private var library
    @Environment(VoiceCatalog.self) private var voices
    @Environment(\.nodusPalette) private var palette

    @Bindable var book: Book
    var onOpen: () -> Void
    var onReadAndListen: () -> Void
    var onDelete: () -> Void

    @State private var photoItem: PhotosPickerItem?
    @State private var saveTask: Task<Void, Never>?

    private var eligibleCollections: [LibraryCollection] {
        let existing = Set(book.memberships.compactMap { $0.collection?.id })
        return library.flattenedCollections()
            .filter { !existing.contains($0.collection.id) }
            .map(\.collection)
    }

    private var bookVoices: [VoiceCatalog.Voice] {
        let installed = voices.allInstalledVoices
        guard let language = VoiceCatalog.languageCode(book.language) else { return installed }
        let matching = installed.filter { VoiceCatalog.languageCode($0.language) == language }
        return matching.isEmpty ? installed : matching
    }

    /// Where the original file is: a cloud-only book is not on this Mac yet.
    private var fileState: String {
        switch book.downloadState {
        case .downloaded: String(localized: "\(book.format.label) · Downloaded")
        case .cloudOnly: String(localized: "\(book.format.label) · In iCloud only")
        case .downloading: String(localized: "\(book.format.label) · Downloading…")
        }
    }

    private var currentVoiceName: String {
        if let voice = voices.voice(withID: book.preferredVoiceID) {
            return "\(voice.name) · \(voice.engineLabel)"
        }
        return book.preferredVoiceID == nil ? String(localized: "Book default") : String(localized: "Book voice not installed")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                BookCoverView(book: book, showBadges: false)
                    .frame(width: 132, height: 198)
                    .frame(maxWidth: .infinity)

                HStack(spacing: 8) {
                    PhotosPicker(selection: $photoItem, matching: .images) {
                        Text("Change Cover…")
                            .font(.caption)
                            .foregroundStyle(palette.accent)
                    }
                    .buttonStyle(.plain)
                    if book.coverFileName != nil {
                        Button("Reset") { library.clearCustomCover(book) }
                            .buttonStyle(.plain)
                            .font(.caption)
                            .foregroundStyle(palette.muted)
                    }
                }
                .frame(maxWidth: .infinity)

                VStack(alignment: .leading, spacing: 8) {
                    inspectorField("Title", text: $book.title)
                    inspectorField("Author", text: $book.author)
                    HStack(alignment: .top, spacing: 8) {
                        inspectorField("Language", text: $book.language)
                        inspectorField("Published", text: $book.published)
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Description")
                            .font(.caption2)
                            .foregroundStyle(palette.muted)
                        TextEditor(text: $book.bookDescription)
                            .font(.caption)
                            .frame(minHeight: 70, maxHeight: 110)
                            .scrollContentBackground(.hidden)
                            .padding(4)
                            .background(palette.panel, in: RoundedRectangle(cornerRadius: 6))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(palette.line, lineWidth: 1)
                            )
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Collections")
                        .font(.caption)
                        .foregroundStyle(palette.muted)
                    FlowLayout(spacing: 6) {
                        ForEach(book.memberships.compactMap(\.collection)) { collection in
                            HStack(spacing: 4) {
                                Text(collection.name)
                                    .lineLimit(1)
                                Button {
                                    library.remove(book, from: collection)
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 8, weight: .bold))
                                }
                                .buttonStyle(.plain)
                            }
                            .font(.caption2)
                            .foregroundStyle(palette.accent)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(palette.selection, in: Capsule())
                        }

                        Menu {
                            ForEach(eligibleCollections) { collection in
                                Button(collection.name) {
                                    library.add(book, to: collection)
                                }
                            }
                            if eligibleCollections.isEmpty {
                                Text("No other collections")
                            }
                        } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(palette.muted)
                                .frame(width: 24, height: 24)
                                .overlay(Capsule().stroke(palette.line, style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
                                .contentShape(Capsule())
                        }
                        .nodusMenuLabelStyle()
                        .accessibilityLabel("Add to collection")
                    }
                }

                VStack(spacing: 0) {
                    HStack {
                        Text("Status").foregroundStyle(palette.muted)
                        Spacer()
                        Menu {
                            ForEach(ReadingStatus.allCases) { status in
                                Button(status.label) { library.setStatus(book, status: status) }
                            }
                        } label: {
                            menuValue(book.status.label)
                        }
                        .nodusMenuLabelStyle()
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 34)
                    Divider().overlay(palette.line)
                    HStack {
                        Text("Voice for this book").foregroundStyle(palette.muted)
                        Spacer()
                        Menu {
                            Button(String(localized: "Book default")) { library.setPreferredVoice(book, voiceID: nil) }
                            Divider()
                            ForEach(bookVoices) { voice in
                                Button("\(voice.name) · \(voice.engineLabel) · \(voice.languageName)") {
                                    library.setPreferredVoice(book, voiceID: voice.id)
                                }
                            }
                        } label: {
                            menuValue(currentVoiceName)
                        }
                        .nodusMenuLabelStyle()
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 34)
                    Divider().overlay(palette.line)
                    HStack {
                        Text("File").foregroundStyle(palette.muted)
                        Spacer()
                        Text(fileState)
                            .foregroundStyle(palette.text)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 34)
                }
                .font(.caption)
                .panelCard(radius: 10)

            }
            .padding(16)
        }
        .background(palette.background)
        .onChange(of: book.title) { _, _ in scheduleSave() }
        .onChange(of: book.author) { _, _ in scheduleSave() }
        .onChange(of: book.language) { _, _ in scheduleSave() }
        .onChange(of: book.published) { _, _ in scheduleSave() }
        .onChange(of: book.bookDescription) { _, _ in scheduleSave() }
        .onDisappear { saveNow() }
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

    /// A row value that opens a menu: the value and a small chevron.
    private func menuValue(_ text: String) -> some View {
        HStack(spacing: 4) {
            Text(text)
                .lineLimit(1)
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .semibold))
        }
        .foregroundStyle(palette.text)
        .contentShape(Rectangle())
    }

    private func inspectorField(_ label: LocalizedStringKey, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(palette.muted)
            TextField(label, text: text)
                .textFieldStyle(.plain)
                .font(.caption)
                .padding(.horizontal, 6)
                .frame(height: 26)
                .background(palette.panel, in: RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(palette.line, lineWidth: 1)
                )
        }
    }

    private func scheduleSave() {
        book.touch()
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            library.save()
        }
    }

    private func saveNow() {
        saveTask?.cancel()
        book.touch()
        library.save()
    }
}

/// The library's Import action as a toolbar capsule, the same in every Mac
/// library view (the iOS "+" is sized for touch, not for a Mac toolbar).
struct MacImportToolbarButton: View {
    @Environment(ImportCoordinator.self) private var imports
    @Environment(\.nodusPalette) private var palette

    var body: some View {
        Button {
            imports.beginImport()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .semibold))
                Text("Import")
                    .font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(palette.onAccent)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(palette.accent, in: Capsule())
            .fixedSize()
        }
        .buttonStyle(.plain)
        .help("Import documents (⇧⌘I)")
        .accessibilityLabel("Import documents")
    }
}

/// Simple wrapping layout for collection chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: min(width, x), height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
#endif
