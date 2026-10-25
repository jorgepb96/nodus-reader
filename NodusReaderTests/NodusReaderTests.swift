// SPDX-License-Identifier: AGPL-3.0-only
import DesignSystem
import Foundation
import SwiftData
import Testing
@testable import Nodus_Reader

// MARK: - Fixtures

@MainActor
private struct Fixture {
    let container: ModelContainer
    let fileStore: FileStore
    let service: LibraryService
    let root: URL

    init() throws {
        container = try Persistence.makeContainer(inMemory: true)
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NodusReaderTests-\(UUID().uuidString)", isDirectory: true)
        fileStore = FileStore(root: root)
        service = LibraryService(context: container.mainContext, fileStore: fileStore)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor
private func sampleSpec(asPDF: Bool = false) -> SampleLibrary.Spec {
    SampleLibrary.Spec(
        title: "The Test Book",
        author: "Ada Lovelace",
        language: "en",
        description: "A deterministic fixture for Nodus Reader tests.",
        asPDF: asPDF,
        chapters: [
            SampleLibrary.Chapter(title: "First Chapter", paragraphs: [
                "This is the first paragraph of the test document.",
                "A second paragraph follows with a semicolon; and a full stop."
            ]),
            SampleLibrary.Chapter(title: "Second Chapter", paragraphs: [
                "The second chapter contains one more sentence."
            ])
        ]
    )
}

// MARK: - EPUB and import

@Test @MainActor
func epubParserExtractsMetadataAndChapters() throws {
    let url = try SampleLibrary.makeEPUB(sampleSpec())
    defer { try? FileManager.default.removeItem(at: url) }

    let extraction = try EPUBParser.parse(url: url, fallbackTitle: "Fallback")
    #expect(extraction.title == "The Test Book")
    #expect(extraction.author == "Ada Lovelace")
    #expect(extraction.language == "en")
    #expect(extraction.chapters.count == 2)
    #expect(extraction.chapters[0].title == "First Chapter")
    #expect(extraction.chapters[0].text.contains("first paragraph"))
    #expect(!extraction.chapters[0].text.hasPrefix("First Chapter"))
}

@Test @MainActor
func epubTitlePrefixDoesNotEatBodyText() throws {
    var spec = sampleSpec()
    spec.chapters = [
        SampleLibrary.Chapter(title: "I", paragraphs: ["It was a dark and stormy night."])
    ]
    let url = try SampleLibrary.makeEPUB(spec)
    defer { try? FileManager.default.removeItem(at: url) }

    let extraction = try EPUBParser.parse(url: url, fallbackTitle: "Fallback")
    let chapter = try #require(extraction.chapters.first)
    #expect(chapter.title == "I")
    #expect(chapter.text.hasPrefix("It was a dark and stormy night."))
}

@Test @MainActor
func importsEPUBAndRejectsDuplicateContent() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }

    let url = try SampleLibrary.makeEPUB(sampleSpec())
    defer { try? FileManager.default.removeItem(at: url) }

    let first = await fixture.service.importFiles([url]) { _ in }
    #expect(first.imported.count == 1)
    #expect(first.failures.isEmpty)
    let book = try #require(first.imported.first)
    #expect(book.title == "The Test Book")
    #expect(book.author == "Ada Lovelace")
    #expect(book.format == .epub)
    #expect(book.chapterTitles == ["First Chapter", "Second Chapter"])
    #expect(FileManager.default.fileExists(atPath: fixture.fileStore.documentURL(for: book).path))

    let duplicate = await fixture.service.importFiles([url]) { _ in }
    #expect(duplicate.imported.isEmpty)
    #expect(duplicate.duplicates == ["The Test Book"])
    #expect(fixture.service.allBooks().count == 1)
}

