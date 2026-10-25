// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import SwiftData

// MARK: - Enumerations

public enum BookFormat: String, Codable, CaseIterable, Identifiable, Sendable {
    case epub
    case pdf
    case txt
    case markdown
    case html
    case rtf

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .epub: "EPUB"
        case .pdf: "PDF"
        case .txt: "TXT"
        case .markdown: "Markdown"
        case .html: "HTML"
        case .rtf: "RTF"
        }
    }

    public var badge: String {
        switch self {
        case .epub: "EPUB"
        case .pdf: "PDF"
        case .txt: "TXT"
        case .markdown: "MD"
        case .html: "HTML"
        case .rtf: "RTF"
        }
    }

    public var systemImage: String {
        switch self {
        case .epub: "book.closed"
        case .pdf: "doc.richtext"
        case .txt, .markdown: "doc.plaintext"
        case .html: "globe"
        case .rtf: "doc.text"
        }
    }

    public init?(fileExtension: String) {
        switch fileExtension.lowercased() {
        case "epub": self = .epub
        case "pdf": self = .pdf
        case "txt", "text": self = .txt
        case "md", "markdown", "mdown": self = .markdown
        case "html", "htm", "xhtml": self = .html
        case "rtf": self = .rtf
        default: return nil
        }
    }
}

public enum ReadingStatus: String, Codable, CaseIterable, Identifiable, Sendable {
    case toRead
    case inProgress
    case finished

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .toRead: "To read"
        case .inProgress: "In progress"
        case .finished: "Finished"
        }
    }
}

public enum DownloadState: String, Codable, Sendable {
    case downloaded
    case cloudOnly
    case downloading
}

public enum ReadingMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case read
    case listen
    case readAndListen

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .read: "Read"
        case .listen: "Listen"
        case .readAndListen: "Read & Listen"
        }
    }
}

// MARK: - Per-book appearance

/// A book's own reader appearance. Each part is optional so a book can keep
/// its own typography and still follow the global theme, or the reverse.
public struct BookAppearance: Codable, Equatable, Sendable {
    /// Same format as `ThemeManager.readerThemeSelection`, including
    /// `custom:<uuid>`; nil follows the global reader theme.
    public var readerThemeSelection: String?
    public var typography: ReaderTypography?

    public init(readerThemeSelection: String? = nil, typography: ReaderTypography? = nil) {
        self.readerThemeSelection = readerThemeSelection
        self.typography = typography
    }
}

// MARK: - Locator

/// A small, format-independent reading locator. Paginated text stores a chapter
/// and page fraction; PDFs also store a page index. EPUB CFI is future work.
public struct ReadingLocator: Codable, Equatable, Sendable {
    public var chapterIndex: Int
    public var scrollFraction: Double
    public var pageIndex: Int?

    public init(chapterIndex: Int = 0, scrollFraction: Double = 0, pageIndex: Int? = nil) {
        self.chapterIndex = chapterIndex
        self.scrollFraction = scrollFraction
        self.pageIndex = pageIndex
    }
}

// MARK: - Book

@Model
public final class Book {
    @Attribute(.unique) public var id: UUID = UUID()
    public var title: String = ""
    public var author: String = ""
    public var formatRaw: String = BookFormat.epub.rawValue
    public var language: String = ""
    public var published: String = ""
    public var bookDescription: String = ""
    public var fileName: String = ""
    public var relativePath: String = ""
    public var fileSize: Int64 = 0
    public var contentHash: String = ""
    public var addedAt: Date = Date()
    public var lastOpenedAt: Date?
    public var progress: Double = 0
    public var locatorJSON: String = ""
    public var statusRaw: String = ReadingStatus.toRead.rawValue
    public var isFavorite: Bool = false
    public var coverFileName: String?
    public var searchText: String = ""
    public var tocJSON: String = ""
    public var downloadStateRaw: String = DownloadState.downloaded.rawValue
    public var sourceDevice: String = ""
    public var lastPositionDevice: String = ""
    public var lastPositionDate: Date?
    public var preferredVoiceID: String?
    public var readingModeRaw: String = ReadingMode.read.rawValue
    /// JSON `BookAppearance`; empty when the book uses the global appearance.
    public var appearanceJSON: String = ""
    public var createdAt: Date = Date()
    public var updatedAt: Date = Date()

