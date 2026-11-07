// SPDX-License-Identifier: AGPL-3.0-only
import AVFoundation
import Foundation
import Observation
import StableAudioMLX
#if os(iOS)
import os
#endif
#if os(iOS)
import UIKit
#endif

/// Immersive Audio for the open book: music and ambience under silent
/// reading or narration. It wires the pieces together:
/// - where the reader is (the reader's page, or narration's sentence);
/// - the director (`AmbienceDirector`), which decides when the atmosphere changes;
/// - scene analysis (`SceneAnalysisScheduler`), in automatic mode only;
/// - the policy (`ImmersivePlaybackPolicy`), which decides when sound plays;
/// - the engine (`ImmersiveAudioEngine`) and the downloaded packs.
/// Narration is only observed: nothing here pauses, moves or restarts it.
@MainActor
@Observable
final class ImmersiveAudioController {
    enum Status: Equatable {
        case off
        /// On, but no reader is open.
        case waiting
        /// On, but no atmosphere sounds are downloaded yet.
        case needsPacks
        case playing
        case paused
        /// The audio engine could not start this session.
        case unavailable(String)
    }

    let preferences: ImmersiveAudioPreferences
    let library: ImmersiveAudioLibrary
    /// AI soundscapes: the models (per device) and the generated pieces (shared by books).
    let soundscapeModels: SoundscapeModels
    let generated: GeneratedLibrary
    /// What AI generation is doing.
    private(set) var generation: GenerationStatus = .idle
    @ObservationIgnored private let playback: PlaybackController
    @ObservationIgnored private let models: ModelManager
    @ObservationIgnored private let store: SceneMapStore

    private(set) var status: Status = .off
    private(set) var atmosphere: Atmosphere?
    private(set) var musicTrack: CatalogTrack?
    private(set) var ambienceTrack: CatalogTrack?
    private(set) var isLocked = false
    /// The reader chose the atmosphere for this book in automatic mode.
    private(set) var isChosenByReader = false
    private(set) var availability: ImmersiveAvailability = .unsupportedSystem
    private(set) var documentKind: DocumentKind?
    private(set) var analysedWindows = 0
    private(set) var totalWindows = 0
    /// The book's soundscape style (AI soundscapes): the reader's choice, the detected
    /// style, or neutral.
    private(set) var bookStyle: SoundscapeStyle = .neutral
    /// The reader chose `bookStyle` for this book.
    private(set) var isStyleChosen = false
    /// Why the atmosphere last changed or held (shown in the debug section).
    private(set) var lastReason = ""

    @ObservationIgnored private var engine: ImmersiveAudioEngine?
    @ObservationIgnored private var worker: GenerationWorker?
    @ObservationIgnored private let prompts = try? PromptLibrary.bundled()
    @ObservationIgnored private var isPreparingPack = false
    /// Why the next piece is not being composed yet ("narration", "memory"…), shown
    /// beside the pack's progress; nil while a piece is composed.
    private(set) var generationWaiting: String?
    /// Priority of a piece asked for because the reader (or the director) wants it now.
    static let immediatePriority = GenerationWorker.immediatePriority
    /// Below this headroom a memory warning stops the piece in progress.
    static let memoryWarningHeadroom: Int64 = 400_000_000
    @ObservationIgnored private var packTotal = 0
    @ObservationIgnored private var packDone = 0
    @ObservationIgnored private var lastPlan = Date.distantPast
    @ObservationIgnored private var director = AmbienceDirector()
    @ObservationIgnored private var tracker = PositionTracker()
    @ObservationIgnored private var clock = EngagedClock()
    @ObservationIgnored private var policy = ImmersivePlaybackPolicy()
    @ObservationIgnored private var history = PlayHistory()
    @ObservationIgnored private var scheduler: SceneAnalysisScheduler?
    @ObservationIgnored private(set) var bookID: UUID?
    @ObservationIgnored private var openReader: (book: Book, chapters: [ExtractedChapter]?)?
    @ObservationIgnored private var openReaderChapter = 0
    @ObservationIgnored private var openReaderOffset = 0
    @ObservationIgnored private var book: Book?
    @ObservationIgnored private var story: StoryText?
    @ObservationIgnored private var map: SceneMap?
    @ObservationIgnored private var bookPreferences = ImmersiveBookPreferences()
    @ObservationIgnored private var readerChapter = 0
    @ObservationIgnored private var readerOffset = 0
    @ObservationIgnored private var lastActivity = Date()
    @ObservationIgnored private var tickTask: Task<Void, Never>?
    @ObservationIgnored private var releaseTask: Task<Void, Never>?
    @ObservationIgnored private var shutdownTask: Task<Void, Never>?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var appActive = true
    /// False from the moment the app stops being active (app switcher, Settings,
    /// Control Center): iOS refuses GPU work in the background, so composing stops
    /// before the app gets there.
    @ObservationIgnored private var sceneActive = true
    /// A composed piece of another mood (or ambience) plays until the wanted one is
    /// ready; only that piece, or the reader's own choice, replaces it.
    @ObservationIgnored private var musicStandIn = false
    @ObservationIgnored private var ambienceStandIn = false
    /// The reader is choosing: never keep a stand-in under their choice's name.
    @ObservationIgnored private var choosing = false
    @ObservationIgnored private var lastNarrationPlaying = false
    @ObservationIgnored private var narrationHadBook = false
    @ObservationIgnored private var engineFailed = false

    static let idleLimit: TimeInterval = 15 * 60
    static let tickInterval: TimeInterval = 15

    init(preferences: ImmersiveAudioPreferences, library: ImmersiveAudioLibrary, playback: PlaybackController,
         models: ModelManager, store: SceneMapStore = SceneMapStore(),
         soundscapeModels: SoundscapeModels? = nil, generated: GeneratedLibrary? = nil) {
        self.preferences = preferences
        self.library = library
        let soundscapes = library.root.deletingLastPathComponent().appendingPathComponent("Soundscapes", isDirectory: true)
        #if DEBUG
        // UI tests share one simulator: each fixture run starts with nothing composed.
        if ProcessInfo.processInfo.arguments.contains("-NodusResetReadingState") {
            try? FileManager.default.removeItem(at: soundscapes.appendingPathComponent("Generated", isDirectory: true))
        }
        #endif
        self.soundscapeModels = soundscapeModels ?? SoundscapeModels(root: soundscapes.appendingPathComponent("Models", isDirectory: true))
        self.generated = generated ?? GeneratedLibrary(root: soundscapes.appendingPathComponent("Generated", isDirectory: true))
        self.generated.budgetBytes = Int64(preferences.generatedBudgetMB) * 1_000_000
        self.playback = playback
        self.models = models
        self.store = store
        policy.pausePolicy = preferences.pausePolicy
        policy.enabled = preferences.isEnabled
        refreshAvailability(language: nil)
        updateStatus()
        observePlayback()
        observePreferences()
        observeSystem()
        library.onInstalledChanged = { [weak self] in self?.libraryChanged() }
        self.soundscapeModels.onChange = { [weak self] in self?.libraryChanged() }
        self.generated.onChange = { [weak self] in self?.soundsChanged() }
        self.library.onChange = { [weak self] in self?.soundsChanged() }
    }

