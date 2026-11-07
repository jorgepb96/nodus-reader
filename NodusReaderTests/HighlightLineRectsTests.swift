// SPDX-License-Identifier: AGPL-3.0-only
#if os(iOS)
import Testing
import UIKit
@testable import Nodus_Reader

@Suite("Highlight line rects")
struct HighlightLineRectsTests {
    /// The narrated sentence is drawn in pieces (spoken, word, still to come). A piece
    /// that ends mid-line and one that runs on to the next line must cover the same
    /// height, or a gap opens under the spoken part as the word advances.
    @Test @MainActor func piecesOnOneLineShareItsHeight() throws {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 12
        paragraph.alignment = .justified
        paragraph.hyphenationFactor = 1
        let text = String(repeating: "The voice came from the sofa across the room and its tones brought relief. ", count: 3)
        let storage = NSTextStorage(string: text, attributes: [.font: UIFont.systemFont(ofSize: 18),
                                                               .paragraphStyle: paragraph])
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: 300, height: 2_000))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        layout.ensureLayout(for: container)
        // A word in the middle of the second line.
        let secondLine = layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: 40), effectiveRange: nil)
        let middle = layout.glyphIndex(for: CGPoint(x: 150, y: secondLine.midY), in: container)
        let split = layout.characterIndexForGlyph(at: middle)
        let spoken = ReaderPageHighlights.lineRects(layout, glyphRange: layout.glyphRange(
            forCharacterRange: NSRange(location: 0, length: split), actualCharacterRange: nil), in: container)
        let coming = ReaderPageHighlights.lineRects(layout, glyphRange: layout.glyphRange(
            forCharacterRange: NSRange(location: split, length: 120), actualCharacterRange: nil), in: container)
        let spokenLast = try #require(spoken.max { $0.minY < $1.minY })
        let comingFirst = try #require(coming.min { $0.minY < $1.minY })
        #expect(abs(spokenLast.minY - comingFirst.minY) < 0.5)
        #expect(abs(spokenLast.maxY - comingFirst.maxY) < 0.5)
    }

    /// A sentence over several whole lines: one rect per line, each on its own line,
    /// together covering exactly those lines (TextKit's middle rect spans them all).
    @Test @MainActor func everyLineOfALongRangeIsCoveredOnce() throws {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 12
        paragraph.alignment = .justified
        paragraph.hyphenationFactor = 1
        let text = String(repeating: "Le rogó que trocasen trajes, pues era más justo que él fuese la doncella menesterosa. ", count: 8)
        let storage = NSTextStorage(string: text, attributes: [.font: UIFont.systemFont(ofSize: 18),
                                                               .paragraphStyle: paragraph])
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: 300, height: 4_000))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        layout.ensureLayout(for: container)
        let range = NSRange(location: 10, length: 300)
        let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var lines: [CGRect] = []
        layout.enumerateLineFragments(forGlyphRange: glyphs) { rect, _, _, _, _ in lines.append(rect) }
        #expect(lines.count >= 5)
        let rects = ReaderPageHighlights.lineRects(layout, glyphRange: glyphs, in: container)
        #expect(rects.count == lines.count)
        for (rect, line) in zip(rects.sorted { $0.minY < $1.minY }, lines) {
            #expect(abs(rect.minY - line.minY) < 0.5 && abs(rect.height - line.height) < 0.5)
        }
    }
}
#endif
