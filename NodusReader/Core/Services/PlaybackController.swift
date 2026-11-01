// SPDX-License-Identifier: AGPL-3.0-only
import AVFoundation
import Foundation
import KokoroTTS
import Observation
import PhononTTS
#if canImport(MediaPlayer)
import MediaPlayer
#endif
#if os(iOS)
import UIKit
#endif

public enum SleepTimerOption: String, CaseIterable, Identifiable, Sendable {
    case off
    case fiveMinutes
    case fifteenMinutes
    case thirtyMinutes
    case fortyFiveMinutes
    case sixtyMinutes
    case endOfChapter

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .off: String(localized: "Off")
        case .fiveMinutes: String(localized: "5 minutes")
        case .fifteenMinutes: String(localized: "15 minutes")
        case .thirtyMinutes: String(localized: "30 minutes")
        case .fortyFiveMinutes: String(localized: "45 minutes")
        case .sixtyMinutes: String(localized: "60 minutes")
        case .endOfChapter: String(localized: "End of chapter")
        }
    }

    public var shortLabel: String {
        switch self {
        case .off: "Off"
        case .fiveMinutes: "5 min"
        case .fifteenMinutes: "15 min"
        case .thirtyMinutes: "30 min"
        case .fortyFiveMinutes: "45 min"
        case .sixtyMinutes: "60 min"
        case .endOfChapter: "Chapter"
        }
    }

    public var minutes: Int? {
        switch self {
        case .fiveMinutes: 5
        case .fifteenMinutes: 15
        case .thirtyMinutes: 30
        case .fortyFiveMinutes: 45
        case .sixtyMinutes: 60
        default: nil
        }
    }
}

public struct NarrationSentence: Identifiable, Sendable {
    public let id: Int
    public let chapterIndex: Int
    public let text: String
    /// UTF-16 range of this sentence inside the chapter text.
    public let chapterOffset: Int
    public let chapterLength: Int

    public var chapterRange: NSRange {
        NSRange(location: chapterOffset, length: chapterLength)
    }
}

/// Local narration with the installed Kokoro and Phonon neural engines.
/// Neural audio uses an AVAudioEngine graph and per-sentence word state.
@MainActor
@Observable
public final class PlaybackController {
    public static let speedOptions: [Double] = [0.75, 1.0, 1.25, 1.35, 1.5, 1.75, 2.0]
    private static let speedPreferenceKey = "nodus.playback.speed"

    @ObservationIgnored private let library: LibraryService
    @ObservationIgnored private let defaults: UserDefaults
    public let voices: VoiceCatalog
    @ObservationIgnored private let models: ModelManager

