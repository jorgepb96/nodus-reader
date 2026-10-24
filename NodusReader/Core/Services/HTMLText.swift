// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// Lightweight HTML-to-text extraction used for EPUB chapters, HTML files and
/// chapter titles. It intentionally avoids WebKit so it can run off the main
/// thread during import.
public enum HTMLText {
    public static func plainText(from data: Data) -> String {
        let raw = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""
        return plainText(from: raw)
    }

    public static func plainText(from html: String) -> String {
        var text = html

        text = text.replacingOccurrences(of: "(?is)<script[^>]*>.*?</script>", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?is)<style[^>]*>.*?</style>", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?is)<head[^>]*>.*?</head>", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?is)<br\\s*/?>", with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?is)</(p|div|section|article|li|tr|h[1-6]|blockquote)>", with: "\n\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?is)<img[^>]*alt=\"([^\"]*)\"[^>]*>", with: " $1 ", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?is)<[^>]+>", with: " ", options: .regularExpression)
        text = decodeEntities(text)
        return normalize(text)
    }

    /// First heading or `<title>` in the document, used as the chapter label.
    public static func firstHeading(from data: Data) -> String? {
        let html = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""
        for pattern in ["(?is)<h1[^>]*>(.*?)</h1>", "(?is)<h2[^>]*>(.*?)</h2>", "(?is)<title[^>]*>(.*?)</title>"] {
            if let match = firstMatch(pattern, in: html) {
                let cleaned = normalize(decodeEntities(stripTags(match)))
                if !cleaned.isEmpty { return cleaned }
            }
        }
        return nil
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
