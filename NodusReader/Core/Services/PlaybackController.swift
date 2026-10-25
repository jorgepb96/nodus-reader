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
        case .off: "Off"
        case .fiveMinutes: "5 minutes"
        case .fifteenMinutes: "15 minutes"
        case .thirtyMinutes: "30 minutes"
        case .fortyFiveMinutes: "45 minutes"
        case .sixtyMinutes: "60 minutes"
        case .endOfChapter: "End of chapter"
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

/// Local narration for system voices, Kokoro and Phonon. Neural audio uses an
/// AVAudioEngine graph and the same sentence/word state as the system voice.
@MainActor
@Observable
public final class PlaybackController {
    public static let speedOptions: [Double] = [0.75, 1.0, 1.25, 1.5, 1.75, 2.0]

    @ObservationIgnored private let library: LibraryService
    public let voices: VoiceCatalog
    @ObservationIgnored private let models: ModelManager
    @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()
    @ObservationIgnored private let sampleSynthesizer = AVSpeechSynthesizer()
    @ObservationIgnored private let speechDelegate = SpeechDelegate()

    @ObservationIgnored private let audioEngine = AVAudioEngine()
    @ObservationIgnored private let audioPlayer = AVAudioPlayerNode()
    @ObservationIgnored private let timePitch = AVAudioUnitTimePitch()
    @ObservationIgnored private let neuralFormat = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)
    @ObservationIgnored private var neuralTask: Task<Void, Never>?
    @ObservationIgnored private var neuralProgressTask: Task<Void, Never>?
    @ObservationIgnored private var cacheTask: Task<Void, Never>?
    @ObservationIgnored private var samplePlayer: AVAudioPlayer?
    @ObservationIgnored private var sampleTask: Task<Void, Never>?
    @ObservationIgnored private var sampleToken = UUID()
    @ObservationIgnored private var neuralWords: [NarrationWordTiming] = []
    @ObservationIgnored private var neuralBufferDuration: TimeInterval = 0
    @ObservationIgnored private var neuralStartTime: TimeInterval = 0
    @ObservationIgnored private var neuralStartOffset: Int = 0
    @ObservationIgnored private var neuralPlaybackToken = UUID()
    @ObservationIgnored private var neuralPaused = false
    @ObservationIgnored private var activeUtterance: AVSpeechUtterance?
    @ObservationIgnored private var loadToken = UUID()
    @ObservationIgnored private var cacheToken = UUID()
    @ObservationIgnored private var restartOnResume = false
    @ObservationIgnored private var restartVoiceOnResume = false
    @ObservationIgnored private var voiceChangeObserver: NSObjectProtocol?
    @ObservationIgnored private var libraryDeletionObserver: NSObjectProtocol?
    @ObservationIgnored private let synthesisGate = SynthesisGate()

    public private(set) var activeBook: Book?
    public private(set) var chapters: [ExtractedChapter] = []
    public private(set) var sentences: [NarrationSentence] = []
    public private(set) var currentIndex = 0
    public private(set) var chapterIndex = 0
    public private(set) var isPlaying = false
    public private(set) var isLoading = false
    public private(set) var isPlayingSample = false
    public private(set) var sampleVoiceID: String?
    public private(set) var currentWordRange: NSRange?
    public private(set) var currentWord: String?
    public private(set) var audioCacheBytes: Int64 = 0
    public private(set) var audioCacheProgress: Double?
    public private(set) var isGeneratingAudioCache = false
    public var errorMessage: String?
    public var cacheErrorMessage: String?
    public var mode: ReadingMode = .listen
    public var speedMultiplier: Double = 1.0
    public var sleepTimer: SleepTimerOption = .off
    public private(set) var sleepEndsAt: Date?

    @ObservationIgnored private var sleepTask: Task<Void, Never>?
    @ObservationIgnored private var resumeAfterInterruption = false
    @ObservationIgnored private var utteranceStartOffset = 0
    @ObservationIgnored private var interruptionObserver: NSObjectProtocol?
    @ObservationIgnored private var routeObserver: NSObjectProtocol?

    init(library: LibraryService, voices: VoiceCatalog, models: ModelManager) {
        self.library = library
        self.voices = voices
        self.models = models
        synthesizer.delegate = speechDelegate
        if let neuralFormat {
            audioEngine.attach(audioPlayer)
            audioEngine.attach(timePitch)
            audioEngine.connect(audioPlayer, to: timePitch, format: neuralFormat)
            audioEngine.connect(timePitch, to: audioEngine.mainMixerNode, format: neuralFormat)
            audioEngine.prepare()
        }
        speechDelegate.onFinish = { [weak self] utterance in
            Task { @MainActor [weak self] in
                self?.handleUtteranceFinished(utterance)
            }
        }
        speechDelegate.onCancel = { [weak self] utterance in
            Task { @MainActor [weak self] in
                guard let self, utterance === self.activeUtterance else { return }
                self.activeUtterance = nil
                guard !self.isNeuralVoice else { return }
                self.isPlaying = false
            }
        }
        speechDelegate.onWillSpeakRange = { [weak self] range, utterance in
            Task { @MainActor [weak self] in
                self?.handleWillSpeak(range, utterance: utterance)
            }
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
                let offset = self.currentWordRange?.location ?? 0
                if self.isPlaying {
                    self.stopAudio()
                    self.isPlaying = false
                    self.speakCurrent(fromOffset: offset)
                } else if self.audioPlayer.isPlaying || self.synthesizer.isSpeaking {
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
        activeVoice?.name ?? "System voice"
    }

    /// True when the book's synced voice is not installed on this device and a
    /// fallback voice is reading it instead.
    public var preferredVoiceIsMissing: Bool {
        guard let id = activeBook?.preferredVoiceID else { return false }
        return voices.voice(withID: id) == nil
    }

    public var engineLabel: String {
        activeVoice?.engineLabel ?? "System"
    }

    public var isNeuralVoice: Bool {
        activeVoice?.isSystem == false
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
        if activeBook?.id == book.id {
            self.mode = mode
            if let startingChapterIndex, let startingChapterOffset,
               let found = sentenceIndex(chapter: startingChapterIndex, offset: startingChapterOffset) {
                let offset = startingChapterOffset - sentences[found].chapterOffset
                stopAudio()
                isPlaying = false
                currentIndex = found
                chapterIndex = sentences[found].chapterIndex
                library.setReadingMode(book, mode: mode)
                mode == .read ? pause() : speakCurrent(fromOffset: offset)
                return
            }
            if let startingSentence,
               let index = sentenceIndex(matching: startingSentence) {
                stopAudio()
                isPlaying = false
                currentIndex = index
                chapterIndex = sentences[index].chapterIndex
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
        self.mode = mode
        isLoading = true
        errorMessage = nil

        do {
            // The neural catalogue is published at launch, so `voices` may not
            // be empty while the system voice list has never been enumerated.
            // Always ask; loadIfNeeded is a no-op once system voices exist.
            await voices.loadIfNeeded()
            guard token == loadToken, activeBook?.id == book.id else { return }
            let loaded = try await BookTextLoader.loadChapters(for: book, fileStore: library.fileStore)
            guard token == loadToken, activeBook?.id == book.id else { return }
            guard !loaded.isEmpty else {
                throw ImportError.emptyDocument(book.title)
            }
            chapters = loaded
            sentences = Self.buildSentences(from: loaded)
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
            currentIndex = sentences.firstIndex { $0.chapterIndex == resumeChapter } ?? 0
            var startOffset = 0
            if let startingChapterIndex, let startingChapterOffset,
               let found = sentenceIndex(chapter: startingChapterIndex, offset: startingChapterOffset) {
                currentIndex = found
                startOffset = max(0, startingChapterOffset - sentences[found].chapterOffset)
            } else if let startingSentence, let index = sentenceIndex(matching: startingSentence) {
                currentIndex = index
                startOffset = wordOffset
            }
            chapterIndex = sentences[currentIndex].chapterIndex
            isLoading = false
            library.setReadingMode(book, mode: mode)
            library.open(book)
            if mode != .read {
                configureAudioSession()
                speakCurrent(fromOffset: startOffset)
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
        if isNeuralVoice {
            if audioPlayer.isPlaying {
                audioPlayer.pause()
                neuralPaused = true
                neuralProgressTask?.cancel()
                neuralProgressTask = nil
                isPlaying = false
                saveProgress()
                updateNowPlaying()
            } else if isPlaying {
                neuralTask?.cancel()
                neuralTask = nil
                neuralPaused = false
                isPlaying = false
                isLoading = false
                saveProgress()
                updateNowPlaying()
            }
            return
        }
        guard synthesizer.isSpeaking else {
            isPlaying = false
            return
        }
        synthesizer.pauseSpeaking(at: .immediate)
        isPlaying = false
        saveProgress()
        updateNowPlaying()
    }

    public func resume() {
        guard let book = activeBook else { return }
        if mode == .read {
            mode = .listen
            library.setReadingMode(book, mode: mode)
        }
        if restartVoiceOnResume {
            restartVoiceOnResume = false
            restartOnResume = false
            let offset = currentWordRange?.location ?? 0
            stopAudio()
            isPlaying = false
            speakCurrent(fromOffset: offset)
            updateNowPlaying()
            return
        }
        if restartOnResume, !isNeuralVoice || !neuralPaused {
            restartOnResume = false
            let offset = currentWordRange?.location ?? 0
            stopAudio()
            isPlaying = false
            speakCurrent(fromOffset: offset)
            updateNowPlaying()
            return
        }
        restartOnResume = false
        configureAudioSession()
        if isNeuralVoice {
            if neuralPaused {
                startNeuralEngine()
                audioPlayer.play()
                neuralPaused = false
                isPlaying = true
                startNeuralProgress()
            } else {
                speakCurrent()
            }
            updateNowPlaying()
            return
        }
        if synthesizer.isPaused {
            synthesizer.continueSpeaking()
            isPlaying = true
        } else {
            speakCurrent()
        }
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
        currentIndex = 0
        chapterIndex = 0
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
            cancelAudioCacheGeneration()
            saveProgress()
            activeBook = nil
            chapters = []
            sentences = []
            currentIndex = 0
            chapterIndex = 0
            mode = .listen
            updateNowPlaying()
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

    public func setSpeed(_ multiplier: Double) {
        speedMultiplier = multiplier
        timePitch.rate = Float(multiplier)
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
        sampleSynthesizer.stopSpeaking(at: .immediate)
        samplePlayer?.stop()
        sampleTask?.cancel()
        let token = UUID()
        sampleToken = token
        let sample = voice.language.hasPrefix("es")
            ? "Así suena esta voz al narrar tu biblioteca en Nodus Reader."
            : "This is how this voice sounds reading your library in Nodus Reader."
        isPlayingSample = true
        sampleVoiceID = voice.id

        if voice.isSystem {
            let utterance = AVSpeechUtterance(string: sample)
            utterance.voice = AVSpeechSynthesisVoice(identifier: voice.id)
            utterance.rate = clampRate(Float(AVSpeechUtteranceDefaultSpeechRate) * 0.95)
            sampleSynthesizer.speak(utterance)
            sampleTask = Task { @MainActor [weak self] in
                while self?.sampleSynthesizer.isSpeaking == true {
                    try? await Task.sleep(for: .milliseconds(250))
                }
                guard let self, token == self.sampleToken else { return }
                self.isPlayingSample = false
            }
            return
        }

        sampleTask = Task { [weak self] in
            guard let self else { return }
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("nodus-sample-\(UUID().uuidString).caf")
            defer { try? FileManager.default.removeItem(at: url) }
            do {
                let audio = try await self.synthesize(text: sample, voice: voice)
                guard !Task.isCancelled, token == self.sampleToken,
                      let buffer = self.makeBuffer(samples: audio.samples, sampleRate: audio.sampleRate) else {
                    self.isPlayingSample = false
                    return
                }
                let file = try AVAudioFile(forWriting: url, settings: buffer.format.settings,
                                           commonFormat: .pcmFormatFloat32, interleaved: false)
                try file.write(from: buffer)
                let player = try AVAudioPlayer(contentsOf: url)
                guard token == self.sampleToken else {
                    self.isPlayingSample = false
                    return
                }
                self.samplePlayer = player
                player.play()
                while player.isPlaying {
                    try? await Task.sleep(for: .milliseconds(200))
                }
                if token == self.sampleToken { self.isPlayingSample = false }
            } catch {
                if token == self.sampleToken { self.isPlayingSample = false }
            }
        }
    }

    private func stopSamplePlayback() {
        sampleToken = UUID()
        sampleTask?.cancel()
        sampleTask = nil
        sampleSynthesizer.stopSpeaking(at: .immediate)
        samplePlayer?.stop()
        samplePlayer = nil
        isPlayingSample = false
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
        guard let book = activeBook, let voice = activeVoice, !voice.isSystem else {
            errorMessage = "Choose a Kokoro or Phonon voice before generating audio."
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
                                                          sampleRate: audio.sampleRate)
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

    private static func alignWords(text: String, samples: [Float],
                                   sampleRate: Double) async -> [NarrationWordTiming] {
        await Task.detached(priority: .userInitiated) {
            AudioWordAligner.align(text: text, samples: samples, sampleRate: sampleRate)
        }.value
    }

    private static func buildSentences(from chapters: [ExtractedChapter]) -> [NarrationSentence] {
        var result: [NarrationSentence] = []
        for (chapterIndex, chapter) in chapters.enumerated() {
            let ns = chapter.text as NSString
            guard ns.length > 0 else { continue }
            ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length),
                                   options: [.bySentences, .substringNotRequired]) { _, range, _, _ in
                let text = ns.substring(with: range)
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
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
        chapterIndex = sentences[index].chapterIndex
        saveProgress()
        if wasPlaying { speakCurrent() }
    }

    private func speakCurrent(fromOffset offset: Int = 0) {
        guard let book = activeBook, sentences.indices.contains(currentIndex) else { return }
        guard let voice = voices.narrationVoice(preferredID: book.preferredVoiceID,
                                                language: book.language) else {
            errorMessage = "No voice is available for this document."
            return
        }
        if voice.isSystem {
            speakSystemCurrent(voice: voice, fromOffset: offset)
        } else {
            speakNeuralCurrent(voice: voice, fromOffset: offset)
        }
    }

    private func speakSystemCurrent(voice: VoiceCatalog.Voice, fromOffset offset: Int) {
        guard let resolved = voices.systemVoice(for: voice) else {
            errorMessage = "No system voice is available for this document."
            return
        }
        let fullText = sentences[currentIndex].text as NSString
        let requested = max(offset, 0)
        let clamped = requested < fullText.length ? requested : 0
        let spokenText = fullText.substring(from: clamped)
        guard !spokenText.isEmpty else { return }
        utteranceStartOffset = clamped
        resetWordState()

        let utterance = AVSpeechUtterance(string: spokenText)
        utterance.voice = resolved
        utterance.rate = clampRate(Float(AVSpeechUtteranceDefaultSpeechRate) * Float(speedMultiplier))
        utterance.pitchMultiplier = 1
        utterance.postUtteranceDelay = 0.05
        activeUtterance = utterance
        synthesizer.speak(utterance)
        isPlaying = true
        chapterIndex = sentences[currentIndex].chapterIndex
        saveProgress()
        updateNowPlaying()
    }

    // MARK: Neural playback

    private func speakNeuralCurrent(voice: VoiceCatalog.Voice, fromOffset offset: Int) {
        guard let book = activeBook, sentences.indices.contains(currentIndex) else { return }
        stopAudio()
        let sentence = sentences[currentIndex]
        let text = sentence.text
        let requested = max(offset, 0)
        let clamped = requested < (text as NSString).length ? requested : 0
        resetWordState()
        neuralPaused = false
        neuralStartOffset = clamped
        chapterIndex = sentence.chapterIndex
        isPlaying = true
        isLoading = true
        library.setReadingMode(book, mode: mode)
        saveProgress()
        updateNowPlaying()

        let token = UUID()
        neuralPlaybackToken = token
        neuralTask = Task { [weak self] in
            guard let self else { return }
            await self.prepareNeuralSentence(text: text, voice: voice,
                                             chapterIndex: sentence.chapterIndex,
                                             offset: clamped, token: token)
        }
    }

    private func prepareNeuralSentence(text: String, voice: VoiceCatalog.Voice,
                                       chapterIndex: Int, offset: Int, token: UUID) async {
        guard let book = activeBook else { return }
        let cache = models.narrationCache
        let key = cache.key(text: text, engine: voice.engineRaw, voice: voice.id)
        var cached = await cache.load(bookID: book.id, key: key)
        if cached == nil {
            do {
                let audio = try await synthesize(text: text, voice: voice)
                // Phonon returns the partial audio it managed to produce when
                // a task is cancelled. Never cache that as a complete sentence.
                try Task.checkCancellation()
                guard token == neuralPlaybackToken else { return }
                let words = await Self.alignWords(text: text, samples: audio.samples,
                                                  sampleRate: audio.sampleRate)
                try Task.checkCancellation()
                guard token == neuralPlaybackToken else { return }
                guard let buffer = makeBuffer(samples: audio.samples,
                                              sampleRate: audio.sampleRate) else {
                    throw NeuralNarrationError.invalidAudio
                }
                let saved = await cache.save(bookID: book.id, key: key, buffer: buffer, words: words)
                if activeBook?.id == book.id { audioCacheBytes += saved }
                cached = CachedNarration(buffer: buffer, words: words,
                                         duration: Double(audio.samples.count) / max(audio.sampleRate, 1))
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
            errorMessage = "The neural engine returned no audio."
            isPlaying = false
            isLoading = false
            return
        }
        neuralWords = cached.words
        neuralBufferDuration = cached.duration
        let start = startTime(for: offset, in: cached)
        neuralStartTime = start
        let buffer = slice(cached.buffer, from: start) ?? cached.buffer
        neuralBufferDuration = Double(buffer.frameLength) / cached.buffer.format.sampleRate

        configureAudioSession()
        startNeuralEngine()
        audioPlayer.stop()
        audioPlayer.scheduleBuffer(buffer, at: nil, options: []) { [weak self] in
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

    private func startNeuralEngine() {
        guard neuralFormat != nil else { return }
        if !audioEngine.isRunning {
            try? audioEngine.start()
        }
    }

    private func startNeuralProgress() {
        neuralProgressTask?.cancel()
        neuralProgressTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(60))
                guard !Task.isCancelled, let self else { return }
                self.tickNeuralProgress()
            }
        }
    }

    private func tickNeuralProgress() {
        guard isPlaying, !neuralPaused,
              let nodeTime = audioPlayer.lastRenderTime,
              let playerTime = audioPlayer.playerTime(forNodeTime: nodeTime) else { return }
        let elapsed = Double(playerTime.sampleTime) / max(playerTime.sampleRate, 1)
        let absolute = neuralStartTime + elapsed
        if let word = neuralWords.last(where: { $0.start <= absolute }) {
            setNeuralWord(word)
        }
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
        resetWordState()
        saveProgress()
        speakCurrent()
    }

    private func stopAudio() {
        activeUtterance = nil
        synthesizer.stopSpeaking(at: .immediate)
        neuralTask?.cancel()
        neuralTask = nil
        neuralProgressTask?.cancel()
        neuralProgressTask = nil
        audioPlayer.stop()
        neuralPaused = false
        neuralWords = []
        neuralBufferDuration = 0
        neuralStartTime = 0
        neuralPlaybackToken = UUID()
        isLoading = false
    }

    private func sentenceIndex(chapter: Int, offset: Int) -> Int? {
        let target = max(0, offset)
        return sentences.firstIndex { sentence in
            sentence.chapterIndex == chapter &&
            target >= sentence.chapterOffset &&
            target < sentence.chapterOffset + max(sentence.chapterLength, 1)
        }
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

    private func handleWillSpeak(_ range: NSRange, utterance: AVSpeechUtterance) {
        guard utterance === activeUtterance,
              !isNeuralVoice,
              sentences.indices.contains(currentIndex) else { return }
        let sentence = sentences[currentIndex].text as NSString
        let absolute = NSRange(location: utteranceStartOffset + range.location, length: range.length)
        guard absolute.location >= 0,
              absolute.location + absolute.length <= sentence.length else { return }
        currentWordRange = absolute
        currentWord = sentence.substring(with: absolute)
    }

    private func resetWordState() {
        currentWordRange = nil
        currentWord = nil
    }

    private func clampRate(_ rate: Float) -> Float {
        min(max(rate, AVSpeechUtteranceMinimumSpeechRate), AVSpeechUtteranceMaximumSpeechRate)
    }

    private func handleUtteranceFinished(_ utterance: AVSpeechUtterance) {
        guard utterance === activeUtterance else { return }
        activeUtterance = nil
        guard isPlaying, !isNeuralVoice else { return }
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
        // Same as the neural path: persist each sentence so a quit, a crash or
        // another device never loses a long system-voice listening session.
        resetWordState()
        saveProgress()
        speakCurrent()
    }

    private func finishBook() {
        guard !sentences.isEmpty else { return }
        stopAudio()
        if let book = activeBook {
            let locator: ReadingLocator
            if book.format == .pdf {
                let lastPage = chapters.last?.id ?? max(book.locator.pageIndex ?? 0, 0)
                locator = ReadingLocator(chapterIndex: lastPage, scrollFraction: 1, pageIndex: lastPage)
            } else {
                locator = ReadingLocator(chapterIndex: max(chapters.count - 1, 0), scrollFraction: 1)
            }
            library.updateProgress(book, locator: locator, progress: 1)
        }
        isPlaying = false
        resetWordState()
        updateNowPlaying()
    }

    private func saveProgress() {
        guard let book = activeBook, !sentences.isEmpty else { return }
        if book.format == .pdf {
            // PDF chapters are stored by original page id, not by array index.
            let pageID = chapters.indices.contains(chapterIndex)
                ? chapters[chapterIndex].id
                : max(book.locator.pageIndex ?? 0, 0)
            let locator = ReadingLocator(chapterIndex: pageID, scrollFraction: chapterProgress,
                                         pageIndex: pageID)
            library.updateProgress(book, locator: locator, progress: overallProgress)
            return
        }
        var locator = ReadingLocator(chapterIndex: chapterIndex, scrollFraction: chapterProgress)
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

    private func configureRemoteCommands() {
        #if canImport(MediaPlayer) && os(iOS)
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.isEnabled = true
        center.pauseCommand.isEnabled = true
        center.togglePlayPauseCommand.isEnabled = true
        center.nextTrackCommand.isEnabled = true
        center.previousTrackCommand.isEnabled = true
        center.skipForwardCommand.isEnabled = true
        center.skipBackwardCommand.isEnabled = true
        center.skipForwardCommand.preferredIntervals = [30]
        center.skipBackwardCommand.preferredIntervals = [30]

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
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        #endif
    }
}

// MARK: - Speech delegate

private final class SpeechDelegate: NSObject, AVSpeechSynthesizerDelegate {
    var onFinish: ((AVSpeechUtterance) -> Void)?
    var onCancel: ((AVSpeechUtterance) -> Void)?
    var onWillSpeakRange: ((NSRange, AVSpeechUtterance) -> Void)?

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        onFinish?(utterance)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        onCancel?(utterance)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                           willSpeakRangeOfSpeechString characterRange: NSRange,
                           utterance: AVSpeechUtterance) {
        onWillSpeakRange?(characterRange, utterance)
    }
}

enum NeuralNarrationError: LocalizedError {
    case engineNotLoaded(String)
    case invalidAudio

    var errorDescription: String? {
        switch self {
        case .engineNotLoaded(let engine):
            "The \(engine) engine is not loaded. Open Settings › Voices & Models and install it again."
        case .invalidAudio:
            "The neural engine returned audio in an unsupported format."
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
