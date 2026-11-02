// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// Decides which windows to analyse, and runs the analysis in the
/// background: ahead of the reader (about half an hour of narration), never
/// the whole book at once, one request at a time, pausing while narration
/// synthesises a sentence, in Low Power Mode, when the device is hot or the
/// app is in the background, and cancelled when the book closes.
@MainActor
final class SceneAnalysisScheduler {
    /// Windows analysed ahead of the position (≈ 3,000 characters each,
    /// about 3 minutes of narration).
    static let horizon = 10
    /// Windows behind the position kept analysed (for small jumps back).
    static let behind = 2
    static let saveEvery = 4

    /// The order to analyse in: the current window, then forward to the
    /// horizon, then just behind. Already analysed windows are skipped.
    nonisolated static func queue(map: SceneMap, around index: Int, horizon: Int = horizon,
                                  behind: Int = behind) -> [Int] {
        guard !map.windows.isEmpty else { return [] }
        let last = map.windows.count - 1
        let current = min(max(index, 0), last)
        var order = Array(current...min(current + horizon, last))
        if current > 0 { order += (max(current - behind, 0)..<current).reversed() }
        return order.filter { map.status[$0] == nil }
    }

    /// Three samples of about 1,500 characters at a quarter, half and three
    /// quarters of the story, each starting at a paragraph.
    nonisolated static func profileSamples(_ story: StoryText) -> [String] {
        let span = story.storyEnd - story.storyStart
        guard span > 0 else { return [] }
        return [0.25, 0.5, 0.75].compactMap { fraction in
            var start = story.storyStart + Int(Double(span) * fraction)
            let newline = story.text.range(of: "\n", range: NSRange(location: start, length: min(800, story.storyEnd - start)))
            if newline.location != NSNotFound { start = NSMaxRange(newline) }
            let length = min(1_500, story.storyEnd - start)
            guard length > 200 else { return nil }
            return story.text.substring(with: NSRange(location: start, length: length))
        }
    }

    struct Context: Sendable {
        var bookID: UUID
        var story: StoryText
        var language: String
        var languageName: String
    }

    /// What the runner asks the app before each request.
    struct Conditions {
        var canRun: @MainActor () -> Bool
        var position: @MainActor () -> Int
    }

    private(set) var map: SceneMap?
    private var task: Task<Void, Never>?
    private let store: SceneMapStore
    private let analyse: (SceneWindow, SceneMap.Context) async throws -> WindowStatus
    private let vote: ([String]) async throws -> [DocumentKind]
    var onUpdate: ((SceneMap) -> Void)?
    var onLanguageUnsupported: (() -> Void)?

    /// `analyse` and `vote` run the model (or a stand-in in tests).
    init(store: SceneMapStore,
         analyse: @escaping (SceneWindow, SceneMap.Context) async throws -> WindowStatus,
         vote: @escaping ([String]) async throws -> [DocumentKind]) {
        self.store = store
        self.analyse = analyse
        self.vote = vote
    }

    var isRunning: Bool { task != nil }

    func start(map initial: SceneMap, context: Context, conditions: Conditions) {
        stop()
        map = initial
        task = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            await self?.run(context: context, conditions: conditions)
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        if let map, let id = currentBook { store.saveMap(map, bookID: id) }
        currentBook = nil
    }

    private var currentBook: UUID?

    private func run(context: Context, conditions: Conditions) async {
        currentBook = context.bookID
        guard var map else { return }
        if map.profile == nil {
            let samples = Self.profileSamples(context.story)
            let signals = TextSignals.measure(samples.joined(separator: "\n"))
            guard await wait(for: conditions) else { return }
            do {
                let votes = try await vote(samples)
                map.profile = DocumentProfile.resolve(votes: votes, signals: signals)
            } catch SceneAnalysisFailure.unsupportedLanguage {
                onLanguageUnsupported?()
                return
            } catch is CancellationError {
                return
            } catch {
                map.profile = DocumentProfile.resolve(votes: [], signals: signals)
            }
            publish(map, save: true, bookID: context.bookID)
        }
        // Essays, academic texts and manuals are never analysed scene by scene.
        guard map.profile?.kind.hasScenes != false else { return }
        var sinceSave = 0
        while !Task.isCancelled {
            let index = map.windowIndex(containing: conditions.position()) ?? 0
            guard let next = Self.queue(map: map, around: index).first else {
                // Everything near the reader is done; look again in a while.
                try? await Task.sleep(for: .seconds(10))
                continue
            }
            guard await wait(for: conditions) else { return }
            let window = map.windows[next]
            let mapContext = SceneMap.Context(passage: context.story.text.substring(with: NSRange(location: window.start, length: window.length)),
                                              before: Self.context(context.story.text, before: window.start),
                                              after: Self.context(context.story.text, after: window.end),
                                              language: context.languageName)
            do {
                let status = try await analyse(window, mapContext)
                guard !Task.isCancelled else { break }
                map.status[next] = status
                sinceSave += 1
                publish(map, save: sinceSave >= Self.saveEvery, bookID: context.bookID)
                if sinceSave >= Self.saveEvery { sinceSave = 0 }
            } catch SceneAnalysisFailure.unsupportedLanguage {
                onLanguageUnsupported?()
                break
            } catch SceneAnalysisFailure.temporarilyUnavailable {
                try? await Task.sleep(for: .seconds(30))
            } catch is CancellationError {
                break
            } catch {
                map.status[next] = .failed(String(describing: error))
                publish(map, save: false, bookID: context.bookID)
            }
        }
        store.saveMap(map, bookID: context.bookID)
    }

    private func publish(_ map: SceneMap, save: Bool, bookID: UUID) {
        self.map = map
        onUpdate?(map)
        if save { store.saveMap(map, bookID: bookID) }
    }

    /// Waits until analysis may run; false when cancelled.
    private func wait(for conditions: Conditions) async -> Bool {
        while !Task.isCancelled {
            if conditions.canRun() { return true }
            try? await Task.sleep(for: .seconds(2))
        }
        return false
    }

    nonisolated static func context(_ text: NSString, before offset: Int) -> String {
        let start = max(0, offset - 400)
        return text.substring(with: NSRange(location: start, length: offset - start))
    }

    nonisolated static func context(_ text: NSString, after offset: Int) -> String {
        let length = min(300, text.length - offset)
        return length > 0 ? text.substring(with: NSRange(location: offset, length: length)) : ""
    }
}

extension SceneMap {
    /// The text sent to the model for one window (on the device).
    struct Context: Sendable {
        var passage: String
        var before: String
        var after: String
        var language: String
    }
}
