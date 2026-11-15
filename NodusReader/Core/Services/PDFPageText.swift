// SPDX-License-Identifier: AGPL-3.0-only
import CoreGraphics
import Foundation
import PDFKit
import Vision

/// Readable text for a PDF page. Many PDFs carry a text layer that does not
/// match what is drawn: fonts embedded without a Unicode map extract as
/// "6ïQkq_'QXKXnXqn…" although the page shows normal words. Such a layer is
/// recognised and replaced with Vision OCR of the rendered page, so Intelligent
/// Reading, narration and search read what the page actually shows.
public enum PDFPageText {
    /// One line read by OCR. `box` is normalized with a bottom-left origin.
    public struct RecognizedLine: Sendable {
        public var text: String
        public var box: CGRect
    }

    /// The page's text: its text layer when it reads as words, otherwise
    /// (with `allowOCR`) what OCR finds on the rendered page, or nil.
    public static func readableText(page: PDFPage, allowOCR: Bool) -> String? {
        let layer = PDFTextLayer.string(of: page)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !layer.isEmpty, !isGarbled(layer) { return layer }
        return allowOCR ? recognizedText(page: page) : nil
    }

    /// What OCR reads on the rendered page, or nil when it finds nothing.
    public static func recognizedText(page: PDFPage) -> String? {
        guard let lines = try? recognizeLines(page: page), !lines.isEmpty else { return nil }
        return lines.map(\.text).joined(separator: "\n")
    }

    // MARK: Garbled text layers

    private static let edgePunctuation = CharacterSet(charactersIn: ".,;:!?¿¡\"'’‘“”«»()[]{}—–-…*")
    private static let vowels = Set("aeiouyáéíóúàèìòùâêîôûäëïöüãõåæœø")

    /// True when most of the letters in `text` are not in anything that looks
    /// like a word: digits or symbols inside words, mixed case inside words
    /// ("QXKXnXqnNK") or Latin words without a vowel. Numbers and lone symbols
    /// are ignored, so tables and formulas do not count against a page.
    public static func isGarbled(_ text: String) -> Bool {
        var letters = 0
        var wordLetters = 0
        for token in text.split(whereSeparator: \.isWhitespace) {
            let core = String(token).trimmingCharacters(in: edgePunctuation)
            let count = core.reduce(0) { $0 + ($1.isLetter ? 1 : 0) }
            guard count > 0 else { continue }
            letters += count
            if looksLikeWord(core) { wordLetters += count }
        }
        guard letters >= 40 else { return false }
        return Double(wordLetters) < Double(letters) * 0.6
    }

    static func looksLikeWord(_ word: String) -> Bool {
        let characters = Array(word)
        guard characters.allSatisfy({ $0.isLetter || "'’-.".contains($0) }) else { return false }
        let letters = characters.filter(\.isLetter)
        guard !letters.isEmpty else { return false }
        let uppercase = letters.filter(\.isUppercase).count
        let allCaps = uppercase == letters.count
        // lowercase, Capitalized or an all-caps word or acronym.
        guard uppercase == 0 || allCaps || (uppercase == 1 && letters[0].isUppercase) else { return false }
        let isLatin = letters.allSatisfy { $0.unicodeScalars.allSatisfy { $0.value < 0x250 } }
        if isLatin, letters.count > 1, !allCaps,
           !letters.contains(where: { vowels.contains(Character($0.lowercased())) }) {
            return false
        }
        return true
    }

    // MARK: OCR

    /// Text lines Vision reads on the rendered page, in its reading order.
    public static func recognizeLines(page: PDFPage) throws -> [RecognizedLine] {
        // Vision and PDFKit create large temporary images. Drain them after
        // each page; otherwise a long scanned book can exhaust the process
        // and later pages return only a handful of lines.
        try autoreleasepool {
            let bounds = page.bounds(for: .cropBox)
            guard let image = render(page: page, bounds: bounds, scale: 2) else { return [] }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.automaticallyDetectsLanguage = true
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
            return (request.results ?? []).compactMap { observation in
                guard let candidate = observation.topCandidates(1).first else { return nil }
                let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                return RecognizedLine(text: text, box: observation.boundingBox)
            }
        }
    }

