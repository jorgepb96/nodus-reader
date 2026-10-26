// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import PDFKit

/// Extracts import-time metadata and searchable text. Rendering is handled by
/// the readers; this type is safe to run off the main thread.
public enum DocumentExtractor {
    /// - Parameter completeText: import only needs a bounded sample for
    ///   metadata and search, but narration needs every page. Without it a
    ///   long PDF stopped after page 80 and was then marked Finished.
    public static func extract(url: URL, format: BookFormat,
                               completeText: Bool = false) throws -> DocumentExtraction {
        let fallbackTitle = fallbackTitle(for: url)
        switch format {
        case .epub:
            return try EPUBParser.parse(url: url, fallbackTitle: fallbackTitle)
        case .pdf:
            return try extractPDF(url: url, fallbackTitle: fallbackTitle, completeText: completeText)
        case .txt, .markdown:
            return try extractText(url: url, format: format, fallbackTitle: fallbackTitle)
        case .html:
            return try extractHTML(url: url, fallbackTitle: fallbackTitle)
        case .rtf:
            return try extractRTF(url: url, fallbackTitle: fallbackTitle)
        }
    }

    public static func fallbackTitle(for url: URL) -> String {
        let name = url.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
        return name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - PDF

    private static func extractPDF(url: URL, fallbackTitle: String,
                                   completeText: Bool) throws -> DocumentExtraction {
        guard let document = PDFDocument(url: url) else {
            throw ImportError.unreadableDocument(url.lastPathComponent)
        }

        let attributes = document.documentAttributes
        let title = (attributes?[PDFDocumentAttribute.titleAttribute] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let author = (attributes?[PDFDocumentAttribute.authorAttribute] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let subject = (attributes?[PDFDocumentAttribute.subjectAttribute] as? String) ?? ""
        let creationDate = attributes?[PDFDocumentAttribute.creationDateAttribute] as? Date

        var published = ""
        if let creationDate {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy"
            published = formatter.string(from: creationDate)
        }

        var chapters: [ExtractedChapter] = []
        var extractedCharacters = 0
        let pageLimit = completeText ? document.pageCount : min(document.pageCount, 80)
        // Import reads a few pages with OCR when their text layer is garbled
        // or missing (enough for the language and search); narration reads
        // them all.
        var ocrBudget = completeText ? Int.max : 6
        for index in 0..<pageLimit {
            if completeText, Task.isCancelled { break }
            guard let page = document.page(at: index) else { continue }
            let layer = page.string ?? ""
            let layerReadable = !layer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !PDFPageText.isGarbled(layer)
            if !layerReadable { ocrBudget -= 1 }
            let text = PDFPageText.readableText(page: page, allowOCR: !layerReadable && ocrBudget >= 0) ?? ""
            let cleaned = HTMLText.normalize(text)
            // Narration keeps empty pages so that chapter N stays page N.
            guard !cleaned.isEmpty || completeText else { continue }
            chapters.append(ExtractedChapter(id: index, title: String(localized: "Page \(index + 1)"), text: cleaned))
            extractedCharacters += cleaned.count
            if !completeText, extractedCharacters > 500_000 { break }
        }

        let searchText = chapters.map(\.text).joined(separator: "\n\n")
        return DocumentExtraction(
            title: title.isEmpty ? fallbackTitle : title,
            author: author,
            language: LanguageDetector.detect(in: searchText),
            published: published,
            summary: HTMLText.plainText(from: subject),
            chapters: chapters,
            searchText: String(searchText.prefix(500_000))
        )
    }

    // MARK: - Plain text and Markdown

    private static func extractText(url: URL, format: BookFormat, fallbackTitle: String) throws -> DocumentExtraction {
        let data = try Data(contentsOf: url)
        guard let raw = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw ImportError.emptyDocument(url.lastPathComponent)
        }

        var title = fallbackTitle
        var body = raw
        if format == .markdown {
            if let heading = firstMarkdownHeading(in: raw) {
                title = heading
            }
            body = MarkdownText.plainText(raw)
        } else {
            body = PlainText.paragraphs(raw)
        }

        let normalized = HTMLText.normalize(body)
        guard !normalized.isEmpty else {
            throw ImportError.emptyDocument(url.lastPathComponent)
        }
        let chapter = ExtractedChapter(id: 0, title: title, text: normalized)
        return DocumentExtraction(title: title, author: "", language: LanguageDetector.detect(in: normalized),
                                  chapters: [chapter])
    }

    private static func firstMarkdownHeading(in text: String) -> String? {
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") {
                let title = trimmed.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
                if !title.isEmpty { return String(title) }
            }
        }
        return nil
    }

