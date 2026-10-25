// SPDX-License-Identifier: AGPL-3.0-only
import DesignSystem
import Foundation
import SwiftData
import Testing
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif
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
func epubWithEncryptedChaptersIsReportedAsDRM() throws {
    let container = """
    <?xml version="1.0"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
    <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>
    """
    let fontsOnly = """
    <encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><EncryptedData xmlns="http://www.w3.org/2001/04/xmlenc#">
    <CipherData><CipherReference URI="OEBPS/Fonts/Body.otf"/></CipherData></EncryptedData></encryption>
    """
    #expect(!EPUBParser.encryptsText(Data(fontsOnly.utf8)))
    let url = try SampleLibrary.makeArchive([
        ("mimetype", "application/epub+zip"),
        ("META-INF/container.xml", container),
        ("META-INF/encryption.xml", fontsOnly.replacingOccurrences(of: "Fonts/Body.otf", with: "Text/c1.xhtml")),
        ("OEBPS/content.opf", "<package/>")
    ])
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(throws: ImportError.drmProtected(url.lastPathComponent)) {
        try EPUBParser.parse(url: url, fallbackTitle: "Protected")
    }
}

@Test @MainActor
func importsEPUBFolderPackage() async throws {
    // Apple Books and some Files providers keep an EPUB as a folder package.
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    let package = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
        .appendingPathComponent("Folder Book.epub", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: package.deletingLastPathComponent()) }
    let files: [(String, String)] = [
        ("mimetype", "application/epub+zip"),
        ("META-INF/container.xml", """
        <?xml version="1.0"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
        <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>
        """),
        ("OEBPS/content.opf", """
        <?xml version="1.0"?><package xmlns="http://www.idpf.org/2007/opf" version="3.0">
        <metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>Folder Book</dc:title><dc:language>en</dc:language></metadata>
        <manifest><item id="c1" href="c1.xhtml" media-type="application/xhtml+xml"/></manifest>
        <spine><itemref idref="c1"/></spine></package>
        """),
        ("OEBPS/c1.xhtml", "<html><body><h1>Opening</h1><p>Death was a tall figure with a scythe and a horse.</p></body></html>")
    ]
    for (path, contents) in files {
        let url = package.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
    }

    let result = await fixture.service.importFiles([package]) { _ in }
    #expect(result.failures.isEmpty)
    let book = try #require(result.imported.first)
    #expect(book.title == "Folder Book")
    #expect(book.format == .epub)
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
    // Each word starts where the voice resumes (20 ms analysis frames), not
    // in the middle of the pause before it.
    for (word, onset) in zip(timings.dropFirst(), [0.35, 0.65, 0.95]) {
        #expect(abs(word.start - onset) <= 0.015)
    }
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
func htmlTextJoinsWrappedLinesAndSkipsMarkers() {
    // Project Gutenberg wraps every source line; inline tags, footnote calls
    // and page numbers must not break sentences for reading or narration.
    let html = """
    <body><h2 id="c1">CHAPTER 1.</h2>
    <p>Call me Ishmael. Some years
    ago, never mind how long<a class="noteref" href="#n1">1</a> precisely,
    having <i>little</i> or no money.</p><p>Second <em>para</em>.</p>
    <span class="pagenum">[Pg 12]</span><p>Third&nbsp;one &amp; done.</p></body>
    """
    let conversion = HTMLText.convert(html)
    #expect(conversion.text == """
    CHAPTER 1.

    Call me Ishmael. Some years ago, never mind how long precisely, having little or no money.

    Second para.

    Third one & done.
    """)
    #expect(conversion.anchors["c1"] == 0)
    #expect(HTMLText.plainText(from: "a < b and <br/>c") == "a < b and\nc")
}

@Test @MainActor
func epubChaptersFollowContentsAnchors() throws {
    let url = try SampleLibrary.makeArchive([
        ("mimetype", "application/epub+zip"),
        ("META-INF/container.xml", """
        <?xml version="1.0"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
        <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>
        """),
        ("OEBPS/content.opf", """
        <?xml version="1.0"?><package xmlns="http://www.idpf.org/2007/opf" version="2.0">
        <metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>Moby Dick</dc:title><dc:language>en</dc:language></metadata>
        <manifest>
          <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
          <item id="p1" href="text/part1.xhtml" media-type="application/xhtml+xml"/>
          <item id="p2" href="text/part2.xhtml" media-type="application/xhtml+xml"/>
        </manifest>
        <spine toc="ncx"><itemref idref="p1"/><itemref idref="p2"/></spine></package>
        """),
        ("OEBPS/toc.ncx", """
        <?xml version="1.0"?><ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1"><navMap>
          <navPoint id="a"><navLabel><text>ETYMOLOGY.</text></navLabel><content src="text/part1.xhtml#etym"/></navPoint>
          <navPoint id="b"><navLabel><text>CHAPTER 1. Loomings.</text></navLabel><content src="text/part1.xhtml#ch1"/></navPoint>
          <navPoint id="c"><navLabel><text>CHAPTER 2. The Carpet-Bag.</text></navLabel><content src="text/part1.xhtml#ch2"/></navPoint>
        </navMap><pageList><pageTarget><navLabel><text>12</text></navLabel><content src="text/part2.xhtml"/></pageTarget></pageList></ncx>
        """),
        ("OEBPS/text/part1.xhtml", """
        <html><head><title>Moby Dick</title></head><body>
        <p>The Project Gutenberg edition of this classic novel.</p>
        <h2 id="etym">ETYMOLOGY.</h2><p>Supplied by a Late Consumptive Usher to a Grammar School.</p>
        <div id="ch1"><h2>CHAPTER 1. Loomings.</h2><p>Call me Ishmael. Some years ago, never mind how long precisely.</p></div>
        <h2 id="ch2">CHAPTER 2. The Carpet-Bag.</h2><p>I stuffed a shirt or two into my old carpet-bag.</p>
        </body></html>
        """),
        ("OEBPS/text/part2.xhtml", """
        <html><head><title>Moby Dick</title></head><body>
        <p>It was a very dubious-looking, nay, a very dark and dismal night.</p></body></html>
        """)
    ])
    defer { try? FileManager.default.removeItem(at: url) }

    let extraction = try EPUBParser.parse(url: url, fallbackTitle: "Fallback")
    #expect(extraction.chapters.map(\.title) == [
        "Moby Dick", "ETYMOLOGY.", "CHAPTER 1. Loomings.", "CHAPTER 2. The Carpet-Bag."
    ])
    #expect(extraction.chapters.map(\.id) == [0, 1, 2, 3])
    #expect(extraction.chapters[2].text == "Call me Ishmael. Some years ago, never mind how long precisely.")
    // The untitled continuation file belongs to chapter 2.
    #expect(extraction.chapters[3].text.hasPrefix("I stuffed a shirt"))
    #expect(extraction.chapters[3].text.hasSuffix("dark and dismal night."))
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

// MARK: - Reader appearance, continuous scroll and PDF notes

@Test @MainActor
func bookAppearanceOverridesTheGlobalOneAndSyncs() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    let suite = "nodus.tests.appearance.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let theme = ThemeManager(defaults: defaults)
    let preferences = ReaderPreferences(defaults: defaults)
    let journal = SyncJournal(context: fixture.container.mainContext)
    fixture.service.syncJournal = journal

    let url = try SampleLibrary.makeEPUB(sampleSpec())
    defer { try? FileManager.default.removeItem(at: url) }
    let book = try #require(await fixture.service.importFiles([url]) { _ in }.imported.first)

    // No override: the global typography and theme apply.
    preferences.fontScale = 1.2
    #expect(ReaderAppearanceResolver.typography(for: book, preferences: preferences).fontScale == 1.2)

    // "This book only" starts from what is shown, then diverges.
    var own = ReaderAppearanceResolver.snapshot(themeManager: theme, preferences: preferences)
    own.typography?.fontScale = 1.5
    own.typography?.flow = .scrollVertical
    own.readerThemeSelection = ReaderThemeID.sepia.rawValue
    fixture.service.setAppearance(own, for: book)

    #expect(ReaderAppearanceResolver.typography(for: book, preferences: preferences).fontScale == 1.5)
    #expect(ReaderAppearanceResolver.typography(for: book, preferences: preferences).flow == .scrollVertical)
    #expect(ReaderAppearanceResolver.themeSelection(for: book, themeManager: theme) == "sepia")
    #expect(preferences.fontScale == 1.2, "A book's own settings never change the global ones")

    // It is a user edit: the book is queued for sync with its appearance.
    let entries = try fixture.container.mainContext.fetch(FetchDescriptor<SyncOutboxEntry>())
    #expect(entries.contains { $0.entityType == .book && $0.entityID == book.id })
    #expect(book.appearanceJSON.contains("scrollVertical"))

    // Back to the general settings.
    fixture.service.setAppearance(nil, for: book)
    #expect(book.appearanceJSON.isEmpty)
    #expect(ReaderAppearanceResolver.typography(for: book, preferences: preferences).fontScale == 1.2)
}

@Test @MainActor
func readerTypographyDecodesOlderPayloadsAndSyncsFlow() throws {
    // A payload written before `flow` existed keeps the defaults for it.
    let legacy = Data(#"{"fontScale":1.4,"justify":false}"#.utf8)
    let decoded = try JSONDecoder().decode(ReaderTypography.self, from: legacy)
    #expect(decoded.fontScale == 1.4)
    #expect(decoded.justify == false)
    #expect(decoded.flow == .paged)

    let suite = "nodus.tests.flow.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let reading = ReaderPreferences(defaults: defaults)
    reading.flow = .scrollHorizontal
    let payload = SyncedPreferences(theme: ThemeManager(defaults: defaults), reading: reading).encoded
    let otherSuite = "nodus.tests.flowB.\(UUID().uuidString)"
    let other = try #require(UserDefaults(suiteName: otherSuite))
    defer { other.removePersistentDomain(forName: otherSuite) }
    let otherReading = ReaderPreferences(defaults: other)
    try #require(SyncedPreferences.decode(payload)).apply(theme: ThemeManager(defaults: other), reading: otherReading)
    #expect(otherReading.flow == .scrollHorizontal)
}

@Test @MainActor
func continuousSlicesCoverEveryChapterWithoutGaps() async throws {
    let style = ReaderPageStyle(
        theme: ReaderTheme.resolve(.light, colorScheme: .light),
        typography: ReaderTypography()
    )
    let chapters = (0..<2).map {
        ExtractedChapter(id: $0, title: "Chapter \($0 + 1)",
                         text: String(repeating: "Words follow words down the column. ", count: 300))
    }
    let paginated = TextPaginator.paginate(chapters: chapters, style: style,
                                           pageSize: CGSize(width: 320, height: 560))
    for chapter in chapters.indices {
        let slices = paginated.pages.filter { $0.chapterIndex == chapter }
        #expect(!slices.isEmpty)
        // Each slice starts where the previous one ended (only a leading
        // newline may be skipped), so stacking them reads continuously.
        for (previous, next) in zip(slices, slices.dropFirst()) {
            #expect(next.fullRange.location - NSMaxRange(previous.fullRange) <= 1)
        }
        let chapterLength = (chapters[chapter].text as NSString).length
        #expect(slices.last.map { $0.chapterEndOffset } == chapterLength)
        // The shared mapping turns slice-local indexes into chapter offsets.
        let mapping = ReaderTextMapping.page(slices[0])
        #expect(mapping.anchorOffset(slices[0].prefixLength) == 0)
    }
}

@Test
func reflowHighlightsAnchorToCanonicalPageText() {
    func block(_ kind: PDFReflowBlock.Kind, _ text: String, header: Bool = false) -> PDFReflowBlock {
        PDFReflowBlock(id: UUID(), kind: kind, text: text, rect: .zero, pageIndex: 4,
                       imageFileName: nil, isHeaderFooter: header, usedOCR: false)
    }
    let header = block(.body, "Journal of Tests · 12", header: true)
    let title = block(.heading1, "Results")
    let figure = block(.figure, "")
    let body = block(.body, "The yield rose sharply after the second trial.")
    let page = PDFReflowPage(pageIndex: 4, width: 600, height: 800,
                             blocks: [header, title, figure, body], regions: [])
    let layout = page.canonicalLayout

    // Headers count even when hidden; figures do not take text space.
    #expect(layout.text == "Journal of Tests · 12\n\nResults\n\nThe yield rose sharply after the second trial.")
    let bodyBase = try! #require(layout.bases[body.id])
    #expect(layout.bases[figure.id] == nil)

    // A selection of "rose sharply" in the body block maps into page space.
    let local = ("The yield rose sharply after the second trial." as NSString).range(of: "rose sharply")
    let mapping = ReaderTextMapping.block(base: bodyBase, length: (body.text as NSString).length)
    let anchored = try! #require(mapping.anchorRange(for: local))
    #expect((layout.text as NSString).substring(with: anchored) == "rose sharply")
    #expect(mapping.localRange(anchored) == local)

    // Stored offsets still valid: used as is.
    #expect(ReflowAnnotationAnchor.resolve(start: anchored.location, end: NSMaxRange(anchored),
                                           quote: "rose sharply", in: layout.text) == anchored)
    // Shifted by a rebuilt cache: found again by its quote.
    let moved = ReflowAnnotationAnchor.resolve(start: 3, end: 15, quote: "rose sharply", in: layout.text)
    #expect(moved == anchored)
    // Gone from the page: not drawn.
    #expect(ReflowAnnotationAnchor.resolve(start: 0, end: 5, quote: "absent words", in: layout.text) == nil)
}

@Test @MainActor
func exportedPDFNotesNamePages() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    let url = try SampleLibrary.makePDF(sampleSpec(asPDF: true))
    defer { try? FileManager.default.removeItem(at: url) }
    let book = try #require(await fixture.service.importFiles([url]) { _ in }.imported.first)
    fixture.service.addAnnotation(book, chapterIndex: 2, startOffset: 0, endOffset: 5,
                                  quote: "First", note: "Check this")
    let export = fixture.service.exportNotes(for: book)
    #expect(export.contains("— Page 3"))
    #expect(!export.contains("— Chapter"))
}

// MARK: - Reader paragraph layout

@Test @MainActor
func readerParagraphsAreIndentedWithoutBlankLines() throws {
    let style = ReaderPageStyle(theme: ThemeManager().readerTheme(colorScheme: .light), typography: ReaderTypography())
    let text = "Resumen\n\nThe first paragraph after a heading.\n\nA second paragraph, indented."
    let body = style.bodyText(text)
    let ns = text as NSString
    // Offsets never move: annotations and narration use the chapter text.
    #expect(body.string == text)

    func paragraphStyle(at index: Int) -> NSParagraphStyle? {
        body.attribute(.paragraphStyle, at: index, effectiveRange: nil) as? NSParagraphStyle
    }
    // The blank line between paragraphs is drawn with no height.
    let blank = ns.range(of: "\n\n").location + 1
    #expect(try #require(paragraphStyle(at: blank)).maximumLineHeight < 0.1)
    // Heading and the paragraph after it start flush; the next one is indented.
    #expect(try #require(paragraphStyle(at: 0)).firstLineHeadIndent == 0)
    #expect(try #require(paragraphStyle(at: ns.range(of: "The first").location)).firstLineHeadIndent == 0)
    #expect(try #require(paragraphStyle(at: ns.range(of: "A second").location)).firstLineHeadIndent > 0)
    #expect(try #require(paragraphStyle(at: ns.range(of: "A second").location)).paragraphSpacing == 0)
}

// MARK: - Hugging Face sign-in

@Test
func huggingFaceOAuthUsesPKCEAndChecksTheCallback() throws {
    // RFC 7636 appendix B test vector.
    let request = HuggingFaceOAuth.Request(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk", state: "s123")
    #expect(request.challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")

    let items = URLComponents(url: request.authorizeURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
    func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
    #expect(request.authorizeURL.host == "huggingface.co")
    #expect(value("client_id") == HuggingFaceOAuth.clientID)
    #expect(value("redirect_uri") == "nodusreader://oauth/huggingface")
    #expect(value("code_challenge_method") == "S256")
    #expect(value("code_challenge") == request.challenge)
    #expect(value("state") == "s123")
    #expect(value("scope") == "openid profile gated-repos")
    #expect(value("client_secret") == nil)

    let good = URL(string: "nodusreader://oauth/huggingface?code=abc&state=s123")!
    #expect(try request.code(from: good) == "abc")
    #expect(throws: HuggingFaceOAuthError.stateMismatch) {
        try request.code(from: URL(string: "nodusreader://oauth/huggingface?code=abc&state=other")!)
    }
    #expect(throws: HuggingFaceOAuthError.denied("access_denied")) {
        try request.code(from: URL(string: "nodusreader://oauth/huggingface?error=access_denied&state=s123")!)
    }

    // The token request carries the verifier and no secret.
    let body = String(data: request.tokenRequest(code: "abc").httpBody ?? Data(), encoding: .utf8) ?? ""
    #expect(body.contains("grant_type=authorization_code"))
    #expect(body.contains("code_verifier=dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"))
    #expect(!body.contains("secret"))
}

@Test
func huggingFaceTokenResponseBecomesARefreshableSession() throws {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let json = Data(#"{"access_token":"hf_oauth_x","refresh_token":"r1","expires_in":3600,"token_type":"bearer"}"#.utf8)
    let session = try HuggingFaceOAuth.session(fromTokenResponse: json, now: now)
    #expect(session.accessToken == "hf_oauth_x")
    #expect(session.refreshToken == "r1")
    #expect(!session.isExpired(now: now))
    #expect(session.isExpired(now: now.addingTimeInterval(3_590)))

    // A refresh response without a new refresh token keeps the old one.
    let refreshed = try HuggingFaceOAuth.session(
        fromTokenResponse: Data(#"{"access_token":"hf_oauth_y","expires_in":3600}"#.utf8),
        previous: HuggingFaceOAuth.Session(accessToken: "hf_oauth_x", refreshToken: "r1", expiresAt: now, account: "ada"),
        now: now
    )
    #expect(refreshed.refreshToken == "r1")
    #expect(refreshed.account == "ada")
    #expect(throws: HuggingFaceOAuthError.invalidResponse) {
        try HuggingFaceOAuth.session(fromTokenResponse: Data("{}".utf8))
    }
}

// MARK: - Voice engine memory

@Test @MainActor
func voiceEnginesAreReleasedOnlyWhenNarrationIsIdle() throws {
    let suite = "nodus.tests.engine-memory.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let manager = ModelManager(voices: VoiceCatalog(defaults: defaults), defaults: defaults)

    // Playing narration keeps its engine in memory.
    manager.setNarrationInUse(true)
    #expect(!manager.releaseEnginesIfIdle())
    // Once it stops, nothing holds the engine; it can be released.
    manager.setNarrationInUse(false)
    #expect(manager.releaseEnginesIfIdle())
    #expect(manager.loadedEngines.isEmpty)
    #expect(ModelManager.idleUnloadDelay <= .seconds(300))
}

// MARK: - Model downloads (opt-in: downloads about 500 MB)

/// End-to-end check of every downloadable engine on this machine: the same
/// install path as Settings › Voices & Models (Hugging Face download, hash
/// checks by the SDKs, Core ML load), then a real synthesis and the word
/// alignment that drives the read-along highlight. Opt in with
/// `TEST_RUNNER_NODUS_MODEL_DOWNLOAD_TESTS=1` (and preferably
/// `TEST_RUNNER_CFFIXED_USER_HOME=<scratch>` so models land outside the real
/// app container).
@Test(.enabled(if: ProcessInfo.processInfo.environment["NODUS_MODEL_DOWNLOAD_TESTS"] == "1"),
      .timeLimit(.minutes(40)))
@MainActor
func modelDownloadsSynthesizeAndAlignWithText() async throws {
    let suite = "nodus.tests.models.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let manager = ModelManager(voices: VoiceCatalog(defaults: defaults), defaults: defaults)

    let sentence = "Call me Ishmael, and listen closely to every single word."
    var words: [NSRange] = []
    (sentence as NSString).enumerateSubstrings(in: NSRange(location: 0, length: (sentence as NSString).length),
                                               options: .byWords) { _, range, _, _ in words.append(range) }

    let downloadable = manager.models.filter(\.isAvailable)
    #expect(!downloadable.isEmpty)
    for model in downloadable {
        if !manager.isInstalled(model) {
            manager.install(model)
            let deadline = Date().addingTimeInterval(30 * 60)
            while Date() < deadline {
                let state = manager.state(for: model)
                if state == .installed { break }
                if case .failed(let message) = state {
                    Issue.record("\(model.name) failed to install: \(message)")
                    break
                }
                try await Task.sleep(for: .seconds(2))
            }
        }
        #expect(manager.isInstalled(model), "\(model.name) should be installed")
        guard manager.isInstalled(model), let voice = model.voices.first else { continue }

        manager.selectModel(model)
        var voiceIDs = [voice.id]
        if model.engine == .kokoro {
            // The full catalogue, not only the starter voice: a British male
            // voice that is not in the hosted starter bundle.
            voiceIDs.append("kokoro:bm_george")
        }
        for voiceID in voiceIDs {
        let audio = try await manager.synthesize(sentence, voiceID: voiceID, engine: model.engine)
        let duration = Double(audio.samples.count) / audio.sampleRate
        #expect(duration > 1.5, "\(model.name) produced \(duration) s of audio")
        #expect(audio.samples.contains { abs($0) > 0.01 }, "\(model.name) produced silence")

        // The read-along highlight: one timing per word, in text order and in
        // time order, covering the generated audio.
        let timings = AudioWordAligner.align(text: sentence, samples: audio.samples, sampleRate: audio.sampleRate)
        #expect(timings.map { NSRange(location: $0.location, length: $0.length) } == words)
        #expect(zip(timings, timings.dropFirst()).allSatisfy { $0.start <= $1.start && $0.end <= $1.end })
        #expect(timings.first.map { $0.start >= 0 } == true)
        #expect(timings.last.map { abs($0.end - duration) < 0.05 } == true)
        }

        // Memory: idle narration releases the engine, and the next sentence
        // loads it again without user action.
        #expect(manager.loadedEngines.contains(model.engine))
        #expect(manager.releaseEnginesIfIdle())
        #expect(manager.loadedEngines.isEmpty)
        let reloaded = try await manager.synthesize(sentence, voiceID: voice.id, engine: model.engine)
        #expect(reloaded.samples.count > 0)
        #expect(manager.loadedEngines == [model.engine])
    }
}

/// A Phonon 40M Spanish bundle converted on a Mac (see docs/MODEL_LICENSES.md):
/// installed through Install from file, selected, and narrating Spanish. Opt in
/// with `TEST_RUNNER_NODUS_PHONON40_ES_BUNDLE=<folder>`.
@Test(.enabled(if: ProcessInfo.processInfo.environment["NODUS_PHONON40_ES_BUNDLE"] != nil),
      .timeLimit(.minutes(10)))
@MainActor
func convertedPhonon40SpanishBundleNarratesSpanish() async throws {
    let folder = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["NODUS_PHONON40_ES_BUNDLE"]))
    let suite = "nodus.tests.phonon40.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let manager = ModelManager(voices: VoiceCatalog(defaults: defaults), defaults: defaults)
    let model = try #require(manager.models.first { $0.id == ModelManager.phonon40SpanishID })
    #expect(!model.downloadable)

    await manager.installFromFolder(folder)
    #expect(manager.errorMessage == nil)
    #expect(manager.isInstalled(model))
    manager.selectModel(model)

    let sentence = "En un lugar de la Mancha, de cuyo nombre no quiero acordarme, vivía un hidalgo."
    let audio = try await manager.synthesize(sentence, voiceID: "phonon:Lucía-Sol", engine: .phonon)
    let duration = Double(audio.samples.count) / audio.sampleRate
    #expect(duration > 2, "produced \(duration) s")
    #expect(audio.samples.contains { abs($0) > 0.01 })
    let timings = AudioWordAligner.align(text: sentence, samples: audio.samples, sampleRate: audio.sampleRate)
    #expect(timings.count == 15)
    #expect(zip(timings, timings.dropFirst()).allSatisfy { $0.start <= $1.start })
    #expect(manager.loadedEngines == [.phonon])
}

@Test
func localStoreNeverUsesSwiftDataCloudKitOrTheAppGroup() {
    // Signed builds carry iCloud and App Group entitlements. With SwiftData's
    // `.automatic` defaults the store would try CloudKit mirroring (this schema
    // is incompatible, so the app could not open its library and crashed at
    // launch) and move into the shared group container.
    let configuration = Persistence.configuration()
    #expect(configuration.cloudKitContainerIdentifier == nil)
    #expect(configuration.groupAppContainerIdentifier == nil)
}