    @Relationship(deleteRule: .cascade, inverse: \CollectionMembership.book)
    public var memberships: [CollectionMembership] = []

    @Relationship(deleteRule: .cascade, inverse: \Bookmark.book)
    public var bookmarks: [Bookmark] = []

    @Relationship(deleteRule: .cascade, inverse: \Annotation.book)
    public var annotations: [Annotation] = []

    public init(id: UUID = UUID(),
                title: String,
                author: String,
                format: BookFormat,
                language: String = "",
                published: String = "",
                bookDescription: String = "",
                fileName: String,
                relativePath: String,
                fileSize: Int64,
                contentHash: String,
                searchText: String = "",
                tocJSON: String = "",
                sourceDevice: String = "") {
        self.id = id
        self.title = title
        self.author = author
        self.formatRaw = format.rawValue
        self.language = language
        self.published = published
        self.bookDescription = bookDescription
        self.fileName = fileName
        self.relativePath = relativePath
        self.fileSize = fileSize
        self.contentHash = contentHash
        self.searchText = searchText
        self.tocJSON = tocJSON
        self.sourceDevice = sourceDevice
        self.addedAt = Date()
        self.createdAt = Date()
        self.updatedAt = Date()
    }

    public var format: BookFormat {
        get { BookFormat(rawValue: formatRaw) ?? .txt }
        set { formatRaw = newValue.rawValue }
    }

    public var status: ReadingStatus {
        get { ReadingStatus(rawValue: statusRaw) ?? .toRead }
        set { statusRaw = newValue.rawValue }
    }

    public var downloadState: DownloadState {
        get { DownloadState(rawValue: downloadStateRaw) ?? .downloaded }
        set { downloadStateRaw = newValue.rawValue }
    }

    public var readingMode: ReadingMode {
        get { ReadingMode(rawValue: readingModeRaw) ?? .read }
        set { readingModeRaw = newValue.rawValue }
    }

    public var displayAuthor: String {
        author.isEmpty ? "Unknown author" : author
    }

    public var languageDisplayName: String {
        LanguageDetector.displayName(for: language)
    }

    public var languagePrefix: String {
        String(language.prefix(2)).lowercased()
    }

    /// Non-optional sort key for the macOS table.
    public var lastOpenedSort: Date {
        lastOpenedAt ?? .distantPast
    }

    public var locator: ReadingLocator {
        get {
            guard let data = locatorJSON.data(using: .utf8),
                  let value = try? JSONDecoder().decode(ReadingLocator.self, from: data) else {
                return ReadingLocator()
            }
            return value
        }
        set {
            if let data = try? JSONEncoder().encode(newValue), let string = String(data: data, encoding: .utf8) {
                locatorJSON = string
            }
        }
    }

    /// This book's own theme and typography, if the reader chose "This book
    /// only". Synced with the book; nil means the global appearance applies.
    public var appearance: BookAppearance? {
        get {
            guard !appearanceJSON.isEmpty, let data = appearanceJSON.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(BookAppearance.self, from: data)
        }
        set {
            guard let newValue, let data = try? JSONEncoder().encode(newValue),
                  let string = String(data: data, encoding: .utf8) else {
                appearanceJSON = ""
                return
            }
            appearanceJSON = string
        }
    }

    public var chapterTitles: [String] {
        guard let data = tocJSON.data(using: .utf8),
              let titles = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return titles
    }

    public func setChapterTitles(_ titles: [String]) {
        if let data = try? JSONEncoder().encode(titles), let string = String(data: data, encoding: .utf8) {
            tocJSON = string
        }
    }

    public var collectionNames: [String] {
        memberships
            .compactMap(\.collection)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .map(\.name)
    }

    public func touch() {
        updatedAt = Date()
    }
}

// MARK: - Collections

/// Hierarchical collection. Depth is not limited: `parentID` points at another
/// collection and the UI walks the tree recursively.
@Model
public final class LibraryCollection {
    @Attribute(.unique) public var id: UUID = UUID()
    public var name: String = ""
    public var parentID: UUID?
    public var sortIndex: Int = 0
    public var createdAt: Date = Date()
    public var updatedAt: Date = Date()

