// SPDX-License-Identifier: AGPL-3.0-only
#if os(iOS)
import SwiftUI
import UIKit

/// Read-only text with the reader's selection menu (Highlight, Add Note), word
/// taps and highlight overlays. Used by paginated pages, continuous-scroll
/// slices and PDF Intelligent Reading blocks; `mapping` translates local
/// indexes to the anchor space each one uses.
final class ReaderSelectableTextView: UIView, UITextViewDelegate {
    let textView = UITextView()
    private let overlay = ReaderHighlightOverlayView()

    var mapping: ReaderTextMapping
    var contentInsets: UIEdgeInsets = .zero {
        didSet { setNeedsLayout() }
    }
    var onWordTap: ((Int) -> Void)?
    var onHighlight: ((NSRange, AnnotationColor) -> Void)?
    var onNote: ((NSRange) -> Void)?

    init(mapping: ReaderTextMapping) {
        self.mapping = mapping
        super.init(frame: .zero)
        backgroundColor = .clear
        textView.backgroundColor = .clear
        textView.isEditable = false
        textView.isSelectable = true
        textView.isScrollEnabled = false
        textView.textContainerInset = .zero
        textView.contentInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.dataDetectorTypes = []
        textView.adjustsFontForContentSizeCategory = false
        textView.delegate = self
        addSubview(textView)

        // Highlights are painted behind the glyphs (the text view is clear),
        // so even opaque narration colours never hide words.
        overlay.textView = textView
        overlay.backgroundColor = .clear
        overlay.isUserInteractionEnabled = false
        insertSubview(overlay, belowSubview: textView)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.cancelsTouchesInView = false
        textView.addGestureRecognizer(tap)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Only a real size change relayouts and redraws: a page in a curl
        // animation that redraws is re-captured mid-turn and visibly shakes.
        let frame = bounds.inset(by: contentInsets)
        guard textView.frame != frame else { return }
        textView.frame = frame
        overlay.frame = frame
        overlay.setNeedsDisplay()
    }

    func setText(_ text: NSAttributedString) {
        guard !textView.attributedText.isEqual(to: text) else { return }
        textView.attributedText = text
        overlay.setNeedsDisplay()
    }

    func setHighlights(_ highlights: ReaderPageHighlights) {
        overlay.spans = highlights.spans.compactMap { span in
            guard let local = mapping.localRange(span.range) else { return nil }
            return ReaderHighlightOverlayView.Span(range: local, fill: span.fill,
                                                   underline: span.underline,
                                                   underlineWidth: span.underlineWidth,
                                                   rounded: span.rounded)
        }
    }

    /// Height needed to show all the text at `width`, insets included.
    func fittingHeight(width: CGFloat) -> CGFloat {
        let textWidth = max(1, width - contentInsets.left - contentInsets.right)
        let size = textView.sizeThatFits(CGSize(width: textWidth, height: .greatestFiniteMagnitude))
        return ceil(size.height) + contentInsets.top + contentInsets.bottom
    }

    // MARK: Selection menu

    func textView(_ textView: UITextView, editMenuForTextIn range: NSRange,
                  suggestedActions: [UIMenuElement]) -> UIMenu? {
        guard let anchorRange = mapping.anchorRange(for: range) else {
            return UIMenu(children: suggestedActions)
        }
        let colors = AnnotationColor.allCases.map { color in
            UIAction(title: color.title) { [weak self] _ in
                self?.onHighlight?(anchorRange, color)
            }
        }
        let highlight = UIMenu(title: "Highlight", image: UIImage(systemName: "highlighter"), children: colors)
        let note = UIAction(title: "Add Note…", image: UIImage(systemName: "note.text")) { [weak self] _ in
            self?.onNote?(anchorRange)
        }
        return UIMenu(children: [highlight, note] + suggestedActions)
    }

    // MARK: Word tap

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        let point = gesture.location(in: textView)
        guard let position = textView.closestPosition(to: point) else { return }
        let index = textView.offset(from: textView.beginningOfDocument, to: position)
        if let offset = mapping.anchorOffset(index) {
            onWordTap?(offset)
        }
    }
}

/// A page rendered by UIKit so text selection, the edit menu, word taps and
/// highlight overlays all use the same TextKit layout as pagination.
final class ReaderPageHostController: UIViewController {
    let page: ReaderPage
    private let style: ReaderPageStyle
    private var highlights: ReaderPageHighlights
    private let content: ReaderSelectableTextView

    var onWordTap: ((Int) -> Void)? {
        get { content.onWordTap }
        set { content.onWordTap = newValue }
    }
    var onHighlight: ((NSRange, AnnotationColor) -> Void)? {
        get { content.onHighlight }
        set { content.onHighlight = newValue }
    }
    var onNote: ((NSRange) -> Void)? {
        get { content.onNote }
        set { content.onNote = newValue }
    }

    init(page: ReaderPage, style: ReaderPageStyle, highlights: ReaderPageHighlights) {
        self.page = page
        self.style = style
        self.highlights = highlights
        self.content = ReaderSelectableTextView(mapping: .page(page))
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = style.background
        content.setText(page.attributed)
        content.textView.accessibilityLabel = "\(page.chapterTitle), page \(page.pageIndexInChapter + 1) of \(max(page.pagesInChapter, 1))"
        content.contentInsets = UIEdgeInsets(top: 8, left: style.margin, bottom: 8, right: style.margin)
        view.addSubview(content)
        content.setHighlights(highlights)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        content.frame = view.bounds
    }

    func updateHighlights(_ highlights: ReaderPageHighlights) {
        guard highlights != self.highlights else { return }
        self.highlights = highlights
        content.setHighlights(highlights)
    }
}

/// The back of a page while it curls: the theme's paper with the page's text
/// faintly showing through, mirrored, as on printed paper. UIKit's own back
/// is a white wash whatever the theme.
final class ReaderPageBackController: UIViewController {
    let front: ReaderPageHostController
    private let style: ReaderPageStyle

    init(front: ReaderPageHostController, style: ReaderPageStyle) {
        self.front = front
        self.style = style
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = style.background
        view.isUserInteractionEnabled = false
        view.accessibilityElementsHidden = true
        // Only a page already on screen can be captured (turning forward);
        // turning back, the paper alone is shown.
        if front.isViewLoaded, front.view.window != nil,
           let showThrough = front.view.snapshotView(afterScreenUpdates: false) {
            showThrough.alpha = style.isDark ? 0.10 : 0.07
            showThrough.transform = CGAffineTransform(scaleX: -1, y: 1)
            showThrough.frame = view.bounds
            showThrough.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.addSubview(showThrough)
        }
    }
}

/// Draws sentence, word and annotation tint behind the text: it is a sibling
/// placed below the clear text view, so glyphs are always drawn on top.
final class ReaderHighlightOverlayView: UIView {
    struct Span: Equatable {
        var range: NSRange
        var fill: UIColor
        var underline: UIColor?
        var underlineWidth: CGFloat
        var rounded: Bool
    }

    weak var textView: UITextView?
    var spans: [Span] = [] {
        didSet { if spans != oldValue { setNeedsDisplay() } }
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
