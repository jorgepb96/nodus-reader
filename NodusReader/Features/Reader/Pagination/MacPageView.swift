// SPDX-License-Identifier: AGPL-3.0-only
#if os(macOS)
import AppKit
import SwiftUI

final class ReaderMacPageContainer: NSView {
    let textView = ReaderMacTextView()
    let overlay = MacHighlightOverlayView()
    var style: ReaderPageStyle

    init(style: ReaderPageStyle) {
        self.style = style
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = style.background.cgColor
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

        // Highlights are painted behind the glyphs (the text view draws no
        // background), so even opaque narration colours never hide words.
        overlay.textView = textView
        addSubview(overlay, positioned: .below, relativeTo: textView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let frame = bounds.insetBy(dx: style.margin, dy: 8)
        textView.frame = frame
        textView.textContainer?.containerSize = frame.size
        overlay.frame = frame
        overlay.needsDisplay = true
    }
}

final class ReaderMacTextView: NSTextView {
    /// Local index ↔ anchor space (chapter offsets, or PDF page offsets).
    var mapping: ReaderTextMapping?
    var onWordTap: ((Int) -> Void)?
    var onHighlight: ((NSRange, AnnotationColor) -> Void)?
    var onNote: ((NSRange) -> Void)?

    private var clickRecognizer: NSClickGestureRecognizer?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard clickRecognizer == nil else { return }
        let click = NSClickGestureRecognizer(target: self, action: #selector(handleClick(_:)))
        click.numberOfClicksRequired = 1
        addGestureRecognizer(click)
        clickRecognizer = click
    }