    #if canImport(MediaPlayer) && os(iOS)
    /// The lock screen and Dynamic Island artwork, built once per book.
    @ObservationIgnored private var nowPlayingArtwork: (bookID: UUID, artwork: MPMediaItemArtwork)?
    #endif
    @ObservationIgnored private let audioEngine = AVAudioEngine()
    @ObservationIgnored private let audioPlayer = AVAudioPlayerNode()
    @ObservationIgnored private let timePitch = AVAudioUnitTimePitch()
    @ObservationIgnored private let neuralFormat = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)
    @ObservationIgnored private var neuralTask: Task<Void, Never>?
    /// Sentences made ahead of the one playing (by index, with the voice that
    /// made them), so the next sentence starts without waiting for synthesis.
    @ObservationIgnored private var prefetched: [Int: (voiceID: String, narration: CachedNarration)] = [:]
    @ObservationIgnored private var prefetchTask: Task<Void, Never>?
    private static let prefetchDepth = 2
    @ObservationIgnored private var neuralProgressTask: Task<Void, Never>?
    @ObservationIgnored private var cacheTask: Task<Void, Never>?
    @ObservationIgnored private var samplePlayer: AVAudioPlayer?
    @ObservationIgnored private var sampleTask: Task<Void, Never>?
    @ObservationIgnored private var sampleToken = UUID()
    @ObservationIgnored private var neuralWords: [NarrationWordTiming] = []
    @ObservationIgnored private var neuralBufferDuration: TimeInterval = 0
    @ObservationIgnored private var neuralStartTime: TimeInterval = 0
    /// Absolute time in the full sentence, without the highlight's visual lead.
    @ObservationIgnored private var neuralPositionTime: TimeInterval?
    @ObservationIgnored private var neuralPositionVoiceID: String?
    @ObservationIgnored private var narrationFinished = false
    @ObservationIgnored private var neuralStartOffset: Int = 0
    @ObservationIgnored private var neuralPlaybackToken = UUID()
    @ObservationIgnored private var neuralPaused = false
    @ObservationIgnored private var loadToken = UUID()
    @ObservationIgnored private var cacheToken = UUID()
    @ObservationIgnored private var restartOnResume = false
    @ObservationIgnored private var restartVoiceOnResume = false
    @ObservationIgnored private var readerResumePosition: (bookID: UUID, chapterIndex: Int, offset: Int)?
    @ObservationIgnored private var pendingChapterSeek: (chapter: Int, offset: Int?, fraction: Double)?
    @ObservationIgnored private var voiceChangeObserver: NSObjectProtocol?
    @ObservationIgnored private var libraryDeletionObserver: NSObjectProtocol?
    @ObservationIgnored private let synthesisGate = SynthesisGate()

    public private(set) var activeBook: Book?
    public private(set) var chapters: [ExtractedChapter] = []
    public private(set) var sentences: [NarrationSentence] = []
    public private(set) var currentIndex = 0
    public private(set) var chapterIndex = 0
    public private(set) var isPlaying = false {
        didSet {
            updateEngineUse()
            // The lock screen and Dynamic Island follow every change, including
            // stops from errors, chapter ends and sleep timers.
            if oldValue != isPlaying { updateNowPlaying() }
        }
    }
    public private(set) var isLoading = false
    public private(set) var isPlayingSample = false {
        didSet { updateEngineUse() }
    }

    /// Tells the model manager whether narration needs the neural engine to
    /// stay in memory (it is released a few minutes after playback stops).
    private func updateEngineUse() {
        models.setNarrationInUse(isPlaying || isPlayingSample)
    }
    public private(set) var sampleVoiceID: String?
    /// The sample of `sampleVoiceID` is still being synthesised (a neural
    /// model may first have to load): its play button shows progress.
    public private(set) var isPreparingSample = false
    public private(set) var currentWordRange: NSRange?
    public private(set) var currentWord: String?
    public private(set) var audioCacheBytes: Int64 = 0
    public private(set) var audioCacheProgress: Double?
    public private(set) var isGeneratingAudioCache = false
    public var errorMessage: String?
    public var cacheErrorMessage: String?
    public var mode: ReadingMode = .listen
    public private(set) var speedMultiplier: Double = 1.0
    public var sleepTimer: SleepTimerOption = .off
    public private(set) var sleepEndsAt: Date?

    @ObservationIgnored private var sleepTask: Task<Void, Never>?
    @ObservationIgnored private var resumeAfterInterruption = false
    @ObservationIgnored private var interruptionObserver: NSObjectProtocol?
    @ObservationIgnored private var routeObserver: NSObjectProtocol?

    init(library: LibraryService, voices: VoiceCatalog, models: ModelManager,
         defaults: UserDefaults = .standard) {
        self.library = library
        self.defaults = defaults
        self.voices = voices
        self.models = models
        let savedSpeed = defaults.double(forKey: Self.speedPreferenceKey)
        speedMultiplier = Self.speedOptions.contains(savedSpeed) ? savedSpeed : 1.0
        // Restore the audio rate as well as its label before any narration
        // starts; otherwise the UI can show the saved speed while playing 1×.
        timePitch.rate = Float(speedMultiplier)
        #if DEBUG
        // UI tests exercise the real playback clock without audible output.
        if ProcessInfo.processInfo.arguments.contains("-NodusSilentAudioTests") {
            audioPlayer.volume = 0
        }
        #endif
        if let neuralFormat {
            audioEngine.attach(audioPlayer)
            audioEngine.attach(timePitch)
            audioEngine.connect(audioPlayer, to: timePitch, format: neuralFormat)
            audioEngine.connect(timePitch, to: audioEngine.mainMixerNode, format: neuralFormat)
            audioEngine.prepare()
        }
        libraryDeletionObserver = NotificationCenter.default.addObserver(
            forName: .nodusLibraryBooksDeleted,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let ids = notification.userInfo?["ids"] as? [UUID] ?? []
            Task { @MainActor [weak self] in
                guard let self, let activeID = self.activeBook?.id,
                      ids.contains(activeID) else { return }
                self.forgetDeletedBook()
            }
        }
        voiceChangeObserver = NotificationCenter.default.addObserver(
            forName: .nodusVoiceEngineChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.activeBook != nil else { return }
                self.cancelAudioCacheGeneration()
                let offset = self.currentWordRange?.location ?? self.neuralStartOffset
                if self.isPlaying {
                    self.stopAudio()
                    self.isPlaying = false
                    self.speakCurrent(fromOffset: offset)
                } else if self.audioPlayer.isPlaying {
                    self.stopAudio()
                    self.isPlaying = false
                } else if self.activeBook != nil {
                    self.restartVoiceOnResume = true
                }
            }
        }
        configureRemoteCommands()
        #if os(iOS)
        observeAudioSession()
        #endif
    }

    #if os(iOS)
    private func observeAudioSession() {
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch type {
                case .began:
                    self.resumeAfterInterruption = self.isPlaying
                    self.pause()
                case .ended:
                    let optionsRaw = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                    let options = AVAudioSession.InterruptionOptions(rawValue: optionsRaw)
                    if options.contains(.shouldResume), self.resumeAfterInterruption {
                        self.resume()
                    }
                    self.resumeAfterInterruption = false
                @unknown default:
                    break
                }
            }
        }

        routeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  let reason = AVAudioSession.RouteChangeReason(rawValue: raw),
                  reason == .oldDeviceUnavailable else { return }
            Task { @MainActor [weak self] in
                self?.pause()
            }
        }
    }
    #endif

    // MARK: Computed state

    public var hasActiveBook: Bool { activeBook != nil }
    public var currentSentence: String {
        guard sentences.indices.contains(currentIndex) else { return "" }
        return sentences[currentIndex].text
    }
    public var previousSentenceText: String? {
        guard sentences.indices.contains(currentIndex - 1) else { return nil }
        return sentences[currentIndex - 1].text
    }
    public var nextSentenceText: String? {
        guard sentences.indices.contains(currentIndex + 1) else { return nil }
        return sentences[currentIndex + 1].text
    }
    public var chapterTitle: String {
        guard chapters.indices.contains(chapterIndex) else { return "" }
        return chapters[chapterIndex].title
    }
    public var chapterCount: Int { chapters.count }
    public var sentenceCount: Int { sentences.count }
    public var chapterNumber: Int { chapterIndex + 1 }
    public var sentenceNumber: Int { currentIndex + 1 }

    public var currentSentenceChapterRange: NSRange? {
        guard sentences.indices.contains(currentIndex) else { return nil }
        return sentences[currentIndex].chapterRange
    }

    /// The word being read, or the requested start inside a sentence while
    /// audio is being prepared. Used when returning from the audio panel.
    public var currentChapterOffset: Int? {
        guard sentences.indices.contains(currentIndex) else { return nil }
        return sentences[currentIndex].chapterOffset + (currentWordRange?.location ?? neuralStartOffset)
    }

    /// Transfer the audio position once when the player opens the reader.
    /// Later visits in Read mode keep any progress made by turning pages.
    public func requestReaderResume() {
        guard let book = activeBook, let offset = currentChapterOffset else { return }
        readerResumePosition = (book.id, chapterIndex, offset)
    }

    public func consumeReaderResume(for book: Book) -> (chapterIndex: Int, offset: Int)? {
        guard let position = readerResumePosition, position.bookID == book.id else { return nil }
        readerResumePosition = nil
        return (position.chapterIndex, position.offset)
    }

    public var currentWordChapterRange: NSRange? {
        guard let sentence = sentences.indices.contains(currentIndex) ? sentences[currentIndex] : nil,
              let word = currentWordRange else { return nil }
        return NSRange(location: sentence.chapterOffset + word.location, length: word.length)
    }

    public var sentenceIndexInChapter: Int {
        sentences.prefix(currentIndex).filter { $0.chapterIndex == chapterIndex }.count
    }

    public var sentenceCountInChapter: Int {
        sentences.filter { $0.chapterIndex == chapterIndex }.count
    }

    public var chapterProgress: Double {
        let count = max(sentenceCountInChapter, 1)
        return Double(sentenceIndexInChapter) / Double(count)
    }

    public var overallProgress: Double {
        guard !sentences.isEmpty, !chapters.isEmpty else { return 0 }
        let chapterBase = Double(chapterIndex) / Double(chapters.count)
        let withinChapter = chapterProgress / Double(chapters.count)
        return min(1, chapterBase + withinChapter)
    }

    public var speedLabel: String {
        String(format: "%g×", speedMultiplier)
    }

    public var activeVoice: VoiceCatalog.Voice? {
        guard let book = activeBook else { return voices.defaultVoice }
        return voices.narrationVoice(preferredID: book.preferredVoiceID, language: book.language)
    }

    public var activeVoiceID: String? {
        activeVoice?.id ?? voices.defaultVoiceID
    }

    public var voiceLabel: String {
        activeVoice?.name ?? String(localized: "No voice model")
    }

    /// True when the book's synced voice is not installed on this device and a
    /// fallback voice is reading it instead.
    public var preferredVoiceIsMissing: Bool {
        guard let id = activeBook?.preferredVoiceID else { return false }
        return voices.voice(withID: id) == nil
    }

    public var engineLabel: String {
        activeVoice?.engineLabel ?? String(localized: "No voice model")
    }

    /// Narration is always neural now; false only while no model is installed.
    public var isNeuralVoice: Bool { activeVoice != nil }

    public var sleepRemainingLabel: String? {
        guard let end = sleepEndsAt else { return nil }
        let seconds = max(0, Int(end.timeIntervalSinceNow))
        let minutes = seconds / 60
        let remainder = seconds % 60
        return String(format: "%d:%02d", minutes, remainder)
    }

    public var deviceName: String { DeviceInfo.name }

    // MARK: Starting and stopping

    public func start(book: Book, mode: ReadingMode = .listen,
                      startingSentence: String? = nil, wordOffset: Int = 0,
                      startingChapterIndex: Int? = nil, startingChapterOffset: Int? = nil) async {
        if activeBook?.id == book.id {
            self.mode = mode
            if let startingChapterIndex, let startingChapterOffset,
               let found = sentenceIndex(chapter: startingChapterIndex, offset: startingChapterOffset) {
                let offset = startingChapterOffset - sentences[found].chapterOffset
                stopAudio()
                isPlaying = false
                currentIndex = found
                narrationFinished = false
                chapterIndex = sentences[found].chapterIndex
                neuralStartOffset = max(0, offset)
                library.setReadingMode(book, mode: mode)
                mode == .read ? pause() : speakCurrent(fromOffset: offset)
                return
            }
            if let startingSentence,
               let index = sentenceIndex(matching: startingSentence) {
                stopAudio()
                isPlaying = false
                currentIndex = index
                narrationFinished = false
                chapterIndex = sentences[index].chapterIndex
                neuralStartOffset = max(0, wordOffset)
                library.setReadingMode(book, mode: mode)
                mode == .read ? pause() : speakCurrent(fromOffset: wordOffset)
                return
            }
            setMode(mode)
            if mode != .read, !isPlaying { resume() }
            return
        }

        stopSpeaking(clearBook: true)
        let token = UUID()
        loadToken = token
        activeBook = book
        narrationFinished = false
        self.mode = mode
        isLoading = true
        errorMessage = nil

        do {
            await voices.loadIfNeeded()
            guard token == loadToken, activeBook?.id == book.id else { return }
            let loaded = try await BookTextLoader.loadChapters(for: book, fileStore: library.fileStore)
            guard token == loadToken, activeBook?.id == book.id else { return }
            guard !loaded.isEmpty else {
                throw ImportError.emptyDocument(book.title)
            }
            library.refreshChapterTitlesIfNeeded(book, chapters: loaded)
            chapters = loaded
            sentences = Self.buildSentences(from: loaded)
            resetPrefetch()
            guard !sentences.isEmpty else {
                throw ImportError.emptyDocument(book.title)
            }
            let resumeChapter: Int
            if book.format == .pdf {
                let page = max(book.locator.pageIndex ?? book.locator.chapterIndex, 0)
                resumeChapter = loaded.lastIndex { $0.id <= page } ?? 0
            } else {
                resumeChapter = min(max(book.locator.chapterIndex, 0), max(chapters.count - 1, 0))
            }
            let legacyOffset = Int(Double(max((loaded[resumeChapter].text as NSString).length - 1, 0)) *
                                   min(max(book.locator.scrollFraction, 0), 1))
            currentIndex = sentenceIndex(chapter: resumeChapter, offset: legacyOffset)
                ?? sentences.firstIndex { $0.chapterIndex > resumeChapter } ?? 0
            var startOffset = 0
            var startTime: TimeInterval?
            if let startingChapterIndex, let startingChapterOffset,
               let found = sentenceIndex(chapter: startingChapterIndex, offset: startingChapterOffset) {
                currentIndex = found
                startOffset = max(0, startingChapterOffset - sentences[found].chapterOffset)
            } else if let startingSentence, let index = sentenceIndex(matching: startingSentence) {
                currentIndex = index
                startOffset = wordOffset
            } else if let saved = book.locator.narrationPosition,
                      let destination = narrationDestination(chapter: saved.chapterIndex, offset: saved.characterOffset, fraction: 0) {
                currentIndex = destination.index
                startOffset = destination.offset
                let sentence = sentences[currentIndex]
                if sentence.chapterOffset == saved.sentenceOffset, sentence.text == saved.sentenceText,
                   saved.voiceID == activeVoice?.id,
                   let time = saved.audioTime, time.isFinite, time >= 0 {
                    startTime = time
                }
            }
            // The reader may select another chapter while the book text is
            // still loading. Its latest selection takes precedence.
            if let pending = pendingChapterSeek {
                pendingChapterSeek = nil
                if let destination = narrationDestination(chapter: pending.chapter, offset: pending.offset,
                                                          fraction: pending.fraction) {
                    currentIndex = destination.index
                    startOffset = destination.offset
                    startTime = nil
                }
            }
            chapterIndex = sentences[currentIndex].chapterIndex
            neuralStartOffset = startOffset
            neuralPositionTime = startTime
            neuralPositionVoiceID = startTime == nil ? nil : activeVoice?.id
            isLoading = false
            library.setReadingMode(book, mode: mode)
            library.open(book)
            if mode != .read {
                configureAudioSession()
                speakCurrent(fromOffset: startOffset, fromTime: startTime)
            }
        } catch {
            guard token == loadToken else { return }
            isLoading = false
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            stopSpeaking(clearBook: true)
        }
    }

    public func toggle() {
        isPlaying ? pause() : resume()
    }

    public func pause() {
        captureNarrationTime()
        if isNeuralVoice {
            if audioPlayer.isPlaying {
                audioPlayer.pause()
                // A running engine renders silence, which iOS reports as
                // playing on the lock screen; pause it with the player.
                audioEngine.pause()
                neuralPaused = true
                neuralProgressTask?.cancel()
                neuralProgressTask = nil
                isPlaying = false
                updateNowPlaying()
            } else if isPlaying {
                neuralTask?.cancel()
                neuralTask = nil
                neuralPaused = false
                isPlaying = false
                isLoading = false
                updateNowPlaying()
            }
            // Also save an already-paused/restored cursor before dismissal.
            saveProgress()
            return
        }
        isPlaying = false
        saveProgress()
    }

    /// Save before the scene goes inactive without interrupting background audio.
    public func persistPosition() {
        captureNarrationTime()
        saveProgress()
    }

    public func resume() {
        guard let book = activeBook else { return }
        if mode == .read {
            mode = .readAndListen
            library.setReadingMode(book, mode: mode)
        }
        if restartVoiceOnResume {
            restartVoiceOnResume = false
            restartOnResume = false
            let offset = currentWordRange?.location ?? neuralStartOffset
            stopAudio()
            isPlaying = false
            speakCurrent(fromOffset: offset)
            updateNowPlaying()
            return
        }
        if restartOnResume, !neuralPaused {
            restartOnResume = false
            let offset = currentWordRange?.location ?? neuralStartOffset
            let time = neuralPositionTime
            stopAudio()
            isPlaying = false
            speakCurrent(fromOffset: offset, fromTime: time)
            updateNowPlaying()
            return
        }
        restartOnResume = false
        configureAudioSession()
        if isNeuralVoice {
            if neuralPaused {
                guard startNeuralEngine() else {
                    audioUnavailable()
                    return
                }
                audioPlayer.play()
                neuralPaused = false
                isPlaying = true
                startNeuralProgress()
            } else {
                speakCurrent(fromOffset: currentWordRange?.location ?? neuralStartOffset,
                             fromTime: neuralPositionTime)
            }
            updateNowPlaying()
            return
        }
        speakCurrent()
        updateNowPlaying()
    }

    public func stopAndClose() {
        stopSpeaking(clearBook: true)
    }

    /// The SwiftData object is already deleted; do not save progress into it.
    private func forgetDeletedBook() {
        let deletedBookID = activeBook?.id
        let pendingCacheTask = cacheTask
        cancelAudioCacheGeneration()
        sleepTask?.cancel()
        sleepTask = nil
        sleepTimer = .off
        sleepEndsAt = nil
        stopAudio()
        isPlaying = false
        resetWordState()
        activeBook = nil
        chapters = []
        sentences = []
        resetPrefetch()
        currentIndex = 0
        chapterIndex = 0
        pendingChapterSeek = nil
        readerResumePosition = nil
        mode = .listen
        updateNowPlaying()
        if let deletedBookID {
            let cache = models.narrationCache
            Task.detached {
                _ = await pendingCacheTask?.value
                await cache.deleteBook(bookID: deletedBookID)
            }
        }
    }

    public func stopSpeaking(clearBook: Bool) {
        // Capture the clock and persist the cursor before resetting playback.
        persistPosition()
        loadToken = UUID()
        sleepTask?.cancel()
        sleepTask = nil
        sleepTimer = .off
        sleepEndsAt = nil
        stopAudio()
        stopSamplePlayback()
        isPlaying = false
        resetWordState()
        if clearBook {
            restartOnResume = false
            restartVoiceOnResume = false
            readerResumePosition = nil
            pendingChapterSeek = nil
            cancelAudioCacheGeneration()
            activeBook = nil
            chapters = []
            sentences = []
            resetPrefetch()
            currentIndex = 0
            chapterIndex = 0
            mode = .listen
            updateNowPlaying()
            deactivateAudioSession()
        }
    }

    /// Starts narration at a character offset inside the current sentence.
    /// Used by the reader when the user taps a word.
    public func playFromWord(offsetInSentence offset: Int) {
        guard let book = activeBook, !sentences.isEmpty else { return }
        if mode == .read { mode = .readAndListen }
        library.setReadingMode(book, mode: mode)
        configureAudioSession()
        stopAudio()
        isPlaying = false
        speakCurrent(fromOffset: offset)
    }

    // MARK: Transport

    public func nextSentence() {
        guard !isLoading, !sentences.isEmpty else { return }
        guard currentIndex + 1 < sentences.count else {
            finishBook()
            return
        }
        move(to: currentIndex + 1)
    }

    public func previousSentence() {
        guard !isLoading, currentIndex > 0 else { return }
        move(to: currentIndex - 1)
    }

    public func nextChapter() {
        guard !isLoading,
              let next = sentences.firstIndex(where: { $0.chapterIndex > chapterIndex }) else { return }
        move(to: next)
    }

    public func previousChapter() {
        guard !isLoading,
              let previous = sentences.lastIndex(where: { $0.chapterIndex < chapterIndex }) else { return }
        let chapter = sentences[previous].chapterIndex
        guard let start = sentences.firstIndex(where: { $0.chapterIndex == chapter }) else { return }
        move(to: start)
    }

    public func seek(to index: Int) {
        guard !isLoading, sentences.indices.contains(index) else { return }
        move(to: index)
    }

    /// Follow an explicit reader jump without changing its playing/paused
    /// state. For PDFs, `chapter` is the original page ID used by the reader.
    @discardableResult
    public func seek(toChapter chapter: Int, offset: Int? = nil, fraction: Double = 0) -> Bool {
        guard activeBook != nil else { return false }
        if isLoading, sentences.isEmpty {
            pendingChapterSeek = (chapter, offset, fraction)
            return true
        }
        guard let destination = narrationDestination(chapter: chapter, offset: offset, fraction: fraction) else {
            // A chapter without readable text must not leave the previous
            // chapter speaking behind the selected page.
            pause()
            return false
        }
        let wasPlaying = isPlaying
        stopAudio()
        resetPrefetch()
        resetWordState()
        isPlaying = false
        currentIndex = destination.index
        narrationFinished = false
        chapterIndex = sentences[destination.index].chapterIndex
        neuralStartOffset = destination.offset
        restartOnResume = true
        restartVoiceOnResume = false
        readerResumePosition = nil
        errorMessage = nil
        saveProgress()
        if wasPlaying, mode != .read {
            restartOnResume = false
            speakCurrent(fromOffset: destination.offset)
        }
        updateNowPlaying()
        return true
    }

    private func narrationDestination(chapter: Int, offset: Int?, fraction: Double) -> (index: Int, offset: Int)? {
        let index: Int
        if activeBook?.format == .pdf {
            guard let match = chapters.firstIndex(where: { $0.id == chapter }) else { return nil }
            index = match
        } else {
            index = chapter
        }
        guard chapters.indices.contains(index) else { return nil }
        let length = (chapters[index].text as NSString).length
        let position = offset ?? Int((Double(max(length - 1, 0)) * min(max(fraction, 0), 1)).rounded())
        guard let sentence = sentenceIndex(chapter: index, offset: max(0, position)) else { return nil }
        let inSentence = max(0, min(position - sentences[sentence].chapterOffset,
                                    max(sentences[sentence].chapterLength - 1, 0)))
        return (sentence, inSentence)
    }

    public func setSpeed(_ multiplier: Double) {
        guard Self.speedOptions.contains(multiplier) else { return }
        speedMultiplier = multiplier
        timePitch.rate = Float(multiplier)
        defaults.set(multiplier, forKey: Self.speedPreferenceKey)
        guard isPlaying else {
            if activeBook != nil { restartOnResume = true }
            return
        }
        let offset = currentWordRange?.location ?? 0
        if isNeuralVoice {
            neuralProgressTask?.cancel()
            neuralProgressTask = nil
            stopAudio()
            isPlaying = false
            speakCurrent(fromOffset: offset)
            return
        }
        stopAudio()
        isPlaying = false
        speakCurrent(fromOffset: offset)
    }

    public func setVoice(_ voice: VoiceCatalog.Voice) {
        guard let book = activeBook else { return }
        cancelAudioCacheGeneration()
        library.setPreferredVoice(book, voiceID: voice.id)
        if isPlaying {
            let offset = currentWordRange?.location ?? 0
            stopAudio()
            isPlaying = false
            speakCurrent(fromOffset: offset)
        } else {
            restartVoiceOnResume = true
        }
        updateNowPlaying()
    }

    public func setMode(_ newMode: ReadingMode) {
        mode = newMode
        if let book = activeBook {
            library.setReadingMode(book, mode: newMode)
        }
        switch newMode {
        case .read:
            pause()
        case .listen, .readAndListen:
            if !isPlaying { resume() }
        }
    }

    public func setSleepTimer(_ timer: SleepTimerOption) {
        sleepTask?.cancel()
        sleepTask = nil
        sleepTimer = timer
        sleepEndsAt = nil
        guard let minutes = timer.minutes else { return }
        sleepEndsAt = Date().addingTimeInterval(TimeInterval(minutes * 60))
        sleepTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(minutes * 60))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                self.pause()
                self.sleepTimer = .off
                self.sleepEndsAt = nil
            }
        }
    }

    // MARK: Samples

    public func playSample(voice: VoiceCatalog.Voice) {
        if isPlaying { pause() }
        configureAudioSession()
        samplePlayer?.stop()
        sampleTask?.cancel()
        let token = UUID()
        sampleToken = token
        let sample = voice.language.hasPrefix("es")
            ? "Así suena esta voz al narrar tu biblioteca en Nodus Reader."
            : "This is how this voice sounds reading your library in Nodus Reader."
        isPlayingSample = true
        isPreparingSample = true
        sampleVoiceID = voice.id

        sampleTask = Task { [weak self] in
            guard let self else { return }
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("nodus-sample-\(UUID().uuidString).caf")
            defer { try? FileManager.default.removeItem(at: url) }
            do {
                let audio = try await self.synthesize(text: sample, voice: voice)
                guard !Task.isCancelled, token == self.sampleToken,
                      let buffer = self.makeBuffer(samples: audio.samples, sampleRate: audio.sampleRate) else {
                    if token == self.sampleToken { self.isPreparingSample = false }
                    self.isPlayingSample = false
                    return
                }
                let file = try AVAudioFile(forWriting: url, settings: buffer.format.settings,
                                           commonFormat: .pcmFormatFloat32, interleaved: false)
                try file.write(from: buffer)
                let player = try AVAudioPlayer(contentsOf: url)
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("-NodusSilentAudioTests") { player.volume = 0 }
                #endif
                guard token == self.sampleToken else {
                    self.isPlayingSample = false
                    return
                }
                self.samplePlayer = player
                self.isPreparingSample = false
                player.play()
                while player.isPlaying {
                    try? await Task.sleep(for: .milliseconds(200))
                }
                if token == self.sampleToken { self.isPlayingSample = false }
            } catch {
                if token == self.sampleToken {
                    self.isPreparingSample = false
                    self.isPlayingSample = false
                }
            }
        }
    }

    /// Stops the sample being prepared or played.
    public func stopSample() {
        stopSamplePlayback()
    }

    private func stopSamplePlayback() {
        sampleToken = UUID()
        sampleTask?.cancel()
        sampleTask = nil
        samplePlayer?.stop()
        samplePlayer = nil
        isPlayingSample = false
        isPreparingSample = false
        sampleVoiceID = nil
    }

    // MARK: Audio cache

    func refreshAudioCacheSize() async {
        guard let book = activeBook else {
            audioCacheBytes = 0
            return
        }
        audioCacheBytes = await models.narrationCache.bytes(for: book.id)
    }

    func generateAudioCacheForCurrentBook() {
        guard let book = activeBook, let voice = activeVoice else {
            errorMessage = String(localized: "Choose a Kokoro or Phonon voice before generating audio.")
            return
        }
        guard !isGeneratingAudioCache else { return }
        let allSentences = sentences
        guard !allSentences.isEmpty else { return }
        isGeneratingAudioCache = true
        audioCacheProgress = 0
        cacheErrorMessage = nil
        let token = UUID()
        cacheToken = token
        let cache = models.narrationCache
        let bookID = book.id
        cacheTask = Task { [weak self] in
            guard let self else { return }
            var completed = 0
            for sentence in allSentences {
                guard !Task.isCancelled, token == self.cacheToken,
                      self.activeBook?.id == bookID else { break }
                let key = cache.key(text: sentence.text, engine: voice.engineRaw, voice: voice.id)
                let existing = await cache.load(bookID: bookID, key: key)
                if existing == nil {
                    do {
                        let audio = try await self.synthesize(text: sentence.text, voice: voice)
                        try Task.checkCancellation()
                        guard token == self.cacheToken else { break }
                        let words = await Self.alignWords(text: sentence.text,
                                                          samples: audio.samples,
                                                          sampleRate: audio.sampleRate,
                                                          language: voice.language)
                        try Task.checkCancellation()
                        guard token == self.cacheToken else { break }
                        if let buffer = self.makeBuffer(samples: audio.samples,
                                                        sampleRate: audio.sampleRate) {
                            let saved = await cache.save(bookID: bookID, key: key,
                                                         buffer: buffer, words: words)
                            if self.activeBook?.id == bookID {
                                self.audioCacheBytes += saved
                            }
                        }
                    } catch {
                        if !Task.isCancelled, token == self.cacheToken {
                            self.cacheErrorMessage = (error as? LocalizedError)?.errorDescription
                                ?? error.localizedDescription
                        }
                        break
                    }
                }
                completed += 1
                if token == self.cacheToken {
                    self.audioCacheProgress = Double(completed) / Double(allSentences.count)
                }
            }
            guard token == self.cacheToken else { return }
            self.isGeneratingAudioCache = false
            self.audioCacheProgress = nil
            await self.refreshAudioCacheSize()
            self.cacheTask = nil
        }
    }

    func cancelAudioCacheGeneration() {
        cacheErrorMessage = nil
        cacheToken = UUID()
        cacheTask?.cancel()
        cacheTask = nil
        isGeneratingAudioCache = false
        audioCacheProgress = nil
    }

    func deleteAudioCacheForCurrentBook() async {
        guard let book = activeBook else { return }
        let task = cacheTask
        let playback = neuralTask
        cancelAudioCacheGeneration()
        await task?.value
        await playback?.value
        await models.narrationCache.deleteBook(bookID: book.id)
        await refreshAudioCacheSize()
    }

    func deleteAllNarrationCaches() async {
        let task = cacheTask
        let playback = neuralTask
        cancelAudioCacheGeneration()
        await task?.value
        await playback?.value
        await models.narrationCache.deleteAll()
        audioCacheBytes = 0
    }

    // MARK: Internals

    /// Word timings for the read-along highlight: measured by on-device
    /// speech recognition where the system offers it, otherwise estimated from
    /// the pauses in the audio.
    private static func alignWords(text: String, samples: [Float], sampleRate: Double,
                                   language: String) async -> [NarrationWordTiming] {
        if let measured = await SpeechWordAligner.align(text: text, samples: samples,
                                                        sampleRate: sampleRate, language: language) {
            return measured
        }
        return await Task.detached(priority: .userInitiated) {
            AudioWordAligner.align(text: text, samples: samples, sampleRate: sampleRate)
        }.value
    }

    private static func buildSentences(from chapters: [ExtractedChapter]) -> [NarrationSentence] {
        var result: [NarrationSentence] = []
        for (chapterIndex, chapter) in chapters.enumerated() {
            let ns = chapter.text as NSString
            for range in SentenceTokenizer.ranges(from: chapter.text) {
                let text = ns.substring(with: range)
                result.append(NarrationSentence(id: result.count, chapterIndex: chapterIndex,
                                                text: text, chapterOffset: range.location,
                                                chapterLength: range.length))
            }
        }
        return result
    }

    private func move(to index: Int) {
        guard sentences.indices.contains(index) else { return }
        let wasPlaying = isPlaying
        stopAudio()
        isPlaying = false
        resetWordState()
        currentIndex = index
        narrationFinished = false
        chapterIndex = sentences[index].chapterIndex
        saveProgress()
        if wasPlaying { speakCurrent() }
    }

    private func speakCurrent(fromOffset offset: Int = 0, fromTime time: TimeInterval? = nil) {
        guard let book = activeBook, sentences.indices.contains(currentIndex) else { return }
        guard let voice = voices.narrationVoice(preferredID: book.preferredVoiceID,
                                                language: book.language) else {
            errorMessage = String(localized: "No voice is available for this document.")
            return
        }
        speakNeuralCurrent(voice: voice, fromOffset: offset, fromTime: time)
    }

    // MARK: Neural playback

    private func speakNeuralCurrent(voice: VoiceCatalog.Voice, fromOffset offset: Int,
                                    fromTime time: TimeInterval? = nil) {
        guard let book = activeBook, sentences.indices.contains(currentIndex) else { return }
        // The engine keeps running between sentences: with nothing playing
        // while the next one is made, iOS suspends a locked phone's app.
        stopAudio(keepingEngine: true)
        let sentence = sentences[currentIndex]
        let text = sentence.text
        let requested = max(offset, 0)
        let clamped = requested < (text as NSString).length ? requested : 0
        resetWordState()
        neuralPaused = false
        neuralStartOffset = clamped
        neuralPositionTime = time
        neuralPositionVoiceID = voice.id
        narrationFinished = false
        chapterIndex = sentence.chapterIndex
        isPlaying = true
        isLoading = true
        library.setReadingMode(book, mode: mode)
        saveProgress()
        updateNowPlaying()

        let token = UUID()
        neuralPlaybackToken = token
        let index = currentIndex
        neuralTask = Task { [weak self] in
            guard let self else { return }
            await self.prepareNeuralSentence(index: index, text: text, voice: voice,
                                             chapterIndex: sentence.chapterIndex,
                                             offset: clamped, audioTime: time, token: token)
        }
    }

    private func prepareNeuralSentence(index: Int, text: String, voice: VoiceCatalog.Voice,
                                       chapterIndex: Int, offset: Int, audioTime: TimeInterval?, token: UUID) async {
        guard let book = activeBook else { return }
        var cached: CachedNarration?
        if let ready = prefetched[index], ready.voiceID == voice.id {
            cached = ready.narration
        }
        prefetched = prefetched.filter { $0.key > index && $0.value.voiceID == voice.id }
        var restoredTime = audioTime
        if cached == nil, audioTime != nil {
            let cache = models.narrationCache
            let key = cache.key(text: text, engine: voice.engineRaw, voice: voice.id)
            cached = await cache.load(bookID: book.id, key: key)
            // Newly generated speech can have different timings (especially
            // on another device). Keep the word cursor if the original audio
            // has been evicted rather than seek into a different timeline.
            if cached == nil { restoredTime = nil }
        }
        if cached == nil {
            do {
                cached = try await narration(for: text, voice: voice, book: book)
            } catch {
                if !Task.isCancelled, token == neuralPlaybackToken {
                    isPlaying = false
                    isLoading = false
                    errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                }
                return
            }
        }
        guard !Task.isCancelled, token == neuralPlaybackToken, let cached else { return }
        guard cached.buffer.frameLength > 0 else {
            errorMessage = String(localized: "The neural engine returned no audio.")
            isPlaying = false
            isLoading = false
            return
        }
        neuralWords = cached.words
        neuralBufferDuration = cached.duration
        let start = restoredTime.flatMap { time in
            time.isFinite && time >= 0 && time < cached.duration ? time : nil
        } ?? startTime(for: offset, in: cached)
        neuralStartTime = start
        neuralPositionTime = start
        let buffer = slice(cached.buffer, from: start) ?? cached.buffer
        neuralBufferDuration = Double(buffer.frameLength) / cached.buffer.format.sampleRate

        configureAudioSession()
        guard startNeuralEngine() else {
            audioUnavailable()
            return
        }
        audioPlayer.stop()
        // Wait until the output has played, rather than just been consumed by
        // the render thread; stopping earlier truncates the tail and can click.
        audioPlayer.scheduleBuffer(buffer, at: nil, options: [], completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.neuralSentenceFinished(token: token)
            }
        }
        audioPlayer.play()
        isPlaying = true
        isLoading = false
        neuralPaused = false
        if let word = currentWordTiming(for: offset) {
            setNeuralWord(word)
        }
        startNeuralProgress()
        updateNowPlaying()
        schedulePrefetch(after: index, voice: voice)
    }

    /// The sentence's audio: from the cache, or synthesized now and cached.
    /// The cache is checked again once synthesis is free, so a sentence a
    /// prefetch has just made is not made twice.
    private func narration(for text: String, voice: VoiceCatalog.Voice,
                           book: Book) async throws -> CachedNarration {
        let cache = models.narrationCache
        let key = cache.key(text: text, engine: voice.engineRaw, voice: voice.id)
        if let cached = await cache.load(bookID: book.id, key: key) { return cached }
        return try await synthesisGate.run {
            if let cached = await cache.load(bookID: book.id, key: key) { return cached }
            let audio = try await self.withBackgroundTime {
                try await self.synthesizeUnlocked(text: text, voice: voice)
            }
            // Phonon returns the partial audio it managed to produce when a
            // task is cancelled. Never cache that as a complete sentence.
            try Task.checkCancellation()
            let words = await Self.alignWords(text: text, samples: audio.samples,
                                              sampleRate: audio.sampleRate, language: voice.language)
            try Task.checkCancellation()
            guard let buffer = self.makeBuffer(samples: audio.samples, sampleRate: audio.sampleRate) else {
                throw NeuralNarrationError.invalidAudio
            }
            let saved = await cache.save(bookID: book.id, key: key, buffer: buffer, words: words)
            if self.activeBook?.id == book.id { self.audioCacheBytes += saved }
            return CachedNarration(buffer: buffer, words: words,
                                   duration: Double(audio.samples.count) / max(audio.sampleRate, 1))
        }
    }

    /// Makes the next sentences while this one plays.
    private func schedulePrefetch(after index: Int, voice: VoiceCatalog.Voice) {
        guard let book = activeBook else { return }
        let last = min(index + Self.prefetchDepth, sentences.count - 1)
        guard last > index else { return }
        prefetchTask?.cancel()
        prefetchTask = Task { [weak self] in
            for target in (index + 1)...last {
                guard let self, !Task.isCancelled,
                      self.activeBook?.id == book.id, self.sentences.indices.contains(target) else { return }
                if let ready = self.prefetched[target], ready.voiceID == voice.id { continue }
                let text = self.sentences[target].text
                guard let made = try? await self.narration(for: text, voice: voice, book: book),
                      !Task.isCancelled, self.activeBook?.id == book.id else { return }
                self.prefetched[target] = (voice.id, made)
            }
        }
    }

    private func resetPrefetch() {
        prefetchTask?.cancel()
        prefetchTask = nil
        prefetched = [:]
    }

    /// The audio engine could not start (another app holds the audio, or iOS
    /// refused in the background). Pause cleanly: playing a node on a stopped
    /// engine raises an exception that closes the app.
    private func audioUnavailable() {
        audioPlayer.stop()
        neuralProgressTask?.cancel()
        neuralProgressTask = nil
        neuralPaused = false
        isPlaying = false
        isLoading = false
        restartOnResume = true
        saveProgress()
        updateNowPlaying()
    }

    /// Asks iOS for time to finish a synthesis if the app goes to the
    /// background meanwhile; the request always ends, even when iOS expires it.
    private func withBackgroundTime<T>(_ work: () async throws -> T) async rethrows -> T {
        #if os(iOS)
        let task = BackgroundTimeRequest()
        defer { task.end() }
        #endif
        return try await work()
    }

    private struct NeuralAudio {
        var samples: [Float]
        var sampleRate: Double
    }

    private func synthesize(text: String, voice: VoiceCatalog.Voice) async throws -> NeuralAudio {
        try await synthesisGate.run {
            try await self.synthesizeUnlocked(text: text, voice: voice)
        }
    }

    private func synthesizeUnlocked(text: String, voice: VoiceCatalog.Voice) async throws -> NeuralAudio {
        guard let engine = ModelManager.Engine(rawValue: voice.engineRaw) else {
            throw NeuralNarrationError.engineNotLoaded(voice.engineRaw)
        }
        let audio = try await models.synthesize(text, voiceID: voice.id, engine: engine)
        return NeuralAudio(samples: audio.samples, sampleRate: audio.sampleRate)
    }

    private func makeBuffer(samples: [Float], sampleRate: Double) -> AVAudioPCMBuffer? {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { pointer in
            if let base = pointer.baseAddress {
                channel.update(from: base, count: samples.count)
            }
        }
        return buffer
    }

    private func slice(_ buffer: AVAudioPCMBuffer, from time: TimeInterval) -> AVAudioPCMBuffer? {
        guard time > 0, let channel = buffer.floatChannelData?[0] else { return nil }
        let sampleRate = buffer.format.sampleRate
        let start = min(Int(time * sampleRate), Int(buffer.frameLength))
        let remaining = Int(buffer.frameLength) - start
        guard remaining > 0,
              let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let sliced = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(remaining)),
              let destination = sliced.floatChannelData?[0] else { return nil }
        destination.update(from: channel.advanced(by: start), count: remaining)
        // A word seek can land on a nonzero sample inside otherwise clean PCM.
        let fadeCount = min(Int(sampleRate * 0.010), remaining)
        if fadeCount > 1 {
            for index in 0..<fadeCount {
                let phase = Double(index) / Double(fadeCount - 1)
                destination[index] *= Float(0.5 - 0.5 * cos(.pi * phase))
            }
        }
        sliced.frameLength = AVAudioFrameCount(remaining)
        return sliced
    }

    private func startTime(for offset: Int, in cached: CachedNarration) -> TimeInterval {
        guard offset > 0 else { return 0 }
        if let word = cached.words.last(where: { $0.location <= offset }) {
            return word.start
        }
        let ns = currentSentenceText() as NSString
        let fraction = Double(min(offset, ns.length)) / Double(max(ns.length, 1))
        return cached.duration * fraction
    }

    private func currentWordTiming(for offset: Int) -> NarrationWordTiming? {
        neuralWords.last { $0.location <= offset }
    }

    private func currentSentenceText() -> String {
        guard sentences.indices.contains(currentIndex) else { return "" }
        return sentences[currentIndex].text
    }

    /// Starts the engine if needed and says whether it is running.
    @discardableResult
    private func startNeuralEngine() -> Bool {
        guard neuralFormat != nil else { return false }
        if !audioEngine.isRunning {
            try? audioEngine.start()
        }
        return audioEngine.isRunning
    }

    private func startNeuralProgress() {
        neuralProgressTask?.cancel()
        neuralProgressTask = Task { [weak self] in
            while !Task.isCancelled {
                // About one display frame: a 60 ms poll left the highlight up
                // to 60 ms behind the voice.
                try? await Task.sleep(for: .milliseconds(16))
                guard !Task.isCancelled, let self else { return }
                self.tickNeuralProgress()
            }
        }
    }

    private func tickNeuralProgress() {
        guard isPlaying, !neuralPaused,
              let nodeTime = audioPlayer.lastRenderTime,
              let playerTime = audioPlayer.playerTime(forNodeTime: nodeTime) else { return }
        let rendered = Double(playerTime.sampleTime) / max(playerTime.sampleRate, 1)
        // The player's clock counts audio handed to the hardware, which is
        // heard `outputLatency` later (a few ms on the speaker, ~0.2 s over
        // Bluetooth). The highlight itself reaches the screen a couple of
        // frames after it is set, so it is set that much ahead.
        let heard = rendered - outputLatency()
        neuralPositionTime = max(neuralStartTime, min(neuralStartTime + neuralBufferDuration,
                                                     neuralStartTime + heard))
        let absolute = neuralStartTime + heard + Self.highlightDisplayLead
        if let word = neuralWords.last(where: { $0.start <= absolute }) {
            setNeuralWord(word)
        }
    }

    /// Read the audio clock at the pause/close action, not just the last UI
    /// highlight (which is deliberately slightly ahead of audible playback).
    private func captureNarrationTime() {
        guard isPlaying, !neuralPaused, audioPlayer.isPlaying,
              let nodeTime = audioPlayer.lastRenderTime,
              let playerTime = audioPlayer.playerTime(forNodeTime: nodeTime) else { return }
        let heard = Double(playerTime.sampleTime) / max(playerTime.sampleRate, 1) - outputLatency()
        let time = max(neuralStartTime, min(neuralStartTime + neuralBufferDuration, neuralStartTime + heard))
        neuralPositionTime = time
        if let word = neuralWords.last(where: { $0.start <= time }) { setNeuralWord(word) }
    }

    /// Time from setting the word to it being drawn: the main-actor hop,
    /// the SwiftUI update and the next display refresh.
    private static let highlightDisplayLead: TimeInterval = 0.04

    private func outputLatency() -> TimeInterval {
        var latency = audioEngine.outputNode.presentationLatency
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        latency = max(latency, session.outputLatency + session.ioBufferDuration)
        #endif
        return max(0, min(latency, 0.5))
    }

    private func setNeuralWord(_ word: NarrationWordTiming) {
        let range = NSRange(location: word.location, length: word.length)
        guard range != currentWordRange else { return }
        currentWordRange = range
        let text = currentSentenceText() as NSString
        if NSMaxRange(range) <= text.length {
            currentWord = text.substring(with: range)
        }
    }

    private func neuralSentenceFinished(token: UUID) {
        guard token == neuralPlaybackToken, isPlaying, !neuralPaused else { return }
        neuralProgressTask?.cancel()
        neuralProgressTask = nil
        guard currentIndex + 1 < sentences.count else {
            finishBook()
            return
        }
        let nextIndex = currentIndex + 1
        let nextChapter = sentences[nextIndex].chapterIndex
        if sleepTimer == .endOfChapter, nextChapter != chapterIndex {
            pause()
            sleepTimer = .off
            return
        }
        currentIndex = nextIndex
        chapterIndex = nextChapter
        neuralPositionTime = nil
        neuralStartOffset = 0
        resetWordState()
        saveProgress()
        speakCurrent()
    }

    private func stopAudio(keepingEngine: Bool = false) {
        neuralTask?.cancel()
        neuralTask = nil
        neuralProgressTask?.cancel()
        neuralProgressTask = nil
        audioPlayer.stop()
        if !keepingEngine, audioEngine.isRunning { audioEngine.pause() }
        neuralPaused = false
        neuralWords = []
        neuralBufferDuration = 0
        neuralStartTime = 0
        neuralPositionTime = nil
        neuralPositionVoiceID = nil
        neuralStartOffset = 0
        neuralPlaybackToken = UUID()
        isLoading = false
    }

    private func sentenceIndex(chapter: Int, offset: Int) -> Int? {
        let target = max(0, offset)
        // A page can begin with whitespace between sentences. Start at the
        // next sentence instead of falling back to an old playback position.
        return sentences.firstIndex { sentence in
            sentence.chapterIndex == chapter &&
            target < sentence.chapterOffset + max(sentence.chapterLength, 1)
        } ?? sentences.lastIndex { $0.chapterIndex == chapter }
    }

    private func resetWordState() {
        currentWordRange = nil
        currentWord = nil
    }

    private func sentenceIndex(matching text: String) -> Int? {
        let target = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard target.count > 4 else { return nil }
        if let exact = sentences.firstIndex(where: {
            $0.text.trimmingCharacters(in: .whitespacesAndNewlines) == target
        }) {
            return exact
        }
        let prefix = String(target.prefix(48))
        return sentences.firstIndex(where: {
            $0.text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(prefix)
                || $0.text.contains(prefix)
        })
    }

    private func finishBook() {
        guard !sentences.isEmpty else { return }
        narrationFinished = true
        stopAudio()
        if let book = activeBook {
            let locator: ReadingLocator
            if book.format == .pdf {
                let lastPage = chapters.last?.id ?? max(book.locator.pageIndex ?? 0, 0)
                locator = ReadingLocator(chapterIndex: lastPage, scrollFraction: 1, pageIndex: lastPage)
            } else {
                locator = ReadingLocator(chapterIndex: max(chapters.count - 1, 0), scrollFraction: 1)
            }
            library.updateProgress(book, locator: locator, progress: 1, preservingNarrationPosition: false)
        }
        isPlaying = false
        resetWordState()
        updateNowPlaying()
    }

    private func saveProgress() {
        guard let book = activeBook, sentences.indices.contains(currentIndex),
              !narrationFinished else { return }
        let sentence = sentences[currentIndex]
        let pageOrChapter = book.format == .pdf && chapters.indices.contains(chapterIndex)
            ? chapters[chapterIndex].id : chapterIndex
        let position = NarrationPosition(
            chapterIndex: pageOrChapter,
            sentenceOffset: sentence.chapterOffset,
            characterOffset: sentence.chapterOffset + (currentWordRange?.location ?? neuralStartOffset),
            sentenceText: sentence.text,
            audioTime: neuralPositionTime,
            voiceID: neuralPositionTime == nil ? activeVoice?.id : neuralPositionVoiceID
        )
        if book.format == .pdf {
            // PDF chapters are stored by original page id, not by array index.
            let pageID = chapters.indices.contains(chapterIndex)
                ? chapters[chapterIndex].id
                : max(book.locator.pageIndex ?? 0, 0)
            let locator = ReadingLocator(chapterIndex: pageID, scrollFraction: chapterProgress,
                                         pageIndex: pageID, narrationPosition: position)
            library.updateProgress(book, locator: locator, progress: overallProgress)
            return
        }
        var locator = ReadingLocator(chapterIndex: chapterIndex, scrollFraction: chapterProgress,
                                     narrationPosition: position)
        locator.pageIndex = book.locator.pageIndex
        library.updateProgress(book, locator: locator, progress: overallProgress)
    }

    // MARK: Audio session and remote controls

    private func configureAudioSession() {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: [.allowBluetooth, .allowAirPlay])
        try? session.setActive(true)
        #endif
    }

    /// Narration is over (book closed or finished): give the audio session
    /// back so other apps resume and iOS stops showing Nodus as playing.
    private func deactivateAudioSession() {
        if audioEngine.isRunning { audioEngine.stop() }
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    private func configureRemoteCommands() {
        #if canImport(MediaPlayer) && os(iOS)
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.isEnabled = true
        center.pauseCommand.isEnabled = true
        center.togglePlayPauseCommand.isEnabled = true
        center.nextTrackCommand.isEnabled = true
        center.previousTrackCommand.isEnabled = true
        // The ±30 s skip buttons jumped whole chapters, which their icon does
        // not suggest; the lock screen shows previous/next sentence instead.
        center.skipForwardCommand.isEnabled = false
        center.skipBackwardCommand.isEnabled = false

        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.resume() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pause() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.toggle() }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.nextSentence() }
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.previousSentence() }
            return .success
        }
        center.skipForwardCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.nextChapter() }
            return .success
        }
        center.skipBackwardCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.previousChapter() }
            return .success
        }
        #endif
    }

    private func updateNowPlaying() {
        #if canImport(MediaPlayer) && os(iOS)
        guard let book = activeBook else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: book.title,
            MPMediaItemPropertyArtist: book.displayAuthor,
            MPMediaItemPropertyAlbumTitle: chapterTitle,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: Double(currentIndex),
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue
        ]
        info[MPNowPlayingInfoPropertyPlaybackQueueCount] = sentences.count
        info[MPNowPlayingInfoPropertyPlaybackQueueIndex] = currentIndex
        if let artwork = artwork(for: book) {
            info[MPMediaItemPropertyArtwork] = artwork
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        #endif
    }

    #if canImport(MediaPlayer) && os(iOS)
    /// The book's cover, or the same typographic cover the library draws when
    /// the book has none (or it has not downloaded yet).
    private func artwork(for book: Book) -> MPMediaItemArtwork? {
        if let cached = nowPlayingArtwork, cached.bookID == book.id { return cached.artwork }
        let image = library.fileStore.coverURL(for: book.coverFileName)
            .flatMap { UIImage(contentsOfFile: $0.path) }
            ?? CoverGenerator.typographicCover(title: book.title, author: book.displayAuthor)
                .flatMap { UIImage(data: $0) }
        guard let image else { return nil }
        let artwork = Self.makeArtwork(image)
        nowPlayingArtwork = (book.id, artwork)
        return artwork
    }

    /// Built outside the main actor: MediaPlayer calls the image handler on
    /// its own queue.
    private nonisolated static func makeArtwork(_ image: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }
    #endif
}

