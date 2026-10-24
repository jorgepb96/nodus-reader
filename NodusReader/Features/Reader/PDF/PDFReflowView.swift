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

    @State private var mode: PDFReadingMode = .original

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("PDF reading mode", selection: $mode) {
                    ForEach(PDFReadingMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
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
                              pdfPageIndex: $pdfPageIndex)
            }
        }
    }
}

// MARK: - Reflow

struct PDFReflowView: View {
    @Environment(LibraryService.self) private var library
    @Environment(ReaderPreferences.self) private var preferences

    let book: Book
    let url: URL
    let theme: ReaderTheme
    @Binding var pdfPageIndex: Int

    @State private var job = PDFReflowJob()
    @State private var showImages = true
    @State private var skipHeaders = true
    @State private var showSourceSheet = false

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
            .preferredColorScheme(theme.isDark ? .dark : .light)
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
                    .padding(.horizontal, max(20, preferences.margin))
                    .padding(.top, 20)
                    .padding(.bottom, 60)
                }
                .scrollIndicators(.hidden)
                .onScrollGeometryChange(for: Double.self) { geometry in
                    let scrollable = max(geometry.contentSize.height - geometry.containerSize.height, 1)
                    return min(max(geometry.contentOffset.y / scrollable, 0), 1)
                } action: { _, fraction in
                    let page = min(document.pageCount - 1,
                                   Int(fraction * Double(max(document.pageCount, 1))))
                    if page != pdfPageIndex { pdfPageIndex = max(0, page) }
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

                ForEach(blocks) { block in
                    blockView(block)
                }
            }
            .padding(.bottom, 6)
        }
    }

    @ViewBuilder
    private func blockView(_ block: PDFReflowBlock) -> some View {
        switch block.kind {
        case .heading1:
            Text(block.text)
                .font(.system(size: 27, weight: .regular, design: .serif))
                .foregroundStyle(theme.text)
                .padding(.top, 8)
        case .heading2:
            Text(block.text)
                .font(.system(size: 21, weight: .medium, design: .serif))
                .foregroundStyle(theme.text)
                .padding(.top, 4)
        case .body:
            JustifiedText(
                text: block.text,
                size: preferences.baseFontSize,
                weight: weight,
                useSerif: preferences.useSerif,
                color: theme.text,
                lineSpacing: preferences.lineSpacing,
                justified: preferences.justify
            )
        case .quote:
            HStack(alignment: .top, spacing: 10) {
                Rectangle().fill(theme.accent).frame(width: 2)
                JustifiedText(
                    text: block.text,
                    size: preferences.baseFontSize,
                    weight: .regular,
                    useSerif: true,
                    color: theme.muted,
                    lineSpacing: preferences.lineSpacing,
                    justified: false
                )
            }
        case .list:
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("•").foregroundStyle(theme.accent)
                Text(block.text)
                    .font(.system(size: preferences.baseFontSize, design: preferences.useSerif ? .serif : .default))
                    .foregroundStyle(theme.text)
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

    private var weight: JustifiedText.Weight {
        switch preferences.weightIndex {
        case 2: .semibold
        case 1: .medium
        default: .regular
        }
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
        do {
            let document = try await Task.detached(priority: .userInitiated) {
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
            }.value
            job.document = document
            job.progress = 1
        } catch {
            job.errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
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
                    Text("Original page")
                        .font(.system(.headline, design: .serif))
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
                            ForEach(page.regions) { region in
                                regionOverlay(region, size: proxy.size)
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
                        legend(Color(hex: 0xC4B5FD), "Text")
                        legend(Color(hex: 0x7C3AED), "Heading")
                        legend(Color(hex: 0x6E8CD8), "Table")
                        legend(Color(hex: 0x7FB89A), "Image")
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

    private func regionOverlay(_ region: PDFReflowRegion, size: CGSize) -> some View {
        let rect = CGRect(x: region.rect.minX * size.width,
                          y: region.rect.minY * size.height,
                          width: region.rect.width * size.width,
                          height: region.rect.height * size.height)
        let color: Color = switch region.kind {
        case .text: Color(hex: 0xC4B5FD)
        case .heading: Color(hex: 0x7C3AED)
        case .table: Color(hex: 0x6E8CD8)
        case .figure: Color(hex: 0x7FB89A)
        case .headerFooter: Color.gray.opacity(0.6)
        case .narrating: Color(hex: 0xE9C46A)
        }
        return Rectangle()
            .stroke(color, lineWidth: 1)
            .background(color.opacity(0.08))
            .frame(width: max(1, rect.width), height: max(1, rect.height))
            .offset(x: rect.minX, y: rect.minY)
    }

    private func legend(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 10, height: 8)
            Text(text).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func loadImage() async {
        isLoading = true
        let index = min(max(pageIndex, 0), document.totalPageCount - 1)
        let image = await Task.detached(priority: .userInitiated) { () -> PlatformImage? in
            guard let pdf = PDFDocument(url: url), let page = pdf.page(at: index) else { return nil }
            return page.thumbnail(of: CGSize(width: 900, height: 1200), for: .cropBox)
        }.value
        self.image = image
        isLoading = false
    }
}

// MARK: - Images

struct ReflowImage: View {
    let url: URL
    let theme: ReaderTheme
    @State private var image: PlatformImage?

    var body: some View {
        Group {
            if let image {
                Image(platformImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(theme.panelFallback)
                    .frame(height: 120)
                    .overlay(ProgressView())
            }
        }
        .task(id: url) {
            guard let data = await Task.detached(priority: .userInitiated, operation: { try? Data(contentsOf: url) }).value,
                  let platform = PlatformImage(data: data) else { return }
            image = platform
        }
    }
}

private extension ReaderTheme {
    var panelFallback: Color {
        isDark ? Color.white.opacity(0.06) : Color.black.opacity(0.05)
    }
}
