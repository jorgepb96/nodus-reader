// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI
import DesignSystem
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// How the reader's scroll view moves to keep a line in view.
enum ReaderScrollMotion {
    /// Straight to the destination: a layout rebuild, Reduce Motion, or a
    /// jump the reader asked to land on at once.
    case instant
    /// Eases in and out: a move that starts from rest.
    case smooth
    /// Eases out only: the last stretch of a move that is already travelling,
    /// so the two parts read as one gesture and never change direction.
    case settle
}

/// A one-shot visual jump, independent of the automatic-follow preference.
struct ReaderTextScrollRequest {
    let id: UUID
    let range: NSRange
    var motion: ReaderScrollMotion = .instant
}

/// Easing shared by the iOS and Mac scroll animators.
private func readerScrollProgress(_ t: Double, motion: ReaderScrollMotion) -> Double {
    let t = min(max(t, 0), 1)
    switch motion {
    case .instant: return 1
    case .settle: return 1 - pow(1 - t, 3)
    case .smooth: return t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
    }
}

/// Longer moves take a little longer, so a line and a full screen both glide.
private func readerScrollDuration(distance: CGFloat, viewport: CGFloat) -> Double {
    let screens = Double(distance / max(viewport, 1))
    return min(0.7, max(0.3, 0.3 + screens * 0.25))
}

/// The point at which the follow re-centres the spoken line: outside the
/// central fifth of the reading area. Inside it nothing moves.
private let readerFollowBand: ClosedRange<CGFloat> = 0.40...0.60

