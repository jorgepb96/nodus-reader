// SPDX-License-Identifier: AGPL-3.0-only
import CryptoKit
import Foundation
import ZIPFoundation

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

    static func directorySize(_ directory: URL, fileManager: FileManager) -> Int64 {
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
    /// coordinated access. The original file is never modified. An EPUB kept
    /// as a folder package (Apple Books, some Files providers) is zipped into
    /// a regular `.epub` file.
    public static func stageCopy(from source: URL, suggestedName: String? = nil,
                                 store: FileStore = .shared) throws -> URL {
        let accessed = source.startAccessingSecurityScopedResource()
        defer {
            if accessed { source.stopAccessingSecurityScopedResource() }
        }

        let name = suggestedName ?? source.lastPathComponent
        let staged = store.makeTemporaryURL(suggestedName: name)
        do {
            // The coordinated read also downloads a cloud file that is not
            // on this device yet.
            var coordinationError: NSError?
            var copyError: Error?
            NSFileCoordinator().coordinate(readingItemAt: source, options: [], error: &coordinationError) { readURL in
                do { try copy(readURL, to: staged, name: name) } catch { copyError = error }
            }
            if let copyError { throw copyError }
            if let coordinationError { throw coordinationError }
        } catch let error as ImportError {
            throw error
        } catch {
            // File providers sometimes drop the coordination connection
            // ("Couldn't communicate with a helper application") although the
            // item is readable under its security scope: copy it directly.
            do {
                try copy(source, to: staged, name: name)
            } catch let error as ImportError {
                throw error
            } catch {
                throw ImportError.providerUnavailable(name)
            }
        }
        guard FileManager.default.fileExists(atPath: staged.path) else {
            throw ImportError.fileAccessDenied(name)
        }
        return staged
    }

    private static func copy(_ readURL: URL, to staged: URL, name: String) throws {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: readURL.path, isDirectory: &isDirectory) else {
            throw ImportError.providerUnavailable(name)
        }
        // Check the size first: copying a multi-gigabyte file only to reject
        // it wastes minutes and disk space.
        let size = isDirectory.boolValue
            ? FileStore.directorySize(readURL, fileManager: fileManager)
            : FileStore.fileSize(at: readURL)
        if size > maximumImportBytes {
            throw ImportError.fileTooLarge(name)
        }
        if fileManager.fileExists(atPath: staged.path) {
            try fileManager.removeItem(at: staged)
        }
        if isDirectory.boolValue {
            try zipPackage(readURL, to: staged)
        } else {
            try fileManager.copyItem(at: readURL, to: staged)
        }
    }

    /// Zips a package directory with its contents at the archive root, the
    /// `mimetype` entry first and stored, as the EPUB container requires.
    static func zipPackage(_ directory: URL, to destination: URL) throws {
        let archive = try Archive(url: destination, accessMode: .create)
        let root = directory.standardizedFileURL.resolvingSymlinksInPath()
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey]
        ) else { throw ImportError.unreadableDocument(directory.lastPathComponent) }
        var paths: [String] = []
        for case let url as URL in enumerator
            where (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            let full = url.standardizedFileURL.resolvingSymlinksInPath().path
            guard full.hasPrefix(rootPath) else { continue }
            paths.append(String(full.dropFirst(rootPath.count)))
        }
        paths.sort { lhs, rhs in
            lhs == "mimetype" || (rhs != "mimetype" && lhs < rhs)
        }
        for path in paths {
            try archive.addEntry(with: path, relativeTo: root,
                                 compressionMethod: path == "mimetype" ? .none : .deflate)
        }
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
