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

    /// Line rects of one span, ready to be filled as a single shape. Edges
    /// snap to device pixels and sub-point gaps between stacked lines close,
    /// so a translucent fill never leaves a seam of background between lines.
    /// The rects of `glyphRange`, one per line, each as tall as its whole line. TextKit's
    /// enclosing rects are only as tall as the text where a range stops mid-line, but
    /// include the line spacing where it runs on: drawn side by side (the spoken part of
    /// a sentence and the rest) they left a gap under the shorter one.
    static func lineRects(_ layout: NSLayoutManager, glyphRange: NSRange, in container: NSTextContainer) -> [CGRect] {
        var rects: [CGRect] = []
        layout.enumerateEnclosingRects(forGlyphRange: glyphRange,
                                       withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                                       in: container) { rect, _ in
            let glyph = layout.glyphIndex(for: CGPoint(x: rect.midX, y: rect.midY), in: container)
            let line = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            rects.append(CGRect(x: rect.minX, y: line.minY, width: rect.width, height: line.height))
        }
        return rects
    }

    static func fillRects(_ rects: [CGRect], scale: CGFloat) -> [CGRect] {
        let scale = max(scale, 1)
        func snap(_ value: CGFloat) -> CGFloat { (value * scale).rounded() / scale }
        var snapped = rects.map { rect in
            CGRect(x: snap(rect.minX), y: snap(rect.minY),
                   width: snap(rect.maxX) - snap(rect.minX), height: snap(rect.maxY) - snap(rect.minY))
        }.sorted { $0.minY < $1.minY }
        for index in snapped.indices.dropLast() {
            let next = snapped[index + 1]
            let gap = next.minY - snapped[index].maxY
            let overlapsHorizontally = next.minX < snapped[index].maxX && snapped[index].minX < next.maxX
            if gap > 0, gap <= 1, overlapsHorizontally {
                snapped[index].size.height += gap
            }
        }
        return snapped
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
