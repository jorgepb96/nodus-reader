// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// Files live in the user's iCloud Documents container; metadata lives in
/// CloudKit. A file may arrive after its metadata, so every operation is
/// best-effort and the Book's download state is the source of truth in the UI.
@MainActor
final class ICloudDocumentStore {
    static let containerIdentifier = "iCloud.ai.nodus.reader"

    private let fileManager: FileManager
    private let fileStore: FileStore

    init(fileStore: FileStore = .shared, fileManager: FileManager = .default) {
        self.fileStore = fileStore
        self.fileManager = fileManager
    }

    var isAvailable: Bool {
        fileManager.ubiquityIdentityToken != nil && containerURL != nil
    }

    private var containerURL: URL? {
        fileManager.url(forUbiquityContainerIdentifier: Self.containerIdentifier)
    }

    private var documentsRoot: URL? {
        containerURL?.appendingPathComponent("Documents/NodusReader", isDirectory: true)
    }

    func remoteFileURL(for book: Book) -> URL? {
        documentsRoot?
            .appendingPathComponent("Books", isDirectory: true)
            .appendingPathComponent(book.id.uuidString, isDirectory: true)
            .appendingPathComponent(book.fileName)
    }

    func remoteCoverURL(for bookID: UUID) -> URL? {
        documentsRoot?
            .appendingPathComponent("Covers", isDirectory: true)
            .appendingPathComponent("\(bookID.uuidString).jpg")
    }

    func hasRemoteFile(for book: Book) -> Bool {
        guard let url = remoteFileURL(for: book) else { return false }
        guard fileManager.fileExists(atPath: url.path) else { return false }
        return true
    }

    /// iCloud may represent a not-yet-downloaded file only as a hidden
    /// placeholder, so a metadata query is the reliable way to know whether the
    /// copy exists in the user's iCloud Drive.
    func hasRemoteCopy(for book: Book) async -> Bool {
        await locateRemoteItem(for: book) != nil
    }

    private func locateRemoteItem(for book: Book) async -> URL? {
        guard let remote = remoteFileURL(for: book), let root = documentsRoot else { return nil }
        if fileManager.fileExists(atPath: remote.path) { return remote }

        let fileName = book.fileName
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
                    if url.lastPathComponent == fileName {
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
    func upload(_ book: Book) {
        guard isAvailable, let remote = remoteFileURL(for: book) else { return }
        let local = fileStore.documentURL(for: book)
        guard fileManager.fileExists(atPath: local.path) else { return }
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

        if let cover = fileStore.coverURL(for: book.coverFileName),
           let remoteCover = remoteCoverURL(for: book.id),
           fileManager.fileExists(atPath: cover.path) {
            try? fileManager.createDirectory(at: remoteCover.deletingLastPathComponent(),
                                             withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: remoteCover.path) {
                try? fileManager.removeItem(at: remoteCover)
            }
            try? fileManager.copyItem(at: cover, to: remoteCover)
        }
    }

    func download(_ book: Book) async throws {
        guard let remote = await locateRemoteItem(for: book) else {
            throw SyncFileError.notInICloud
        }

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

        let local = fileStore.documentURL(for: book)
        try fileManager.createDirectory(at: local.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: local.path) {
            try fileManager.removeItem(at: local)
        }
        try fileManager.copyItem(at: remote, to: local)

        if let remoteCover = remoteCoverURL(for: book.id),
           fileManager.fileExists(atPath: remoteCover.path) {
            let data = try? Data(contentsOf: remoteCover)
            if let data, let name = try? fileStore.writeCover(data, bookID: book.id) {
                book.coverFileName = name
            }
        }
    }

    func downloadCover(for book: Book) {
        guard let remote = remoteCoverURL(for: book.id),
              fileManager.fileExists(atPath: remote.path),
              let data = try? Data(contentsOf: remote),
              let name = try? fileStore.writeCover(data, bookID: book.id) else { return }
        book.coverFileName = name
        book.touch()
    }

    func deleteRemoteFiles(for book: Book) {
        deleteRemoteFiles(bookID: book.id, fileName: book.fileName)
    }

    func deleteRemoteFiles(bookID: UUID, fileName: String) {
        guard let root = documentsRoot else { return }
        let remote = root
            .appendingPathComponent("Books", isDirectory: true)
            .appendingPathComponent(bookID.uuidString, isDirectory: true)
        try? fileManager.removeItem(at: remote)
        if let cover = remoteCoverURL(for: bookID) {
            try? fileManager.removeItem(at: cover)
        }
    }

    func removeLocalDownload(for book: Book) throws {
        try fileStore.removeDocument(book)
    }

    func size(of book: Book) -> Int64 {
        guard let remote = remoteFileURL(for: book) else { return 0 }
        return FileStore.fileSize(at: remote)
    }
}

enum SyncFileError: LocalizedError {
    case notInICloud
    case downloadTimedOut

    var errorDescription: String? {
        switch self {
        case .notInICloud:
            "The document is not available in iCloud yet."
        case .downloadTimedOut:
            "The iCloud download took too long. Check your connection and try again."
        }
    }
}
