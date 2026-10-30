// SPDX-License-Identifier: AGPL-3.0-only
import CoreGraphics
import CoreText
import Foundation
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif
import PDFKit
import Testing
@testable import Nodus_Reader

// MARK: - Text helpers

@Test
func textNormalizerRepairsLigaturesAndPageNumbers() {
    #expect(TextNormalizer.cleanLine("e\u{FB00}ect and \u{FB01}ne") == "effect and fine")
    #expect(TextNormalizer.cleanLine("a\u{00A0}b\u{200B}c") == "a bc")
    #expect(TextNormalizer.cleanLine("confl ictivos y signifi cado") == "conflictivos y significado")
    #expect(TextNormalizer.cleanLine("fi ables y defi nirlos") == "fiables y definirlos")
    #expect(TextNormalizer.isPageNumber("Page 12"))
    #expect(TextNormalizer.isPageNumber("12 of 90"))
    #expect(TextNormalizer.isPageNumber("Fielding, et al. Page 1"))
    #expect(!TextNormalizer.isPageNumber("9110"))
    #expect(TextNormalizer.isBarePageNumber("9110"))
    #expect(TextNormalizer.isBarePageNumber("iv"))
}

@Test
func hyphenationKeepsCompoundsAndJoinsBrokenWords() {
    let known: Set<String> = ["example", "English-to", "sequence-aligned"]
    let resolver = HyphenationResolver { known.contains($0.lowercased()) }
    #expect(TextNormalizer.joinLines(["exam-", "ple"], hyphenation: resolver) == "example")
    #expect(TextNormalizer.joinLines(["English-to-", "German"], hyphenation: resolver)
        == "English-to-German")
    #expect(TextNormalizer.joinLines(["sequence-", "aligned"], hyphenation: resolver)
        == "sequence-aligned")
    #expect(TextNormalizer.joinLines(["foo-", "bar"], hyphenation: resolver) == "foobar")
}

@Test
func plainTextJoinsWrappedLinesAndKeepsParagraphs() {
    let source = "The Nodus Text Document\n\nThis is a paragraph that is wrapped\nacross source lines.\n\nA second paragraph."
    let text = PlainText.paragraphs(source)
    #expect(text.contains("wrapped across source lines."))
    #expect(text.contains("\n\nA second paragraph."))
}

@Test
func markdownImportProducesCleanReadingText() {
    let source = """
    # The Nodus Test Document

    This is the first paragraph. It is wrapped
    across several source lines, and the parser must
    join them into one paragraph.

    ## A section

    A paragraph with **bold**, *italic*, `code`, a [link](https://example.com) and an image:
    ![Alt text](cover.png). A line with a break<br>here.

    [nodus]: https://example.com/definition

    - First list item
    - Second list item with a wrapped
      continuation line

    1. Numbered item one
    2. Numbered item two

    > A quotation that should stay
    > together as one block.

    ```swift
    let value = 42
    ```

    | Name | Value |
    | --- | --- |
    | Alpha | 1 |

    ---
    """
    let text = MarkdownText.plainText(source)
    #expect(text.contains("This is the first paragraph. It is wrapped across several source lines"))
    #expect(text.contains("bold, italic, code, a link and an image: Alt text. A line with a break here."))
    #expect(!text.contains("nodus:"))
    #expect(text.contains("• First list item\n• Second list item with a wrapped continuation line"))
    #expect(text.contains("1. Numbered item one\n2. Numbered item two"))
    #expect(text.contains("A quotation that should stay together as one block."))
    #expect(text.contains("let value = 42"))
    #expect(text.contains("Name | Value"))
    #expect(!text.contains("#"))
    #expect(!text.contains("```"))
    #expect(!text.contains("---"))
}

@Test
func htmlImportKeepsListsAndTablesAndDropsBoilerplate() {
    let html = """
    <html><head><title>HTML Test</title><script>alert(1)</script></head><body>
    <h1>HTML Test</h1>
    <p>This is a paragraph that is
    wrapped across source lines.</p>
    <ul><li>First item</li><li>Second item</li></ul>
    <ol><li>One</li><li>Two</li></ol>
    <table><tr><td>Alpha</td><td>1</td></tr><tr><td>Beta</td><td>2</td></tr></table>
    <footer>This footer is boilerplate.</footer>
    </body></html>
    """
    let text = HTMLText.plainText(from: html)
    #expect(text.contains("This is a paragraph that is wrapped across source lines."))
    #expect(text.contains("• First item"))
    #expect(text.contains("• Second item"))
    #expect(text.contains("1. One"))
    #expect(text.contains("2. Two"))
    #expect(text.contains("Alpha | 1"))
    #expect(text.contains("Beta | 2"))
    #expect(!text.contains("This footer is boilerplate."))
}

// MARK: - PDF fixture