    // MARK: Reader

    /// A book opened in the reader. `chapters` are the reader's chapters
    /// (nil for a PDF: its text is loaded only if automatic mode needs it).
    func readerOpened(book: Book, chapters: [ExtractedChapter]?) {
        if openReader?.book.id != book.id {
            openReaderChapter = 0
            openReaderOffset = 0
        }
        openReader = (book, chapters)
        playbackChanged()
        lastActivity = Date()
        updateStatus()
        // New sounds are looked for only while the feature is in use (at
        // most once a day): the reader sees them in Settings › Sound packs.
        if preferences.isEnabled, library.hasAnything {
            Task { [library] in await library.checkForNewSounds() }
        }
    }

    /// The page on screen moved. A different book being browsed must not
    /// move or wake the atmosphere belonging to the narration session.
    func readerPosition(book: Book, chapter: Int, offset: Int) {
        guard openReader?.book.id == book.id else { return }
        openReaderChapter = chapter
        openReaderOffset = offset
        guard bookID == book.id else { return }
        readerChapter = chapter
        readerOffset = offset
        lastActivity = Date()
        apply(policy.handle(.readerActivity))
        if !narrationDrivesPosition { step(reason: "page") }
    }

    func readerClosed(book: Book) {
        if openReader?.book.id == book.id { openReader = nil }
        synchronizeBook()
        guard book.id == bookID else { return }
        if policy.readerOpen { apply(policy.handle(.readerClosed)) }
        if !narrationDrivesPosition {
            scheduler?.stop()
            if !isPreparingPack { cancelGeneration() }
        }
        // Keep the engine a little in case the reader comes straight back.
        shutdownTask?.cancel()
        shutdownTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(300))
            guard let self, !Task.isCancelled, !self.policy.shouldPlay else { return }
            self.shutdownEngine()
        }
        updateStatus()
    }

    /// Narration (including its loading/paused session) owns the soundtrack.
    /// Browsing another reader only becomes audible after that session closes,
    /// or when the user explicitly starts narrating the other book.
    private func synchronizeBook() {
        let narrationBook = playback.mode != .read ? playback.activeBook : nil
        let target = narrationBook ?? openReader?.book ?? sessionBook
        guard let target else {
            if policy.readerOpen { apply(policy.handle(.readerClosed)) }
            return
        }
        shutdownTask?.cancel()
        if bookID != target.id {
            resetSession()
            bookID = target.id
            book = target
            lastNarrationPlaying = false
            narrationHadBook = narrationBook != nil
            policy.narration = narrationBook != nil && !playback.isPlaying ? .paused : .none
            policy.readerOpen = false
            policy.finished = false
            bookPreferences = store.loadPreferences(bookID: target.id) ?? ImmersiveBookPreferences()
            refreshBookStyle()
            isLocked = bookPreferences.locked
            isChosenByReader = bookPreferences.atmosphere != nil && !isLocked
            refreshAvailability(language: target.language)
            let isOpen = openReader?.book.id == target.id
            readerChapter = isOpen ? openReaderChapter : 0
            readerOffset = isOpen ? openReaderOffset : 0
            prepareText(book: target, chapters: isOpen ? openReader?.chapters : nil)
        }
        let isOpen = openReader?.book.id == target.id
        if policy.readerOpen != isOpen {
            apply(policy.handle(isOpen ? .readerOpened : .readerClosed))
        }
    }

    private func resetSession() {
        cancelGeneration()
        scheduler?.stop()
        scheduler = nil
        director = AmbienceDirector()
        tracker = PositionTracker()
        clock = EngagedClock()
        story = nil
        map = nil
        documentKind = nil
        analysedWindows = 0
        totalWindows = 0
        atmosphere = nil
        musicTrack = nil
        ambienceTrack = nil
        // Crossfades are for tracks within one book. Switching books must
        // stop both old layers before scheduling the new book's soundtrack.
        engine?.stop(.music, fadeOut: 0)
        engine?.stop(.ambience, fadeOut: 0)
    }

    private func prepareText(book: Book, chapters: [ExtractedChapter]?) {
        let id = book.id
        Task { [weak self] in
            var chapters = chapters
            if chapters == nil, self?.preferences.mode == .automatic {
                chapters = try? await BookTextLoader.loadChapters(for: book)
            }
            guard let chapters, !chapters.isEmpty, let self, self.bookID == id else { return }
            let texts = chapters.map(\.text)
            let titles = chapters.map(\.title)
            let contentHash = book.contentHash
            let prepared = await Task.detached(priority: .utility) { () -> (StoryText, [SceneWindow], String) in
                let story = StoryText(chapters: texts, titles: titles)
                return (story, SceneSegmenter.windows(in: story), ImmersiveContentKey.make(contentHash: contentHash, text: story.text))
            }.value
            guard self.bookID == id else { return }
            let (story, windows, key) = prepared
            self.story = story
            let language = Self.languageCode(book.language)
            let saved = self.store.loadMap(bookID: id)
                ?? SceneMap(contentKey: key, language: language, windows: windows)
            self.map = saved.adapted(contentKey: key, language: language, windows: windows)
            self.publish(map: self.map)
            self.startAnalysisIfNeeded()
            self.step(reason: "text")
        }
    }

    // MARK: Analysis

    private func startAnalysisIfNeeded() {
        guard preferences.mode == .automatic, availability.allowsAutomatic, scheduler?.isRunning != true,
              let map, let story, let book else { return }
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, macOS 26.0, *) else { return }
        let analyzer = SceneAnalyzer()
        let languageName = Self.languageName(book.language)
        let scheduler = SceneAnalysisScheduler(
            store: store,
            analyse: { _, context in
                try await analyzer.analyse(passage: context.passage, before: context.before,
                                           after: context.after, language: context.language)
            },
            vote: { samples in
                try await analyzer.documentVotes(samples: samples, language: languageName)
            })
        scheduler.onUpdate = { [weak self] map in
            self?.publish(map: map)
        }
        scheduler.onLanguageUnsupported = { [weak self] in
            self?.availability = .languageUnsupported
        }
        let context = SceneAnalysisScheduler.Context(bookID: book.id, story: story,
                                                     language: Self.languageCode(book.language),
                                                     languageName: Self.languageName(book.language))
        scheduler.start(map: map, context: context, conditions: .init(
            canRun: { [weak self] in self?.analysisMayRun ?? false },
            position: { [weak self] in self?.storyPosition ?? 0 }))
        self.scheduler = scheduler
        #endif
    }

    // MARK: AI soundscapes

    private var aiSource: Bool { preferences.source == .ai }

    /// Something can play: downloaded packs, or (AI) generated pieces or models to make them.
    var hasSounds: Bool {
        aiSource ? (generated.hasAnything || soundscapeModels.anyInstalled || library.hasAnything) : library.hasAnything
    }

    /// Moods the director may choose: with AI and the Music model, every mood can be made.
    var availableMoods: Set<MusicMood> {
        guard aiSource else { return library.installedMoods }
        return soundscapeModels.isInstalled(.music) || Self.usesFixtureGenerator ? Set(MusicMood.allCases)
            : generated.installedMoods.union(library.installedMoods)
    }

    var availableBeds: Set<BaseAmbience> {
        guard aiSource else { return library.installedBeds }
        return soundscapeModels.isInstalled(.sfx) || Self.usesFixtureGenerator ? Set(BaseAmbience.allCases)
            : generated.installedBeds.union(library.installedBeds)
    }

    private func url(for track: CatalogTrack) -> URL? {
        track.semantics.origin == "generated" ? generated.url(for: track) : library.url(for: track)
    }

    /// The generated piece playing now (music first), for the favorite button.
    var currentGeneratedPiece: GeneratedPiece? {
        [musicTrack, ambienceTrack].compactMap { $0 }.first { $0.semantics.origin == "generated" }
            .flatMap { generated.piece($0.id) }
    }

    func toggleFavoriteCurrent() {
        guard let piece = currentGeneratedPiece else { return }
        generated.setFavorite(piece.id, !piece.favorite)
    }

    /// Whether this book can be prepared now (AI source, a model installed, a book).
    var canPrepareSoundscapes: Bool {
        aiSource && soundscapeModels.anyInstalled && bookID != nil && prompts != nil && SoundscapeModels.isSupported
            || (aiSource && bookID != nil && Self.usesFixtureGenerator)
    }

    /// Books offered a session's music in this run of the app (once each).
    @ObservationIgnored private var sessionOffered: Set<UUID> = []

    /// The book about to be listened to while its session's music is composed (the
    /// narration has not started yet, and the reader may not be open).
    @ObservationIgnored private var sessionBook: Book?

    /// Whether starting to listen to `book` should first offer to compose the session's
    /// music: AI source with a model, the question not turned off, and not asked for
    /// this book yet in this run of the app.
    func offersSession(for book: Book) -> Bool {
        guard preferences.isEnabled, preferences.askBeforeSession, aiSource, prompts != nil,
              asksSession(for: book), !sessionOffered.contains(book.id) else { return false }
        // Another book's pack may still be composing (Start now): this book asks anyway.
        if isPreparingPack, book.id == bookID { return false }
        return (soundscapeModels.anyInstalled && SoundscapeModels.isSupported) || Self.usesFixtureGenerator
    }

    /// The per-book choice (Don't ask for this book), on by default.
    func asksSession(for book: Book) -> Bool {
        _ = asksSessionRevision // observed, so switches follow a change
        let stored = book.id == bookID ? Optional(bookPreferences) : store.loadPreferences(bookID: book.id)
        return stored?.skipsSessionOffer != true
    }

    func setAsksSession(_ ask: Bool, for book: Book) {
        var stored = (book.id == bookID ? Optional(bookPreferences) : store.loadPreferences(bookID: book.id))
            ?? ImmersiveBookPreferences()
        stored.skipsSessionOffer = ask ? nil : true
        if book.id == bookID { bookPreferences = stored }
        store.savePreferences(stored, bookID: book.id)
        asksSessionRevision += 1
    }

    /// For the atmosphere panel's switch: the book open now.
    var asksSessionForCurrentBook: Bool {
        get { book.map(asksSession(for:)) ?? true }
        set { if let book { setAsksSession(newValue, for: book) } }
    }
    private var asksSessionRevision = 0

    func markSessionOffered(_ book: Book) {
        sessionOffered.insert(book.id)
    }

    /// The reader is scrolling or turning pages: composing yields the GPU for a moment.
    func readerInteracted() {
        guard aiSource, worker != nil else { return }
        SA3Engine.yield.hold(for: 4)
    }

    /// Composes `count` pieces for the session about to start (the scene's music first,
    /// then other moods and an ambience), quick recipes, with visible progress; the voice
    /// waits for them. Later pieces are composed ahead as the story needs them.
    func prepareSession(for book: Book, count: Int) {
        markSessionOffered(book)
        sessionBook = book
        synchronizeBook()
        guard canPrepareSoundscapes, let prompts, let worker = ensureWorker() else { return }
        let music = soundscapeModels.isInstalled(.music) || Self.usesFixtureGenerator
        let ambience = (soundscapeModels.isInstalled(.sfx) || Self.usesFixtureGenerator) && preferences.ambienceEnabled
        let current = director.current ?? preferences.defaultAtmosphere
        var moods = [current.music ?? .calm]
        for mood in SoundscapePlanner.defaultMoods(bookStyle) where !moods.contains(mood) { moods.append(mood) }
        var beds: [BaseAmbience] = current.base != .none ? [current.base] : []
        for bed in SoundscapePlanner.defaultBeds(bookStyle) where !beds.contains(bed) { beds.append(bed) }
        let bedCount = ambience ? (count >= 6 ? 2 : count >= 3 ? 1 : 0) : 0
        let musicCount = music ? max(0, count - bedCount) : 0
        let seed = UInt64.random(in: 1 ... UInt64.max / 2)
        var jobs: [GenerationJob] = []
        for (index, mood) in moods.prefix(musicCount).enumerated() {
            if var job = SoundscapePlanner.job(layer: .music, mood: mood, bed: nil, style: bookStyle, bookID: bookID,
                                               library: prompts, seed: seed &+ UInt64(index), priority: 20,
                                               studyOnly: preferences.mode == .study) {
                // The first piece is short, so the voice waits as little as possible.
                if index == 0 { job.recipe = .quickMusic }
                jobs.append(job)
            }
        }
        for (index, bed) in beds.prefix(musicCount == 0 ? count : bedCount).enumerated() where ambience {
            if let job = SoundscapePlanner.job(layer: .ambience, mood: nil, bed: bed, style: bookStyle, bookID: bookID,
                                               library: prompts, seed: seed &+ 100 &+ UInt64(index), priority: 20,
                                               studyOnly: preferences.mode == .study) { jobs.append(job) }
        }
        guard !jobs.isEmpty else { return }
        isPreparingPack = true
        packTotal = jobs.count
        packDone = 0
        generation = .preparing(done: 0, total: jobs.count)
        // This session replaces whatever was queued, another book's pack included.
        Task { await worker.replace(with: jobs) }
    }

    /// The session sheet is on screen: compile the composer's kernels while the reader
    /// decides, so the first piece starts sooner.
    func prewarmSoundscapes() {
        guard aiSource, soundscapeModels.anyInstalled || Self.usesFixtureGenerator, let worker = ensureWorker() else { return }
        Task { await worker.warmUp() }
    }

    /// The session's music is ready or the reader started without it.
    func sessionStarted() {
        sessionBook = nil
    }

    /// The optional per-book pack, generated now with visible progress.
    func prepareSoundscapes() {
        guard canPrepareSoundscapes, let prompts, let worker = ensureWorker() else { return }
        let music = soundscapeModels.isInstalled(.music) || Self.usesFixtureGenerator
        let ambience = soundscapeModels.isInstalled(.sfx) || Self.usesFixtureGenerator
        let length = map?.windows.last?.end
            ?? (playback.activeBook?.id == bookID ? playback.chapters.reduce(0) { $0 + ($1.text as NSString).length } : nil)
        let jobs = SoundscapePlanner.starterPack(style: bookStyle, map: map, bookID: bookID, library: prompts,
                                                 seed: UInt64.random(in: 1 ... UInt64.max / 2),
                                                 studyOnly: preferences.mode == .study, textLength: length)
            .filter { $0.request.layer == .music ? music : ambience }
            .map { job -> GenerationJob in var job = job; job.priority += 10; return job }
        guard !jobs.isEmpty else { return }
        isPreparingPack = true
        packTotal = jobs.count
        packDone = 0
        generation = .preparing(done: 0, total: jobs.count)
        Task { await worker.replace(with: jobs) }
    }

    func cancelPreparation() {
        cancelGeneration()
    }

    /// Lifts a pause after repeated failures.
    func resumeGeneration() {
        guard let worker else { return }
        generation = .idle
        Task { await worker.resume() }
        planSoundscapes(force: true)
    }

    /// Stops the piece in progress without dropping what is planned.
    private func interruptGeneration(retryAfter: Double, shorter: Bool) {
        guard let worker else { return }
        Task { await worker.interrupt(retryAfter: retryAfter, shorter: shorter) }
    }

    private func cancelGeneration(keepingPack: Bool = false) {
        if let worker { Task { await worker.cancelAll() } }
        if isPreparingPack, !keepingPack {
            isPreparingPack = false
        }
        if !isPreparingPack, case .paused = generation {} else if !isPreparingPack { generation = .idle }
    }

    /// Plans what to generate ahead while a book's soundscape plays (at most every 15 s
    /// unless forced). The director is untouched: this only prepares what it may choose.
    private func planSoundscapes(force: Bool) {
        guard aiSource, preferences.isEnabled, policy.shouldPlay, bookID != nil, !isPreparingPack, appActive,
              let prompts else { return }
        if case .paused = generation { return }
        detectBookStyleIfNeeded()
        let music = (soundscapeModels.isInstalled(.music) || Self.usesFixtureGenerator) && preferences.musicEnabled
        let ambience = (soundscapeModels.isInstalled(.sfx) || Self.usesFixtureGenerator) && preferences.ambienceEnabled
        guard music || ambience else { return }
        guard force || Date().timeIntervalSince(lastPlan) >= 15 else { return }
        lastPlan = Date()
        guard let worker = ensureWorker() else { return }
        let generated = generated
        let used = Set(generated.pieces.filter { piece in bookID.map(piece.bookIDs.contains) ?? false }.map(\.promptID))
        let input = PlannerInput(map: map, position: storyPosition, current: director.current, style: bookStyle,
                                 intensity: preferences.intensity, inventory: { generated.usableCount(for: $0) },
                                 used: used, studyOnly: preferences.mode == .study, bookID: bookID,
                                 musicEnabled: music, ambienceEnabled: ambience)
        let jobs = SoundscapePlanner.plan(input, library: prompts, seed: UInt64.random(in: 1 ... UInt64.max / 2))
        Task { await worker.replace(with: jobs) }
    }

    static var usesFixtureGenerator: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-NodusSoundscapeFixtureGenerator")
        #else
        false
        #endif
    }

    private func ensureWorker() -> GenerationWorker? {
        if let worker { return worker }
        let generator: SoundscapeGenerating
        if Self.usesFixtureGenerator {
            generator = FixtureGenerator(delay: 1)
        } else {
            guard SoundscapeModels.isSupported else { return nil }
            generator = SA3Generator(directory: soundscapeModels.directory)
        }
        let worker = GenerationWorker(
            generator: generator, library: generated,
            admission: { [weak self] in
                await self?.admissionState() ?? AdmissionState(thermal: .nominal, lowPower: false, foreground: false,
                                                               narrationWaiting: false, analysisRunning: false,
                                                               availableMemory: nil)
            },
            pacing: Self.usesFixtureGenerator ? 0.05 : 1,
            onEvent: { [weak self] event in Task { @MainActor in self?.handle(event) } })
        self.worker = worker
        return worker
    }

    private func admissionState() async -> AdmissionState {
        let analysing = await OnDeviceModelGate.shared.isBusy
        var memory: Int64?
        #if os(iOS)
        // The Simulator (and some unlimited hosts) report 0: unknown, not "no memory".
        let available = Int64(os_proc_available_memory())
        memory = available > 0 ? available : nil
        #endif
        let info = ProcessInfo.processInfo
        return AdmissionState(thermal: info.thermalState, lowPower: info.isLowPowerModeEnabled,
                              foreground: appActive && sceneActive,
                              narrationWaiting: playback.isPlaying && playback.isLoading, analysisRunning: analysing,
                              availableMemory: memory)
    }

    private func handle(_ event: WorkerEvent) {
        switch event {
        case .started(let job):
            generationWaiting = nil
            if isPreparingPack, job.priority < Self.immediatePriority {
                generation = .preparing(done: packDone, total: packTotal)
            } else {
                generation = .composing(job.request.mood?.label ?? job.request.bed?.label ?? "")
            }
        case .finished(let piece, let job):
            generationWaiting = nil
            generated.evict(activeMoods: Set([director.current?.music].compactMap { $0 }),
                            activeBeds: Set([director.current?.base].compactMap { $0 }))
            if job.priority < Self.immediatePriority {
                packProgressed()
            } else {
                generation = isPreparingPack ? .preparing(done: packDone, total: packTotal) : .idle
            }
            // A piece for what the director wants but could not play yet starts now.
            if let mood = piece.mood, mood == director.current?.music,
               musicTrack?.semantics.origin != "generated" || musicTrack?.moods.contains(mood) != true {
                startMusic(mood, crossfade: preferences.crossfade, avoidSubPool: nil)
            } else if piece.layer == .music, musicTrack == nil, director.current?.music != nil {
                // Music is wanted and nothing plays: the first piece ready stands in
                // until one for the scene's own mood is composed (it is asked for first).
                playStandIn(piece)
            }
            if let bed = piece.bed, bed == director.current?.base,
               ambienceTrack?.semantics.origin != "generated" || ambienceTrack?.bed != bed {
                startAmbience(bed, crossfade: preferences.crossfade)
            } else if piece.layer == .ambience, ambienceTrack == nil, director.current?.base ?? .none != .none {
                playStandIn(piece)
            }
            planSoundscapes(force: true)
        case .rejected(let job, _), .failed(let job, _):
            generationWaiting = nil
            if job.priority < Self.immediatePriority {
                packProgressed()
            } else {
                generation = isPreparingPack ? .preparing(done: packDone, total: packTotal) : .idle
            }
        case .waiting(let reason):
            generationWaiting = reason
        case .paused(let reason):
            isPreparingPack = false
            generation = .paused(reason)
        }
        updateStatus()
    }

    private func packProgressed() {
        guard isPreparingPack else {
            generation = .idle
            return
        }
        packDone += 1
        if packDone >= packTotal {
            isPreparingPack = false
            generation = .idle
            planSoundscapes(force: true)
        } else {
            generation = .preparing(done: packDone, total: packTotal)
        }
    }

    // MARK: Style

    /// Sets this book's style; nil returns to the detected one.
    func setBookStyle(_ style: SoundscapeStyle?) {
        bookPreferences.styleOverride = style
        if let bookID { store.savePreferences(bookPreferences, bookID: bookID) }
        refreshBookStyle()
        planSoundscapes(force: true)
    }

    private func refreshBookStyle() {
        bookStyle = BookStyleDetector.resolve(override: bookPreferences.styleOverride, detected: map?.profile?.style)
        isStyleChosen = bookPreferences.styleOverride != nil
    }

    @ObservationIgnored private var styleTask: Task<Void, Never>?

    /// Classifies the book's style once (three samples through the shared on-device
    /// gate) when it has none and the model is available. Only AI soundscapes ask.
    func detectBookStyleIfNeeded() {
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, macOS 26.0, *), styleTask == nil, availability.allowsAutomatic,
              let map, map.profile?.style == nil, let story, let book else { return }
        let samples = SceneAnalysisScheduler.profileSamples(story)
        let language = Self.languageName(book.language)
        let bookID = book.id
        styleTask = Task { [weak self, store] in
            let votes = (try? await SceneAnalyzer().styleVotes(samples: samples, language: language)) ?? []
            guard let self, !Task.isCancelled, self.bookID == bookID else { return }
            let style = BookStyleDetector.vote(votes)
            // Merge into the newest map: analysis may have advanced meanwhile.
            var current = self.map ?? map
            if current.profile == nil {
                current.profile = DocumentProfile.resolve(votes: [], signals: TextSignals.measure(samples.joined(separator: "\n")))
            }
            current.profile?.style = style
            store.saveMap(current, bookID: bookID)
            self.publish(map: current)
            self.styleTask = nil
        }
        #endif
    }

    private func publish(map: SceneMap?) {
        self.map = map
        refreshBookStyle()
        planSoundscapes(force: false)
        documentKind = map?.profile?.kind
        analysedWindows = map?.analysedCount ?? 0
        totalWindows = map?.windows.count ?? 0
    }

    private var analysisMayRun: Bool {
        guard appActive, !models.isSynthesizing, preferences.mode == .automatic else { return false }
        let info = ProcessInfo.processInfo
        if info.isLowPowerModeEnabled { return false }
        return info.thermalState == .nominal || info.thermalState == .fair
    }

    private func refreshAvailability(language: String?) {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-NodusImmersiveForceNoAppleIntelligence") {
                availability = .deviceNotEligible
                return
            }
            #endif
            let state = SceneAnalyzer.modelState()
            let supported = language.map { SceneAnalyzer.supports(languageCode: Self.languageCode($0)) }
            availability = .resolve(systemHasModel: true, model: state, languageSupported: supported)
            return
        }
        #endif
        availability = .unsupportedSystem
    }

    nonisolated static func languageCode(_ language: String) -> String {
        let code = Locale.Language(identifier: language).languageCode?.identifier ?? "en"
        return code.isEmpty ? "en" : code
    }

    nonisolated static func languageName(_ language: String) -> String {
        Locale(identifier: "en").localizedString(forLanguageCode: languageCode(language)) ?? "English"
    }

    // MARK: Position

    private var narrationDrivesPosition: Bool {
        guard let bookID, playback.activeBook?.id == bookID, playback.mode != .read else { return false }
        return playback.isPlaying || narrationHadBook
    }

    private var storyPosition: Int {
        guard let story else { return 0 }
        if narrationDrivesPosition, playback.sentences.indices.contains(playback.currentIndex) {
            let sentence = playback.sentences[playback.currentIndex]
            return story.offset(chapter: sentence.chapterIndex, characterOffset: sentence.chapterOffset)
        }
        return story.offset(chapter: readerChapter, characterOffset: readerOffset)
    }

    private var storyChapter: Int {
        if narrationDrivesPosition { return playback.chapterIndex }
        return readerChapter
    }

    // MARK: Decisions

    private func directorInput(now: TimeInterval) -> AmbienceDirector.Input {
        let position = storyPosition
        let motion = tracker.update(position: position, chapter: storyChapter, text: story?.text)
        var input = AmbienceDirector.Input(now: now, position: position, movement: motion.movement,
                                           atTransitionSite: motion.crossedSite, map: map,
                                           mode: preferences.mode, intensity: preferences.intensity)
        input.defaults = bookPreferences.atmosphere.flatMap { preferences.mode == .manual ? $0 : nil }
            ?? preferences.defaultAtmosphere
        if let chosen = bookPreferences.atmosphere, preferences.mode != .study {
            input.override = bookPreferences.locked ? .lock(chosen) : (preferences.mode == .automatic ? .manual(chosen) : nil)
        }
        if !availability.allowsAutomatic, preferences.mode == .automatic {
            // No analysis here: automatic mode holds the default atmosphere.
            input.map = nil
        }
        input.musicEnabled = preferences.musicEnabled
        input.ambienceEnabled = preferences.ambienceEnabled
        input.installedMoods = availableMoods
        input.installedBeds = availableBeds.union([.none])
        input.studyBlock = preferences.studyBlockMinutes > 0 ? TimeInterval(preferences.studyBlockMinutes * 60) : nil
        input.crossfade = preferences.crossfade
        return input
    }

    /// Runs the director once and applies its decision.
    private func step(reason: String) {
        guard policy.shouldPlay, let engine, engine.isRunning else { return }
        let now = clock.tick(at: ProcessInfo.processInfo.systemUptime, playing: true)
        let decision = director.step(directorInput(now: now))
        applyDecision(decision)
        if let last = director.log.last { lastReason = last.reason }
        atmosphere = director.current
        planSoundscapes(force: false)
    }

    private func applyDecision(_ decision: AmbienceDirector.Decision) {
        if case .change(let mood, _, let fade) = decision.music {
            startMusic(mood, crossfade: fade, avoidSubPool: nil)
        } else if decision.rotateMusicTexture, let mood = director.current?.music {
            startMusic(mood, crossfade: preferences.crossfade, avoidSubPool: musicTrack?.semantics.subPool)
        }
        if case .change(let bed, _, let fade) = decision.base {
            startAmbience(bed, crossfade: fade)
        }
    }

    private func startMusic(_ mood: MusicMood?, crossfade: TimeInterval, avoidSubPool: String?) {
        guard let engine else { return }
        guard let mood else {
            engine.stop(.music, fadeOut: crossfade)
            musicTrack = nil
            return
        }
        let now = clock.engaged
        let favorites = generated.favoriteIDs
        let decision = SoundscapeSourcePicker.decide(
            source: preferences.source, generated: preferences.source == .ai ? generated.musicTracks(mood, style: bookStyle) : [],
            downloaded: library.musicTracks(mood), currentID: musicTrack?.id
        ) { pool in
            TrackSelector.next(from: pool, current: self.musicTrack?.id, history: self.history, now: now,
                               maximumEnergy: self.preferences.intensity.maximumEnergy,
                               studyOnly: self.preferences.mode == .study, avoidSubPool: avoidSubPool, favorites: favorites)
        }
        switch decision {
        case .keep where musicTrack?.moods.contains(mood) == true:
            planSoundscapes(force: true)
        case .keep where musicStandIn && !choosing:
            composeNow(layer: .music, mood: mood, bed: nil)
        case .keep, .stop:
            musicStandIn = false
            // Nothing made for this mood yet: never leave another mood playing under its
            // name. With AI, compose it before anything else.
            engine.stop(.music, fadeOut: crossfade)
            musicTrack = nil
            composeNow(layer: .music, mood: mood, bed: nil)
        case .play(let track):
            guard let url = url(for: track) else {
                engine.stop(.music, fadeOut: crossfade)
                musicTrack = nil
                return
            }
            history.played(track.id, at: now)
            musicStandIn = false
            if track.semantics.origin == "generated" { generated.markPlayed(track.id) }
            // A downloaded piece only stands in until one is composed for this mood.
            else if aiSource, generated.musicTracks(mood, style: bookStyle).isEmpty {
                composeNow(layer: .music, mood: mood, bed: nil)
            }
            musicTrack = track
            engine.play(.init(id: track.id, url: url, layer: .music, loop: track.audio.isLoop,
                              tailStart: track.audio.tailStartSeconds, gain: Self.gain(for: track)),
                        crossfade: crossfade)
        }
    }

    private func startAmbience(_ bed: BaseAmbience, crossfade: TimeInterval) {
        guard let engine else { return }
        guard bed != .none else {
            engine.stop(.ambience, fadeOut: crossfade)
            ambienceTrack = nil
            return
        }
        let now = clock.engaged
        let favorites = generated.favoriteIDs
        let decision = SoundscapeSourcePicker.decide(
            source: preferences.source, generated: preferences.source == .ai ? generated.ambienceTracks(bed, style: bookStyle) : [],
            downloaded: library.ambienceTracks(bed), currentID: ambienceTrack?.id
        ) { pool in
            TrackSelector.next(from: pool, current: self.ambienceTrack?.id, history: self.history, now: now, favorites: favorites)
        }
        switch decision {
        case .keep where ambienceTrack?.bed == bed:
            planSoundscapes(force: true)
        case .keep where ambienceStandIn && !choosing:
            composeNow(layer: .ambience, mood: nil, bed: bed)
        case .keep, .stop:
            ambienceStandIn = false
            engine.stop(.ambience, fadeOut: crossfade)
            ambienceTrack = nil
            composeNow(layer: .ambience, mood: nil, bed: bed)
        case .play(let track):
            guard let url = url(for: track) else {
                engine.stop(.ambience, fadeOut: crossfade)
                ambienceTrack = nil
                return
            }
            history.played(track.id, at: now)
            ambienceStandIn = false
            if track.semantics.origin == "generated" { generated.markPlayed(track.id) }
            else if aiSource, generated.ambienceTracks(bed, style: bookStyle).isEmpty {
                composeNow(layer: .ambience, mood: nil, bed: bed)
            }
            ambienceTrack = track
            engine.play(.init(id: track.id, url: url, layer: .ambience, loop: true, tailStart: nil,
                              gain: Self.gain(for: track)),
                        crossfade: crossfade)
        }
    }

    /// Plays a just-composed piece while nothing plays on its layer.
    private func playStandIn(_ piece: GeneratedPiece) {
        guard policy.shouldPlay, let engine, engine.isRunning, let url = generated.url(for: piece.track) else { return }
        let track = piece.track
        history.played(track.id, at: clock.engaged)
        generated.markPlayed(track.id)
        if piece.layer == .music {
            musicStandIn = true
            musicTrack = track
            engine.play(.init(id: track.id, url: url, layer: .music, loop: track.audio.isLoop,
                              tailStart: track.audio.tailStartSeconds, gain: Self.gain(for: track)),
                        crossfade: preferences.crossfade)
        } else {
            ambienceStandIn = true
            ambienceTrack = track
            engine.play(.init(id: track.id, url: url, layer: .ambience, loop: true, tailStart: nil,
                              gain: Self.gain(for: track)),
                        crossfade: preferences.crossfade)
        }
    }

    /// Asks for one piece ahead of everything queued (a pack included).
    private func composeNow(layer: CatalogTrack.Layer, mood: MusicMood?, bed: BaseAmbience?) {
        guard aiSource, appActive, let prompts else { return }
        let component: SoundscapeModels.Component = layer == .music ? .music : .sfx
        guard soundscapeModels.isInstalled(component) || Self.usesFixtureGenerator, let worker = ensureWorker(),
              let job = SoundscapePlanner.job(layer: layer, mood: mood, bed: bed, style: bookStyle, bookID: bookID,
                                              library: prompts, seed: UInt64.random(in: 1 ... UInt64.max / 2),
                                              priority: Self.immediatePriority, studyOnly: preferences.mode == .study)
        else { return }
        Task { await worker.enqueue([job]) }
    }

    /// Attenuates a file mastered louder than its layer's target.
    private static func gain(for track: CatalogTrack) -> Double {
        let target = track.layer == .music ? -20.0 : -28.0
        return min(max(GainCurve.linear(fromDecibels: target - track.audio.integratedLUFS), 0.5), 1)
    }

    /// A piece is near its end: the next one of the same mood fades in.
    private func trackTail(_ layer: ImmersiveAudioEngine.Layer, id: String) {
        guard layer == .music, musicTrack?.id == id, let mood = director.current?.music else { return }
        startMusic(mood, crossfade: 6, avoidSubPool: nil)
    }

    private func trackEnded(_ layer: ImmersiveAudioEngine.Layer, id: String) {
        guard layer == .music, musicTrack?.id == id, let mood = director.current?.music else { return }
        startMusic(mood, crossfade: 2, avoidSubPool: nil)
    }

    // MARK: Playing and pausing

    private func apply(_ transition: ImmersivePlaybackPolicy.Transition?) {
        guard let transition else { return }
        switch transition {
        case .play(let fade):
            guard hasSounds else {
                updateStatus()
                return
            }
            // A start that failed once (the output was unavailable, the app
            // was in the background) is retried on every resume.
            engineFailed = false
            releaseTask?.cancel()
            AudioSessionCoordinator.shared.claim(.immersive)
            let engine = ensureEngine()
            engine.setVolume(.music, slider: preferences.musicVolume, duration: 0)
            engine.setVolume(.ambience, slider: preferences.ambienceVolume, duration: 0)
            engine.setDuckingDepth(music: preferences.ducking.decibels)
            updateNarrationLevels()
            engine.start(fadeIn: fade)
            _ = clock.tick(at: ProcessInfo.processInfo.systemUptime, playing: true)
            startTicking()
            // The engine starts asynchronously; decide once it runs.
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(150))
                self?.step(reason: "resume")
                self?.updateStatus()
            }
        case .pause(let fade):
            _ = clock.tick(at: ProcessInfo.processInfo.systemUptime, playing: false)
            tickTask?.cancel()
            tickTask = nil
            engine?.pause(fadeOut: fade)
            releaseTask?.cancel()
            releaseTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(fade + 0.3))
                guard let self, !Task.isCancelled, !self.policy.shouldPlay else { return }
                AudioSessionCoordinator.shared.release(.immersive)
            }
        }
        updateStatus()
    }

    private func ensureEngine() -> ImmersiveAudioEngine {
        if let engine { return engine }
        #if DEBUG
        let silent = ProcessInfo.processInfo.arguments.contains("-NodusSilentAudioTests")
        #else
        let silent = false
        #endif
        let engine = ImmersiveAudioEngine(silent: silent)
        engine.onTrackTail = { [weak self] layer, id in
            Task { @MainActor in self?.trackTail(layer, id: id) }
        }
        engine.onTrackEnded = { [weak self] layer, id in
            Task { @MainActor in self?.trackEnded(layer, id: id) }
        }
        engine.onFailure = { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                if error is ImmersiveAudioEngine.EngineError { return }
                self.engineFailed = true
                self.status = .unavailable(String(localized: "Music and ambience could not start on this audio output. Narration is not affected."))
            }
        }
        self.engine = engine
        return engine
    }

    private func shutdownEngine() {
        tickTask?.cancel()
        tickTask = nil
        engine?.shutdown()
        engine = nil
        musicTrack = nil
        ambienceTrack = nil
        AudioSessionCoordinator.shared.release(.immersive)
        updateStatus()
    }

    private func startTicking() {
        guard tickTask == nil else { return }
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.tickInterval))
                guard let self, !Task.isCancelled else { return }
                if !self.narrationDrivesPosition, Date().timeIntervalSince(self.lastActivity) > Self.idleLimit {
                    self.apply(self.policy.handle(.idleTimeout))
                }
                self.step(reason: "tick")
            }
        }
    }

    private func updateStatus() {
        if !preferences.isEnabled { status = .off; return }
        if case .unavailable = status, engineFailed { return }
        if !hasSounds { status = .needsPacks; return }
        if bookID == nil || !policy.readerOpen && policy.narration != .playing { status = .waiting; return }
        status = policy.shouldPlay ? .playing : .paused
    }

    // MARK: Narration

    private func observePlayback() {
        withObservationTracking {
            _ = playback.isPlaying
            _ = playback.isLoading
            _ = playback.narrationPeak
            _ = playback.currentIndex
            _ = playback.activeBook?.id
            _ = playback.mode
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.playbackChanged()
                self?.observePlayback()
            }
        }
    }

    private func playbackChanged() {
        synchronizeBook()
        let ours = bookID != nil && playback.activeBook?.id == bookID && playback.mode != .read
        let playing = ours && playback.isPlaying
        if playing != lastNarrationPlaying {
            lastNarrationPlaying = playing
            if playing {
                narrationHadBook = true
                apply(policy.handle(.narrationStarted))
            } else if ours {
                apply(policy.handle(.narrationPaused))
            }
        }
        if narrationHadBook, !ours {
            narrationHadBook = false
            apply(policy.handle(.narrationStopped))
        }
        updateNarrationLevels()
        if playing { step(reason: "narration") }
    }

    private func updateNarrationLevels() {
        let ours = bookID != nil && playback.activeBook?.id == bookID && playback.mode != .read
        let audible = ours && playback.isPlaying && !playback.isLoading
        engine?.setNarrationAudible(audible)
        engine?.setNarrationPeak(ours && playback.isPlaying ? playback.narrationPeak : nil)
    }

    // MARK: Settings

    private func observePreferences() {
        withObservationTracking {
            _ = preferences.mode
            _ = preferences.musicVolume
            _ = preferences.ambienceVolume
            _ = preferences.ducking
            _ = preferences.pausePolicy
            _ = preferences.musicEnabled
            _ = preferences.ambienceEnabled
            _ = preferences.defaultAtmosphere
            _ = preferences.intensity
            _ = preferences.source
            _ = preferences.generatedBudgetMB
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.preferencesChanged()
                self?.observePreferences()
            }
        }
    }

    private func preferencesChanged() {
        generated.budgetBytes = Int64(preferences.generatedBudgetMB) * 1_000_000
        if preferences.source != .ai { cancelGeneration() }
        policy.pausePolicy = preferences.pausePolicy
        if policy.enabled != preferences.isEnabled {
            apply(policy.handle(.enabled(preferences.isEnabled)))
            if !preferences.isEnabled { shutdownEngine() }
        }
        engine?.setVolume(.music, slider: preferences.musicVolume)
        engine?.setVolume(.ambience, slider: preferences.ambienceVolume)
        engine?.setDuckingDepth(music: preferences.ducking.decibels)
        if preferences.mode == .automatic, let book, story == nil {
            prepareText(book: book, chapters: nil)
        }
        if preferences.mode == .automatic { startAnalysisIfNeeded() } else { scheduler?.stop() }
        step(reason: "settings")
        updateStatus()
        if policy.shouldPlay, engine?.isRunning != true, hasSounds { apply(.play(fadeIn: 2)) }
    }

    /// Packs were installed or deleted: start playing if waiting for them.
    /// Sounds were added or deleted. A deleted file keeps playing from its open handle
    /// (a loop forever): stop it, and let the layer pick again or compose.
    private func soundsChanged() {
        updateStatus()
        guard let engine else { return }
        if let track = musicTrack, url(for: track) == nil {
            engine.stop(.music, fadeOut: 1)
            musicTrack = nil
            musicStandIn = false
            if policy.shouldPlay, let mood = director.current?.music { startMusic(mood, crossfade: 1, avoidSubPool: nil) }
        }
        if let track = ambienceTrack, url(for: track) == nil {
            engine.stop(.ambience, fadeOut: 1)
            ambienceTrack = nil
            ambienceStandIn = false
            if policy.shouldPlay, let bed = director.current?.base, bed != .none { startAmbience(bed, crossfade: 1) }
        }
    }

    private func libraryChanged() {
        updateStatus()
        if policy.shouldPlay, engine?.isRunning != true {
            apply(.play(fadeIn: 2))
        } else {
            step(reason: "library")
        }
    }

    // MARK: Reader actions

    func setEnabled(_ on: Bool) {
        preferences.mode = on ? preferences.modeToEnable(automaticAvailable: availability.allowsAutomatic) : .off
    }

    func togglePlayback() {
        apply(policy.handle(policy.shouldPlay ? .userPause : .userPlay))
    }

    /// Keeps what plays now for this book, whatever the text does.
    func lock() {
        guard let current = director.current else { return }
        bookPreferences.locked = true
        bookPreferences.atmosphere = current
        saveBookPreferences()
        isLocked = true
        step(reason: "lock")
    }

    func unlock() {
        bookPreferences.locked = false
        if preferences.mode == .automatic { bookPreferences.atmosphere = nil }
        saveBookPreferences()
        isLocked = false
        isChosenByReader = bookPreferences.atmosphere != nil && preferences.mode == .automatic
        step(reason: "unlock")
    }

    func choose(base: BaseAmbience) {
        var chosen = director.current ?? preferences.defaultAtmosphere
        chosen.base = base
        choose(chosen)
        if base != .none, !preferences.ambienceEnabled { preferences.ambienceEnabled = true }
    }

    func choose(music: MusicMood?) {
        var chosen = director.current ?? preferences.defaultAtmosphere
        chosen.music = music
        choose(chosen)
        if music != nil, !preferences.musicEnabled { preferences.musicEnabled = true }
    }

    private func choose(_ chosen: Atmosphere) {
        bookPreferences.atmosphere = chosen
        if preferences.mode != .automatic {
            preferences.defaultAtmosphere = chosen
        }
        isChosenByReader = preferences.mode == .automatic && !bookPreferences.locked
        saveBookPreferences()
        choosing = true
        defer { choosing = false }
        step(reason: "choice")
    }

    /// Clears the reader's choice and lock: the text decides again.
    func returnToAutomatic() {
        bookPreferences = ImmersiveBookPreferences()
        refreshBookStyle()
        saveBookPreferences()
        isLocked = false
        isChosenByReader = false
        if preferences.mode != .automatic, availability.allowsAutomatic { preferences.mode = .automatic }
        step(reason: "automatic")
    }

    func apply(profile: ImmersiveProfile) {
        preferences.apply(profile, automaticAvailable: availability.allowsAutomatic)
        bookPreferences.atmosphere = nil
        bookPreferences.locked = false
        isLocked = false
        isChosenByReader = false
        saveBookPreferences()
    }

    /// Deletes every scene map (they are rebuilt when needed).
    func deleteSceneMaps() {
        scheduler?.stop()
        scheduler = nil
        store.removeAllMaps()
        map = map.map { SceneMap(contentKey: $0.contentKey, language: $0.language, windows: $0.windows) }
        publish(map: map)
        startAnalysisIfNeeded()
    }

    var sceneMapsSize: Int64 { store.totalSize() }

    var directorLog: [AmbienceDirector.Event] { director.log }

    private func saveBookPreferences() {
        guard let bookID else { return }
        store.savePreferences(bookPreferences, bookID: bookID)
    }

    // MARK: System events

    private func observeSystem() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil,
                                            queue: .main) { [weak self] _ in
            let state = ProcessInfo.processInfo.thermalState
            Task { @MainActor in
                // Stop the piece now; admission waits until the device cools, then the
                // same plan (and a starter pack) carries on.
                if state == .serious || state == .critical { self?.interruptGeneration(retryAfter: 0, shorter: false) }
            }
        })
        #if os(iOS)
        observers.append(center.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil,
                                            queue: .main) { [weak self] _ in
            // A warning reports pressure on the whole system, not this app's limit. On an
            // iPhone 13 (4 GB) one arrives every ~20 s while composing, at about 1 GB, and
            // pieces still finish (peak ~1.2 GB): stop only when the app's own headroom is
            // nearly gone, and retry soon with a shorter recipe.
            Task { @MainActor in
                let available = Int64(os_proc_available_memory())
                if available > 0, available >= Self.memoryWarningHeadroom { return }
                self?.interruptGeneration(retryAfter: 15, shorter: true)
            }
        })
        observers.append(center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil,
                                            queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.sceneActive = false
                self?.interruptGeneration(retryAfter: 0, shorter: false)
            }
        })
        observers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil,
                                            queue: .main) { [weak self] _ in
            Task { @MainActor in self?.sceneActive = true }
        })
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil,
                                            queue: .main) { [weak self] _ in
            Task { @MainActor in self?.appActiveChanged(false) }
        })
        observers.append(center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil,
                                            queue: .main) { [weak self] _ in
            Task { @MainActor in self?.appActiveChanged(true) }
        })
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil,
                                            queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            Task { @MainActor in
                guard let self, let raw, let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
                self.apply(self.policy.handle(type == .began ? .interruptionBegan : .interruptionEnded))
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil,
                                            queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            Task { @MainActor in
                guard let self, let raw, AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable else { return }
                self.apply(self.policy.handle(.headphonesUnplugged))
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.silenceSecondaryAudioHintNotification, object: nil,
                                            queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionSilenceSecondaryAudioHintTypeKey] as? UInt
            Task { @MainActor in
                let begin = raw.flatMap(AVAudioSession.SilenceSecondaryAudioHintType.init(rawValue:)) == .begin
                self?.engine?.setMusicSilenced(begin)
            }
        })
        #endif
    }

    private func appActiveChanged(_ active: Bool) {
        appActive = active
        // No GPU work in the background: the piece in progress stops and the plan waits
        // (admission requires the foreground) instead of being dropped.
        if !active { interruptGeneration(retryAfter: 0, shorter: false) }
        if active {
            lastActivity = Date()
            refreshAvailability(language: book?.language)
            startAnalysisIfNeeded()
        }
        apply(policy.handle(.appActive(active)))
    }
}
