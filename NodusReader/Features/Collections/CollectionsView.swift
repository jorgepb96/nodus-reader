// SPDX-License-Identifier: AGPL-3.0-only
import DesignSystem
import SwiftData
import SwiftUI

struct CollectionsView: View {
    @Environment(LibraryService.self) private var library
    @Environment(\.nodusPalette) private var palette

    @Query(sort: \LibraryCollection.sortIndex) private var collections: [LibraryCollection]
    @Query private var memberships: [CollectionMembership]

    @State private var showNewCollection = false
    @State private var newCollectionName = ""

    private var roots: [LibraryCollection] {
        collections
            .filter { $0.parentID == nil }
            .sorted {
                $0.sortIndex == $1.sortIndex
                    ? $0.name.localizedStandardCompare($1.name) == .orderedAscending
                    : $0.sortIndex < $1.sortIndex
            }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    DisplayTitle("Collections")
                    Text("Group documents without duplicating them.")
                        .font(.subheadline)
                        .foregroundStyle(palette.muted)
                }

                if roots.isEmpty {
                    NodusEmptyState(
                        icon: "folder",
                        title: "No collections yet",
                        message: "Create a collection, nest subcollections as deeply as you need and add the same book to several places."
                    )
                    .frame(minHeight: 320)
                    PrimaryPillButton("New Collection", systemImage: "plus") {
                        showNewCollection = true
                    }
                    .frame(maxWidth: 260)
                } else {
                    VStack(spacing: 0) {
                        ForEach(roots) { collection in
                            NavigationLink(value: collection.id) {
                                CollectionSummaryRow(
                                    collection: collection,
                                    subcollectionCount: collections.filter { $0.parentID == collection.id }.count,
                                    bookCount: bookCount(for: collection)
                                )
                            }
                            .buttonStyle(.plain)
                            if collection.id != roots.last?.id {
                                Divider().overlay(palette.line)
                            }
                        }
                    }
                    .panelCard(radius: 20)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 110)
        }
        .background(palette.background)
        .toolbar {
            ToolbarItem(placement: .principal) { BrandToolbar() }
            ToolbarItem(placement: .nodusTrailing) {
                Button {
                    showNewCollection = true
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 44, height: 44)
                        .background(palette.panel, in: Circle())
                        .overlay(Circle().stroke(palette.line, lineWidth: 1))
                }
                .accessibilityLabel("New collection")
            }
        }
        .inlineNavigationTitle()
        .navigationBarBackground(palette.background)
        .navigationDestination(for: UUID.self) { id in
            CollectionDetailView(collectionID: id)
        }
        .alert("New Collection", isPresented: $showNewCollection) {
            TextField("Name", text: $newCollectionName)
            Button("Create") {
                _ = library.createCollection(name: newCollectionName)
                newCollectionName = ""
            }
            Button("Cancel", role: .cancel) { newCollectionName = "" }
        } message: {
            Text("Collections can contain subcollections and documents.")
        }
    }

    private func bookCount(for collection: LibraryCollection) -> Int {
        let ids = Set([collection.id] + library.descendantIDs(of: collection))
        let bookIDs = memberships
            .filter { membership in
                membership.collection.map { ids.contains($0.id) } ?? false
            }
            .compactMap { $0.book?.id }
        return Set(bookIDs).count
    }
}

struct CollectionSummaryRow: View {
    @Environment(\.nodusPalette) private var palette
    let collection: LibraryCollection
    let subcollectionCount: Int
    let bookCount: Int

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "folder")
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(palette.accent)
                .frame(width: 40, height: 40)
                .background(palette.selection, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(collection.name)
                    .font(.system(size: 18, design: .serif))
                    .foregroundStyle(palette.text)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(palette.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(palette.muted)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    private var subtitle: String {
        var parts: [String] = []
        if subcollectionCount == 1 { parts.append("1 subcollection") }
        if subcollectionCount > 1 { parts.append("\(subcollectionCount) subcollections") }
        if bookCount == 1 { parts.append("1 book") } else { parts.append("\(bookCount) books") }
        return parts.joined(separator: " · ")
    }
}
