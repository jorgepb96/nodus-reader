// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import SwiftData
#if os(iOS)
import UIKit
#endif

public enum Persistence {
    public static let schema = Schema([
        Book.self,
        LibraryCollection.self,
        CollectionMembership.self,
        Bookmark.self,
        Annotation.self,
        SyncOutboxEntry.self,
        SyncTombstone.self
    ])

    /// The app store lives in Application Support. CloudKit metadata and
    /// iCloud Documents are layered on top of this local replica; the SwiftData
    /// file itself is never treated as a document.
    public static func makeContainer(inMemory: Bool = false) throws -> ModelContainer {
        try ModelContainer(for: schema, configurations: [configuration(inMemory: inMemory)])
    }

    /// SwiftData defaults to `.automatic` for both CloudKit and the App Group.
    /// With the iCloud and App Group entitlements of a signed build that means
    /// NSPersistentCloudKitContainer mirroring (which rejects this schema's
    /// unique IDs and required relationships, so the app could not open its
    /// library at launch) and a store moved into the shared group container.
    /// Sync is done by `CloudSyncService`; the store stays in this app's
    /// Application Support.
    static func configuration(inMemory: Bool = false) -> ModelConfiguration {
        ModelConfiguration(
            "NodusReader",
            schema: schema,
            isStoredInMemoryOnly: inMemory,
            groupContainer: .none,
            cloudKitDatabase: .none
        )
    }
}

public enum DeviceInfo {
    public static var name: String {
        #if os(macOS)
        return Host.current().localizedName ?? "Mac"
        #elseif os(iOS)
        return UIDevice.current.name
        #else
        return "Device"
        #endif
    }

    public static var platformName: String {
        #if os(macOS)
        return "Mac"
        #elseif os(iOS)
        return UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
        #else
        return "Device"
        #endif
    }

    public static var isPad: Bool {
        #if os(iOS)
        return UIDevice.current.userInterfaceIdiom == .pad
        #else
        return false
        #endif
    }
}
