// SPDX-License-Identifier: AGPL-3.0-only
import AVFoundation
import CoreText
import KokoroTTS
import PDFKit
import DesignSystem
import Foundation
import SwiftData
import PhononTTS
import SwiftUI
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
    // The first word starts with the voice (0.1 s), not in the silence before.
    #expect(abs(timings[0].start - 0.1) < 0.001)
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
    #expect(coordinator.bookToOpen != nil,
            "A successful import should request the reader presentation")
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
    #expect(coordinator.bookToOpen != nil)
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

// MARK: - Voices across models

@Test @MainActor
func voicesOfEveryInstalledModelAreListedAndRoutedToTheirModel() throws {
    let suite = "nodus.tests.voice-routing.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let manager = ModelManager(voices: VoiceCatalog(defaults: defaults), defaults: defaults)

    // Each voice ID names its model, so a voice of an unselected model plays with it.
    #expect(manager.model(forVoiceID: "phonon:Harper")?.model.id == "phonon-31m-en")
    #expect(manager.model(forVoiceID: "phonon-40m-es:Alba")?.model.id == "phonon-40m-es")
    #expect(manager.model(forVoiceID: "phonon-40m-multilingual:Alba")?.model.id == "phonon-40m-multilingual")
    #expect(manager.model(forVoiceID: "phonon-40m-multilingual:Alba")?.name == "Alba")
    #expect(manager.model(forVoiceID: "kokoro:bm_george")?.name == "bm_george")
    // Saved by builds where 40M Spanish voices were "phonon:<name>".
    #expect(manager.model(forVoiceID: "phonon:Lucía-Sol")?.model.id == "phonon-40m-es")
    // The same voice in two checkpoints stays two voices.
    let spanish = try #require(manager.models.first { $0.id == "phonon-40m-es" })
    let multilingual = try #require(manager.models.first { $0.id == "phonon-40m-multilingual" })
    #expect(Set(spanish.voices.map(\.id)).isDisjoint(with: multilingual.voices.map(\.id)))

    // The Voices screen lists every installed model; the reader keeps the selected one.
    let catalog = VoiceCatalog(defaults: defaults)
    func voice(_ id: String, model: String) -> VoiceCatalog.Voice {
        VoiceCatalog.Voice(id: id, name: id, language: "es-ES", languageName: "Spanish", quality: 3,
                           gender: nil, engineRaw: "phonon", modelID: model, modelName: model)
    }
    let selected = voice("phonon-40m-es:Alba", model: "phonon-40m-es")
    let other = voice("phonon-40m-multilingual:Alba", model: "phonon-40m-multilingual")
    catalog.setNeuralVoices([selected], installed: [selected, other])
    #expect(catalog.voices.contains { $0.id == selected.id })
    #expect(!catalog.voices.contains { $0.id == other.id })
    #expect(catalog.allInstalledVoices.contains { $0.id == other.id })
    #expect(catalog.voice(withID: other.id) != nil)
}

// MARK: - Space: compressed narration audio

@Test
func narrationCacheStoresCompressedAudioWithTheSameLength() async throws {
    let cache = NarrationAudioCache(root: FileManager.default.temporaryDirectory
        .appendingPathComponent("nodus-audio-\(UUID().uuidString)", isDirectory: true))
    let book = UUID()
    defer { Task { await cache.deleteBook(bookID: book) } }
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1))
    let frames: AVAudioFrameCount = 24_000 * 10
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
    buffer.frameLength = frames
    let channel = try #require(buffer.floatChannelData?[0])
    for index in 0..<Int(frames) {
        // A voice-like signal: a gliding tone with a syllable envelope.
        let time = Double(index) / 24_000
        channel[index] = Float(0.4 * sin(2 * .pi * (180 + 40 * sin(time)) * time) * abs(sin(.pi * time * 3)))
    }
    let words = [NarrationWordTiming(location: 0, length: 4, start: 0, end: 10)]

    let stored = await cache.save(bookID: book, key: "k", buffer: buffer, words: words)
    let pcmBytes = Int64(frames) * 4
    #expect(stored > 0)
    #expect(stored < pcmBytes / 8, "\(stored) bytes is not compressed (PCM would be \(pcmBytes))")

    let loaded = try #require(await cache.load(bookID: book, key: "k"))
    #expect(loaded.buffer.format.sampleRate == 24_000)
    // Word timings depend on the decoded length matching the original.
    #expect(abs(Int(loaded.buffer.frameLength) - Int(frames)) <= 24, "decoded \(loaded.buffer.frameLength) of \(frames) frames")
    #expect(loaded.words == words)
}

// MARK: - Space: deleting caches, books and models

