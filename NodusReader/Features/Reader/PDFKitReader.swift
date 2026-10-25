// SPDX-License-Identifier: AGPL-3.0-only
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

    var body: some View {
        #if os(macOS)
        MacPDFReader(url: url, pageIndex: $pageIndex, pageCount: $pageCount,
                     jumpToPage: $jumpToPage, background: NSColor(background))
        #else
        IOSPDFReader(url: url, pageIndex: $pageIndex, pageCount: $pageCount,
                     jumpToPage: $jumpToPage, background: UIColor(background))
        #endif
    }
}

#if os(macOS)
private struct MacPDFReader: NSViewRepresentable {
    let url: URL
    @Binding var pageIndex: Int
    @Binding var pageCount: Int
    @Binding var jumpToPage: Int?
    var background: NSColor

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
