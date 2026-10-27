// SPDX-License-Identifier: AGPL-3.0-only
import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import Vision
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// MARK: - Models

struct PDFReflowDocument: Codable, Sendable {
    /// 6: OCR fragments are merged before reading order, OCR headings use
    /// text/indent/spacing cues rather than raw box height, contents rows are
    /// rebuilt from columns, table pages are preserved as images, and front
    /// matter before a contents page is dropped when it is only cover copy.
    /// 5: blocks are reconstructed from font and baseline geometry, not only
    /// from line boxes. Contents and indexes keep one entry per line, running
    /// headers and feet are recognised by repetition and page numbers, and
    /// paragraphs that continue on the next page carry that relationship.
    static let schemaVersion = 6

    var version: Int = PDFReflowDocument.schemaVersion
    var contentHash: String
    var pageCount: Int
    var totalPageCount: Int
    var pages: [PDFReflowPage]
    var usedOCR: Bool
    var generatedAt: Date
}

struct PDFReflowPage: Codable, Identifiable, Sendable {
    var pageIndex: Int
    var width: CGFloat
    var height: CGFloat
    var blocks: [PDFReflowBlock]
    var regions: [PDFReflowRegion]

    var id: Int { pageIndex }
}

struct PDFReflowBlock: Codable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable {
        case heading1
        case heading2
        case body
        case quote
        case list
        case figure
        case tableImage
    }

    var id: UUID
    var kind: Kind
    var text: String
    var rect: CGRect          // normalized, top-left origin
    var pageIndex: Int
    var imageFileName: String?
    var isHeaderFooter: Bool
    var usedOCR: Bool
    /// Smaller type at the foot of a page, kept apart from the body. It is
    /// also marked `isHeaderFooter`, so narration skips it.
    var isFootnote: Bool = false
    /// The first body block of a page continues the last body block of the
    /// previous page. The text stays on its original page for narration and
    /// annotations; Markdown joins both halves.
    var continuesPrevious: Bool = false
    /// Dominant point size of the block. Used to tell footnotes and running
    /// heads from body text, and by the Markdown renderer.
    var fontSize: CGFloat = 0
    /// A figure or table caption. It is body text visually, but it must not
    /// absorb a paragraph that continues after the figure.
    var isCaption: Bool = false
}

struct PDFReflowRegion: Codable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable {
        case text
        case heading
        case table
        case figure
        case headerFooter
        case narrating
    }

    var id: UUID
    var kind: Kind
    var rect: CGRect
    var label: String
}

// MARK: - Cache

struct PDFReflowStore {
    let root: URL

    init(fileStore: FileStore = .shared) {
        root = fileStore.root.appendingPathComponent("Reflow", isDirectory: true)
    }

    func directory(for bookID: UUID) -> URL {
        root.appendingPathComponent(bookID.uuidString, isDirectory: true)
    }

    func manifestURL(for bookID: UUID) -> URL {
        directory(for: bookID).appendingPathComponent("manifest.json")
    }

    func imagesDirectory(for bookID: UUID) -> URL {
        directory(for: bookID).appendingPathComponent("images", isDirectory: true)
    }

    func imageURL(for bookID: UUID, name: String) -> URL {
        imagesDirectory(for: bookID).appendingPathComponent(name)
    }

    func load(bookID: UUID, contentHash: String) -> PDFReflowDocument? {
        guard let data = try? Data(contentsOf: manifestURL(for: bookID)),
              let document = try? JSONDecoder().decode(PDFReflowDocument.self, from: data),
              document.version == PDFReflowDocument.schemaVersion,
              document.contentHash == contentHash else { return nil }
        let images = imagesDirectory(for: bookID)
        let referenced = document.pages
            .flatMap(\.blocks)
            .compactMap(\.imageFileName)
        for name in referenced where !FileManager.default.fileExists(
            atPath: images.appendingPathComponent(name).path
        ) {
            return nil
        }
        return document
    }

    func save(_ document: PDFReflowDocument, bookID: UUID) throws {
        let directory = directory(for: bookID)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(document)
        try data.write(to: manifestURL(for: bookID), options: .atomic)
    }

    func remove(bookID: UUID) {
        try? FileManager.default.removeItem(at: directory(for: bookID))
    }

    func size(bookID: UUID) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: directory(for: bookID),
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]
        ) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true { total += Int64(values?.fileSize ?? 0) }
        }
        return total
    }
}

// MARK: - Extractor

enum PDFReflowExtractor {
    /// Extracts a reading-order representation without uploading the document.
    /// Text pages use PDFKit glyph bounds and font attributes; scanned pages
    /// use Vision OCR. Tables and text-less pages are preserved as images.
    static func extract(url: URL, bookID: UUID, contentHash: String,
                        store: PDFReflowStore,
                        maxPages: Int = 400,
                        progress: (@Sendable (Double) -> Void)? = nil,
                        hyphenation: HyphenationResolver = .system) throws -> PDFReflowDocument {
        guard let document = PDFDocument(url: url) else {
            throw ImportError.unreadableDocument(url.lastPathComponent)
        }
        let limit = min(document.pageCount, max(1, maxPages))
        guard limit > 0 else { throw ImportError.emptyDocument(url.lastPathComponent) }

        let imagesDirectory = store.imagesDirectory(for: bookID)
        try? FileManager.default.removeItem(at: imagesDirectory)
        try FileManager.default.createDirectory(at: imagesDirectory, withIntermediateDirectories: true)

        var pageData: [PageData] = []
        var usedOCR = false

        // First pass: read every text layer (and OCR the pages that need it)
        // once. The font profile is document-wide, so a title page cannot
        // redefine what "body text" means for the rest of the book.
        for index in 0..<limit {
            try Task.checkCancellation()
            guard let page = document.page(at: index) else { continue }
            let bounds = page.bounds(for: .cropBox)
            guard bounds.width > 1, bounds.height > 1 else { continue }

            var lines = mergeLineFragments(textLines(page: page, bounds: bounds), bounds: bounds)
            var ocrPage = false
            let bodyForGarble = lines.filter { !$0.marginal }.map(\.text).joined(separator: " ")
            let garbled = PDFPageText.isGarbled(bodyForGarble)
            let shortBody = bodyForGarble.count < 80
            if lines.count < 3 || garbled || shortBody {
                let ocr = (try? visionLines(page: page, bounds: bounds)) ?? []
                let mergedOCR = mergeLineFragments(ocr, bounds: bounds)
                if !mergedOCR.isEmpty, garbled || shortBody || mergedOCR.count > lines.count {
                    lines = mergedOCR
                    ocrPage = true
                    usedOCR = true
                } else if garbled {
                    lines = []
                }
            }
            pageData.append(PageData(index: index, bounds: bounds, lines: lines, usedOCR: ocrPage))
            progress?(0.45 * Double(index + 1) / Double(limit))
        }

        let profile = LayoutProfile.make(from: pageData)
        var pages: [PDFReflowPage] = []
        var contents = ContentsState()

        for data in pageData {
            try Task.checkCancellation()
            guard let page = document.page(at: data.index) else { continue }
            var builder = PageBuilder(index: data.index, bounds: data.bounds, page: page,
                                      profile: profile, hyphenation: hyphenation,
                                      contents: contents)
            let built = builder.build(from: data.lines, usedOCR: data.usedOCR,
                                      imagesDirectory: imagesDirectory)
            contents = builder.contents
            pages.append(built)
            progress?(0.45 + 0.50 * Double(data.index + 1) / Double(max(1, pageData.count)))
        }

        markParagraphContinuations(in: &pages)
        markColumnContinuations(in: &pages)
        markHeadersAndFooters(in: &pages, profile: profile)
        markFrontMatter(in: &pages)

        let result = PDFReflowDocument(contentHash: contentHash, pageCount: limit,
                                       totalPageCount: document.pageCount,
                                       pages: pages, usedOCR: usedOCR, generatedAt: Date())
        try store.save(result, bookID: bookID)
        progress?(1)
        return result
    }

    // MARK: Contents helpers