@Test @MainActor
func importsPDFWithMetadataAndText() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }

    let url = try SampleLibrary.makePDF(sampleSpec(asPDF: true))
    defer { try? FileManager.default.removeItem(at: url) }

    let result = await fixture.service.importFiles([url]) { _ in }
    #expect(result.imported.count == 1)
    #expect(result.failures.isEmpty)
    let book = try #require(result.imported.first)
    #expect(book.format == .pdf)
    #expect(book.title == "The Test Book")
    #expect(!book.searchText.isEmpty)
}

// MARK: - Collections

@Test @MainActor
func deletingACollectionKeepsItsDocuments() throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }

    let book = Book(
        title: "Standalone",
        author: "Test",
        format: .epub,
        fileName: "standalone.epub",
        relativePath: "Library/standalone.epub",
        fileSize: 100,
        contentHash: UUID().uuidString
    )
    fixture.container.mainContext.insert(book)
    try fixture.container.mainContext.save()

    let history = try #require(fixture.service.createCollection(name: "History"))
    let contemporary = try #require(fixture.service.createCollection(name: "Contemporary History", parentID: history.id))
    let travel = try #require(fixture.service.createCollection(name: "Travel Literature", parentID: history.id))
    fixture.service.add(book, to: contemporary)
    fixture.service.add(book, to: travel)

    #expect(book.memberships.count == 2)
    #expect(fixture.service.books(in: history).isEmpty)
    #expect(fixture.service.booksIncludingDescendants(in: history).count == 1)
    #expect(fixture.service.bookCount(in: history) == 1)
    #expect(fixture.service.collectionPath(for: travel).map(\.name) == ["History", "Travel Literature"])

    fixture.service.deleteCollection(history)
    #expect(fixture.service.allCollections().isEmpty)
    #expect(fixture.service.allBooks().count == 1)
    #expect(book.memberships.isEmpty)
}

@Test @MainActor
func manualOrderUpdatesMembershipSortIndices() throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }

    let collection = try #require(fixture.service.createCollection(name: "Essays"))
    for index in 0..<3 {
        let book = Book(
            title: "Book \(index)",
            author: "Author",
            format: .txt,
            fileName: "book\(index).txt",
            relativePath: "Library/book\(index).txt",
            fileSize: 10,
            contentHash: UUID().uuidString
        )
        fixture.container.mainContext.insert(book)
        fixture.service.add(book, to: collection)
    }
    try fixture.container.mainContext.save()

    #expect(fixture.service.books(in: collection).map(\.title) == ["Book 0", "Book 1", "Book 2"])
    fixture.service.moveBooks(in: collection, fromOffsets: IndexSet(integer: 2), toOffset: 0)
    #expect(fixture.service.books(in: collection).map(\.title) == ["Book 2", "Book 0", "Book 1"])
}

// MARK: - Themes

@Test @MainActor
func themeManagerPersistsBuiltInAndCustomThemes() throws {
    let suite = "nodus.tests.theme.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    let manager = ThemeManager(defaults: defaults)
    manager.appTheme = .sepia
    manager.selectReaderTheme(.oled)

    let restored = ThemeManager(defaults: defaults)
    #expect(restored.appTheme == .sepia)
    #expect(restored.selectedReaderThemeID == .oled)

    let custom = restored.addCustomTheme(name: "Night Ink", backgroundHex: 0x101018,
                                         textHex: 0xEFEAF2, accentHex: 0xC4B5FD, isDark: true)
    let themed = restored.readerTheme(colorScheme: .light)
    #expect(themed.name == "Night Ink")
    #expect(restored.selectedCustomTheme?.id == custom.id)

    let persisted = ThemeManager(defaults: defaults)
    #expect(persisted.customThemes.count == 1)
    #expect(persisted.readerTheme(colorScheme: .light).name == "Night Ink")
}

@Test @MainActor
func readerThemeFollowsTheAppByDefault() throws {
    let suite = "nodus.tests.theme.follow.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    let manager = ThemeManager(defaults: defaults)
    #expect(manager.readerFollowsApp)
    manager.appTheme = .oled
    #expect(manager.readerTheme(colorScheme: .light).isDark)
    #expect(manager.readerTheme(colorScheme: .light).name == "OLED Black")

    manager.selectReaderTheme(.light)
    #expect(!manager.readerFollowsApp)
    #expect(!manager.readerTheme(colorScheme: .dark).isDark)
}

