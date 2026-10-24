// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Observation
import SwiftData
import SwiftUI

// MARK: - Import result types

public struct ImportFailure: Identifiable, Sendable {
    public let id = UUID()
    public let fileName: String
    public let message: String

    public init(fileName: String, message: String) {
        self.fileName = fileName
        self.message = message
    }
}

public struct ImportResult {
    public var imported: [Book] = []
    public var duplicates: [String] = []
    public var failures: [ImportFailure] = []

    public var isEmpty: Bool {
        imported.isEmpty && duplicates.isEmpty && failures.isEmpty
    }

    public var summaryText: String {
        var parts: [String] = []
        if imported.count == 1 { parts.append("1 document imported") }
        if imported.count > 1 { parts.append("\(imported.count) documents imported") }
        if !duplicates.isEmpty {
            parts.append(duplicates.count == 1 ? "1 duplicate skipped" : "\(duplicates.count) duplicates skipped")
        }
        if !failures.isEmpty {
            parts.append(failures.count == 1 ? "1 file could not be imported" : "\(failures.count) files could not be imported")
        }
        return parts.joined(separator: " · ")
    }
}

public struct ImportProgress: Sendable {
    public var current: Int
    public var total: Int
    public var fileName: String

    public init(current: Int, total: Int, fileName: String) {
        self.current = current
        self.total = total
        self.fileName = fileName
    }
}

// MARK: - Library service

/// All library mutations go through this object. It owns the SwiftData context
/// on the main actor and performs file parsing off the main thread.
@MainActor
@Observable
public final class LibraryService {
    public let context: ModelContext
    public let fileStore: FileStore
    weak var syncJournal: SyncJournal?
    var narrationCache: NarrationAudioCache?
    @ObservationIgnored private var publishedCollectionsFingerprint: String?

    public init(context: ModelContext, fileStore: FileStore = .shared) {
        self.context = context
        self.fileStore = fileStore
    }

    // MARK: Import

    public func importFiles(_ urls: [URL], into collectionID: UUID? = nil,
                            progress: (ImportProgress) -> Void) async -> ImportResult {
        var result = ImportResult()
        let total = urls.count

        for (index, url) in urls.enumerated() {
            progress(ImportProgress(current: index + 1, total: total, fileName: url.lastPathComponent))
            do {
                switch try await importOne(url: url, collectionID: collectionID) {
                case .imported(let book):
                    result.imported.append(book)
                case .duplicate(let title):
                    result.duplicates.append(title)
                }
            } catch {
                result.failures.append(ImportFailure(
                    fileName: url.lastPathComponent,
                    message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                ))
            }
        }

        fileStore.cleanTemporaryFiles()
        return result
    }

    private enum SingleImport {
        case imported(Book)
        case duplicate(String)
    }

    private func importOne(url: URL, collectionID: UUID?) async throws -> SingleImport {
        guard url.isFileURL else {
            throw ImportError.fileAccessDenied(url.lastPathComponent)
        }
        guard let format = BookFormat(fileExtension: url.pathExtension) else {
            throw ImportError.unsupportedFormat(url.lastPathComponent)
        }

        let originalName = url.lastPathComponent
        let staged = try FileAccess.stageCopy(from: url, suggestedName: originalName, store: fileStore)
        var moved = false
        defer {
            if !moved {
                try? FileManager.default.removeItem(at: staged.deletingLastPathComponent())
            }
        }

        let hash = try ContentHash.sha256(of: staged)
        if let existing = try existingBook(withHash: hash) {
            return .duplicate(existing.title)
        }

        let extraction = try await Task.detached(priority: .userInitiated) {
            try DocumentExtractor.extract(url: staged, format: format)
        }.value

        let bookID = UUID()
        let coverData = CoverGenerator.coverData(
            extraction: extraction,
            documentURL: staged,
            format: format,
            title: extraction.title,
            author: extraction.author
        )

        let committed = try fileStore.commit(temporaryURL: staged, bookID: bookID, fileName: originalName)
        moved = true

        let book = Book(
            id: bookID,
            title: extraction.title,
            author: extraction.author,
            format: format,
            language: extraction.language,
            published: extraction.published,
            bookDescription: extraction.summary,
            fileName: FileStore.sanitizedFileName(originalName),
            relativePath: committed.relativePath,
            fileSize: committed.size,
            contentHash: hash,
            searchText: extraction.searchText,
            sourceDevice: DeviceInfo.name
        )
        book.setChapterTitles(extraction.chapterTitles)
        if let coverData, let coverName = try? fileStore.writeCover(coverData, bookID: bookID) {
            book.coverFileName = coverName
        }

        context.insert(book)

        if let collectionID, let collection = collection(withID: collectionID) {
            let next = (collection.memberships.map(\.sortIndex).max() ?? -1) + 1
            let membership = CollectionMembership(book: book, collection: collection, sortIndex: next)
            context.insert(membership)
        }

        do {
            try context.save()
        } catch {
            context.delete(book)
            try? FileManager.default.removeItem(at: fileStore.documentURL(for: committed.relativePath).deletingLastPathComponent())
            throw error
        }
        try? FileManager.default.removeItem(at: staged.deletingLastPathComponent())
        return .imported(book)
    }

