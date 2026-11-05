// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Observation

struct OfflineNarrationPlan: Codable, Identifiable, Sendable {
    struct Sentence: Codable, Sendable {
        let text: String
        let key: String
        let chapterIndex: Int
        let offset: Int
    }
    struct Unit: Codable, Identifiable, Sendable {
        let id: Int
        let title: String
        let start: Int
        let end: Int
        var indices: Range<Int> { start..<end }
    }
    let id: UUID
    let bookID: UUID
    let bookHash: String
    let title: String
    let voiceID: String
    let voiceName: String
    let engine: String
    let pronunciationRevision: String
    let createdAt: Date
    let sentences: [Sentence]
    let units: [Unit]

    var isValid: Bool {
        guard !sentences.isEmpty, !units.isEmpty, units.first?.start == 0, units.last?.end == sentences.count,
              sentences.allSatisfy({ !$0.text.isEmpty && $0.chapterIndex >= 0 && $0.offset >= 0 &&
                  $0.key.count == 64 && $0.key.allSatisfy(\.isHexDigit) }) else { return false }
        for (i, unit) in units.enumerated() {
            guard unit.id == i, unit.start >= 0, unit.end > unit.start, unit.end <= sentences.count,
                  i == 0 || units[i - 1].end == unit.start else { return false }
        }
        return true
    }

    /// Qwen cache-policy revisions also apply to persisted offline jobs. Recompute their keys
    /// before rendering, so the reader and the queue cannot disagree about where audio is saved.
    func needsQwenCacheMigration(cache: NarrationAudioCache) -> Bool {
        guard engine == "qwen", let first = sentences.first else { return false }
        let rules = (try? JSONDecoder().decode([PronunciationRule].self, from: Data(pronunciationRevision.utf8))) ?? []
        let prepared = PronunciationTransformer.prepare(first.text, rules: rules)
        return first.key != cache.key(text: first.text, engine: engine, voice: voiceID, pronunciation: prepared.signature)
    }

    func migratingQwenCache(cache: NarrationAudioCache) -> Self {
        let rules = (try? JSONDecoder().decode([PronunciationRule].self, from: Data(pronunciationRevision.utf8))) ?? []
        let updated = sentences.map { sentence in
            let prepared = PronunciationTransformer.prepare(sentence.text, rules: rules)
            return Sentence(text: sentence.text,
                            key: cache.key(text: sentence.text, engine: engine, voice: voiceID, pronunciation: prepared.signature),
                            chapterIndex: sentence.chapterIndex, offset: sentence.offset)
        }
        return Self(id: id, bookID: bookID, bookHash: bookHash, title: title, voiceID: voiceID,
                    voiceName: voiceName, engine: engine, pronunciationRevision: pronunciationRevision,
                    createdAt: createdAt, sentences: updated, units: units)
    }

    @MainActor
    static func make(book: Book, chapters: [ExtractedChapter], voice: VoiceCatalog.Voice,
                     paragraphsPerBlock: Int, cache: NarrationAudioCache) -> Self {
        let byChapter = chapters.count > 1 && book.format != .pdf
        var sentences: [Sentence] = [], units: [Unit] = []
        var unitStart = 0, paragraphCount = 0
        func finish(_ title: String) {
            guard sentences.count > unitStart else { return }
            units.append(Unit(id: units.count, title: title, start: unitStart, end: sentences.count))
            unitStart = sentences.count
        }
        for (chapterIndex, chapter) in chapters.enumerated() {
            let ns = chapter.text as NSString
            var paragraphEnds: [Int] = []
            ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: [.byParagraphs, .substringNotRequired]) { _, range, _, _ in
                if ns.substring(with: range).rangeOfCharacter(from: .alphanumerics) != nil { paragraphEnds.append(NSMaxRange(range)) }
            }
            var nextParagraph = 0
            for range in SentenceTokenizer.ranges(from: chapter.text) {
                let text = ns.substring(with: range)
                let prepared = PronunciationTransformer.prepare(text, rules: book.pronunciations)
                let key = cache.key(text: text, engine: voice.engineRaw, voice: voice.id, pronunciation: prepared.signature)
                sentences.append(Sentence(text: text, key: key, chapterIndex: chapterIndex, offset: range.location))
                while nextParagraph < paragraphEnds.count, paragraphEnds[nextParagraph] <= NSMaxRange(range) {
                    paragraphCount += 1; nextParagraph += 1
                }
                // A boundary is only emitted after an entire tokenizer sentence,
                // even if that sentence spans the nominal paragraph boundary.
                let last = text.last { !$0.isWhitespace && !"\"'”’»)]}」』）】〉》".contains($0) }
                let endsSentence = last.map { ".!?…。！？।॥؟".contains($0) } ?? false
                if !byChapter, paragraphCount >= max(1, paragraphsPerBlock), endsSentence {
                    finish(String(localized: "Part \(units.count + 1)")); paragraphCount = 0
                }
            }
            if byChapter { finish(chapter.title) }
        }
        finish(String(localized: "Part \(units.count + 1)"))
        return Self(id: UUID(), bookID: book.id, bookHash: book.contentHash, title: book.title,
                    voiceID: voice.id, voiceName: voice.name, engine: voice.engineRaw,
                    pronunciationRevision: book.pronunciationsJSON, createdAt: Date(), sentences: sentences, units: units)
    }
}