// MARK: - Narration alignment

@Test
func wordAlignmentMatchesTextRangesAndMonotonicTimes() throws {
    let text = "One two three four."
    let sampleRate = 1_000.0
    var samples = [Float](repeating: 0, count: 1_300)
    for range in [100..<300, 350..<600, 650..<900, 950..<1_200] {
        for index in range { samples[index] = 0.5 }
    }

    let timings = AudioWordAligner.align(text: text, samples: samples, sampleRate: sampleRate)
    #expect(timings.count == 4)
    #expect(timings.map(\.location) == [0, 4, 8, 14])
    #expect(timings[0].start == 0)
    #expect(abs(timings[3].end - 1.3) < 0.001)
    for index in 1..<timings.count {
        #expect(timings[index].start >= timings[index - 1].start)
    }
    #expect(timings.allSatisfy { $0.end > $0.start })
}

@Test
func wordAlignmentHandlesOneWordAndSilence() {
    let one = AudioWordAligner.align(text: "Hello", samples: [0.2, 0.3, 0.1], sampleRate: 100)
    #expect(one.count == 1)
    #expect(one[0].end > 0)

    let silent = AudioWordAligner.align(text: "No signal here", samples: [0, 0, 0], sampleRate: 100)
    #expect(silent.count == 3)
    #expect(silent.allSatisfy { $0.end > $0.start })
}

// MARK: - Sync journal

@Test @MainActor
func syncJournalBuildsDurableOutboxAndTombstones() throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    let journal = SyncJournal(context: fixture.container.mainContext)
    fixture.service.syncJournal = journal

    let book = Book(
        title: "Synced", author: "Test", format: .txt,
        fileName: "synced.txt", relativePath: "Library/synced.txt",
        fileSize: 12, contentHash: UUID().uuidString
    )
    fixture.container.mainContext.insert(book)
    try fixture.container.mainContext.save()

    journal.enqueueAll()
    let entries = try fixture.container.mainContext.fetch(FetchDescriptor<SyncOutboxEntry>())
    #expect(entries.count == 1)
    #expect(entries.first?.entityType == .book)
    #expect(entries.first?.operation == .upsert)

    journal.recordDelete(.book, id: book.id)
    let tombstones = try fixture.container.mainContext.fetch(FetchDescriptor<SyncTombstone>())
    #expect(tombstones.count == 1)
    #expect(tombstones.first?.entityID == book.id)
    let afterDelete = try fixture.container.mainContext.fetch(FetchDescriptor<SyncOutboxEntry>())
    #expect(afterDelete.count == 1)
    #expect(afterDelete.first?.operation == .delete)

    // Deleting the same entity twice must not duplicate tombstones or outbox rows.
    journal.recordDelete(.book, id: book.id)
    #expect(try fixture.container.mainContext.fetchCount(FetchDescriptor<SyncTombstone>()) == 1)
    #expect(journal.pendingCount() == 1)
}

@Test @MainActor
func voiceCatalogPrefersTheBookLanguage() async throws {
    let suite = "nodus.tests.voices.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    let catalog = VoiceCatalog(defaults: defaults)
    await catalog.loadIfNeeded()

    let spanish = catalog.narrationVoice(preferredID: nil, language: "es")
    #expect(spanish?.language.lowercased().hasPrefix("es") == true,
            "A Spanish book should resolve a Spanish voice instead of the global default")
    #expect(!catalog.voices(matchingLanguage: "es").isEmpty)

    let missingPreferred = catalog.narrationVoice(preferredID: "not.installed.voice", language: "es")
    #expect(missingPreferred?.language.lowercased().hasPrefix("es") == true)
}

// MARK: - Defensive paths

