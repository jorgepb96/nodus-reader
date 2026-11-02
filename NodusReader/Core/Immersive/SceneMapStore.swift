// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// What a reader chose for one book: kept on this device only.
struct ImmersiveBookPreferences: Codable, Equatable, Sendable {
    /// Nil follows the global mode.
    var mode: ImmersiveMode?
    /// The atmosphere chosen by hand (manual mode or a pick in automatic).
    var atmosphere: Atmosphere?
    var locked = false
}

/// Immersive Audio's derived data, per book, in `Immersive/`: scene maps
/// (`Scenes/<id>.json`) and per-book choices (`Books/<id>.json`). Derived
/// from the text or chosen on this device; never synced, excluded from
/// backups (scene maps can always be rebuilt).
struct SceneMapStore: Sendable {
    let root: URL

    init(fileStore: FileStore = .shared) {
        root = fileStore.root.appendingPathComponent("Immersive", isDirectory: true)
    }

    init(root: URL) {
        self.root = root
    }

    private var scenes: URL { root.appendingPathComponent("Scenes", isDirectory: true) }
    private var books: URL { root.appendingPathComponent("Books", isDirectory: true) }

    func mapURL(for bookID: UUID) -> URL { scenes.appendingPathComponent("\(bookID.uuidString).json") }
    func preferencesURL(for bookID: UUID) -> URL { books.appendingPathComponent("\(bookID.uuidString).json") }

    func loadMap(bookID: UUID) -> SceneMap? {
        guard let data = try? Data(contentsOf: mapURL(for: bookID)) else { return nil }
        return try? JSONDecoder().decode(SceneMap.self, from: data)
    }

    func saveMap(_ map: SceneMap, bookID: UUID) {
        write(map, to: mapURL(for: bookID))
    }

    func loadPreferences(bookID: UUID) -> ImmersiveBookPreferences? {
        guard let data = try? Data(contentsOf: preferencesURL(for: bookID)) else { return nil }
        return try? JSONDecoder().decode(ImmersiveBookPreferences.self, from: data)
    }

    func savePreferences(_ preferences: ImmersiveBookPreferences, bookID: UUID) {
        if preferences == ImmersiveBookPreferences() {
            try? FileManager.default.removeItem(at: preferencesURL(for: bookID))
        } else {
            write(preferences, to: preferencesURL(for: bookID))
        }
    }

    func remove(bookID: UUID) {
        try? FileManager.default.removeItem(at: mapURL(for: bookID))
        try? FileManager.default.removeItem(at: preferencesURL(for: bookID))
    }

    /// Deletes every scene map (per-book choices are kept).
    func removeAllMaps() {
        try? FileManager.default.removeItem(at: scenes)
    }

    /// Books with saved data of either kind.
    func bookIDs() -> Set<UUID> {
        var ids = Set<UUID>()
        for directory in [scenes, books] {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            ids.formUnion(names.compactMap { UUID(uuidString: ($0 as NSString).deletingPathExtension) })
        }
        return ids
    }

    func totalSize() -> Int64 {
        FileStore.directorySize(root, fileManager: .default)
    }

    private func write<T: Encodable>(_ value: T, to url: URL) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var rootURL = root
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? rootURL.setResourceValues(values)
        try? data.write(to: url, options: .atomic)
    }
}
