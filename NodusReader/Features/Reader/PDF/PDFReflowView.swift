// SPDX-License-Identifier: AGPL-3.0-only
import DesignSystem
import PDFKit
import SwiftUI

@Observable
final class PDFReflowJob {
    var isWorking = false
    var progress: Double = 0
    var document: PDFReflowDocument?
    var errorMessage: String?
}

enum PDFReadingMode: String, CaseIterable, Identifiable {
    case original = "Original PDF"
    case intelligent = "Intelligent Reading"
    var id: String { rawValue }
}

// MARK: - Container

struct PDFReaderContainer: View {
    @Environment(LibraryService.self) private var library
    @Environment(ReaderPreferences.self) private var preferences

    let book: Book
    let url: URL
    let theme: ReaderTheme
    @Binding var pdfPageIndex: Int
    @Binding var pdfPageCount: Int
    @Binding var jumpToPage: Int?
    /// Owned by the reader so opening a PDF note can switch to Intelligent
    /// Reading, where notes are shown.
    @Binding var mode: PDFReadingMode
    var onAnnotate: (Int, NSRange, String, AnnotationColor) -> Void = { _, _, _, _ in }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("PDF reading mode", selection: $mode) {
                    ForEach(PDFReadingMode.allCases) { mode in
                        Text(LocalizedStringKey(mode.rawValue)).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 360)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(theme.background)

            Rectangle().fill(theme.line).frame(height: 0.5)

            switch mode {
            case .original:
                PDFKitReader(url: url, pageIndex: $pdfPageIndex, pageCount: $pdfPageCount,
                             jumpToPage: $jumpToPage, background: theme.background)
                    .ignoresSafeArea(edges: .bottom)
            case .intelligent:
                PDFReflowView(book: book, url: url, theme: theme,
                              pdfPageIndex: $pdfPageIndex, jumpToPage: $jumpToPage,
                              onAnnotate: onAnnotate)
            }
        }
    }
}

// MARK: - Reflow

/// Scrolls the reflow to the last analysed page at or before `page`.
private func scroll(_ proxy: ScrollViewProxy, to page: Int, in document: PDFReflowDocument) {
    guard let target = document.pages.last(where: { $0.pageIndex <= page }) ?? document.pages.first else { return }
    proxy.scrollTo(target.pageIndex, anchor: .top)
}

struct PDFReflowView: View {
    @Environment(LibraryService.self) private var library
    @Environment(ReaderPreferences.self) private var preferences

    let book: Book
    let url: URL
    let theme: ReaderTheme
    @Binding var pdfPageIndex: Int
    /// Contents, bookmarks and "go to page" requests from the reader chrome.
    @Binding var jumpToPage: Int?
    /// A highlight or note on (original page, canonical range, quote, colour).
    var onAnnotate: (Int, NSRange, String, AnnotationColor) -> Void = { _, _, _, _ in }

    @State private var job = PDFReflowJob()
    @State private var showImages = true
    @State private var skipHeaders = true
    @State private var showSourceSheet = false

    /// The book's own typography when it has one, the global one otherwise.
    private var typography: ReaderTypography {
        ReaderAppearanceResolver.typography(for: book, preferences: preferences)
    }

    private var store: PDFReflowStore {
        PDFReflowStore(fileStore: library.fileStore)
    }