@Test
func fileStoreRejectsEscapedPathsAndUsesCanonicalBookFolders() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("NodusPathTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = FileStore(root: root)
    let outside = root.appendingPathComponent("Outside.txt")
    try Data("sentinel".utf8).write(to: outside)

    let book = Book(
        title: "Unsafe", author: "Test", format: .txt,
        fileName: "../Outside.txt",
        relativePath: "../../Outside.txt",
        fileSize: 1, contentHash: "hash"
    )
    #expect(store.documentURL(for: book).path.hasPrefix(store.libraryDirectory.path))
    #expect(!store.documentURL(for: book).path.contains(".."))
    #expect(store.coverURL(for: "../../Outside.jpg")?.deletingLastPathComponent().path
        == store.coversDirectory.path)

    store.removeBookFiles(book)
    #expect(FileManager.default.fileExists(atPath: outside.path))
}

@Test
func pageHighlightsClipAtPageBoundaries() {
    let page1 = ReaderPage(
        id: 0, chapterIndex: 0, chapterTitle: "One", chapterLength: 100,
        prefixLength: 0, fullRange: NSRange(location: 0, length: 60),
        attributed: NSAttributedString(string: String(repeating: "a", count: 60)),
        pageIndexInChapter: 0, pagesInChapter: 2
    )
    let page2 = ReaderPage(
        id: 1, chapterIndex: 0, chapterTitle: "One", chapterLength: 100,
        prefixLength: 0, fullRange: NSRange(location: 60, length: 40),
        attributed: NSAttributedString(string: String(repeating: "b", count: 40)),
        pageIndexInChapter: 1, pagesInChapter: 2
    )
    let crossing = NSRange(location: 50, length: 20)
    #expect(page1.localRange(forChapterRange: crossing) == NSRange(location: 50, length: 10))
    #expect(page2.localRange(forChapterRange: crossing) == NSRange(location: 0, length: 10))
}

@Test @MainActor
func syncJournalSuspensionIgnoresProgrammaticRemoteSaves() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    let journal = SyncJournal(context: fixture.container.mainContext)

    journal.withSuspendedRecording {
        let book = Book(
            title: "Remote", author: "Test", format: .txt,
            fileName: "remote.txt", relativePath: "Library/remote.txt",
            fileSize: 4, contentHash: UUID().uuidString
        )
        fixture.container.mainContext.insert(book)
        try? fixture.container.mainContext.save()
    }

    // Let any queued NotificationCenter block run before asserting; a regression
    // to `queue: .main` must fail here rather than pass immediately.
    await Task.yield()
    await Task.yield()
    #expect(journal.pendingCount() == 0)
}

@Test @MainActor
func pushedTombstonesAreNotRequeuedOnEverySyncEnable() throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    let journal = SyncJournal(context: fixture.container.mainContext)
    fixture.service.syncJournal = journal

    journal.recordDelete(.book, id: UUID())
    let tombstones = try fixture.container.mainContext.fetch(FetchDescriptor<SyncTombstone>())
    let tombstone = try #require(tombstones.first)
    #expect(!tombstone.isPushed)

    tombstone.isPushed = true
    try fixture.container.mainContext.save()
    let entries = try fixture.container.mainContext.fetch(FetchDescriptor<SyncOutboxEntry>())
    for entry in entries { fixture.container.mainContext.delete(entry) }
    try fixture.container.mainContext.save()

    journal.enqueueAll()
    let requeued = try fixture.container.mainContext.fetch(FetchDescriptor<SyncOutboxEntry>())
    #expect(requeued.isEmpty)
}

// MARK: - Utilities

@Test
func contentHashIsStableAndSensitive() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let first = directory.appendingPathComponent("a.txt")
    let second = directory.appendingPathComponent("b.txt")
    let third = directory.appendingPathComponent("c.txt")
    try Data("same content".utf8).write(to: first)
    try Data("same content".utf8).write(to: second)
    try Data("different content".utf8).write(to: third)

    let firstHash = try ContentHash.sha256(of: first)
    let secondHash = try ContentHash.sha256(of: second)
    let thirdHash = try ContentHash.sha256(of: third)
    #expect(firstHash == secondHash)
    #expect(firstHash != thirdHash)
}