@Test @MainActor
func deletingCachesBooksAndModelsFreesTheirFiles() async throws {
    // Narration audio: one book's cache goes, another's stays; "delete all" empties it.
    let cache = NarrationAudioCache(root: FileManager.default.temporaryDirectory
        .appendingPathComponent("nodus-audio-\(UUID().uuidString)", isDirectory: true))
    let kept = UUID(), removed = UUID()
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2_400))
    buffer.frameLength = 2_400
    for book in [kept, removed] {
        #expect(await cache.save(bookID: book, key: "k", buffer: buffer, words: []) > 0)
    }
    await cache.deleteBook(bookID: removed)
    #expect(await cache.bytes(for: removed) == 0)
    #expect(await cache.bytes(for: kept) > 0)
    await cache.deleteBook(bookID: kept)
    #expect(await cache.bytes(for: kept) == 0)

    // Deleting a book removes its document, cover and PDF reflow/OCR cache.
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    let url = try SampleLibrary.makeEPUB(sampleSpec())
    defer { try? FileManager.default.removeItem(at: url) }
    let result = await fixture.service.importFiles([url]) { _ in }
    let book = try #require(result.imported.first)
    let reflow = fixture.root.appendingPathComponent("Reflow/\(book.id.uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: reflow, withIntermediateDirectories: true)
    try Data("ocr".utf8).write(to: reflow.appendingPathComponent("manifest.json"))
    let document = fixture.fileStore.documentURL(for: book)
    let cover = fixture.fileStore.coverURL(for: book.coverFileName)
    #expect(FileManager.default.fileExists(atPath: document.path))
    fixture.service.delete(book)
    #expect(!FileManager.default.fileExists(atPath: document.path))
    #expect(!FileManager.default.fileExists(atPath: reflow.path))
    if let cover { #expect(!FileManager.default.fileExists(atPath: cover.path)) }

    // Deleting a model removes only its own folder.
    let suite = "nodus.tests.space.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let manager = ModelManager(voices: VoiceCatalog(defaults: defaults), defaults: defaults)
    let multilingual = try #require(manager.models.first { $0.id == ModelManager.phonon40MultilingualID })
    let folder = ModelManager.directory(forModelID: multilingual.id, engine: .phonon)
    let english = ModelManager.directory(forModelID: "phonon-31m-en", engine: .phonon)
    let englishExisted = FileManager.default.fileExists(atPath: english.path)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data(repeating: 1, count: 1_000).write(to: folder.appendingPathComponent("model.bin"))
    manager.delete(multilingual)
    #expect(!FileManager.default.fileExists(atPath: folder.path))
    #expect(FileManager.default.fileExists(atPath: english.path) == englishExisted)
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
    let catalog = VoiceCatalog(defaults: defaults)
    let manager = ModelManager(voices: catalog, defaults: defaults)

    let sentence = "Call me Ishmael, and listen closely to every single word."
    var words: [NSRange] = []
    (sentence as NSString).enumerateSubstrings(in: NSRange(location: 0, length: (sentence as NSString).length),
                                               options: .byWords) { _, range, _, _ in words.append(range) }

    // Public models only; the gated 40M checkpoints have their own opt-in test.
    let downloadable = manager.models.filter { $0.isAvailable && !$0.requiresAcceptedLicense }
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

    // Any installed model can be tried from the Voices screen, not only the
    // selected one: with one engine selected, a voice of the other still speaks.
    let installed = downloadable.filter { manager.isInstalled($0) }
    if let first = installed.first, let second = installed.dropFirst().first,
       let otherVoice = second.voices.first {
        manager.selectModel(first)
        let audio = try await manager.synthesize(sentence, voiceID: otherVoice.id, engine: second.engine)
        #expect(audio.samples.contains { abs($0) > 0.01 }, "\(second.name) did not speak while \(first.name) was selected")
        #expect(catalog.allInstalledVoices.contains { $0.id == otherVoice.id })
    }
}

/// Kokoro narrating Spanish with its three Spanish voices: the voice files are
/// downloaded and verified into an installed bundle, the text goes through
/// `SpanishG2P`, and the audio aligns with the words for the read-along
/// highlight. With `TEST_RUNNER_NODUS_KOKORO_ES_OUT=<folder>` the audio is also
/// written there as WAV, to be checked with a speech recognizer. Opt in with
/// `TEST_RUNNER_NODUS_MODEL_DOWNLOAD_TESTS=1` and a Kokoro bundle installed under
/// `TEST_RUNNER_CFFIXED_USER_HOME`.
@Test(.enabled(if: ProcessInfo.processInfo.environment["NODUS_MODEL_DOWNLOAD_TESTS"] == "1"),
      .timeLimit(.minutes(20)))
@MainActor
func kokoroNarratesSpanish() async throws {
    let suite = "nodus.tests.kokoro-es.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let catalog = VoiceCatalog(defaults: defaults)
    let manager = ModelManager(voices: catalog, defaults: defaults)
    let kokoro = try #require(manager.models.first { $0.engine == .kokoro })
    try #require(manager.isInstalled(kokoro), "Install Kokoro first (modelDownloadsSynthesizeAndAlignWithText)")
    _ = await ModelManager.installMissingKokoroVoices()
    manager.selectModel(kokoro)

    let spanishVoices = kokoro.voices.filter { $0.language == "es-ES" }
    #expect(spanishVoices.map(\.name) == ["Dora", "Alex", "Santa"])
    let sentences = [
        "En un lugar de la Mancha, de cuyo nombre no quiero acordarme, no ha mucho tiempo que vivía un hidalgo.",
        "La biblioteca abre a las nueve y media; el señor García llegó tarde porque llovía muchísimo.",
        "Cuando era niña, mi abuela me contaba historias sobre el pueblo donde había nacido.",
        "El tren salió de la estación con veinte minutos de retraso y nadie supo explicar por qué.",
        "¿Sabes cuántos libros has leído este año? Yo, sinceramente, he perdido la cuenta."
    ]
    let output = ProcessInfo.processInfo.environment["NODUS_KOKORO_ES_OUT"].map { URL(fileURLWithPath: $0) }
    for voice in spanishVoices {
        for (index, sentence) in sentences.enumerated() {
            let audio = try await manager.synthesize(sentence, voiceID: voice.id, engine: .kokoro)
            let duration = Double(audio.samples.count) / audio.sampleRate
            #expect(duration > 2.5 && duration < 20, "\(voice.name) produced \(duration) s for sentence \(index + 1)")
            #expect(audio.samples.contains { abs($0) > 0.01 }, "\(voice.name) produced silence")
            let timings = AudioWordAligner.align(text: sentence, samples: audio.samples, sampleRate: audio.sampleRate)
            var words = 0
            (sentence as NSString).enumerateSubstrings(in: NSRange(location: 0, length: (sentence as NSString).length),
                                                       options: .byWords) { _, _, _, _ in words += 1 }
            #expect(timings.count == words)
            if let output {
                let format = try #require(AVAudioFormat(standardFormatWithSampleRate: audio.sampleRate, channels: 1))
                let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format,
                                                           frameCapacity: AVAudioFrameCount(audio.samples.count)))
                buffer.frameLength = AVAudioFrameCount(audio.samples.count)
                audio.samples.withUnsafeBufferPointer { source in
                    buffer.floatChannelData![0].update(from: source.baseAddress!, count: audio.samples.count)
                }
                let url = output.appendingPathComponent("kokoro_\(voice.name.lowercased())_\(index + 1).wav")
                let file = try AVAudioFile(forWriting: url, settings: format.settings)
                try file.write(from: buffer)
            }
        }
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

/// The on-device path for the gated Phonon 40M checkpoints: download with a Hugging Face token
/// (read from the file named by `NODUS_HF_TOKEN_FILE`, never printed), verify, convert to Core ML
/// with PhononCore's exporter, then load and speak. Opt in with
/// `TEST_RUNNER_NODUS_HF_TOKEN_FILE=<path>`; downloads about 130 MB per model.
@Test(.enabled(if: ProcessInfo.processInfo.environment["NODUS_HF_TOKEN_FILE"] != nil),
      .timeLimit(.minutes(30)),
      arguments: ["phonon-40m-es", "phonon-40m-multilingual"])
func phonon40ConvertsOnDevice(modelID: String) async throws {
    let spec = try #require(PhononOnDeviceConversion.spec(forModelID: modelID))
    let tokenFile = try #require(ProcessInfo.processInfo.environment["NODUS_HF_TOKEN_FILE"])
    let token = try String(contentsOfFile: tokenFile, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("phonon40-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let destination = root.appendingPathComponent(modelID)
    let work = root.appendingPathComponent("work")

    try await PhononOnDeviceConversion.run(spec, token: token, workDirectory: work, destination: destination) { _ in }

    #expect(!FileManager.default.fileExists(atPath: work.path), "downloaded weights are removed")
    #expect(PhononModels.isInstalled(at: destination))
    let languages = ModelManager.phononBundleLanguages(at: destination)
    let phonon = try await Phonon.load(models: destination, language: .spanish)
    #expect(phonon.voices.count == spec.voices.count)

    // (voice, language, text): every language the bundle speaks gets a sentence.
    var checks: [(String, PhononTTS.Language, String)] = [
        ("Alba", .spanish, "Hola, esto es una prueba de lectura en voz alta.")
    ]
    if spec.voiceLanguages == nil {
        #expect(Set(languages) == ["en", "es", "fr", "de", "pt"])
        let french = try #require(spec.voices.first { $0.language.hasPrefix("fr") })
        let english = try #require(spec.voices.first { $0.language.hasPrefix("en") })
        checks.append((french.name, .french, "Bonjour, ceci est un essai de lecture à voix haute."))
        checks.append((english.name, .english, "Hello, this is a read-aloud test."))
    } else {
        #expect(languages == ["es"])
    }
    for (voice, language, text) in checks {
        // Accented names (Noémie, Lucía-Sol) may be stored decomposed by the file system.
        let stored = try #require(phonon.voices.first { $0 == voice })
        try await phonon.setVoice(stored)
        try await phonon.setLanguage(language)
        let samples = try await phonon.synthesize(text)
        #expect(Double(samples.count) / Phonon.sampleRate > 1.2, "\(voice) produced too little audio")
        #expect(samples.contains { abs($0) > 0.01 })
    }
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

@Test
func storageCleanupFreesOnlyWhatTheRulesAllow() {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let day: TimeInterval = 24 * 60 * 60
    let mb: Int64 = 1_000_000
    func book(_ daysAgo: Double?, finished: Bool = false, audio: Int64 = 10 * mb, ocr: Int64 = 0)
        -> StorageJanitor.Candidate {
        StorageJanitor.Candidate(id: UUID(), lastOpened: daysAgo.map { now.addingTimeInterval(-$0 * day) },
                                 finished: finished, audioBytes: audio, ocrBytes: ocr)
    }
    let recent = book(2)
    let stale = book(31, ocr: 5 * mb)
    let finishedLastWeek = book(8, finished: true)
    let finishedYesterday = book(1, finished: true)
    let neverOpened = book(nil)
    let empty = book(400, audio: 0)
    let active = book(60)
    let all = [recent, stale, finishedLastWeek, finishedYesterday, neverOpened, empty, active]
    let policy = StorageJanitor.Policy()

    let freed = Set(StorageJanitor.plan(all, policy: policy, protected: [active.id], now: now))
    #expect(freed == [stale.id, finishedLastWeek.id, neverOpened.id])

    // "Never" and the finished toggle switch their rules off.
    let lenient = StorageJanitor.Policy(unusedDays: 0, deleteFinished: false)
    #expect(StorageJanitor.plan(all, policy: lenient, protected: [active.id], now: now).isEmpty)

    // Over the audio cap, the books opened longest ago go first; the protected
    // book counts towards the cap but is never deleted.
    let capped = StorageJanitor.Policy(unusedDays: 0, deleteFinished: false, audioCapBytes: 25 * mb)
    let older = book(20)
    let newer = book(3)
    let playing = book(90)
    let order = StorageJanitor.plan([newer, older, playing], policy: capped,
                                    protected: [playing.id], now: now)
    #expect(order == [older.id])
}

@Test
func interruptedModelConversionsAreRemoved() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("nodus-models-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let work = root.appendingPathComponent(".phonon-40m-es-conversion/checkpoint", isDirectory: true)
    let installed = root.appendingPathComponent("Phonon-40m-es", isDirectory: true)
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: installed, withIntermediateDirectories: true)
    try Data("weights".utf8).write(to: work.appendingPathComponent("model.safetensors"))
    try Data("{}".utf8).write(to: installed.appendingPathComponent("bundle.json"))

    #expect(ModelManager.removeInterruptedConversions(in: root) == 1)
    #expect(!FileManager.default.fileExists(atPath: work.deletingLastPathComponent().path))
    #expect(FileManager.default.fileExists(atPath: installed.appendingPathComponent("bundle.json").path))
}

/// Kokoro's Spanish voices were trained on espeak-ng phonemes (with misaki's
/// tie mapping). Every expected string below is espeak-ng 1.52 output for the
/// same text.
@Test(arguments: [
    ("Hola, ¿qué tal estás?", "ˈola, kˈe tˈal estˈas?"),
    ("En un lugar de la Mancha, de cuyo nombre no quiero acordarme.",
     "en ˈun luɣˈaɾ ðe la mˈanʧa, de kˈuʝo nˈombɾe nˈo kjˈeɾo ˌakoɾðˈaɾme."),
    ("La biblioteca abre a las nueve y media", "la βˌiβliotˈeka ˈaβɾe a las nwˈeβe i mˈeðja"),
    ("Rápidamente, desde el puente, vimos un hielo enorme y un huevo",
     "rˈapiðamˈente, dˌesðe el pwˈɛnte, bˈimos ˈun jˈelo enˈoɾme i ˈun wˈeβo"),
    ("Tengo un perro y una gata", "tˈɛŋɡo ˈum pˈero i ˈuna ɣˈata"),
    ("Muy bien", "mˈuj βjˈen"),
    ("Ruido, patria y lluvia", "ruˈiðo, pˈatɾia i ʎˈuβja"),
    ("Llueve en Gijón; el chico baila con agua, guerra, pingüino y Ximena",
     "ʎuˈeβe eŋ xixˈon; el ʧˈiko βˈIla kon ˈaɣwa, ɡˈera, pˌiŋɡuˈino i simˈena"),
    ("Cuidado con el rey", "kwiðˈaðo kon el rˈA"),
    ("Habéis llegado a Europa", "aβˈeis ʎeɣˈaðo a eʊɾˈopa"),
    ("Verdad", "beɾðˈad")
])
func spanishPhonemesFollowEspeak(text: String, expected: String) {
    #expect(SpanishG2P.phonemize(text) == expected)
}

@Test
func spanishNumbersAbbreviationsAndRomanNumeralsAreSpelledOut() {
    let numbers = SpanishG2P.phonemize("Llegó en 1605 con el 25%.")
    #expect(numbers.contains("mˈil sAsθjˈɛntos θˈinko"))
    #expect(numbers.contains("poɾ θjˈɛnto"))
    #expect(SpanishG2P.phonemize("El Sr. García") == "el seɲˈoɾ ɣaɾθˈia")
    #expect(SpanishG2P.phonemize("Capítulo IV") == "kapˈitulo kwˈatɾo")
    // A word that only looks like a numeral stays a word.
    #expect(SpanishTextNormalizer.romanNumerals(in: "MI casa") == "MI casa")
    #expect(SpanishTextNormalizer.romanValue("XIV") == 14)
    #expect(SpanishTextNormalizer.romanValue("IIII") == nil)
}

@Test
func kokoroSpanishPiecesFitTheModelAndKeepEveryWord() {
    let text = Array(repeating: "Frisaba la edad de nuestro hidalgo con los cincuenta años, era de complexión recia,",
                     count: 6).joined(separator: " ") + " seco de carnes y enjuto de rostro."
    let pieces = KokoroSpanish.pieces(of: text)
    #expect(pieces.count > 1)
    #expect(pieces.allSatisfy { $0.phonemes.count <= KokoroSpanish.maxPhonemes })
    let words = { (string: String) in string.split(whereSeparator: { !$0.isLetter }).map(String.init) }
    #expect(pieces.flatMap { words($0.text) } == words(text))
    #expect(KokoroSpanish.isSpanishVoice("ef_dora") && KokoroSpanish.isSpanishVoice("em_santa"))
    #expect(!KokoroSpanish.isSpanishVoice("af_heart"))
    #expect(ModelManager.kokoroVoices.filter { $0.language == "es-ES" }.map(\.id)
        == ["kokoro:ef_dora", "kokoro:em_alex", "kokoro:em_santa"])
}

@Test
func readerSearchIgnoresCaseAndAccentsAndStartsAtTheReadingPosition() {
    let chapters = ["La acción empieza.", "Otra ACCION aquí y otra acción allí."]
    let matches = ReaderSearch.matches(for: "accion", in: chapters)
    #expect(matches.map(\.chapterIndex) == [0, 1, 1])
    #expect(matches.map(\.range.location) == [3, 5, 24])
    #expect(ReaderSearch.matches(for: "  ", in: chapters).isEmpty)
    #expect(ReaderSearch.firstIndex(in: matches, fromChapter: 1, offset: 10) == 2)
    // Past the last match the search starts again from the first.
    #expect(ReaderSearch.firstIndex(in: matches, fromChapter: 1, offset: 30) == 0)
}

@Test @MainActor
func readerSearchStepsWrapAround() {
    let model = ReaderSearchModel()
    model.setMatches([ReaderSearchMatch(chapterIndex: 0, range: NSRange(location: 0, length: 1)),
                      ReaderSearchMatch(chapterIndex: 2, range: NSRange(location: 4, length: 1))],
                     startingAt: 1)
    #expect(model.rangesByChapter.keys.sorted() == [0, 2])
    model.next()
    #expect(model.current == 0)
    model.previous()
    #expect(model.current == 1)
    model.dismiss()
    #expect(!model.isPresented && model.count == 0 && model.currentMatch == nil)
}

@Test
func sheetsOverTheReaderUseTheReaderThemeColours() {
    let dark = ReaderTheme.resolve(.dark, colorScheme: .dark)
    let palette = NodusPalette.reader(dark)
    #expect(palette.background == dark.background)
    #expect(palette.text == dark.text)
    #expect(palette.isDark)
    let sepia = NodusPalette.reader(ReaderTheme.resolve(.sepia, colorScheme: .light))
    #expect(sepia.background == NodusPalette.sepia.background)
    #expect(!sepia.isDark)
}

@Test(arguments: [
    "6ïQkq_’QXKXnXqnNK’%Q»»KMfKnóKï5¿K 2K5;»%KXnXqn7;jKïQXKXq’nXqn4—»qX— Nqï%_—nXqn,’%;XQ—’nXqnNK’%Q»»KMfK-nóKï5¿Kn",
    "ab202SyuóáuGsV aa if5(5df5396 Gᵒᵒᵒ S1 zy+0,n( +,9nI6+06,üy y°S1 +V2V,fn—3ff,gVn,.(3gy.V 4—»qX—LnHFHJ ,’%Kn%q’Q’nX—5%—_K»n’qn¿Kn_qK»Q”KX"
])
func garbledPDFTextLayersAreRecognised(text: String) {
    #expect(PDFPageText.isGarbled(text))
}

@Test(arguments: [
    "En un lugar de la Mancha, de cuyo nombre no quiero acordarme, no ha mucho tiempo que vivía un hidalgo.",
    "Table 3. Results (n = 120): 45.2% ± 3.1, p < 0.05; see Smith et al. (2019), pp. 12–14, and the NASA report.",
    "La tesis doctoral analiza el período 1936–1939 en el marco de la historiografía española contemporánea.",
    "Short"
])
func readablePDFTextLayersAreKept(text: String) {
    #expect(!PDFPageText.isGarbled(text))
}

/// A page that shows Spanish text drawn as an image, with a text layer of
/// garbage on top: what a PDF whose fonts have no Unicode map looks like to
/// PDFKit. Import, narration and Intelligent Reading must read the page.
@Test @MainActor
func pdfWithAGarbledTextLayerIsReadWithOCR() throws {
    let lines = ["En un lugar de la Mancha, de cuyo nombre",
                 "no quiero acordarme, no ha mucho tiempo",
                 "que vivía un hidalgo de los de lanza en",
                 "astillero, adarga antigua y galgo corredor."]
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("garbled-\(UUID().uuidString).pdf")
    defer { try? FileManager.default.removeItem(at: url) }
    try writeGarbledPDF(lines: lines, to: url)

    let pdf = try #require(PDFDocument(url: url))
    let page = try #require(pdf.page(at: 0))
    let layer = page.string ?? ""
    #expect(PDFPageText.isGarbled(layer), "The fixture's text layer should be garbage: \(layer)")
    let readable = PDFPageText.readableText(page: page, allowOCR: true) ?? ""
    #expect(readable.contains("Mancha") && readable.contains("hidalgo"), "OCR read: \(readable)")

    let extraction = try DocumentExtractor.extract(url: url, format: .pdf, completeText: true)
    let text = extraction.chapters.map(\.text).joined(separator: " ")
    #expect(text.contains("Mancha") && !text.contains("QXKX"))
    #expect(extraction.language.hasPrefix("es"))

    let root = FileManager.default.temporaryDirectory.appendingPathComponent("reflow-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = PDFReflowStore(fileStore: FileStore(root: root))
    let reflow = try PDFReflowExtractor.extract(url: url, bookID: UUID(), contentHash: "test", store: store)
    let reflowText = reflow.pages.flatMap(\.blocks).map(\.text).joined(separator: " ")
    #expect(reflow.usedOCR)
    #expect(reflowText.contains("Mancha") && !reflowText.contains("QXKX"), "Reflow read: \(reflowText)")
}

private func writeGarbledPDF(lines: [String], to url: URL) throws {
    var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
    // The visible text, rasterised so that it is not in the text layer.
    let scale: CGFloat = 2
    let bitmap = try #require(CGContext(data: nil, width: Int(mediaBox.width * scale),
                                        height: Int(mediaBox.height * scale), bitsPerComponent: 8,
                                        bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    bitmap.setFillColor(CGColor(gray: 1, alpha: 1))
    bitmap.fill(CGRect(x: 0, y: 0, width: mediaBox.width * scale, height: mediaBox.height * scale))
    bitmap.scaleBy(x: scale, y: scale)
    let font = CTFontCreateWithName("Times New Roman" as CFString, 22, nil)
    for (index, line) in lines.enumerated() {
        let attributed = NSAttributedString(string: line, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)
        ])
        bitmap.textPosition = CGPoint(x: 60, y: 700 - CGFloat(index) * 34)
        CTLineDraw(CTLineCreateWithAttributedString(attributed), bitmap)
    }
    let image = try #require(bitmap.makeImage())

    let pdf = try #require(CGContext(url as CFURL, mediaBox: &mediaBox, nil))
    pdf.beginPDFPage(nil)
    pdf.draw(image, in: mediaBox)
    // The text layer: invisible garbage where the words are drawn.
    pdf.setTextDrawingMode(.invisible)
    let garbage = ["6ïQkq_’QXKXnXqnNK’%Q»»KMfKnóKï5¿K", "2K5;»%KXnXqn7;jKïQXKXq’nXqn4—»qX—",
                   "Nqï%_—nXqn,’%;XQ—’nXqnNK’%Q»»KMfK", "nóKï5¿Kn ab202SyuóáuGsV if5(5df5396"]
    for (index, line) in garbage.enumerated() {
        let attributed = NSAttributedString(string: line, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font
        ])
        pdf.textPosition = CGPoint(x: 60, y: 700 - CGFloat(index) * 34)
        CTLineDraw(CTLineCreateWithAttributedString(attributed), pdf)
    }
    pdf.endPDFPage()
    pdf.closePDF()
}

