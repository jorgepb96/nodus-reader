// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import CryptoKit

struct PronunciationRule: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var written: String
    var spoken: String
}

struct PreparedPronunciation: Sendable {
    struct Span: Sendable {
        var original: NSRange
        var spoken: NSRange
        var replaced: Bool
    }
    let original: String
    let spoken: String
    let spans: [Span]
    var signature: String {
        guard original != spoken else { return "" }
        let map = spans.map { "\($0.original.location):\($0.original.length):\($0.spoken.location):\($0.spoken.length):\($0.replaced)" }.joined(separator: ";")
        return SHA256.hash(data: Data((spoken + "|" + map).utf8)).map { String(format: "%02x", $0) }.joined()
    }
    func project(_ words: [NarrationWordTiming]) -> [NarrationWordTiming] {
        guard original != spoken else { return words }
        var result: [NarrationWordTiming] = []
        for word in words {
            let range = NSRange(location: word.location, length: word.length)
            for span in spans where NSIntersectionRange(span.spoken, range).length > 0 {
                let overlap = NSIntersectionRange(span.spoken, range)
                let source = span.replaced ? span.original : NSRange(location: span.original.location + overlap.location - span.spoken.location, length: overlap.length)
                if let last = result.last, last.location == source.location, last.length == source.length {
                    result[result.count - 1].end = max(last.end, word.end)
                } else {
                    result.append(NarrationWordTiming(location: source.location, length: source.length, start: word.start, end: word.end))
                }
            }
        }
        return result
    }
}

enum PronunciationTransformer {
    static func prepare(_ text: String, rules: [PronunciationRule]) -> PreparedPronunciation {
        let ns = text as NSString
        var matches: [(NSRange, String)] = []
        for rule in rules where !rule.written.isEmpty && !rule.spoken.isEmpty {
            // NSString search preserves the source's UTF-16 offsets and canonical Unicode equivalence.
            var cursor = 0
            while cursor < ns.length {
                let found = ns.range(of: rule.written, options: [], range: NSRange(location: cursor, length: ns.length - cursor))
                guard found.location != NSNotFound else { break }
                let letters = CharacterSet.alphanumerics.union(.nonBaseCharacters).union(CharacterSet(charactersIn: "_"))
                func isWord(_ index: Int) -> Bool {
                    guard index >= 0 && index < ns.length, let scalar = UnicodeScalar(ns.character(at: index)) else { return false }
                    return letters.contains(scalar)
                }
                if !isWord(found.location - 1) && !isWord(NSMaxRange(found)) { matches.append((found, rule.spoken)) }
                cursor = NSMaxRange(found)
            }
        }
        matches.sort { $0.0.location == $1.0.location ? $0.0.length > $1.0.length : $0.0.location < $1.0.location }
        var output = ""
        var spans: [PreparedPronunciation.Span] = []
        var cursor = 0
        func append(_ range: NSRange, _ replacement: String?, replaced: Bool) {
            guard range.length > 0 else { return }
            let value = replacement ?? ns.substring(with: range)
            let start = (output as NSString).length
            output += value
            spans.append(.init(original: range, spoken: NSRange(location: start, length: (value as NSString).length), replaced: replaced))
        }
        for (range, value) in matches where range.location >= cursor {
            append(NSRange(location: cursor, length: range.location - cursor), nil, replaced: false)
            append(range, value, replaced: true)
            cursor = NSMaxRange(range)
        }
        append(NSRange(location: cursor, length: ns.length - cursor), nil, replaced: false)
        return PreparedPronunciation(original: text, spoken: output, spans: spans)
    }
}

extension Book {
    var pronunciations: [PronunciationRule] {
        get { (try? JSONDecoder().decode([PronunciationRule].self, from: Data(pronunciationsJSON.utf8))) ?? [] }
        set { pronunciationsJSON = String(data: (try? JSONEncoder().encode(newValue)) ?? Data(), encoding: .utf8) ?? "" }
    }
}