@Test
func htmlTextStripsMarkupAndDecodesEntities() {
    let html = "<html><head><title>A title</title></head><body><h1>Heading</h1><p>Fish &amp; chips<br/>Next line.</p><script>ignored()</script></body></html>"
    let text = HTMLText.plainText(from: html)
    #expect(text.contains("Fish & chips"))
    #expect(text.contains("Next line."))
    #expect(!text.contains("<p>"))
    #expect(!text.contains("ignored"))
    #expect(HTMLText.firstHeading(from: Data(html.utf8)) == "Heading")
}

@Test
func sentenceTokenizerProducesNonEmptySentences() {
    let sentences = SentenceTokenizer.sentences(from: "One. Two! Three? A final one.")
    #expect(sentences.count == 4)
    #expect(sentences.allSatisfy { !$0.isEmpty })
}

@Test
func fileNamesAreSanitized() {
    #expect(FileStore.sanitizedFileName("A/B:C.epub") == "B-C.epub")
    #expect(FileStore.sanitizedFileName("  ") == "Document")
}

@Test
func readingLocatorRoundTripsThroughJSON() throws {
    let locator = ReadingLocator(chapterIndex: 4, scrollFraction: 0.6, pageIndex: 9)
    let data = try JSONEncoder().encode(locator)
    let decoded = try JSONDecoder().decode(ReadingLocator.self, from: data)
    #expect(decoded == locator)
}

// MARK: - Independent audit regressions

@Test @MainActor
func progressWritesAfterDeletionAreIgnored() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }

    let url = try SampleLibrary.makeEPUB(sampleSpec())
    defer { try? FileManager.default.removeItem(at: url) }
    let book = try #require(await fixture.service.importFiles([url]) { _ in }.imported.first)

    // A reader or narration session can still hold the model when the book is
    // deleted (Mac Reading window, remote tombstone). Its late writes must not
    // touch the destroyed model or resurrect the row.
    fixture.service.delete(book)
    fixture.service.updateProgress(book, locator: ReadingLocator(chapterIndex: 1, scrollFraction: 0.5),
                                   progress: 0.5)
    fixture.service.open(book)
    fixture.service.setReadingMode(book, mode: .listen)
    #expect(fixture.service.allBooks().isEmpty)
}

@Test @MainActor
func concurrentImportRequestsAreQueuedInsteadOfDropped() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    let coordinator = ImportCoordinator(library: fixture.service)

    var second = sampleSpec()
    second.title = "Second Book"
    let firstURL = try SampleLibrary.makeEPUB(sampleSpec())
    let secondURL = try SampleLibrary.makeEPUB(second)
    defer {
        try? FileManager.default.removeItem(at: firstURL)
        try? FileManager.default.removeItem(at: secondURL)
    }

    async let a: Void = coordinator.importFiles([firstURL])
    async let b: Void = coordinator.importFiles([secondURL])
    _ = await (a, b)

    #expect(fixture.service.allBooks().count == 2)
    #expect(!coordinator.isImporting)
}

@Test @MainActor
func importingAFolderImportsSupportedFilesRecursively() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    let coordinator = ImportCoordinator(library: fixture.service)

    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("NodusFolderImport-\(UUID().uuidString)", isDirectory: true)
    let nested = folder.appendingPathComponent("Nested/Deeper", isDirectory: true)
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }

    let epub = try SampleLibrary.makeEPUB(sampleSpec())
    try FileManager.default.moveItem(at: epub, to: folder.appendingPathComponent("book.epub"))
    try "A plain text note.\n\nWith two paragraphs.".write(
        to: nested.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)
    try Data([0xFF, 0xD8, 0xFF]).write(to: nested.appendingPathComponent("photo.jpg"))
    try "hidden".write(to: folder.appendingPathComponent(".hidden.txt"), atomically: true, encoding: .utf8)

    await coordinator.importFiles([folder])

    #expect(fixture.service.allBooks().count == 2)
    #expect(coordinator.lastResult?.failures.isEmpty == true)
}

