// SPDX-License-Identifier: AGPL-3.0-only
import CoreGraphics
import DesignSystem
import Foundation
import PDFKit
import Testing
@testable import Nodus_Reader

// Serial novels reach 1,000 to 2,400 chapters. These tests keep opening,
// paginating and narrating such a book bounded by what the reader shows, not
// by the length of the book.

enum LargeBookFixture {
    static func chapterParagraphs(_ chapter: Int, paragraphs: Int) -> [String] {
        SampleLibrary.syntheticParagraphs(seed: chapter, count: paragraphs)
    }

    static func chapters(count: Int, paragraphs: Int) -> [ExtractedChapter] {
        (0..<count).map { index in
            ExtractedChapter(id: index, title: "Chapter \(index + 1): The Lantern",
                             text: chapterParagraphs(index, paragraphs: paragraphs).joined(separator: "\n"))
        }
    }

    @MainActor
    static func epub(chapters count: Int, paragraphs: Int) throws -> URL {
        try SampleLibrary.makeEPUB(SampleLibrary.Spec(
            title: "The Longest Serial",
            author: "Nodus Tests",
            language: "en",
            description: "A synthetic serial novel.",
            asPDF: false,
            chapters: (0..<count).map {
                SampleLibrary.Chapter(title: "Chapter \($0 + 1): The Lantern",
                                      paragraphs: chapterParagraphs($0, paragraphs: paragraphs))
            }
        ))
    }

    static func seconds(_ work: () throws -> Void) rethrows -> Double {
        let start = Date()
        try work()
        return Date().timeIntervalSince(start)
    }

    static func style() -> ReaderPageStyle {
        ReaderPageStyle(theme: ReaderTheme.resolve(.light, colorScheme: .light),
                        preferences: ReaderPreferences(defaults: UserDefaults(suiteName: "nodus.tests.large.\(UUID().uuidString)")!))
    }
}

// MARK: - The window of a very long book

@Test
func bookExtentChoosesAWindowAroundTheReader() {
    // 100 chapters of 20,000 characters: 150,000 on each side is 8 chapters.
    let extent = ReaderBookExtent(lengths: Array(repeating: 20_000, count: 100))
    #expect(extent.total == 2_000_000)
    #expect(extent.window(around: 50) == 42..<59)
    // The ends of the book.
    #expect(extent.window(around: 0) == 0..<9)
    #expect(extent.window(around: 99) == 91..<100)
    // Always the neighbouring chapters, however long they are.
    let huge = ReaderBookExtent(lengths: Array(repeating: 900_000, count: 10))
    #expect(huge.window(around: 4) == 3..<6)
    #expect(ReaderBookExtent(lengths: []).window(around: 3) == 0..<0)
}

@Test
func bookExtentGrowsTheWindowInsteadOfMovingIt() {
    let extent = ReaderBookExtent(lengths: Array(repeating: 20_000, count: 200))
    let first = extent.window(around: 50)
    // Inside the window nothing is requested; at its ends, more is.
    #expect(!extent.isEdge(50, of: first))
    #expect(extent.isEdge(first.upperBound - 1, of: first))
    #expect(extent.isEdge(first.lowerBound, of: first))
    // The ends of the book are not edges: there is nothing beyond them.
    #expect(!extent.isEdge(0, of: 0..<9))
    #expect(!extent.isEdge(199, of: 191..<200))

    // Reading on keeps every page already laid out and adds chapters after.
    let grown = extent.window(around: first.upperBound - 1, extending: first)
    #expect(grown.lowerBound == first.lowerBound)
    #expect(grown.upperBound > first.upperBound)
    #expect(!extent.isEdge(first.upperBound - 1, of: grown))
    // Reading backwards adds chapters before.
    let back = extent.window(around: first.lowerBound, extending: first)
    #expect(back.upperBound == first.upperBound)
    #expect(back.lowerBound < first.lowerBound)
    // A chapter elsewhere, or a window that has grown too much, starts again.
    #expect(extent.window(around: 150, extending: first) == extent.window(around: 150))
    let long = 0..<70
    #expect(extent.characters(in: long) > ReaderBookExtent.maximumWindowCharacters)
    #expect(extent.window(around: 69, extending: long) == extent.window(around: 69))
}

@Test
func bookExtentMeasuresProgressInText() {
    let extent = ReaderBookExtent(lengths: [100, 300, 600])
    #expect(extent.fraction(chapter: 0, offset: 0) == 0)
    #expect(extent.fraction(chapter: 1, offset: 0) == 0.1)
    #expect(extent.fraction(chapter: 1, offset: 150) == 0.25)
    #expect(extent.fraction(chapter: 2, offset: 600) == 1)
    // Offsets past the chapter and unknown chapters stay in range.
    #expect(extent.fraction(chapter: 2, offset: 9_000) == 1)
    #expect(extent.fraction(chapter: 7, offset: 0) == 0)
    #expect(!extent.isLarge)
    #expect(ReaderBookExtent(lengths: Array(repeating: 10_000, count: 2400)).isLarge)
}

