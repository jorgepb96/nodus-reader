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
}
#endif
