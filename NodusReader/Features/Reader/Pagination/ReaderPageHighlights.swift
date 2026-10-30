// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import DesignSystem
#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct ReaderPageHighlightSpan: Equatable {
    var range: NSRange
    var fill: PlatformColor
    var underline: PlatformColor?
    var underlineWidth: CGFloat
    var rounded: Bool
}

struct ReaderPageHighlights: Equatable {
    var spans: [ReaderPageHighlightSpan] = []

    /// Paint each character once: in combined mode the word replaces that
    /// portion of the sentence's fill instead of adding a second tint to it.
    static func narration(sentence: NSRange?, word: NSRange?,
                          style: NarrationHighlightStyle, theme: ReaderTheme) -> [ReaderPageHighlightSpan] {
        let sentence = style.highlightsSentence ? validRange(sentence) : nil
        let word = style.highlightsWord ? validRange(word) : nil
        var spans: [ReaderPageHighlightSpan] = []

        if let sentence {
            let intersection = word.map { NSIntersectionRange(sentence, $0) }
            let ranges: [NSRange]
            if let intersection, intersection.length > 0 {
                ranges = [
                    NSRange(location: sentence.location, length: intersection.location - sentence.location),
                    NSRange(location: NSMaxRange(intersection), length: NSMaxRange(sentence) - NSMaxRange(intersection))
                ]
            } else {
                ranges = [sentence]
            }
            for range in ranges where range.length > 0 {
                spans.append(ReaderPageHighlightSpan(range: range, fill: PlatformColor(theme.narration),
                                                     underline: nil, underlineWidth: 0, rounded: true))
            }
        }

        if let word {
            spans.append(ReaderPageHighlightSpan(
                range: word,
                fill: theme.isDark ? PlatformColor(hex: NodusHex.lavender, alpha: 0.55)
                    : PlatformColor(hex: NodusHex.violet, alpha: 0.38),
                underline: nil,
                underlineWidth: 0, rounded: true
            ))
        }
        return spans
    }

    private static func validRange(_ range: NSRange?) -> NSRange? {
        guard let range, range.location != NSNotFound, range.location >= 0, range.length > 0 else { return nil }
        return range
    }
}

extension PlatformColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        let red = CGFloat((hex >> 16) & 0xFF) / 255
        let green = CGFloat((hex >> 8) & 0xFF) / 255
        let blue = CGFloat(hex & 0xFF) / 255
        #if os(macOS)
        self.init(srgbRed: red, green: green, blue: blue, alpha: alpha)
        #else
        self.init(red: red, green: green, blue: blue, alpha: alpha)
        #endif
    }
}
