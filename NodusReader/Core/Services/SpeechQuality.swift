// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

enum SpeechVerification: String, Sendable { case valid, defective, unavailable }

struct NarrationSynthesis: Sendable {
    var samples: [Float]
    var sampleRate: Double
    var words: [NarrationWordTiming]? = nil
    var checkedWords = false
    var verification: SpeechVerification = .unavailable
}

enum SpeechQuality {
    static func accepts(samples: [Float], text: String, recognized: [SpeechWordAligner.RecognizedWord]?, language: String = "en-US") -> Bool {
        guard samples.count >= 1200, samples.allSatisfy(\.isFinite),
              samples.contains(where: { abs($0) > 0.001 }) else { return false }
        guard let recognized else { return true }
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: language); formatter.numberStyle = .spellOut
        let parser = NumberFormatter(); parser.locale = formatter.locale; parser.numberStyle = .decimal
        func tokens(_ text: String) -> [String] {
            AudioWordAligner.words(in: text).flatMap { word -> [String] in
                let numeric = word.text.allSatisfy { $0.isNumber || $0 == "." || $0 == "," }
                let expanded = (numeric ? parser.number(from: word.text) : nil).flatMap { formatter.string(from: $0) } ?? word.text
                return expanded.split(whereSeparator: { $0.isWhitespace || $0 == "-" }).map { SpeechWordAligner.normalize(String($0)) }.filter { !$0.isEmpty }
            }
        }
        var expected = tokens(text)
        var heard = recognized.flatMap { tokens($0.text) }
        if ["zh", "ja", "ko"].contains(String(language.prefix(2))) {
            expected = expected.joined().map(String.init)
            heard = heard.joined().map(String.init)
        }
        guard !expected.isEmpty, !heard.isEmpty else { return false }
        // Ordered matching tolerates ASR spelling/name differences without accepting unrelated noise.
        var row = [Int](repeating: 0, count: heard.count + 1)
        for word in expected {
            var previous = 0
            for j in heard.indices {
                let old = row[j + 1]
                row[j + 1] = word == heard[j] ? previous + 1 : max(row[j], row[j + 1])
                previous = old
            }
        }
        return Double(row.last!) / Double(expected.count) >= 0.5
    }
}