    @Relationship(deleteRule: .cascade, inverse: \CollectionMembership.collection)
    public var memberships: [CollectionMembership] = []

    public init(id: UUID = UUID(), name: String, parentID: UUID? = nil, sortIndex: Int = 0) {
        self.id = id
        self.name = name
        self.parentID = parentID
        self.sortIndex = sortIndex
        self.createdAt = Date()
        self.updatedAt = Date()
    }

    public func touch() {
        updatedAt = Date()
    }
}

/// Explicit join object. A document can belong to many collections without
/// being duplicated, and each membership carries its own manual order.
@Model
public final class CollectionMembership {
    @Attribute(.unique) public var id: UUID = UUID()
    public var book: Book?
    public var collection: LibraryCollection?
    public var sortIndex: Int = 0
    public var addedAt: Date = Date()
    public var updatedAt: Date = Date()

    public init(id: UUID = UUID(), book: Book, collection: LibraryCollection, sortIndex: Int = 0) {
        self.id = id
        self.book = book
        self.collection = collection
        self.sortIndex = sortIndex
        self.addedAt = Date()
        self.updatedAt = Date()
    }
}

// MARK: - Smart lists

public enum SmartList: String, CaseIterable, Identifiable, Hashable, Sendable {
    case home
    case allBooks
    case favorites
    case toRead
    case finished
    case inbox

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .home: "Home"
        case .allBooks: "All Books"
        case .favorites: "Favorites"
        case .toRead: "To Read"
        case .finished: "Finished"
        case .inbox: "Inbox"
        }
    }

    public var systemImage: String {
        switch self {
        case .home: "house"
        case .allBooks: "books.vertical"
        case .favorites: "star"
        case .toRead: "bookmark"
        case .finished: "checkmark.circle"
        case .inbox: "tray"
        }
    }
}

public struct LibraryFilter: Sendable, Equatable {
    public enum Kind: String, CaseIterable, Identifiable, Sendable {
        case all, inProgress, toRead, finished, favorites, epub, pdf

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .all: "All"
            case .inProgress: "In progress"
            case .toRead: "To read"
            case .finished: "Finished"
            case .favorites: "Favorites"
            case .epub: "EPUB"
            case .pdf: "PDF"
            }
        }
    }

    public static func matches(_ book: Book, kind: Kind) -> Bool {
        switch kind {
        case .all: true
        case .inProgress: book.status == .inProgress
        case .toRead: book.status == .toRead
        case .finished: book.status == .finished
        case .favorites: book.isFavorite
        case .epub: book.format == .epub
        case .pdf: book.format == .pdf
        }
    }
}

public enum LibrarySort: String, CaseIterable, Identifiable, Sendable {
    case recentlyOpened
    case recentlyAdded
    case title
    case author

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .recentlyOpened: "Recently opened"
        case .recentlyAdded: "Recently added"
        case .title: "Title"
        case .author: "Author"
        }
    }
}


// MARK: - Bookmarks and annotations

public enum AnnotationColor: String, Codable, CaseIterable, Identifiable, Sendable {
    case yellow
    case green
    case blue
    case pink
    case purple

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .yellow: "Yellow"
        case .green: "Green"
        case .blue: "Blue"
        case .pink: "Pink"
        case .purple: "Purple"
        }
    }

    /// Fill used behind selected text. Kept as a raw value so the model layer
    /// does not depend on the design system.
    public var fillHex: UInt32 {
        switch self {
        case .yellow: 0xFBEFC0
        case .green: 0xCFE6C2
        case .blue: 0xC7DDF5
        case .pink: 0xF6D0DF
        case .purple: 0xE2D3F2
        }
    }

    public var underlineHex: UInt32 {
        switch self {
        case .yellow: 0xD4A72C
        case .green: 0x6FA35A
        case .blue: 0x4D7EA8
        case .pink: 0xB35D7E
        case .purple: 0x7C3AED
        }
    }
}

@Model
public final class Bookmark {
    @Attribute(.unique) public var id: UUID = UUID()
    public var book: Book?
    public var title: String = ""
    public var chapterTitle: String = ""
    public var locatorJSON: String = ""
    public var createdAt: Date = Date()
    public var updatedAt: Date = Date()

