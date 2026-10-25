// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import NaturalLanguage

/// Detects or normalises the language of an imported document. A declared
/// EPUB language wins; otherwise the text itself is sampled locally.
public enum LanguageDetector {
    public static func resolve(declared: String, text: String) -> String {
        let normalized = normalize(declared)
        if !normalized.isEmpty { return normalized }
        return detect(in: text)
    }

    public static func normalize(_ code: String) -> String {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let lowered = trimmed.lowercased()
        if lowered == "und" || lowered == "unknown" || lowered == "undefined" { return "" }
        // Keep a valid BCP-47 tag; strip accidental whitespace and underscores.
        return trimmed.replacingOccurrences(of: "_", with: "-")
    }

    public static func detect(in text: String) -> String {
        let sample = String(text.prefix(5000))
        guard sample.count > 40 else { return "" }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(sample)
        guard let language = recognizer.dominantLanguage else { return "" }
        return language.rawValue
    }

    public static func displayName(for code: String) -> String {
        let normalized = normalize(code)
        guard !normalized.isEmpty else { return String(localized: "Unknown language") }
        if let name = Locale.current.localizedString(forIdentifier: normalized) {
            return name
        }
        if let name = Locale.current.localizedString(forLanguageCode: normalized) {
            return name
        }
        if let name = Locale.current.localizedString(forLanguageCode: String(normalized.prefix(2))) {
            return name
        }
        return normalized
    }
}
