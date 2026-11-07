// SPDX-License-Identifier: AGPL-3.0-only
import Accelerate
import AVFoundation
import Foundation
import KokoroTTS
import Observation
import OSLog
import PhononTTS
#if canImport(MediaPlayer)
import MediaPlayer
#endif
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
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
    @ObservationIgnored let models: ModelManager
    let offlineAudio: OfflineNarrationQueue

    #if canImport(MediaPlayer)
    /// System Now Playing artwork, built once per book.
    @ObservationIgnored private var nowPlayingArtwork: (bookID: UUID, artwork: MPMediaItemArtwork)?
    #endif
    @ObservationIgnored private let audioEngine = AVAudioEngine()
    @ObservationIgnored private let audioPlayer = AVAudioPlayerNode()
    @ObservationIgnored private let timePitch = AVAudioUnitTimePitch()
    @ObservationIgnored private let neuralFormat = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)
    @ObservationIgnored private var neuralTask: Task<Void, Never>?
    /// Sentences made ahead of the one playing (by index, with the voice that
    /// made them), so the next sentence starts without waiting for synthesis.
    @ObservationIgnored private var prefetched: [Int: (voiceID: String, key: String, narration: CachedNarration)] = [:]
    @ObservationIgnored private let prefetchWorker = NarrationPrefetchWorker()
    @ObservationIgnored private var prefetchContext: String?
    @ObservationIgnored private var neuralProgressTask: Task<Void, Never>?
    @ObservationIgnored private var samplePlayer: AVAudioPlayer?
    @ObservationIgnored private var sampleTask: Task<Void, Never>?
    @ObservationIgnored private var sampleToken = UUID()
    @ObservationIgnored private var neuralWords: [NarrationWordTiming] = []
    @ObservationIgnored private var neuralBufferDuration: TimeInterval = 0
    @ObservationIgnored private var neuralStartTime: TimeInterval = 0
    /// Gapless narration: the next sentence queued behind the one playing, the player
    /// clock offset of the sentence playing, and the voice and book they were made for.
    @ObservationIgnored private var chained: (index: Int, voiceID: String, key: String, narration: CachedNarration,
                                              duration: TimeInterval, silence: TimeInterval)?
    @ObservationIgnored private var timeline = NarrationTimeline()
    /// The next sentence is being prepared because the previous one ended (not a start,
    /// seek or voice change): only then may Low Power Mode wait to play two at once.
    @ObservationIgnored private var continuingNarration = false
    @ObservationIgnored private var scheduledVoice: VoiceCatalog.Voice?
    /// Absolute time in the full sentence, without the highlight's visual lead.
    @ObservationIgnored private var neuralPositionTime: TimeInterval?
    @ObservationIgnored private var neuralPositionVoiceID: String?
    @ObservationIgnored private var neuralPositionAudioKey: String?
    @ObservationIgnored private var neuralStartOffset: Int = 0
    @ObservationIgnored private var neuralPlaybackToken = UUID()
    @ObservationIgnored private var neuralPaused = false
    @ObservationIgnored private var loadToken = UUID()
    @ObservationIgnored private var progressSaves = ProgressSaveThrottle()
    @ObservationIgnored private var restartOnResume = false
    @ObservationIgnored private var restartVoiceOnResume = false
    @ObservationIgnored private var readerResumePosition: (bookID: UUID, chapterIndex: Int, offset: Int)?
    @ObservationIgnored private var pendingChapterSeek: (chapter: Int, offset: Int?, fraction: Double)?
    @ObservationIgnored private var voiceChangeObserver: NSObjectProtocol?
    @ObservationIgnored private var libraryDeletionObserver: NSObjectProtocol?
    @ObservationIgnored private var readingPositionObserver: NSObjectProtocol?
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
    public private(set) var isLoading = false { didSet { updateEngineUse() } }
    public private(set) var narrationFinished = false
    /// The loudest sample of the sentence playing (0…1). Immersive Audio keeps
    /// its own mix below what is left, so narration plus music never clips.
    public private(set) var narrationPeak: Float = 0
    /// Narration was stopped by the system rebuilding the audio output (a
    /// new route or device); it restarts the sentence on its own.
    @ObservationIgnored private var stoppedByEngine = false
    @ObservationIgnored private var engineConfigurationObserver: NSObjectProtocol?
    public private(set) var isPlayingSample = false {
        didSet { updateEngineUse() }
    }

    /// Tells the model manager whether narration needs the neural engine to
    /// stay in memory (it is released a few minutes after playback stops).
    private func updateEngineUse() {
        let busy = isPlaying || isPlayingSample || isPreparingSample
        models.setNarrationInUse(busy)
        offlineAudio.setInteractiveBusy(isPreparingSample || isPlayingSample || (isPlaying && isLoading))
    }
    public private(set) var sampleVoiceID: String?
    /// The sample of `sampleVoiceID` is still being synthesised (a neural
    /// model may first have to load): its play button shows progress.
    public private(set) var isPreparingSample = false {
        didSet { updateEngineUse() }
    }
    public private(set) var currentWordRange: NSRange?
    public private(set) var currentWord: String?
    public private(set) var audioCacheBytes: Int64 = 0
    public var audioCacheProgress: Double? { currentAudioJob?.progress }
    public var isGeneratingAudioCache: Bool {
        currentAudioJob.map { [.queued, .generating, .waiting, .caughtUp].contains($0.state.status) } ?? false
    }
    var currentAudioJob: OfflineNarrationQueue.Job? {
        offlineAudio.jobs.last { $0.plan.bookID == activeBook?.id && $0.plan.voiceID == activeVoiceID }
    }
    public var errorMessage: String?
    public var cacheErrorMessage: String?
    public var mode: ReadingMode = .listen {
        didSet {
            #if os(macOS)
            if oldValue != mode { updateNowPlaying() }
            #endif
        }
    }
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
        self.offlineAudio = OfflineNarrationQueue(root: library.fileStore.root.appendingPathComponent("AudioJobs", isDirectory: true),
                                                  cache: models.narrationCache)
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
                guard let self else { return }
                if let activeID = self.activeBook?.id, ids.contains(activeID) { self.forgetDeletedBook() }
                let jobs = self.offlineAudio.jobs.filter { ids.contains($0.plan.bookID) }
                for job in jobs { await self.offlineAudio.remove(job.id, deletingAudio: true) }
            }
        }
        voiceChangeObserver = NotificationCenter.default.addObserver(
            forName: .nodusVoiceEngineChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.stopSamplePlayback()
                guard self.activeBook != nil else { return }
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
        observePronunciations()
        configureRemoteCommands()
        #if os(iOS)
        observeAudioSession()
        #endif
        observeEngineConfiguration()
        offlineAudio.configure(available: { [weak self] plan in
            guard let self else { return false }
            if self.isPlaying, self.activeBook?.id != plan.bookID || self.activeVoiceID != plan.voiceID { return false }
            return self.library.allBooks().contains(where: { $0.id == plan.bookID }) && self.voices.voice(withID: plan.voiceID) != nil
        }, idle: { [weak self] in
            guard let self else { return false }
            return !self.isLoading && !self.isPreparingSample && !self.isPlayingSample && !self.models.isSynthesizing && self.models.loadingEngine == nil
        }, validate: { [weak self] plan in
            guard let book = self?.library.allBooks().first(where: { $0.id == plan.bookID }),
                  book.contentHash == plan.bookHash, book.pronunciationsJSON == plan.pronunciationRevision else {
                throw OfflineNarrationQueue.QueueError.bookChanged
            }
        }, render: { [weak self] plan, sentence in
            guard let self, let book = self.library.allBooks().first(where: { $0.id == plan.bookID }),
                  book.contentHash == plan.bookHash, book.pronunciationsJSON == plan.pronunciationRevision,
                  let voice = self.voices.voice(withID: plan.voiceID) else { throw OfflineNarrationQueue.QueueError.bookChanged }
            _ = try await self.narration(for: sentence.text, voice: voice, book: book, background: true)
        })
        observeOfflineResources()
        readingPositionObserver = NotificationCenter.default.addObserver(forName: .nodusReadingPositionChanged, object: nil, queue: .main) { [weak self] notification in
            guard let bookID = notification.userInfo?["bookID"] as? UUID,
                  let chapter = notification.userInfo?["chapter"] as? Int else { return }
            let fraction = notification.userInfo?["fraction"] as? Double ?? 0
            let offset = notification.userInfo?["offset"] as? Int
            Task { @MainActor [weak self] in
                self?.offlineAudio.updateReadingPosition(bookID: bookID, chapterIndex: chapter, fraction: fraction, offset: offset)
            }
        }
    }

    private func observeOfflineResources() {
        withObservationTracking {
            _ = models.isSynthesizing
            _ = models.loadingEngine
            _ = voices.allInstalledVoices
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.offlineAudio.resourcesDidChange()
                self?.observeOfflineResources()
            }
        }
    }

    /// The output changed under a running engine (headphones, AirPlay, a new
    /// Mac output device): the system stops it. Restart the sentence where
    /// it was instead of skipping or going silent.
    private func observePronunciations() {
        let observedID = activeBook?.id
        let previousRules = activeBook?.pronunciations ?? []
        let previousJSON = activeBook?.pronunciationsJSON
        withObservationTracking {
            _ = activeBook?.pronunciationsJSON
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.activeBook?.id == observedID else { self.observePronunciations(); return }
                // SwiftData reports a change whenever the book is saved (progress, every
                // sentence): only a real change of rules may discard the prepared
                // sentences, or the voice ran out of them and paused every few seconds.
                guard self.activeBook?.pronunciationsJSON != previousJSON else {
                    self.observePronunciations()
                    return
                }
                self.resetPrefetch()
                guard let book = self.activeBook, self.sentences.indices.contains(self.currentIndex),
                      PronunciationTransformer.prepare(self.sentences[self.currentIndex].text, rules: previousRules).signature !=
                      PronunciationTransformer.prepare(self.sentences[self.currentIndex].text, rules: book.pronunciations).signature else {
                    self.observePronunciations()
                    return
                }
                let offset = self.currentWordRange?.location ?? self.neuralStartOffset
                let playing = self.isPlaying
                self.stopAudio()
                self.isPlaying = false
                self.neuralPositionTime = nil
                self.neuralStartOffset = offset
                self.restartVoiceOnResume = !playing
                if playing { self.speakCurrent(fromOffset: offset) }
                self.observePronunciations()
            }
        }
    }

    private func pronunciationKey(_ text: String, voice: VoiceCatalog.Voice, book: Book) -> String {
        models.narrationCache.key(text: text, engine: voice.engineRaw, voice: voice.id,
            pronunciation: PronunciationTransformer.prepare(text, rules: book.pronunciations + (voice.engineRaw == "linnet" ? LinnetText.rules(text) : [])).signature)
    }

    private func observeEngineConfiguration() {
        engineConfigurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: audioEngine,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.activeBook != nil else { return }
                let wasPlaying = (self.isPlaying && !self.neuralPaused) || self.stoppedByEngine
                self.stoppedByEngine = false
                guard wasPlaying else { return }
                if self.isPlaying { self.audioUnavailable() }
                self.resume()
            }
        }
    }

    /// `buffer` in `format`, or the buffer itself when it already matches.
    nonisolated static func converted(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard buffer.format.sampleRate != format.sampleRate
                || buffer.format.channelCount != format.channelCount else { return buffer }
        guard let converter = AVAudioConverter(from: buffer.format, to: format) else { return nil }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 1_024
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .endOfStream
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, error == nil, output.frameLength > 0 else { return nil }
        return output
    }

    /// Largest absolute sample of a mono buffer.
    nonisolated static func peak(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var peak: Float = 0
        vDSP_maxmgv(channel, 1, &peak, vDSP_Length(buffer.frameLength))
        return min(peak, 1)
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
                    self.resumeAfterInterruption = self.isPlaying || self.stoppedByEngine
                    self.stoppedByEngine = false
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
    public var playbackActionSymbol: String {
        if narrationFinished { return "arrow.counterclockwise" }
        return isPlaying ? "pause.fill" : "play.fill"
    }
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

    private let voiceResolver = VoiceSelectionResolver()

    public var activeVoice: VoiceCatalog.Voice? {
        guard let book = activeBook else { return voices.defaultVoice }
        return voiceResolver.resolve(book: book, catalog: voices, commit: false)
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
        return activeVoice?.id != id
    }

    public var engineLabel: String {
        activeVoice?.engineLabel ?? String(localized: "No voice model")
    }

    /// Narration is always neural now; false only while no model is installed.
    public var isNeuralVoice: Bool { activeVoice != nil }

    /// Lab diagnostics: what is prefetched relative to the sentence playing.
    public var prefetchDescription: String {
        let ahead = prefetched.keys.sorted().map { "+\($0 - currentIndex)" }.joined(separator: ",")
        return "sentence \(currentIndex), prefetched [\(ahead)], worker \(prefetchWorker.isRunning ? "running" : "idle"), "
            + "chained \(chained.map { "\($0.index)" } ?? "-"), loading \(isLoading)"
    }

    /// Seconds of neural narration ready ahead of the listener: the rest of the sentence
    /// playing plus the consecutive sentences already synthesized. Nil when nothing
    /// neural is playing. AI soundscapes compose only with a cushion.
    public var narrationBufferedAhead: TimeInterval? {
        guard isPlaying, !neuralPaused, neuralBufferDuration > 0 else { return nil }
        let heard = (neuralPositionTime ?? neuralStartTime) - neuralStartTime
        var ahead = max(0, neuralBufferDuration - heard)
        var index = currentIndex + 1
        while let ready = prefetched[index] {
            ahead += ready.narration.duration
            index += 1
        }
        return ahead / max(speedMultiplier, 0.5)
    }

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
        if mode != .read,
           voices.defaultVoiceID.hasPrefix("com.apple") || book.preferredVoiceID?.hasPrefix("com.apple") == true || voices.allInstalledVoices.isEmpty {
            await voices.loadIfNeeded()
        }
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
        _ = voiceResolver.resolve(book: book, catalog: voices, commit: true)
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
                   let voice = activeVoice, saved.voiceID == voice.id,
                   (saved.audioKey == pronunciationKey(sentence.text, voice: voice, book: book) ||
                    (saved.audioKey == nil && PronunciationTransformer.prepare(sentence.text, rules: book.pronunciations).signature.isEmpty)),
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
        suspendPrefetch()
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
        saveProgress(immediate: true)
    }

    public func resume() {
        guard let book = activeBook else { return }
        if narrationFinished {
            guard let first = sentences.first else { return }
            // A completed narration replays the document, rather than the last
            // sentence. Pauses and explicit seeks keep their existing position.
            stopAudio()
            resetPrefetch()
            resetWordState()
            currentIndex = 0
            chapterIndex = first.chapterIndex
            narrationFinished = false
            restartOnResume = false
            restartVoiceOnResume = false
            pendingChapterSeek = nil
            readerResumePosition = nil
            errorMessage = nil
            library.setStatus(book, status: .inProgress)
            saveProgress()
        }
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
                if let voice = activeVoice { schedulePrefetch(after: currentIndex, voice: voice) }
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
        let generation = deletedBookID.flatMap { offlineAudio.cancel(bookID: $0) }
        sleepTask?.cancel()
        sleepTask = nil
        sleepTimer = .off
        sleepEndsAt = nil
        stopAudio()
        isPlaying = false
        resetWordState()
        activeBook = nil
        narrationFinished = false
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
                _ = await generation?.value
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
            activeBook = nil
            narrationFinished = false
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
        stopSamplePlayback()
        if let engine = ModelManager.Engine(rawValue: voice.engineRaw) {
            models.prepareForVoiceChange(to: engine)
        }
        library.setPreferredVoice(book, voiceID: voice.id, voice: voice)
        voiceResolver.clear(bookID: book.id)
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

    public func playSample(voice: VoiceCatalog.Voice, text: String? = nil) {
        if isPlaying { pause() }
        configureAudioSession()
        samplePlayer?.stop()
        sampleTask?.cancel()
        let token = UUID()
        sampleToken = token
        let sample = text ?? (voice.language.hasPrefix("es")
            ? "Así suena esta voz al narrar tu biblioteca en Nodus Reader."
            : "This is how this voice sounds reading your library in Nodus Reader.")
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
                    if token == self.sampleToken {
                        self.isPreparingSample = false
                        self.isPlayingSample = false
                    }
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
                    if !Task.isCancelled { self.errorMessage = error.localizedDescription }
                }
            }
        }
    }

    /// Stops the sample being prepared or played.
    func previewPronunciation(_ text: String, book: Book) {
        let voice = activeBook?.id == book.id ? activeVoice : voiceResolver.resolve(book: book, catalog: voices, commit: true)
        if let voice = voice ?? activeVoice { playSample(voice: voice, text: text) }
        else { errorMessage = String(localized: "Install a voice model to preview pronunciation.") }
    }

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

    func generateAudioCacheForCurrentBook(paragraphsPerBlock: Int = 10) {
        guard let book = activeBook, let voice = activeVoice else {
            errorMessage = String(localized: "Choose a voice before generating audio.")
            return
        }
        cacheErrorMessage = nil
        do {
            let plan = OfflineNarrationPlan.make(book: book, chapters: chapters, voice: voice,
                                                  paragraphsPerBlock: paragraphsPerBlock, cache: models.narrationCache)
            try offlineAudio.enqueue(plan)
        } catch { cacheErrorMessage = error.localizedDescription }
    }

    func enqueueOfflineAudio(book: Book, voice: VoiceCatalog.Voice, paragraphsPerBlock: Int, lookAhead: Int? = nil) async throws {
        let chapters = try await BookTextLoader.loadChapters(for: book, fileStore: library.fileStore)
        let plan = OfflineNarrationPlan.make(book: book, chapters: chapters, voice: voice,
                                              paragraphsPerBlock: paragraphsPerBlock, cache: models.narrationCache)
        try offlineAudio.enqueue(plan, lookAhead: lookAhead)
        offlineAudio.updateReadingPosition(bookID: book.id, chapterIndex: book.locator.chapterIndex, fraction: book.locator.scrollFraction)
    }

    func cancelAudioCacheGeneration() {
        cacheErrorMessage = nil
        if let bookID = activeBook?.id { _ = offlineAudio.cancel(bookID: bookID) }
    }

    func deleteAudioCacheForCurrentBook() async {
        guard let book = activeBook else { return }
        let playback = neuralTask
        let prefetch = suspendPrefetch()
        let generation = offlineAudio.cancel(bookID: book.id)
        await playback?.value
        await prefetch?.value
        await generation?.value
        await models.narrationCache.deleteBook(bookID: book.id)
        offlineAudio.resetProgress(bookID: book.id)
        await refreshAudioCacheSize()
    }

    func deleteAllNarrationCaches() async {
        let playback = neuralTask
        let prefetch = suspendPrefetch()
        let generation = offlineAudio.pauseAll()
        await playback?.value
        await prefetch?.value
        await generation?.value
        await models.narrationCache.deleteAll()
        offlineAudio.resetProgress(bookID: nil)
        audioCacheBytes = 0
    }

    // MARK: Internals

    /// Word timings for the read-along highlight: measured by on-device
    /// speech recognition where the system offers it, otherwise estimated from
    /// the pauses in the audio.
    private static func alignWords(text: String, samples: [Float], sampleRate: Double,
                                   language: String,
                                   timeLimit: Duration = SpeechWordAligner.timeLimit) async -> [NarrationWordTiming] {
        if let measured = await SpeechWordAligner.align(text: text, samples: samples,
                                                        sampleRate: sampleRate, language: language,
                                                        timeLimit: timeLimit) {
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
        guard let voice = voiceResolver.resolve(book: book, catalog: voices, commit: true) else {
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
        // A prefetched sentence is already in memory. Do not flash
        // "generating" during the handoff; only show it when synthesis is
        // really needed.
        let readyKey = pronunciationKey(text, voice: voice, book: book)
        let prefetchedReady = prefetched[currentIndex].map {
            $0.voiceID == voice.id && $0.key == readyKey
        } ?? false
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
        isLoading = !prefetchedReady
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
        let continuing = continuingNarration
        continuingNarration = false
        let expectedKey = pronunciationKey(text, voice: voice, book: book)
        var cached: CachedNarration?
        if let ready = prefetched[index], ready.voiceID == voice.id, ready.key == expectedKey {
            cached = ready.narration
        }
        prefetched = prefetched.filter { $0.key > index && $0.value.voiceID == voice.id }
        var restoredTime = audioTime
        if cached == nil, audioTime != nil {
            let cache = models.narrationCache
            cached = await cache.load(bookID: book.id, key: expectedKey)
            // Newly generated speech can have different timings (especially
            // on another device). Keep the word cursor if the original audio
            // has been evicted rather than seek into a different timeline.
            if cached == nil { restoredTime = nil }
        }
        let wasMiss = cached == nil
        if cached == nil {
            isLoading = true
            Logger(subsystem: "ai.nodus.reader", category: "NarrationQueue").info("Waiting for uncached sentence index=\(index)")
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
        guard !Task.isCancelled, token == neuralPlaybackToken,
              pronunciationKey(text, voice: voice, book: book) == expectedKey, let cached else { return }
        if wasMiss, continuing, ProcessInfo.processInfo.isLowPowerModeEnabled, sentences.indices.contains(index + 1) {
            // Low Power Mode slows synthesis below real time: rather than stopping after
            // every sentence, wait a little for the next one too and play both gaplessly.
            schedulePrefetch(after: index, voice: voice)
            let deadline = Date().addingTimeInterval(min(cached.duration, 8))
            while prefetched[index + 1] == nil, Date() < deadline, !Task.isCancelled, token == neuralPlaybackToken {
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard !Task.isCancelled, token == neuralPlaybackToken else { return }
        }
        guard cached.buffer.frameLength > 0 else {
            errorMessage = String(localized: "The neural engine returned no audio.")
            isPlaying = false
            isLoading = false
            return
        }
        neuralPositionAudioKey = expectedKey
        neuralWords = cached.words
        neuralBufferDuration = cached.duration
        narrationPeak = Self.peak(of: cached.buffer)
        let start = restoredTime.flatMap { time in
            time.isFinite && time >= 0 && time < cached.duration ? time : nil
        } ?? startTime(for: offset, in: cached)
        neuralStartTime = start
        neuralPositionTime = start
        let sliced = slice(cached.buffer, from: start) ?? cached.buffer
        neuralBufferDuration = Double(sliced.frameLength) / cached.buffer.format.sampleRate
        // The player is wired at 24 kHz and does not convert scheduled buffers
        // (only files): Ming's 44.1 kHz speech is converted here, or it would
        // play slow and low with a drifting word clock.
        let buffer = neuralFormat.flatMap { Self.converted(sliced, to: $0) } ?? sliced

        configureAudioSession()
        guard startNeuralEngine() else {
            audioUnavailable()
            return
        }
        audioPlayer.stop()
        chained = nil
        timeline.reset()
        scheduledVoice = voice
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
        chainNext(after: index, voice: voice, book: book, token: token)
    }

    /// Queues the next sentence behind the one playing when it is already made (same
    /// voice and pronunciation, same chapter), so the player never stops between them.
    /// A new paragraph gets a short pause.
    private func chainNext(after index: Int, voice: VoiceCatalog.Voice, book: Book, token: UUID) {
        guard chained == nil, index == currentIndex, isPlaying, !neuralPaused, token == neuralPlaybackToken,
              scheduledVoice?.id == voice.id, activeBook?.id == book.id, audioEngine.isRunning,
              sentences.indices.contains(index + 1) else { return }
        let next = index + 1
        let key = pronunciationKey(sentences[next].text, voice: voice, book: book)
        guard let ready = prefetched[next], ready.voiceID == voice.id, ready.key == key,
              ready.narration.buffer.frameLength > 0 else { return }
        let chapterIndex = sentences[index].chapterIndex
        let chapterText = chapters.indices.contains(chapterIndex) ? chapters[chapterIndex].text : ""
        guard case .chain(let silence) = NarrationChain.plan(current: sentences[index], next: sentences[next],
                                                             chapterText: chapterText, nextReady: true,
                                                             stopsAtChapterEnd: sleepTimer == .endOfChapter) else { return }
        let buffer = neuralFormat.flatMap { Self.converted(ready.narration.buffer, to: $0) } ?? ready.narration.buffer
        if silence > 0, let pause = AVAudioPCMBuffer(pcmFormat: buffer.format,
                                                       frameCapacity: AVAudioFrameCount(silence * buffer.format.sampleRate)) {
            pause.frameLength = pause.frameCapacity
            for channel in 0 ..< Int(buffer.format.channelCount) {
                pause.floatChannelData?[channel].update(repeating: 0, count: Int(pause.frameLength))
            }
            audioPlayer.scheduleBuffer(pause, completionHandler: nil)
        }
        audioPlayer.scheduleBuffer(buffer, at: nil, options: [], completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.neuralSentenceFinished(token: token)
            }
        }
        chained = (next, voice.id, key, ready.narration,
                   Double(buffer.frameLength) / buffer.format.sampleRate, silence)
    }

    /// The sentence's audio: from the cache, or synthesized now and cached.
    /// The cache is checked again once synthesis is free, so a sentence a
    /// prefetch has just made is not made twice.
    private func narration(for text: String, voice: VoiceCatalog.Voice,
                           book: Book, background: Bool = false,
                           prefetch: Bool = false) async throws -> CachedNarration {
        let cache = models.narrationCache
        let revision = book.pronunciationsJSON
        let prepared = PronunciationTransformer.prepare(text, rules: book.pronunciations + (voice.engineRaw == "linnet" ? LinnetText.rules(text) : []))
        let key = pronunciationKey(text, voice: voice, book: book)
        if let cached = await cache.load(bookID: book.id, key: key) { return cached }
        // Prefetch must not sit on the synthesis gate waiting for precise
        // speech recognition: recognition normally takes 0.15–0.5 s, but it
        // can take up to the full limit and that is exactly the small pause
        // heard before a short next sentence. Fall back to the pause-based
        // estimate after a shorter budget; the current sentence keeps the
        // full precision budget.
        let alignmentLimit: Duration = prefetch ? .milliseconds(700) : SpeechWordAligner.timeLimit
        return try await synthesisGate.run(background: background) {
            // A seek/stop can cancel a producer while it is queued behind
            // playback or an offline job. Don't start new synthesis afterward.
            try Task.checkCancellation()
            if background, self.isLoading || self.isPreparingSample || self.isPlayingSample ||
                (self.isPlaying && (self.activeBook?.id != book.id || self.activeVoiceID != voice.id)) { throw CancellationError() }
            if let cached = await cache.load(bookID: book.id, key: key) { return cached }
            try Task.checkCancellation()
            let audio = try await self.withBackgroundTime {
                try await self.synthesizeUnlocked(text: prepared.spoken, voice: voice)
            }
            // Phonon returns the partial audio it managed to produce when a
            // task is cancelled. Never cache that as a complete sentence.
            try Task.checkCancellation()
            let aligned: [NarrationWordTiming]
            if let words = audio.words { aligned = words }
            else if audio.checkedWords { aligned = AudioWordAligner.align(text: prepared.spoken, samples: audio.samples, sampleRate: audio.sampleRate) }
            else { aligned = await Self.alignWords(text: prepared.spoken, samples: audio.samples, sampleRate: audio.sampleRate, language: voice.language, timeLimit: alignmentLimit) }
            guard book.pronunciationsJSON == revision else { throw CancellationError() }
            let words = prepared.project(aligned)
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

    /// Keeps up to thirty seconds of future playback ready. Advancing normally
    /// changes demand without cancelling an in-flight sentence.
    private func schedulePrefetch(after index: Int, voice: VoiceCatalog.Voice) {
        guard index == currentIndex, let book = activeBook else { return }
        let context = "\(book.id)|\(voice.id)|\(book.pronunciationsJSON)"
        if prefetchContext != context {
            resetPrefetch()
            prefetchContext = context
        }
        prefetchWorker.start(next: { [weak self] in
            guard let self, self.isPlaying, !self.neuralPaused,
                  self.activeBook?.id == book.id, self.prefetchContext == context else { return nil }
            let start = self.currentIndex + 1
            guard start < self.sentences.count else { return nil }
            let end = min(start + 24, self.sentences.count)
            let durations: [TimeInterval?] = (start..<end).map { target in
                guard let ready = self.prefetched[target], ready.voiceID == voice.id,
                      ready.key == self.pronunciationKey(self.sentences[target].text, voice: voice, book: book) else { return nil }
                return ready.narration.duration
            }
            return NarrationPrefetchPolicy.nextOffset(durations: durations, rate: self.speedMultiplier).map { start + $0 }
        }, produce: { [weak self] target in
            guard let self else { throw CancellationError() }
            let text = self.sentences[target].text
            let key = self.pronunciationKey(text, voice: voice, book: book)
            let made = try await self.narration(for: text, voice: voice, book: book, prefetch: true)
            try Task.checkCancellation()
            guard self.activeBook?.id == book.id, self.prefetchContext == context,
                  self.pronunciationKey(text, voice: voice, book: book) == key else { throw CancellationError() }
            // The player may have consumed this sentence while synthesis was
            // finishing. Its disk cache remains useful; don't retain old PCM.
            if target > self.currentIndex {
                self.prefetched[target] = (voice.id, key, made)
                if target == self.currentIndex + 1 {
                    self.chainNext(after: self.currentIndex, voice: voice, book: book, token: self.neuralPlaybackToken)
                }
            }
        })
    }

    @discardableResult
    private func suspendPrefetch() -> Task<Void, Never>? {
        prefetchWorker.cancel()
    }

    private func resetPrefetch() {
        suspendPrefetch()
        prefetchContext = nil
        prefetched = [:]
    }

    /// The audio engine could not start (another app holds the audio, or iOS
    /// refused in the background). Pause cleanly: playing a node on a stopped
    /// engine raises an exception that closes the app.
    private func audioUnavailable() {
        suspendPrefetch()
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

    private typealias NeuralAudio = NarrationSynthesis

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
        return audio
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
        // frames after it is set, so it is set that much ahead. With gapless
        // narration the clock keeps running across queued sentences.
        let heard = timeline.heard(rendered: rendered, latency: outputLatency())
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
        let heard = timeline.heard(rendered: Double(playerTime.sampleTime) / max(playerTime.sampleRate, 1),
                                   latency: outputLatency())
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
        // A stopped engine (route or device change) completes its scheduled
        // buffers at once: that is not the end of the sentence.
        guard audioEngine.isRunning else {
            stoppedByEngine = true
            audioUnavailable()
            return
        }
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
        if let chain = chained, chain.index == nextIndex, let voice = scheduledVoice, let book = activeBook {
            // Already playing: move the state along without touching the player.
            chained = nil
            timeline.advance(past: neuralBufferDuration, silence: chain.silence)
            currentIndex = nextIndex
            chapterIndex = nextChapter
            prefetched[nextIndex] = nil
            resetWordState()
            neuralStartOffset = 0
            neuralStartTime = 0
            neuralPositionTime = 0
            neuralPositionVoiceID = chain.voiceID
            neuralPositionAudioKey = chain.key
            neuralWords = chain.narration.words
            neuralBufferDuration = chain.duration
            narrationPeak = Self.peak(of: chain.narration.buffer)
            saveProgress()
            updateNowPlaying()
            startNeuralProgress()
            schedulePrefetch(after: nextIndex, voice: voice)
            chainNext(after: nextIndex, voice: voice, book: book, token: neuralPlaybackToken)
            return
        }
        currentIndex = nextIndex
        chapterIndex = nextChapter
        neuralPositionTime = nil
        neuralStartOffset = 0
        resetWordState()
        saveProgress()
        continuingNarration = true
        speakCurrent()
    }

    private func stopAudio(keepingEngine: Bool = false) {
        if !keepingEngine { suspendPrefetch() }
        neuralTask?.cancel()
        neuralTask = nil
        neuralProgressTask?.cancel()
        neuralProgressTask = nil
        audioPlayer.stop()
        chained = nil
        timeline.reset()
        continuingNarration = false
        if !keepingEngine, audioEngine.isRunning { audioEngine.pause() }
        neuralPaused = false
        neuralWords = []
        neuralBufferDuration = 0
        neuralStartTime = 0
        neuralPositionTime = nil
        neuralPositionVoiceID = nil
        neuralPositionAudioKey = nil
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

    /// Saves the position on the device every time; while the voice plays, the iCloud
    /// upload waits up to a minute (a pause, a stop or leaving the app upload at once).
    private func saveProgress(immediate: Bool = false) {
        guard let book = activeBook, sentences.indices.contains(currentIndex),
              !narrationFinished else { return }
        let deferSync = !immediate && isPlaying
        // Every saved position redraws what shows the book (Home behind the
        // reader, and with it the reader and its sheets): while playing, the
        // position is written every few sentences. Pauses, closing and leaving
        // the app still save at once.
        guard progressSaves.shouldSave(playing: deferSync, now: Date()) else { return }
        let sentence = sentences[currentIndex]
        let pageOrChapter = book.format == .pdf && chapters.indices.contains(chapterIndex)
            ? chapters[chapterIndex].id : chapterIndex
        let position = NarrationPosition(
            chapterIndex: pageOrChapter,
            sentenceOffset: sentence.chapterOffset,
            characterOffset: sentence.chapterOffset + (currentWordRange?.location ?? neuralStartOffset),
            sentenceText: sentence.text,
            audioTime: neuralPositionTime,
            audioKey: neuralPositionAudioKey,
            voiceID: neuralPositionTime == nil ? activeVoice?.id : neuralPositionVoiceID
        )
        if book.format == .pdf {
            // PDF chapters are stored by original page id, not by array index.
            let pageID = chapters.indices.contains(chapterIndex)
                ? chapters[chapterIndex].id
                : max(book.locator.pageIndex ?? 0, 0)
            let locator = ReadingLocator(chapterIndex: pageID, scrollFraction: chapterProgress,
                                         pageIndex: pageID, narrationPosition: position)
            library.updateProgress(book, locator: locator, progress: overallProgress, deferredSync: deferSync)
            return
        }
        var locator = ReadingLocator(chapterIndex: chapterIndex, scrollFraction: chapterProgress,
                                     narrationPosition: position)
        locator.pageIndex = book.locator.pageIndex
        library.updateProgress(book, locator: locator, progress: overallProgress, deferredSync: deferSync)
    }

    // MARK: Audio session and remote controls

    private func configureAudioSession() {
        AudioSessionCoordinator.shared.claim(.narration)
    }

    /// Narration is over (book closed or finished): give the audio session
    /// back so other apps resume and iOS stops showing Nodus as playing
    /// (unless Immersive Audio is still playing under the reader).
    private func deactivateAudioSession() {
        if audioEngine.isRunning { audioEngine.stop() }
        AudioSessionCoordinator.shared.release(.narration)
    }

    private func configureRemoteCommands() {
        #if canImport(MediaPlayer)
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
        #if os(macOS)
        // There is no full-book time-based seek for generated narration.
        center.changePlaybackPositionCommand.isEnabled = false
        center.seekForwardCommand.isEnabled = false
        center.seekBackwardCommand.isEnabled = false
        center.stopCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.stopAndClose() }
            return .success
        }
        #endif

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
        #if os(macOS)
        updateNowPlaying()
        #endif
        #endif
    }

    private func updateNowPlaying() {
        #if canImport(MediaPlayer)
        let infoCenter = MPNowPlayingInfoCenter.default()
        #if os(macOS)
        let hasNarration = activeBook != nil && mode != .read && !sentences.isEmpty
        let commands = MPRemoteCommandCenter.shared()
        commands.playCommand.isEnabled = hasNarration
        commands.pauseCommand.isEnabled = hasNarration
        commands.togglePlayPauseCommand.isEnabled = hasNarration
        commands.nextTrackCommand.isEnabled = hasNarration
        commands.previousTrackCommand.isEnabled = hasNarration
        commands.stopCommand.isEnabled = hasNarration
        guard hasNarration else {
            infoCenter.playbackState = .stopped
            infoCenter.nowPlayingInfo = nil
            nowPlayingArtwork = nil
            return
        }
        #endif
        guard let book = activeBook else {
            infoCenter.nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: book.title,
            MPMediaItemPropertyArtist: book.displayAuthor,
            MPMediaItemPropertyAlbumTitle: chapterTitle,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue
        ]
        #if os(macOS)
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? speedMultiplier : 0.0
        info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = speedMultiplier
        // A sentence index is not elapsed seconds. Omit the timeline until
        // a complete narration duration is known.
        #else
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = Double(currentIndex)
        #endif
        info[MPNowPlayingInfoPropertyPlaybackQueueCount] = sentences.count
        info[MPNowPlayingInfoPropertyPlaybackQueueIndex] = currentIndex
        if let artwork = artwork(for: book) {
            info[MPMediaItemPropertyArtwork] = artwork
        }
        infoCenter.nowPlayingInfo = info
        #if os(macOS)
        // macOS has no AVAudioSession to infer this state from.
        infoCenter.playbackState = isPlaying ? .playing : (narrationFinished ? .stopped : .paused)
        #endif
        #endif
    }

    #if canImport(MediaPlayer)
    /// The book's cover, or the same typographic cover the library draws when
    /// the book has none (or it has not downloaded yet).
    private func artwork(for book: Book) -> MPMediaItemArtwork? {
        if let cached = nowPlayingArtwork, cached.bookID == book.id { return cached.artwork }
        #if os(macOS)
        let data = library.fileStore.coverURL(for: book.coverFileName)
            .flatMap { try? Data(contentsOf: $0) }
            .flatMap { NSImage(data: $0) == nil ? nil : $0 }
            ?? CoverGenerator.typographicCover(title: book.title, author: book.displayAuthor)
        guard let data, let image = NSImage(data: data) else { return nil }
        let artwork = Self.makeArtwork(data, boundsSize: image.size)
        #else
        let image = library.fileStore.coverURL(for: book.coverFileName)
            .flatMap { UIImage(contentsOfFile: $0.path) }
            ?? CoverGenerator.typographicCover(title: book.title, author: book.displayAuthor)
                .flatMap { UIImage(data: $0) }
        guard let image else { return nil }
        let artwork = Self.makeArtwork(image)
        #endif
        nowPlayingArtwork = (book.id, artwork)
        return artwork
    }

    /// Built outside the main actor: MediaPlayer calls the image handler on
    /// its own queue.
    #if os(macOS)
    private nonisolated static func makeArtwork(_ data: Data, boundsSize: CGSize) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: boundsSize) { size in
            // Decode per request instead of sharing a mutable NSImage across queues.
            NSImage(data: data) ?? NSImage(size: size)
        }
    }
    #else
    private nonisolated static func makeArtwork(_ image: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }
    #endif
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
            String(localized: "The voice could not generate usable audio. Try again or choose another voice.")
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

/// Spaces out the position saves made while narration plays; any other save
/// (a pause, a stop, leaving the app) goes through at once.
struct ProgressSaveThrottle {
    static let playingInterval: TimeInterval = 15
    private var lastPlayingSave: Date?

    mutating func shouldSave(playing: Bool, now: Date) -> Bool {
        guard playing else {
            lastPlayingSave = nil
            return true
        }
        if let last = lastPlayingSave, now.timeIntervalSince(last) < Self.playingInterval { return false }
        lastPlayingSave = now
        return true
    }
}
