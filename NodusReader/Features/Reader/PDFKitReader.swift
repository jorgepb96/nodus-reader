// SPDX-License-Identifier: AGPL-3.0-only
import DesignSystem
import PDFKit
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct PDFKitReader: View {
    let url: URL
    @Binding var pageIndex: Int
    @Binding var pageCount: Int
    @Binding var jumpToPage: Int?
    var background: Color
    var search: ReaderSearchModel?

    var body: some View {
        // Read here so a new query or match updates the page view.
        let query = search?.isPresented == true ? search?.query ?? "" : ""
        let current = search?.current
        #if os(macOS)
        MacPDFReader(url: url, pageIndex: $pageIndex, pageCount: $pageCount,
                     jumpToPage: $jumpToPage, background: NSColor(background),
                     search: search, query: query, current: current)
        #else
        IOSPDFReader(url: url, pageIndex: $pageIndex, pageCount: $pageCount,
                     jumpToPage: $jumpToPage, background: UIColor(background),
                     search: search, query: query, current: current)
        #endif
    }
}

/// Find in a PDF with PDFKit: every match is highlighted, and the current one
/// is selected and scrolled to. The search runs a moment after the last
/// keystroke and starts from the page on screen.
@MainActor
final class PDFSearchDriver {
    private var query = ""
    private var selections: [PDFSelection] = []
    private var shown: Int?
    private var pending: Task<Void, Never>?

    nonisolated init() {}

    func update(_ view: PDFView, search: ReaderSearchModel?, query newQuery: String, current: Int?) {
        let trimmed = newQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed != query {
            query = trimmed
            pending?.cancel()
            selections = []
            shown = nil
            view.highlightedSelections = nil
            guard !trimmed.isEmpty else {
                Task { @MainActor in search?.setCount(0, startingAt: nil) }
                return
            }
            Task { @MainActor in search?.isSearching = true }
            pending = Task { @MainActor [weak self, weak view] in
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled, let self, let view else { return }
                self.find(trimmed, in: view, search: search)
            }
            return
        }
        guard let current, current != shown, selections.indices.contains(current) else { return }
        shown = current
        let selection = selections[current]
        view.setCurrentSelection(selection, animate: true)
        view.go(to: selection)
    }

    private func find(_ text: String, in view: PDFView, search: ReaderSearchModel?) {
        guard let document = view.document else { return }
        let found = document.findString(text, withOptions: [.caseInsensitive, .diacriticInsensitive])
        selections = Array(found.prefix(ReaderSearch.maximumMatches))
        for selection in selections {
            selection.color = PlatformColor(hex: NodusHex.searchMatch, alpha: 0.6)
        }
        view.highlightedSelections = selections.isEmpty ? nil : selections
        let currentPage = view.currentPage.map { document.index(for: $0) } ?? 0
        let start = selections.firstIndex { selection in
            (selection.pages.first.map { document.index(for: $0) } ?? 0) >= currentPage
        }
        search?.isSearching = false
        search?.setCount(selections.count, startingAt: start)
    }
}

#if os(macOS)
private struct MacPDFReader: NSViewRepresentable {
    let url: URL
    @Binding var pageIndex: Int
    @Binding var pageCount: Int
    @Binding var jumpToPage: Int?
    var background: NSColor
    var search: ReaderSearchModel?
    var query: String
    var current: Int?

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.autoScales = true
        view.backgroundColor = background
        view.document = PDFDocument(url: url)
        context.coordinator.observe(view)
        context.coordinator.parent = self
        DispatchQueue.main.async {
            pageCount = view.document?.pageCount ?? 0
            go(to: pageIndex, in: view)
        }
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        context.coordinator.parent = self
        view.backgroundColor = background
        context.coordinator.search.update(view, search: search, query: query, current: current)
        if let target = jumpToPage {
            DispatchQueue.main.async {
                go(to: target, in: view)
                jumpToPage = nil
            }
        }
    }

    private func go(to index: Int, in view: PDFView) {
        guard let document = view.document, document.pageCount > 0 else { return }
        let clamped = min(max(0, index), document.pageCount - 1)
        guard let page = document.page(at: clamped) else { return }
        view.go(to: page)
    }

    final class Coordinator {
        var parent: MacPDFReader
        private var token: NSObjectProtocol?
        let search = PDFSearchDriver()

        init(parent: MacPDFReader) {
            self.parent = parent
        }

        deinit {
            if let token { NotificationCenter.default.removeObserver(token) }
        }

        func observe(_ view: PDFView) {
            token = NotificationCenter.default.addObserver(
                forName: .PDFViewPageChanged, object: view, queue: .main
            ) { [weak self, weak view] _ in
                guard let self, let view, let page = view.currentPage,
                      let index = view.document?.index(for: page) else { return }
                if parent.pageIndex != index { parent.pageIndex = index }
                if parent.pageCount != (view.document?.pageCount ?? 0) {
                    parent.pageCount = view.document?.pageCount ?? 0
                }
            }
        }
    }
}
#else
private struct IOSPDFReader: UIViewRepresentable {
    let url: URL
    @Binding var pageIndex: Int
    @Binding var pageCount: Int
    @Binding var jumpToPage: Int?
    var background: UIColor
    var search: ReaderSearchModel?
    var query: String
    var current: Int?

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.autoScales = true
        view.backgroundColor = background
        view.usePageViewController(false)
        view.document = PDFDocument(url: url)
        context.coordinator.observe(view)
        context.coordinator.parent = self
        DispatchQueue.main.async {
            pageCount = view.document?.pageCount ?? 0
            go(to: pageIndex, in: view)
        }
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        context.coordinator.parent = self
        view.backgroundColor = background
        context.coordinator.search.update(view, search: search, query: query, current: current)
        if let target = jumpToPage {
            DispatchQueue.main.async {
                go(to: target, in: view)
                jumpToPage = nil
            }
        }
    }

    private func go(to index: Int, in view: PDFView) {
        guard let document = view.document, document.pageCount > 0 else { return }
        let clamped = min(max(0, index), document.pageCount - 1)
        guard let page = document.page(at: clamped) else { return }
        view.go(to: page)
    }

    final class Coordinator {
        var parent: IOSPDFReader
        private var token: NSObjectProtocol?
        let search = PDFSearchDriver()

        init(parent: IOSPDFReader) {
            self.parent = parent
        }

        deinit {
            if let token { NotificationCenter.default.removeObserver(token) }
        }

        func observe(_ view: PDFView) {
            token = NotificationCenter.default.addObserver(
                forName: .PDFViewPageChanged, object: view, queue: .main
            ) { [weak self, weak view] _ in
                guard let self, let view, let page = view.currentPage,
                      let index = view.document?.index(for: page) else { return }
                if parent.pageIndex != index { parent.pageIndex = index }
                if parent.pageCount != (view.document?.pageCount ?? 0) {
                    parent.pageCount = view.document?.pageCount ?? 0
                }
            }
        }
    }
}
#endif
