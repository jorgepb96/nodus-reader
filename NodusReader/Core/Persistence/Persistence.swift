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
        let configuration = ModelConfiguration(
            "NodusReader",
            schema: schema,
            isStoredInMemoryOnly: inMemory
        )
        return try ModelContainer(for: schema, configurations: [configuration])
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
