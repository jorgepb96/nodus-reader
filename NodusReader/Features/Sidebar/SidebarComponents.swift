// SPDX-License-Identifier: AGPL-3.0-only
import DesignSystem
import SwiftUI

extension SmartList {
    var destination: SidebarDestination {
        switch self {
        case .home: .home
        case .allBooks: .allBooks
        case .favorites: .favorites
        case .toRead: .toRead
        case .finished: .finished
        case .inbox: .inbox
        }
    }

    var dotColor: Color {
        switch self {
        case .home: NodusColors.lavender
        case .allBooks: NodusColors.mutedGrey
        case .favorites: NodusColors.gold
        case .toRead: NodusColors.slateBlue
        case .finished: NodusColors.sage
        case .inbox: NodusColors.rose
        }
    }
}

struct SidebarSmartListRow: View {
    @Environment(\.nodusPalette) private var palette
    let list: SmartList
    let count: Int

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(list.dotColor)
                .frame(width: 8, height: 8)
            Text(list.title)
                .font(.subheadline)
                .foregroundStyle(palette.text)
            Spacer(minLength: 8)
            if count > 0 {
                Text("\(count)")
                    .font(.caption)
                    .foregroundStyle(palette.muted)
                    .monospacedDigit()
            }
        }
        .tag(list.destination)
        .accessibilityElement(children: .combine)
    }
}

struct SidebarFooter: View {
    @Environment(\.nodusPalette) private var palette
    @Environment(CloudSyncService.self) private var sync
    let bookCount: Int
    var onSettings: (() -> Void)?

    /// iCloud sync state when it is on; otherwise the local library.
    private var syncIcon: String {
        switch sync.status {
        case .syncing: "arrow.triangle.2.circlepath.icloud"
        case .upToDate: "checkmark.icloud"
        case .error, .unavailable: "exclamationmark.icloud"
        case .offline: "icloud.slash"
        case .waiting, .disabled: "icloud"
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: sync.isEnabled ? syncIcon : "internaldrive")
                .font(.system(size: 15))
                .foregroundStyle(palette.accent)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(sync.isEnabled ? sync.status.title : String(localized: "On this device"))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(palette.text)
                Text(sync.isEnabled ? String(localized: "\(bookCount) books · iCloud")
                                    : String(localized: "\(bookCount) books · Local library"))
                    .font(.caption2)
                    .foregroundStyle(palette.muted)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 0)
            if let onSettings {
                Button(action: onSettings) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 14))
                        .foregroundStyle(palette.muted)
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Settings")
            }
        }
        .padding(10)
        .background(palette.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
    }
}

/// Recursive collection outline used by the iPad and Mac sidebars.
struct CollectionOutlineRow: View {
    @Environment(\.nodusPalette) private var palette
    @Environment(LibraryService.self) private var library

    let collection: LibraryCollection
    let depth: Int
    let allCollections: [LibraryCollection]
    let memberships: [CollectionMembership]
    @Binding var selection: SidebarDestination?
    var onNewSubcollection: (LibraryCollection) -> Void
    var onRename: (LibraryCollection) -> Void
    var onDelete: (LibraryCollection) -> Void

    @State private var expanded = false

    private var children: [LibraryCollection] {
        allCollections
            .filter { $0.parentID == collection.id }
            .sorted {
                $0.sortIndex == $1.sortIndex
                    ? $0.name.localizedStandardCompare($1.name) == .orderedAscending
                    : $0.sortIndex < $1.sortIndex
            }
    }

    private var bookCount: Int {
        let ids = Set([collection.id] + library.descendantIDs(of: collection))
        let bookIDs = memberships
            .filter { membership in membership.collection.map { ids.contains($0.id) } ?? false }
            .compactMap { $0.book?.id }
        return Set(bookIDs).count
    }

    private var moveTargets: [LibraryCollection] {
        let descendants = Set(library.descendantIDs(of: collection))
        return allCollections.filter { $0.id != collection.id && !descendants.contains($0.id) }
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            ForEach(children) { child in
                CollectionOutlineRow(
                    collection: child,
                    depth: depth + 1,
                    allCollections: allCollections,
                    memberships: memberships,
                    selection: $selection,
                    onNewSubcollection: onNewSubcollection,
                    onRename: onRename,
                    onDelete: onDelete
                )
            }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "folder")
                    .font(.system(size: 14))
                    .foregroundStyle(palette.accent)
                Text(collection.name)
                    .font(.subheadline)
                    .foregroundStyle(palette.text)
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text("\(bookCount)")
                    .font(.caption2)
                    .foregroundStyle(palette.muted)
                    .monospacedDigit()
            }
            .contentShape(Rectangle())
            .onTapGesture {
                selection = .collection(collection.id)
            }
            .tag(SidebarDestination.collection(collection.id))
        }
        .tag(SidebarDestination.collection(collection.id))
        .contextMenu {
            Button {
                onNewSubcollection(collection)
            } label: {
                Label("New Subcollection…", systemImage: "folder.badge.plus")
            }
            Button {
                onRename(collection)
            } label: {
                Label("Rename…", systemImage: "pencil")
            }
            if !moveTargets.isEmpty {
                Menu {
                    Button("Library (top level)") {
                        library.moveCollection(collection, toParent: nil)
                    }
                    Divider()
                    ForEach(moveTargets) { target in
                        Button(library.collectionPath(for: target).map(\.name).joined(separator: " / ")) {
                            library.moveCollection(collection, toParent: target.id)
                        }
                    }
                } label: {
                    Label("Move to", systemImage: "arrow.turn.down.right")
                }
            }
            Divider()
            Button(role: .destructive) {
                onDelete(collection)
            } label: {
                Label("Delete Collection…", systemImage: "trash")
            }
        }
        .accessibilityElement(children: .contain)
    }
}