@Test
func windowPaginationLaysOutOnlyItsChapters() async {
    let chapters = LargeBookFixture.chapters(count: 40, paragraphs: 12)
    let style = LargeBookFixture.style()
    let size = CGSize(width: 340, height: 600)
    let whole = await TextPaginator.paginateConcurrently(chapters: chapters, style: style, pageSize: size)
    let window = await TextPaginator.paginateConcurrently(chapters: chapters, style: style, pageSize: size,
                                                          only: 10..<14)
    #expect(Set(window.pages.map(\.chapterIndex)) == [10, 11, 12, 13])
    #expect(window.pages.map(\.id) == Array(window.pages.indices))
    #expect(window.firstPageByChapter[10] == 0)
    // The same pages as in the whole book: same breaks, same text.
    let expected = whole.pages.filter { (10..<14).contains($0.chapterIndex) }
    #expect(window.pages.map(\.fullRange) == expected.map(\.fullRange))
    #expect(window.pages.map(\.pagesInChapter) == expected.map(\.pagesInChapter))

    // Growing the window reuses the chapters already laid out.
    var known: [Int: [ReaderPage]] = [:]
    for page in window.pages { known[page.chapterIndex, default: []].append(page) }
    let grown = await TextPaginator.paginateConcurrently(chapters: chapters, style: style, pageSize: size,
                                                         known: known, only: 10..<18)
    #expect(Array(grown.pages.prefix(window.pages.count)) == window.pages)
    #expect(Set(grown.pages.map(\.chapterIndex)) == Set(10..<18))
}

// MARK: - Opening and narrating

@Test @MainActor
func longEPUBKeepsItsChaptersInOrderWhenParsedOnEveryCore() throws {
    let url = try LargeBookFixture.epub(chapters: 300, paragraphs: 3)
    defer { try? FileManager.default.removeItem(at: url) }
    let chapters = try EPUBParser.parse(url: url, fallbackTitle: "Large").chapters
    #expect(chapters.count == 300)
    #expect(chapters.map(\.id) == Array(0..<300))
    for index in [0, 1, 63, 64, 65, 127, 128, 255, 299] {
        #expect(chapters[index].title == "Chapter \(index + 1): The Lantern")
        #expect(chapters[index].text == LargeBookFixture.chapterParagraphs(index, paragraphs: 3).joined(separator: "\n\n"))
    }
}

@Test
func sentencesBuiltOnEveryCoreMatchTheBookOrder() {
    let chapters = LargeBookFixture.chapters(count: 60, paragraphs: 6)
    let sentences = PlaybackController.buildSentences(from: chapters)
    #expect(sentences.map(\.id) == Array(sentences.indices))
    var expected: [(Int, NSRange)] = []
    for (index, chapter) in chapters.enumerated() {
        expected += SentenceTokenizer.ranges(from: chapter.text).map { (index, $0) }
    }
    #expect(sentences.count == expected.count)
    #expect(sentences.map(\.chapterIndex) == expected.map(\.0))
    #expect(sentences.map(\.chapterRange) == expected.map(\.1))
    let sample = sentences[sentences.count / 2]
    #expect(sample.text == (chapters[sample.chapterIndex].text as NSString).substring(with: sample.chapterRange))
}

/// Counts extractions for `BookTextCache`.
private actor ExtractionCounter {
    private(set) var count = 0
    func extract() async -> [ExtractedChapter] {
        count += 1
        try? await Task.sleep(for: .milliseconds(80))
        return [ExtractedChapter(id: 0, title: "One", text: "Text \(count)")]
    }
}

@Test
func bookTextIsExtractedOnceForEveryoneWhoAsks() async throws {
    let cache = BookTextCache()
    let counter = ExtractionCounter()
    let key = BookTextCache.Key(bookID: UUID(), contentHash: "hash", path: "/book.epub", modified: nil)
    // The reader, narration and recaps asking at once share one pass.
    async let first = cache.chapters(for: key) { await counter.extract() }
    async let second = cache.chapters(for: key) { await counter.extract() }
    async let third = cache.chapters(for: key) { await counter.extract() }
    let results = try await [first, second, third]
    #expect(await counter.count == 1)
    #expect(results.allSatisfy { $0.first?.text == "Text 1" })
    // Narration starting later reads the same text again without parsing.
    #expect(try await cache.chapters(for: key) { await counter.extract() }.first?.text == "Text 1")
    #expect(await counter.count == 1)
    // Another book, or the same file changed, is extracted.
    var changed = key
    changed.modified = Date()
    #expect(try await cache.chapters(for: changed) { await counter.extract() }.first?.text == "Text 2")
    // A PDF whose Intelligent Reading finished reads its new text.
    var reflowed = changed
    reflowed.reflowModified = Date()
    #expect(try await cache.chapters(for: reflowed) { await counter.extract() }.first?.text == "Text 3")
    #expect(await counter.count == 3)
}