    private func existingBook(withHash hash: String) throws -> Book? {
        var descriptor = FetchDescriptor<Book>(predicate: #Predicate<Book> { $0.contentHash == hash })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    // MARK: Fetching

    public func allBooks() -> [Book] {
        (try? context.fetch(FetchDescriptor<Book>())) ?? []
    }

    public func books(sortedBy sort: LibrarySort) -> [Book] {
        let books = allBooks()
        switch sort {
        case .recentlyOpened:
            return books.sorted {
                ($0.lastOpenedAt ?? .distantPast) > ($1.lastOpenedAt ?? .distantPast)
            }
        case .recentlyAdded:
            return books.sorted { $0.addedAt > $1.addedAt }
        case .title:
            return books.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .author:
            return books.sorted { $0.author.localizedStandardCompare($1.author) == .orderedAscending }
        }
    }

    public func books(in list: SmartList) -> [Book] {
        let books = books(sortedBy: .recentlyOpened)
        switch list {
        case .home, .allBooks:
            return books
        case .favorites:
            return books.filter(\.isFavorite)
        case .toRead:
            return books.filter { $0.status == .toRead }
        case .finished:
            return books.filter { $0.status == .finished }
        case .inbox:
            return books.filter { $0.memberships.isEmpty }
        }
    }

    public func search(_ query: String, among books: [Book]) -> [Book] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return books }
        return books.filter { book in
            book.title.localizedCaseInsensitiveContains(trimmed)
                || book.author.localizedCaseInsensitiveContains(trimmed)
                || book.searchText.localizedCaseInsensitiveContains(trimmed)
                || book.collectionNames.contains { $0.localizedCaseInsensitiveContains(trimmed) }
        }
    }

    public func continueBook() -> Book? {
        let opened = allBooks()
            .filter { $0.lastOpenedAt != nil }
            .sorted { ($0.lastOpenedAt ?? .distantPast) > ($1.lastOpenedAt ?? .distantPast) }
        return opened.first { $0.status != .finished && $0.progress < 0.999 } ?? opened.first
    }

    public func upNext(limit: Int = 8) -> [Book] {
        let currentID = continueBook()?.id
        let books = allBooks()
            .filter { $0.id != currentID }
            .filter { $0.status != .finished }
            .sorted {
                let lhs = $0.lastOpenedAt ?? $0.addedAt
                let rhs = $1.lastOpenedAt ?? $1.addedAt
                return lhs > rhs
            }
        return Array(books.prefix(limit))
    }

    // MARK: Open / progress

    public func open(_ book: Book) {
        let now = Date()
        book.lastOpenedAt = now
        if book.status == .toRead {
            book.status = .inProgress
        }
        book.lastPositionDevice = DeviceInfo.name
        book.lastPositionDate = now
        book.touch()
        save()
    }

    public func updateProgress(_ book: Book, locator: ReadingLocator, progress: Double) {
        book.locator = locator
        book.progress = min(max(progress, 0), 1)
        book.lastOpenedAt = Date()
        book.lastPositionDevice = DeviceInfo.name
        book.lastPositionDate = Date()
        if book.progress >= 0.995 {
            book.progress = 1
            book.status = .finished
        } else if book.progress > 0 {
            book.status = .inProgress
        }
        book.touch()
        save()
    }

    public func setFavorite(_ book: Book, isFavorite: Bool) {
        book.isFavorite = isFavorite
        book.touch()
        save()
    }

    public func setStatus(_ book: Book, status: ReadingStatus) {
        book.status = status
        if status == .finished { book.progress = 1 }
        if status == .toRead { book.progress = 0 }
        book.touch()
        save()
    }