/// How fast Kokoro runs on the CPU only, the only placement iOS allows while a
/// locked phone narrates in the background (no Metal). Opt in with
/// `TEST_RUNNER_NODUS_KOKORO_CPU_BENCH=1` and a Kokoro bundle installed under
/// `TEST_RUNNER_CFFIXED_USER_HOME`.
@Test(.enabled(if: ProcessInfo.processInfo.environment["NODUS_KOKORO_CPU_BENCH"] == "1"),
      .timeLimit(.minutes(10)))
func kokoroCPUOnlySpeed() async throws {
    let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("NodusReader/Models/Kokoro", isDirectory: true)
    let text = "It is a way I have of driving off the spleen and regulating the circulation, whenever I find myself growing grim about the mouth."
    for (name, policy) in [("default", KokoroComputePolicy.gistDefault), ("cpuOnly", KokoroComputePolicy.cpuOnly)] {
        let engine = try await KokoroTTS.load(resources: .directory(directory), computePolicy: policy)
        _ = try await engine.synthesize("Warm up.", voice: KokoroVoiceID("af_heart"))
        let start = Date()
        let audio = try await engine.synthesize(text, voice: KokoroVoiceID("af_heart"))
        let elapsed = Date().timeIntervalSince(start)
        print("KOKORO \(name): \(String(format: "%.2f", elapsed)) s for \(String(format: "%.2f", audio.durationSeconds)) s, RTF \(String(format: "%.2f", elapsed / audio.durationSeconds))")
        #expect(audio.durationSeconds > 3)
    }
}

