// SPDX-License-Identifier: AGPL-3.0-only
#if os(iOS)
import DesignSystem
import SwiftData
import SwiftUI

struct PadRootView: View {
    @Environment(NavigationModel.self) private var navigation
    @Environment(LibraryService.self) private var library
    @Environment(PlaybackController.self) private var playback
    @Environment(\.nodusPalette) private var palette

    @Query(sort: \Book.addedAt, order: .reverse) private var books: [Book]
    @Query(sort: \LibraryCollection.sortIndex) private var collections: [LibraryCollection]
    @Query private var memberships: [CollectionMembership]

    @State private var searchText = ""
    @State private var detailPath = NavigationPath()
    @State private var showPlayer = false
    @State private var showSettings = false
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
        @Bindable var navigation = navigation

        NavigationSplitView(columnVisibility: $navigation.columnVisibility) {
            sidebar
                .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 340)
        } detail: {
            NavigationStack(path: $detailPath) {
                detailContent
                    .navigationDestination(for: UUID.self) { id in
                        CollectionDetailView(collectionID: id, showsBrand: false)
                    }
            }
            .miniPlayer(showPlayer: $showPlayer)
        }
        .tint(palette.accent)
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                SettingsView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showSettings = false }
                        }
                    }
            }
            .preferredColorScheme(themeScheme)
            .presentationSizing(.page)
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack {
                BrandToolbar()
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 6)

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14))
                    .foregroundStyle(palette.muted)
                TextField("Search", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.footnote)
                    .foregroundStyle(palette.text)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(palette.muted)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 38)
            .background(palette.input, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(.horizontal, 12)
            .padding(.bottom, 8)

            List(selection: selectionBinding) {
                Section {
                    ForEach(SmartList.allCases) { list in
                        SidebarSmartListRow(list: list, count: count(for: list))
                    }
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
                        Spacer()
                        Button {
                            newCollectionParent = nil
                            newCollectionName = ""
                            showNewCollection = true
                        } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("New collection")
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .onChange(of: navigation.sidebarSelection) { _, _ in
                detailPath = NavigationPath()
            }
            .onChange(of: searchText) { _, newValue in
                if !newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    detailPath = NavigationPath()
                }
            }
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

            SidebarFooter(bookCount: books.count, onSettings: { showSettings = true })
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
        if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            SearchResultsContent(query: searchText)
        } else {
            switch navigation.sidebarSelection {
            case .home:
                HomeView(titleSize: 44, showsBrand: false)
            case .collection(let id):
                CollectionDetailView(collectionID: id, showsBrand: false)
            default:
                PadLibraryContentView(selection: navigation.sidebarSelection)
            }
        }
    }

    private var themeScheme: ColorScheme {
        switch palette.isDark {
        case true: .dark
        case false: .light
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
        // Reuse the shared alert by showing it with the rename target set.
        showRename = true
    }

    private func beginDelete(_ collection: LibraryCollection) {
        deleteTarget = collection
        showDelete = true
    }
}
#endif
