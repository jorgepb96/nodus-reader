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
    private var backs: [Int: ReaderPageBackController] = [:]
    /// Page curl draws a real back for every page (the theme's paper); slide
    /// and vertical scroll have none.
    private let curlHasBacks: Bool
    private var generation = UUID()
    private(set) var currentIndex = 0
    private var transitioning = false

    /// Slide and Vertical use a plain scroll transition that follows the
    /// finger; Reduce Motion turns the curl into a slide. Programmatic page
    /// changes are never animated.
    init(style: ReaderPageStyle,
         turn: PageTurnStyle,
         highlightsProvider: @escaping (ReaderPage) -> ReaderPageHighlights) {
        self.style = style
        self.highlightsProvider = highlightsProvider
        self.curlHasBacks = turn == .curl
        super.init(transitionStyle: turn == .curl ? .pageCurl : .scroll,
                   navigationOrientation: turn == .vertical ? .vertical : .horizontal,
                   options: turn == .curl
                       ? [.spineLocation: UIPageViewController.SpineLocation.min.rawValue]
                       : [.interPageSpacing: 0])
        dataSource = self
        delegate = self
        isDoubleSided = curlHasBacks
        view.backgroundColor = style.background
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        if let first = host(at: 0) {
            setViewControllers(spread(first, index: 0), direction: .forward, animated: false)
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
            let blank = UIViewController()
            blank.view.backgroundColor = style.background
            setViewControllers([blank], direction: .forward, animated: false)
            return
        }

        let target = min(max(requestedIndex, 0), pages.count - 1)
        if pagesChanged {
            hosts.removeAll()
            backs.removeAll()
            self.currentIndex = target
            if let targetHost = host(at: target) {
                setViewControllers(spread(targetHost, index: target), direction: .forward, animated: false)
            }
        } else if transitioning {
            // A page is mid-curl: touching its views now re-captures it and
            // makes it shake. Highlights catch up when the turn ends.
            return
        } else if target != self.currentIndex {
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
        setViewControllers(spread(targetHost, index: target), direction: direction, animated: animated)
        trimHosts()
        refreshHighlights()
    }

    /// Each host keeps a TextKit stack; keep only the pages around the current
    /// one so a long reading session does not grow memory without bound.
    private func trimHosts() {
        let visible = Set((viewControllers ?? []).compactMap { ($0 as? ReaderPageHostController)?.page.id })
        hosts = hosts.filter { index, host in
            abs(index - currentIndex) <= 2 || visible.contains(host.page.id)
        }
        backs = backs.filter { index, _ in abs(index - currentIndex) <= 2 }
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

    /// The controllers shown at rest: just the page. With the spine at the
    /// edge, UIKit asks the data source for each back while it turns.
    private func spread(_ front: ReaderPageHostController, index: Int) -> [UIViewController] {
        [front]
    }

    private func back(at index: Int, front: ReaderPageHostController) -> ReaderPageBackController {
        if let existing = backs[index], existing.front === front { return existing }
        let back = ReaderPageBackController(front: front, style: style)
        backs[index] = back
        return back
    }

    private func index(of controller: UIViewController) -> Int? {
        let page: ReaderPage
        if let host = controller as? ReaderPageHostController {
            page = host.page
        } else if let back = controller as? ReaderPageBackController {
            page = back.front.page
        } else {
            return nil
        }
        return pages.firstIndex { $0.id == page.id }
    }

    // MARK: UIPageViewControllerDataSource

    // Double-sided order: page 0, back 0, page 1, back 1, …
    func pageViewController(_ pageViewController: UIPageViewController,
                            viewControllerBefore viewController: UIViewController) -> UIViewController? {
        guard let index = index(of: viewController) else { return nil }
        if curlHasBacks, viewController is ReaderPageBackController {
            return host(at: index)
        }
        guard index > 0, let previous = host(at: index - 1) else { return nil }
        return curlHasBacks ? back(at: index - 1, front: previous) : previous
    }

    func pageViewController(_ pageViewController: UIPageViewController,
                            viewControllerAfter viewController: UIViewController) -> UIViewController? {
        guard let index = index(of: viewController) else { return nil }
        if curlHasBacks, let front = viewController as? ReaderPageHostController {
            // The back exists only if there is a next page to turn to.
            return index + 1 < pages.count ? back(at: index, front: front) : nil
        }
        guard index + 1 < pages.count else { return nil }
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
              let host = pageViewController.viewControllers?.first(where: { $0 is ReaderPageHostController })
                  as? ReaderPageHostController,
              let index = pages.firstIndex(where: { $0.id == host.page.id }) else {
            refreshHighlights()
            return
        }
        currentIndex = index
        trimHosts()
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
    var turn: PageTurnStyle = .curl

    func makeUIViewController(context: Context) -> ReaderPageCurlController {
        ReaderPageCurlController(style: style, turn: turn,
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
