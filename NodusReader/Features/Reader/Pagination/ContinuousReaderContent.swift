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
    /// Slices currently on screen. A line inside one of them is reached with
    /// a single glide of its own text view; only others need a travel first.
    @State private var visibleIDs: Set<Int> = []
    /// The return request whose slice is ready to centre its line, and how.
    @State private var armedReturn: (id: UUID, motion: ReaderScrollMotion)?
    /// While the column travels towards a distant slice, the line-by-line
    /// follow waits: two owners moving the offset at once made it bounce.
    @State private var travelID: UUID?
    /// False for a moment after the column is (re)built, so the first
    /// positioning lands at once instead of sliding from a slice's top edge.
    @State private var settled = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.readerFollowState) private var followState
    @Environment(\.readerManualNavigation) private var onManualNavigation

    private var narrationPageID: Int? {
        // An explicit return owns the scroll until it has landed.
        guard followState?.isSuspended != true, axis == .vertical, narrationReturnTarget == nil,
              let narrationChapterIndex, let narrationRange else { return nil }
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
            .onScrollPhaseChange { _, phase in
                // Only a real touch suspends the follow. Deceleration also
                // follows the animated scrolls that keep the spoken line in
                // place, so treating it as manual input stopped auto-scroll
                // by itself. Every user drag already starts with tracking.
                if phase == .tracking || phase == .interacting {
                    onManualNavigation?()
                }
            }
            .onScrollTargetVisibilityChange(idType: Int.self, threshold: 0.01) { ids in
                visibleIDs = Set(ids)
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
            .scrollIndicators(axis == .vertical ? .automatic : .never)
            .background(Color(platformColor: style.background))
            .onAppear {
                // A rebuilt column (new layout, narration starting) opens on
                // the spoken or requested line, not on the top of its slice:
                // the line then needs no visible correction.
                let returnPage = returnPageID
                if axis == .vertical, let id = returnPage ?? narrationPageID {
                    leadingID = id
                    proxy.scrollTo(id, anchor: .center)
                } else {
                    leadingID = pageIndex
                    proxy.scrollTo(pageIndex, anchor: anchor)
                }
                if let target = narrationReturnTarget, returnPage != nil {
                    armedReturn = (target.id, .instant)
                }
            }
            .task {
                try? await Task.sleep(for: .milliseconds(450))
                settled = true
            }
            .onChange(of: narrationPageID) { _, id in
                // The spoken line moved to another slice. On screen, its text
                // view glides to it. A seek or chapter jump far away travels
                // there first, and the follow waits until it has arrived.
                guard let id, axis == .vertical, !visibleIDs.contains(id) else { return }
                travel(proxy, to: id, returnID: nil)
            }
            .onChange(of: pageIndex) { _, index in
                // A contents jump, bookmark or narration follow moved the reader.
                guard index != leadingID else { return }
                leadingID = index
                // A pending return places the exact line itself; snapping
                // the slice's top edge first was the jump before the glide.
                if axis == .vertical, narrationReturnTarget != nil { return }
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) {
                    proxy.scrollTo(index, anchor: anchor)
                }
            }
            .onChange(of: narrationReturnTarget?.id) { _, _ in
                guard let target = narrationReturnTarget, let id = returnPageID else { return }
                if axis == .horizontal {
                    leadingID = id
                    proxy.scrollTo(id, anchor: anchor)
                    narrationReturnTarget = nil
                } else if !settled {
                    leadingID = id
                    proxy.scrollTo(id, anchor: .center)
                    armedReturn = (target.id, .instant)
                } else if visibleIDs.contains(id) {
                    // Already on screen: one glide up or down, or nothing at
                    // all when the line is already in the middle.
                    armedReturn = (target.id, .smooth)
                } else {
                    travel(proxy, to: id, returnID: target.id)
                }
            }
        }
    }

    private var anchor: UnitPoint { axis == .vertical ? .top : .leading }

    /// The slice holding the pending explicit return (Return to narration,
    /// a contents or search jump).
    private var returnPageID: Int? {
        guard let target = narrationReturnTarget, let offset = target.characterOffset else { return nil }
        return pages.first(where: {
            $0.chapterIndex == target.chapterIndex && offset >= $0.chapterStartOffset &&
            offset < max($0.chapterEndOffset, $0.chapterStartOffset + 1)
        })?.id
    }

    /// Brings a slice that is not on screen next to the viewport's centre,
    /// always on the far side of it, so the line is still ahead in the
    /// direction of travel. The text view then eases the rest of the way:
    /// one motion, never back and forth. A distant slice is reached at once;
    /// animating through hundreds of lazily built slices would stutter.
    private func travel(_ proxy: ScrollViewProxy, to id: Int, returnID: UUID?) {
        let reference = leadingID ?? pageIndex
        let forward = id > (visibleIDs.max() ?? reference)
        let neighbour = min(max(forward ? id - 1 : id + 1, 0), max(pages.count - 1, 0))
        let distance = abs(id - (forward ? visibleIDs.max() ?? reference : visibleIDs.min() ?? reference))
        let token = UUID()
        travelID = token
        let finish = {
            guard travelID == token else { return }
            travelID = nil
            if let returnID, narrationReturnTarget?.id == returnID {
                armedReturn = (returnID, reduceMotion ? .instant : .settle)
            }
        }
        if reduceMotion || distance > 4 {
            proxy.scrollTo(neighbour, anchor: .center)
            // Let the lazy stack lay out the destination before it is asked
            // to place its line.
            DispatchQueue.main.async { finish() }
        } else {
            withAnimation(.easeIn(duration: 0.3)) {
                proxy.scrollTo(neighbour, anchor: .center)
            } completion: {
                finish()
            }
        }
    }

    private func report(_ id: Int) {
        // Ignore stale visibility reports while an explicit range jump is
        // materializing its lazy text view. The one-shot request owns it.
        guard axis != .vertical || narrationReturnTarget == nil else { return }
        leadingID = id
        if pageIndex != id { pageIndex = id }
    }

    private func scrollRequest(for page: ReaderPage) -> ReaderTextScrollRequest? {
        // Only once the slice is ready: a request seen while the column is
        // still travelling would start a second, competing move.
        guard axis == .vertical, let target = narrationReturnTarget, let armedReturn,
              armedReturn.id == target.id,
              target.chapterIndex == page.chapterIndex, let offset = target.characterOffset,
              offset >= page.chapterStartOffset, offset < page.chapterEndOffset else { return nil }
        return ReaderTextScrollRequest(id: target.id, range: NSRange(location: offset, length: 1),
                                       motion: armedReturn.motion)
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
                narrationFollowRange: travelID == nil && page.id == narrationPageID ? narrationRange : nil,
                scrollRequest: scrollRequest(for: page),
                animatesFollow: settled,
                onScrollRequestHandled: { id in
                    guard narrationReturnTarget?.id == id else { return }
                    armedReturn = nil
                    narrationReturnTarget = nil
                    // The page index was moved to the line's slice without
                    // scrolling; report the slice really at the top again.
                    if let first = visibleIDs.min() { report(atEnd ? pages.indices.last ?? first : first) }
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
