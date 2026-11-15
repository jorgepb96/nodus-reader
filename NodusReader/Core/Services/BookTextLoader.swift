// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// Loads readable text for the reader, narration and search fallback.
/// EPUB is parsed with the import parser. PDF text comes from the Intelligent
/// Reading cache when it exists (its OCR is already done), otherwise from
/// PDFKit, with OCR for pages whose text layer is missing or garbled.
public enum BookTextLoader {
    /// The reader, narration, recaps and soundscapes all ask for the text of
    /// the book that is open. One extraction serves them all: a serial novel
    /// takes seconds to parse and a long PDF is read page by page, so every
    /// extra pass was a wait (narration parsed the book again after the
    /// reader had) and, for PDFs, another copy of the document in memory.
    public static func loadChapters(for book: Book, fileStore: FileStore = .shared) async throws -> [ExtractedChapter] {
        let url = fileStore.documentURL(for: book)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ImportError.fileAccessDenied(book.fileName)
        }
        let format = book.format
        // A PDF reads from the Intelligent Reading cache once it is complete:
        // its text (and every offset in it) then differs from PDFKit's.
        let reflow = format == .pdf
            ? Self.modificationDate(PDFReflowStore(fileStore: fileStore).manifestURL(for: book.id)) : nil
        let key = BookTextCache.Key(bookID: book.id, contentHash: book.contentHash, path: url.path,
                                    modified: Self.modificationDate(url), reflowModified: reflow)
        return try await BookTextCache.shared.chapters(for: key) {
            try await extractChapters(url: url, format: format, bookID: key.bookID,
                                      contentHash: key.contentHash, fileStore: fileStore)
        }
    }

    private static func modificationDate(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    private static func extractChapters(url: URL, format: BookFormat, bookID: UUID, contentHash: String,
                                        fileStore: FileStore) async throws -> [ExtractedChapter] {
        try await Task.detached(priority: .userInitiated) {
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

/// The text of the book last opened, and the extraction in flight. Callers
/// that arrive while a book is being extracted wait for that same pass.
/// Only one book is kept: its chapters are the ones the reader already holds.
actor BookTextCache {
    struct Key: Hashable, Sendable {
        var bookID: UUID
        var contentHash: String
        var path: String
        var modified: Date?
        var reflowModified: Date?
    }

    static let shared = BookTextCache()

    private var cached: (key: Key, chapters: [ExtractedChapter])?
    private var inFlight: [Key: Task<[ExtractedChapter], Error>] = [:]

    func chapters(for key: Key,
                  extract: @escaping @Sendable () async throws -> [ExtractedChapter]) async throws -> [ExtractedChapter] {
        if let cached, cached.key == key { return cached.chapters }
        if let running = inFlight[key] { return try await running.value }
        // Not a child of the caller: a reader that closes must not cancel
        // the pass narration is also waiting for.
        let task = Task.detached(priority: .userInitiated) { try await extract() }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        let chapters = try await task.value
        if !chapters.isEmpty { cached = (key, chapters) }
        return chapters
    }

    func removeAll() {
        cached = nil
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
        return mergingFalseBoundaries(result, in: ns)
    }

    /// Titles and common abbreviations (English and Spanish) that end in a period
    /// without ending the sentence. "etc." and "no." are left out: they often do.
    private static let abbreviations: Set<String> = [
        "mr", "mrs", "ms", "dr", "st", "jr", "sr", "srs", "sra", "sras", "srta", "sres", "dña", "dª", "ud", "uds",
        "vd", "vds", "prof", "gen", "col", "capt", "lt", "sgt", "rev", "fr", "vs", "ej", "pág", "págs", "núm", "nº",
    ]

    /// The system tokenizer splits after "Sr." or "J." and between a quoted question and
    /// its "he asked": the voice then closes its intonation and pauses mid-sentence.
    /// Such pieces are joined back; real boundaries stay.
    private static func mergingFalseBoundaries(_ ranges: [NSRange], in ns: NSString) -> [NSRange] {
        guard var current = ranges.first else { return ranges }
        var merged: [NSRange] = []
        for next in ranges.dropFirst() {
            let gap = NSRange(location: NSMaxRange(current), length: max(0, next.location - NSMaxRange(current)))
            let sameParagraph = !ns.substring(with: gap).contains("\n")
            if sameParagraph, endsWithAbbreviation(ns.substring(with: current)) || startsInLowercase(ns.substring(with: next)) {
                current = NSRange(location: current.location, length: NSMaxRange(next) - current.location)
            } else {
                merged.append(current)
                current = next
            }
        }
        merged.append(current)
        return merged
    }

    private static func endsWithAbbreviation(_ sentence: String) -> Bool {
        guard sentence.hasSuffix(".") else { return false }
        let body = sentence.dropLast()
        let word = body.reversed().prefix { $0.isLetter || $0 == "ª" || $0 == "º" }
        // "Mary's." ends in a possessive, not an initial.
        if let before = body.dropLast(word.count).last, "'’".contains(before) { return false }
        let token = String(word.reversed()).lowercased()
        // A single letter is an initial ("J. R. R. Tolkien", "D. Quijote", "p. ej.").
        return token.count == 1 || abbreviations.contains(token)
    }

    /// "he asked" after a quoted question, "—dijo" after an exclamation.
    private static func startsInLowercase(_ sentence: String) -> Bool {
        guard let first = sentence.first(where: { $0.isLetter }) else { return false }
        return first.isLowercase
    }

    private static func isDecorativeSeparator(_ line: String) -> Bool {
        let marks = line.unicodeScalars.filter { !CharacterSet.whitespaces.contains($0) }
        // Recognise rules such as "_____", "---", "* * *" and Unicode
        // horizontal rules without stripping punctuation from actual prose.
        return marks.count >= 3 && marks.allSatisfy { separatorMarks.contains($0) }
    }

    private static let separatorMarks = CharacterSet(charactersIn: "_-–—―*⁂⁎~•·=─━═﹏＿－")
}

/// Lets `DispatchQueue.concurrentPerform` fill one slot per iteration: every
/// iteration writes only its own index, so the writes never overlap.
struct UnsafeSendableBuffer<Element>: @unchecked Sendable {
    let buffer: UnsafeMutableBufferPointer<Element>

    init(_ buffer: UnsafeMutableBufferPointer<Element>) {
        self.buffer = buffer
    }
}

struct UncheckedSendableBox<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}
