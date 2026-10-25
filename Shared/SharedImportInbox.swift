// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// A collection snapshot the app publishes so the Share Extension can offer a
/// destination without opening SwiftData in another process.
struct SharedCollection: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    let name: String
    let depth: Int
}

struct SharedImportItem: Codable, Identifiable, Sendable {
    let id: UUID
    let fileName: String
    let payloadName: String
    let collectionID: UUID?
    let createdAt: Date
}

/// The App Group hand-off between the Share Extension and the app. The extension
/// only copies bytes and writes a tiny JSON manifest; all parsing, hashing,
/// metadata extraction and cover generation stay in the app.
enum SharedImportInbox {
    static let appGroupIdentifier = "group.ai.nodus.reader"

    /// Resolved once per process: the container lookup crosses into
    /// containermanager and must not run on every SwiftData save.
    private static let containerURL: URL? = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: appGroupIdentifier
    )

    static var defaultRoot: URL? {
        containerURL?.appendingPathComponent("ShareInbox", isDirectory: true)
    }

    static func root(_ override: URL? = nil) -> URL? {
        if let override { return override }
        return defaultRoot
    }

    static func collectionsURL(root override: URL? = nil) -> URL? {
        guard let root = root(override) else { return nil }
        return root.appendingPathComponent("collections.json")
    }

    static func publishCollections(_ collections: [SharedCollection], root override: URL? = nil) {
        guard let url = collectionsURL(root: override) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(collections) {
            try? data.write(to: url, options: .atomic)
        }
    }

    static func collections(root override: URL? = nil) -> [SharedCollection] {
        guard let url = collectionsURL(root: override),
              let data = try? Data(contentsOf: url),
              let values = try? JSONDecoder().decode([SharedCollection].self, from: data) else { return [] }
        return values
    }

    static func stage(fileURL: URL, fileName: String, collectionID: UUID?,
                      root override: URL? = nil) throws -> SharedImportItem {
        guard let root = root(override) else { throw SharedInboxError.appGroupUnavailable }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let id = UUID()
        let directory = root.appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let safeName = sanitized(fileName)
        let payload = directory.appendingPathComponent(safeName)
        do {
            try FileManager.default.copyItem(at: fileURL, to: payload)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        let item = SharedImportItem(id: id, fileName: safeName, payloadName: safeName,
                                    collectionID: collectionID, createdAt: Date())
        // Metadata is written last: a half-copied item is never visible to the app.
        let data = try JSONEncoder().encode(item)
        do {
            try data.write(to: directory.appendingPathComponent("item.json"), options: .atomic)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        return item
    }

    /// Copies are only visible once `item.json` exists. A process killed during
    /// staging can leave an unreachable directory behind; sweep those after a
    /// day so the shared container cannot grow without bound.
    static func sweepStale(root override: URL? = nil, olderThan interval: TimeInterval = 86_400) {
        guard let root = root(override),
              let directories = try? FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
              ) else { return }
        let cutoff = Date().addingTimeInterval(-interval)
        for directory in directories {
            let metadata = directory.appendingPathComponent("item.json")
            guard !FileManager.default.fileExists(atPath: metadata.path),
                  let values = try? directory.resourceValues(forKeys: [.contentModificationDateKey]),
                  let date = values.contentModificationDate,
                  date < cutoff else { continue }
            try? FileManager.default.removeItem(at: directory)
        }
    }

    static func pending(root override: URL? = nil) -> [SharedImportItem] {        guard let root = root(override),
              let directories = try? FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
              ) else { return [] }
        return directories.compactMap { directory in
            let metadata = directory.appendingPathComponent("item.json")
            guard let data = try? Data(contentsOf: metadata),
                  let item = try? JSONDecoder().decode(SharedImportItem.self, from: data),
                  item.payloadName == (item.payloadName as NSString).lastPathComponent,
                  !item.payloadName.isEmpty,
                  item.payloadName != ".", item.payloadName != ".." else { return nil }
            let payload = directory.appendingPathComponent(item.payloadName)
            guard FileManager.default.fileExists(atPath: payload.path) else { return nil }
            return item
        }
        .sorted { $0.createdAt < $1.createdAt }
    }

    static func fileURL(for item: SharedImportItem, root override: URL? = nil) -> URL? {
        guard let root = root(override) else { return nil }
        let url = root.appendingPathComponent(item.id.uuidString, isDirectory: true)
            .appendingPathComponent(item.payloadName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static func remove(_ item: SharedImportItem, root override: URL? = nil) {
        guard let root = root(override) else { return }
        try? FileManager.default.removeItem(at: root.appendingPathComponent(item.id.uuidString, isDirectory: true))
    }

    static func sanitized(_ name: String) -> String {
        let last = (name as NSString).lastPathComponent
        let cleaned = last
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: "\\", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, cleaned != ".", cleaned != ".." else { return "Document" }
        return cleaned
    }
}

enum SharedInboxError: LocalizedError {
    case appGroupUnavailable
    case unreadableItem(String)
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .appGroupUnavailable:
            "Nodus Reader's shared container is not available. Open the app once and check the App Group entitlement."
        case .unreadableItem(let name):
            "“\(name)” could not be read."
        case .unsupported(let name):
            "“\(name)” is not a supported document format."
        }
    }
}