    public func setReadingMode(_ book: Book, mode: ReadingMode) {
        book.readingMode = mode
        save()
    }

    // MARK: Bookmarks

    public func bookmarks(for book: Book) -> [Bookmark] {
        book.bookmarks.sorted { $0.createdAt > $1.createdAt }
    }

    @discardableResult
    public func addBookmark(_ book: Book, title: String, chapterTitle: String,
                            locator: ReadingLocator) -> Bookmark {
        let bookmark = Bookmark(book: book, title: title, chapterTitle: chapterTitle, locator: locator)
        context.insert(bookmark)
        save()
        return bookmark
    }

    public func renameBookmark(_ bookmark: Bookmark, title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        bookmark.title = trimmed
        bookmark.touch()
        save()
    }

    public func deleteBookmark(_ bookmark: Bookmark) {
        syncJournal?.recordDelete(.bookmark, id: bookmark.id)
        context.delete(bookmark)
        save()
    }

    // MARK: Annotations

    public func annotations(for book: Book) -> [Annotation] {
        book.annotations.sorted {
            $0.chapterIndex == $1.chapterIndex
                ? $0.startOffset < $1.startOffset
                : $0.chapterIndex < $1.chapterIndex
        }
    }

    public func annotations(for book: Book, chapterIndex: Int) -> [Annotation] {
        book.annotations
            .filter { $0.chapterIndex == chapterIndex }
            .sorted { $0.startOffset < $1.startOffset }
    }

    @discardableResult
    public func addAnnotation(_ book: Book, chapterIndex: Int, startOffset: Int, endOffset: Int,
                              quote: String, color: AnnotationColor = .yellow,
                              note: String = "") -> Annotation {
        let annotation = Annotation(book: book, chapterIndex: chapterIndex,
                                    startOffset: startOffset, endOffset: endOffset,
                                    quote: quote, note: note, color: color)
        context.insert(annotation)
        save()
        return annotation
    }

    public func updateAnnotation(_ annotation: Annotation, note: String? = nil,
                                 color: AnnotationColor? = nil) {
        if let note { annotation.note = note }
        if let color { annotation.color = color }
        annotation.touch()
        save()
    }

    public func deleteAnnotation(_ annotation: Annotation) {
        syncJournal?.recordDelete(.annotation, id: annotation.id)
        context.delete(annotation)
        save()
    }