/// A three-page PDF with a contents page, a running head, page numbers, a
/// paragraph split across pages, and a second section.
private func makeParserFixture() throws -> URL {
    let pageWidth: CGFloat = 612
    let pageHeight: CGFloat = 792
    var mediaBox = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("parser-fixture-\(UUID().uuidString).pdf")
    guard let pdf = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
        throw ImportError.unreadableDocument("fixture")
    }

    let regular = CTFontCreateWithName("Helvetica" as CFString, 10.5, nil)
    let heading = CTFontCreateWithName("Helvetica-Bold" as CFString, 14, nil)
    let titleFont = CTFontCreateWithName("Helvetica-Bold" as CFString, 24, nil)
    let tocFont = CTFontCreateWithName("Helvetica-Bold" as CFString, 15, nil)
    let small = CTFontCreateWithName("Helvetica" as CFString, 8, nil)

    func draw(_ text: String, top: CGFloat, font: CTFont) {
        let attributed = NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font
        ])
        pdf.textPosition = CGPoint(x: 72, y: pageHeight - top)
        CTLineDraw(CTLineCreateWithAttributedString(attributed), pdf)
    }

    func beginPage(_ number: Int) {
        pdf.beginPDFPage(nil)
        draw("PARSER TEST", top: 24, font: small)
        draw("Page \(number)", top: pageHeight - 32, font: small)
    }

    // Page 1: title and contents.
    beginPage(1)
    draw("A Parser Test", top: 100, font: titleFont)
    draw("Table of Contents", top: 170, font: tocFont)
    draw("1. Introduction ......... 2", top: 205, font: regular)
    draw("2. Methods ......... 3", top: 225, font: regular)
    draw("3. Results ......... 4", top: 245, font: regular)
    pdf.endPDFPage()

    // Page 2: heading and a paragraph that reaches the bottom of the page and
    // continues on page 3.
    beginPage(2)
    draw("1 Introduction", top: 100, font: heading)
    let body = [
        "This fixture exercises the parser that turns a PDF into readable",
        "Markdown. The paragraph is wrapped over many lines and reaches",
        "the bottom of the page. It must stay one paragraph even though",
        "the text layer stores every visual line separately. The parser",
        "joins the lines, handles a hyphenated word at a line end and",
        "keeps the running head and the page number out of the prose.",
        "The final line deliberately has no full stop because the text",
        "continues on the next page, where the parser must join it",
        "without a blank line or a repeated page label. The rest of the",
        "page is filled with ordinary sentences so that the paragraph",
        "really reaches the lower margin of the page. A reader should",
        "see one continuous paragraph, and narration should read one",
        "sentence from the bottom of this page into the top of the next.",
        "The running head is repeated on every page and is not part of",
        "the book. The page number is a folio and is not part of the",
        "book either. The parser must recognise both without touching",
        "the prose or splitting the paragraph around them. This is the",
        "kind of page break that used to cut a paragraph in two, and it",
        "must not do that any more. The last line ends with the words",
        "and the paragraph continues"
    ]
    var top: CGFloat = 130
    for line in body {
        draw(line, top: top, font: regular)
        top += 16
    }
    pdf.endPDFPage()

    // Page 3: the continuation, then a new section.
    beginPage(3)
    draw("on the next page.", top: 100, font: regular)
    draw("2 Methods", top: 140, font: heading)
    draw("The second section starts here and is a separate paragraph.", top: 175, font: regular)
    pdf.endPDFPage()
    pdf.closePDF()
    return url
}

@Test @MainActor
func pdfParserKeepsParagraphsContentsAndRunningHeadsApart() throws {
    let url = try makeParserFixture()
    defer { try? FileManager.default.removeItem(at: url) }

    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("parser-store-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = PDFReflowStore(fileStore: FileStore(root: root))
    let document = try PDFReflowExtractor.extract(
        url: url, bookID: UUID(), contentHash: "fixture", store: store, maxPages: 10
    )

    #expect(document.pages.count == 3)
    let contents = document.pages[0].blocks
    #expect(contents.contains { $0.kind == .heading1 && $0.text == "Table of Contents" })
    let entries = contents.filter { $0.kind == .list }.map(\.text)
    #expect(entries.contains("1. Introduction · 2"))
    #expect(entries.contains("2. Methods · 3"))
    #expect(contents.contains { $0.isHeaderFooter && $0.text == "PARSER TEST" })
    #expect(contents.contains { $0.isHeaderFooter && $0.text == "Page 1" })

    let secondPage = document.pages[1]
    #expect(secondPage.blocks.contains { $0.kind == .heading1 && $0.text == "1 Introduction" })
    #expect(secondPage.blocks.contains { $0.isHeaderFooter && $0.text == "Page 2" })

    let thirdPage = document.pages[2]
    let continuation = try #require(thirdPage.blocks.first { $0.text.hasPrefix("on the next page.") })
    #expect(continuation.continuesPrevious)
    #expect(thirdPage.blocks.contains { $0.kind == .heading1 && $0.text == "2 Methods" })

    let markdown = document.markdown()
    #expect(markdown.contains("# A Parser Test"))
    #expect(markdown.contains("# Table of Contents"))
    #expect(markdown.contains("- 1. Introduction · 2"))
    #expect(markdown.contains("# 1 Introduction"))
    #expect(markdown.contains("# 2 Methods"))
    #expect(markdown.contains("and the paragraph continues on the next page."),
            "Markdown:\n\(markdown)")
    #expect(!markdown.contains("PARSER TEST"))
    #expect(!markdown.contains("Page 2"))
    #expect(!markdown.contains("Page 3"))
}

