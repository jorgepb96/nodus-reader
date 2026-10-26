// SPDX-License-Identifier: AGPL-3.0-only
import CoreGraphics
import CoreText
import Foundation
import PDFKit
import Testing
@testable import Nodus_Reader

// MARK: - Text helpers

@Test
func textNormalizerRepairsLigaturesAndPageNumbers() {
    #expect(TextNormalizer.cleanLine("e\u{FB00}ect and \u{FB01}ne") == "effect and fine")
    #expect(TextNormalizer.cleanLine("a\u{00A0}b\u{200B}c") == "a bc")
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