    // MARK: - HTML

    private static func extractHTML(url: URL, fallbackTitle: String) throws -> DocumentExtraction {
        let data = try Data(contentsOf: url)
        let text = HTMLText.plainText(from: data)
        guard !text.isEmpty else {
            throw ImportError.emptyDocument(url.lastPathComponent)
        }
        let title = HTMLText.firstHeading(from: data) ?? fallbackTitle
        let chapter = ExtractedChapter(id: 0, title: title, text: text)
        return DocumentExtraction(title: title, author: "", language: LanguageDetector.detect(in: text),
                                  chapters: [chapter])
    }

    // MARK: - RTF

    private static func extractRTF(url: URL, fallbackTitle: String) throws -> DocumentExtraction {
        let data = try Data(contentsOf: url)
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.rtf,
            .characterEncoding: String.Encoding.utf8.rawValue
        ]
        guard let attributed = try? NSAttributedString(data: data, options: options, documentAttributes: nil) else {
            throw ImportError.unreadableDocument(url.lastPathComponent)
        }
        let text = PlainText.paragraphs(attributed.string)
        guard !text.isEmpty else {
            throw ImportError.emptyDocument(url.lastPathComponent)
        }
        let chapter = ExtractedChapter(id: 0, title: fallbackTitle, text: text)
        return DocumentExtraction(title: fallbackTitle, author: "", language: LanguageDetector.detect(in: text),
                                  chapters: [chapter])
    }
}

public enum MarkdownText {
    /// Markdown to clean reading text. Soft line breaks inside a paragraph are
    /// joined, list items stay one per line, and code keeps its line breaks.
    /// The reader displays this text; the original Markdown is not rendered.
    public static func plainText(_ source: String) -> String {
        let lines = source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")

        var blocks: [String] = []
        var paragraph: [String] = []
        var listItems: [(ordered: Bool, text: String)] = []
        var quote: [String] = []
        var tableRows: [[String]] = []
        var code: [String] = []
        var inCode = false
        var index = 0

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            let text = inline(paragraph.joined(separator: " "))
            if !text.isEmpty { blocks.append(text) }
            paragraph = []
        }

        func flushList() {
            guard !listItems.isEmpty else { return }
            var rendered: [String] = []
            var number = 1
            for item in listItems {
                if item.ordered {
                    rendered.append("\(number). \(item.text)")
                    number += 1
                } else {
                    rendered.append("• \(item.text)")
                }
            }
            blocks.append(rendered.joined(separator: "\n"))
            listItems = []
        }

        func flushQuote() {
            guard !quote.isEmpty else { return }
            let text = inline(quote.joined(separator: " "))
            if !text.isEmpty { blocks.append(text) }
            quote = []
        }

        func flushTable() {
            guard !tableRows.isEmpty else { return }
            blocks.append(tableRows.map { $0.joined(separator: " | ") }.joined(separator: "\n"))
            tableRows = []
        }

        func flushCode() {
            guard !code.isEmpty else { return }
            blocks.append(code.joined(separator: "\n"))
            code = []
        }

        func flushAll() {
            flushParagraph()
            flushList()
            flushQuote()
            flushTable()
            flushCode()
        }