private func parserCorpusPath() -> String? {
    let environment = ProcessInfo.processInfo.environment
    return environment["NODUS_PARSER_CORPUS"]
        ?? environment["TEST_RUNNER_NODUS_PARSER_CORPUS"]
}

/// Opt in with `TEST_RUNNER_NODUS_PARSER_CORPUS=/path/to/downloaded/pdfs`. The
/// corpus is not committed; `tools/parser-corpus/fetch.sh` downloads it.
@Test(.enabled(if: parserCorpusPath() != nil))
@MainActor
func realPDFCorpusParsesCleanly() throws {
    let root = URL(fileURLWithPath: try #require(parserCorpusPath()))
    let storeRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("parser-corpus-store-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: storeRoot) }
    let store = PDFReflowStore(fileStore: FileStore(root: storeRoot))

    let rfcURL = root.appendingPathComponent("rfc9110.pdf")
    if FileManager.default.fileExists(atPath: rfcURL.path) {
        let rfc = try PDFReflowExtractor.extract(
            url: rfcURL, bookID: UUID(), contentHash: "rfc", store: store, maxPages: 4
        )
        #expect(rfc.pages.count == 4)
        #expect(rfc.pages[0].blocks.contains { $0.isHeaderFooter })
        #expect(rfc.pages[1].blocks.contains { $0.kind == .list && $0.text.contains("1. Introduction") })
        let markdown = rfc.markdown()
        #expect(!markdown.contains("Fielding, et al."))
        #expect(markdown.contains("Table of Contents"))
        #expect(markdown.contains("1. Introduction"))
    }

    let bertURL = root.appendingPathComponent("arxiv-bert.pdf")
    if FileManager.default.fileExists(atPath: bertURL.path) {
        let bert = try PDFReflowExtractor.extract(
            url: bertURL, bookID: UUID(), contentHash: "bert", store: store, maxPages: 3
        )
        let markdown = bert.markdown()
        #expect(markdown.contains("BERT: Pre-training of Deep Bidirectional Transformers"))
        #expect(markdown.contains("Left-to-right language modeling and auto-encoder"))
        #expect(markdown.contains("minimal difference between the pre-trained architecture"),
                "MARKDOWN:\n\(markdown)")
        #expect(!markdown.contains("arXiv:1810.04805"))
        #expect(!markdown.contains("Page 3"))
    }
}

// MARK: - EPUB

@MainActor
private func makeParserEPUB() throws -> URL {
    let container = """
    <?xml version="1.0" encoding="UTF-8"?>
    <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
      <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
    </container>
    """
    let opf = """
    <?xml version="1.0" encoding="UTF-8"?>
    <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id">
      <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
        <dc:identifier id="id">urn:uuid:\(UUID().uuidString)</dc:identifier>
        <dc:title>Fixture Book</dc:title>
        <dc:creator>Test Author</dc:creator>
        <dc:language>en</dc:language>
      </metadata>
      <manifest>
        <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
        <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
        <item id="ch1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
      </manifest>
      <spine toc="ncx"><itemref idref="ch1"/></spine>
    </package>
    """
    let ncx = """
    <?xml version="1.0" encoding="UTF-8"?>
    <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
      <navMap>
        <navPoint id="n1"><navLabel><text>I hope Mr. Bingley will like it. CHAPTER II.</text></navLabel><content src="ch1.xhtml#chap2"/></navPoint>
        <navPoint id="n2"><navLabel><text>delighted to see their dear friend again.</text></navLabel><content src="ch1.xhtml#chap3"/></navPoint>
      </navMap>
    </ncx>
    """
    let nav = """
    <?xml version="1.0" encoding="UTF-8"?>
    <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
    <body><nav epub:type="toc"><ol>
      <li><a href="ch1.xhtml#chap2">I hope Mr. Bingley will like it. CHAPTER II.</a></li>
      <li><a href="ch1.xhtml#chap3">delighted to see their dear friend again.</a></li>
    </ol></nav></body></html>
    """
    let chapter = """
    <?xml version="1.0" encoding="UTF-8"?>
    <html xmlns="http://www.w3.org/1999/xhtml"><head><title>Fixture Book</title></head><body>
    <p>This is the first part of a long paragraph that ends with the word connection and it is long enough to be prose rather than a verse line, so the parser can tell that it is not finished</p>
    <div class="figcenter"><span id="img_images_i_1.jpg"></span><div class="caption"><p>“A Caption”</p><p>[Copyright 1894]</p></div></div>
    <p class="nind">and continues after the illustration with the rest of the paragraph, which is also long enough to be prose and starts in lower case on purpose.</p>
    <h2 id="chap2"><span class="caption">I hope Mr. Bingley will like it.</span><br/><br/>CHAPTER II.</h2>
    <p>MR. BENNET was among the earliest of those who waited on Mr. Bingley, and this paragraph is long enough to be prose and to keep its own line.</p>
    <h2 id="chap3"><span class="caption">delighted to see their dear friend again.</span><br/><br/>CHAPTERXXVII.</h2>
    <p>This is the third chapter paragraph, long enough not to be considered verse and with ordinary sentences inside it.</p>
    </body></html>
    """
    return try SampleLibrary.makeArchive([
        ("mimetype", "application/epub+zip"),
        ("META-INF/container.xml", container),
        ("OEBPS/content.opf", opf),
        ("OEBPS/toc.ncx", ncx),
        ("OEBPS/nav.xhtml", nav),
        ("OEBPS/ch1.xhtml", chapter)
    ])
}

@Test @MainActor
func epubCleansTitlesAndJoinsParagraphsAcrossIllustrations() throws {
    let url = try makeParserEPUB()
    defer { try? FileManager.default.removeItem(at: url) }

    let extraction = try EPUBParser.parse(url: url, fallbackTitle: "Fallback")
    #expect(extraction.title == "Fixture Book")
    let allText = extraction.chapters.map(\.text).joined(separator: "\n\n")
    #expect(!allText.contains("A Caption"))
    #expect(!allText.contains("Copyright 1894"))
    #expect(allText.contains("not finished and continues after the illustration"),
            "Text:\n\(allText)")

    let titles = extraction.chapters.map(\.title)
    #expect(titles.contains("CHAPTER II."), "Titles: \(titles)")
    #expect(titles.contains("CHAPTER XXVII."), "Titles: \(titles)")
    #expect(!titles.contains { $0.contains("I hope Mr. Bingley") })
    #expect(!titles.contains { $0.contains("delighted to see") })

    let chapter2 = try #require(extraction.chapters.first { $0.title == "CHAPTER II." })
    #expect(chapter2.text.hasPrefix("MR. BENNET was among"))
}

