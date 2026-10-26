// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Observation

/// Automatic cleanup of data the app can regenerate: narration audio and PDF
/// Intelligent Reading (OCR) results. Documents, covers, notes, highlights and
/// bookmarks are never touched, and neither is the book being read or narrated.
///
/// Rules, from Settings › iCloud & Storage:
/// - a book not opened for `unusedDays` (default 30; 0 = never) loses its caches;
/// - a finished book loses them `finishedGraceDays` (7) after it was last opened;
/// - narration audio is capped at `audioCapBytes` (2 GB): beyond it, the caches of
///   the books opened longest ago go first;
/// - caches of books no longer in the library are removed.
@MainActor
@Observable
final class StorageJanitor {
    struct Policy: Equatable, Sendable {
        var unusedDays: Int = 30
        var deleteFinished = true
        var finishedGraceDays = 7
        var audioCapBytes: Int64 = 2_000_000_000
    }

    /// What the planner knows about one book's caches.
    struct Candidate: Equatable, Sendable {
        var id: UUID
        var lastOpened: Date?
        var finished: Bool
        var audioBytes: Int64
        var ocrBytes: Int64
    }

    struct Report: Equatable, Sendable {
        var books = 0
        var freedBytes: Int64 = 0
    }

    static let unusedDaysOptions = [7, 30, 90, 0]

    private enum Key {
        static let unusedDays = "nodus.storage.unusedDays"
        static let deleteFinished = "nodus.storage.deleteFinished"
    }

    private let library: LibraryService
    private let cache: NarrationAudioCache
    private let defaults: UserDefaults
    @ObservationIgnored private var running: Task<Report, Never>?

    var unusedDays: Int {
        didSet { defaults.set(unusedDays, forKey: Key.unusedDays) }
    }
    var deleteFinished: Bool {
        didSet { defaults.set(deleteFinished, forKey: Key.deleteFinished) }
    }

    var policy: Policy {
        Policy(unusedDays: unusedDays, deleteFinished: deleteFinished)
    }

    init(library: LibraryService, cache: NarrationAudioCache, defaults: UserDefaults = .standard) {
        self.library = library
        self.cache = cache
        self.defaults = defaults
        unusedDays = defaults.object(forKey: Key.unusedDays) as? Int ?? Policy().unusedDays
        deleteFinished = defaults.object(forKey: Key.deleteFinished) as? Bool ?? Policy().deleteFinished
    }

    /// The books whose caches go, in the order they are freed. Pure, so the
    /// rules are tested without files.
    nonisolated static func plan(_ candidates: [Candidate], policy: Policy,
                                 protected: Set<UUID>, now: Date = Date()) -> [UUID] {
        let day: TimeInterval = 24 * 60 * 60
        func idle(_ candidate: Candidate) -> TimeInterval {
            now.timeIntervalSince(candidate.lastOpened ?? .distantPast)
        }
        var chosen: [UUID] = []
        var remaining: [Candidate] = []
        for candidate in candidates where candidate.audioBytes + candidate.ocrBytes > 0 {
            if protected.contains(candidate.id) { continue }
            let unused = policy.unusedDays > 0 && idle(candidate) >= Double(policy.unusedDays) * day
            let finished = policy.deleteFinished && candidate.finished
                && idle(candidate) >= Double(policy.finishedGraceDays) * day
            if unused || finished {
                chosen.append(candidate.id)
            } else {
                remaining.append(candidate)
            }
        }
        // Over the audio cap: free the books opened longest ago first.
        var audio = remaining.reduce(0) { $0 + $1.audioBytes }
            + candidates.filter { protected.contains($0.id) }.reduce(0) { $0 + $1.audioBytes }
        for candidate in remaining.sorted(by: { idle($0) > idle($1) }) where audio > policy.audioCapBytes {
            guard candidate.audioBytes > 0 else { continue }
            chosen.append(candidate.id)
            audio -= candidate.audioBytes
        }
        return chosen
    }

    /// Runs the rules once (launch, background, Free Space Now). Concurrent
    /// requests share one run. `protected` is the book being narrated; the book
    /// opened last (the one in the reader) is always kept too.
    @discardableResult
    func run(protected: Set<UUID> = []) async -> Report {
        if let running { return await running.value }
        let books = library.allBooks()
        // The book open in the reader is the one opened last.
        var protected = protected
        if let last = books.filter({ $0.lastOpenedAt != nil })
            .max(by: { $0.lastOpenedSort < $1.lastOpenedSort }) {
            protected.insert(last.id)
        }
        let known = Set(books.map(\.id))
        let ocrRoot = library.fileStore.root.appendingPathComponent("Reflow", isDirectory: true)
        let info = books.map { (id: $0.id, lastOpened: $0.lastOpenedAt ?? $0.addedAt, finished: $0.status == .finished) }
        let policy = self.policy
        let cache = self.cache
        let task = Task<Report, Never>.detached(priority: .utility) {
            var report = Report()
            var candidates: [Candidate] = []
            for book in info {
                candidates.append(Candidate(
                    id: book.id, lastOpened: book.lastOpened, finished: book.finished,
                    audioBytes: await cache.bytes(for: book.id),
                    ocrBytes: FileStore.directorySize(ocrRoot.appendingPathComponent(book.id.uuidString),
                                                      fileManager: .default)
                ))
            }
            let byID = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0) })
            for id in Self.plan(candidates, policy: policy, protected: protected) {
                guard let candidate = byID[id] else { continue }
                await cache.deleteBook(bookID: id)
                try? FileManager.default.removeItem(at: ocrRoot.appendingPathComponent(id.uuidString))
                report.books += 1
                report.freedBytes += candidate.audioBytes + candidate.ocrBytes
            }
            // Caches left behind by books deleted on another device.
            for id in await cache.cachedBookIDs() where !known.contains(id) && !protected.contains(id) {
                report.freedBytes += await cache.bytes(for: id)
                await cache.deleteBook(bookID: id)
            }
            for id in Self.folderIDs(in: ocrRoot) where !known.contains(id) {
                let folder = ocrRoot.appendingPathComponent(id.uuidString)
                report.freedBytes += FileStore.directorySize(folder, fileManager: .default)
                try? FileManager.default.removeItem(at: folder)
            }
            return report
        }
        running = task
        let report = await task.value
        running = nil
        return report
    }

    /// Bytes of OCR results across the library.
    func ocrBytes() async -> Int64 {
        let root = library.fileStore.root.appendingPathComponent("Reflow", isDirectory: true)
        return await Task.detached(priority: .utility) {
            FileStore.directorySize(root, fileManager: .default)
        }.value
    }

    nonisolated static func folderIDs(in root: URL) -> [UUID] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return names.compactMap(UUID.init(uuidString:))
    }
}
