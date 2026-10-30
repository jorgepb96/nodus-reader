// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// Loads readable text for the reader, narration and search fallback.
/// EPUB is parsed with the import parser. PDF text comes from the Intelligent
/// Reading cache when it exists (its OCR is already done), otherwise from
/// PDFKit, with OCR for pages whose text layer is missing or garbled.
public enum BookTextLoader {
    public static func loadChapters(for book: Book, fileStore: FileStore = .shared) async throws -> [ExtractedChapter] {
        let url = fileStore.documentURL(for: book)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ImportError.fileAccessDenied(book.fileName)
        }
        let format = book.format
        let bookID = book.id
        let contentHash = book.contentHash
        return try await Task.detached(priority: .userInitiated) {
            // One chapter per page (empty pages too): chapter N is page N,
            // so narration starts on the page the reader shows.
            if format == .pdf,
               let reflow = PDFReflowStore(fileStore: fileStore).load(bookID: bookID, contentHash: contentHash),
               reflow.pageCount == reflow.totalPageCount {
                let pages = Dictionary(reflow.pages.map { ($0.pageIndex, $0) }, uniquingKeysWith: { first, _ in first })
                let chapters = (0..<reflow.pageCount).map { index in
                    ExtractedChapter(id: index, title: String(localized: "Page \(index + 1)"),
                                     text: pages[index]?.narrationText ?? "")
                }
                if chapters.contains(where: { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                    return chapters
                }
            }
            return try DocumentExtractor.extract(url: url, format: format, completeText: true).chapters
        }.value
    }

    public static func plainText(for book: Book, fileStore: FileStore = .shared) async throws -> String {
        let chapters = try await loadChapters(for: book, fileStore: fileStore)
        return chapters.map(\.text).joined(separator: "\n\n")
    }
}

/// Splits text into sentences for sentence-level narration, the default
/// synchronisation granularity from design/DESIGN.md.
public enum SentenceTokenizer {
    public static func sentences(from text: String) -> [String] {
        let ns = text as NSString
        return ranges(from: text).map {
            ns.substring(with: $0).replacingOccurrences(of: "\n", with: " ")
        }
    }

    /// Sentence ranges in the original UTF-16 text. Decorative rules are
    /// boundaries, even when the sentence tokenizer would attach them to the
    /// prose before or after them. Never rewrite the chapter: the reader and
    /// word alignment use these same offsets.
    static func ranges(from text: String) -> [NSRange] {
        let ns = text as NSString
        guard ns.length > 0 else { return [] }
        var result: [NSRange] = []

        func appendSentences(in segment: NSRange) {
            guard segment.length > 0 else { return }
            ns.enumerateSubstrings(in: segment, options: [.bySentences, .substringNotRequired]) { _, range, _, _ in
                let value = ns.substring(with: range) as NSString
                let content = value.rangeOfCharacter(from: .whitespacesAndNewlines.inverted)
                guard content.location != NSNotFound,
                      value.rangeOfCharacter(from: .alphanumerics).location != NSNotFound else { return }
                let lastContent = value.rangeOfCharacter(from: .whitespacesAndNewlines.inverted, options: .backwards)
                result.append(NSRange(location: range.location + content.location,
                                      length: NSMaxRange(lastContent) - content.location))
            }
        }

        var segmentStart = 0
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length),
                               options: [.byLines, .substringNotRequired]) { _, range, enclosingRange, _ in
            guard isDecorativeSeparator(ns.substring(with: range)) else { return }
            appendSentences(in: NSRange(location: segmentStart, length: range.location - segmentStart))
            segmentStart = NSMaxRange(enclosingRange)
        }
        appendSentences(in: NSRange(location: segmentStart, length: ns.length - segmentStart))
        return result
    }

    private static func isDecorativeSeparator(_ line: String) -> Bool {
        let marks = line.unicodeScalars.filter { !CharacterSet.whitespaces.contains($0) }
        // Recognise rules such as "_____", "---", "* * *" and Unicode
        // horizontal rules without stripping punctuation from actual prose.
        return marks.count >= 3 && marks.allSatisfy { separatorMarks.contains($0) }
    }

    private static let separatorMarks = CharacterSet(charactersIn: "_-–—―*⁂⁎~•·=─━═﹏＿－")
}