@Test @MainActor
func epubImportsEveryChapterBeyondTwoThousand() throws {
    // Serial novels can be longer than the old 2,000-chapter cap. The parser
    // must import the whole spine, not silently stop near the end of the book.
    let chapterCount = 2_334
    let chapters = (1...chapterCount).map { number in
        SampleLibrary.Chapter(
            title: "Chapter \(number)",
            paragraphs: ["This is the body of chapter \(number), long enough to be kept."]
        )
    }
    let url = try SampleLibrary.makeEPUB(SampleLibrary.Spec(
        title: "Long Serial",
        author: "Test Author",
        language: "en",
        description: "A serial novel with more chapters than the old cap.",
        asPDF: false,
        chapters: chapters
    ))
    defer { try? FileManager.default.removeItem(at: url) }

    let extraction = try EPUBParser.parse(url: url, fallbackTitle: "Fallback")
    #expect(extraction.chapters.count == chapterCount)
    #expect(extraction.chapters.first?.title == "Chapter 1")
    #expect(extraction.chapters.last?.title == "Chapter \(chapterCount)")
    #expect(extraction.chapters.last?.text.contains("body of chapter \(chapterCount)") == true)
}

@Test
func epubTitleCleanerHandlesIllustrationCaptionsAndGutenbergPrefixes() {
    #expect(ChapterBuilder.cleanTitle("I hope Mr. Bingley will like it. CHAPTER XXVII.")
        == "CHAPTER XXVII.")
    #expect(ChapterBuilder.cleanTitle("CHAPTERXXVII.") == "CHAPTER XXVII.")
    #expect(ChapterBuilder.cleanTitle("The Project Gutenberg eBook of Beowulf")
        == "Beowulf")
}

@Test
func epubCleanerRemovesProjectGutenbergHeaderAndLicence() {
    let text = """
    The Project Gutenberg eBook of Test

    *** START OF THE PROJECT GUTENBERG EBOOK TEST ***

    The actual book starts here.

    *** END OF THE PROJECT GUTENBERG EBOOK TEST ***

    THE FULL PROJECT GUTENBERG™ LICENSE
    """
    #expect(EPUBTextCleaner.clean(text) == "The actual book starts here.")
}

@Test
func epubCleanerRemovesCervantesVirtualGeneratedLicence() {
    let text = """
    Este archivo fue generado de forma automática el 29/06/2022.
    Biblioteca Virtual Miguel de Cervantes - Universidad de Alicante
    http://www.cervantesvirtual.com/obra/example/
    I.S.B.N. 978-84-1143-550-5
    Licencia CC-BY-NC
    https://creativecommons.org/licenses/by-nc/4.0/deed.es_ES

    Miguel de Cervantes Saavedra
    """
    #expect(EPUBTextCleaner.clean(text) == "Miguel de Cervantes Saavedra")
}

private func parserEPUBCorpusPath() -> String? {
    let environment = ProcessInfo.processInfo.environment
    return environment["NODUS_EPUB_CORPUS"]
        ?? environment["TEST_RUNNER_NODUS_EPUB_CORPUS"]
}