@Test @MainActor
func outboxEntryReenqueuedDuringPushIsKept() throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    let context = fixture.container.mainContext
    let journal = SyncJournal(context: context)
    fixture.service.syncJournal = journal

    let book = Book(title: "In flight", author: "Test", format: .txt,
                    fileName: "flight.txt", relativePath: "Library/flight.txt",
                    fileSize: 4, contentHash: UUID().uuidString)
    context.insert(book)
    try context.save()
    journal.enqueueAll()
    let entry = try #require(try context.fetch(FetchDescriptor<SyncOutboxEntry>()).first)
    let enqueuedAt = entry.createdAt

    // The user edits the book while its upsert is on the network.
    fixture.service.setFavorite(book, isFavorite: true)
    journal.completePush(entry, enqueuedAt: enqueuedAt, operation: .upsert)
    try context.save()
    #expect(journal.pendingCount() == 1, "The newer edit must still be pushed")

    // A delete recorded during the push must not be dropped either.
    let current = try #require(try context.fetch(FetchDescriptor<SyncOutboxEntry>()).first)
    let snapshot = current.createdAt
    journal.recordDelete(.book, id: book.id)
    journal.completePush(current, enqueuedAt: snapshot, operation: .upsert)
    try context.save()
    #expect(journal.pendingCount() == 1)
    #expect(try context.fetch(FetchDescriptor<SyncOutboxEntry>()).first?.operation == .delete)

    // An untouched entry is removed after a successful push.
    let pending = try #require(try context.fetch(FetchDescriptor<SyncOutboxEntry>()).first)
    journal.completePush(pending, enqueuedAt: pending.createdAt, operation: .delete)
    try context.save()
    #expect(journal.pendingCount() == 0)
}

@Test @MainActor
func syncedBooksRebuildSearchTextAndChaptersOnceLocal() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }

    let url = try SampleLibrary.makeEPUB(sampleSpec())
    defer { try? FileManager.default.removeItem(at: url) }
    let book = try #require(await fixture.service.importFiles([url]) { _ in }.imported.first)

    // CloudKit records carry neither field, so a book created from a pull has
    // them empty until its document is downloaded.
    book.searchText = ""
    book.tocJSON = ""
    let updatedAt = book.updatedAt
    await fixture.service.refreshExtractedTextIfNeeded(book)

    #expect(book.chapterTitles == ["First Chapter", "Second Chapter"])
    #expect(book.searchText.contains("first paragraph"))
    #expect(book.updatedAt == updatedAt, "Derived text is not a user edit")
    #expect(fixture.service.search("semicolon", among: fixture.service.allBooks()).count == 1)
}

@Test @MainActor
func syncJournalRecordsInsertsAndEditsFromSaves() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    let context = fixture.container.mainContext
    let journal = SyncJournal(context: context)
    fixture.service.syncJournal = journal

    // Ordinary saves (an import, a new collection, a bookmark) must reach the
    // outbox without a manual enqueueAll; otherwise nothing after the first
    // sync enable is ever pushed to iCloud.
    let book = Book(title: "Recorded", author: "Test", format: .txt,
                    fileName: "recorded.txt", relativePath: "Library/recorded.txt",
                    fileSize: 4, contentHash: UUID().uuidString)
    context.insert(book)
    try context.save()
    #expect(journal.pendingCount() == 1)

    let collection = try #require(fixture.service.createCollection(name: "Recorded"))
    fixture.service.add(book, to: collection)
    fixture.service.addBookmark(book, title: "Page 1", chapterTitle: "",
                                locator: ReadingLocator())
    let entries = try context.fetch(FetchDescriptor<SyncOutboxEntry>())
    #expect(Set(entries.map(\.entityType)) == [.book, .collection, .membership, .bookmark])
    #expect(entries.allSatisfy { $0.operation == .upsert })
}

// MARK: - Second independent pass