enum NeuralNarrationError: LocalizedError {
    case engineNotLoaded(String)
    case invalidAudio

    var errorDescription: String? {
        switch self {
        case .engineNotLoaded(let engine):
            String(localized: "The \(engine) engine is not loaded. Open Settings › Voices & Models and install it again.")
        case .invalidAudio:
            String(localized: "The neural engine returned audio in an unsupported format.")
        }
    }
}


/// Serialises neural synthesis across playback and offline-cache generation.
/// Phonon keeps a single mutable voice per engine, so `setVoice` and `speak`
/// must run as one unit; Kokoro gets the same protection for predictable memory.
private actor SynthesisGate {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func run<T>(_ operation: () async throws -> T) async rethrows -> T {
        await acquire()
        do {
            let result = try await operation()
            release()
            return result
        } catch {
            release()
            throw error
        }
    }

    private func acquire() async {
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func release() {
        if waiters.isEmpty {
            busy = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

#if os(iOS)
/// A background-time request that is always ended: by its owner when the work
/// is done, or by iOS's expiration handler. An unended request gets the app
/// killed in the background.
@MainActor
private final class BackgroundTimeRequest {
    private var identifier: UIBackgroundTaskIdentifier = .invalid

    init() {
        identifier = UIApplication.shared.beginBackgroundTask(withName: "Narration") { [weak self] in
            MainActor.assumeIsolated { self?.end() }
        }
    }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}
#endif
