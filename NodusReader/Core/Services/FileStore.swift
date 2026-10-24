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

    public func documentURL(for relativePath: String) -> URL {
        root.appendingPathComponent(relativePath)
    }

    public func documentURL(for book: Book) -> URL {
        documentURL(for: book.relativePath)
    }

    public func coverURL(for fileName: String?) -> URL? {
        guard let fileName, !fileName.isEmpty else { return nil }
        return coversDirectory.appendingPathComponent(fileName)
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
        let name = "\(bookID.uuidString)-\(Int(Date().timeIntervalSince1970 * 1000)).jpg"
        let url = coversDirectory.appendingPathComponent(name)
        try data.write(to: url, options: .atomic)
        return name
    }

    public func removeBookFiles(_ book: Book) {
        let document = documentURL(for: book)
        try? fileManager.removeItem(at: document.deletingLastPathComponent())
        if let cover = coverURL(for: book.coverFileName) {
            try? fileManager.removeItem(at: cover)
        }
    }

    /// Removes only the document copy (the "Remove Download" path once iCloud
    /// sync exists). Metadata and annotations stay in the local database.
    public func removeDocument(_ book: Book) throws {
        let document = documentURL(for: book)
        guard fileManager.fileExists(atPath: document.path) else { return }
        try fileManager.removeItem(at: document.deletingLastPathComponent())
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
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Document" : cleaned
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
