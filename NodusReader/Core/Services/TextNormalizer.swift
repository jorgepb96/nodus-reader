// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Decodes a text document without assuming one encoding. UTF-8 is preferred;
/// UTF-16 (with or without BOM) and Windows-1252/Latin-1/Mac Roman follow.
public enum TextFileDecoder {
    public static func decode(_ data: Data) -> String? {
        guard !data.isEmpty else { return "" }
        let bytes = [UInt8](data.prefix(4))
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]),
           let text = String(data: data, encoding: .utf8) {
            return clean(text)
        }
        if bytes.starts(with: [0xFF, 0xFE]),
           let text = String(data: data, encoding: .utf16LittleEndian) {
            return clean(text)
        }
        if bytes.starts(with: [0xFE, 0xFF]),
           let text = String(data: data, encoding: .utf16BigEndian) {
            return clean(text)
        }

        // UTF-16 without a BOM is common in Windows-generated .txt files.
        let sample = [UInt8](data.prefix(2048))
        if sample.count > 16 {
            let evenZeros = stride(from: 0, to: sample.count, by: 2).filter { sample[$0] == 0 }.count
            let oddZeros = stride(from: 1, to: sample.count, by: 2).filter { sample[$0] == 0 }.count
            if oddZeros > sample.count / 8, evenZeros < oddZeros / 3,
               let text = String(data: data, encoding: .utf16LittleEndian) {
                return clean(text)
            }
            if evenZeros > sample.count / 8, oddZeros < evenZeros / 3,
               let text = String(data: data, encoding: .utf16BigEndian) {
                return clean(text)
            }
        }

        if let text = String(data: data, encoding: .utf8) { return clean(text) }
        for encoding in [String.Encoding.windowsCP1252, .isoLatin1, .macOSRoman] {
            if let text = String(data: data, encoding: encoding) { return clean(text) }
        }
        return nil
    }

    private static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{FEFF}", with: "")
    }
}

/// Normalisation shared by the document parsers. It repairs the small
/// artefacts of PDF text layers (ligatures, soft hyphens, non-breaking spaces)
/// without touching the words themselves.
public enum TextNormalizer {
    private static let ligatures: [Character: String] = [
        "\u{FB00}": "ff", "\u{FB01}": "fi", "\u{FB02}": "fl",
        "\u{FB03}": "ffi", "\u{FB04}": "ffl", "\u{FB05}": "ft", "\u{FB06}": "st"
    ]

