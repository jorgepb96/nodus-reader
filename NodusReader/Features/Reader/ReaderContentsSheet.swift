// SPDX-License-Identifier: AGPL-3.0-only
import DesignSystem
import PDFKit
import SwiftUI

struct ReaderContentsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.nodusPalette) private var palette

    let bookTitle: String
    let chapters: [ExtractedChapter]
    @Binding var currentChapter: Int
    let pdfURL: URL?
    let pageCount: Int
    @Binding var currentPage: Int
    @Binding var jumpToPage: Int?

    @State private var draftPage = 1

    private struct OutlineRow: Identifiable {
        let id = UUID()
        let title: String
        let pageIndex: Int
        let depth: Int
    }

    private var outlineRows: [OutlineRow] {
        guard let pdfURL, let document = PDFDocument(url: pdfURL), let root = document.outlineRoot else {
            return []
        }
        var rows: [OutlineRow] = []
        func visit(_ node: PDFOutline, depth: Int) {
            for index in 0..<node.numberOfChildren {
                guard let child = node.child(at: index) else { continue }
                let pageIndex = child.destination?.page.flatMap { document.index(for: $0) } ?? 0
                rows.append(OutlineRow(title: child.label ?? "Untitled", pageIndex: pageIndex, depth: depth))
                visit(child, depth: depth + 1)
            }
        }
        visit(root, depth: 0)
        return rows
    }

    var body: some View {
        NavigationStack {
            List {
                if pdfURL != nil {
                    pdfContents
                } else {
                    chapterContents
                }
            }
            .navigationTitle(bookTitle)
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear { draftPage = currentPage + 1 }
        }
        #if os(iOS)
        .presentationDetents([.medium, .large])
        #endif
    }

    @ViewBuilder
    private var chapterContents: some View {
        Section("Contents") {
            ForEach(chapters) { chapter in
                Button {
                    currentChapter = chapter.id
                    dismiss()
                } label: {
                    HStack(spacing: 10) {
                        Text("\(chapter.id + 1)")
                            .font(.caption)
                            .foregroundStyle(palette.muted)
                            .frame(width: 22, alignment: .trailing)
                            .monospacedDigit()
                        Text(chapter.title)
                            .foregroundStyle(palette.text)
                            .lineLimit(2)
                        Spacer(minLength: 6)
                        if currentChapter == chapter.id {
                            Image(systemName: "checkmark")
                                .foregroundStyle(palette.accent)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private var pdfContents: some View {
        if outlineRows.isEmpty {
            Section("Contents") {
                Text("This PDF does not include an outline.")
                    .font(.footnote)
                    .foregroundStyle(palette.muted)
            }
        } else {
            Section("Contents") {
                ForEach(outlineRows) { row in
                    Button {
                        jumpToPage = row.pageIndex
                        currentPage = row.pageIndex
                        dismiss()
                    } label: {
                        HStack(spacing: 8) {
                            if row.depth > 0 {
                                Color.clear.frame(width: CGFloat(row.depth) * 14, height: 1)
                            }
                            Text(row.title)
                                .foregroundStyle(palette.text)
                                .lineLimit(2)
                            Spacer(minLength: 6)
                            Text("\(row.pageIndex + 1)")
                                .font(.caption)
                                .foregroundStyle(palette.muted)
                                .monospacedDigit()
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }

        if pageCount > 0 {
            Section("Page") {
                HStack {
                    Text("Page")
                    Spacer()
                    Text("\(draftPage) of \(pageCount)")
                        .foregroundStyle(palette.muted)
                        .monospacedDigit()
                }
                Slider(
                    value: Binding(
                        get: { Double(draftPage) },
                        set: { draftPage = Int($0.rounded()) }
                    ),
                    in: 1...Double(max(pageCount, 1)),
                    step: 1
                )
                .accessibilityLabel("Page")
                Button("Go to page \(draftPage)") {
                    let target = min(max(draftPage - 1, 0), max(pageCount - 1, 0))
                    jumpToPage = target
                    currentPage = target
                    dismiss()
                }
                .foregroundStyle(palette.accent)
            }
        }
    }
}
