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
        let layer = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !layer.isEmpty, !isGarbled(layer) { return layer }
        guard allowOCR, let lines = try? recognizeLines(page: page), !lines.isEmpty else { return nil }
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
