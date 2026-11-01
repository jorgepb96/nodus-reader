// SPDX-License-Identifier: AGPL-3.0-only
import AVFoundation
import Foundation
import Observation
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
    /// Why the atmosphere last changed or held (shown in the debug section).
    private(set) var lastReason = ""

    @ObservationIgnored private var engine: ImmersiveAudioEngine?
    @ObservationIgnored private var director = AmbienceDirector()
    @ObservationIgnored private var tracker = PositionTracker()
    @ObservationIgnored private var clock = EngagedClock()
    @ObservationIgnored private var policy = ImmersivePlaybackPolicy()
    @ObservationIgnored private var history = PlayHistory()
    @ObservationIgnored private var scheduler: SceneAnalysisScheduler?
    @ObservationIgnored private var bookID: UUID?
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
    @ObservationIgnored private var lastNarrationPlaying = false
    @ObservationIgnored private var narrationHadBook = false
    @ObservationIgnored private var engineFailed = false

    static let idleLimit: TimeInterval = 15 * 60
    static let tickInterval: TimeInterval = 15

    init(preferences: ImmersiveAudioPreferences, library: ImmersiveAudioLibrary, playback: PlaybackController,
         models: ModelManager, store: SceneMapStore = SceneMapStore()) {
        self.preferences = preferences
        self.library = library
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
    }

    // MARK: Reader

    /// A book opened in the reader. `chapters` are the reader's chapters
    /// (nil for a PDF: its text is loaded only if automatic mode needs it).
    func readerOpened(book: Book, chapters: [ExtractedChapter]?) {
        shutdownTask?.cancel()
        if bookID != book.id {
            resetSession()
            bookID = book.id
            self.book = book
            bookPreferences = store.loadPreferences(bookID: book.id) ?? ImmersiveBookPreferences()
            isLocked = bookPreferences.locked
            isChosenByReader = bookPreferences.atmosphere != nil && !isLocked
            refreshAvailability(language: book.language)
            prepareText(book: book, chapters: chapters)
        }
        lastActivity = Date()
        apply(policy.handle(.readerOpened))
        updateStatus()
    }

    /// The page on screen moved (silent reading position).
    func readerPosition(chapter: Int, offset: Int) {
        readerChapter = chapter
        readerOffset = offset
        lastActivity = Date()
        apply(policy.handle(.readerActivity))
        if !narrationDrivesPosition { step(reason: "page") }
    }

    func readerClosed(book: Book) {
        guard book.id == bookID else { return }
        apply(policy.handle(.readerClosed))
        scheduler?.stop()
        // Keep the engine a little in case the reader comes straight back.
        shutdownTask?.cancel()
        shutdownTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(300))
            guard let self, !Task.isCancelled, !self.policy.shouldPlay else { return }
            self.shutdownEngine()
        }
        updateStatus()
    }

    private func resetSession() {
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
        engine?.stop(.music, fadeOut: 2)
        engine?.stop(.ambience, fadeOut: 2)
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

    private func publish(map: SceneMap?) {
        self.map = map
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
        input.installedMoods = library.installedMoods
        input.installedBeds = library.installedBeds.union([.none])
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
        let pool = library.musicTracks(mood)
        guard let track = TrackSelector.next(from: pool, current: musicTrack?.id, history: history, now: now,
                                             maximumEnergy: preferences.intensity.maximumEnergy,
                                             studyOnly: preferences.mode == .study, avoidSubPool: avoidSubPool),
              let url = library.url(for: track) else {
            engine.stop(.music, fadeOut: crossfade)
            musicTrack = nil
            return
        }
        history.played(track.id, at: now)
        musicTrack = track
        engine.play(.init(id: track.id, url: url, layer: .music, loop: track.audio.isLoop,
                          tailStart: track.audio.tailStartSeconds, gain: Self.gain(for: track)),
                    crossfade: crossfade)
    }

    private func startAmbience(_ bed: BaseAmbience, crossfade: TimeInterval) {
        guard let engine else { return }
        guard bed != .none,
              let track = TrackSelector.next(from: library.ambienceTracks(bed), current: ambienceTrack?.id,
                                             history: history, now: clock.engaged),
              let url = library.url(for: track) else {
            engine.stop(.ambience, fadeOut: crossfade)
            ambienceTrack = nil
            return
        }
        history.played(track.id, at: clock.engaged)
        ambienceTrack = track
        engine.play(.init(id: track.id, url: url, layer: .ambience, loop: true, tailStart: nil,
                          gain: Self.gain(for: track)),
                    crossfade: crossfade)
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
            guard library.hasAnything, !engineFailed else {
                updateStatus()
                return
            }
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
        if !library.hasAnything { status = .needsPacks; return }
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
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.playbackChanged()
                self?.observePlayback()
            }
        }
    }

    private func playbackChanged() {
        let ours = bookID != nil && playback.activeBook?.id == bookID
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
        let ours = bookID != nil && playback.activeBook?.id == bookID
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
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.preferencesChanged()
                self?.observePreferences()
            }
        }
    }

    private func preferencesChanged() {
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
    }

    /// Packs were installed or deleted: start playing if waiting for them.
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
        step(reason: "choice")
    }

    /// Clears the reader's choice and lock: the text decides again.
    func returnToAutomatic() {
        bookPreferences = ImmersiveBookPreferences()
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
        #if os(iOS)
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
        if active {
            lastActivity = Date()
            refreshAvailability(language: book?.language)
            startAnalysisIfNeeded()
        }
        apply(policy.handle(.appActive(active)))
    }
}