    private func chapterRange(for localRange: NSRange) -> NSRange? {
        mapping?.anchorRange(for: localRange)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        guard let range = chapterRange(for: selectedRange()), range.length > 0 else { return menu }

        let highlightItem = NSMenuItem(title: String(localized: "Highlight"), action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: String(localized: "Highlight"))
        for color in AnnotationColor.allCases {
            let item = NSMenuItem(title: color.title, action: #selector(applyHighlight(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = color.rawValue
            submenu.addItem(item)
        }
        highlightItem.submenu = submenu
        menu.insertItem(highlightItem, at: 0)

        let noteItem = NSMenuItem(title: String(localized: "Add Note…"), action: #selector(addNote), keyEquivalent: "")
        noteItem.target = self
        menu.insertItem(noteItem, at: 1)
        return menu
    }

    @objc private func applyHighlight(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let color = AnnotationColor(rawValue: raw),
              let range = chapterRange(for: selectedRange()) else { return }
        onHighlight?(range, color)
    }

    @objc private func addNote() {
        guard let range = chapterRange(for: selectedRange()) else { return }
        onNote?(range)
    }

    @objc private func handleClick(_ gesture: NSClickGestureRecognizer) {
        guard selectedRange().length == 0, let mapping else { return }
        let point = gesture.location(in: self)
        let containerPoint = CGPoint(x: point.x - textContainerOrigin.x,
                                     y: point.y - textContainerOrigin.y)
        guard let container = textContainer, let layoutManager else { return }
        let index = layoutManager.characterIndex(for: containerPoint, in: container,
                                                 fractionOfDistanceBetweenInsertionPoints: nil)
        if let offset = mapping.anchorOffset(index) {
            onWordTap?(offset)
        }
    }
}

final class MacHighlightOverlayView: NSView {
    struct Span {
        var range: NSRange
        var fill: NSColor
        var underline: NSColor?
        var underlineWidth: CGFloat
        var rounded: Bool
    }

    weak var textView: ReaderMacTextView?
    var spans: [Span] = [] {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let textView, let layoutManager = textView.layoutManager,
              let container = textView.textContainer else { return }
        layoutManager.ensureLayout(for: container)
        for span in spans {
            guard let text = textView.textStorage, span.range.length > 0,
                  NSMaxRange(span.range) <= text.length else { continue }
            let glyphRange = layoutManager.glyphRange(forCharacterRange: span.range, actualCharacterRange: nil)
            var rects: [NSRect] = []
            layoutManager.enumerateEnclosingRects(forGlyphRange: glyphRange,
                                                  withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                                                  in: container) { rect, _ in
                rects.append(rect.offsetBy(dx: textView.textContainerOrigin.x,
                                            dy: textView.textContainerOrigin.y))
            }
            for rect in rects {
                let path = span.rounded
                    ? NSBezierPath(roundedRect: rect.insetBy(dx: 0, dy: -1), xRadius: 3, yRadius: 3)
                    : NSBezierPath(rect: rect.insetBy(dx: 0, dy: -1))
                span.fill.setFill()
                path.fill()
                if let underline = span.underline {
                    underline.setFill()
                    NSRect(x: rect.minX, y: rect.maxY - span.underlineWidth,
                           width: rect.width, height: span.underlineWidth).fill()
                }
            }
        }
    }
}

struct MacPageView: NSViewRepresentable {
    var page: ReaderPage
    var style: ReaderPageStyle
    var highlights: ReaderPageHighlights
    var onWordTap: (Int) -> Void
    var onHighlight: (NSRange, AnnotationColor) -> Void
    var onNote: (NSRange) -> Void

    func makeNSView(context: Context) -> ReaderMacPageContainer {
        ReaderMacPageContainer(style: style)
    }

    func updateNSView(_ container: ReaderMacPageContainer, context: Context) {
        let styleChanged = container.style != style
        container.style = style
        container.layer?.backgroundColor = style.background.cgColor
        container.textView.mapping = .page(page)
        container.textView.onWordTap = onWordTap
        container.textView.onHighlight = onHighlight
        container.textView.onNote = onNote
        // A theme change keeps the same characters but changes their colours,
        // so comparing only the plain string would leave stale text colours.
        if styleChanged || container.textView.string != page.attributed.string {
            container.textView.textStorage?.setAttributedString(page.attributed)
        }
        container.overlay.spans = highlights.spans.compactMap { span in
            guard let local = page.localRange(forChapterRange: span.range) else { return nil }
            return MacHighlightOverlayView.Span(range: local, fill: span.fill,
                                                underline: span.underline,
                                                underlineWidth: span.underlineWidth,
                                                rounded: span.rounded)
        }
        container.needsLayout = true
        container.overlay.needsDisplay = true
    }
}

struct MacPageSpread: View {
    var pages: [ReaderPage]
    @Binding var pageIndex: Int
    var style: ReaderPageStyle
    var highlightsProvider: (ReaderPage) -> ReaderPageHighlights
    var onWordTap: (Int, Int) -> Void
    var onHighlight: (Int, NSRange, AnnotationColor) -> Void
    var onNote: (Int, NSRange) -> Void

    private var firstVisibleIndex: Int {
        // On an odd final page, pair it with the previous page so the spread
        // never ends with an empty right-hand sheet.
        if pageIndex == pages.count - 1, pageIndex > 0, pageIndex.isMultiple(of: 2) {
            return pageIndex - 1
        }
        return pageIndex
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(0..<2, id: \.self) { offset in
                let index = firstVisibleIndex + offset
                if pages.indices.contains(index) {
                    let page = pages[index]
                    MacPageView(page: page, style: style,
                                highlights: highlightsProvider(page),
                                onWordTap: { offset in onWordTap(page.chapterIndex, offset) },
                                onHighlight: { range, color in
                                    onHighlight(page.chapterIndex, range, color)
                                },
                                onNote: { range in onNote(page.chapterIndex, range) })
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Color(nsColor: style.background)
                }
                if offset == 0 {
                    Rectangle()
                        .fill(Color.black.opacity(0.12))
                        .frame(width: 1)
                }
            }
        }
        .background(Color(nsColor: style.background))
    }
}
#endif