    var body: some View {
        GeometryReader { proxy in
            let showPanel = proxy.size.width > 820
            HStack(spacing: 0) {
                reflowContent
                    .frame(maxWidth: .infinity)
                if showPanel, let document = job.document {
                    Rectangle().fill(theme.line).frame(width: 0.5)
                    PDFSourcePanel(
                        book: book,
                        url: url,
                        document: document,
                        pageIndex: $pdfPageIndex,
                        showImages: $showImages,
                        skipHeaders: $skipHeaders
                    )
                    .frame(width: 300)
                }
            }
            .overlay(alignment: .topTrailing) {
                if !showPanel, job.document != nil {
                    Button {
                        showSourceSheet = true
                    } label: {
                        Image(systemName: "rectangle.righthalf.inset.filled")
                            .font(.system(size: 16))
                            .foregroundStyle(theme.text)
                            .frame(width: 40, height: 40)
                            .background(theme.background.opacity(0.94), in: Circle())
                            .overlay(Circle().stroke(theme.line, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .padding(12)
                    .accessibilityLabel("Original page panel")
                }
            }
        }
        .background(theme.background)
        .task { await loadReflow() }
        .sheet(isPresented: $showSourceSheet) {
            NavigationStack {
                if let document = job.document {
                    PDFSourcePanel(book: book, url: url, document: document,
                                   pageIndex: $pdfPageIndex,
                                   showImages: $showImages,
                                   skipHeaders: $skipHeaders)
                        .navigationTitle("Original page")
                        .inlineNavigationTitle()
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { showSourceSheet = false }
                            }
                        }
                }
            }
            .readerPresentation(isDark: theme.isDark)
        }
    }

    @ViewBuilder
    private var reflowContent: some View {
        if job.isWorking {
            VStack(spacing: 14) {
                ProgressView(value: job.progress)
                    .tint(theme.accent)
                    .frame(width: 220)
                Text("Analysing the PDF on this device…")
                    .font(.footnote)
                    .foregroundStyle(theme.muted)
                Text("\(Int(job.progress * 100))%")
                    .font(.caption2)
                    .foregroundStyle(theme.muted)
                    .monospacedDigit()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = job.errorMessage {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 24))
                    .foregroundStyle(theme.accent)
                Text("Intelligent Reading could not be prepared")
                    .font(.system(.headline, design: .serif))
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(theme.muted)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
                Button("Try again") {
                    Task { await loadReflow(force: true) }
                }
                .foregroundStyle(theme.accent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(24)
        } else if let document = job.document {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 22) {
                        ForEach(document.pages) { page in
                            pageView(page)
                                .id(page.pageIndex)
                        }
                        if document.pageCount < document.totalPageCount {
                            Text("This build has analysed the first \(document.pageCount) of \(document.totalPageCount) pages. The original PDF remains available in full.")
                                .font(.caption)
                                .foregroundStyle(theme.muted)
                                .padding(.top, 20)
                        }
                        if document.usedOCR {
                            Text("Some pages had no text layer and were read with on-device OCR. OCR can make mistakes; compare with the original page.")
                                .font(.caption2)
                                .foregroundStyle(theme.muted)
                                .padding(.top, 6)
                        }
                    }
                    .frame(maxWidth: 620)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, max(20, typography.margin))
                    .padding(.top, 20)
                    .padding(.bottom, 60)
                }
                .scrollIndicators(.hidden)
                .onScrollGeometryChange(for: Double.self) { geometry in
                    let scrollable = max(geometry.contentSize.height - geometry.containerSize.height, 1)
                    return min(max(geometry.contentOffset.y / scrollable, 0), 1)
                } action: { _, fraction in
                    // Map to the original page id: pages without text are not
                    // in the reflow, so an array index is not a page number.
                    guard !document.pages.isEmpty else { return }
                    let index = min(document.pages.count - 1,
                                    Int(fraction * Double(document.pages.count)))
                    let page = document.pages[max(0, index)].pageIndex
                    if page != pdfPageIndex { pdfPageIndex = page }
                }
                .onAppear {
                    // Switching from Original keeps the reading position.
                    scroll(proxy, to: pdfPageIndex, in: document)
                }
                .onChange(of: jumpToPage) { _, target in
                    guard let target else { return }
                    scroll(proxy, to: target, in: document)
                    pdfPageIndex = target
                    jumpToPage = nil
                }
            }
        } else {
            ProgressView().tint(theme.accent)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func pageView(_ page: PDFReflowPage) -> some View {
        let blocks = page.blocks.filter { block in
            (!skipHeaders || !block.isHeaderFooter) &&
            (showImages || (block.kind != .figure && block.kind != .tableImage))
        }
        if !blocks.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                Button {
                    pdfPageIndex = page.pageIndex
                } label: {
                    Eyebrow("Page \(page.pageIndex + 1)", color: theme.accent)
                }
                .buttonStyle(.plain)

                let layout = page.canonicalLayout
                let highlights = pageHighlights(page: page.pageIndex, text: layout.text)
                ForEach(blocks) { block in
                    blockView(block, base: layout.bases[block.id], highlights: highlights)
                }
            }
            .padding(.bottom, 6)
        }
    }

    /// Saved highlights for one original page, located in its canonical text.
    private func pageHighlights(page: Int, text: String) -> ReaderPageHighlights {
        let isDark = theme.isDark
        let spans = book.annotations.filter { $0.chapterIndex == page }.compactMap { annotation -> ReaderPageHighlightSpan? in
            guard let range = ReflowAnnotationAnchor.resolve(start: annotation.startOffset,
                                                             end: annotation.endOffset,
                                                             quote: annotation.quote,
                                                             in: text) else { return nil }
            return ReaderPageHighlightSpan(
                range: range,
                fill: PlatformColor(hex: annotation.color.fillHex, alpha: isDark ? 0.45 : 0.65),
                underline: PlatformColor(hex: annotation.color.underlineHex),
                underlineWidth: 1.5,
                rounded: true
            )
        }
        return ReaderPageHighlights(spans: spans)
    }

    /// Selectable text for one block: Highlight / Add Note in the selection
    /// menu, anchored at `base` in the page's canonical text.
    private func selectableText(_ block: PDFReflowBlock, base: Int?,
                                highlights: ReaderPageHighlights) -> some View {
        let pageIndex = block.pageIndex
        let length = (block.text as NSString).length
        let pageText = pageCanonicalText(pageIndex)
        return SelectableReaderText(
            text: attributedText(for: block),
            mapping: base.map { .block(base: $0, length: length) }
                ?? ReaderTextMapping(anchorOffset: { _ in nil }, localRange: { _ in nil }),
            highlights: highlights,
            accessibilityLabel: nil,
            onHighlight: { range, color in
                onAnnotate(pageIndex, range, quote(range, in: pageText), color)
            },
            onNote: { range in
                onAnnotate(pageIndex, range, quote(range, in: pageText), .yellow)
            }
        )
    }

    private func pageCanonicalText(_ pageIndex: Int) -> String {
        job.document?.pages.first { $0.pageIndex == pageIndex }?.canonicalLayout.text ?? ""
    }

    private func quote(_ range: NSRange, in text: String) -> String {
        let ns = text as NSString
        guard range.location >= 0, NSMaxRange(range) <= ns.length else { return "" }
        return ns.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func attributedText(for block: PDFReflowBlock) -> NSAttributedString {
        let style = ReaderPageStyle(theme: theme, typography: typography)
        var attributes = style.bodyAttributes
        switch block.kind {
        case .heading1:
            attributes[.font] = Self.serifFont(size: 27, weight: .regular)
            attributes[.paragraphStyle] = NSParagraphStyle.default
        case .heading2:
            attributes[.font] = Self.serifFont(size: 21, weight: .medium)
            attributes[.paragraphStyle] = NSParagraphStyle.default
        case .quote:
            attributes[.foregroundColor] = PlatformColor(theme.muted)
            let paragraph = (style.flushParagraphStyle.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
            paragraph.alignment = .natural
            attributes[.paragraphStyle] = paragraph
        case .list:
            let paragraph = (style.flushParagraphStyle.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
            paragraph.alignment = .natural
            attributes[.paragraphStyle] = paragraph
        case .body, .figure, .tableImage:
            break
        }
        return NSAttributedString(string: block.text, attributes: attributes)
    }

    private static func serifFont(size: CGFloat, weight: PlatformFont.Weight) -> PlatformFont {
        let base = PlatformFont.systemFont(ofSize: size, weight: weight)
        guard let descriptor = base.fontDescriptor.withDesign(.serif) else { return base }
        return PlatformFont(descriptor: descriptor, size: size) ?? base
    }

    @ViewBuilder
    private func blockView(_ block: PDFReflowBlock, base: Int?,
                           highlights: ReaderPageHighlights) -> some View {
        switch block.kind {
        case .heading1:
            selectableText(block, base: base, highlights: highlights)
                .padding(.top, 8)
        case .heading2:
            selectableText(block, base: base, highlights: highlights)
                .padding(.top, 4)
        case .body:
            selectableText(block, base: base, highlights: highlights)
        case .quote:
            HStack(alignment: .top, spacing: 10) {
                Rectangle().fill(theme.accent).frame(width: 2)
                selectableText(block, base: base, highlights: highlights)
            }
        case .list:
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("•").foregroundStyle(theme.accent)
                selectableText(block, base: base, highlights: highlights)
            }
        case .figure, .tableImage:
            if let name = block.imageFileName, showImages {
                VStack(alignment: .leading, spacing: 6) {
                    ReflowImage(url: store.imageURL(for: book.id, name: name), theme: theme)
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(theme.line, lineWidth: 1)
                        )
                    HStack(spacing: 6) {
                        Text(block.kind == .tableImage ? "Table" : "Page image")
                            .font(.caption2)
                            .foregroundStyle(theme.muted)
                        Spacer()
                        Button("Compare with page \(block.pageIndex + 1)") {
                            pdfPageIndex = block.pageIndex
                            if !isWide { showSourceSheet = true }
                        }
                        .font(.caption2)
                        .foregroundStyle(theme.accent)
                    }
                }
            }
        }
    }

    private var isWide: Bool {
        #if os(macOS)
        true
        #else
        DeviceInfo.isPad
        #endif
    }

    private func loadReflow(force: Bool = false) async {
        if !force, let cached = store.load(bookID: book.id, contentHash: book.contentHash) {
            job.document = cached
            return
        }
        job.isWorking = true
        job.errorMessage = nil
        job.progress = 0
        let bookID = book.id
        let contentHash = book.contentHash
        let store = self.store
        let url = self.url
        let work = Task.detached(priority: .userInitiated) {
            try PDFReflowExtractor.extract(
                url: url,
                bookID: bookID,
                contentHash: contentHash,
                store: store
            ) { fraction in
                Task { @MainActor in
                    job.progress = fraction
                }
            }
        }
        do {
            let document = try await withTaskCancellationHandler {
                try await work.value
            } onCancel: {
                work.cancel()
            }
            job.document = document
            job.progress = 1
        } catch {
            if !Task.isCancelled {
                job.errorMessage = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
            }
        }
        job.isWorking = false
    }
}