    /// A single line from a PDF, HTML or text document: no ligatures, no
    /// invisible characters, one space between words.
    public static func cleanLine(_ text: String) -> String {
        var value = ""
        value.reserveCapacity(text.count)
        for character in text {
            if let replacement = ligatures[character] {
                value += replacement
            } else {
                switch character {
                case "\u{00A0}", "\u{202F}", "\u{2007}", "\u{2009}", "\u{200A}":
                    value.append(" ")
                case "\u{00AD}", "\u{200B}", "\u{200C}", "\u{200D}", "\u{FEFF}":
                    continue
                case "\u{FFFD}":
                    continue
                default:
                    if let scalar = character.unicodeScalars.first,
                       scalar.value < 0x20, character != "\n", character != "\t" {
                        continue
                    }
                    value.append(character)
                }
            }
        }
        value = value.replacingOccurrences(of: "\t", with: " ")
        value = value.replacingOccurrences(of: "[ ]{2,}", with: " ", options: .regularExpression)
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A merged paragraph: the same repairs as a line, plus the punctuation
    /// spacing that PDF line joins tend to break.
    public static func cleanBlock(_ text: String) -> String {
        var value = cleanLine(text)
        // A URL that started a new line after a full stop.
        value = value.replacingOccurrences(of: "([.!?])(https?://)", with: "$1 $2", options: .regularExpression)
        // A sentence that started on the next visual line without a space.
        value = value.replacingOccurrences(of: "([.!?])([A-Z][a-z])", with: "$1 $2", options: .regularExpression)
        // A space before a comma, full stop or closing punctuation is a line
        // fragment, not typography.
        value = value.replacingOccurrences(of: " +([,.;:!?])", with: "$1", options: .regularExpression)
        value = value.replacingOccurrences(of: "([(¿¡]) +", with: "$1", options: .regularExpression)
        value = value.replacingOccurrences(of: " +(\\)|\\]|\\})", with: "$1", options: .regularExpression)
        value = value.replacingOccurrences(of: "[ ]{2,}", with: " ", options: .regularExpression)
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Joins the lines of a paragraph. A hyphen at the end of a line is
    /// resolved with `hyphenation` instead of being deleted unconditionally:
    /// "exam-" + "ple" is "example", but "English-to-" + "German" is
    /// "English-to-German".
    public static func joinLines(_ lines: [String], hyphenation: HyphenationResolver = .system) -> String {
        var result = ""
        for raw in lines {
            let line = cleanLine(raw)
            guard !line.isEmpty else { continue }
            if result.isEmpty {
                result = line
                continue
            }
            if result.hasSuffix("-"), !result.hasSuffix("--") {
                result = hyphenation.join(prefix: result, suffix: line)
            } else if result.hasSuffix("—") || result.hasSuffix("–") {
                result += line
            } else if line.first.map({ ".,;:!?)]}»”’".contains($0) }) == true {
                result += line
            } else {
                result += " " + line
            }
        }
        return cleanBlock(result)
    }

    /// Vision sometimes returns Cyrillic lookalikes for Latin glyphs in a
    /// Spanish/English page. Repair only when Latin clearly dominates, so a
    /// genuine Russian page is left alone.
    public static func repairLatinOCR(_ text: String) -> String {
        let scalars = text.unicodeScalars
        let cyrillic = scalars.filter { (0x0400...0x04FF).contains($0.value) }.count
        let latin = scalars.filter { (0x0041...0x024F).contains($0.value) }.count
        guard cyrillic > 0, latin > cyrillic * 4 else { return text }
        let map: [Character: Character] = [
            "у": "y", "о": "o", "е": "e", "а": "a", "р": "p", "с": "c",
            "х": "x", "к": "k", "м": "m", "т": "t", "н": "h", "в": "b",
            "і": "i", "ї": "ï", "ј": "j", "ѕ": "s"
        ]
        return String(text.map { map[$0] ?? $0 })
    }

    /// OCR frequently reads a capital I in a Roman numeral as a lower-case l
    /// ("Il. Marco teórico"). Repair only the leading numeral of a line.
    public static func repairRomanOCR(_ text: String) -> String {
        var value = text
        for (bad, good) in [("IIl.", "III."), ("Il.", "II."), ("lII.", "III.")] {
            if value.hasPrefix(bad) {
                value = good + value.dropFirst(bad.count)
                break
            }
        }
        if value.hasSuffix("'"),
           value.dropLast().allSatisfy({ !$0.isLetter || $0.isUppercase || $0.isWhitespace }) {
            value.removeLast()
        }
        return value
    }

    /// True when a line is only a page number, "Page 12", "12 of 90" or a
    /// Roman folio. Used to keep running feet out of the body and the contents.
    public static func isPageNumber(_ text: String) -> Bool {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 40 else { return false }
        let patterns = [
            #"^page\s+\d{1,4}(?:\s*(?:of|/)\s*\d{1,4})?$"#,
            #"^p\.?\s*\d{1,4}$"#,
            #"^\d{1,4}\s*(?:of|/)\s*\d{1,4}$"#,
            #".*\bpage\s+\d{1,4}$"#,
            #"^page\s+[ivxlcdm]{1,8}$"#,
            #"^(?:p[áa]g(?:ina)?\.?)\s*\d{1,4}(?:\s*(?:de|/)\s*\d{1,4})?$"#
        ]
        return patterns.contains { value.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil }
    }

    /// A folio written as a bare number or a lower-case Roman numeral. It is
    /// only a page number near the top or bottom edge of the page: "9110" in
    /// an RFC header is a document number, not a folio.
    public static func isBarePageNumber(_ text: String) -> Bool {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 8 else { return false }
        return value.range(of: #"^\d{1,4}$"#, options: .regularExpression) != nil
            || value.range(of: #"^[ivxlcdm]{1,8}$"#, options: .regularExpression) != nil
    }
}

/// Decides whether a line-ending hyphen was a soft line break or a real
/// compound hyphen. The system spell checker is used when it is available;
/// tests can inject a deterministic checker.
public struct HyphenationResolver: Sendable {
    public typealias WordCheck = @Sendable (String) -> Bool

    private let isWord: WordCheck

    public init(isWord: @escaping WordCheck) {
        self.isWord = isWord
    }

    public static let system = HyphenationResolver { SystemWordCheck.isWord($0) }

    /// True when the joined form is a word. Used by tests and by the fallback
    /// heuristic; exposes the same checker the resolver uses.
    public func knows(_ word: String) -> Bool {
        isWord(word)
    }

    /// `prefix` ends with the hyphen that was at the end of the line.
    public func join(prefix: String, suffix: String) -> String {
        guard let regex = Self.trailingWord else {
            return String(prefix.dropLast()) + suffix
        }
        let ns = prefix as NSString
        guard let match = regex.firstMatch(in: prefix, range: NSRange(location: 0, length: ns.length)),
              let leftRange = Range(match.range(at: 1), in: prefix) else {
            return String(prefix.dropLast()) + suffix
        }
        let left = String(prefix[leftRange])
        let right = Self.leadingWord(in: suffix)
        guard !left.isEmpty, !right.isEmpty else {
            return String(prefix.dropLast()) + suffix
        }
        // A broken word starts in lower case. An upper-case continuation is a
        // compound ("English-Spanish") and keeps its hyphen.
        if let first = suffix.first, first.isUppercase {
            return prefix + suffix
        }
        if left.count <= 2 {
            return String(prefix.dropLast()) + suffix
        }
        let joined = left + right
        let hyphenated = left + "-" + right
        if isWord(joined) {
            return String(prefix.dropLast()) + suffix
        }
        if isWord(hyphenated) {
            return prefix + suffix
        }
        // Unknown technical words: keep the hyphen only when both sides are
        // complete words; otherwise it is far more likely a line break.
        if isWord(left), isWord(right) {
            return prefix + suffix
        }
        return String(prefix.dropLast()) + suffix
    }

    private static let trailingWord = try? NSRegularExpression(
        pattern: "([\\p{L}\\p{M}]+)-$", options: []
    )

    private static func leadingWord(in text: String) -> String {
        let scalars = text.unicodeScalars
        var result = ""
        for scalar in scalars {
            if CharacterSet.letters.contains(scalar) || CharacterSet.nonBaseCharacters.contains(scalar) {
                result.unicodeScalars.append(scalar)
            } else {
                break
            }
        }
        return result
    }
}

/// System spell checker wrapper. It is cached because a long PDF can contain
/// hundreds of line-ending hyphens. A serial queue keeps the AppKit/UIKit
/// checker away from the parser's concurrent callers.
private enum SystemWordCheck {
    private static let queue = DispatchQueue(label: "ai.nodus.reader.hyphenation")
    private static var cache: [String: Bool] = [:]

    static func isWord(_ word: String) -> Bool {
        let value = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count >= 3, value.contains(where: \.isLetter) else { return false }
        return queue.sync {
            if let cached = cache[value] { return cached }
            let result = check(value)
            if cache.count > 8_000 { cache.removeAll(keepingCapacity: true) }
            cache[value] = result
            return result
        }
    }

    private static func check(_ word: String) -> Bool {
        #if os(macOS)
        let checker = NSSpellChecker.shared
        if checker.checkSpelling(of: word, startingAt: 0).location == NSNotFound {
            return true
        }
        // A document may be in English while the Mac is set to Spanish (or the
        // reverse). Try the other common language before giving up.
        var wordCount = 0
        let english = checker.checkSpelling(
            of: word, startingAt: 0, language: "en", wrap: false,
            inSpellDocumentWithTag: 0, wordCount: &wordCount
        )
        return english.location == NSNotFound
        #else
        let languages = Array(Set([
            Locale.current.language.languageCode?.identifier ?? "en",
            "en"
        ]))
        for language in languages {
            let checker = UITextChecker()
            let range = checker.rangeOfMisspelledWord(
                in: word,
                range: NSRange(location: 0, length: (word as NSString).length),
                startingAt: 0,
                wrap: false,
                language: language
            )
            if range.location == NSNotFound { return true }
        }
        return false
        #endif
    }
}

/// Plain text from a .txt or RTF paragraph: blank lines separate paragraphs,
/// single line breaks inside a paragraph are wrapping.
public enum PlainText {
    public static func paragraphs(_ text: String) -> String {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\u{000C}", with: "\n\n")
        let blocks = normalized.replacingOccurrences(of: "\n{2,}", with: "\u{0001}", options: .regularExpression)
            .components(separatedBy: "\u{0001}")
        var result: [String] = []
        for block in blocks {
            let lines = block.components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard !lines.isEmpty else { continue }
            result.append(contentsOf: paragraphs(in: lines))
        }
        return result.joined(separator: "\n\n")
    }

    /// RTF's attributed string already has one newline per paragraph. Joining
    /// those lines would merge every paragraph in a Word-generated document.
    public static func rtfParagraphs(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { $0.replacingOccurrences(of: #"(?<=[A-Za-z])(?=\d)"#, with: " ", options: .regularExpression) }
            .joined(separator: "\n\n")
    }

    private static func paragraphs(in lines: [String]) -> [String] {
        if lines.contains(where: isListOrQuote) {
            return [lines.joined(separator: "\n")]
        }
        // A file whose paragraphs are one long line each.
        if lines.count > 1, lines.allSatisfy({ $0.count >= 50 && endsSentence($0) }) {
            return lines
        }

        var segments: [[String]] = []
        var current: [String] = []
        for line in lines {
            if isHeading(line) {
                if !current.isEmpty { segments.append(current); current = [] }
                segments.append([line])
            } else {
                current.append(line)
            }
        }
        if !current.isEmpty { segments.append(current) }

        var result: [String] = []
        for segment in segments {
            if segment.count == 1 {
                result.append(segment[0])
            } else if isVerse(segment) {
                // A single newline keeps the stanza together; blank lines only
                // separate stanzas.
                result.append(segment.joined(separator: "\n"))
            } else {
                result.append(contentsOf: splitProseLines(segment))
            }
        }
        return result
    }

    /// Raw text without blank lines still often marks a new paragraph with a
    /// short line: hard-wrapped prose fills the measure until the last line.
    private static func splitProseLines(_ lines: [String]) -> [String] {
        guard lines.count > 1 else { return lines }
        let lengths = lines.map(\.count).sorted()
        let median = lengths[lengths.count / 2]
        guard median > 0 else { return [TextNormalizer.joinLines(lines)] }
        var result: [String] = []
        var current: [String] = []
        for (index, line) in lines.enumerated() {
            current.append(line)
            guard index + 1 < lines.count else { continue }
            let next = lines[index + 1]
            let short = Double(line.count) < Double(median) * 0.9
            if short, endsSentence(line), next.first?.isUppercase == true {
                result.append(TextNormalizer.joinLines(current))
                current = []
            }
        }
        if !current.isEmpty { result.append(TextNormalizer.joinLines(current)) }
        return result
    }

    private static func isListOrQuote(_ line: String) -> Bool {
        line.range(of: #"^(?:[-*+•]|\d{1,3}[.)]|>)\s+\S"#, options: .regularExpression) != nil
    }

    private static func isHeading(_ line: String) -> Bool {
        guard line.count <= 100 else { return false }
        if line.range(of: #"(?i)^(chapter|capítulo|capitulo|part|parte|book|libro|act|acto|scene|escena)\b"#,
                      options: .regularExpression) != nil {
            return true
        }
        if line.range(of: #"^\d{1,3}\.?\s+\p{Lu}"#, options: .regularExpression) != nil {
            return true
        }
        if line.range(of: #"^[IVXLCDM]{1,8}\.?$"#, options: .regularExpression) != nil {
            return true
        }
        let letters = line.filter { $0.isLetter }
        let allCaps = !letters.isEmpty && line == line.uppercased()
        guard allCaps else { return false }
        return line.last.map { !".?!,;:".contains($0) } ?? true
    }

    private static func isVerse(_ lines: [String]) -> Bool {
        guard lines.count >= 3 else { return false }
        let lengths = lines.map(\.count).sorted()
        let median = lengths[lengths.count / 2]
        guard median < 40 else { return false }
        let terminal = lines.filter { line in
            guard let last = line.last else { return false }
            return ".?!".contains(last)
        }.count
        return terminal <= 1
    }

    private static func endsSentence(_ line: String) -> Bool {
        guard let last = line.last else { return false }
        return ".?!".contains(last)
    }
}

/// Repairs a paragraph that an illustration or a page-level wrapper split in
/// two. The source fragment starts in lower case and both halves are long
/// enough to be prose; short verse lines are left untouched.
public enum ParagraphJoiner {
    public static func join(_ text: String) -> String {
        let paragraphs = text.components(separatedBy: "\n\n")
        var result: [String] = []
        for raw in paragraphs {
            let paragraph = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !paragraph.isEmpty else { continue }
            if let last = result.last,
               last.count >= 80,
               paragraph.count >= 80,
               let lastCharacter = last.last, lastCharacter.isLetter,
               let firstCharacter = paragraph.first, firstCharacter.isLowercase {
                result[result.count - 1] = last + " " + paragraph
            } else {
                result.append(paragraph)
            }
        }
        return result.joined(separator: "\n\n")
    }
}

/// Project Gutenberg and Biblioteca Virtual Miguel de Cervantes add legal
/// headers, footers and generated-licence pages to their EPUBs. They are not
/// part of the book and must not become chapters or paragraphs.
enum EPUBTextCleaner {
    static func clean(_ text: String) -> String {
        var value = text
        value = stripProjectGutenberg(value)
        value = stripCervantesVirtual(value)
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stripProjectGutenberg(_ text: String) -> String {
        var value = text
        let start = #"(?is)\*{2,3}\s*START OF (?:THE|THIS) PROJECT GUTENBERG EBOOK.*?\*{2,3}"#
        if let range = value.range(of: start, options: .regularExpression) {
            value = String(value[range.upperBound...])
        }
        let end = #"(?is)\*{2,3}\s*END OF (?:THE|THIS) PROJECT GUTENBERG EBOOK.*?\*{2,3}"#
        if let range = value.range(of: end, options: .regularExpression) {
            value = String(value[..<range.lowerBound])
        }
        let lower = value.lowercased()
        if lower.contains("the project gutenberg ebook of"),
           lower.contains("release date:"),
           value.count < 5000 {
            return ""
        }
        if lower.contains("the full project gutenberg"),
           lower.contains("license") {
            return ""
        }
        return value
    }

    private static func stripCervantesVirtual(_ text: String) -> String {
        let lower = text.lowercased()
        guard lower.contains("este archivo fue generado de forma automática")
            || lower.contains("biblioteca virtual miguel de cervantes - universidad de alicante") else {
            return text
        }
        let lines = text.components(separatedBy: "\n")
        if let last = lines.lastIndex(where: {
            let line = $0.lowercased()
            return line.contains("creativecommons.org/licenses") || line.contains("licencia cc-by")
        }) {
            return lines[(last + 1)...].joined(separator: "\n")
        }
        return text
    }
}