// MARK: - PDF text layers

@Test
func pdfPagesThatFailAreNotReadAgain() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("nodus-text-layer-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let journal = PDFTextLayerJournal(directory: directory)
    #expect(journal.begin(document: "book.pdf|10", page: 3))
    journal.end(document: "book.pdf|10", page: 3, failed: false)
    #expect(journal.begin(document: "book.pdf|10", page: 4))
    journal.end(document: "book.pdf|10", page: 4, failed: true)
    #expect(!journal.begin(document: "book.pdf|10", page: 4))
    #expect(journal.begin(document: "book.pdf|10", page: 3))
    journal.end(document: "book.pdf|10", page: 3, failed: false)
    // The app ends in the middle of page 7 (no `end`).
    #expect(journal.begin(document: "book.pdf|10", page: 7))

    // Next launch: the failed page and the one being read are skipped;
    // the others, and other documents, are read as usual.
    let relaunched = PDFTextLayerJournal(directory: directory)
    #expect(relaunched.isSkipped(document: "book.pdf|10", page: 4))
    #expect(relaunched.isSkipped(document: "book.pdf|10", page: 7))
    #expect(!relaunched.begin(document: "book.pdf|10", page: 7))
    #expect(relaunched.begin(document: "book.pdf|10", page: 3))
    relaunched.end(document: "book.pdf|10", page: 3, failed: false)
    #expect(relaunched.begin(document: "other.pdf|10", page: 7))
    relaunched.end(document: "other.pdf|10", page: 7, failed: false)
    // And it stays that way.
    #expect(PDFTextLayerJournal(directory: directory).isSkipped(document: "book.pdf|10", page: 7))
    #expect(!PDFTextLayerJournal(directory: directory).isSkipped(document: "other.pdf|10", page: 7))
}

@Test
func exceptionsFromSystemFrameworksAreCaught() {
    var ran = false
    #expect(NodusPerformCatchingExceptions { ran = true })
    #expect(ran)
    #expect(!NodusPerformCatchingExceptions {
        NSException(name: .rangeException, reason: "Thrown inside a system framework", userInfo: nil).raise()
    })
}

@Test @MainActor
func pdfTextLayerIsReadThroughTheGuard() throws {
    let url = try SampleLibrary.makePDF(SampleLibrary.Spec(
        title: "Guarded", author: "Nodus Tests", language: "en", description: "", asPDF: true,
        chapters: [SampleLibrary.Chapter(title: "Only", paragraphs: ["The quiet river carried a lantern past the old walls."])]
    ))
    defer { try? FileManager.default.removeItem(at: url) }
    let document = try #require(PDFDocument(url: url))
    let page = try #require(document.page(at: 0))
    #expect(PDFTextLayer.string(of: page) == page.string)
    let chapters = try DocumentExtractor.extract(url: url, format: .pdf, completeText: true).chapters
    #expect(chapters.count == document.pageCount)
    #expect(chapters.contains { $0.text.contains("lantern") })
}

// MARK: - Text helpers on the hot path

@Test
func boilerplateDetectionMatchesTheRulesItGuards() {
    #expect(EPUBTextCleaner.mentionsBoilerplateSource("*** START OF THE PROJECT GUTENBERG EBOOK ***"))
    #expect(EPUBTextCleaner.mentionsBoilerplateSource("the full project Gutenberg license"))
    #expect(EPUBTextCleaner.mentionsBoilerplateSource("Biblioteca Virtual Miguel de CERVANTES - Universidad de Alicante"))
    #expect(EPUBTextCleaner.mentionsBoilerplateSource("Este archivo fue Generado de forma automática"))
    #expect(!EPUBTextCleaner.mentionsBoilerplateSource("Chapter 1\nThe merchant counted his coins again before dawn."))
    #expect(!EPUBTextCleaner.mentionsBoilerplateSource(""))
    #expect(!EPUBTextCleaner.mentionsBoilerplateSource("gutenber"))
    // Unchanged results for ordinary chapters and for boilerplate.
    #expect(EPUBTextCleaner.clean("  A chapter.\n") == "A chapter.")
    #expect(EPUBTextCleaner.clean("Preface\n*** START OF THE PROJECT GUTENBERG EBOOK X ***\nThe text.") == "The text.")
    let long = String(repeating: "word ", count: 20).trimmingCharacters(in: .whitespaces)
    #expect(ParagraphJoiner.join(long + "\n\n" + long) == long + " " + long)
    #expect(ParagraphJoiner.join("Short one\n\nshort two") == "Short one\n\nshort two")
}

