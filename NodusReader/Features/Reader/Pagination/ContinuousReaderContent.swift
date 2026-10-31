// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Continuous reading: the TextKit slices of the book laid end to end in a
/// freely scrolling column (vertical) or strip of columns (horizontal), with
/// no page snapping. `pageIndex` tracks the slice at the leading edge, so the
/// reader's progress, bookmarks, contents jumps and narration follow keep
/// working exactly as in paged mode.
struct ContinuousReaderContent: View {
    var pages: [ReaderPage]
    var axis: Axis
    /// Horizontal strip only: the width and height of each column.
    var columnWidth: CGFloat?
    var columnHeight: CGFloat?
    @Binding var pageIndex: Int
    var style: ReaderPageStyle
    var narrationChapterIndex: Int?
    var narrationRange: NSRange?
    @Binding var narrationReturnTarget: ReaderNavigationTarget?
    var narrationBottomPadding: CGFloat
    var highlightsProvider: (ReaderPage) -> ReaderPageHighlights
    var onWordTap: (Int, Int) -> Void
    var onHighlight: (Int, NSRange, AnnotationColor) -> Void
    var onNote: (Int, NSRange) -> Void

    /// The slice last reported from scrolling. A `pageIndex` that differs
    /// from it came from elsewhere (contents, bookmark, search) and scrolls.
    @State private var leadingID: Int?
    @State private var atEnd = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var narrationPageID: Int? {
        guard axis == .vertical, let narrationChapterIndex, let narrationRange else { return nil }
        return pages.first { page in
            page.chapterIndex == narrationChapterIndex &&
            narrationRange.location >= page.chapterStartOffset &&
            narrationRange.location < page.chapterEndOffset
        }?.id
    }

    var body: some View {
        // Scrolling has a single owner. The narration follow moves the offset
        // line by line, so jumps are one-shot `scrollTo` calls: a
        // `scrollPosition(id:)` binding would re-anchor the leading slice's
        // top edge on every layout change and fight the follow.
        ScrollViewReader { proxy in
            ScrollView(axis == .vertical ? .vertical : .horizontal) {
                if axis == .vertical {
                    LazyVStack(spacing: 0) { slices }
                        .scrollTargetLayout()
                        .padding(.vertical, 16)
                        .padding(.bottom, narrationBottomPadding)
                } else {
                    LazyHStack(spacing: 0) { slices }
                        .scrollTargetLayout()
                }
            }
            .onScrollTargetVisibilityChange(idType: Int.self, threshold: 0.01) { ids in
                // The user or the narration follow scrolled: report the slice
                // at the leading edge.
                guard let first = ids.min() else { return }
                report(atEnd ? pages.indices.last ?? first : first)
            }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                // The last slice can never reach the leading edge, so the end of
                // the content counts as being on the last page.
                // `visibleRect` already accounts for the reader's top and bottom
                // bars (content insets), unlike offset + container size.
                if axis == .vertical {
                    return geometry.visibleRect.maxY >= geometry.contentSize.height - 2
                }
                return geometry.visibleRect.maxX >= geometry.contentSize.width - 2
            } action: { _, isAtEnd in
                atEnd = isAtEnd
                if isAtEnd, let last = pages.indices.last { report(last) }
            }
            .scrollIndicators(axis == .vertical ? .automatic : .hidden)
            .background(Color(platformColor: style.background))
            .onAppear {
                leadingID = pageIndex
                proxy.scrollTo(pageIndex, anchor: anchor)
            }
            .onChange(of: narrationPageID, initial: true) { _, id in
                // Bring distant lazy slices into existence (a seek or chapter jump).
                // Adjacent slices are already laid out; their text views follow the
                // narrated line without snapping back to the start of each slice.
                if let id, abs(id - (leadingID ?? pageIndex)) > 1 {
                    leadingID = id
                    proxy.scrollTo(id, anchor: anchor)
                }
            }
            .onChange(of: pageIndex) { _, index in
                // A contents jump, bookmark or narration follow moved the reader.
                guard index != leadingID else { return }
                leadingID = index
                withAnimation(reduceMotion || narrationReturnTarget != nil ? nil : .easeInOut(duration: 0.25)) {
                    proxy.scrollTo(index, anchor: anchor)
                }
            }
        }
    }

    private var anchor: UnitPoint { axis == .vertical ? .top : .leading }

    private func report(_ id: Int) {
        leadingID = id
        if pageIndex != id { pageIndex = id }
    }

    private func scrollRequest(for page: ReaderPage) -> ReaderTextScrollRequest? {
        guard axis == .vertical, let target = narrationReturnTarget,
              target.chapterIndex == page.chapterIndex, let offset = target.characterOffset,
              offset >= page.chapterStartOffset, offset < page.chapterEndOffset else { return nil }
        return ReaderTextScrollRequest(id: target.id, range: NSRange(location: offset, length: 1))
    }

    @ViewBuilder
    private var slices: some View {
        ForEach(pages) { page in
            SelectableReaderText(
                text: page.attributed,
                mapping: .page(page),
                highlights: highlightsProvider(page),
                horizontalInset: style.margin,
                fillsProposedHeight: axis == .horizontal,
                accessibilityLabel: "\(page.chapterTitle), part \(page.pageIndexInChapter + 1) of \(max(page.pagesInChapter, 1))",
                narrationFollowRange: page.id == narrationPageID ? narrationRange : nil,
                scrollRequest: scrollRequest(for: page),
                onScrollRequestHandled: { id in
                    if narrationReturnTarget?.id == id { narrationReturnTarget = nil }
                },
                onWordTap: { offset in onWordTap(page.chapterIndex, offset) },
                onHighlight: { range, color in onHighlight(page.chapterIndex, range, color) },
                onNote: { range in onNote(page.chapterIndex, range) }
            )
            .frame(width: columnWidth, height: columnHeight.map { $0 - 16 })
            .padding(.vertical, axis == .horizontal ? 8 : 0)
            // TextKit leaves out the line spacing after the last line of a
            // slice that ends a paragraph; a slice that continues one keeps it.
            .padding(.bottom, axis == .vertical && !page.continuesParagraph ? style.lineSpacing : 0)
            // Breathing room before each new chapter in the vertical column.
            .padding(.top, axis == .vertical && page.pageIndexInChapter == 0 && page.id > 0 ? 48 : 0)
            .overlay(alignment: .trailing) {
                if axis == .horizontal {
                    Rectangle()
                        .fill(Color(platformColor: style.muted).opacity(0.18))
                        .frame(width: 0.5)
                        .padding(.vertical, 24)
                }
            }
            .id(page.id)
        }
    }
}

private extension Color {
    init(platformColor: PlatformColor) {
        #if os(macOS)
        self.init(nsColor: platformColor)
        #else
        self.init(uiColor: platformColor)
        #endif
    }
}