/// SwiftUI wrapper around the reader's selectable text (selection menu,
/// word taps, highlight overlays). It sizes itself to its text, so it can sit
/// in lazy stacks: continuous-scroll slices and PDF Intelligent Reading blocks.
struct SelectableReaderText {
    @Environment(\.pronunciationSelection) private var pronounce
    @Environment(\.nodusPalette) private var palette
    @Environment(\.readerFollowState) private var followState
    @Environment(\.readerManualNavigation) private var onManualNavigation
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
    var scrollRequest: ReaderTextScrollRequest? = nil
    /// False right after a layout rebuild: the first follow lands at once
    /// instead of sliding in from the slice's top edge.
    var animatesFollow = true
    var onScrollRequestHandled: (UUID) -> Void = { _ in }
    var onWordTap: (Int) -> Void = { _ in }
    var onHighlight: (NSRange, AnnotationColor) -> Void = { _, _ in }
    var onNote: (NSRange) -> Void = { _ in }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    final class Coordinator {
        var handledScrollRequest: UUID?
        var updateID = UUID()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    private var localScrollRequest: ReaderTextScrollRequest? {
        guard let scrollRequest, let range = mapping.localRange(scrollRequest.range) else { return nil }
        return ReaderTextScrollRequest(id: scrollRequest.id, range: range,
                                       motion: reduceMotion ? .instant : scrollRequest.motion)
    }

    @MainActor private var localNarrationRange: NSRange? {
        guard followState?.isSuspended != true, let narrationFollowRange else { return nil }
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
        view.onPronounce = pronounce
        view.setText(text)
        view.textView.accessibilityLabel = accessibilityLabel
        view.setHighlights(highlights)
        view.narrationFollowRange = localNarrationRange
        let range = localNarrationRange
        let request = localScrollRequest
        let coordinator = context.coordinator
        let updateID = UUID()
        coordinator.updateID = updateID
        let intent = followState
        let revision = intent?.revision
        let motion: ReaderScrollMotion = !reduceMotion && animatesFollow ? .smooth : .instant
        DispatchQueue.main.async { [weak view] in
            guard let view, coordinator.updateID == updateID, intent?.revision == revision else { return }
            if let request, coordinator.handledScrollRequest != request.id {
                if view.followNarration(request.range, motion: request.motion, explicit: true) {
                    coordinator.handledScrollRequest = request.id
                    onScrollRequestHandled(request.id)
                }
            } else if intent?.isSuspended != true, let range, view.narrationFollowRange == range {
                view.followNarration(range, motion: motion)
            }
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
    @discardableResult
    func followNarration(_ range: NSRange, motion: ReaderScrollMotion, explicit: Bool = false) -> Bool {
        guard window != nil, explicit || ReaderTextInteraction.allowsFollow else { return false }
        var ancestor = superview
        while let view = ancestor, !(view is UIScrollView) { ancestor = view.superview }
        guard let scroll = ancestor as? UIScrollView,
              !scroll.isDragging, (explicit || !scroll.isDecelerating), !scroll.isTracking,
              NSMaxRange(range) <= textView.attributedText.length else { return false }
        layoutIfNeeded()
        let layout = textView.layoutManager
        layout.ensureLayout(for: textView.textContainer)
        let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        guard glyphs.length > 0 else { return false }
        let line = layout.lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
            .offsetBy(dx: textView.textContainerInset.left, dy: textView.textContainerInset.top)
        let rect = textView.convert(line, to: scroll)
        let insets = scroll.adjustedContentInset
        let height = scroll.bounds.height - insets.top - insets.bottom
        let visibleTop = scroll.contentOffset.y + insets.top
        guard height > 0 else { return false }
        let maximum = max(-insets.top, scroll.contentSize.height - scroll.bounds.height + insets.bottom)
        let target = min(maximum, max(-insets.top, rect.midY - height * 0.5 - insets.top))
        let animator = ReaderScrollAnimator.animator(for: scroll)
        // Already gliding to this line: let the running move finish instead
        // of restarting it, which made the follow stutter.
        if let heading = animator.destination, abs(heading - target) <= 1 { return true }
        // Keep the spoken line inside the central fifth; when it leaves, put
        // it back at the exact centre of the reading area. A line that is
        // already there never moves, so a return to it cannot bounce.
        let position = (rect.midY - visibleTop) / height
        guard !readerFollowBand.contains(position) else { return true }
        guard abs(target - scroll.contentOffset.y) > 1 else { return true }
        animator.scroll(to: target, motion: motion, viewport: height)
        return true
    }
}

/// Drives the reader's scroll view frame by frame. Unlike
/// `setContentOffset(_:animated:)` it can be retargeted mid-flight without
/// restarting from rest, stops as soon as the reader touches the page, and
/// takes longer for longer moves so the spoken line always glides.
@MainActor
final class ReaderScrollAnimator: NSObject {
    private static var key: UInt8 = 0
    private weak var scroll: UIScrollView?
    private var link: CADisplayLink?
    private var from: CGFloat = 0
    private var to: CGFloat = 0
    private var start: CFTimeInterval = 0
    private var duration: CFTimeInterval = 0.3
    private var motion: ReaderScrollMotion = .smooth
    private var lastApplied: CGFloat = 0

    /// Where a running animation is heading; nil when the view is at rest.
    var destination: CGFloat? { link == nil ? nil : to }

    static func animator(for scroll: UIScrollView) -> ReaderScrollAnimator {
        if let existing = objc_getAssociatedObject(scroll, &key) as? ReaderScrollAnimator {
            return existing
        }
        let animator = ReaderScrollAnimator()
        animator.scroll = scroll
        objc_setAssociatedObject(scroll, &key, animator, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return animator
    }

    func scroll(to target: CGFloat, motion: ReaderScrollMotion, viewport: CGFloat) {
        guard let scroll else { return }
        guard motion != .instant else {
            stop()
            scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: target), animated: false)
            return
        }
        let current = scroll.contentOffset.y
        // A retarget while moving keeps going and only eases out, so the
        // page never pauses or reverses between two lines.
        self.motion = link == nil ? motion : .settle
        from = current
        to = target
        lastApplied = current
        start = CACurrentMediaTime()
        duration = readerScrollDuration(distance: abs(target - current), viewport: viewport)
        if link == nil {
            let link = CADisplayLink(target: self, selector: #selector(step(_:)))
            link.add(to: .main, forMode: .common)
            self.link = link
        }
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    @objc private func step(_ link: CADisplayLink) {
        // A touch, or any other owner moving the offset, ends the animation.
        guard let scroll, !scroll.isTracking, !scroll.isDragging,
              abs(scroll.contentOffset.y - lastApplied) <= 1 else {
            stop()
            return
        }
        let t = (CACurrentMediaTime() - start) / duration
        let y = from + (to - from) * CGFloat(readerScrollProgress(t, motion: motion))
        lastApplied = y
        scroll.contentOffset = CGPoint(x: scroll.contentOffset.x, y: y)
        if t >= 1 { stop() }
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
        // Light themes use opaque highlight fills. Keep every highlight
        // behind the glyphs, just as in the paginated Mac reader.
        addSubview(overlay, positioned: .below, relativeTo: textView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let frame = bounds.insetBy(dx: horizontalInset, dy: 0)
        textView.frame = frame
        textView.textContainer?.containerSize = CGSize(width: frame.width, height: .greatestFiniteMagnitude)
        overlay.frame = frame
        overlay.needsDisplay = true
    }

    func fittingHeight(width: CGFloat) -> CGFloat {
        guard let container = textView.textContainer, let layoutManager = textView.layoutManager else { return 0 }
        container.containerSize = CGSize(width: max(1, width - horizontalInset * 2),
                                         height: .greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: container)
        let visible = textView.textStorage?.readerVisibleLength ?? 0
        if let storage = textView.textStorage, visible > 0, visible < storage.length {
            // The block ends with the line before the hidden continuation
            // word, line spacing included; the word's own line stays out of view.
            let glyph = layoutManager.glyphIndexForCharacter(at: visible - 1)
            // Exact, not rounded up: the next slice's highlight must meet this one's.
            return layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).maxY
        }
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
        view.textView.onInteractionBegan = onManualNavigation
        view.textView.onHighlight = onHighlight
        view.textView.onNote = onNote
        view.textView.onPronounce = pronounce
        view.textView.setSelectionColors(background: NSColor(palette.accent), foreground: NSColor(palette.onAccent))
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
        let request = localScrollRequest
        let coordinator = context.coordinator
        let updateID = UUID()
        coordinator.updateID = updateID
        let intent = followState
        let revision = intent?.revision
        let motion: ReaderScrollMotion = !reduceMotion && animatesFollow ? .smooth : .instant
        DispatchQueue.main.async { [weak view] in
            guard let view, coordinator.updateID == updateID, intent?.revision == revision else { return }
            if let request, coordinator.handledScrollRequest != request.id {
                if view.followNarration(request.range, motion: request.motion, explicit: true) {
                    coordinator.handledScrollRequest = request.id
                    onScrollRequestHandled(request.id)
                }
            } else if intent?.isSuspended != true, let range, view.narrationFollowRange == range {
                view.followNarration(range, motion: motion)
            }
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
    @discardableResult
    func followNarration(_ range: NSRange, motion: ReaderScrollMotion, explicit: Bool = false) -> Bool {
        guard window != nil, (explicit || textView.selectedRange().length == 0),
              let scroll = enclosingScrollView, let document = scroll.documentView,
              let layout = textView.layoutManager, let container = textView.textContainer,
              NSMaxRange(range) <= (textView.textStorage?.length ?? 0),
              (explicit || NSEvent.pressedMouseButtons == 0) else { return false }
        layoutSubtreeIfNeeded()
        layout.ensureLayout(for: container)
        let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        guard glyphs.length > 0 else { return false }
        let line = layout.lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
            .offsetBy(dx: textView.textContainerOrigin.x, dy: textView.textContainerOrigin.y)
        let rect = textView.convert(line, to: document)
        let visible = scroll.contentView.documentVisibleRect
        guard visible.height > 0 else { return false }
        let maximum = max(0, document.bounds.height - visible.height)
        let target = min(maximum, max(0, rect.midY - visible.height * 0.5))
        let animator = ReaderScrollAnimator.animator(for: scroll)
        if let heading = animator.destination, abs(heading - target) <= 1 { return true }
        // The same central band as on iOS: a line already there never moves.
        let position = (rect.midY - visible.minY) / visible.height
        guard !readerFollowBand.contains(position) else { return true }
        guard abs(target - visible.minY) > 1 else { return true }
        animator.scroll(to: target, motion: motion, viewport: visible.height)
        return true
    }
}

/// The Mac counterpart of the iOS animator: moves the clip view frame by
/// frame, can be retargeted without stopping and yields to the reader's own
/// scrolling.
@MainActor
final class ReaderScrollAnimator: NSObject {
    private static var key: UInt8 = 0
    private weak var scroll: NSScrollView?
    private var link: CADisplayLink?
    private var from: CGFloat = 0
    private var to: CGFloat = 0
    private var start: CFTimeInterval = 0
    private var duration: CFTimeInterval = 0.3
    private var motion: ReaderScrollMotion = .smooth
    private var lastApplied: CGFloat = 0

    var destination: CGFloat? { link == nil ? nil : to }

    static func animator(for scroll: NSScrollView) -> ReaderScrollAnimator {
        if let existing = objc_getAssociatedObject(scroll, &key) as? ReaderScrollAnimator {
            return existing
        }
        let animator = ReaderScrollAnimator()
        animator.scroll = scroll
        objc_setAssociatedObject(scroll, &key, animator, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return animator
    }

    func scroll(to target: CGFloat, motion: ReaderScrollMotion, viewport: CGFloat) {
        guard let scroll else { return }
        guard motion != .instant else {
            stop()
            apply(target, to: scroll)
            return
        }
        let current = scroll.contentView.bounds.origin.y
        self.motion = link == nil ? motion : .settle
        from = current
        to = target
        lastApplied = current
        start = CACurrentMediaTime()
        duration = readerScrollDuration(distance: abs(target - current), viewport: viewport)
        if link == nil {
            let link = scroll.displayLink(target: self, selector: #selector(step(_:)))
            link.add(to: .main, forMode: .common)
            self.link = link
        }
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    private func apply(_ y: CGFloat, to scroll: NSScrollView) {
        let origin = NSPoint(x: scroll.contentView.bounds.origin.x, y: y)
        scroll.contentView.scroll(to: origin)
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    @objc private func step(_ link: CADisplayLink) {
        guard let scroll, NSEvent.pressedMouseButtons == 0,
              abs(scroll.contentView.bounds.origin.y - lastApplied) <= 1 else {
            stop()
            return
        }
        let t = (CACurrentMediaTime() - start) / duration
        let y = from + (to - from) * CGFloat(readerScrollProgress(t, motion: motion))
        lastApplied = y
        apply(y, to: scroll)
        if t >= 1 { stop() }
    }
}
#endif
