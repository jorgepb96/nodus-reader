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
            if format == .pdf,
               let reflow = PDFReflowStore(fileStore: fileStore).load(bookID: bookID, contentHash: contentHash),
               reflow.pageCount == reflow.totalPageCount {
                let chapters = reflow.pages.compactMap { page -> ExtractedChapter? in
                    let text = page.canonicalLayout.text
                    guard !text.isEmpty else { return nil }
                    return ExtractedChapter(id: page.pageIndex,
                                            title: String(localized: "Page \(page.pageIndex + 1)"), text: text)
                }
                if !chapters.isEmpty { return chapters }
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
        let normalized = text.replacingOccurrences(of: "\n", with: " ")
        var result: [String] = []
        normalized.enumerateSubstrings(in: normalized.startIndex..<normalized.endIndex,
                                       options: [.bySentences, .substringNotRequired]) { _, range, _, _ in
            let sentence = normalized[range].trimmingCharacters(in: .whitespacesAndNewlines)
            if !sentence.isEmpty { result.append(sentence) }
        }
        if result.isEmpty, !normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result = [normalized.trimmingCharacters(in: .whitespacesAndNewlines)]
        }
        return result
    }
}