@Test(.enabled(if: parserEPUBCorpusPath() != nil))
@MainActor
func realEPUBCorpusParsesParagraphsCleanly() throws {
    let root = URL(fileURLWithPath: try #require(parserEPUBCorpusPath()))

    let prideURL = root.appendingPathComponent("gutenberg-pride-and-prejudice.epub")
    if FileManager.default.fileExists(atPath: prideURL.path) {
        let pride = try EPUBParser.parse(url: prideURL, fallbackTitle: "Fallback")
        #expect(pride.title == "Pride and Prejudice")
        let text = pride.chapters.map(\.text).joined(separator: "\n\n")
        #expect(text.lowercased().contains("it is a truth universally acknowledged"))
        #expect(text.contains("his being gone to London"))
        #expect(!text.contains("The Project Gutenberg eBook of"))
        #expect(!text.contains("THE FULL PROJECT GUTENBERG"))
        let chapter2 = try #require(pride.chapters.first { $0.title == "CHAPTER II." })
        #expect(chapter2.text.hasPrefix("MR. BENNET was among"))
        #expect(!chapter2.text.hasPrefix("I hope Mr. Bingley"))
    }

    let quijoteURL = root.appendingPathComponent("cervantes-quijote.epub")
    if FileManager.default.fileExists(atPath: quijoteURL.path) {
        let quijote = try EPUBParser.parse(url: quijoteURL, fallbackTitle: "Fallback")
        #expect(quijote.title.contains("Quijote"))
        let text = quijote.chapters.map(\.text).joined(separator: "\n\n")
        #expect(text.contains("En un lugar de la Mancha"))
        #expect(!text.contains("Este archivo fue generado"))
        #expect(quijote.chapters.contains { $0.title == "Capítulo I" })
    }

    let aliceURL = root.appendingPathComponent("gutenberg-alice.epub")
    if FileManager.default.fileExists(atPath: aliceURL.path) {
        let alice = try EPUBParser.parse(url: aliceURL, fallbackTitle: "Fallback")
        #expect(alice.chapters.contains { $0.title == "Contents" })
        #expect(alice.chapters.filter { $0.title.hasPrefix("CHAPTER I.") }.count == 1)
    }

    let beowulfURL = root.appendingPathComponent("gutenberg-beowulf.epub")
    if FileManager.default.fileExists(atPath: beowulfURL.path) {
        let beowulf = try EPUBParser.parse(url: beowulfURL, fallbackTitle: "Fallback")
        #expect(!beowulf.title.contains("Project Gutenberg"))
    }

    let shakespeareURL = root.appendingPathComponent("gutenberg-shakespeare.epub")
    if FileManager.default.fileExists(atPath: shakespeareURL.path) {
        let shakespeare = try EPUBParser.parse(url: shakespeareURL, fallbackTitle: "Fallback")
        #expect(shakespeare.chapters.count > 500)
        #expect(shakespeare.chapters.count < 2_000)
    }
}

// MARK: - Every format

private func temporaryFormatFile(_ name: String, data: Data) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("NodusFormatTests", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("\(UUID().uuidString)-\(name)")
    try data.write(to: url)
    return url
}

@Test
func textImportJoinsWrappedLinesAndKeepsHeadingsListsAndVerse() throws {
    let source = """
    THE NODUS FORMAT TEST
    by Test Author

    CHAPTER I. A BEGINNING

    This is the first paragraph, hard-wrapped over
    three lines so the reader must join them into
    one paragraph.

    This is a second paragraph after a blank line.

    CHAPTER II. LISTS AND VERSES

    - First item
    - Second item
    - Third item

    The woods are lovely, dark and deep,
    But I have promises to keep,
    And miles to go before I sleep.

    Final paragraph with accents: áéíóú ñ ¿Qué? ¡Hola!
    """
    let url = try temporaryFormatFile("formats.txt", data: Data(source.utf8))
    defer { try? FileManager.default.removeItem(at: url) }

    let extraction = try DocumentExtractor.extract(url: url, format: .txt)
    let body = try #require(extraction.chapters.first).text
    #expect(body.contains("THE NODUS FORMAT TEST\n\nby Test Author"))
    #expect(body.contains("This is the first paragraph, hard-wrapped over three lines so the reader must join them into one paragraph."))
    #expect(body.contains("- First item\n- Second item\n- Third item"))
    #expect(body.contains("The woods are lovely, dark and deep,\nBut I have promises to keep"))
    #expect(body.contains("áéíóú ñ ¿Qué? ¡Hola!"))
}

@Test
func textImportDecodesWindows1252AndUTF16() throws {
    let cp1252 = "“Smart quotes” — dash, ñ, á, and €uro.\n\nSecond paragraph with ‘single quotes’."
    let cpData = try #require(cp1252.data(using: .windowsCP1252))
    let cpURL = try temporaryFormatFile("cp1252.txt", data: cpData)
    defer { try? FileManager.default.removeItem(at: cpURL) }

    let cpExtraction = try DocumentExtractor.extract(url: cpURL, format: .txt)
    let cpBody = try #require(cpExtraction.chapters.first).text
    #expect(cpBody.contains("“Smart quotes” — dash, ñ, á, and €uro."))
    #expect(cpBody.contains("Second paragraph with ‘single quotes’."))

    let utf16 = "UTF-16 title\n\nFirst paragraph in UTF-16 with accents áéíóú.\n\nSecond paragraph."
    let utf16Data = try #require(utf16.data(using: .utf16))
    let utf16URL = try temporaryFormatFile("utf16.txt", data: utf16Data)
    defer { try? FileManager.default.removeItem(at: utf16URL) }

    let utf16Extraction = try DocumentExtractor.extract(url: utf16URL, format: .txt)
    let utf16Body = try #require(utf16Extraction.chapters.first).text
    #expect(utf16Body.contains("UTF-16 title"))
    #expect(utf16Body.contains("First paragraph in UTF-16 with accents áéíóú."))
    #expect(!utf16Body.contains("ÿþ"))
    #expect(!utf16Body.contains("\0"))

    // Windows often writes UTF-16LE without a BOM.
    let noBOM = "No BOM title\n\nParagraph with áéíóú and ñ."
    let noBOMData = try #require(noBOM.data(using: .utf16LittleEndian))
    let noBOMURL = try temporaryFormatFile("utf16le.txt", data: noBOMData)
    defer { try? FileManager.default.removeItem(at: noBOMURL) }
    let noBOMExtraction = try DocumentExtractor.extract(url: noBOMURL, format: .txt)
    let noBOMBody = try #require(noBOMExtraction.chapters.first).text
    #expect(noBOMBody.contains("No BOM title"))
    #expect(noBOMBody.contains("Paragraph with áéíóú and ñ."))
}

@Test
func markdownImportStripsFrontMatterAndKeepsAutolinksAndFootnotes() throws {
    let source = """
    ---
    title: "Markdown fixture"
    author: Test Author
    ---

    # Main title

    First paragraph hard-wrapped over
    two source lines.

    ## A section

    - First item
    - Second item with **bold** and *italic*
      and a wrapped continuation.
    - [ ] A task item

    1. One
    2. Two

    > A quote that spans
    > two lines.
    >
    > A second quote paragraph.

    ```swift
    let value = "áéíóú"
    print(value)
    ```

    | Name | Value |
    | :--- | ---: |
    | Alpha | 1 |
    | Beta | 2 |

    A paragraph with a [link](https://example.com), an image ![Alt text](cover.png), an autolink <https://example.org>, and `code`.

    [reference]: https://example.com/ref
    [^1]: A footnote definition.

    ---

    Final paragraph after a rule.
    """
    let url = try temporaryFormatFile("formats.md", data: Data(source.utf8))
    defer { try? FileManager.default.removeItem(at: url) }

    let extraction = try DocumentExtractor.extract(url: url, format: .markdown)
    let body = try #require(extraction.chapters.first).text
    #expect(extraction.title == "Main title")
    #expect(!body.contains("title:"))
    #expect(!body.contains("author:"))
    #expect(body.contains("A quote that spans two lines.\n\nA second quote paragraph."))
    #expect(body.contains("• A task item"))
    #expect(body.contains("let value = \"áéíóú\"\nprint(value)"))
    #expect(body.contains("Name | Value\nAlpha | 1\nBeta | 2"))
    #expect(body.contains("an autolink https://example.org, and code."))
    #expect(body.contains("A footnote definition."))
    #expect(!body.contains(": A footnote definition."))
    #expect(!body.contains("```"))
    #expect(!body.contains("---"))
}

@Test
func htmlImportDecodesWindows1252AndKeepsListsTablesAndAutolinks() throws {
    let source = """
    <html><head><meta charset="windows-1252"><title>HTML fixture</title></head><body>
    <h1>HTML fixture</h1>
    <p>“Smart quotes” — dash, ñ, €uro.</p>
    <ul><li>First</li><li>Second</li></ul>
    <ol start="3"><li>Three</li><li>Four</li></ol>
    <table><tr><th>Name</th><th>Value</th></tr><tr><td>Alpha</td><td>1</td></tr><tr><td>Beta</td><td>2</td></tr></table>
    <p><a href="https://example.org">https://example.org</a></p>
    <footer>Footer must go.</footer><nav>Navigation must go.</nav>
    </body></html>
    """
    let data = try #require(source.data(using: .windowsCP1252))
    let url = try temporaryFormatFile("formats.html", data: data)
    defer { try? FileManager.default.removeItem(at: url) }

    let extraction = try DocumentExtractor.extract(url: url, format: .html)
    let body = try #require(extraction.chapters.first).text
    #expect(extraction.title == "HTML fixture")
    #expect(body.contains("“Smart quotes” — dash, ñ, €uro."))
    #expect(body.contains("• First\n• Second"))
    #expect(body.contains("3. Three\n4. Four"))
    #expect(body.contains("Name | Value\nAlpha | 1\nBeta | 2"))
    #expect(body.contains("https://example.org"))
    #expect(!body.contains("Footer must go."))
    #expect(!body.contains("Navigation must go."))
}

@Test
func rtfImportKeepsParagraphsAndUnicode() throws {
    let source = #"""
    {\rtf1\ansi\ansicpg1252\deff0
    {\fonttbl{\f0\froman Times New Roman;}{\f1\fswiss Arial;}}
    \f1\b\fs32 Format RTF Test\b0\fs24\par
    \par
    \f0 This is the first paragraph of the RTF fixture. It has \b bold text\b0  and \i italic text\i0 .\par
    This is the second paragraph with accents: \'e1\'e9\'ed\'f3\'fa and \u241? and \u8364?.\par
    \par
    \b A heading inside RTF\b0\par
    - First list item\par
    - Second list item\par
    \par
    Final paragraph with a table below.\par
    \trowd\cellx3000\cellx6000
    Alpha\cell 1\cell\row
    Beta\cell 2\cell\row
    }
    """#
    let url = try temporaryFormatFile("formats.rtf", data: Data(source.utf8))
    defer { try? FileManager.default.removeItem(at: url) }

    let extraction = try DocumentExtractor.extract(url: url, format: .rtf)
    let body = try #require(extraction.chapters.first).text
    #expect(body.contains("Format RTF Test\n\nThis is the first paragraph"))
    #expect(body.contains("italic text.\n\nThis is the second paragraph"))
    #expect(body.contains("áéíóú and ñ and €"))
    #expect(body.contains("A heading inside RTF\n\n- First list item"))
    #expect(body.contains("Alpha 1\n\nBeta 2"))
}

private func parserFormatCorpusPath() -> String? {
    let environment = ProcessInfo.processInfo.environment
    return environment["NODUS_FORMAT_CORPUS"]
        ?? environment["TEST_RUNNER_NODUS_FORMAT_CORPUS"]
}

@Test(.enabled(if: parserFormatCorpusPath() != nil))
func realFormatCorpusParsesCleanly() throws {
    let root = URL(fileURLWithPath: try #require(parserFormatCorpusPath()))

    let prideURL = root.appendingPathComponent("gutenberg-pride.txt")
    if FileManager.default.fileExists(atPath: prideURL.path) {
        let pride = try DocumentExtractor.extract(url: prideURL, format: .txt)
        let text = pride.chapters.map(\.text).joined(separator: "\n\n")
        #expect(text.lowercased().contains("it is a truth universally acknowledged"))
        #expect(!text.contains("*** START OF THE PROJECT GUTENBERG"))
        #expect(!text.contains("THE FULL PROJECT GUTENBERG"))
    }

    let rfcURL = root.appendingPathComponent("rfc9110.txt")
    if FileManager.default.fileExists(atPath: rfcURL.path) {
        let rfc = try DocumentExtractor.extract(url: rfcURL, format: .txt)
        let text = rfc.chapters.map(\.text).joined(separator: "\n\n")
        #expect(text.contains("HTTP Semantics"))
        #expect(text.contains("Fielding"))
    }

    let wikiURL = root.appendingPathComponent("wikipedia-gatsby.html")
    if FileManager.default.fileExists(atPath: wikiURL.path) {
        let wiki = try DocumentExtractor.extract(url: wikiURL, format: .html)
        #expect(wiki.title.contains("Great Gatsby"))
        #expect(wiki.chapters.map(\.text).joined(separator: "\n\n").contains("Jay Gatsby"))
    }
}

@Test
func textImportRecoversParagraphsWithoutBlankLines() throws {
    let source = """
    The Nodus Text
    by Test Author
    CHAPTER I
    This is the first paragraph, hard-wrapped over
    three lines so the reader must join them.
    This is the second paragraph of the same file.
    CHAPTER II
    Another paragraph that is long enough to be prose and should be separate from the chapter label.
    """
    let url = try temporaryFormatFile("no-blank-lines.txt", data: Data(source.utf8))
    defer { try? FileManager.default.removeItem(at: url) }

    let extraction = try DocumentExtractor.extract(url: url, format: .txt)
    let body = try #require(extraction.chapters.first).text
    #expect(body.contains("CHAPTER I\n\nThis is the first paragraph"))
    #expect(body.contains("must join them.\n\nThis is the second paragraph"))
    #expect(body.contains("CHAPTER II\n\nAnother paragraph"))
}

@Test
func markdownTitleSkipsFrontMatterAndCodeFences() throws {
    let source = """
    ---
    title: "Front matter"
    ---

    ```swift
    # this is a code comment
    ```

    # Real title

    Body paragraph.
    """
    let url = try temporaryFormatFile("title.md", data: Data(source.utf8))
    defer { try? FileManager.default.removeItem(at: url) }

    let extraction = try DocumentExtractor.extract(url: url, format: .markdown)
    #expect(extraction.title == "Real title")
    #expect(extraction.chapters.first?.text.contains("Body paragraph.") == true)
}

@Test
func textImportRejectsAnEmptyDocument() throws {
    let url = try temporaryFormatFile("empty.txt", data: Data())
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(throws: ImportError.self) {
        _ = try DocumentExtractor.extract(url: url, format: .txt)
    }
}


// MARK: - Scanned PDF layout

@MainActor
private func makeScannedPDF() throws -> URL {
    let size = CGSize(width: 1240, height: 1754)
    guard let bitmap = CGContext(data: nil, width: Int(size.width), height: Int(size.height),
                                 bitsPerComponent: 8, bytesPerRow: 0,
                                 space: CGColorSpaceCreateDeviceRGB(),
                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        throw ImportError.unreadableDocument("scanned page")
    }
    bitmap.translateBy(x: 0, y: size.height)
    bitmap.scaleBy(x: 1, y: -1)
    #if canImport(UIKit)
    UIGraphicsPushContext(bitmap)
    defer { UIGraphicsPopContext() }
    #else
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: bitmap, flipped: true)
    defer { NSGraphicsContext.restoreGraphicsState() }
    #endif
    do {
        bitmap.setFillColor(gray: 1, alpha: 1)
        bitmap.fill(CGRect(origin: .zero, size: size))
        let muted = PlatformColor(white: 0.35, alpha: 1)
        let header = "A GENERIC RUNNING HEADER"
        header.draw(at: CGPoint(x: 180, y: 55), withAttributes: [
            .font: PlatformFont.systemFont(ofSize: 24), .foregroundColor: muted
        ])
        "CHAPTER I".draw(at: CGPoint(x: 140, y: 190), withAttributes: [
            .font: PlatformFont.boldSystemFont(ofSize: 46), .foregroundColor: PlatformColor.black
        ])
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 12
        let body: [NSAttributedString.Key: Any] = [
            .font: PlatformFont.systemFont(ofSize: 29),
            .foregroundColor: PlatformColor.black,
            .paragraphStyle: paragraph
        ]
        ("This is the first paragraph, hard-wrapped over two lines so the reading "
         + "engine must join them.")
            .draw(in: CGRect(x: 140, y: 300, width: 960, height: 260), withAttributes: body)
        ("This is the second paragraph after a blank gap. It must stay a separate "
         + "paragraph from the first one.")
            .draw(in: CGRect(x: 140, y: 700, width: 960, height: 240), withAttributes: body)
        "1".draw(at: CGPoint(x: 610, y: 1650), withAttributes: [
            .font: PlatformFont.systemFont(ofSize: 24), .foregroundColor: muted
        ])
    }
    guard let cgImage = bitmap.makeImage() else { throw ImportError.unreadableDocument("scanned page") }
    let data = NSMutableData()
    var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
    guard let consumer = CGDataConsumer(data: data as CFMutableData),
          let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
        throw ImportError.unreadableDocument("scanned page")
    }
    context.beginPDFPage(nil)
    context.draw(cgImage, in: mediaBox)
    context.endPDFPage()
    context.closePDF()
    return try temporaryFormatFile("scanned-layout.pdf", data: data as Data)
}

@Test @MainActor
func scannedPDFJoinsParagraphsAndDoesNotPromoteBodyLinesToHeadings() async throws {
    let url = try makeScannedPDF()
    defer { try? FileManager.default.removeItem(at: url) }
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("NodusScannedStore-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = PDFReflowStore(fileStore: FileStore(root: root))
    let document = try await Task.detached(priority: .userInitiated) {
        try PDFReflowExtractor.extract(
            url: url, bookID: UUID(), contentHash: "scanned-layout",
            store: store, maxPages: 1
        )
    }.value
    #expect(document.usedOCR)
    let markdown = document.markdown()
    #expect(markdown.contains("CHAPTER I"))
    #expect(markdown.contains("This is the first paragraph, hard-wrapped over two lines so the reading engine must join them."))
    #expect(markdown.contains("This is the second paragraph after a blank gap."))
    #expect(!markdown.contains("# This is the first paragraph"))
    #expect(!markdown.contains("A GENERIC RUNNING HEADER"))
}

@Test
func textNormalizerHandlesSpanishPageLabelsAndOcrLookalikes() {
    #expect(TextNormalizer.isPageNumber("PÁGINA 8"))
    #expect(TextNormalizer.isPageNumber("Página 8 de 70"))
    #expect(TextNormalizer.isPageNumber("pág. 8"))
    #expect(TextNormalizer.repairLatinOCR("Presentación у objetivos") == "Presentación y objetivos")
    #expect(TextNormalizer.repairRomanOCR("Il. Marco teórico") == "II. Marco teórico")
    #expect(TextNormalizer.repairRomanOCR("INTRODUCCIÓN'") == "INTRODUCCIÓN")
}

@Test
func contentsEntryParsesOcrSplitPageNumbers() {
    #expect(PDFReflowExtractor.contentsEntry("3.1. Title .. 68", onContentsPage: true)
        == "3.1. Title · 68")
    #expect(PDFReflowExtractor.contentsEntry("CAPÍTULO V. ESPAÑA EN BLANCO Y NEGRO.70",
                                             onContentsPage: true)
        == "CAPÍTULO V. ESPAÑA EN BLANCO Y NEGRO · 70")
    #expect(PDFReflowExtractor.contentsEntry("Tabla 2. Corpus visual.41", onContentsPage: true)
        == "Tabla 2. Corpus visual · 41")
}