    public init(id: UUID = UUID(), book: Book, title: String, chapterTitle: String = "",
                locator: ReadingLocator = ReadingLocator()) {
        self.id = id
        self.book = book
        self.title = title
        self.chapterTitle = chapterTitle
        self.createdAt = Date()
        self.updatedAt = Date()
        self.locator = locator
    }

    public var locator: ReadingLocator {
        get {
            guard let data = locatorJSON.data(using: .utf8),
                  let value = try? JSONDecoder().decode(ReadingLocator.self, from: data) else {
                return ReadingLocator()
            }
            return value
        }
        set {
            if let data = try? JSONEncoder().encode(newValue), let string = String(data: data, encoding: .utf8) {
                locatorJSON = string
            }
        }
    }

    public func touch() { updatedAt = Date() }
}

@Model
public final class Annotation {
    @Attribute(.unique) public var id: UUID = UUID()
    public var book: Book?
    public var chapterIndex: Int = 0
    public var startOffset: Int = 0
    public var endOffset: Int = 0
    public var quote: String = ""
    public var note: String = ""
    public var colorRaw: String = AnnotationColor.yellow.rawValue
    public var createdAt: Date = Date()
    public var updatedAt: Date = Date()

    public init(id: UUID = UUID(), book: Book, chapterIndex: Int, startOffset: Int, endOffset: Int,
                quote: String, note: String = "", color: AnnotationColor = .yellow) {
        self.id = id
        self.book = book
        self.chapterIndex = chapterIndex
        self.startOffset = startOffset
        self.endOffset = endOffset
        self.quote = quote
        self.note = note
        self.colorRaw = color.rawValue
        self.createdAt = Date()
        self.updatedAt = Date()
    }

    public var color: AnnotationColor {
        get { AnnotationColor(rawValue: colorRaw) ?? .yellow }
        set { colorRaw = newValue.rawValue }
    }

    public var isNote: Bool { !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    public func touch() { updatedAt = Date() }
}

// MARK: - Sync outbox

public enum SyncEntityType: String, Codable, CaseIterable, Sendable {
    case book
    case collection
    case membership
    case bookmark
    case annotation
    case readingPosition
    case theme
    case preference
}

public enum SyncOperationKind: String, Codable, Sendable {
    case upsert
    case delete
}

@Model
public final class SyncOutboxEntry {
    @Attribute(.unique) public var id: UUID = UUID()
    public var entityTypeRaw: String = SyncEntityType.book.rawValue
    public var entityID: UUID = UUID()
    public var operationRaw: String = SyncOperationKind.upsert.rawValue
    public var payloadJSON: String = ""
    public var createdAt: Date = Date()
    public var attempts: Int = 0
    public var nextAttemptAt: Date = Date()
    public var lastError: String = ""

    public init(id: UUID = UUID(), entityType: SyncEntityType, entityID: UUID,
                operation: SyncOperationKind, payloadJSON: String = "") {
        self.id = id
        self.entityTypeRaw = entityType.rawValue
        self.entityID = entityID
        self.operationRaw = operation.rawValue
        self.payloadJSON = payloadJSON
        self.createdAt = Date()
        self.nextAttemptAt = Date()
    }

    public var entityType: SyncEntityType {
        SyncEntityType(rawValue: entityTypeRaw) ?? .book
    }

    public var operation: SyncOperationKind {
        SyncOperationKind(rawValue: operationRaw) ?? .upsert
    }
}

@Model
public final class SyncTombstone {
    @Attribute(.unique) public var id: UUID = UUID()
    public var entityTypeRaw: String = SyncEntityType.book.rawValue
    public var entityID: UUID = UUID()
    public var deletedAt: Date = Date()
    /// False until the tombstone has been accepted by CloudKit. Kept locally so
    /// re-enabling sync does not resurrect and re-delete historical items.
    public var isPushed: Bool = false

    public init(id: UUID = UUID(), entityType: SyncEntityType, entityID: UUID) {
        self.id = id
        self.entityTypeRaw = entityType.rawValue
        self.entityID = entityID
        self.deletedAt = Date()
        self.isPushed = false
    }

    public var entityType: SyncEntityType {
        SyncEntityType(rawValue: entityTypeRaw) ?? .book
    }
}
