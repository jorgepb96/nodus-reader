// SPDX-License-Identifier: AGPL-3.0-only
import CryptoKit
import Foundation

/// Owns the on-disk layout of the library.
///
/// ```
/// Application Support/NodusReader/
///   Library/<book-id>/<original name>
///   Covers/<book-id>.jpg
///   Temporary/
/// ```
///
/// Only relative paths are persisted, so the container URL can move between
/// launches (and between iOS and macOS) safely.
public final class FileStore: @unchecked Sendable {
    public static let shared = FileStore()

    public let root: URL
    private let fileManager: FileManager

    public init(root: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        if let root {
            self.root = root
        } else {
            let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? fileManager.temporaryDirectory
            self.root = base.appendingPathComponent("NodusReader", isDirectory: true)
        }
        ensureDirectories()
    }

    public var libraryDirectory: URL {
        root.appendingPathComponent("Library", isDirectory: true)
    }

    public var coversDirectory: URL {
        root.appendingPathComponent("Covers", isDirectory: true)
    }

    public var temporaryDirectory: URL {
        root.appendingPathComponent("Temporary", isDirectory: true)
    }

    private func ensureDirectories() {
        for directory in [root, libraryDirectory, coversDirectory, temporaryDirectory] {
            try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    /// Resolves a persisted relative path defensively. Only paths inside the
    /// app's `Library` directory are accepted; a malformed remote record must
    /// never be able to point deletion at the app container or outside it.
    public func documentURL(for relativePath: String) -> URL {
        let candidate = root.appendingPathComponent(relativePath).standardizedFileURL
        let base = libraryDirectory.standardizedFileURL
        guard !relativePath.isEmpty,
              !relativePath.hasPrefix("/"),
              !relativePath.contains(".."),
              candidate.path.hasPrefix(base.path + "/") else {
            return libraryDirectory.appendingPathComponent(".invalid-path")
        }
        return candidate
    }

    /// Canonical on-disk location for a book. `relativePath` is synchronized
    /// data, so the live URL is derived from the stable ID and sanitized file
    /// name instead of trusting the stored path.
    public func documentURL(for book: Book) -> URL {
        documentURL(bookID: book.id, fileName: book.fileName)
    }

    public func documentURL(bookID: UUID, fileName: String) -> URL {
        libraryDirectory
            .appendingPathComponent(bookID.uuidString, isDirectory: true)
            .appendingPathComponent(Self.sanitizedFileName(fileName))
    }

    public func coverURL(for fileName: String?) -> URL? {
        guard let fileName, !fileName.isEmpty else { return nil }
        let safe = Self.sanitizedFileName(fileName)
        guard safe != ".", safe != ".." else { return nil }
        return coversDirectory.appendingPathComponent(safe)
    }

    public func coverForBook(_ book: Book) -> URL? {
        coverURL(for: book.coverFileName)
    }

    // MARK: - Import staging

    public func makeTemporaryURL(suggestedName: String) -> URL {
        let safeName = Self.sanitizedFileName(suggestedName)
        let directory = temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(safeName)
    }

    /// Moves a staged file into its permanent location.
    /// - Returns: the relative path and final size.
    public func commit(temporaryURL: URL, bookID: UUID, fileName: String) throws -> (relativePath: String, size: Int64) {
        let safeName = Self.sanitizedFileName(fileName)
        let folder = libraryDirectory.appendingPathComponent(bookID.uuidString, isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent(safeName)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: temporaryURL, to: destination)
        let size = Self.fileSize(at: destination)
        let relative = "Library/\(bookID.uuidString)/\(safeName)"
        return (relative, size)
    }

    public func writeCover(_ data: Data, bookID: UUID) throws -> String {
        try fileManager.createDirectory(at: coversDirectory, withIntermediateDirectories: true)
        let name = "\(bookID.uuidString)-\(UUID().uuidString).jpg"
        let url = coversDirectory.appendingPathComponent(name)
        try data.write(to: url, options: .atomic)
        return name
    }

    public func removeBookFiles(_ book: Book) {
        let folder = libraryDirectory.appendingPathComponent(book.id.uuidString, isDirectory: true)
        if folder.lastPathComponent == book.id.uuidString {
            try? fileManager.removeItem(at: folder)
        }
        if let cover = coverURL(for: book.coverFileName) {
            try? fileManager.removeItem(at: cover)
        }
        let reflow = root.appendingPathComponent("Reflow", isDirectory: true)
            .appendingPathComponent(book.id.uuidString, isDirectory: true)
        try? fileManager.removeItem(at: reflow)
    }

    /// Removes only the document copy (the "Remove Download" path once iCloud
    /// sync exists). Metadata and annotations stay in the local database.
    public func removeDocument(_ book: Book) throws {
        try removeDocument(bookID: book.id)
    }

    public func removeDocument(bookID: UUID) throws {
        let folder = libraryDirectory.appendingPathComponent(bookID.uuidString, isDirectory: true)
        guard folder.lastPathComponent == bookID.uuidString,
              fileManager.fileExists(atPath: folder.path) else { return }
        try fileManager.removeItem(at: folder)
    }

    public func cleanTemporaryFiles(olderThan interval: TimeInterval = 60 * 60 * 24) {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: temporaryDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        let cutoff = Date().addingTimeInterval(-interval)
        for url in contents {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            if let date = values?.contentModificationDate, date < cutoff {
                try? fileManager.removeItem(at: url)
            }
        }
    }

    public func librarySize() -> Int64 {
        Self.directorySize(libraryDirectory, fileManager: fileManager)
    }

    public func coversSize() -> Int64 {
        Self.directorySize(coversDirectory, fileManager: fileManager)
    }

    public func size(ofBook book: Book) -> Int64 {
        var total = Self.fileSize(at: documentURL(for: book))
        if let cover = coverURL(for: book.coverFileName) {
            total += Self.fileSize(at: cover)
        }
        return total
    }

    // MARK: - Helpers

    public static func sanitizedFileName(_ name: String) -> String {
        let last = (name as NSString).lastPathComponent
        let cleaned = last
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: "\\", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, cleaned != ".", cleaned != ".." else { return "Document" }
        return cleaned
    }

    public static func fileSize(at url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values?.fileSize ?? 0)
    }

    private static func directorySize(_ directory: URL, fileManager: FileManager) -> Int64 {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]
        ) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if values?.isRegularFile == true {
                total += Int64(values?.fileSize ?? 0)
            }
        }
        return total
    }
}