@MainActor
@Observable
final class OfflineNarrationQueue {
    enum Status: String, Codable { case queued, generating, waiting, paused, caughtUp, completed, failed }
    struct State: Codable {
        var status: Status = .queued
        var completed: Set<Int> = []
        var error: String?
        var lookAhead: Int?
        var readingSentence: Int = 0
    }
    struct Job: Identifiable {
        var plan: OfflineNarrationPlan
        var state: State
        var id: UUID { plan.id }
        var target: Range<Int> {
            guard let ahead = state.lookAhead, !plan.units.isEmpty else { return plan.sentences.indices }
            let unit = plan.units.lastIndex { $0.start <= state.readingSentence } ?? 0
            return plan.units[unit].start..<plan.units[min(plan.units.count - 1, unit + max(1, ahead) - 1)].end
        }
        var progress: Double { Double(target.filter(state.completed.contains).count) / Double(max(1, target.count)) }
        func isReady(_ unit: OfflineNarrationPlan.Unit) -> Bool { unit.indices.allSatisfy(state.completed.contains) }
    }
    private(set) var jobs: [Job] = []
    private(set) var errorMessage: String?
    @ObservationIgnored private let root: URL
    @ObservationIgnored private let cache: NarrationAudioCache
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var workerToken = UUID()
    @ObservationIgnored private var activeID: UUID?
    @ObservationIgnored private var preferredBookID: UUID?
    @ObservationIgnored private var interactiveBusy = false
    @ObservationIgnored private var editorClaims: Set<UUID> = []
    @ObservationIgnored private var pendingVerification: Set<UUID> = []
    @ObservationIgnored private var pendingCacheMigrations: Set<UUID> = []
    @ObservationIgnored private var available: (OfflineNarrationPlan) -> Bool = { _ in false }
    @ObservationIgnored private var idle: () -> Bool = { false }
    @ObservationIgnored private var validate: (OfflineNarrationPlan) throws -> Void = { _ in }
    @ObservationIgnored private var render: (OfflineNarrationPlan, OfflineNarrationPlan.Sentence) async throws -> Void = { _, _ in }