/// Light text over a pastel highlight is unreadable; dark themes use each
/// colour's deep tone, translucent, instead.
@Test(arguments: AnnotationColor.allCases)
func highlightsStayReadableInDarkThemes(color: AnnotationColor) {
    let dark = color.pageFill(isDark: true)
    let light = color.pageFill(isDark: false)
    #expect(dark.hex == color.underlineHex && dark.alpha < 0.5)
    #expect(light.hex == color.fillHex)
    // Relative luminance of the deep tone stays well below the pastel's.
    func luminance(_ hex: UInt32) -> Double {
        let channels = [(hex >> 16) & 0xFF, (hex >> 8) & 0xFF, hex & 0xFF].map { Double($0) / 255 }
        return 0.2126 * channels[0] + 0.7152 * channels[1] + 0.0722 * channels[2]
    }
    #expect(luminance(dark.hex) < luminance(light.hex) - 0.2)
}

/// Recognised words carry the measured times; words heard differently ("9"
/// for "nueve") are placed between their matched neighbours.
@Test
func recognisedWordsTimeTheReadAlongHighlight() throws {
    let text = "La biblioteca abre a las nueve y media."
    let words = AudioWordAligner.words(in: text)
    let heard: [SpeechWordAligner.RecognizedWord] = [
        .init(text: "La", start: 0.20, end: 0.32), .init(text: "biblioteca", start: 0.32, end: 0.95),
        .init(text: "abre", start: 0.95, end: 1.25), .init(text: "a", start: 1.25, end: 1.32),
        .init(text: "las", start: 1.32, end: 1.50), .init(text: "9", start: 1.50, end: 1.80),
        .init(text: "y", start: 1.80, end: 1.88), .init(text: "media.", start: 1.88, end: 2.30)
    ]
    let timings = try #require(SpeechWordAligner.place(words: words, recognized: heard, duration: 2.5))
    #expect(timings.map(\.location) == words.map(\.range.location))
    #expect(timings[1].start == 0.32)            // biblioteca, matched
    #expect(timings[5].start == 1.50)            // nueve: between "las" and "y"
    #expect(timings[6].start == 1.80)            // y, matched
    #expect(timings.last?.end == 2.5)
    #expect(zip(timings, timings.dropFirst()).allSatisfy { $0.start <= $1.start })
    #expect(SpeechWordAligner.normalize("Acción,") == "accion")

    // Recognition that matches too little is not trusted.
    let wrong: [SpeechWordAligner.RecognizedWord] = [.init(text: "otra", start: 0, end: 1),
                                                      .init(text: "cosa", start: 1, end: 2)]
    #expect(SpeechWordAligner.place(words: words, recognized: wrong, duration: 2.5) == nil)
}