@Test @MainActor
func syncedPreferencesRoundTripBetweenDevices() throws {
    let suiteA = "nodus.tests.prefsA.\(UUID().uuidString)"
    let suiteB = "nodus.tests.prefsB.\(UUID().uuidString)"
    let defaultsA = try #require(UserDefaults(suiteName: suiteA))
    let defaultsB = try #require(UserDefaults(suiteName: suiteB))
    defer {
        defaultsA.removePersistentDomain(forName: suiteA)
        defaultsB.removePersistentDomain(forName: suiteB)
    }

    let themeA = ThemeManager(defaults: defaultsA)
    let readingA = ReaderPreferences(defaults: defaultsA)
    themeA.appTheme = .sepia
    themeA.addCustomTheme(name: "Night paper", backgroundHex: 0x101010, textHex: 0xEEEEEE,
                          accentHex: 0x7C3AED, isDark: true)
    readingA.fontScale = 1.3
    readingA.pageTurn = .vertical

    let payload = SyncedPreferences(theme: themeA, reading: readingA).encoded
    let decoded = try #require(SyncedPreferences.decode(payload))

    let themeB = ThemeManager(defaults: defaultsB)
    let readingB = ReaderPreferences(defaults: defaultsB)
    decoded.apply(theme: themeB, reading: readingB)

    #expect(SyncedPreferences(theme: themeB, reading: readingB).encoded == payload)
    #expect(themeB.customThemes.map(\.name) == ["Night paper"])
    #expect(readingB.pageTurn == .vertical)
    // Persisted on the receiving device, not only in memory.
    #expect(ReaderPreferences(defaults: defaultsB).fontScale == 1.3)
}

@Test @MainActor
func importingACloudOnlyBookAttachesTheLocalCopy() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }

    let url = try SampleLibrary.makeEPUB(sampleSpec())
    defer { try? FileManager.default.removeItem(at: url) }
    let book = try #require(await fixture.service.importFiles([url]) { _ in }.imported.first)

    // Simulate a book that arrived from iCloud without its document.
    try fixture.fileStore.removeDocument(book)
    book.downloadState = .cloudOnly
    fixture.service.save()

    let result = await fixture.service.importFiles([url]) { _ in }
    #expect(result.duplicates.isEmpty)
    #expect(result.imported.first?.id == book.id)
    #expect(fixture.service.allBooks().count == 1)
    #expect(book.downloadState == .downloaded)
    #expect(FileManager.default.fileExists(atPath: fixture.fileStore.documentURL(for: book).path))
}

@Test @MainActor
func backgroundSearchMatchesTheSameBooksAsSearch() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    let url = try SampleLibrary.makeEPUB(sampleSpec())
    defer { try? FileManager.default.removeItem(at: url) }
    _ = await fixture.service.importFiles([url]) { _ in }
    let books = fixture.service.allBooks()

    #expect(await fixture.service.matchingBookIDs("  ", among: books) == nil)
    for query in ["semicolon", "lovelace", "nothing-like-this"] {
        let expected = Set(fixture.service.search(query, among: books).map(\.id))
        #expect(await fixture.service.matchingBookIDs(query, among: books) == expected)
    }
}

@Test @MainActor
func paginationRunsOffTheMainThread() async throws {
    let style = ReaderPageStyle(theme: ReaderTheme.resolve(.light, colorScheme: .light),
                                preferences: ReaderPreferences(defaults: UserDefaults(suiteName: "nodus.tests.pages.\(UUID().uuidString)")!))
    let chapters = (0..<3).map {
        ExtractedChapter(id: $0, title: "Chapter \($0 + 1)",
                         text: String(repeating: "A sentence that fills the page. ", count: 400))
    }
    let paginated = await Task.detached {
        #expect(!Thread.isMainThread)
        return TextPaginator.paginate(chapters: chapters, style: style,
                                      pageSize: CGSize(width: 340, height: 600))
    }.value
    #expect(paginated.pages.count > 3)
    #expect(Set(paginated.firstPageByChapter.keys) == [0, 1, 2])
}