    init(root: URL, cache: NarrationAudioCache) {
        self.root = root; self.cache = cache
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var folder = root; var values = URLResourceValues(); values.isExcludedFromBackup = true
        try? folder.setResourceValues(values)
        for name in (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [] {
            guard let id = UUID(uuidString: name),
                  let data = try? Data(contentsOf: root.appendingPathComponent(name).appendingPathComponent("plan.json")),
                  let plan = try? JSONDecoder().decode(OfflineNarrationPlan.self, from: data), plan.id == id,
                  plan.isValid else { continue }
            let stateData = try? Data(contentsOf: root.appendingPathComponent(name).appendingPathComponent("state.json"))
            var state = stateData.flatMap { try? JSONDecoder().decode(State.self, from: $0) } ?? State()
            state.completed = state.completed.filter { plan.sentences.indices.contains($0) }
            if state.status == .generating { state.status = .queued }
            state.readingSentence = min(max(0, state.readingSentence), plan.sentences.count - 1)
            state.lookAhead = state.lookAhead.map { min(1000, max(1, $0)) }
            if plan.needsQwenCacheMigration(cache: cache) {
                pendingCacheMigrations.insert(id)
                state.completed.removeAll()
                if [.completed, .caughtUp].contains(state.status) { state.status = .queued }
            }
            jobs.append(Job(plan: plan, state: state))
            pendingVerification.insert(id)
        }
        jobs.sort { $0.plan.createdAt < $1.plan.createdAt }
    }

    func configure(available: @escaping (OfflineNarrationPlan) -> Bool, idle: @escaping () -> Bool,
                   validate: @escaping (OfflineNarrationPlan) throws -> Void = { _ in },
                   render: @escaping (OfflineNarrationPlan, OfflineNarrationPlan.Sentence) async throws -> Void) {
        self.available = available; self.idle = idle; self.validate = validate; self.render = render
        kick()
    }

    func enqueue(_ plan: OfflineNarrationPlan, lookAhead: Int? = nil) throws {
        guard plan.isValid else { throw QueueError.invalidPlan }
        if let existing = jobs.first(where: { $0.plan.bookID == plan.bookID && $0.plan.voiceID == plan.voiceID &&
            $0.plan.bookHash == plan.bookHash && $0.plan.pronunciationRevision == plan.pronunciationRevision &&
            $0.plan.units.map(\.end) == plan.units.map(\.end) && $0.plan.sentences.map(\.key) == plan.sentences.map(\.key) }) {
            setLookAhead(existing.id, count: lookAhead); resume(existing.id); return
        }
        let folder = directory(plan.id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONEncoder().encode(plan).write(to: folder.appendingPathComponent("plan.json"), options: .atomic)
        jobs.append(Job(plan: plan, state: State(lookAhead: lookAhead.map { min(1000, max(1, $0)) })))
        persist(plan.id); kick()
    }

    func setLookAhead(_ id: UUID, count: Int?) {
        guard let i = index(id) else { return }
        if activeID == id { interrupt() }
        jobs[i].state.lookAhead = count.map { min(1000, max(1, $0)) }
        if [.caughtUp, .completed].contains(jobs[i].state.status) { jobs[i].state.status = .queued }
        persist(id); kick()
    }

    func updateReadingPosition(bookID: UUID, chapterIndex: Int, fraction: Double, offset: Int? = nil) {
        preferredBookID = bookID
        for i in jobs.indices where jobs[i].plan.bookID == bookID && jobs[i].state.lookAhead != nil {
            let plan = jobs[i].plan
            let positions = plan.sentences.indices.filter { plan.sentences[$0].chapterIndex == chapterIndex }
            guard let first = positions.first, let last = positions.last else { continue }
            let length = plan.sentences[last].offset + (plan.sentences[last].text as NSString).length
            let character = offset ?? Int(Double(length) * min(1, max(0, fraction.isFinite ? fraction : 0)))
            let sentence = positions.last { plan.sentences[$0].offset <= character } ?? first
            guard sentence != jobs[i].state.readingSentence else { continue }
            let previousTarget = jobs[i].target
            jobs[i].state.readingSentence = sentence
            if jobs[i].target != previousTarget, [.caughtUp, .completed].contains(jobs[i].state.status) { jobs[i].state.status = .queued }
            persist(jobs[i].id)
        }
        kick()
    }

    func setInteractiveBusy(_ busy: Bool) {
        interactiveBusy = busy
        if busy { interrupt() } else { kick() }
    }

    func setEditor(_ id: UUID, active: Bool) {
        if active { editorClaims.insert(id); interrupt() }
        else { editorClaims.remove(id); kick() }
    }

    func resourcesDidChange() { kick() }

    func pause(_ id: UUID) {
        guard let index = index(id) else { return }
        jobs[index].state.status = .paused
        persist(id)
        if activeID == id { interrupt() }
        kick()
    }

    func resume(_ id: UUID) {
        guard let index = index(id) else { return }
        jobs[index].state.status = .queued; jobs[index].state.error = nil
        pendingVerification.insert(id)
        persist(id); kick()
    }

    /// Stops a book's pending jobs before deleting its cache or library entry.
    func cancel(bookID: UUID) -> Task<Void, Never>? {
        for i in jobs.indices where jobs[i].plan.bookID == bookID {
            jobs[i].state.status = .paused; persist(jobs[i].id)
        }
        return jobs.contains(where: { $0.id == activeID && $0.plan.bookID == bookID }) ? interrupt() : nil
    }

    func pauseAll() -> Task<Void, Never>? {
        for i in jobs.indices where jobs[i].state.status != .completed {
            jobs[i].state.status = .paused; persist(jobs[i].id)
        }
        return interrupt()
    }

    func resetProgress(bookID: UUID?) {
        for i in jobs.indices where bookID == nil || jobs[i].plan.bookID == bookID {
            jobs[i].state.completed = []; jobs[i].state.status = .paused
            persist(jobs[i].id)
        }
    }

    func remove(_ id: UUID, deletingAudio: Bool) async {
        guard let job = jobs.first(where: { $0.id == id }) else { return }
        let claim = UUID(); setEditor(claim, active: true)
        defer { setEditor(claim, active: false) }
        let pending = worker
        pause(id)
        await pending?.value
        if deletingAudio {
            await cache.delete(bookID: job.plan.bookID, keys: job.plan.sentences.map(\.key))
            // Another plan can refer to the same cache keys.
            let keys = Set(job.plan.sentences.map(\.key))
            for i in jobs.indices where jobs[i].id != id && jobs[i].plan.bookID == job.plan.bookID {
                jobs[i].state.completed = jobs[i].state.completed.filter { !keys.contains(jobs[i].plan.sentences[$0].key) }
                if jobs[i].plan.sentences.contains(where: { keys.contains($0.key) }) { jobs[i].state.status = .paused }
                persist(jobs[i].id)
            }
        }
        jobs.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: directory(id))
        kick()
    }

    func deleteAudio(_ id: UUID, unit: OfflineNarrationPlan.Unit) async {
        guard let job = jobs.first(where: { $0.id == id }) else { return }
        let claim = UUID(); setEditor(claim, active: true)
        defer { setEditor(claim, active: false) }
        let pending = worker
        pause(id)
        await pending?.value
        await cache.delete(bookID: job.plan.bookID, keys: unit.indices.map { job.plan.sentences[$0].key })
        let removed = Set(unit.indices.map { job.plan.sentences[$0].key })
        for i in jobs.indices where jobs[i].plan.bookID == job.plan.bookID {
            let before = jobs[i].state.completed
            jobs[i].state.completed = before.filter { !removed.contains(jobs[i].plan.sentences[$0].key) }
            if jobs[i].plan.sentences.contains(where: { removed.contains($0.key) }) { jobs[i].state.status = .paused }
            persist(jobs[i].id)
        }
    }

    private func index(_ id: UUID) -> Int? { jobs.firstIndex { $0.id == id } }
    private func nextJob() -> Int? {
        let candidates = jobs.indices.filter { [.queued, .waiting].contains(jobs[$0].state.status) && available(jobs[$0].plan) }
        return candidates.first { jobs[$0].plan.bookID == preferredBookID } ?? candidates.first
    }
    private func directory(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }

    private func persist(_ id: UUID) {
        guard let index = index(id) else { return }
        do {
            try JSONEncoder().encode(jobs[index].state).write(to: directory(id).appendingPathComponent("state.json"), options: .atomic)
        } catch {
            jobs[index].state.status = .failed
            jobs[index].state.error = error.localizedDescription
            errorMessage = error.localizedDescription
        }
    }

    @discardableResult
    private func interrupt() -> Task<Void, Never>? {
        let pending = worker
        worker?.cancel()
        if let id = activeID, let i = index(id), jobs[i].state.status == .generating {
            jobs[i].state.status = .waiting; persist(id)
        }
        return pending
    }

    private func kick() {
        for index in jobs.indices where ModelManager.Engine(rawValue: jobs[index].plan.engine)?.isEnabled == false {
            guard [.queued, .generating, .waiting].contains(jobs[index].state.status) else { continue }
            let reason = String(localized: "This voice engine is unavailable on this device. Choose another voice to generate new audio.")
            if jobs[index].state.status != .waiting || jobs[index].state.error != reason {
                jobs[index].state.status = .waiting
                jobs[index].state.error = reason
                persist(jobs[index].id)
            }
        }

        guard worker == nil, !interactiveBusy, editorClaims.isEmpty, idle() else { return }
        guard nextJob() != nil else { return }
        let token = UUID(); workerToken = token
        worker = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            defer {
                if self.workerToken == token {
                    self.worker = nil; self.activeID = nil
                    self.kick()
                }
            }
            while !Task.isCancelled, !self.interactiveBusy, self.editorClaims.isEmpty, self.idle(),
                  let i = self.nextJob() {
                let plan = self.jobs[i].plan
                if self.pendingCacheMigrations.contains(plan.id) {
                    // Large books can have many thousands of keys. Hashing and rewriting the plan
                    // must not monopolize the UI thread when changing voices or opening the player.
                    let cache = self.cache, destination = self.directory(plan.id).appendingPathComponent("plan.json")
                    do {
                        let updated = try await Task.detached(priority: .utility) {
                            let updated = plan.migratingQwenCache(cache: cache)
                            try JSONEncoder().encode(updated).write(to: destination, options: .atomic)
                            return updated
                        }.value
                        try Task.checkCancellation()
                        guard let index = self.index(plan.id) else { return }
                        self.jobs[index].plan = updated
                        self.pendingCacheMigrations.remove(plan.id)
                        self.persist(plan.id)
                    } catch {
                        if Task.isCancelled { return }
                        if let index = self.index(plan.id) {
                            self.jobs[index].state.status = .failed
                            self.jobs[index].state.error = error.localizedDescription
                            self.persist(plan.id)
                        }
                    }
                    continue
                }
                if self.pendingVerification.remove(plan.id) != nil {
                    let completed = self.jobs[i].state.completed
                    for sentence in completed {
                        if Task.isCancelled { return }
                        if !(await self.cache.contains(bookID: plan.bookID, key: plan.sentences[sentence].key)), let index = self.index(plan.id) {
                            self.jobs[index].state.completed.remove(sentence)
                        }
                    }
                    self.persist(plan.id)
                    continue
                }
                guard let sentenceIndex = self.jobs[i].target.first(where: { !self.jobs[i].state.completed.contains($0) }) else {
                    self.jobs[i].state.status = self.jobs[i].state.lookAhead == nil ? .completed : .caughtUp
                    self.persist(plan.id); continue
                }
                self.activeID = plan.id
                self.jobs[i].state.status = .generating; self.persist(plan.id)
                do {
                    try Task.checkCancellation()
                    try self.validate(plan)
                    let sentence = plan.sentences[sentenceIndex]
                    if !(await self.cache.contains(bookID: plan.bookID, key: sentence.key)) {
                        try await self.render(plan, sentence)
                    }
                    try Task.checkCancellation()
                    guard await self.cache.contains(bookID: plan.bookID, key: sentence.key) else {
                        throw QueueError.notSaved
                    }
                    guard let index = self.index(plan.id) else { return }
                    self.jobs[index].state.completed.insert(sentenceIndex)
                    self.jobs[index].state.status = .queued
                    self.persist(plan.id)
                } catch {
                    guard let index = self.index(plan.id) else { return }
                    if Task.isCancelled || error is CancellationError {
                        if self.jobs[index].state.status != .paused { self.jobs[index].state.status = .waiting }
                    } else {
                        self.jobs[index].state.status = .failed
                        self.jobs[index].state.error = error.localizedDescription
                    }
                    self.persist(plan.id)
                    if Task.isCancelled { return }
                }
            }
        }
    }

    enum QueueError: LocalizedError {
        case notSaved, bookChanged, invalidPlan
        var errorDescription: String? {
            switch self {
            case .notSaved: String(localized: "The generated audio could not be saved. Check available storage and resume.")
            case .bookChanged: String(localized: "The book or its pronunciation rules changed. Create a new audio job.")
            case .invalidPlan: String(localized: "This document has no readable sentences to prepare.")
            }
        }
    }
}