// MARK: - Source panel

struct PDFSourcePanel: View {
    @Environment(LibraryService.self) private var library
    let book: Book
    let url: URL
    let document: PDFReflowDocument
    @Binding var pageIndex: Int
    @Binding var showImages: Bool
    @Binding var skipHeaders: Bool

    @State private var image: PlatformImage?
    @State private var isLoading = true

    private var page: PDFReflowPage? {
        document.pages.first { $0.pageIndex == pageIndex }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Spacer()
                    Text("\(pageIndex + 1) / \(document.totalPageCount)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.white)
                    if let image {
                        Image(platformImage: image)
                            .resizable()
                            .scaledToFit()
                    } else if isLoading {
                        ProgressView()
                    }
                    if let page {
                        GeometryReader { proxy in
                            let fitted = fittedPageRect(page: page, in: proxy.size)
                            ForEach(page.regions) { region in
                                regionOverlay(region, fittedRect: fitted)
                            }
                        }
                    }
                }
                .aspectRatio(0.77, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.black.opacity(0.12), lineWidth: 1))

                HStack(spacing: 8) {
                    Button {
                        pageIndex = max(0, pageIndex - 1)
                    } label: {
                        Image(systemName: "chevron.left").frame(width: 32, height: 28)
                    }
                    .disabled(pageIndex <= 0)
                    Spacer()
                    Text((page?.regions.count ?? 0) == 0 ? "No regions" : "\(page?.regions.count ?? 0) regions")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        pageIndex = min(document.totalPageCount - 1, pageIndex + 1)
                    } label: {
                        Image(systemName: "chevron.right").frame(width: 32, height: 28)
                    }
                    .disabled(pageIndex >= document.totalPageCount - 1)
                }
                .buttonStyle(.plain)

                Toggle("Show images", isOn: $showImages)
                    .font(.footnote)
                Toggle("Skip headers & page numbers", isOn: $skipHeaders)
                    .font(.footnote)

                if let page {
                    VStack(alignment: .leading, spacing: 6) {
                        legend(NodusColors.lavender, "Text")
                        legend(NodusColors.violet, "Heading")
                        legend(NodusColors.slateBlue, "Table")
                        legend(NodusColors.sage, "Image")
                        legend(Color.gray.opacity(0.6), "Header / footer")
                    }
                    .padding(.top, 4)
                }

                Text("Regions are detected locally. Nothing is uploaded.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
            .padding(14)
            .padding(.bottom, 28)
        }
        .background(uiBackground)
        .task(id: pageIndex) { await loadImage() }
    }

    private var uiBackground: Color {
        #if os(macOS)
        Color(nsColor: .windowBackgroundColor)
        #else
        Color(uiColor: .systemBackground)
        #endif
    }

    private func fittedPageRect(page: PDFReflowPage, in size: CGSize) -> CGRect {
        guard page.width > 1, page.height > 1 else {
            return CGRect(origin: .zero, size: size)
        }
        let pageAspect = page.width / page.height
        let boxAspect = size.width / max(size.height, 1)
        let fitted: CGSize
        if pageAspect > boxAspect {
            fitted = CGSize(width: size.width, height: size.width / pageAspect)
        } else {
            fitted = CGSize(width: size.height * pageAspect, height: size.height)
        }
        return CGRect(x: (size.width - fitted.width) / 2,
                      y: (size.height - fitted.height) / 2,
                      width: fitted.width,
                      height: fitted.height)
    }

    private func regionOverlay(_ region: PDFReflowRegion, fittedRect: CGRect) -> some View {
        let rect = CGRect(x: fittedRect.minX + region.rect.minX * fittedRect.width,
                          y: fittedRect.minY + region.rect.minY * fittedRect.height,
                          width: region.rect.width * fittedRect.width,
                          height: region.rect.height * fittedRect.height)
        let color: Color = switch region.kind {
        case .text: NodusColors.lavender
        case .heading: NodusColors.violet
        case .table: NodusColors.slateBlue
        case .figure: NodusColors.sage
        case .headerFooter: Color.gray.opacity(0.6)
        case .narrating: NodusColors.gold
        }
        return Rectangle()
            .stroke(color, lineWidth: 1)
            .background(color.opacity(0.08))
            .frame(width: max(1, rect.width), height: max(1, rect.height))
            .offset(x: rect.minX, y: rect.minY)
    }

    private func legend(_ color: Color, _ text: LocalizedStringKey) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 10, height: 8)
            Text(text).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func loadImage() async {
        isLoading = true
        image = nil
        let index = min(max(pageIndex, 0), document.totalPageCount - 1)
        let rendered = await Task.detached(priority: .userInitiated) { () -> PlatformImage? in
            guard let pdf = PDFDocument(url: url), let page = pdf.page(at: index) else { return nil }
            return page.thumbnail(of: CGSize(width: 900, height: 1200), for: .cropBox)
        }.value
        guard !Task.isCancelled else { return }
        self.image = rendered
        isLoading = false
    }
}

