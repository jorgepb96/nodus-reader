// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// SwiftUI wrapper around the reader's selectable text (selection menu,
/// word taps, highlight overlays). It sizes itself to its text, so it can sit
/// in lazy stacks: continuous-scroll slices and PDF Intelligent Reading blocks.
struct SelectableReaderText {
    var text: NSAttributedString
    var mapping: ReaderTextMapping
    var highlights: ReaderPageHighlights = ReaderPageHighlights()
    /// Horizontal padding inside the view (the reader's page margin).
    var horizontalInset: CGFloat = 0
    /// Columns take the height they are given; otherwise the text's height.
    var fillsProposedHeight = false
    var accessibilityLabel: String?
    /// Stable chapter/page range of the spoken word. Independent of which
    /// highlight layers the user chose to display.
    var narrationFollowRange: NSRange?
    var onWordTap: (Int) -> Void = { _ in }
    var onHighlight: (NSRange, AnnotationColor) -> Void = { _, _ in }
    var onNote: (NSRange) -> Void = { _ in }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var localNarrationRange: NSRange? {
        guard let narrationFollowRange else { return nil }
        // Only the block containing the word's start may move the viewport.
        return mapping.localRange(NSRange(location: narrationFollowRange.location, length: 1))
    }
}

#if os(iOS)
extension SelectableReaderText: UIViewRepresentable {
    func makeUIView(context: Context) -> ReaderSelectableTextView {
        let view = ReaderSelectableTextView(mapping: mapping)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateUIView(_ view: ReaderSelectableTextView, context: Context) {
        view.mapping = mapping
        view.contentInsets = UIEdgeInsets(top: 0, left: horizontalInset, bottom: 0, right: horizontalInset)
        view.onWordTap = onWordTap
        view.onHighlight = onHighlight
        view.onNote = onNote
        view.setText(text)
        view.textView.accessibilityLabel = accessibilityLabel
        view.setHighlights(highlights)
        view.narrationFollowRange = localNarrationRange
        let range = localNarrationRange
        let animated = !reduceMotion
        DispatchQueue.main.async { [weak view] in
            guard let view, let range, view.narrationFollowRange == range else { return }
            view.followNarration(range, animated: animated)
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: ReaderSelectableTextView,
                      context: Context) -> CGSize? {
        let width = proposal.width ?? 320
        if fillsProposedHeight, let height = proposal.height {
            return CGSize(width: width, height: height)
        }
        return CGSize(width: width, height: uiView.fittingHeight(width: width))
    }
}

extension ReaderSelectableTextView {
    /// The outer SwiftUI scroll view owns scrolling; the UITextView itself
    /// stays non-scrolling so selections and highlights share one text layout.
    func followNarration(_ range: NSRange, animated: Bool) {
        guard window != nil, textView.selectedRange.length == 0 else { return }
        var ancestor = superview
        while let view = ancestor, !(view is UIScrollView) { ancestor = view.superview }
        guard let scroll = ancestor as? UIScrollView,
              !scroll.isDragging, !scroll.isDecelerating, !scroll.isTracking,
              NSMaxRange(range) <= textView.attributedText.length else { return }
        layoutIfNeeded()
        let layout = textView.layoutManager
        layout.ensureLayout(for: textView.textContainer)
        let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        guard glyphs.length > 0 else { return }
        let line = layout.lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
            .offsetBy(dx: textView.textContainerInset.left, dy: textView.textContainerInset.top)
        let rect = textView.convert(line, to: scroll)
        let insets = scroll.adjustedContentInset
        let height = scroll.bounds.height - insets.top - insets.bottom
        let visibleTop = scroll.contentOffset.y + insets.top
        guard height > 0,
              rect.midY < visibleTop + height * 0.22 || rect.midY > visibleTop + height * 0.55 else { return }
        let maximum = max(-insets.top, scroll.contentSize.height - scroll.bounds.height + insets.bottom)
        let target = min(maximum, max(-insets.top, rect.midY - height * 0.35 - insets.top))
        guard abs(target - scroll.contentOffset.y) > 1 else { return }
        scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: target), animated: animated)
    }
}
#else
/// A self-sizing Mac text block built on the same text view and overlay as
/// the two-page spread.
final class ReaderMacSelectableView: NSView {
    let textView = ReaderMacTextView()
    let overlay = MacHighlightOverlayView()
    var narrationFollowRange: NSRange?
    var horizontalInset: CGFloat = 0 {
        didSet { needsLayout = true }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        textView.drawsBackground = false
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.importsGraphics = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = false
        textView.autoresizingMask = []
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        addSubview(textView)
        overlay.textView = textView
        textView.addSubview(overlay)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let frame = bounds.insetBy(dx: horizontalInset, dy: 0)
        textView.frame = frame
        textView.textContainer?.containerSize = CGSize(width: frame.width, height: .greatestFiniteMagnitude)
        overlay.frame = textView.bounds
        overlay.needsDisplay = true
    }

