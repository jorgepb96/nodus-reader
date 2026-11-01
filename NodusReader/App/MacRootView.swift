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
    /// The sidebar as it was before a book opened, restored when it closes.
    @State private var visibilityBeforeReader: NavigationSplitViewVisibility?
    #if DEBUG
    /// `-NodusShowVoices YES`: Voices & Models in the window, for screen captures.
    @State private var showsDebugVoices = false
    #endif

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
            set: {
                if let newValue = $0 {
                    navigation.sidebarSelection = newValue
                    // A place chosen in the sidebar beside the reader closes it.
                    navigation.macReaderBookID = nil
                }
            }
        )
    }

    var body: some View {
        // The reader takes the detail column, beside the library sidebar,
        // which folds away while reading; closing it brings back the library
        // where it was (its selection lives in `navigation`).
        Group {
            #if DEBUG
            if showsDebugVoices, UserDefaults.standard.string(forKey: "NodusShowVoices") == "ming" {
                ScrollView { StudioSection(onShowModels: {}).padding(24) }
            } else if showsDebugVoices {
                NavigationStack { VoicesView(initialMode: .models) }
            } else {
                libraryWindow
            }
            #else
            libraryWindow
            #endif
        }
        // Switches, as on iPhone and iPad and in the design, not checkboxes.
        .toggleStyle(.switch)
        .task {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-NodusOpenSettings") {
                navigation.sidebarSelection = .settings
            }
            if UserDefaults.standard.string(forKey: "NodusShowVoices") != nil {
                showsDebugVoices = true
            }
            if ProcessInfo.processInfo.arguments.contains("-NodusStartSampleNarration"),
               let book = books.first(where: { $0.title == UserDefaults.standard.string(forKey: "NodusSampleNarrationBook") ?? "Moby-Dick" }) {
                // `-NodusSampleNarrationVoice <id>` reads it with that voice.
                if let voiceID = UserDefaults.standard.string(forKey: "NodusSampleNarrationVoice") {
                    library.setPreferredVoice(book, voiceID: voiceID)
                }
                await playback.start(book: book, mode: .listen)
            }
            if ProcessInfo.processInfo.arguments.contains("-NodusCaptureScreens") {
                await MacScreenCapture.tour(navigation: navigation, books: { books }, collections: { collections })
            }
            if ProcessInfo.processInfo.arguments.contains("-NodusOpenSampleReader"),
               let book = books.first(where: { $0.title == "Moby-Dick" }) {
                navigation.macReaderBookID = book.id
            }
            // `-NodusImportFile <path> -NodusOpenBookAt <0…1> [-NodusBookBreakDays <n>]`
            // imports a document into the sample library and opens it there.
            if let path = UserDefaults.standard.string(forKey: "NodusImportFile"),
               let book = await StoryCompanionDebug.importAndPlace(path: path, library: library) {
                // Let the library table take the new row before it goes.
                try? await Task.sleep(for: .seconds(2))
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
                // The reader bar has its own sidebar button where the
                // toolbar's would cover it.
                .toolbar(removing: navigation.macReaderBookID != nil ? .sidebarToggle : nil)
        } detail: {
            if let bookID = navigation.macReaderBookID {
                MacReaderHost(bookID: bookID) { navigation.macReaderBookID = nil }
                    .environment(\.librarySidebarVisible, navigation.columnVisibility != .detailOnly)
                    .environment(\.toggleLibrarySidebar) {
                        withAnimation {
                            navigation.columnVisibility = navigation.columnVisibility == .detailOnly ? .all : .detailOnly
                        }
                    }
            } else {
                NavigationStack(path: $detailPath) {
                    detailContent
                        .searchable(text: $searchText, placement: .toolbar, prompt: "Search library")
                }
            }
        }
        .tint(palette.accent)
        .onChange(of: navigation.macReaderBookID != nil, initial: true) { _, reading in
            if reading {
                visibilityBeforeReader = navigation.columnVisibility
                navigation.columnVisibility = .detailOnly
            } else if let visibilityBeforeReader {
                navigation.columnVisibility = visibilityBeforeReader
                self.visibilityBeforeReader = nil
            }
        }
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

            SidebarFooter(bookCount: books.count,
                          settingsSelected: navigation.sidebarSelection == .settings,
                          onSettings: {
                              navigation.sidebarSelection = .settings
                              navigation.macReaderBookID = nil
                          })
        }
        // Up to the top of the window, behind the window buttons and the
        // sidebar toggle, not only below the toolbar.
        .background { palette.sidebar.ignoresSafeArea() }
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
                case .settings:
                    SettingsView(showsBrand: false)
                default:
                    MacLibraryContentView(selection: navigation.sidebarSelection)
                }
            }
        }
        // One window colour under every page and its toolbar.
        .background { palette.background.ignoresSafeArea() }
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