/// Opt-in measurement of the whole pipeline on a 2,400-chapter book:
/// `TEST_RUNNER_NODUS_LARGE_BOOK_PROBE=1 xcodebuild test …`.
@Test(.enabled(if: ProcessInfo.processInfo.environment["NODUS_LARGE_BOOK_PROBE"] != nil))
func largeBookProbe() async throws {
    let url = try await LargeBookFixture.epub(chapters: 2400, paragraphs: 28)
    defer { try? FileManager.default.removeItem(at: url) }

    var extraction: DocumentExtraction?
    let parse = try LargeBookFixture.seconds {
        extraction = try EPUBParser.parse(url: url, fallbackTitle: "Large")
    }
    let chapters = try #require(extraction).chapters
    let characters = chapters.reduce(0) { $0 + ($1.text as NSString).length }
    print("PROBE parse \(parse)s chapters \(chapters.count) characters \(characters)")

    var sentenceCount = 0
    let tokenize = LargeBookFixture.seconds {
        for chapter in chapters { sentenceCount += SentenceTokenizer.ranges(from: chapter.text).count }
    }
    print("PROBE sentences-serial \(tokenize)s sentences \(sentenceCount)")

    let style = LargeBookFixture.style()
    let size = CGSize(width: 340, height: 600)
    let one = LargeBookFixture.seconds {
        _ = TextPaginator.paginateChapter(chapters[0], index: 0, style: style, pageSize: size)
    }
    print("PROBE paginate-one-chapter \(one)s")
    let start = Date()
    let book = await TextPaginator.paginateConcurrently(chapters: chapters, style: style, pageSize: size)
    print("PROBE paginate-book \(Date().timeIntervalSince(start))s pages \(book.pages.count)")
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["NODUS_LARGE_BOOK_PROBE"] != nil))
func largeBookParseBreakdownProbe() {
    let htmls: [String] = (0..<600).map { index in
        let body = LargeBookFixture.chapterParagraphs(index, paragraphs: 28).map { "<p>\($0)</p>" }.joined(separator: "\n      ")
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml">
        <head><title>Chapter \(index + 1): The Lantern</title></head>
        <body>
          <h1>Chapter \(index + 1): The Lantern</h1>
          \(body)
        </body>
        </html>
        """
    }
    let datas = htmls.map { Data($0.utf8) }
    var conversions: [HTMLText.Conversion] = []
    print("PROBE600 convert \(LargeBookFixture.seconds { conversions = htmls.map { HTMLText.convert($0) } })")
    print("PROBE600 decode \(LargeBookFixture.seconds { for data in datas { _ = String(data: data, encoding: .utf8) } })")
    print("PROBE600 firstHeading \(LargeBookFixture.seconds { for data in datas { _ = HTMLText.firstHeading(from: data) } })")
    print("PROBE600 documentTitle \(LargeBookFixture.seconds { for data in datas { _ = HTMLText.documentTitle(from: data) } })")
    print("PROBE600 hasSectionHeading \(LargeBookFixture.seconds { for html in htmls { _ = HTMLText.hasSectionHeading(html) } })")
    var builder = ChapterBuilder(hasNavigation: true)
    print("PROBE600 builder \(LargeBookFixture.seconds { for (index, conversion) in conversions.enumerated() { builder.add(conversion, points: [NavigationPoint(path: "c", fragment: nil, title: "Chapter \(index + 1): The Lantern")], heading: nil, documentTitle: nil, hasSectionHeading: true) } })")
    let texts = builder.chapters.map(\.text)
    print("PROBE600 clean+join \(LargeBookFixture.seconds { for text in texts { _ = ParagraphJoiner.join(EPUBTextCleaner.clean(text)) } })")
    print("PROBE600 cleanTitle \(LargeBookFixture.seconds { for chapter in builder.chapters { _ = ChapterBuilder.cleanTitle(chapter.title) } })")
    let paths = (0..<2400).map { "OEBPS/chapter\($0 + 1).xhtml" }
    print("PROBE2400 navfilter \(LargeBookFixture.seconds { for path in paths { _ = paths.filter { $0.caseInsensitiveCompare(path) == .orderedSame } } })")
}
