// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import PDFKit

/// A contents row keeps its destination in the source document's coordinates.
/// PDF page IDs need not be contiguous in the extracted narration chapters.
struct ReaderContentsEntry: Identifiable, Sendable, Equatable {
    let id: Int
    let title: String
    let chapterIndex: Int
}

enum PDFContents {
    static func entries(url: URL) -> [ReaderContentsEntry] {
        guard let document = PDFDocument(url: url) else { return [] }
        return entries(in: document)
    }

    static func entries(in document: PDFDocument) -> [ReaderContentsEntry] {
        var rows: [ReaderContentsEntry] = []
        func visit(_ node: PDFOutline) {
            for index in 0..<node.numberOfChildren {
                guard let child = node.child(at: index) else { continue }
                let destination = child.destination ?? (child.action as? PDFActionGoTo)?.destination
                if let page = destination?.page {
                    let pageIndex = document.index(for: page)
                    if pageIndex != NSNotFound, pageIndex < document.pageCount {
                        rows.append(ReaderContentsEntry(id: rows.count,
                            title: child.label ?? String(localized: "Untitled"), chapterIndex: pageIndex))
                    }
                }
                // Heading-only outline nodes can still contain valid destinations.
                visit(child)
            }
        }
        if let root = document.outlineRoot { visit(root) }
        if rows.isEmpty {
            return (0..<document.pageCount).map {
                ReaderContentsEntry(id: $0, title: String(localized: "Page \($0 + 1)"), chapterIndex: $0)
            }
        }
        return rows
    }
}
