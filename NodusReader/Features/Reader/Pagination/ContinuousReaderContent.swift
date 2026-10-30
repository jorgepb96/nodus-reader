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

    @State private var visibleID: Int?
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
        .scrollPosition(id: $visibleID, anchor: axis == .vertical ? .top : .leading)
        .onScrollGeometryChange(for: Bool.self) { geometry in
            // The last slice can never reach the leading edge, so the end of
            // the content counts as being on the last page.
            // `visibleRect` already accounts for the reader's top and bottom
            // bars (content insets), unlike offset + container size.
            if axis == .vertical {
                return geometry.visibleRect.maxY >= geometry.contentSize.height - 2
            }
            return geometry.visibleRect.maxX >= geometry.contentSize.width - 2
        } action: { _, atEnd in
            if atEnd, let last = pages.indices.last, pageIndex != last {
                visibleID = last
                pageIndex = last
            }
        }
        .scrollIndicators(axis == .vertical ? .automatic : .hidden)
        .background(Color(platformColor: style.background))
        .onAppear { visibleID = pageIndex }
        .onChange(of: narrationPageID, initial: true) { _, id in
            // Bring distant lazy slices into existence (a seek or chapter jump).
            // Adjacent slices are already laid out; their text views follow the
            // narrated line without snapping back to the start of each slice.
            if let id, abs(id - (visibleID ?? pageIndex)) > 1 { visibleID = id }
        }
        .onChange(of: visibleID) { _, id in
            // The user scrolled: report the slice at the leading edge.
            if let id, id != pageIndex { pageIndex = id }
        }
        .onChange(of: pageIndex) { _, index in
            // A contents jump, bookmark or narration follow moved the reader.
            if visibleID != index {
                withAnimation(reduceMotion || narrationReturnTarget != nil ? nil : .easeInOut(duration: 0.25)) { visibleID = index }
            }
        }
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