/// Words missing from Kokoro's English dictionary go through MisakiSwift's
/// fallback network, which runs on MLX — on the CPU since the background fix.
/// Opt in with `TEST_RUNNER_NODUS_MODEL_DOWNLOAD_TESTS=1` and Kokoro installed.
@Test(.enabled(if: ProcessInfo.processInfo.environment["NODUS_MODEL_DOWNLOAD_TESTS"] == "1"),
      .timeLimit(.minutes(5)))
@MainActor
func kokoroSpeaksWordsOutsideItsDictionary() async throws {
    let suite = "nodus.tests.kokoro-oov.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let manager = ModelManager(voices: VoiceCatalog(defaults: defaults), defaults: defaults)
    let kokoro = try #require(manager.models.first { $0.engine == .kokoro })
    try #require(manager.isInstalled(kokoro))
    manager.selectModel(kokoro)
    let audio = try await manager.synthesize("The glorptastic snarfblats zibbled past Vexmoor and Quindarel.",
                                             voiceID: "kokoro:af_heart", engine: .kokoro)
    #expect(Double(audio.samples.count) / audio.sampleRate > 2)
    #expect(audio.samples.contains { abs($0) > 0.01 })
}

/// Footnote reference marks, footnotes and a table of contents in a PDF with
/// a real text layer: the reflow keeps the body clean, sets the footnote
/// apart and keeps one contents entry per line; narration skips the footnote.
@Test @MainActor
func reflowKeepsFootnotesAndContentsApart() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("footnotes-\(UUID().uuidString).pdf")
    defer { try? FileManager.default.removeItem(at: url) }
    var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
    let pdf = try #require(CGContext(url as CFURL, mediaBox: &mediaBox, nil))
    func draw(_ runs: [(String, CGFloat)], at point: CGPoint) {
        let line = NSMutableAttributedString()
        for (text, size) in runs {
            line.append(NSAttributedString(string: text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Times New Roman" as CFString, size, nil)
            ]))
        }
        pdf.textPosition = point
        CTLineDraw(CTLineCreateWithAttributedString(line), pdf)
    }
    // Page 1: contents.
    pdf.beginPDFPage(nil)
    let entries = ["Introduction", "The early years", "Method and sources", "Results", "Discussion", "Conclusions"]
    for (index, entry) in entries.enumerated() {
        draw([("\(entry) .................................... \(index * 12 + 3)", 14)],
             at: CGPoint(x: 72, y: 700 - CGFloat(index) * 30))
    }
    pdf.endPDFPage()
    // Page 2: body with reference marks, and a footnote at the bottom.
    pdf.beginPDFPage(nil)
    let body = ["The archive was reorganised in the spring of that year,", "when the society moved to its new building",
                "and the collection was catalogued again by hand.", "Several boxes were lost during the move,",
                "although most letters survived in good condition."]
    for (index, text) in body.enumerated() {
        var runs: [(String, CGFloat)] = [(text, 14)]
        if index == 1 { runs = [("when the society", 14), ("12", 8), (" moved to its new building", 14)] }
        draw(runs, at: CGPoint(x: 72, y: 700 - CGFloat(index) * 22))
    }
    draw([("12 See the annual report of the society for that year, page 4.", 9)], at: CGPoint(x: 72, y: 90))
    pdf.endPDFPage()
    pdf.closePDF()

    let root = FileManager.default.temporaryDirectory.appendingPathComponent("reflow-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = PDFReflowStore(fileStore: FileStore(root: root))
    let reflow = try PDFReflowExtractor.extract(url: url, bookID: UUID(), contentHash: "test", store: store)

    let contents = reflow.pages[0].blocks
    #expect(contents.filter { $0.kind == .list }.count == entries.count)
    #expect(contents.first?.text == "Introduction · 3")

    let page = reflow.pages[1]
    let bodyText = page.blocks.filter { !$0.isHeaderFooter }.map(\.text).joined(separator: " ")
    #expect(bodyText.contains("when the society moved"), "Body: \(bodyText)")
    #expect(!bodyText.contains("annual report"))
    let footnote = try #require(page.blocks.first { $0.text.contains("annual report") })
    #expect(footnote.isHeaderFooter)
    // Narration reads the body, not the footnote, at the same offsets.
    let narration = page.narrationText
    #expect((narration as NSString).length == (page.canonicalLayout.text as NSString).length)
    #expect(narration.contains("moved to its new building") && !narration.contains("annual report"))

    #expect(PDFReflowExtractor.contentsEntry("Chapter 2. Sources .......... 41", onContentsPage: false)
        == "Chapter 2. Sources · 41")
    #expect(PDFReflowExtractor.contentsEntry("It happened in 1936", onContentsPage: false) == nil)
}