// MARK: - Images

struct ReflowImage: View {
    let url: URL
    let theme: ReaderTheme
    @State private var image: PlatformImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                Image(platformImage: image)
                    .resizable()
                    .scaledToFit()
            } else if failed {
                RoundedRectangle(cornerRadius: 8)
                    .fill(theme.panelFallback)
                    .frame(height: 120)
                    .overlay(
                        Label("Image unavailable", systemImage: "photo.badge.exclamationmark")
                            .font(.caption)
                            .foregroundStyle(theme.muted)
                    )
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(theme.panelFallback)
                    .frame(height: 120)
                    .overlay(ProgressView())
            }
        }
        .task(id: url) {
            failed = false
            image = nil
            let decoded = await Task.detached(priority: .userInitiated, operation: { () -> PlatformImage? in
                guard let data = try? Data(contentsOf: url),
                      let platform = PlatformImage(data: data) else { return nil }
                #if os(iOS)
                return platform.preparingForDisplay() ?? platform
                #else
                return platform
                #endif
            }).value
            guard !Task.isCancelled else { return }
            guard let decoded else {
                failed = true
                return
            }
            image = decoded
        }
    }
}

private extension ReaderTheme {
    var panelFallback: Color {
        isDark ? Color.white.opacity(0.06) : Color.black.opacity(0.05)
    }
}
