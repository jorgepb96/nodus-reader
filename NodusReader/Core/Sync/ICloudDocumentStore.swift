// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// The values of a `Book` the file layer needs. Captured on the main actor so
/// iCloud file work never touches SwiftData models off the main thread.
struct RemoteBookFile: Sendable {
    let id: UUID
    let fileName: String
    let coverFileName: String?
    let fileSize: Int64

    @MainActor
    init(_ book: Book) {
        id = book.id
        fileName = book.fileName
        coverFileName = book.coverFileName
        fileSize = book.fileSize
    }
}

/// Files live in the user's iCloud Documents container; metadata lives in
/// CloudKit. A file may arrive after its metadata, so every operation is
/// best-effort and the Book's download state is the source of truth in the UI.
///
/// Every filesystem call here can block on iCloud Drive (container lookup,
/// whole-file copies, coordinated reads), so it all runs on a background task.
/// Apple documents `url(forUbiquityContainerIdentifier:)` as unsafe to call
/// on the main thread.
final class ICloudDocumentStore: @unchecked Sendable {
    static let containerIdentifier = "iCloud.ai.nodus.reader"

    private let fileStore: FileStore
    private let lock = NSLock()
    private var cachedContainerURL: URL?
    private var resolvedContainer = false

    init(fileStore: FileStore = .shared) {
        self.fileStore = fileStore
    }

    /// Last known availability; refreshed by `refreshAvailability()`.
    var isAvailable: Bool {
        lock.withLock { cachedContainerURL != nil }
            && FileManager.default.ubiquityIdentityToken != nil
    }

    @discardableResult
    func refreshAvailability() async -> Bool {
        let url = await Task.detached(priority: .utility) {
            FileManager.default.url(forUbiquityContainerIdentifier: Self.containerIdentifier)
        }.value
        lock.withLock {
            cachedContainerURL = url
            resolvedContainer = true
        }
        return isAvailable
    }

    private func documentsRoot() async -> URL? {
        if !lock.withLock({ resolvedContainer }) {
            await refreshAvailability()
        }
        return lock.withLock { cachedContainerURL }?
            .appendingPathComponent("Documents/NodusReader", isDirectory: true)
    }

    private static func remoteFileURL(root: URL, book: RemoteBookFile) -> URL {
        root.appendingPathComponent("Books", isDirectory: true)
            .appendingPathComponent(book.id.uuidString, isDirectory: true)
            .appendingPathComponent(FileStore.sanitizedFileName(book.fileName))
    }

    private static func remoteCoverURL(root: URL, bookID: UUID) -> URL {
        root.appendingPathComponent("Covers", isDirectory: true)
            .appendingPathComponent("\(bookID.uuidString).jpg")
    }

    func hasRemoteFile(for book: RemoteBookFile) async -> Bool {
        guard let root = await documentsRoot() else { return false }
        let url = Self.remoteFileURL(root: root, book: book)
        return await Task.detached(priority: .utility) {
            FileManager.default.fileExists(atPath: url.path)
        }.value
    }

    /// iCloud may represent a not-yet-downloaded file only as a hidden
    /// placeholder, so a metadata query is the reliable way to know whether the
    /// copy exists in the user's iCloud Drive.
    func hasRemoteCopy(for book: RemoteBookFile) async -> Bool {
        await locateRemoteItem(for: book) != nil
    }

    private func locateRemoteItem(for book: RemoteBookFile) async -> URL? {
        guard let root = await documentsRoot() else { return nil }
        let remote = Self.remoteFileURL(root: root, book: book)
        let exists = await Task.detached(priority: .utility) {
            FileManager.default.fileExists(atPath: remote.path)
        }.value
        if exists { return remote }
        return await Self.metadataQuery(root: root, remote: remote)
    }