    func fittingHeight(width: CGFloat) -> CGFloat {
        guard let container = textView.textContainer, let layoutManager = textView.layoutManager else { return 0 }
        container.containerSize = CGSize(width: max(1, width - horizontalInset * 2),
                                         height: .greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: container)
        return ceil(layoutManager.usedRect(for: container).height)
    }
}

extension SelectableReaderText: NSViewRepresentable {
    func makeNSView(context: Context) -> ReaderMacSelectableView {
        ReaderMacSelectableView(frame: .zero)
    }

    func updateNSView(_ view: ReaderMacSelectableView, context: Context) {
        view.horizontalInset = horizontalInset
        view.textView.mapping = mapping
        view.textView.onWordTap = onWordTap
        view.textView.onHighlight = onHighlight
        view.textView.onNote = onNote
        view.textView.setAccessibilityLabel(accessibilityLabel)
        if !(view.textView.textStorage?.isEqual(to: text) ?? false) {
            view.textView.textStorage?.setAttributedString(text)
        }
        view.overlay.spans = highlights.spans.compactMap { span in
            guard let local = mapping.localRange(span.range) else { return nil }
            return MacHighlightOverlayView.Span(range: local, fill: span.fill, underline: span.underline,
                                                underlineWidth: span.underlineWidth, rounded: span.rounded)
        }
        view.needsLayout = true
        view.narrationFollowRange = localNarrationRange
        let range = localNarrationRange
        let animated = !reduceMotion
        DispatchQueue.main.async { [weak view] in
            guard let view, let range, view.narrationFollowRange == range else { return }
            view.followNarration(range, animated: animated)
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ReaderMacSelectableView,
                      context: Context) -> CGSize? {
        let width = proposal.width ?? 480
        if fillsProposedHeight, let height = proposal.height {
            return CGSize(width: width, height: height)
        }
        return CGSize(width: width, height: nsView.fittingHeight(width: width))
    }
}

extension ReaderMacSelectableView {
    func followNarration(_ range: NSRange, animated: Bool) {
        guard window != nil, textView.selectedRange().length == 0,
              let scroll = enclosingScrollView, let document = scroll.documentView,
              let layout = textView.layoutManager, let container = textView.textContainer,
              NSMaxRange(range) <= (textView.textStorage?.length ?? 0),
              NSEvent.pressedMouseButtons == 0 else { return }
        layoutSubtreeIfNeeded()
        layout.ensureLayout(for: container)
        let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        guard glyphs.length > 0 else { return }
        let line = layout.lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
            .offsetBy(dx: textView.textContainerOrigin.x, dy: textView.textContainerOrigin.y)
        let rect = textView.convert(line, to: document)
        let visible = scroll.contentView.documentVisibleRect
        guard visible.height > 0,
              rect.midY < visible.minY + visible.height * 0.22 || rect.midY > visible.minY + visible.height * 0.55 else { return }
        let maximum = max(0, document.bounds.height - visible.height)
        let target = min(maximum, max(0, rect.midY - visible.height * 0.35))
        guard abs(target - visible.minY) > 1 else { return }
        let origin = NSPoint(x: visible.minX, y: target)
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                scroll.contentView.animator().setBoundsOrigin(origin)
            }
        } else {
            scroll.contentView.scroll(to: origin)
        }
        scroll.reflectScrolledClipView(scroll.contentView)
    }
}
#endif
