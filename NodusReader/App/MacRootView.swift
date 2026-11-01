// SPDX-License-Identifier: AGPL-3.0-only
#if os(macOS)
import DesignSystem
import SwiftData
import SwiftUI

struct MacRootView: View {
    @Environment(NavigationModel.self) private var navigation
    @Environment(LibraryService.self) private var library
    @Environment(PlaybackController.self) private var playback
    @Environment(\.nodusPalette) private var palette
    @Environment(\.openSettings) private var openSettings

    @Query(sort: \Book.addedAt, order: .reverse) private var books: [Book]
    @Query(sort: \LibraryCollection.sortIndex) private var collections: [LibraryCollection]
    @Query private var memberships: [CollectionMembership]

    @State private var searchText = ""
    @State private var detailPath = NavigationPath()
    @State private var showNewCollection = false
    @State private var newCollectionParent: UUID?
    @State private var newCollectionName = ""
    @State private var renameTarget: LibraryCollection?
    @State private var renameText = ""
    @State private var deleteTarget: LibraryCollection?
    @State private var showRename = false
    @State private var showDelete = false

    private var roots: [LibraryCollection] {
        collections
            .filter { $0.parentID == nil }
            .sorted {
                $0.sortIndex == $1.sortIndex
                    ? $0.name.localizedStandardCompare($1.name) == .orderedAscending
                    : $0.sortIndex < $1.sortIndex
            }
    }

    private var selectionBinding: Binding<SidebarDestination?> {
        Binding(
            get: { navigation.sidebarSelection },
            set: { if let newValue = $0 { navigation.sidebarSelection = newValue } }
        )
    }

    var body: some View {
        // The reader replaces the library in this window; closing it brings
        // back the library where it was (its selection lives in `navigation`).
        Group {
            if let bookID = navigation.macReaderBookID {
                MacReaderHost(bookID: bookID) { navigation.macReaderBookID = nil }
            } else {
                libraryWindow
            }
        }
        // Switches, as on iPhone and iPad and in the design, not checkboxes.
        .toggleStyle(.switch)
        .task {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-NodusOpenSettings") {
                openSettings()
            }
            if ProcessInfo.processInfo.arguments.contains("-NodusStartSampleNarration"),
               let book = books.first(where: { $0.title == "Moby-Dick" }) {
                await playback.start(book: book, mode: .listen)
            }
            if ProcessInfo.processInfo.arguments.contains("-NodusCaptureScreens") {
                await MacScreenCapture.tour(navigation: navigation, books: { books }, collections: { collections },
                                            openSettings: openSettings)
            }
            if ProcessInfo.processInfo.arguments.contains("-NodusOpenSampleReader"),
               let book = books.first(where: { $0.title == "Moby-Dick" }) {
                navigation.macReaderBookID = book.id
            }
            #endif
        }
    }

    private var libraryWindow: some View {
        @Bindable var navigation = navigation

        return NavigationSplitView(columnVisibility: $navigation.columnVisibility) {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 244, max: 300)
        } detail: {
            NavigationStack(path: $detailPath) {
                detailContent
                    .searchable(text: $searchText, placement: .toolbar, prompt: "Search library")
            }
        }
        .tint(palette.accent)
        .onChange(of: navigation.sidebarSelection) { _, _ in
            detailPath = NavigationPath()
        }
        .onChange(of: searchText) { _, newValue in
            if !newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                detailPath = NavigationPath()
            }
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack {
                BrandToolbar()
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.top, 6)
            .padding(.bottom, 6)

            List(selection: selectionBinding) {
                Section {
                    ForEach(SmartList.allCases) { list in
                        SidebarSmartListRow(list: list, count: count(for: list))
                    }
                } header: {
                    Text("Library")
                        .foregroundStyle(palette.muted)
                }

                Section {
                    ForEach(roots) { collection in
                        CollectionOutlineRow(
                            collection: collection,
                            depth: 0,
                            allCollections: collections,
                            memberships: memberships,
                            selection: selectionBinding,
                            onNewSubcollection: { parent in
                                newCollectionParent = parent.id
                                newCollectionName = ""
                                showNewCollection = true
                            },
                            onRename: beginRename,
                            onDelete: beginDelete
                        )
                    }
                } header: {
                    HStack {
                        Text("Collections")
                            .foregroundStyle(palette.muted)
                        Spacer()
                        Button {
                            newCollectionParent = nil
                            newCollectionName = ""
                            showNewCollection = true
                        } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(palette.muted)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("New collection")
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .alert("Rename Collection", isPresented: $showRename) {
                TextField("Name", text: $renameText)
                Button("Save") {
                    if let renameTarget {
                        library.renameCollection(renameTarget, to: renameText)
                    }
                    renameTarget = nil
                }
                Button("Cancel", role: .cancel) { renameTarget = nil }
            }

            SidebarFooter(bookCount: books.count, onSettings: { openSettings() })
        }
        .background(palette.sidebar)
        .alert("New Collection", isPresented: $showNewCollection) {
            TextField("Name", text: $newCollectionName)
            Button("Create") {
                _ = library.createCollection(name: newCollectionName, parentID: newCollectionParent)
                newCollectionName = ""
                newCollectionParent = nil
            }
            Button("Cancel", role: .cancel) {
                newCollectionName = ""
                newCollectionParent = nil
            }
        }
        .confirmationDialog("Delete Collection?", isPresented: $showDelete, titleVisibility: .visible) {
            Button("Delete Collection", role: .destructive) {
                if let deleteTarget {
                    let deletedIDs = Set([deleteTarget.id] + library.descendantIDs(of: deleteTarget))
                    library.deleteCollection(deleteTarget)
                    if case .collection(let id) = navigation.sidebarSelection,
                       deletedIDs.contains(id) {
                        navigation.sidebarSelection = .allBooks
                    }
                }
                deleteTarget = nil
            }
            Button("Cancel", role: .cancel) { deleteTarget = nil }
        } message: {
            Text("The collection and its subcollections are removed. Documents stay in your library.")
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        Group {
            if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                SearchResultsContent(query: searchText)
            } else {
                switch navigation.sidebarSelection {
                case .home:
                    HomeView(titleSize: 44, showsBrand: false)
                case .collection(let id):
                    CollectionDetailView(collectionID: id, showsBrand: false)
                default:
                    MacLibraryContentView(selection: navigation.sidebarSelection)
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if playback.hasActiveBook {
                MacPlayerBar()
            }
        }
    }

    private func count(for list: SmartList) -> Int {
        switch list {
        case .home: 0
        case .allBooks: books.count
        case .favorites: books.filter(\.isFavorite).count
        case .toRead: books.filter { $0.status == .toRead }.count
        case .finished: books.filter { $0.status == .finished }.count
        case .inbox: books.filter { $0.memberships.isEmpty }.count
        }
    }

    private func beginRename(_ collection: LibraryCollection) {
        renameTarget = collection
        renameText = collection.name
        showRename = true
    }

    private func beginDelete(_ collection: LibraryCollection) {
        deleteTarget = collection
        showDelete = true
    }
}
#endif
