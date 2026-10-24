// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import PDFKit

/// Extracts import-time metadata and searchable text. Rendering is handled by
/// the readers; this type is safe to run off the main thread.
public enum DocumentExtractor {
    public static func extract(url: URL, format: BookFormat) throws -> DocumentExtraction {
        let fallbackTitle = fallbackTitle(for: url)
        switch format {
        case .epub:
            return try EPUBParser.parse(url: url, fallbackTitle: fallbackTitle)
        case .pdf:
            return try extractPDF(url: url, fallbackTitle: fallbackTitle)
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

    private static func extractPDF(url: URL, fallbackTitle: String) throws -> DocumentExtraction {
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
        let pageLimit = min(document.pageCount, 80)
        for index in 0..<pageLimit {
            guard let page = document.page(at: index), let text = page.string else { continue }
            let cleaned = HTMLText.normalize(text)
            guard !cleaned.isEmpty else { continue }
            chapters.append(ExtractedChapter(id: index, title: "Page \(index + 1)", text: cleaned))
            extractedCharacters += cleaned.count
            if extractedCharacters > 500_000 { break }
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
        let text = HTMLText.normalize(attributed.string)
        guard !text.isEmpty else {
            throw ImportError.emptyDocument(url.lastPathComponent)
        }
        let chapter = ExtractedChapter(id: 0, title: fallbackTitle, text: text)
        return DocumentExtraction(title: fallbackTitle, author: "", language: LanguageDetector.detect(in: text),
                                  chapters: [chapter])
    }
}

public enum MarkdownText {
    public static func plainText(_ source: String) -> String {
        var text = source
        text = text.replacingOccurrences(of: "(?m)^#{1,6}\\s*", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?m)^\\s*[-*+]\\s+", with: "• ", options: .regularExpression)
        text = text.replacingOccurrences(of: "!\\[([^\\]]*)\\]\\([^\\)]*\\)", with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: "\\[([^\\]]+)\\]\\([^\\)]*\\)", with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: "(\\*\\*|__)(.*?)\\1", with: "$2", options: .regularExpression)
        text = text.replacingOccurrences(of: "(\\*|_)(.*?)\\1", with: "$2", options: .regularExpression)
        text = text.replacingOccurrences(of: "`{1,3}", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?m)^>\\s?", with: "", options: .regularExpression)
        return text
    }
}