// MARK: - Security-scoped access

public enum FileAccess {
    /// Documents above this size are rejected before any byte is copied.
    public static let maximumImportBytes: Int64 = 250 * 1024 * 1024

    /// Copies an externally supplied URL into the app's staging area using
    /// coordinated access. The original file is never modified.
    public static func stageCopy(from source: URL, suggestedName: String? = nil,
                                 store: FileStore = .shared) throws -> URL {
        let accessed = source.startAccessingSecurityScopedResource()
        defer {
            if accessed { source.stopAccessingSecurityScopedResource() }
        }

        let staged = store.makeTemporaryURL(suggestedName: suggestedName ?? source.lastPathComponent)
        var coordinationError: NSError?
        var copyError: Error?

        NSFileCoordinator().coordinate(readingItemAt: source, options: [], error: &coordinationError) { readURL in
            do {
                // Check the size first: copying a multi-gigabyte file only to
                // reject it wastes minutes and disk space.
                if FileStore.fileSize(at: readURL) > maximumImportBytes {
                    throw ImportError.fileTooLarge(source.lastPathComponent)
                }
                if FileManager.default.fileExists(atPath: staged.path) {
                    try FileManager.default.removeItem(at: staged)
                }
                try FileManager.default.copyItem(at: readURL, to: staged)
            } catch {
                copyError = error
            }
        }

        if let coordinationError { throw coordinationError }
        if let copyError { throw copyError }
        guard FileManager.default.fileExists(atPath: staged.path) else {
            throw ImportError.fileAccessDenied(source.lastPathComponent)
        }
        return staged
    }
}

// MARK: - Hashing

public enum ContentHash {
    public static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 1024 * 1024) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
