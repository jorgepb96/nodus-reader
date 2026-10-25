// SPDX-License-Identifier: AGPL-3.0-only
#if os(iOS)
import SwiftUI
import UIKit

/// Page-curl navigation over TextKit pages. The page controllers own selection,
/// word taps and the highlight overlay; this controller only turns pages.
final class ReaderPageCurlController: UIPageViewController, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
    private(set) var pages: [ReaderPage] = []
    private var style: ReaderPageStyle
    private var highlightsProvider: (ReaderPage) -> ReaderPageHighlights
    private var onWordTap: ((Int, Int) -> Void)?
    private var onHighlight: ((Int, NSRange, AnnotationColor) -> Void)?
    private var onNote: ((Int, NSRange) -> Void)?
    private var onPageChanged: ((Int) -> Void)?
    private var hosts: [Int: ReaderPageHostController] = [:]
    private var generation = UUID()
    private(set) var currentIndex = 0
    private var transitioning = false

    /// Reduce Motion replaces the page curl with a plain horizontal slide that
    /// follows the finger; programmatic page changes are never animated.
    init(style: ReaderPageStyle,
         reduceMotion: Bool,
         highlightsProvider: @escaping (ReaderPage) -> ReaderPageHighlights) {
        self.style = style
        self.highlightsProvider = highlightsProvider
        super.init(transitionStyle: reduceMotion ? .scroll : .pageCurl,
                   navigationOrientation: .horizontal,
                   options: reduceMotion
                       ? [.interPageSpacing: 0]
                       : [.spineLocation: UIPageViewController.SpineLocation.min.rawValue])
        dataSource = self
        delegate = self
        isDoubleSided = false
        view.backgroundColor = style.background
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        if let first = host(at: 0) {
            setViewControllers([first], direction: .forward, animated: false)
        }
    }

    func configure(pages: [ReaderPage],
                   style: ReaderPageStyle,
                   generation: UUID,
                   requestedIndex: Int,
                   highlightsProvider: @escaping (ReaderPage) -> ReaderPageHighlights,
                   onWordTap: @escaping (Int, Int) -> Void,
                   onHighlight: @escaping (Int, NSRange, AnnotationColor) -> Void,
                   onNote: @escaping (Int, NSRange) -> Void,
                   onPageChanged: @escaping (Int) -> Void) {
        let pagesChanged = generation != self.generation || pages.count != self.pages.count
        self.pages = pages
        self.style = style
        self.generation = generation
        self.highlightsProvider = highlightsProvider
        self.onWordTap = onWordTap
        self.onHighlight = onHighlight
        self.onNote = onNote
        self.onPageChanged = onPageChanged
        view.backgroundColor = style.background

        guard !pages.isEmpty else {
            setViewControllers([UIViewController()], direction: .forward, animated: false)
            return
        }

        let target = min(max(requestedIndex, 0), pages.count - 1)
        if pagesChanged {
            hosts.removeAll()
            self.currentIndex = target
            if let targetHost = host(at: target) {
                setViewControllers([targetHost], direction: .forward, animated: false)
            }
        } else if target != self.currentIndex, !transitioning {
            setPage(target, animated: false)
        } else {
            refreshHighlights()
        }
    }

    func setPage(_ index: Int, animated: Bool) {
        guard !pages.isEmpty else { return }
        let target = min(max(index, 0), pages.count - 1)
        guard target != currentIndex else {
            refreshHighlights()
            return
        }
        guard let targetHost = host(at: target) else { return }
        let direction: UIPageViewController.NavigationDirection = target > currentIndex ? .forward : .reverse
        currentIndex = target
        setViewControllers([targetHost], direction: direction, animated: animated)
        refreshHighlights()
    }

    func refreshHighlights() {
        for host in hosts.values {
            host.updateHighlights(highlightsProvider(host.page))
        }
    }

    private func host(at index: Int) -> ReaderPageHostController? {
        guard pages.indices.contains(index) else { return nil }
        if let existing = hosts[index] { return existing }
        let page = pages[index]
        let host = ReaderPageHostController(page: page, style: style,
                                            highlights: highlightsProvider(page))
        let chapter = page.chapterIndex
        host.onWordTap = { [weak self] offset in self?.onWordTap?(chapter, offset) }
        host.onHighlight = { [weak self] range, color in self?.onHighlight?(chapter, range, color) }
        host.onNote = { [weak self] range in self?.onNote?(chapter, range) }
        hosts[index] = host
        return host
    }

    // MARK: UIPageViewControllerDataSource

    func pageViewController(_ pageViewController: UIPageViewController,
                            viewControllerBefore viewController: UIViewController) -> UIViewController? {
        guard let pageHost = viewController as? ReaderPageHostController,
              let index = pages.firstIndex(where: { $0.id == pageHost.page.id }),
              index > 0 else { return nil }
        return host(at: index - 1)
    }

    func pageViewController(_ pageViewController: UIPageViewController,
                            viewControllerAfter viewController: UIViewController) -> UIViewController? {
        guard let pageHost = viewController as? ReaderPageHostController,
              let index = pages.firstIndex(where: { $0.id == pageHost.page.id }),
              index + 1 < pages.count else { return nil }
        return host(at: index + 1)
    }

    // MARK: UIPageViewControllerDelegate

    func pageViewController(_ pageViewController: UIPageViewController,
                            willTransitionTo pendingViewControllers: [UIViewController]) {
        transitioning = true
    }

    func pageViewController(_ pageViewController: UIPageViewController,
                            didFinishAnimating finished: Bool,
                            previousViewControllers: [UIViewController],
                            transitionCompleted completed: Bool) {
        transitioning = false
        guard completed,
              let host = pageViewController.viewControllers?.first as? ReaderPageHostController,
              let index = pages.firstIndex(where: { $0.id == host.page.id }) else { return }
        currentIndex = index
        refreshHighlights()
        onPageChanged?(index)
    }
}

struct PageCurlReader: UIViewControllerRepresentable {
    var pages: [ReaderPage]
    @Binding var pageIndex: Int
    var generation: UUID
    var style: ReaderPageStyle
    var highlightsProvider: (ReaderPage) -> ReaderPageHighlights
    var onWordTap: (Int, Int) -> Void
    var onHighlight: (Int, NSRange, AnnotationColor) -> Void
    var onNote: (Int, NSRange) -> Void
    var reduceMotion = false

    func makeUIViewController(context: Context) -> ReaderPageCurlController {
        ReaderPageCurlController(style: style, reduceMotion: reduceMotion,
                                 highlightsProvider: highlightsProvider)
    }

    func updateUIViewController(_ controller: ReaderPageCurlController, context: Context) {
        controller.configure(
            pages: pages,
            style: style,
            generation: generation,
            requestedIndex: pageIndex,
            highlightsProvider: highlightsProvider,
            onWordTap: onWordTap,
            onHighlight: onHighlight,
            onNote: onNote,
            onPageChanged: { index in
                if pageIndex != index {
                    DispatchQueue.main.async {
                        pageIndex = index
                    }
                }
            }
        )
    }
}
#endif