        while index < lines.count {
            let raw = lines[index]
            let trimmed = raw.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                if inCode {
                    inCode = false
                    flushCode()
                } else {
                    flushParagraph()
                    flushList()
                    flushQuote()
                    flushTable()
                    inCode = true
                    code = []
                }
                index += 1
                continue
            }
            if inCode {
                code.append(raw)
                index += 1
                continue
            }
            if trimmed.isEmpty {
                flushAll()
                index += 1
                continue
            }
            if isHorizontalRule(trimmed) {
                flushAll()
                index += 1
                continue
            }
            if trimmed.range(of: #"^\[[^\]]+\]:\s+\S+"#, options: .regularExpression) != nil,
               !trimmed.hasPrefix("[^") {
                // A link-reference definition is metadata, not prose.
                flushAll()
                index += 1
                continue
            }
            if trimmed.hasPrefix("#") {
                flushAll()
                let heading = trimmed.drop(while: { $0 == "#" })
                    .trimmingCharacters(in: .whitespaces)
                    .replacingOccurrences(of: "#+$", with: "", options: .regularExpression)
                let text = inline(heading)
                if !text.isEmpty { blocks.append(text) }
                index += 1
                continue
            }
            if index + 1 < lines.count, isSetextUnderline(lines[index + 1]) {
                flushAll()
                blocks.append(inline(trimmed))
                index += 2
                continue
            }
            if trimmed.hasPrefix(">") {
                flushParagraph()
                flushList()
                flushTable()
                quote.append(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))
                index += 1
                continue
            }
            if let item = listMarker(trimmed) {
                flushParagraph()
                flushQuote()
                flushTable()
                if !listItems.isEmpty, listItems.last?.ordered != item.ordered {
                    flushList()
                }
                listItems.append((item.ordered, inline(item.text)))
                index += 1
                continue
            }
            if isTableRow(trimmed) {
                flushParagraph()
                flushList()
                flushQuote()
                if isTableSeparator(trimmed) {
                    index += 1
                    continue
                }
                tableRows.append(tableCells(trimmed).map(inline))
                index += 1
                continue
            }
            // A non-marker line after a list is a wrapped list item. A line
            // after a quote continues the quote.
            if !listItems.isEmpty {
                let last = listItems.count - 1
                listItems[last].text = inline(listItems[last].text + " " + trimmed)
                index += 1
                continue
            }
            if !quote.isEmpty {
                quote.append(trimmed)
                index += 1
                continue
            }
            flushList()
            flushTable()
            paragraph.append(trimmed)
            index += 1
        }
        flushAll()
        return blocks
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func listMarker(_ line: String) -> (ordered: Bool, text: String)? {
        if let range = line.range(of: #"^[-*+]\s+"#, options: .regularExpression) {
            return (false, String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces))
        }
        if let range = line.range(of: #"^\d{1,3}[.)]\s+"#, options: .regularExpression) {
            return (true, String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    private static func isHorizontalRule(_ line: String) -> Bool {
        line.range(of: #"^\s*(?:[-*_]\s*){3,}$"#, options: .regularExpression) != nil
    }

    private static func isSetextUnderline(_ line: String) -> Bool {
        line.range(of: #"^\s*(?:=+|-+)\s*$"#, options: .regularExpression) != nil
    }

    private static func isTableRow(_ line: String) -> Bool {
        let pipes = line.filter { $0 == "|" }.count
        return pipes >= 2 || (pipes >= 1 && (line.hasPrefix("|") || line.hasSuffix("|")))
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        line.range(of: #"^\s*\|?\s*:?-{2,}:?\s*(?:\|\s*:?-{2,}:?\s*)+\|?\s*$"#,
                   options: .regularExpression) != nil
    }

    private static func tableCells(_ line: String) -> [String] {
        var value = line.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("|") { value.removeFirst() }
        if value.hasSuffix("|") { value.removeLast() }
        return value.components(separatedBy: "|").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
    }

    /// Inline Markdown to readable text: images become their alt text, links
    /// their label, emphasis and code markers disappear.
    private static func inline(_ source: String) -> String {
        var value = source
        value = value.replacingOccurrences(of: #"!\[([^\]]*)\]\([^)]*\)"#, with: "$1",
                                           options: .regularExpression)
        value = value.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]*\)"#, with: "$1",
                                           options: .regularExpression)
        value = value.replacingOccurrences(of: #"\[([^\]]+)\]\[[^\]]*\]"#, with: "$1",
                                           options: .regularExpression)
        value = value.replacingOccurrences(of: #"\[\^[^\]]+\]"#, with: "", options: .regularExpression)
        value = value.replacingOccurrences(of: #"\*\*(.+?)\*\*"#, with: "$1", options: .regularExpression)
        value = value.replacingOccurrences(of: #"__(.+?)__"#, with: "$1", options: .regularExpression)
        value = value.replacingOccurrences(of: #"\*(.+?)\*"#, with: "$1", options: .regularExpression)
        value = value.replacingOccurrences(of: #"`+([^`]+)`+"#, with: "$1", options: .regularExpression)
        value = value.replacingOccurrences(of: #"~~(.+?)~~"#, with: "$1", options: .regularExpression)
        value = value.replacingOccurrences(of: #"(?i)<br\s*/?>"#, with: " ", options: .regularExpression)
        value = value.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        value = value.replacingOccurrences(of: #"\\([\\`*_{}\[\]()#+.!-])"#, with: "$1",
                                           options: .regularExpression)
        let entities = [
            "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'",
            "&nbsp;": " ", "&mdash;": "—", "&ndash;": "–", "&hellip;": "…",
            "&aacute;": "á", "&eacute;": "é", "&iacute;": "í", "&oacute;": "ó",
            "&uacute;": "ú", "&ntilde;": "ñ"
        ]
        for (entity, replacement) in entities {
            value = value.replacingOccurrences(of: entity, with: replacement)
        }
        value = value.replacingOccurrences(of: "[ ]{2,}", with: " ", options: .regularExpression)
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
