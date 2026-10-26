// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// Lightweight HTML-to-text extraction used for EPUB chapters, HTML files and
/// chapter titles. It intentionally avoids WebKit so it can run off the main
/// thread during import.
public enum HTMLText {
    public static func plainText(from data: Data) -> String {
        let raw = TextFileDecoder.decode(data) ?? ""
        return plainText(from: raw)
    }

    public static func plainText(from html: String) -> String {
        convert(html).text
    }

    /// Reading text plus the UTF-16 offset of every element `id` (and `<a
    /// name>`), so EPUB chapters can be split exactly where the table of
    /// contents points.
    public struct Conversion: Sendable {
        public var text: String
        public var anchors: [String: Int]
    }

    private static let skippedTags: Set<String> = [
        "footer", "nav", "noscript", "form", "button", "svg"
    ]

    private static let blockTags: Set<String> = [
        "p", "div", "h1", "h2", "h3", "h4", "h5", "h6", "li", "blockquote", "section",
        "article", "header", "footer", "aside", "nav", "figure", "figcaption", "table",
        "tr", "ul", "ol", "dl", "dt", "dd", "hr", "pre", "body", "main", "address", "center"
    ]

    /// HTML to clean reading text, built for both the reader and narration:
    /// whitespace and source line breaks inside a paragraph collapse to single
    /// spaces (HTML semantics; Project Gutenberg files wrap every line), block
    /// elements become paragraph breaks, `<br>` a line break, and inline tags
    /// add nothing (no stray space before "." after `</i>`). Footnote call
    /// markers and page-number markers are left out, so narration does not
    /// read "12" in the middle of a sentence.
    public static func convert(_ html: String) -> Conversion {
        var source = html
        for pattern in ["(?is)<script[^>]*>.*?</script>", "(?is)<style[^>]*>.*?</style>",
                        "(?is)<head[^>]*>.*?</head>", "(?s)<!--.*?-->"] {
            source = source.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        let chars = Array(source.utf16)
        var out: [UInt16] = []
        out.reserveCapacity(chars.count)
        var anchors: [String: Int] = [:]
        var pendingSpace = false
        var inPre = false
        var skipTag: String?
        var skipDepth = 0
        var listStack: [(ordered: Bool, count: Int)] = []
        var tableCells = 0

        func lastIsNewline() -> Bool { out.last == 10 }
        func trimTrailingSpaces() { while out.last == 32 { out.removeLast() } }
        func breakLine(_ count: Int) {
            trimTrailingSpaces()
            guard !out.isEmpty else { pendingSpace = false; return }
            var existing = 0
            var index = out.count - 1
            while index >= 0, out[index] == 10 { existing += 1; index -= 1 }
            for _ in existing..<max(existing, count) { out.append(10) }
            pendingSpace = false
        }
        func emit(_ units: [UInt16]) {
            guard skipTag == nil else { return }
            if pendingSpace, !out.isEmpty, !lastIsNewline() { out.append(32) }
            pendingSpace = false
            out.append(contentsOf: units)
        }

        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == 60 /* < */, i + 1 < chars.count, isTagStart(chars[i + 1]) {
                guard let close = chars[i...].firstIndex(of: 62 /* > */) else { break }
                let tag = String(decoding: chars[(i + 1)..<close], as: UTF16.self)
                i = close + 1
                let isClosing = tag.hasPrefix("/")
                let body = isClosing ? String(tag.dropFirst()) : tag
                let name = body.prefix { !$0.isWhitespace && $0 != "/" && $0 != ">" }.lowercased()
                guard !name.isEmpty, !name.hasPrefix("!"), !name.hasPrefix("?") else { continue }
                let selfClosing = body.hasSuffix("/") || ["br", "hr", "img", "meta", "link", "input", "col", "wbr"].contains(name)

                if let skipping = skipTag {
                    if name == skipping, !selfClosing {
                        skipDepth += isClosing ? -1 : 1
                        if skipDepth == 0 { skipTag = nil }
                    }
                    continue
                }
                if !isClosing, skippedTags.contains(name), !selfClosing {
                    skipTag = name
                    skipDepth = 1
                    continue
                }
                if !isClosing, name == "div",
                   let classes = attribute(classPattern, in: body)?.lowercased(),
                   classes.split(whereSeparator: { $0 == " " || $0 == "\t" })
                       .contains(where: { $0 == "figcenter" || $0 == "caption" }) {
                    // Illustration wrappers and their captions are not prose.
                    // The image itself is not rendered by the text reader.
                    skipTag = name
                    skipDepth = 1
                    continue
                }
                let anchor = isClosing ? nil
                    : attribute(idPattern, in: body) ?? (name == "a" ? attribute(namePattern, in: body) : nil)
                if !isClosing, !blockTags.contains(name) {
                    let lower = body.lowercased()
                    if lower.contains("noteref") || lower.contains("pagebreak") || lower.contains("pagenum") {
                        // Footnote calls and page numbers: not part of the prose.
                        if let anchor { anchors[anchor] = out.count }
                        if !selfClosing { skipTag = name; skipDepth = 1 }
                        continue
                    }
                }
                if name == "ul" || name == "ol" {
                    if isClosing {
                        if !listStack.isEmpty { listStack.removeLast() }
                        breakLine(2)
                    } else {
                        breakLine(2)
                        let start = Int(attribute(attributePattern("start"), in: body) ?? "") ?? 1
                        listStack.append((name == "ol", max(0, start - 1)))
                    }
                    continue
                }
                if name == "li" {
                    if isClosing {
                        breakLine(1)
                    } else {
                        if listStack.isEmpty {
                            listStack.append((false, 0))
                        }
                        listStack[listStack.count - 1].count += 1
                        breakLine(1)
                        let item = listStack[listStack.count - 1]
                        let depth = max(0, listStack.count - 1)
                        let marker = item.ordered ? "\(item.count). " : "• "
                        out.append(contentsOf: Array(String(repeating: "  ", count: depth).utf16))
                        out.append(contentsOf: Array(marker.utf16))
                        pendingSpace = false
                    }
                    continue
                }
                if name == "table" {
                    breakLine(2)
                    if isClosing { tableCells = 0 }
                    continue
                }
                if name == "tr" {
                    breakLine(1)
                    if !isClosing { tableCells = 0 }
                    continue
                }
                if name == "td" || name == "th" {
                    if !isClosing {
                        if tableCells > 0 {
                            out.append(contentsOf: Array(" | ".utf16))
                        }
                        tableCells += 1
                        pendingSpace = false
                    }
                    continue
                }
                if blockTags.contains(name) {
                    breakLine(2)
                } else if name == "br" {
                    breakLine(1)
                }
                if name == "pre" { inPre = !isClosing }
                if let id = anchor {
                    if pendingSpace, !out.isEmpty, !lastIsNewline() { out.append(32); pendingSpace = false }
                    anchors[id] = out.count
                }
                continue
            }
            if c == 38 /* & */, let semicolon = chars[i...].prefix(12).firstIndex(of: 59 /* ; */) {
                let entity = "&" + String(decoding: chars[(i + 1)...semicolon], as: UTF16.self)
                let decoded = decodeEntities(entity)
                if decoded != entity {
                    i = semicolon + 1
                    if decoded == " " { pendingSpace = true } else { emit(Array(decoded.utf16)) }
                    continue
                }
            }
            if c == 32 || c == 9 || c == 10 || c == 13 || c == 0xA0 || c == 12 {
                if inPre, c == 10 { breakLine(1) } else { pendingSpace = true }
            } else {
                emit([c])
            }
            i += 1
        }
        trimTrailingSpaces()
        while out.last == 10 { out.removeLast() }
        let text = String(decoding: out, as: UTF16.self)
        let length = out.count
        return Conversion(text: text, anchors: anchors.mapValues { min($0, length) })
    }

