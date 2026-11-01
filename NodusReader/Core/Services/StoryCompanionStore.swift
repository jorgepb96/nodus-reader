// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// Where each book's recap cache lives: `Companion/<book id>.json` in the
/// app's storage. Derived from the book's text on this device, never synced;
/// deleting it only means the next recap is written again.
struct StoryCompanionStore {
    let root: URL

    init(fileStore: FileStore = .shared) {
        root = fileStore.root.appendingPathComponent("Companion", isDirectory: true)
    }

    func url(for bookID: UUID) -> URL {
        root.appendingPathComponent("\(bookID.uuidString).json")
    }

    func load(bookID: UUID) -> StoryCompanionCache? {
        guard let data = try? Data(contentsOf: url(for: bookID)) else { return nil }
        return try? JSONDecoder().decode(StoryCompanionCache.self, from: data)
    }

    func save(_ cache: StoryCompanionCache, bookID: UUID) {
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? data.write(to: url(for: bookID), options: .atomic)
    }

    func remove(bookID: UUID) {
        try? FileManager.default.removeItem(at: url(for: bookID))
    }

    func removeAll() {
        try? FileManager.default.removeItem(at: root)
    }

    /// Books with a saved cache.
    func bookIDs() -> [UUID] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return names.compactMap { UUID(uuidString: ($0 as NSString).deletingPathExtension) }
    }

    func totalSize() -> Int64 {
        FileStore.directorySize(root, fileManager: .default)
    }
}
