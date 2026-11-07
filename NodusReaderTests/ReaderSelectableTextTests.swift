// SPDX-License-Identifier: AGPL-3.0-only
#if os(iOS)
import Foundation
import Testing
import UIKit
import DesignSystem
@testable import Nodus_Reader

/// Narration updates the page views on every word with the same page text.
/// Re-assigning it cancelled a selection being made and relaid the text out.
@Test @MainActor
func samePageTextIsNotAssignedAgain() {
    let style = ReaderPageStyle(theme: ReaderTheme.resolve(.light, colorScheme: .light),
                                typography: ReaderTypography())
    let chapters = [ExtractedChapter(id: 0, title: "Chapter 1",
                                     text: String(repeating: "Call me Ishmael. Some years ago, never mind how long. ", count: 40))]
    let page = TextPaginator.paginate(chapters: chapters, style: style,
                                      pageSize: CGSize(width: 320, height: 560)).pages[0]
    let view = ReaderSelectableTextView(mapping: .page(page))
    view.setText(page.attributed)
    // Mark the text the view holds: re-assigning the page would erase it.
    let marker = NSAttributedString.Key("TestMarker")
    view.textView.textStorage.addAttribute(marker, value: true, range: NSRange(location: 0, length: 4))

    view.setText(page.attributed)

    #expect(view.textView.textStorage.attribute(marker, at: 0, effectiveRange: nil) != nil)
}
#endif