    /// The page drawn on white at `scale` times its size.
    public static func render(page: PDFPage, bounds: CGRect, scale: CGFloat) -> CGImage? {
        let width = Int(bounds.width * scale)
        let height = Int(bounds.height * scale)
        guard width > 1, height > 1,
              let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -bounds.minX, y: -bounds.minY)
        page.draw(with: .cropBox, to: context)
        return context.makeImage()
    }
}

/// The text layer of a PDF page, read defensively.
///
/// `PDFPage.string` lays the page out in reading order. On some pages (a
/// dense, multi-column index) that layout allocates without bound and throws
/// `std::bad_alloc`, which closed the app while it was reading a long book in
/// the background. The exception is caught, and the page is remembered: it is
/// never laid out again and is read with OCR instead. A page that was being
/// read when the app died (the system can end it for memory before the
/// exception is thrown) is treated the same way the next time.
public enum PDFTextLayer {
    public static func string(of page: PDFPage) -> String? {
        guard let document = page.document, let key = PDFTextLayerJournal.key(for: document) else {
            return guardedString(of: page).text
        }
        let index = document.index(for: page)
        guard index != NSNotFound else { return guardedString(of: page).text }
        let journal = PDFTextLayerJournal.shared
        guard journal.begin(document: key, page: index) else { return nil }
        let result = guardedString(of: page)
        journal.end(document: key, page: index, failed: result.failed)
        return result.text
    }

    private static func guardedString(of page: PDFPage) -> (text: String?, failed: Bool) {
        var text: String?
        let completed = NodusPerformCatchingExceptions {
            text = page.string
        }
        return (completed ? text : nil, !completed)
    }
}

/// Which pages' text layers must not be read, and which are being read now.
/// Both are written to disk as they change, so they survive the app being
/// closed in the middle of a page.
final class PDFTextLayerJournal: @unchecked Sendable {
    static let shared = PDFTextLayerJournal(directory: defaultDirectory)

    private static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("PDFTextLayer", isDirectory: true)
    }

    /// A document is known by its file name and size: stored books are named
    /// after their identifier, and the container path can change.
    static func key(for document: PDFDocument) -> String? {
        guard let url = document.documentURL else { return nil }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        return "\(url.lastPathComponent)|\(size)"
    }

    private let lock = NSLock()
    private let skippedURL: URL
    private let pendingURL: URL
    private var skipped: [String: Set<Int>] = [:]
    private var pending: [String] = []

    init(directory: URL) {
        skippedURL = directory.appendingPathComponent("skipped.json")
        pendingURL = directory.appendingPathComponent("pending.txt")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: skippedURL),
           let stored = try? JSONDecoder().decode([String: Set<Int>].self, from: data) {
            skipped = stored
        }
        // Pages the app was reading when it last ended.
        if let left = try? String(contentsOf: pendingURL, encoding: .utf8) {
            var changed = false
            for line in left.split(separator: "\n") {
                let parts = line.split(separator: "\t")
                guard parts.count == 2, let page = Int(parts[1]) else { continue }
                changed = skipped[String(parts[0]), default: []].insert(page).inserted || changed
            }
            if changed { saveSkipped() }
            try? FileManager.default.removeItem(at: pendingURL)
        }
    }

    func isSkipped(document: String, page: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return skipped[document]?.contains(page) == true
    }

    /// False when the page's text layer must not be read.
    func begin(document: String, page: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard skipped[document]?.contains(page) != true else { return false }
        pending.append("\(document)\t\(page)")
        savePending()
        return true
    }

    func end(document: String, page: Int, failed: Bool) {
        lock.lock()
        defer { lock.unlock() }
        if let index = pending.firstIndex(of: "\(document)\t\(page)") { pending.remove(at: index) }
        savePending()
        if failed, skipped[document, default: []].insert(page).inserted { saveSkipped() }
    }

    private func savePending() {
        // Not atomic on purpose: this runs twice per page, and the bytes
        // reach the file even if the process ends right after.
        try? Data(pending.joined(separator: "\n").utf8).write(to: pendingURL)
    }

    private func saveSkipped() {
        guard let data = try? JSONEncoder().encode(skipped) else { return }
        try? data.write(to: skippedURL, options: .atomic)
    }
}
