// SPDX-License-Identifier: AGPL-3.0-only
#if os(iOS)
import SwiftUI
import UIKit

/// A page rendered by UIKit so text selection, the edit menu, word taps and
/// highlight overlays all use the same TextKit layout as pagination.
final class ReaderPageHostController: UIViewController, UITextViewDelegate {
    let page: ReaderPage
    private let style: ReaderPageStyle
    private var highlights: ReaderPageHighlights
    private let textView = UITextView()
    private let overlay = ReaderHighlightOverlayView()

    var onWordTap: ((Int) -> Void)?
    var onHighlight: ((NSRange, AnnotationColor) -> Void)?
    var onNote: ((NSRange) -> Void)?

    init(page: ReaderPage, style: ReaderPageStyle, highlights: ReaderPageHighlights) {
        self.page = page
        self.style = style
        self.highlights = highlights
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = style.background
        textView.backgroundColor = .clear
        textView.isEditable = false
        textView.isSelectable = true
        textView.isScrollEnabled = false
        textView.textContainerInset = .zero
        textView.contentInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.dataDetectorTypes = []
        textView.adjustsFontForContentSizeCategory = false
        textView.attributedText = page.attributed
        textView.delegate = self
        textView.accessibilityLabel = "\(page.chapterTitle), page \(page.pageIndexInChapter + 1) of \(max(page.pagesInChapter, 1))"
        view.addSubview(textView)

        overlay.textView = textView
        overlay.backgroundColor = .clear
        overlay.isUserInteractionEnabled = false
        textView.addSubview(overlay)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.cancelsTouchesInView = false
        textView.addGestureRecognizer(tap)
        applyHighlights()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let insets = UIEdgeInsets(top: 8, left: style.margin, bottom: 8, right: style.margin)
        textView.frame = view.bounds.inset(by: insets)
        overlay.frame = textView.bounds
        overlay.setNeedsDisplay()
    }

    func updateHighlights(_ highlights: ReaderPageHighlights) {
        self.highlights = highlights
        applyHighlights()
    }

    private func applyHighlights() {
        overlay.spans = highlights.spans.compactMap { span in
            guard let local = page.localRange(forChapterRange: span.range) else { return nil }
            return ReaderHighlightOverlayView.Span(
                range: local,
                fill: span.fill,
                underline: span.underline,
                underlineWidth: span.underlineWidth,
                rounded: span.rounded
            )
        }
        overlay.setNeedsDisplay()
    }

    private func chapterRange(for localRange: NSRange) -> NSRange? {
        guard localRange.length > 0,
              let start = page.chapterOffset(forLocalIndex: localRange.location) else { return nil }
        let last = NSMaxRange(localRange) - 1
        guard let end = page.chapterOffset(forLocalIndex: last) else { return nil }
        return NSRange(location: start, length: max(1, end - start + 1))
    }

    // MARK: Selection menu

    func textView(_ textView: UITextView, editMenuForTextIn range: NSRange,
                  suggestedActions: [UIMenuElement]) -> UIMenu? {
        guard let chapterRange = chapterRange(for: range) else {
            return UIMenu(children: suggestedActions)
        }
        let colors = AnnotationColor.allCases.map { color in
            UIAction(title: color.title) { [weak self] _ in
                self?.onHighlight?(chapterRange, color)
            }
        }
        let highlight = UIMenu(title: "Highlight", image: UIImage(systemName: "highlighter"), children: colors)
        let note = UIAction(title: "Add Note…", image: UIImage(systemName: "note.text")) { [weak self] _ in
            self?.onNote?(chapterRange)
        }
        return UIMenu(children: [highlight, note] + suggestedActions)
    }

    // MARK: Word tap

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        let point = gesture.location(in: textView)
        guard let position = textView.closestPosition(to: point) else { return }
        let index = textView.offset(from: textView.beginningOfDocument, to: position)
        if let chapterOffset = page.chapterOffset(forLocalIndex: index) {
            onWordTap?(chapterOffset)
        }
    }
}

/// Draws sentence, word and annotation tint behind the text. It sits above the
/// text view's content but uses translucent fills, so glyphs stay readable.
final class ReaderHighlightOverlayView: UIView {
    struct Span {
        var range: NSRange
        var fill: UIColor
        var underline: UIColor?
        var underlineWidth: CGFloat
        var rounded: Bool
    }

    weak var textView: UITextView?
    var spans: [Span] = [] {
        didSet { setNeedsDisplay() }
    }

    override func draw(_ rect: CGRect) {
        guard let textView else { return }
        let layoutManager = textView.layoutManager
        let container = textView.textContainer
        layoutManager.ensureLayout(for: container)

        for span in spans {
            guard span.range.length > 0, NSMaxRange(span.range) <= textView.attributedText.length else { continue }
            let glyphRange = layoutManager.glyphRange(forCharacterRange: span.range, actualCharacterRange: nil)
            var rects: [CGRect] = []
            layoutManager.enumerateEnclosingRects(forGlyphRange: glyphRange,
                                                  withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                                                  in: container) { glyphRect, _ in
                rects.append(glyphRect.offsetBy(dx: textView.textContainerInset.left,
                                                dy: textView.textContainerInset.top))
            }
            for lineRect in rects {
                let path = span.rounded
                    ? UIBezierPath(roundedRect: lineRect.insetBy(dx: 0, dy: -1), cornerRadius: 3)
                    : UIBezierPath(rect: lineRect.insetBy(dx: 0, dy: -1))
                span.fill.setFill()
                path.fill()
                if let underline = span.underline {
                    let underlineRect = CGRect(x: lineRect.minX, y: lineRect.maxY - span.underlineWidth,
                                               width: lineRect.width, height: span.underlineWidth)
                    underline.setFill()
                    UIRectFill(underlineRect)
                }
            }
        }
    }
}
#endif
