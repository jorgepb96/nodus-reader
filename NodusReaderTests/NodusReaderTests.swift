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
