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
    var onWordTap: (Int) -> Void = { _ in }
    var onHighlight: (NSRange, AnnotationColor) -> Void = { _, _ in }
    var onNote: (NSRange) -> Void = { _ in }
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
#else
/// A self-sizing Mac text block built on the same text view and overlay as
/// the two-page spread.
final class ReaderMacSelectableView: NSView {
    let textView = ReaderMacTextView()
    let overlay = MacHighlightOverlayView()
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
#endif