    public func exportNotes(for book: Book) -> String {
        var lines: [String] = ["# \(book.title)", "", "by \(book.displayAuthor)", ""]
        let bookmarks = bookmarks(for: book)
        if !bookmarks.isEmpty {
            lines.append("## Bookmarks")
            lines.append("")
            for bookmark in bookmarks {
                let chapter = bookmark.chapterTitle.isEmpty ? "Chapter \(bookmark.locator.chapterIndex + 1)" : bookmark.chapterTitle
                lines.append("- **\(bookmark.title)** — \(chapter)")
            }
            lines.append("")
        }
        let notes = annotations(for: book)
        if !notes.isEmpty {
            lines.append("## Highlights and notes")
            lines.append("")
            for annotation in notes {
                lines.append("> \(annotation.quote)")
                lines.append("")
                if annotation.isNote {
                    lines.append(annotation.note)
                    lines.append("")
                }
                lines.append("— Chapter \(annotation.chapterIndex + 1)")
                lines.append("")
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Metadata

    public func updateMetadata(_ book: Book, title: String, author: String,
                               language: String, published: String, summary: String) {
        book.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        book.author = author.trimmingCharacters(in: .whitespacesAndNewlines)
        book.language = language.trimmingCharacters(in: .whitespacesAndNewlines)
        book.published = published.trimmingCharacters(in: .whitespacesAndNewlines)
        book.bookDescription = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        book.touch()
        save()
    }

    public func setCustomCover(_ book: Book, imageData: Data) -> Bool {
        guard let jpeg = ImagePipeline.jpegData(fromImageData: imageData, maxPixel: 1600),
              let name = try? fileStore.writeCover(jpeg, bookID: book.id) else { return false }
        if let previous = book.coverFileName, let oldURL = fileStore.coverURL(for: previous) {
            try? FileManager.default.removeItem(at: oldURL)
        }
        book.coverFileName = name
        book.touch()
        save()
        return true
    }

    public func setPreferredVoice(_ book: Book, voiceID: String?) {
        book.preferredVoiceID = voiceID
        save()
    }

    public func clearCustomCover(_ book: Book) {
        if let name = book.coverFileName,
           let url = fileStore.coverURL(for: name) {
            try? FileManager.default.removeItem(at: url)
        }
        book.coverFileName = nil
        book.touch()
        save()
    }

    /// Depth-first collection list with indentation depth, used by tree pickers.
    public func flattenedCollections() -> [(collection: LibraryCollection, depth: Int)] {
        var result: [(LibraryCollection, Int)] = []
        func visit(_ parentID: UUID?, depth: Int) {
            for child in allCollections()
                .filter({ $0.parentID == parentID })
                .sorted(by: {
                    $0.sortIndex == $1.sortIndex
                        ? $0.name.localizedStandardCompare($1.name) == .orderedAscending
                        : $0.sortIndex < $1.sortIndex
                }) {
                result.append((child, depth))
                visit(child.id, depth: depth + 1)
            }
        }
        visit(nil, depth: 0)
        return result
    }

    public func delete(_ book: Book) {
        let bookID = book.id
        recordDeletions(for: book)
        fileStore.removeBookFiles(book)
        context.delete(book)
        save()
        if let cache = narrationCache {
            Task.detached { await cache.deleteBook(bookID: bookID) }
        }
    }

    public func deleteBooks(_ books: [Book]) {
        let ids = books.map(\.id)
        for book in books {
            recordDeletions(for: book)
            fileStore.removeBookFiles(book)
            context.delete(book)
        }
        save()
        if let cache = narrationCache {
            Task.detached {
                for id in ids { await cache.deleteBook(bookID: id) }
            }
        }
    }

    private func recordDeletions(for book: Book) {
        let payload = (try? JSONSerialization.data(withJSONObject: ["fileName": book.fileName]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? ""
        syncJournal?.recordDelete(.book, id: book.id, payloadJSON: payload)
        for membership in book.memberships { syncJournal?.recordDelete(.membership, id: membership.id) }
        for bookmark in book.bookmarks { syncJournal?.recordDelete(.bookmark, id: bookmark.id) }
        for annotation in book.annotations { syncJournal?.recordDelete(.annotation, id: annotation.id) }
    }

    // MARK: Collections

    public func allCollections() -> [LibraryCollection] {
        (try? context.fetch(FetchDescriptor<LibraryCollection>())) ?? []
    }

    public func collection(withID id: UUID) -> LibraryCollection? {
        allCollections().first { $0.id == id }
    }

    public func rootCollections() -> [LibraryCollection] {
        allCollections()
            .filter { $0.parentID == nil }
            .sorted { lhs, rhs in
                lhs.sortIndex == rhs.sortIndex
                    ? lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                    : lhs.sortIndex < rhs.sortIndex
            }
    }

    public func subcollections(of collection: LibraryCollection?) -> [LibraryCollection] {
        allCollections()
            .filter { $0.parentID == collection?.id }
            .sorted { lhs, rhs in
                lhs.sortIndex == rhs.sortIndex
                    ? lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                    : lhs.sortIndex < rhs.sortIndex
            }
    }

    @discardableResult
    public func createCollection(name: String, parentID: UUID? = nil) -> LibraryCollection? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let siblings = allCollections().filter { $0.parentID == parentID }
        let next = (siblings.map(\.sortIndex).max() ?? -1) + 1
        let collection = LibraryCollection(name: trimmed, parentID: parentID, sortIndex: next)
        context.insert(collection)
        save()
        return collection
    }

    public func renameCollection(_ collection: LibraryCollection, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        collection.name = trimmed
        collection.touch()
        save()
    }

    /// Deletes a collection and its subcollections. Documents are never deleted:
    /// only the membership rows are removed.
    public func deleteCollection(_ collection: LibraryCollection) {
        let ids = Set([collection.id] + descendantIDs(of: collection))
        let memberships = allMemberships().filter { membership in
            membership.collection.map { ids.contains($0.id) } ?? false
        }
        for id in ids { syncJournal?.recordDelete(.collection, id: id) }
        for membership in memberships {
            syncJournal?.recordDelete(.membership, id: membership.id)
            context.delete(membership)
        }
        for item in allCollections() where ids.contains(item.id) {
            context.delete(item)
        }
        save()
    }

    public func moveCollection(_ collection: LibraryCollection, toParent newParentID: UUID?) {
        guard collection.parentID != newParentID else { return }
        if let newParentID {
            guard !descendantIDs(of: collection).contains(newParentID), collection.id != newParentID else { return }
        }
        let siblings = allCollections().filter { $0.parentID == newParentID && $0.id != collection.id }
        collection.parentID = newParentID
        collection.sortIndex = (siblings.map(\.sortIndex).max() ?? -1) + 1
        collection.touch()
        save()
    }

    public func descendantIDs(of collection: LibraryCollection) -> [UUID] {
        let all = allCollections()
        var result: [UUID] = []
        var frontier = [collection.id]
        while let id = frontier.popLast() {
            let children = all.filter { $0.parentID == id }
            for child in children {
                result.append(child.id)
                frontier.append(child.id)
            }
        }
        return result
    }

    public func collectionPath(for collection: LibraryCollection) -> [LibraryCollection] {
        let all = allCollections()
        var path: [LibraryCollection] = [collection]
        var cursor = collection
        while let parentID = cursor.parentID, let parent = all.first(where: { $0.id == parentID }) {
            path.insert(parent, at: 0)
            cursor = parent
            if path.count > 64 { break }
        }
        return path
    }

    public func add(_ book: Book, to collection: LibraryCollection) {
        guard !collection.memberships.contains(where: { $0.book?.id == book.id }) else { return }
        let next = (collection.memberships.map(\.sortIndex).max() ?? -1) + 1
        let membership = CollectionMembership(book: book, collection: collection, sortIndex: next)
        context.insert(membership)
        save()
    }

    public func remove(_ book: Book, from collection: LibraryCollection) {
        let matches = collection.memberships.filter { $0.book?.id == book.id }
        for membership in matches {
            syncJournal?.recordDelete(.membership, id: membership.id)
            context.delete(membership)
        }
        save()
    }

    public func books(in collection: LibraryCollection) -> [Book] {
        collection.memberships
            .sorted { $0.sortIndex < $1.sortIndex }
            .compactMap(\.book)
    }

    public func booksIncludingDescendants(in collection: LibraryCollection) -> [Book] {
        let ids = Set([collection.id] + descendantIDs(of: collection))
        var seen = Set<UUID>()
        var books: [Book] = []
        for item in allCollections() where ids.contains(item.id) {
            for membership in item.memberships.sorted(by: { $0.sortIndex < $1.sortIndex }) {
                if let book = membership.book, seen.insert(book.id).inserted {
                    books.append(book)
                }
            }
        }
        return books
    }

    public func bookCount(in collection: LibraryCollection, includingDescendants: Bool = true) -> Int {
        if includingDescendants {
            return booksIncludingDescendants(in: collection).count
        }
        return books(in: collection).count
    }

    public func otherCollectionNames(for book: Book, excluding collection: LibraryCollection) -> [String] {
        book.memberships
            .compactMap(\.collection)
            .filter { $0.id != collection.id }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .map(\.name)
    }

    public func moveBooks(in collection: LibraryCollection, fromOffsets: IndexSet, toOffset: Int) {
        var memberships = collection.memberships.sorted { $0.sortIndex < $1.sortIndex }
        memberships.move(fromOffsets: fromOffsets, toOffset: toOffset)
        for (index, membership) in memberships.enumerated() {
            membership.sortIndex = index
            membership.updatedAt = Date()
        }
        save()
    }

    private func allMemberships() -> [CollectionMembership] {
        (try? context.fetch(FetchDescriptor<CollectionMembership>())) ?? []
    }

    // MARK: Storage

    public var localLibraryBytes: Int64 {
        fileStore.librarySize()
    }

    public var localCoversBytes: Int64 {
        fileStore.coversSize()
    }

    public var downloadedBookCount: Int {
        allBooks().filter { $0.downloadState == .downloaded }.count
    }

    // MARK: Save

    public func save() {
        do {
            try context.save()
            publishSharedCollectionsIfNeeded()
        } catch {
            assertionFailure("SwiftData save failed: \(error)")
        }
    }

    /// Keeps the Share Extension's collection picker in sync without opening the
    /// SwiftData store from a second process.
    private func publishSharedCollectionsIfNeeded() {
        let flat = flattenedCollections()
        let fingerprint = flat.map { "\($0.collection.id.uuidString)|\($0.depth)|\($0.collection.name)" }
            .joined(separator: "\n")
        guard fingerprint != publishedCollectionsFingerprint else { return }
        publishedCollectionsFingerprint = fingerprint
        SharedImportInbox.publishCollections(flat.map {
            SharedCollection(id: $0.collection.id, name: $0.collection.name, depth: $0.depth)
        })
    }
}