    /// A table-of-contents entry with dot leaders and a page number, or (on a
    /// contents page) a title followed by a page number. The dot leaders are
    /// replaced by a middle dot so the reader never displays "......".
    static func contentsEntry(_ text: String, onContentsPage: Bool) -> String? {
        let value = TextNormalizer.cleanLine(text)
        guard !value.isEmpty, value.count <= 220, !TextNormalizer.isPageNumber(value) else { return nil }
        let pattern = #"^(.*?\S)\s*(?:(?:\.\s?){2,}|…+|_{2,})\s*(\d{1,4}|[ivxlcdmIVXLCDM]{1,6})$"#
        if let match = value.range(of: pattern, options: .regularExpression) {
            let line = String(value[match])
            let title = line.replacingOccurrences(
                of: #"\s*(?:(?:\.\s?){2,}|…+|_{2,})\s*(\d{1,4}|[ivxlcdmIVXLCDM]{1,6})$"#,
                with: "", options: .regularExpression
            )
            let number = line.range(of: #"(\d{1,4}|[ivxlcdmIVXLCDM]{1,6})$"#, options: .regularExpression)
                .map { String(line[$0]) } ?? ""
            return "\(title.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: #"[.\s]+$"#, with: "")) · \(number)"
        }
        if onContentsPage,
           let match = value.range(of: #"^(.*\S)\.(\d{1,4})$"#, options: .regularExpression) {
            let line = String(value[match])
            let number = line.range(of: #"\d{1,4}$"#, options: .regularExpression)
                .map { String(line[$0]) } ?? ""
            let title = line.replacingOccurrences(of: #"\.\d{1,4}$"#, with: "",
                                                   options: .regularExpression)
                .trimmingCharacters(in: CharacterSet(charactersIn: " ."))
            if !title.isEmpty, !number.isEmpty { return "\(title.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: #"[.\s]+$"#, with: "")) · \(number)" }
        }
        if onContentsPage,
           let match = value.range(of: #"^(.*\D)\s+(\d{1,4}|[ivxlcdmIVXLCDM]{1,6})$"#, options: .regularExpression) {
            let line = String(value[match])
            let number = line.range(of: #"(\d{1,4}|[ivxlcdmIVXLCDM]{1,6})$"#, options: .regularExpression)
                .map { String(line[$0]) } ?? ""
            let title = line.replacingOccurrences(
                of: #"\s+(\d{1,4}|[ivxlcdmIVXLCDM]{1,6})$"#, with: "", options: .regularExpression
            )
            return "\(title.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: #"[.\s]+$"#, with: "")) · \(number)"
        }
        return nil
    }

    /// "Markdown 4, 7, 9" or "paragraph 4-5" in an index.
    static func indexEntry(_ text: String) -> String? {
        let value = TextNormalizer.cleanLine(text)
        guard !value.isEmpty, value.count <= 220, !TextNormalizer.isPageNumber(value) else { return nil }
        let pattern = #"^(.+?)\s+((?:\d{1,4}(?:\s*[-,–]\s*\d{1,4})?)(?:\s*,\s*\d{1,4}(?:\s*[-,–]\s*\d{1,4})?)*)$"#
        guard let match = value.range(of: pattern, options: .regularExpression) else { return nil }
        let line = String(value[match])
        guard let numberRange = line.range(of: #"\s+\d{1,4}.*$"#, options: .regularExpression) else {
            return nil
        }
        let title = String(line[..<numberRange.lowerBound]).trimmingCharacters(in: .whitespaces)
        let numbers = String(line[numberRange]).trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty, title.count <= 80 else { return nil }
        return "\(title) · \(numbers)"
    }

    static func isContentsHeading(_ text: String) -> Bool {
        let value = TextNormalizer.cleanLine(text).lowercased()
        guard value.count <= 40 else { return false }
        return value.range(
            of: #"^(table of contents|contents|contenido|contenidos|índice|indice|índice de figuras|índice de tablas|indice de figuras|indice de tablas|list of figures|list of tables|sommaire|inhalt)$"#,
            options: .regularExpression
        ) != nil
    }

    static func isIndexHeading(_ text: String) -> Bool {
        let value = TextNormalizer.cleanLine(text).lowercased()
        guard value.count <= 40 else { return false }
        return value.range(
            of: #"^(index|índice|indice|subject index|onomastic index|índice de figuras|índice de tablas|indice de figuras|indice de tablas|list of figures|list of tables)$"#,
            options: .regularExpression
        ) != nil
    }

    /// A conservative table-of-contents test used to decide whether a page is
    /// a contents page before any context exists. A line that merely ends in a
    /// year ("En 1615") is not an entry; numbered entries, dot leaders and
    /// chapter/appendix labels are.
    private static func strongContentsEntry(_ line: Line) -> Bool {
        let text = line.text
        if text.range(of: #"^(.*?\S)\s*(?:(?:\.\s?){2,}|…+|\_{2,})\s*(\d{1,4}|[ivxlcdmIVXLCDM]{1,6})$"#,
                      options: .regularExpression) != nil {
            return true
        }
        if text.range(of: #"^\s*(?:\d{1,3}(?:\.\d+)*\.?|[IVXLC]{1,6}\.)\s+\p{Lu}"#,
                      options: .regularExpression) != nil {
            return true
        }
        if text.range(of: #"^\s*(chapter|part|appendix|section|capítulo|parte|apéndice)\s+(?:\d+|[IVXLC]+)\b"#,
                      options: [.regularExpression, .caseInsensitive]) != nil {
            return true
        }
        if text.range(of: #"^\s*\d{1,3}\s+\p{Lu}"#, options: .regularExpression) != nil,
           text.count < 90 {
            return true
        }
        return false
    }

    private static func isContentsEntryStart(_ line: Line, previous: Line?, indexMode: Bool) -> Bool {
        let text = line.text
        if contentsEntry(text, onContentsPage: true) != nil { return true }
        if text.range(of: #"^\s*(?:\d{1,3}(?:\.\d+)*\.?|[IVXLC]{1,6}\.)\s+\S"#,
                      options: .regularExpression) != nil {
            return true
        }
        if indexMode, indexEntry(text) != nil { return true }
        guard let previous else { return false }
        // An unnumbered entry starts at the left margin; a wrapped title is
        // indented under it.
        return line.rect.minX <= previous.rect.minX + 0.012 && line.text.count <= 120
    }

    // MARK: Line helpers

    private static func headingLevel(for line: Line, profile: LayoutProfile,
                                     previous: Line? = nil) -> Int? {
        let text = TextNormalizer.cleanLine(line.text)
        guard !text.isEmpty, text.count <= 140, !TextNormalizer.isPageNumber(text) else { return nil }
        if line.isVertical { return nil }
        if line.marginal, line.rect.maxY > 0.90 || line.rect.minY < 0.06 { return nil }

        let ratio = line.fontSize / max(profile.bodyFontSize, 1)
        let wordCount = text.split(whereSeparator: \.isWhitespace).count
        let numbered = text.range(
            of: #"^\s*(?:\d{1,3}(?:\.\d+)*\.|[IVXLC]{1,6}\.)\s+\S"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
        let known = text.first?.isUppercase == true && text.range(
            of: #"^(abstract|introduction|conclusion|conclusions|contents|table of contents|index|references|bibliography|appendix|preface|foreword|acknowledg|summary|overview|background|methods|methodology|materials|results|discussion|related work|resumen|índice|introducción|conclusión|conclusiones|referencias|bibliografía|apéndice|prefacio|prólogo|capítulo|chapter|part|section)\b"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
        let allCaps = text.count >= 3
            && text == text.uppercased()
            && text.rangeOfCharacter(from: .letters) != nil
        let caption = isCaption(text)
        let endsSentence = text.last.map { ".!?;".contains($0) } ?? false
        let sentenceLike = endsSentence && wordCount > 8
        let shortBold = line.isBold && text.count <= 80 && wordCount <= 12
        let romanHeading = text.range(of: #"^[IVXLC]{1,6}$"#, options: .regularExpression) != nil
        if line.isOCR {
            // OCR line boxes vary with accents and merged fragments. Font
            // height is not reliable enough to promote a body line to a
            // heading. Prefer textual cues and a deliberate indented section
            // title; use size only as a secondary signal.
            let bottom = line.rect.minY > 0.80 || line.rect.maxY < 0.08
            let strongIndent = line.rect.minX > profile.bodyLeft + 0.070
            let separated = previous.map {
                line.rect.minY - $0.rect.maxY >= profile.bodyLead * 1.15
            } ?? strongIndent
            let textCue = allCaps || numbered || known || romanHeading
            let sectionCue = !bottom && separated
                && text.count <= 80 && wordCount <= 12
                && !endsSentence && !caption
                && line.rect.minX > profile.bodyLeft + 0.045
                && ratio >= 1.15
            let bigCue = !bottom && separated
                && text.count <= 80 && !sentenceLike && !caption
                && ratio >= 1.40
            guard textCue || sectionCue || bigCue else { return nil }
            if textCue && bottom { return nil }
            return (textCue || bigCue) ? 1 : 2
        }
        let heading = !caption && !sentenceLike
            && (ratio >= 1.12 || numbered || known || (allCaps && text.count <= 80) || shortBold || romanHeading)
        guard heading else { return nil }

        let numberedNoDot = numbered
            && text.range(of: #"^\s*\d{1,2}\s+\S"#, options: .regularExpression) != nil
        let topLevel = ratio >= 1.25
            || (known && ratio >= 1.05)
            || (numbered && text.range(of: #"^\s*\d{1,2}\.\s"#, options: .regularExpression) != nil)
            || (numberedNoDot && (ratio >= 1.03 || line.isBold))
            || (allCaps && ratio >= 1.10)
            || romanHeading
        return topLevel ? 1 : 2
    }

    private static func isCaption(_ text: String) -> Bool {
        text.range(of: #"^(figure|table|fig\.|tabla|figura|graph|chart|map|plate)\s+\d"#,
                   options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func isNoise(_ line: Line) -> Bool {
        let text = TextNormalizer.cleanLine(line.text)
        guard !text.isEmpty else { return true }
        let letters = text.filter { $0.isLetter }.count
        let digits = text.filter { $0.isNumber }.count
        if line.isOCR, letters == 0, digits == 0, text.count <= 12 { return true }
        if line.isOCR, letters == 0, digits <= 1,
           text.range(of: #"^[\s\-–—•·.]+0?[\s\-–—•·.]*$"#, options: .regularExpression) != nil {
            return true
        }
        if line.isOCR, letters <= 2, digits == 0, text.count <= 6 { return true }
        return false
    }

    private static func isBullet(_ text: String) -> Bool {
        text.range(of: #"^\s*(?:[-*•+]|\d{1,2}[.)])\s+\S"#, options: .regularExpression) != nil
    }

    private static func bulletText(_ text: String) -> String {
        text.replacingOccurrences(of: #"^\s*[-*•+]\s+"#, with: "", options: .regularExpression)
    }

    private static func isQuote(_ text: String) -> Bool {
        text.range(of: #"^\s*>\s?"#, options: .regularExpression) != nil
    }

    private static func quoteText(_ text: String) -> String {
        text.replacingOccurrences(of: #"^\s*>\s?"#, with: "", options: .regularExpression)
    }

    private static func endsParagraph(_ text: String) -> Bool {
        guard let last = text.trimmingCharacters(in: .whitespacesAndNewlines).last else { return false }
        return ".!?…:;\"”’»".contains(last)
    }

    private static func startsNewParagraph(_ line: Line, after previous: Line,
                                           paragraphStartX: CGFloat,
                                           profile: LayoutProfile) -> Bool {
        if line.rect.minY < previous.rect.minY - 0.004 { return true }
        if let first = line.text.first, ")]},.;:".contains(first) { return false }
        if let last = previous.text.last, "([{".contains(last) { return false }
        // A line that returns to the paragraph's left margin is a wrapped
        // line, even when the previous fragment was a URL that PDFKit placed
        // to the right. A line that starts at another column is a new block.
        if abs(line.rect.minX - paragraphStartX) > 0.09 {
            let sameOCRLine = line.isOCR && previous.isOCR
                && line.rect.minX > paragraphStartX
                && !endsParagraph(previous.text)
                && abs(line.baseline - previous.baseline) <= max(profile.bodyLead * 1.2, 0.012)
            if !sameOCRLine { return true }
        }
        if previous.text.hasSuffix("-"), !previous.text.hasSuffix("--"),
           line.text.first?.isLowercase == true {
            return false
        }
        let delta = line.baseline - previous.baseline
        if delta < 0 { return true }
        if delta > profile.bodyLead * 1.45 { return true }
        if !line.isOCR, !previous.isOCR,
           abs(line.fontSize - previous.fontSize) > 0.8 { return true }
        if line.rect.minX > previous.rect.minX + 0.018, endsParagraph(previous.text) {
            return true
        }
        return false
    }

    private static func isMarginPageNumber(_ line: Line) -> Bool {
        guard line.text.count <= 8,
              TextNormalizer.isBarePageNumber(line.text) || TextNormalizer.isPageNumber(line.text)
        else { return false }
        return line.rect.minX > 0.85 || line.rect.maxX < 0.15
    }

    private static func definiteMarginal(_ line: Line) -> Bool {
        if line.isVertical { return true }
        if TextNormalizer.isPageNumber(line.text), line.text.count <= 80 { return true }
        if line.text.count <= 8, TextNormalizer.isBarePageNumber(line.text),
           line.rect.minY < 0.08 || line.rect.maxY > 0.84 { return true }
        guard line.text.count <= 120 else { return false }
        // A sentence that begins at the top of a page (a paragraph that
        // continues from the previous page) is body, not a running head.
        if line.text.first?.isLowercase == true { return false }
        return line.rect.minY < 0.05 || line.rect.maxY > 0.95
    }

    private static func marginalCandidate(_ line: Line) -> Bool {
        if line.isVertical { return true }
        if TextNormalizer.isPageNumber(line.text), line.text.count <= 80 { return true }
        if line.text.count <= 8, TextNormalizer.isBarePageNumber(line.text),
           line.rect.minY < 0.08 || line.rect.maxY > 0.84 { return true }
        if line.text.count > 160 { return false }
        return line.rect.minY < 0.10 || line.rect.maxY > 0.90
    }

    private static func looksTabular(_ text: String) -> Bool {
        let numeric = text.split(whereSeparator: { $0 == " " || $0 == "\t" })
            .filter { $0.rangeOfCharacter(from: .decimalDigits) != nil }
        let runs = text.components(separatedBy: "  ")
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return numeric.count >= 3 || runs.count >= 4
    }

    // MARK: Page data

    private struct PageData {
        var index: Int
        var bounds: CGRect
        var lines: [Line]
        var usedOCR: Bool
    }

    private struct LayoutProfile {
        var bodyFontSize: CGFloat
        var bodyLead: CGFloat
        var medianHeight: CGFloat
        var bodyLeft: CGFloat

        static func make(from pages: [PageData]) -> LayoutProfile {
            let ocrLines = pages.flatMap { page in
                page.lines.filter { page.usedOCR && !marginalCandidate($0) }
            }
            var bodySize: CGFloat
            if ocrLines.count >= 40 {
                // Vision does not expose font sizes. Use the median of the
                // per-line bounding heights; a single tall accented line must
                // not redefine "body".
                bodySize = median(ocrLines.map(\.fontSize)) ?? 12
            } else {
                var sizes: [Int: Int] = [:]
                for page in pages {
                    for line in page.lines where !marginalCandidate(line) {
                        let key = Int((line.fontSize * 2).rounded())
                        sizes[key, default: 0] += max(1, line.text.count)
                    }
                }
                let bodyKey = sizes.max { $0.value < $1.value }?.key ?? 21
                bodySize = CGFloat(bodyKey) / 2
            }

            var deltas: [CGFloat] = []
            for page in pages {
                let bodyLines = page.lines
                    .filter { !marginalCandidate($0) && (page.usedOCR || abs($0.fontSize - bodySize) < 1.2) }
                    .sorted { $0.rect.minY < $1.rect.minY }
                for pair in zip(bodyLines, bodyLines.dropFirst()) {
                    let delta = pair.1.baseline - pair.0.baseline
                    if delta > 0.004, delta < 0.06 { deltas.append(delta) }
                }
            }
            let lead = median(deltas) ?? 0.018
            let heights = pages.flatMap(\.lines)
                .filter { !marginalCandidate($0) }
                .map(\.height)
                .filter { $0 > 0 }
            let lefts = pages.flatMap(\.lines)
                .filter { !marginalCandidate($0) && (pages.contains(where: { $0.usedOCR }) || abs($0.fontSize - bodySize) < 1.2) }
                .map(\.rect.minX)
            return LayoutProfile(bodyFontSize: bodySize, bodyLead: lead,
                                 medianHeight: median(heights) ?? 0.018,
                                 bodyLeft: median(lefts) ?? 0.10)
        }
    }

    private struct ContentsState {
        var active = false
        var index = false
    }

    // MARK: Lines

    private struct Line {
        var text: String
        var rect: CGRect      // normalized, top-left origin
        var height: CGFloat   // normalized height
        var rawRect: CGRect   // page coordinates (points)
        var rawBounds: CGRect
        /// Normalized distance from the top of the page to the line's bottom.
        /// Consecutive baselines are more stable than line boxes when a line
        /// contains a superscript or a formula.
        var baseline: CGFloat
        var fontSize: CGFloat
        var isBold: Bool
        var isItalic: Bool
        var fontName: String
        var isVertical: Bool
        var marginal: Bool
        var isOCR: Bool
    }

    private struct StyledLine {
        var text: String
        var fontSize: CGFloat
        var isBold: Bool
        var isItalic: Bool
        var fontName: String
    }

    private static func textLines(page: PDFPage, bounds: CGRect) -> [Line] {
        guard let string = page.string, !string.isEmpty else { return [] }
        let ns = string as NSString
        var lines: [Line] = []
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length),
                               options: [.byLines, .substringNotRequired]) { _, range, _, _ in
            var start = range.location
            var end = NSMaxRange(range)
            while start < end, isWhitespace(ns.character(at: start)) { start += 1 }
            while end > start, isWhitespace(ns.character(at: end - 1)) { end -= 1 }
            guard start < end else { return }
            let trimmedRange = NSRange(location: start, length: end - start)
            guard let selection = page.selection(for: trimmedRange) else { return }
            let lineBounds = selection.bounds(for: page)
            guard lineBounds.width > 1, lineBounds.height > 1 else { return }
            let styled = styledLine(selection.attributedString)
            let text = TextNormalizer.cleanLine(styled?.text ?? ns.substring(with: trimmedRange))
            guard !text.isEmpty, !isOnlyImageMarker(text) else { return }
            let normalized = normalize(lineBounds, in: bounds)
            let baseline = 1 - (lineBounds.minY - bounds.minY) / bounds.height
            let fontSize = styled?.fontSize ?? max(6, normalized.height * bounds.height * 0.8)
            let vertical = normalized.height > normalized.width * 2.2 && text.count > 12
            let marginal = vertical || marginalCandidate(text: text, rect: normalized)
            lines.append(Line(text: text, rect: normalized, height: normalized.height,
                              rawRect: normalizeRaw(lineBounds, in: bounds),
                              rawBounds: lineBounds, baseline: baseline,
                              fontSize: fontSize,
                              isBold: styled?.isBold ?? false,
                              isItalic: styled?.isItalic ?? false,
                              fontName: styled?.fontName ?? "",
                              isVertical: vertical,
                              marginal: marginal,
                              isOCR: false))
        }
        return lines
    }

    /// PDFKit sometimes enumerates one visual line as several fragments when a
    /// font changes in the middle ("application-level" + "protocol for
    /// distributed,"). Join fragments with the same baseline and a small gap,
    /// but leave a wide gutter (two columns, a table cell) alone.
    private static func mergeLineFragments(_ input: [Line], bounds: CGRect) -> [Line] {
        guard input.count > 1 else { return input }
        let baseGap = max(12, bounds.width * 0.02)
        var merged: [Line] = []
        let ordered = input.sorted {
            if abs($0.baseline - $1.baseline) > 0.0005 { return $0.baseline < $1.baseline }
            return $0.rect.minX < $1.rect.minX
        }
        for line in ordered {
            if let index = merged.firstIndex(where: { candidate in
                guard !candidate.isVertical, !line.isVertical else { return false }
                let gap = max(line.rect.minX - candidate.rect.maxX,
                              candidate.rect.minX - line.rect.maxX) * bounds.width
                let allowedGap = line.isOCR ? max(baseGap, bounds.width * 0.05) : baseGap
                let tolerance: CGFloat = line.isOCR ? 0.008 : 0.0035
                return gap <= allowedGap && abs(candidate.baseline - line.baseline) <= tolerance
            }) {
                var target = merged[index]
                let targetIsLeft = target.rect.minX <= line.rect.minX
                let left = targetIsLeft ? target : line
                let right = targetIsLeft ? line : target
                let gap = (right.rect.minX - left.rect.maxX) * bounds.width
                let text: String
                if line.isOCR || gap > 1.5 {
                    text = TextNormalizer.joinLines([left.text, right.text])
                } else {
                    text = TextNormalizer.cleanLine(left.text + right.text)
                }
                target.text = text
                target.rect = target.rect.union(line.rect)
                target.height = max(target.height, line.height)
                target.fontSize = (target.fontSize + line.fontSize) / 2
                target.isOCR = target.isOCR || line.isOCR
                target.isBold = target.isBold && line.isBold
                target.isItalic = target.isItalic && line.isItalic
                target.marginal = target.marginal || line.marginal
                target.baseline = min(target.baseline, line.baseline)
                target.rawRect = target.rawRect.union(line.rawRect)
                target.rawBounds = target.rawBounds.union(line.rawBounds)
                merged[index] = target
            } else {
                merged.append(line)
            }
        }
        return merged
    }

    /// A PDFKit line can span two columns or a sidebar on the same baseline
    /// ("article text    infobox label"). Split it at a wide horizontal gap so
    /// the reading order does not interleave unrelated text.
    private static func isWhitespace(_ unit: unichar) -> Bool {
        guard let scalar = UnicodeScalar(unit) else { return false }
        return CharacterSet.whitespacesAndNewlines.contains(scalar)
    }

    /// The line without footnote reference marks and with its dominant font.
    /// Digits, asterisks and daggers set clearly smaller than the line's text
    /// ("sociedad¹²") are dropped; narration would read them as numbers in the
    /// middle of a sentence.
    private static func styledLine(_ attributed: NSAttributedString?) -> StyledLine? {
        guard let attributed, attributed.length > 0 else { return nil }
        var sizeCounts: [CGFloat: Int] = [:]
        attributed.enumerateAttribute(.font, in: NSRange(location: 0, length: attributed.length)) { value, range, _ in
            guard let font = value as? PlatformFont else { return }
            sizeCounts[font.pointSize, default: 0] += range.length
        }
        guard let bodySize = sizeCounts.max(by: { $0.value < $1.value })?.key, bodySize > 0 else {
            return nil
        }

        var result = ""
        var keptSizeCounts: [CGFloat: Int] = [:]
        var nameCounts: [String: Int] = [:]
        var bold = 0
        var italic = 0
        var kept = 0
        let ns = attributed.string as NSString
        attributed.enumerateAttribute(.font, in: NSRange(location: 0, length: attributed.length)) { value, range, _ in
            let piece = ns.substring(with: range)
            let trimmed = piece.trimmingCharacters(in: .whitespaces)
            let isReferenceMark = trimmed.allSatisfy { $0.isNumber || "*†‡§,".contains($0) }
                || (trimmed.count == 1 && trimmed.first?.isLetter == true)
            if let font = value as? PlatformFont, font.pointSize < bodySize * 0.8,
               isReferenceMark, !trimmed.isEmpty {
                return
            }
            result += piece
            let length = max(1, range.length)
            kept += length
            if let font = value as? PlatformFont {
                keptSizeCounts[font.pointSize, default: 0] += length
                nameCounts[font.fontName, default: 0] += length
                let traits = font.fontDescriptor.symbolicTraits
                #if os(macOS)
                if traits.contains(.bold) { bold += length }
                if traits.contains(.italic) { italic += length }
                #else
                if traits.contains(.traitBold) { bold += length }
                if traits.contains(.traitItalic) { italic += length }
                #endif
            }
        }
        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let dominantSize = keptSizeCounts.max(by: { $0.value < $1.value })?.key ?? bodySize
        let dominantName = nameCounts.max(by: { $0.value < $1.value })?.key ?? ""
        let lowerName = dominantName.lowercased()
        return StyledLine(
            text: trimmed,
            fontSize: dominantSize,
            isBold: bold > kept / 2 || lowerName.contains("bold") || lowerName.contains("black"),
            isItalic: italic > kept / 2 || lowerName.contains("italic") || lowerName.contains("oblique"),
            fontName: dominantName
        )
    }

    private static func visionLines(page: PDFPage, bounds: CGRect) throws -> [Line] {
        try PDFPageText.recognizeLines(page: page).compactMap { recognized -> Line? in
            let text = TextNormalizer.cleanLine(
                TextNormalizer.repairRomanOCR(TextNormalizer.repairLatinOCR(recognized.text))
            )
            guard !text.isEmpty, !isOnlyImageMarker(text) else { return nil }
            let box = recognized.box // normalized, bottom-left origin
            let normalized = CGRect(x: box.minX, y: 1 - box.maxY,
                                    width: box.width, height: box.height)
            let raw = CGRect(x: bounds.minX + box.minX * bounds.width,
                             y: bounds.minY + box.minY * bounds.height,
                             width: box.width * bounds.width,
                             height: box.height * bounds.height)
            let fontSize = max(6, normalized.height * bounds.height * 0.85)
            return Line(text: text, rect: normalized, height: normalized.height,
                        rawRect: raw, rawBounds: raw, baseline: normalized.maxY,
                        fontSize: fontSize, isBold: false, isItalic: false,
                        fontName: "", isVertical: false,
                        marginal: marginalCandidate(text: text, rect: normalized),
                        isOCR: true)
        }
    }

    private static func isOnlyImageMarker(_ text: String) -> Bool {
        !text.isEmpty && text.allSatisfy { $0 == "\u{FFFC}" || $0.isWhitespace }
    }

    private static func marginalCandidate(text: String, rect: CGRect) -> Bool {
        if TextNormalizer.isPageNumber(text), text.count <= 80 { return true }
        if text.count <= 8, TextNormalizer.isBarePageNumber(text),
           rect.minY < 0.08 || rect.maxY > 0.84 { return true }
        guard text.count <= 160 else { return false }
        return rect.minY < 0.10 || rect.maxY > 0.90
    }

    // MARK: Page → blocks

    private struct PageBuilder {
        let index: Int
        let bounds: CGRect
        let page: PDFPage
        let profile: LayoutProfile
        let hyphenation: HyphenationResolver
        var contents: ContentsState
        var blocks: [PDFReflowBlock] = []
        var regions: [PDFReflowRegion] = []

        init(index: Int, bounds: CGRect, page: PDFPage, profile: LayoutProfile,
             hyphenation: HyphenationResolver, contents: ContentsState) {
            self.index = index
            self.bounds = bounds
            self.page = page
            self.profile = profile
            self.hyphenation = hyphenation
            self.contents = contents
        }

        mutating func build(from lines: [Line], usedOCR: Bool,
                            imagesDirectory: URL) -> PDFReflowPage {
            guard !lines.isEmpty else {
                return imagePage(usedOCR: usedOCR, imagesDirectory: imagesDirectory)
            }
            let substantive = lines.filter {
                !PDFReflowExtractor.definiteMarginal($0) && !PDFReflowExtractor.isNoise($0)
            }
            let substantiveText = substantive.map(\.text).joined(separator: " ")
            if substantiveText.count < 25, substantive.count <= 2 {
                return emptyPage(usedOCR: usedOCR)
            }
            let ordered = readingOrder(lines, pageWidth: bounds.width)
            let contentsHeadingIndex = ordered.firstIndex {
                PDFReflowExtractor.isContentsHeading($0.text) || PDFReflowExtractor.isIndexHeading($0.text)
            }
            let tocLike = ordered.filter {
                PDFReflowExtractor.strongContentsEntry($0)
            }.count
            let longProse = ordered.filter {
                $0.text.count > 70 && PDFReflowExtractor.endsParagraph($0.text)
            }.count
            let startsContents = contentsHeadingIndex != nil || (tocLike >= 4 && longProse == 0)
            let isContentsPage = contents.active
                ? ((startsContents || tocLike >= 2) && longProse <= 1)
                : startsContents

            if isContentsPage {
                contents.active = true
                if let headingIndex = contentsHeadingIndex,
                   PDFReflowExtractor.isIndexHeading(ordered[headingIndex].text) {
                    contents.index = true
                }
                let split = contentsSplitIndex(in: ordered, contentsHeadingIndex: contentsHeadingIndex)
                let headingStart = contentsHeadingIndex ?? 0
                if headingStart > 0 {
                    appendNormal(Array(ordered[..<headingStart]), usedOCR: usedOCR)
                }
                if ordered.contains(where: \.isOCR) {
                    // The row parser also recognises a sentence below an index
                    // heading; do not let the line-based splitter discard the
                    // first entries after the heading.
                    appendOCRContents(Array(ordered[headingStart...]), usedOCR: usedOCR)
                } else {
                    appendContents(Array(ordered[headingStart..<split]), usedOCR: usedOCR)
                    if split < ordered.count {
                        contents.active = false
                        contents.index = false
                        appendNormal(Array(ordered[split...]), usedOCR: usedOCR)
                    }
                }
            } else {
                contents.active = false
                contents.index = false
                appendNormal(ordered, usedOCR: usedOCR)
            }

            replaceFigureRegions(usedOCR: usedOCR, imagesDirectory: imagesDirectory)
            replaceTables(ordered: ordered, usedOCR: usedOCR, imagesDirectory: imagesDirectory)
            return PDFReflowPage(pageIndex: index, width: bounds.width, height: bounds.height,
                                 blocks: blocks, regions: regions)
        }

        private func contentsSplitIndex(in lines: [Line], contentsHeadingIndex: Int?) -> Int {
            let start = (contentsHeadingIndex ?? -1) + 1
            guard start < lines.count else { return lines.count }
            for index in start..<lines.count {
                let line = lines[index]
                if line.text.count > 70,
                   PDFReflowExtractor.endsParagraph(line.text),
                   !PDFReflowExtractor.isContentsEntryStart(line, previous: nil,
                                                           indexMode: contents.index) {
                    return index
                }
                guard PDFReflowExtractor.headingLevel(for: line, profile: profile,
                                                      previous: index > start ? lines[index - 1] : nil) != nil,
                      !PDFReflowExtractor.isContentsHeading(line.text),
                      !PDFReflowExtractor.isIndexHeading(line.text),
                      !PDFReflowExtractor.isContentsEntryStart(line, previous: nil,
                                                              indexMode: contents.index) else { continue }
                let next = lines[(index + 1)...].prefix(3).filter { !$0.marginal }
                let looksLikeContents = next.contains {
                    PDFReflowExtractor.isContentsEntryStart($0, previous: line, indexMode: contents.index)
                }
                if !looksLikeContents { return index }
            }
            return lines.count
        }

        /// OCR splits a table-of-contents row into number, title and page-number
        /// fragments. Rebuild rows from their baselines before deciding what is
        /// one entry; the line-by-line reader would otherwise turn every column
        /// into a bullet.
        private func contentsPieces(_ text: String) -> [String] {
            var value = text
            let patterns = [
                #"(?<=\s)(?=(?:[IVXLC]{1,6}|\d{1,3}(?:\.\d+)+)\.\s+\p{Lu})"#,
                #"(?<=\s)(?=(?:CAPÍTULO|CAPITULO|CHAPTER|PARTE|PART|SECCIÓN|SECTION)\b)"#,
                #"(?<=\s)(?=Tabla\s+\d+\.)"#
            ]
            for pattern in patterns {
                value = value.replacingOccurrences(of: pattern, with: "\n", options: .regularExpression)
            }
            var pieces = value.components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            var collapsed: [String] = []
            for piece in pieces {
                if let last = collapsed.last,
                   ["CAPÍTULO", "CAPITULO", "CHAPTER", "PARTE", "PART", "SECCIÓN", "SECTION"]
                       .contains(last.uppercased()) {
                    collapsed[collapsed.count - 1] = last + " " + piece
                } else {
                    collapsed.append(piece)
                }
            }
            pieces = collapsed
            return pieces
        }

        mutating func appendOCRContents(_ lines: [Line], usedOCR: Bool) {
            var rows: [[Line]] = []
            var currentRow: [Line] = []
            for line in lines.sorted(by: { $0.rect.minY < $1.rect.minY }) {
                if line.isVertical || PDFReflowExtractor.isNoise(line) { continue }
                if line.rect.maxY < 0.10 { continue }
                if PDFReflowExtractor.definiteMarginal(line) { continue }
                if let last = currentRow.last,
                   abs(last.baseline - line.baseline) <= 0.012 {
                    currentRow.append(line)
                } else {
                    if !currentRow.isEmpty { rows.append(currentRow) }
                    currentRow = [line]
                }
            }
            if !currentRow.isEmpty { rows.append(currentRow) }
            rows = rows.map { $0.sorted { $0.rect.minX < $1.rect.minX } }

            var pending: [Line] = []

            func appendPiece(_ piece: String) {
                guard !piece.isEmpty else { return }
                let value = PDFReflowExtractor.contentsEntry(piece, onContentsPage: true)
                    ?? (contents.index ? PDFReflowExtractor.indexEntry(piece) : nil)
                    ?? piece
                appendBlock(lines: pending, kind: .list, text: value, usedOCR: usedOCR)
            }

            func flushPending() {
                guard !pending.isEmpty else { return }
                let joined = TextNormalizer.joinLines(pending.map(\.text), hyphenation: hyphenation)
                guard !joined.isEmpty else { pending = []; return }
                let pieces = contentsPieces(joined)
                if pieces.count > 1 {
                    for piece in pieces { appendPiece(piece) }
                } else {
                    appendPiece(joined)
                }
                pending = []
            }

            for row in rows {
                let text = TextNormalizer.joinLines(row.map(\.text), hyphenation: hyphenation)
                guard !text.isEmpty else { continue }
                if PDFReflowExtractor.isContentsHeading(text)
                    || PDFReflowExtractor.isIndexHeading(text) {
                    flushPending()
                    let level = PDFReflowExtractor.headingLevel(for: row[0], profile: profile) ?? 1
                    appendBlock(lines: row, kind: level == 1 ? .heading1 : .heading2,
                                text: text, usedOCR: usedOCR)
                    if PDFReflowExtractor.isIndexHeading(text) { contents.index = true }
                    continue
                }
                let startsNew = text.range(
                    of: #"^\s*(?:\d{1,3}(?:\.\d+)*\.?|[IVXLC]{1,6}\.)\s+\S"#,
                    options: [.regularExpression, .caseInsensitive]
                ) != nil
                    || text.range(of: #"^\s*(?:CAPÍTULO|CAPITULO|CHAPTER|PARTE|PART|SECCIÓN|SECTION)\b"#,
                                  options: [.regularExpression, .caseInsensitive]) != nil
                    || (text.count <= 80 && text == text.uppercased()
                        && text.rangeOfCharacter(from: .letters) != nil)
                let pieces = contentsPieces(text)
                if pieces.count > 1 {
                    if pending.isEmpty {
                        for piece in pieces {
                            let value = PDFReflowExtractor.contentsEntry(piece, onContentsPage: true)
                                ?? (contents.index ? PDFReflowExtractor.indexEntry(piece) : nil)
                                ?? piece
                            appendBlock(lines: row, kind: .list, text: value, usedOCR: usedOCR)
                        }
                    } else {
                        pending.append(contentsOf: row)
                        flushPending()
                    }
                    continue
                }
                let parsed = PDFReflowExtractor.contentsEntry(text, onContentsPage: true)
                    ?? (contents.index ? PDFReflowExtractor.indexEntry(text) : nil)
                if let parsed {
                    if pending.isEmpty {
                        appendBlock(lines: row, kind: .list, text: parsed, usedOCR: usedOCR)
                    } else {
                        pending.append(contentsOf: row)
                        flushPending()
                    }
                } else if startsNew {
                    flushPending()
                    pending = row
                } else if !pending.isEmpty {
                    pending.append(contentsOf: row)
                } else if PDFReflowExtractor.endsParagraph(text), text.count > 40 {
                    appendBlock(lines: row, kind: .body, text: text, usedOCR: usedOCR)
                } else {
                    pending = row
                }
            }
            flushPending()
        }

        mutating func appendContents(_ lines: [Line], usedOCR: Bool) {
            var entry: [Line] = []

            func flushEntry() {
                guard !entry.isEmpty else { return }
                let joined = TextNormalizer.joinLines(entry.map(\.text), hyphenation: hyphenation)
                guard !joined.isEmpty else { entry = []; return }
                let value: String
                if contents.index, let indexed = PDFReflowExtractor.indexEntry(joined) {
                    value = indexed
                } else if let toc = PDFReflowExtractor.contentsEntry(joined, onContentsPage: true) {
                    value = toc
                } else {
                    value = joined
                }
                appendBlock(lines: entry, kind: .list, text: value, usedOCR: usedOCR)
                entry = []
            }

            for line in lines {
                if line.isVertical || PDFReflowExtractor.isMarginPageNumber(line) { continue }
                if PDFReflowExtractor.isNoise(line) { continue }
                if PDFReflowExtractor.definiteMarginal(line) {
                    flushEntry()
                    appendHeaderFooter(line, usedOCR: usedOCR)
                    continue
                }
                if PDFReflowExtractor.isContentsHeading(line.text)
                    || PDFReflowExtractor.isIndexHeading(line.text) {
                    flushEntry()
                    let level = PDFReflowExtractor.headingLevel(for: line, profile: profile) ?? 1
                    appendBlock(lines: [line], kind: level == 1 ? .heading1 : .heading2,
                                text: line.text, usedOCR: usedOCR)
                    if PDFReflowExtractor.isIndexHeading(line.text) { contents.index = true }
                    continue
                }
                if entry.isEmpty, !PDFReflowExtractor.isContentsEntryStart(line, previous: nil,
                                                                             indexMode: contents.index),
                   PDFReflowExtractor.endsParagraph(line.text), line.text.count > 60 {
                    flushEntry()
                    appendBlock(lines: [line], kind: .body, text: line.text, usedOCR: usedOCR)
                    continue
                }
                if PDFReflowExtractor.isContentsEntryStart(line, previous: entry.last,
                                                           indexMode: contents.index) {
                    flushEntry()
                    entry = [line]
                } else if !entry.isEmpty {
                    entry.append(line)
                } else {
                    entry = [line]
                }
            }
            flushEntry()
        }

        mutating func appendNormal(_ lines: [Line], usedOCR: Bool) {
            enum Mode {
                case body
                case heading(Int)
                case list
                case quote
            }

            var mode: Mode = .body
            var current: [Line] = []
            var marginal: [Line] = []

            func flushMarginal() {
                guard !marginal.isEmpty else { return }
                let text = TextNormalizer.joinLines(marginal.map(\.text), hyphenation: hyphenation)
                if !text.isEmpty {
                    appendBlock(lines: marginal, kind: .body, text: text,
                                usedOCR: usedOCR, headerFooter: true)
                }
                marginal = []
            }

            func flushCurrent() {
                guard !current.isEmpty else { return }
                let text: String
                switch mode {
                case .list:
                    text = TextNormalizer.joinLines(
                        current.map { PDFReflowExtractor.bulletText($0.text) },
                        hyphenation: hyphenation
                    )
                case .quote:
                    text = TextNormalizer.joinLines(
                        current.map { PDFReflowExtractor.quoteText($0.text) },
                        hyphenation: hyphenation
                    )
                default:
                    text = TextNormalizer.joinLines(current.map(\.text), hyphenation: hyphenation)
                }
                guard !text.isEmpty else { current = []; return }
                let kind: PDFReflowBlock.Kind
                switch mode {
                case .body: kind = .body
                case .heading(let level): kind = level == 1 ? .heading1 : .heading2
                case .list: kind = .list
                case .quote: kind = .quote
                }
                appendBlock(lines: current, kind: kind, text: text, usedOCR: usedOCR)
                current = []
                mode = .body
            }

            var previousLine: Line?
            for line in lines {
                if line.isVertical || PDFReflowExtractor.isMarginPageNumber(line) { continue }
                if PDFReflowExtractor.isNoise(line) { continue }
                if PDFReflowExtractor.definiteMarginal(line) {
                    flushCurrent()
                    marginal.append(line)
                    continue
                }
                flushMarginal()

                let heading = PDFReflowExtractor.headingLevel(for: line, profile: profile,
                                                              previous: previousLine)
                previousLine = line
                if let heading {
                    if case .heading(let currentLevel) = mode, currentLevel == heading,
                       !current.isEmpty, line.rect.minY - current.last!.rect.maxY < profile.medianHeight * 1.5 {
                        current.append(line)
                    } else {
                        flushCurrent()
                        mode = .heading(heading)
                        current = [line]
                    }
                    continue
                }

                if PDFReflowExtractor.isBullet(line.text) {
                    // Every bullet starts its own list item; a wrapped item is
                    // appended by the `.list` branch below.
                    if !current.isEmpty { flushCurrent() }
                    mode = .list
                    current = [line]
                    continue
                }

                if PDFReflowExtractor.isQuote(line.text) {
                    if case .quote = mode {
                        current.append(line)
                    } else {
                        flushCurrent()
                        mode = .quote
                        current = [line]
                    }
                    continue
                }

                switch mode {
                case .list:
                    // A wrapped list item continues on the next line.
                    if !current.isEmpty,
                       line.rect.minX > current.first!.rect.minX + 0.01,
                       !PDFReflowExtractor.endsParagraph(current.last!.text) {
                        current.append(line)
                    } else {
                        flushCurrent()
                        mode = .body
                        current = [line]
                    }
                case .quote:
                    if !PDFReflowExtractor.endsParagraph(current.last?.text ?? "") {
                        current.append(line)
                    } else {
                        flushCurrent()
                        mode = .body
                        current = [line]
                    }
                case .heading:
                    flushCurrent()
                    mode = .body
                    current = [line]
                case .body:
                    if !current.isEmpty,
                       !PDFReflowExtractor.startsNewParagraph(
                            line, after: current.last!,
                            paragraphStartX: current.first!.rect.minX,
                            profile: profile
                       ) {
                        current.append(line)
                    } else {
                        flushCurrent()
                        mode = .body
                        current = [line]
                    }
                }
            }
            flushCurrent()
            flushMarginal()
        }

        private mutating func appendHeaderFooter(_ line: Line, usedOCR: Bool) {
            let text = TextNormalizer.cleanLine(line.text)
            guard !text.isEmpty else { return }
            appendBlock(lines: [line], kind: .body, text: text,
                        usedOCR: usedOCR, headerFooter: true)
        }

        private mutating func appendBlock(lines: [Line], kind: PDFReflowBlock.Kind,
                                          text: String, usedOCR: Bool,
                                          headerFooter: Bool = false) {
            guard !lines.isEmpty, !text.isEmpty else { return }
            let rect = union(lines.map(\.rect))
            let averageSize = lines.map(\.fontSize).reduce(0, +) / CGFloat(lines.count)
            let isFootnote = !headerFooter && kind == .body
                && rect.minY > 0.50
                && averageSize < profile.bodyFontSize * 0.90
            let allMarginal = lines.allSatisfy { PDFReflowExtractor.definiteMarginal($0) }
            let isHeaderFooter = headerFooter || isFootnote || (allMarginal && kind == .body)
            let cleaned = TextNormalizer.cleanBlock(text)
            let block = PDFReflowBlock(
                id: UUID(), kind: kind, text: cleaned,
                rect: rect, pageIndex: index, imageFileName: nil,
                isHeaderFooter: isHeaderFooter, usedOCR: usedOCR,
                isFootnote: isFootnote, fontSize: averageSize,
                isCaption: kind == .body && PDFReflowExtractor.isCaption(cleaned)
            )
            blocks.append(block)
            let regionKind: PDFReflowRegion.Kind
            switch kind {
            case .heading1, .heading2: regionKind = .heading
            case .figure: regionKind = .figure
            case .tableImage: regionKind = .table
            default: regionKind = isHeaderFooter ? .headerFooter : .text
            }
            regions.append(PDFReflowRegion(
                id: UUID(), kind: regionKind, rect: rect,
                label: regionLabel(kind: kind, isHeaderFooter: isHeaderFooter)
            ))
        }

        private func regionLabel(kind: PDFReflowBlock.Kind, isHeaderFooter: Bool) -> String {
            if isHeaderFooter { return String(localized: "Header / footer") }
            switch kind {
            case .heading1, .heading2: return String(localized: "Heading")
            case .list: return String(localized: "Contents entry")
            case .quote: return String(localized: "Quote")
            case .figure: return String(localized: "Figure")
            case .tableImage: return String(localized: "Table")
            case .body: return String(localized: "Text")
            }
        }

        private mutating func emptyPage(usedOCR: Bool) -> PDFReflowPage {
            PDFReflowPage(pageIndex: index, width: bounds.width, height: bounds.height,
                          blocks: [], regions: regions)
        }

        private mutating func imagePage(usedOCR: Bool, imagesDirectory: URL) -> PDFReflowPage {
            let imageName = "page-\(index)-full.jpg"
            if let image = render(page: page, bounds: bounds, scale: 2),
               let data = jpegData(from: image) {
                try? data.write(to: imagesDirectory.appendingPathComponent(imageName))
            }
            let block = PDFReflowBlock(
                id: UUID(), kind: .figure, text: String(localized: "Page \(index + 1)"),
                rect: CGRect(x: 0, y: 0, width: 1, height: 1),
                pageIndex: index, imageFileName: imageName, isHeaderFooter: false,
                usedOCR: usedOCR
            )
            regions.append(PDFReflowRegion(id: UUID(), kind: .figure,
                                           rect: CGRect(x: 0, y: 0, width: 1, height: 1),
                                           label: String(localized: "Scanned page")))
            return PDFReflowPage(pageIndex: index, width: bounds.width, height: bounds.height,
                                 blocks: [block], regions: regions)
        }

        /// A diagram, chart or table of contents-like block of tiny, scattered
        /// labels is a figure, not prose. Keep the original pixels and remove
        /// its labels from the reading text; the caption below it stays.
        private mutating func replaceFigureRegions(usedOCR: Bool, imagesDirectory: URL) {
            var runs: [[Int]] = []
            var run: [Int] = []
            for index in blocks.indices {
                let block = blocks[index]
                if block.isHeaderFooter || block.isFootnote {
                    // A watermark or symbol inside a figure does not end the
                    // figure; it is simply ignored while grouping.
                    if !run.isEmpty { continue }
                    continue
                }
                if isFigureFragment(block) {
                    run.append(index)
                } else if !run.isEmpty {
                    runs.append(run)
                    run = []
                }
            }
            if !run.isEmpty { runs.append(run) }

            for run in runs.reversed() {
                guard run.count >= 5 else { continue }
                let runBlocks = run.map { blocks[$0] }
                let rect = union(runBlocks.map(\.rect))
                guard rect.width > 0.25, rect.height > 0.08 else { continue }
                let small = runBlocks.filter { $0.fontSize < profile.bodyFontSize * 0.95 }.count
                let columns = Set(runBlocks.map { Int($0.rect.minX * 12) }).count
                guard small * 2 >= runBlocks.count || columns >= 3 else { continue }
                guard !runBlocks.contains(where: { $0.text.count > 180 }) else { continue }

                let imageName = "page-\(index)-figure-\(UUID().uuidString.prefix(6)).jpg"
                if let full = render(page: page, bounds: bounds, scale: 2),
                   let cropped = crop(full, normalized: rect.insetBy(dx: -0.005, dy: -0.005)),
                   let data = jpegData(from: cropped) {
                    try? data.write(to: imagesDirectory.appendingPathComponent(imageName))
                }
                let figure = PDFReflowBlock(
                    id: UUID(), kind: .figure,
                    text: String(localized: "Figure on page \(index + 1)"),
                    rect: rect, pageIndex: index, imageFileName: imageName,
                    isHeaderFooter: false, usedOCR: usedOCR
                )
                let first = run.first!
                let last = run.last!
                blocks.replaceSubrange(first...last, with: [figure])
                regions.removeAll { $0.rect.intersects(rect) && $0.kind != .headerFooter }
                regions.append(PDFReflowRegion(id: UUID(), kind: .figure, rect: rect,
                                               label: String(localized: "Figure")))
            }
        }

        private func isFigureFragment(_ block: PDFReflowBlock) -> Bool {
            let text = block.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, text.count < 100, !PDFReflowExtractor.isCaption(text) else {
                return false
            }
            // The top of a first page is a title/author/metadata block, not a
            // diagram. Leave it to the front-matter pass.
            if index == 0, block.rect.minY < 0.30 { return false }
            if block.kind == .list { return false }
            guard block.kind == .body || block.kind == .heading1 || block.kind == .heading2 else {
                return false
            }
            if block.kind == .heading1 || block.kind == .heading2,
               block.fontSize >= profile.bodyFontSize * 1.15 {
                return false
            }
            return block.fontSize < profile.bodyFontSize * 0.95 || text.count < 45
        }

        private mutating func replaceTables(ordered: [Line], usedOCR: Bool,
                                            imagesDirectory: URL) {
            // A page with a "Tabla N" caption is a table page. OCR cannot
            // recover its columns reliably, and the line-based reader mixes
            // cells from different rows. Keep the caption and the prose after
            // the table, but preserve the table itself as one page image.
            if let captionIndex = blocks.firstIndex(where: {
                $0.isCaption && $0.text.lowercased().hasPrefix("tabla ")
            }) {
                var end = blocks.count
                for candidate in (captionIndex + 1)..<blocks.count {
                    let block = blocks[candidate]
                    if block.isHeaderFooter { continue }
                    let tableRow = block.text.range(
                        of: #"^\s*(?:P\d|C\d|TOTAL|CATEGOR|DESCRIP|\d{1,2}\s*[-–])"#,
                        options: [.regularExpression, .caseInsensitive]
                    ) != nil
                    if block.kind == .body, !tableRow, block.text.count > 250,
                       block.rect.minX < 0.28, block.rect.width > 0.50 {
                        end = candidate
                        break
                    }
                }
                let tableBlocks = Array(blocks[(captionIndex + 1)..<end]).filter {
                    !$0.isHeaderFooter
                }
                if tableBlocks.count >= 2 {
                    let rect = union(tableBlocks.map(\.rect))
                    if rect.width > 0.25, rect.height > 0.04 {
                        let imageName = "page-\(index)-table-\(UUID().uuidString.prefix(6)).jpg"
                        if let full = render(page: page, bounds: bounds, scale: 2),
                           let cropped = crop(full, normalized: rect),
                           let data = jpegData(from: cropped) {
                            try? data.write(to: imagesDirectory.appendingPathComponent(imageName))
                        }
                        let table = PDFReflowBlock(
                            id: UUID(), kind: .tableImage,
                            text: "Table on page \(index + 1) · Reconstructed from the original page",
                            rect: rect, pageIndex: index, imageFileName: imageName,
                            isHeaderFooter: false, usedOCR: usedOCR
                        )
                        blocks.replaceSubrange((captionIndex + 1)..<end, with: [table])
                        regions.removeAll { $0.kind != .headerFooter && $0.rect.intersects(rect) }
                        regions.append(PDFReflowRegion(id: UUID(), kind: .table, rect: rect,
                                                       label: String(localized: "Table")))
                        return
                    }
                }
            }

            var tableLines: [Line] = []
            var tableCandidates = Set<UUID>()

            func flushTable() {
                guard tableLines.count >= 2 else { tableLines = []; return }
                let rect = union(tableLines.map(\.rect))
                let imageName = "page-\(index)-table-\(UUID().uuidString.prefix(6)).jpg"
                if let full = render(page: page, bounds: bounds, scale: 2),
                   let cropped = crop(full, normalized: rect),
                   let data = jpegData(from: cropped) {
                    try? data.write(to: imagesDirectory.appendingPathComponent(imageName))
                }
                let block = PDFReflowBlock(
                    id: UUID(), kind: .tableImage,
                    text: "Table on page \(index + 1) · Reconstructed from the original page",
                    rect: rect, pageIndex: index, imageFileName: imageName,
                    isHeaderFooter: false, usedOCR: usedOCR
                )
                blocks.append(block)
                regions.append(PDFReflowRegion(id: UUID(), kind: .table, rect: rect,
                                               label: String(localized: "Table")))
                tableLines = []
            }

            for block in blocks {
                let linesInBlock = ordered.filter {
                    block.rect.intersects($0.rect) && block.kind == .body
                }
                let tabular = linesInBlock.filter { looksTabular($0.text) }
                if !linesInBlock.isEmpty, tabular.count == linesInBlock.count,
                   tabular.count >= 2 {
                    tableLines.append(contentsOf: tabular)
                    tableCandidates.insert(block.id)
                }
            }
            guard !tableLines.isEmpty else { return }
            let rebuilt = blocks.filter { !tableCandidates.contains($0.id) }
            blocks = rebuilt
            flushTable()
            blocks.append(contentsOf: rebuilt.filter { $0.kind == .tableImage })
            blocks.sort { $0.rect.minY < $1.rect.minY }
        }
    }

    // MARK: Reading order

    private static func readingOrder(_ lines: [Line], pageWidth: CGFloat) -> [Line] {
        guard lines.count > 1 else { return lines }
        let sorted = lines.sorted { $0.rect.minY < $1.rect.minY }
        var result: [Line] = []
        var band: [Line] = []

        func flushBand() {
            guard !band.isEmpty else { return }
            result.append(contentsOf: orderBand(band, pageWidth: pageWidth))
            band = []
        }

        for line in sorted {
            if line.rect.width >= 0.55 {
                flushBand()
                result.append(line)
            } else {
                band.append(line)
            }
        }
        flushBand()
        return result
    }

    private static func orderBand(_ lines: [Line], pageWidth: CGFloat) -> [Line] {
        guard lines.count >= 2 else { return lines }
        let left = lines.filter { $0.rect.midX < 0.5 }
        let right = lines.filter { $0.rect.midX >= 0.5 }
        guard left.count >= 2, right.count >= 2,
              let leftMax = left.map(\.rect.maxX).max(),
              let rightMin = right.map(\.rect.minX).min(),
              leftMax < rightMin - 0.02 else {
            return lines.sorted { $0.rect.minY < $1.rect.minY }
        }
        return left.sorted { $0.rect.minY < $1.rect.minY }
            + right.sorted { $0.rect.minY < $1.rect.minY }
    }

    // MARK: Post-processing

    private static func markHeadersAndFooters(in pages: inout [PDFReflowPage],
                                              profile: LayoutProfile) {
        var counts: [String: Int] = [:]
        var headerTexts: [String: String] = [:]
        for page in pages {
            for block in page.blocks where (block.kind == .body || block.kind == .list)
                && marginalCandidate(block) {
                let key = normalizedHeader(block.text)
                counts[key, default: 0] += 1
                headerTexts[key] = block.text
            }
        }
        for pageIndex in pages.indices {
            for blockIndex in pages[pageIndex].blocks.indices {
                let block = pages[pageIndex].blocks[blockIndex]
                guard block.kind == .body || block.kind == .list else { continue }
                let text = block.text
                let nearTop = block.rect.minY < 0.12
                let nearBottom = block.rect.maxY > 0.86
                guard nearTop || nearBottom || TextNormalizer.isPageNumber(text) else { continue }

                let pageNumber = (TextNormalizer.isPageNumber(text) && text.count <= 80)
                    || (TextNormalizer.isBarePageNumber(text) && text.count <= 8
                        && (nearTop || nearBottom))
                let repeated = counts[normalizedHeader(text), default: 0] >= 2
                let small = block.fontSize > 0 && block.fontSize < profile.bodyFontSize * 0.92
                let runningTitle = nearTop && block.rect.minY < 0.10
                    && text.count < 220 && !PDFReflowExtractor.endsParagraph(text)
                let shouldMark = pageNumber
                    || (repeated && text.count < 160)
                    || runningTitle
                    || (nearBottom && block.rect.maxY > 0.88 && small && text.count < 140)
                if shouldMark {
                    pages[pageIndex].blocks[blockIndex].isHeaderFooter = true
                }
            }
        }
        let repeatedHeaders = headerTexts.filter { counts[$0.key, default: 0] >= 2 }.values
            .sorted { $0.count > $1.count }
        guard !repeatedHeaders.isEmpty else { return }
        for pageIndex in pages.indices {
            for blockIndex in pages[pageIndex].blocks.indices {
                let block = pages[pageIndex].blocks[blockIndex]
                guard !block.isHeaderFooter, block.kind == .body || block.kind == .list,
                      block.rect.minY < 0.16 else { continue }
                for header in repeatedHeaders {
                    guard block.text.hasPrefix(header) else { continue }
                    let remainder = String(block.text.dropFirst(header.count))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if remainder.isEmpty {
                        pages[pageIndex].blocks[blockIndex].isHeaderFooter = true
                    } else {
                        pages[pageIndex].blocks[blockIndex].text = remainder
                    }
                    break
                }
            }
        }
    }

    private static func markColumnContinuations(in pages: inout [PDFReflowPage]) {
        for pageIndex in pages.indices {
            let indices = pages[pageIndex].blocks.indices.filter {
                let block = pages[pageIndex].blocks[$0]
                return block.kind == .body && !block.isHeaderFooter && !block.isFootnote
                    && !isCaption(block.text)
            }
            for pair in zip(indices, indices.dropFirst()) {
                let previous = pages[pageIndex].blocks[pair.0]
                let current = pages[pageIndex].blocks[pair.1]
                guard current.rect.minX > previous.rect.minX + 0.15,
                      current.rect.minY < previous.rect.maxY - 0.01,
                      !endsParagraph(previous.text),
                      current.text.first?.isLowercase == true else { continue }
                pages[pageIndex].blocks[pair.1].continuesPrevious = true
            }
        }
    }

    private static func markFrontMatter(in pages: inout [PDFReflowPage]) {
        if let contentsIndex = pages.firstIndex(where: { page in
            page.blocks.contains {
                PDFReflowExtractor.isContentsHeading($0.text)
                    || PDFReflowExtractor.isIndexHeading($0.text)
            }
        }), contentsIndex > 0 {
            let hasFrontProse = pages[0..<contentsIndex].contains { page in
                page.blocks.contains {
                    $0.kind == .body && !$0.isHeaderFooter && $0.text.count > 600
                }
            }
            if !hasFrontProse {
                for index in 0..<contentsIndex {
                    for blockIndex in pages[index].blocks.indices {
                        pages[index].blocks[blockIndex].isHeaderFooter = true
                    }
                }
            }
        }
        guard var first = pages.first,
              let headingIndex = first.blocks.firstIndex(where: {
                  ($0.kind == .heading1 || $0.kind == .heading2)
                      && $0.rect.minY > 0.03
                      && $0.rect.minY < 0.45
                      && $0.fontSize >= 14
                      && $0.rect.width >= 0.18
              }) else { return }
        let headingTop = first.blocks[headingIndex].rect.minY
        for index in 0..<headingIndex {
            let block = first.blocks[index]
            guard block.rect.maxY <= headingTop + 0.005,
                  block.text.count < 400 else { continue }
            first.blocks[index].isHeaderFooter = true
        }
        pages[0] = first
    }

    private static func markParagraphContinuations(in pages: inout [PDFReflowPage]) {
        guard pages.count > 1 else { return }
        for pageIndex in 1..<pages.count {
            let currentBlocks = pages[pageIndex].blocks
            guard let firstIndex = currentBlocks.firstIndex(where: {
                $0.kind == .body && !$0.isHeaderFooter && !$0.isFootnote
                    && !isCaption($0.text)
            }) else { continue }
            // A page that begins with a heading, contents entry, quote or
            // figure starts a new division; its first paragraph is not a
            // continuation. A figure caption may precede the continuation.
            guard currentBlocks[..<firstIndex].allSatisfy({
                $0.isHeaderFooter || $0.kind == .figure || $0.kind == .tableImage
                    || isCaption($0.text)
            }) else { continue }
            let current = currentBlocks[firstIndex]
            guard let previous = pages[pageIndex - 1].blocks.last(where: {
                $0.kind == .body && !$0.isHeaderFooter && !$0.isFootnote
                    && !isCaption($0.text)
            }) else { continue }
            guard previous.rect.maxY > 0.55, current.rect.minY < 0.60 else { continue }
            guard !endsParagraph(previous.text) else { continue }
            guard current.text.first?.isLowercase == true
                || current.text.hasPrefix("(")
                || current.text.hasPrefix("–")
                || current.text.hasPrefix("-") else { continue }
            pages[pageIndex].blocks[firstIndex].continuesPrevious = true
        }
    }

    private static func marginalCandidate(_ block: PDFReflowBlock) -> Bool {
        if TextNormalizer.isPageNumber(block.text), block.text.count <= 80 { return true }
        if block.text.count <= 8, TextNormalizer.isBarePageNumber(block.text),
           block.rect.minY < 0.10 || block.rect.maxY > 0.86 { return true }
        guard block.text.count <= 160 else { return false }
        return block.rect.minY < 0.12 || block.rect.maxY > 0.88
    }

    private static func normalizedHeader(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: #"\d+"#, with: "#", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Geometry and images

    private static func normalize(_ rect: CGRect, in bounds: CGRect) -> CGRect {
        guard bounds.width > 0, bounds.height > 0 else { return .zero }
        return CGRect(x: (rect.minX - bounds.minX) / bounds.width,
                      y: 1 - (rect.maxY - bounds.minY) / bounds.height,
                      width: rect.width / bounds.width,
                      height: rect.height / bounds.height)
    }

    private static func normalizeRaw(_ rect: CGRect, in bounds: CGRect) -> CGRect {
        guard bounds.width > 0, bounds.height > 0 else { return .zero }
        return CGRect(x: (rect.minX - bounds.minX) / bounds.width,
                      y: (rect.minY - bounds.minY) / bounds.height,
                      width: rect.width / bounds.width,
                      height: rect.height / bounds.height)
    }

    private static func union(_ rects: [CGRect]) -> CGRect {
        guard var result = rects.first else { return .zero }
        for rect in rects.dropFirst() { result = result.union(rect) }
        return result
    }

    private static func median(_ values: [CGFloat]) -> CGFloat? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    private static func render(page: PDFPage, bounds: CGRect, scale: CGFloat) -> CGImage? {
        PDFPageText.render(page: page, bounds: bounds, scale: scale)
    }

    private static func crop(_ image: CGImage, normalized rect: CGRect) -> CGImage? {
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        let pixelRect = CGRect(x: rect.minX * width,
                               y: (1 - rect.maxY) * height,
                               width: max(1, rect.width * width),
                               height: max(1, rect.height * height))
        return image.cropping(to: pixelRect.integral)
    }

    private static func jpegData(from image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data as CFMutableData,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image,
                                   [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}

// MARK: - Markdown

extension PDFReflowDocument {
    /// The book as Markdown. Running headers and feet, page numbers and
    /// footnotes are left out; a paragraph that continued on the next page is
    /// joined back together, and contents/index entries stay one per line.
    func markdown() -> String {
        enum Node {
            case heading(Int, String)
            case paragraph(String)
            case caption(String)
            case list(String)
            case quote(String)
            case image(String, String)
        }

        var nodes: [Node] = []

        func appendText(_ text: String, to node: Node) -> Node {
            switch node {
            case .paragraph(let existing):
                return .paragraph(TextNormalizer.joinLines([existing, text]))
            case .list(let existing):
                return .list(TextNormalizer.joinLines([existing, text]))
            case .quote(let existing):
                return .quote(TextNormalizer.joinLines([existing, text]))
            default:
                return node
            }
        }

        for page in pages {
            for block in page.blocks where !block.isHeaderFooter {
                let text = TextNormalizer.cleanBlock(block.text)
                guard !text.isEmpty else { continue }
                let new: Node
                switch block.kind {
                case .heading1: new = .heading(1, text)
                case .heading2: new = .heading(2, text)
                case .body: new = block.isCaption ? .caption(text) : .paragraph(text)
                case .list: new = .list(text)
                case .quote: new = .quote(text)
                case .figure, .tableImage:
                    new = .image(text, block.imageFileName ?? "")
                }
                if block.continuesPrevious, !nodes.isEmpty, case .paragraph = new {
                    // A paragraph interrupted by a figure or a caption on the
                    // next page is joined back. The figure stays after the
                    // completed paragraph, which is where a reader expects it.
                    var merged = false
                    var stop = false
                    for index in stride(from: nodes.count - 1, through: 0, by: -1) {
                        switch nodes[index] {
                        case .paragraph:
                            nodes[index] = appendText(text, to: nodes[index])
                            merged = true
                            stop = true
                        case .caption, .image:
                            continue
                        case .heading, .list, .quote:
                            stop = true
                        }
                        if stop { break }
                    }
                    if merged { continue }
                }
                nodes.append(new)
            }
        }

        var blocks: [String] = []
        var listItems: [String] = []

        func flushList() {
            guard !listItems.isEmpty else { return }
            blocks.append(listItems.joined(separator: "\n"))
            listItems = []
        }

        for node in nodes {
            if case .list(let text) = node {
                listItems.append("- " + escapeMarkdown(text))
                continue
            }
            flushList()
            switch node {
            case .heading(let level, let text):
                blocks.append(String(repeating: "#", count: max(1, min(level, 6)))
                    + " " + escapeMarkdown(text))
            case .paragraph(let text):
                blocks.append(escapeMarkdown(text))
            case .caption(let text):
                blocks.append("*" + escapeMarkdown(text) + "*")
            case .quote(let text):
                blocks.append("> " + escapeMarkdown(text))
            case .image(let alt, let source):
                blocks.append("![\(escapeMarkdown(alt))](\(source))")
            case .list:
                break
            }
        }
        flushList()
        return blocks.joined(separator: "\n\n") + "\n"
    }

    /// The same structure without Markdown punctuation, for the reader.
    func readingText() -> String {
        var out: [String] = []
        for page in pages {
            for block in page.blocks where !block.isHeaderFooter {
                let text = TextNormalizer.cleanBlock(block.text)
                guard !text.isEmpty else { continue }
                switch block.kind {
                case .heading1, .heading2:
                    if !out.isEmpty { out.append("") }
                    out.append(text)
                    out.append("")
                case .list:
                    out.append("• " + text)
                case .quote:
                    out.append(text)
                    out.append("")
                case .figure, .tableImage:
                    out.append(text)
                    out.append("")
                case .body:
                    if block.isCaption {
                        out.append(text)
                        out.append("")
                    } else if block.continuesPrevious, !out.isEmpty,
                              let last = out.last, !last.isEmpty {
                        out[out.count - 1] = TextNormalizer.joinLines([last, text])
                    } else {
                        out.append(text)
                        out.append("")
                    }
                }
            }
        }
        return out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func escapeMarkdown(_ text: String) -> String {
        var value = text.replacingOccurrences(of: "\\", with: "\\\\")
        for character in ["*", "_", "`", "[", "]", "<", ">", "|", "~"] {
            value = value.replacingOccurrences(of: character, with: "\\" + character)
        }
        if value.hasPrefix("#") || value.hasPrefix("-") || value.hasPrefix("+") {
            value = "\\" + value
        }
        return value
    }
}

// MARK: - Annotation anchoring

extension PDFReflowBlock {
    /// Blocks whose text can be selected, highlighted and annotated.
    var isAnnotatableText: Bool {
        switch kind {
        case .heading1, .heading2, .body, .quote, .list: !text.isEmpty
        case .figure, .tableImage: false
        }
    }
}

extension PDFReflowPage {
    /// The page's text blocks joined with blank lines, in reading order,
    /// headers and footers included, plus each block's UTF-16 start offset.
    /// Highlights in Intelligent Reading are stored as offsets into this text
    /// (`Annotation.chapterIndex` = original page index), so they do not depend
    /// on the "Show images" or "Skip headers" switches. Block UUIDs are not
    /// used: they change whenever the reflow cache is regenerated.
    var canonicalLayout: (text: String, bases: [UUID: Int]) {
        var text = ""
        var bases: [UUID: Int] = [:]
        for block in blocks where block.isAnnotatableText {
            if !text.isEmpty { text += "\n\n" }
            bases[block.id] = (text as NSString).length
            text += block.text
        }
        return (text, bases)
    }

    /// The canonical text with headers, page numbers and footnotes blanked
    /// out (same length, so narration offsets are canonical offsets and the
    /// read-along highlight lands on the same words).
    var narrationText: String {
        let layout = canonicalLayout
        let ns = NSMutableString(string: layout.text)
        for block in blocks where block.isAnnotatableText && block.isHeaderFooter {
            guard let base = layout.bases[block.id] else { continue }
            let length = (block.text as NSString).length
            guard base + length <= ns.length else { continue }
            ns.replaceCharacters(in: NSRange(location: base, length: length),
                                 with: String(repeating: " ", count: length))
        }
        return ns as String
    }
}

/// Finds where a stored PDF highlight is in the current reflow text.
enum ReflowAnnotationAnchor {
    /// The stored range when it still covers `quote`; otherwise the occurrence
    /// of `quote` closest to the old position (the reflow cache may have been
    /// rebuilt with slightly different block boundaries); nil when the quote is
    /// no longer on the page.
    static func resolve(start: Int, end: Int, quote: String, in text: String) -> NSRange? {
        let ns = text as NSString
        let target = quote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return nil }
        let stored = NSRange(location: start, length: max(0, end - start))
        if stored.location >= 0, stored.length > 0, NSMaxRange(stored) <= ns.length,
           ns.substring(with: stored).trimmingCharacters(in: .whitespacesAndNewlines) == target {
            return stored
        }
        var best: NSRange?
        var searchRange = NSRange(location: 0, length: ns.length)
        while searchRange.length > 0 {
            let found = ns.range(of: target, options: [], range: searchRange)
            guard found.location != NSNotFound else { break }
            if best == nil || abs(found.location - start) < abs(best!.location - start) {
                best = found
            }
            let next = NSMaxRange(found)
            searchRange = NSRange(location: next, length: ns.length - next)
        }
        return best
    }
}