    private static func isTagStart(_ unit: UInt16) -> Bool {
        // Letters, "/", "!" and "?": anything else is a literal "<" in text.
        (unit >= 65 && unit <= 90) || (unit >= 97 && unit <= 122) || unit == 47 || unit == 33 || unit == 63
    }

    private static let idPattern = attributePattern("id")
    private static let classPattern = attributePattern("class")
    private static let namePattern = attributePattern("name")

    private static func attributePattern(_ name: String) -> NSRegularExpression? {
        try? NSRegularExpression(
            pattern: "(?i)(?:^|\\s)\(name)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s>]+))"
        )
    }

    private static func attribute(_ regex: NSRegularExpression?, in tag: String) -> String? {
        guard let regex, tag.count > 3 else { return nil }
        let range = NSRange(tag.startIndex..<tag.endIndex, in: tag)
        guard let match = regex.firstMatch(in: tag, range: range) else { return nil }
        for group in 1...3 {
            if let value = Range(match.range(at: group), in: tag) { return String(tag[value]) }
        }
        return nil
    }

    /// Whether the document has an `<h1>`–`<h3>`: a page that opens a section
    /// of its own rather than continuing the previous one.
    public static func hasSectionHeading(_ html: String) -> Bool {
        html.range(of: "(?i)<h[1-3][\\s>]", options: .regularExpression) != nil
    }