    /// `NSMetadataQuery` needs a run loop; it is started on the main actor but
    /// only waits asynchronously for its results.
    @MainActor
    private static func metadataQuery(root: URL, remote: URL) async -> URL? {
        let fileName = remote.lastPathComponent
        let expectedDirectory = remote.deletingLastPathComponent().standardizedFileURL.path
        let query = NSMetadataQuery()
        query.searchScopes = [root]
        query.predicate = NSPredicate(format: "%K == %@", NSMetadataItemFSNameKey, fileName)

        return await withCheckedContinuation { continuation in
            var observer: NSObjectProtocol?
            var finished = false
            let finish: (URL?) -> Void = { url in
                guard !finished else { return }
                finished = true
                if let observer { NotificationCenter.default.removeObserver(observer) }
                query.stop()
                continuation.resume(returning: url)
            }
            observer = NotificationCenter.default.addObserver(
                forName: .NSMetadataQueryDidFinishGathering,
                object: query,
                queue: .main
            ) { _ in
                var found: URL?
                for index in 0..<query.resultCount {
                    guard let item = query.result(at: index) as? NSMetadataItem,
                          let path = item.value(forAttribute: NSMetadataItemPathKey) as? String else { continue }
                    let url = URL(fileURLWithPath: path)
                    let parent = url.deletingLastPathComponent().standardizedFileURL.path
                    if url.lastPathComponent == fileName, parent == expectedDirectory {
                        found = url
                        break
                    }
                }
                finish(found)
            }
            query.start()
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(15))
                finish(nil)
            }
        }
    }

    /// Copies the local document and cover into iCloud Documents. iCloud Drive
    /// handles the upload; this call only needs the local bytes.
    func upload(_ book: RemoteBookFile) async {
        guard let root = await documentsRoot() else { return }
        let local = fileStore.documentURL(bookID: book.id, fileName: book.fileName)
        let cover = fileStore.coverURL(for: book.coverFileName)
        let remote = Self.remoteFileURL(root: root, book: book)
        let remoteCover = Self.remoteCoverURL(root: root, bookID: book.id)
        await Task.detached(priority: .utility) {
            let fileManager = FileManager.default
            if fileManager.fileExists(atPath: local.path) {
                do {
                    try fileManager.createDirectory(at: remote.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
                    if fileManager.fileExists(atPath: remote.path) {
                        try fileManager.removeItem(at: remote)
                    }
                    try fileManager.copyItem(at: local, to: remote)
                } catch {
                    // Metadata sync remains useful even when the file cannot be copied.
                }
            }
            if let cover, fileManager.fileExists(atPath: cover.path) {
                try? fileManager.createDirectory(at: remoteCover.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
                if fileManager.fileExists(atPath: remoteCover.path) {
                    try? fileManager.removeItem(at: remoteCover)
                }
                try? fileManager.copyItem(at: cover, to: remoteCover)
            }
        }.value
    }

    /// Downloads the document into the app container. Returns the new local
    /// cover file name when an iCloud cover was copied too.
    func download(_ book: RemoteBookFile) async throws -> String? {
        guard let remote = await locateRemoteItem(for: book) else {
            throw SyncFileError.notInICloud
        }
        let local = fileStore.documentURL(bookID: book.id, fileName: book.fileName)
        let root = await documentsRoot()
        let fileStore = fileStore
        return try await Task.detached(priority: .userInitiated) {
            let fileManager = FileManager.default
            var values = try remote.resourceValues(forKeys: [
                .isUbiquitousItemKey,
                .ubiquitousItemDownloadingStatusKey
            ])
            if values.isUbiquitousItem == true,
               values.ubiquitousItemDownloadingStatus != .current {
                try fileManager.startDownloadingUbiquitousItem(at: remote)
                var ready = false
                for _ in 0..<120 {
                    try Task.checkCancellation()
                    try await Task.sleep(for: .seconds(1))
                    values = try remote.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
                    if values.ubiquitousItemDownloadingStatus == .current {
                        ready = true
                        break
                    }
                }
                guard ready else { throw SyncFileError.downloadTimedOut }
            }

            try fileManager.createDirectory(at: local.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: local.path) {
                try fileManager.removeItem(at: local)
            }
            try fileManager.copyItem(at: remote, to: local)
            let copiedSize = FileStore.fileSize(at: local)
            if book.fileSize > 0, copiedSize != book.fileSize {
                try? fileManager.removeItem(at: local)
                throw SyncFileError.sizeMismatch
            }

            guard let root else { return nil }
            let remoteCover = Self.remoteCoverURL(root: root, bookID: book.id)
            guard fileManager.fileExists(atPath: remoteCover.path),
                  let data = try? Data(contentsOf: remoteCover) else { return nil }
            return try? fileStore.writeCover(data, bookID: book.id)
        }.value
    }

    /// Copies the iCloud cover for a book, if there is one. Returns its new
    /// local file name.
    func downloadCover(bookID: UUID) async -> String? {
        guard let root = await documentsRoot() else { return nil }
        let remote = Self.remoteCoverURL(root: root, bookID: bookID)
        let fileStore = fileStore
        return await Task.detached(priority: .utility) {
            guard FileManager.default.fileExists(atPath: remote.path),
                  let data = try? Data(contentsOf: remote) else { return nil }
            return try? fileStore.writeCover(data, bookID: bookID)
        }.value
    }

    func deleteRemoteFiles(bookID: UUID, fileName: String) async {
        guard let root = await documentsRoot() else { return }
        let folder = root
            .appendingPathComponent("Books", isDirectory: true)
            .appendingPathComponent(bookID.uuidString, isDirectory: true)
        let cover = Self.remoteCoverURL(root: root, bookID: bookID)
        await Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: cover)
        }.value
    }

    /// Used when the user cleared a custom cover: otherwise a device that
    /// pulls the book later would restore the old cover from iCloud Drive.
    func deleteRemoteCover(bookID: UUID) async {
        guard let root = await documentsRoot() else { return }
        let cover = Self.remoteCoverURL(root: root, bookID: bookID)
        await Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: cover)
        }.value
    }

    func removeLocalDownload(for book: RemoteBookFile) async throws {
        let fileStore = fileStore
        try await Task.detached(priority: .utility) {
            try fileStore.removeDocument(bookID: book.id)
        }.value
    }
}

enum SyncFileError: LocalizedError {
    case notInICloud
    case downloadTimedOut
    case sizeMismatch

    var errorDescription: String? {
        switch self {
        case .notInICloud:
            "The document is not available in iCloud yet."
        case .downloadTimedOut:
            "The iCloud download took too long. Check your connection and try again."
        case .sizeMismatch:
            "The downloaded document does not match the library metadata. Try downloading it again."
        }
    }
}
