// SPDX-License-Identifier: AGPL-3.0-only
#if os(iOS) && canImport(CarPlay)
import CarPlay
import Observation
import SwiftData
import UIKit

/// The services the CarPlay scene drives. The app creates them once at launch,
/// whether the phone or the car opened it, and attaches them here.
@MainActor
final class CarPlayServices {
    static let shared = CarPlayServices()

    private(set) weak var library: LibraryService?
    private(set) weak var playback: PlaybackController?
    private(set) weak var models: ModelManager?

    func attach(library: LibraryService, playback: PlaybackController, models: ModelManager) {
        self.library = library
        self.playback = playback
        self.models = models
    }
}

/// Nodus Reader in the car: narration only. The car lists recent books and the
/// whole library, plays a book from where it was left, and offers its chapters
/// and speed on the Now Playing screen. Book text is never shown.
@objc(NodusCarPlaySceneDelegate)
@MainActor
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate,
                                  CPInterfaceControllerDelegate, CPNowPlayingTemplateObserver {
    private var interfaceController: CPInterfaceController?
    private let recentTemplate = CPListTemplate(title: String(localized: "Recent"), sections: [])
    private let libraryTemplate = CPListTemplate(title: String(localized: "All Books"), sections: [])
    private var observers: [NSObjectProtocol] = []
    private var refreshTask: Task<Void, Never>?
    private var coverTask: Task<Void, Never>?
    /// Covers already drawn for the car, keyed by book and cover file.
    private var covers: [String: UIImage] = [:]
    private var connected = false

    private var services: CarPlayServices { .shared }

    // MARK: Scene

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didConnect interfaceController: CPInterfaceController) {
        self.interfaceController = interfaceController
        connected = true
        interfaceController.delegate = self

        recentTemplate.tabImage = UIImage(systemName: "clock")
        recentTemplate.emptyViewTitleVariants = [String(localized: "No books yet")]
        recentTemplate.emptyViewSubtitleVariants = [String(localized: "Import books on your iPhone to listen to them here.")]
        libraryTemplate.tabImage = UIImage(systemName: "books.vertical")
        libraryTemplate.emptyViewTitleVariants = recentTemplate.emptyViewTitleVariants
        libraryTemplate.emptyViewSubtitleVariants = recentTemplate.emptyViewSubtitleVariants
        let tabs = CPTabBarTemplate(templates: [recentTemplate, libraryTemplate])
        interfaceController.setRootTemplate(tabs, animated: false, completion: nil)

        configureNowPlaying()
        observeChanges()
        refresh()
        if services.playback?.hasActiveBook == true {
            interfaceController.pushTemplate(CPNowPlayingTemplate.shared, animated: false, completion: nil)
        }
        // The phone's library window loads the voice engine when it appears;
        // the car may have launched the app without it.
        if let models = services.models {
            Task { await models.loadInstalledEnginesIfNeeded() }
        }
    }

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didDisconnectInterfaceController interfaceController: CPInterfaceController) {
        connected = false
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        refreshTask?.cancel()
        coverTask?.cancel()
        CPNowPlayingTemplate.shared.remove(self)
        self.interfaceController = nil
    }

    // MARK: Library lists

    private func observeChanges() {
        let center = NotificationCenter.default
        for name in [ModelContext.didSave, .nodusLibraryBooksDeleted] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.scheduleRefresh() }
            })
        }
        observePlayback()
    }

    /// Marks the book playing in the lists as it starts, pauses or changes.
    private func observePlayback() {
        guard connected, let playback = services.playback else { return }
        withObservationTracking {
            _ = playback.activeBook?.id
            _ = playback.isPlaying
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.scheduleRefresh()
                self?.observePlayback()
            }
        }
    }

    private func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }

    private func refresh() {
        guard connected, let library = services.library else { return }
        let limit = CPListTemplate.maximumItemCount
        let recent = ([library.continueBook()].compactMap { $0 } + library.upNext(limit: limit))
        let all = library.books(sortedBy: .title)

        var items: [(item: CPListItem, book: CoverRequest)] = []
        func makeItems(_ books: some Sequence<Book>) -> [CPListItem] {
            books.prefix(limit).map { book in
                let item = listItem(for: book)
                items.append((item, CoverRequest(book: book)))
                return item
            }
        }
        recentTemplate.updateSections([CPListSection(items: makeItems(recent.prefix(12)))])
        libraryTemplate.updateSections([CPListSection(items: makeItems(all))])
        loadCovers(for: items)
    }

    private func listItem(for book: Book) -> CPListItem {
        let downloaded = book.downloadState == .downloaded
        let item = CPListItem(text: book.title,
                              detailText: downloaded ? book.displayAuthor : String(localized: "Not downloaded"),
                              image: covers[CoverRequest(book: book).key])
        item.playbackProgress = CGFloat(min(max(book.progress, 0), 1))
        item.isPlaying = services.playback?.activeBook?.id == book.id && services.playback?.isPlaying == true
        item.isEnabled = downloaded
        item.accessibilityLabel = "\(book.title), \(book.displayAuthor)"
        let bookID = book.id
        item.handler = { [weak self] _, completion in
            Task { @MainActor in
                await self?.play(bookID: bookID)
                completion()
            }
        }
        return item
    }

    // MARK: Covers

    private struct CoverRequest {
        let key: String
        let url: URL?
        let title: String
        let author: String

        @MainActor init(book: Book) {
            key = "\(book.id.uuidString)|\(book.coverFileName ?? "")"
            url = CarPlayServices.shared.library?.fileStore.coverURL(for: book.coverFileName)
            title = book.title
            author = book.displayAuthor
        }
    }

    /// The book's cover, or the typographic cover the library draws when it has
    /// none, scaled to the size the car shows.
    private func loadCovers(for items: [(item: CPListItem, book: CoverRequest)]) {
        coverTask?.cancel()
        let missing = items.filter { covers[$0.book.key] == nil }
        guard !missing.isEmpty else { return }
        let size = CPListItem.maximumImageSize
        let scale = interfaceController?.carTraitCollection.displayScale ?? 2
        let pixels = CGSize(width: size.width * scale, height: size.height * scale)
        coverTask = Task { @MainActor [weak self] in
            for (item, request) in missing {
                guard !Task.isCancelled, let self else { return }
                if let cached = self.covers[request.key] {
                    item.setImage(cached)
                    continue
                }
                var image: UIImage?
                if let url = request.url {
                    image = await Task.detached(priority: .utility) {
                        UIImage(contentsOfFile: url.path)?.preparingThumbnail(of: pixels)
                    }.value
                }
                if image == nil,
                   let data = CoverGenerator.typographicCover(title: request.title, author: request.author) {
                    image = UIImage(data: data)?.preparingThumbnail(of: pixels)
                }
                guard let image else { continue }
                self.covers[request.key] = image
                item.setImage(image)
                await Task.yield()
            }
        }
    }

    // MARK: Playing

    private func play(bookID: UUID) async {
        guard let library = services.library, let playback = services.playback,
              let book = library.allBooks().first(where: { $0.id == bookID }) else { return }
        if playback.activeBook?.id == bookID {
            if playback.mode == .read { playback.setMode(.listen) }
            // A finished book starts again, as Play does on the phone.
            if !playback.isPlaying { playback.resume() }
        } else {
            await playback.start(book: book, mode: .listen)
        }
        if let error = playback.errorMessage, !playback.isPlaying {
            showAlert(error)
            return
        }
        showNowPlaying()
    }

    private func showNowPlaying() {
        guard let interfaceController else { return }
        if interfaceController.topTemplate === CPNowPlayingTemplate.shared { return }
        if interfaceController.templates.contains(where: { $0 === CPNowPlayingTemplate.shared }) {
            interfaceController.pop(to: CPNowPlayingTemplate.shared, animated: true, completion: nil)
        } else {
            interfaceController.pushTemplate(CPNowPlayingTemplate.shared, animated: true, completion: nil)
        }
    }

    private func showAlert(_ message: String) {
        guard let interfaceController else { return }
        let alert = CPAlertTemplate(titleVariants: [message], actions: [
            CPAlertAction(title: String(localized: "OK"), style: .cancel) { [weak interfaceController] _ in
                interfaceController?.dismissTemplate(animated: true, completion: nil)
            }
        ])
        interfaceController.presentTemplate(alert, animated: true, completion: nil)
    }

    // MARK: Now Playing

    private func configureNowPlaying() {
        let nowPlaying = CPNowPlayingTemplate.shared
        nowPlaying.isUpNextButtonEnabled = true
        nowPlaying.upNextTitle = String(localized: "Chapters")
        nowPlaying.isAlbumArtistButtonEnabled = false
        nowPlaying.add(self)
        let speed = CPNowPlayingPlaybackRateButton { [weak self] _ in
            Task { @MainActor in self?.nextSpeed() }
        }
        nowPlaying.updateNowPlayingButtons([speed])
    }

    /// Steps through the reader's speeds, back to the slowest after the fastest.
    private func nextSpeed() {
        guard let playback = services.playback else { return }
        let options = PlaybackController.speedOptions
        let current = options.firstIndex(of: playback.speedMultiplier) ?? options.firstIndex(of: 1.0) ?? 0
        playback.setSpeed(options[(current + 1) % options.count])
    }

    nonisolated func nowPlayingTemplateUpNextButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {
        Task { @MainActor in self.showChapters() }
    }

    nonisolated func nowPlayingTemplateAlbumArtistButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {}

    private func showChapters() {
        guard let interfaceController, let playback = services.playback,
              let book = playback.activeBook, !playback.sentences.isEmpty else { return }
        let chapters = CarPlayChapters(chapters: playback.chapters, sentences: playback.sentences,
                                       currentChapter: playback.chapterIndex,
                                       limit: CPListTemplate.maximumItemCount)
        let items = chapters.entries.map { entry -> CPListItem in
            let item = CPListItem(text: entry.title, detailText: nil)
            item.isPlaying = entry.chapterIndex == playback.chapterIndex
            item.handler = { [weak self, weak playback] _, completion in
                Task { @MainActor in
                    if let playback, playback.activeBook?.id == book.id {
                        playback.seek(to: entry.firstSentence)
                        if !playback.isPlaying { playback.resume() }
                    }
                    self?.showNowPlaying()
                    completion()
                }
            }
            return item
        }
        let template = CPListTemplate(title: book.title, sections: [CPListSection(items: items)])
        interfaceController.pushTemplate(template, animated: true, completion: nil)
    }
}
#endif