    /// The document's `<h1>`, when it has one. Standalone HTML articles often
    /// put the real title here while the first `<h2>` is only a section.
    public static func firstH1(from data: Data) -> String? {
        let html = TextFileDecoder.decode(data) ?? ""
        guard let match = firstMatch("(?is)<h1[^>]*>(.*?)</h1>", in: html) else { return nil }
        let cleaned = normalize(decodeEntities(stripTags(match)))
        return cleaned.isEmpty ? nil : cleaned
    }

    /// First heading or `<title>` in the document, used as the chapter label.
    public static func firstHeading(from data: Data) -> String? {
        let html = TextFileDecoder.decode(data) ?? ""
        for pattern in ["(?is)<h1[^>]*>(.*?)</h1>", "(?is)<h2[^>]*>(.*?)</h2>", "(?is)<title[^>]*>(.*?)</title>"] {
            if let match = firstMatch(pattern, in: html) {
                let cleaned = normalize(decodeEntities(stripTags(match)))
                if !cleaned.isEmpty { return cleaned }
            }
        }
        return nil
    }

    /// The document's `<title>`, without falling back to its headings.
    public static func documentTitle(from data: Data) -> String? {
        let html = TextFileDecoder.decode(data) ?? ""
        guard let match = firstMatch("(?is)<title[^>]*>(.*?)</title>", in: html) else { return nil }
        let cleaned = normalize(decodeEntities(stripTags(match)))
        return cleaned.isEmpty ? nil : cleaned
    }

    public static func normalize(_ text: String) -> String {
        var value = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
        value = value.replacingOccurrences(of: "[\\t ]+", with: " ", options: .regularExpression)
        value = value.replacingOccurrences(of: " *\\n *", with: "\n", options: .regularExpression)
        value = value.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stripTags(_ text: String) -> String {
        text.replacingOccurrences(of: "(?is)<[^>]+>", with: " ", options: .regularExpression)
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges > 1,
              let capture = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[capture])
    }

    private static func decodeEntities(_ text: String) -> String {
        var value = text
        let named: [String: String] = [
            "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'",
            "nbsp": " ", "mdash": "—", "ndash": "–", "hellip": "…",
            "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”",
            "copy": "©", "reg": "®", "trade": "™", "deg": "°",
            "aacute": "á", "eacute": "é", "iacute": "í", "oacute": "ó", "uacute": "ú",
            "ntilde": "ñ", "Aacute": "Á", "Eacute": "É", "Iacute": "Í", "Oacute": "Ó",
            "Uacute": "Ú", "Ntilde": "Ñ", "uuml": "ü", "ouml": "ö", "auml": "ä",
            "szlig": "ß", "ccedil": "ç", "agrave": "à", "egrave": "è"
        ]

        guard let regex = try? NSRegularExpression(pattern: "&(#x?[0-9A-Fa-f]+|[A-Za-z]+);") else {
            return value
        }
        let matches = regex.matches(in: value, range: NSRange(value.startIndex..<value.endIndex, in: value))
        for match in matches.reversed() {
            guard let full = Range(match.range, in: value),
                  let bodyRange = Range(match.range(at: 1), in: value) else { continue }
            let body = String(value[bodyRange])
            var replacement: String?
            if body.hasPrefix("#x") || body.hasPrefix("#X") {
                if let scalar = UInt32(body.dropFirst(2), radix: 16), let unicode = UnicodeScalar(scalar) {
                    replacement = String(unicode)
                }
            } else if body.hasPrefix("#") {
                if let scalar = UInt32(body.dropFirst(), radix: 10), let unicode = UnicodeScalar(scalar) {
                    replacement = String(unicode)
                }
            } else {
                replacement = named[body]
            }
            if let replacement {
                value.replaceSubrange(full, with: replacement)
            }
        }
        return value
    }
}
