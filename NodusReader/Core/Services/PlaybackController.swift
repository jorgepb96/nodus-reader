// SPDX-License-Identifier: AGPL-3.0-only
import AVFoundation
import Foundation
import Observation
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
}

/// A real, local narration engine built on AVSpeechSynthesizer. It is the
/// system-voice implementation that the modular Kokoro/Phonon engines in
/// Milestone 6 will plug into behind the same interface.
@MainActor
@Observable
public final class PlaybackController {
    public static let speedOptions: [Double] = [0.75, 1.0, 1.25, 1.5, 1.75, 2.0]

    @ObservationIgnored private let library: LibraryService
    public let voices: VoiceCatalog
    @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()
    @ObservationIgnored private let sampleSynthesizer = AVSpeechSynthesizer()
    @ObservationIgnored private let speechDelegate = SpeechDelegate()

    public private(set) var activeBook: Book?
    public private(set) var chapters: [ExtractedChapter] = []
    public private(set) var sentences: [NarrationSentence] = []
    public private(set) var currentIndex = 0
    public private(set) var chapterIndex = 0
    public private(set) var isPlaying = false
    public private(set) var isLoading = false
    public private(set) var isPlayingSample = false
    public private(set) var currentWordRange: NSRange?
    public private(set) var currentWord: String?
    public var errorMessage: String?
    public var mode: ReadingMode = .listen
    public var speedMultiplier: Double = 1.0
    public var sleepTimer: SleepTimerOption = .off
    public private(set) var sleepEndsAt: Date?

    @ObservationIgnored private var sleepTask: Task<Void, Never>?
    @ObservationIgnored private var resumeAfterInterruption = false
    @ObservationIgnored private var utteranceStartOffset = 0
    @ObservationIgnored private var interruptionObserver: NSObjectProtocol?
    @ObservationIgnored private var routeObserver: NSObjectProtocol?

    public init(library: LibraryService, voices: VoiceCatalog) {
        self.library = library
        self.voices = voices
        synthesizer.delegate = speechDelegate
        speechDelegate.onFinish = { [weak self] in
            Task { @MainActor [weak self] in self?.handleUtteranceFinished() }
        }
        speechDelegate.onCancel = { [weak self] in
            Task { @MainActor [weak self] in self?.isPlaying = false }
        }
        speechDelegate.onWillSpeakRange = { [weak self] range in
            Task { @MainActor [weak self] in self?.handleWillSpeak(range) }
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
        String(format: "%.1f×", speedMultiplier)
    }

    public var activeVoice: VoiceCatalog.Voice? {
        voices.voice(withID: activeBook?.preferredVoiceID) ?? voices.defaultVoice
    }

    public var activeVoiceID: String? {
        activeBook?.preferredVoiceID ?? voices.defaultVoiceID
    }

    public var voiceLabel: String {
        activeVoice?.name ?? "System voice"
    }

    public var engineLabel: String { "System" }

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
                      startingSentence: String? = nil, wordOffset: Int = 0) async {
        if activeBook?.id == book.id {
            if let startingSentence,
               let index = sentenceIndex(matching: startingSentence) {
                synthesizer.stopSpeaking(at: .immediate)
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
        activeBook = book
        self.mode = mode
        isLoading = true
        errorMessage = nil

        do {
            if voices.voices.isEmpty {
                await voices.loadIfNeeded()
            }
            let loaded = try await BookTextLoader.loadChapters(for: book, fileStore: library.fileStore)
            guard !loaded.isEmpty else {
                throw ImportError.emptyDocument(book.title)
            }
            chapters = loaded
            sentences = Self.buildSentences(from: loaded)
            guard !sentences.isEmpty else {
                throw ImportError.emptyDocument(book.title)
            }
            let resumeChapter = min(max(book.locator.chapterIndex, 0), max(chapters.count - 1, 0))
            currentIndex = sentences.firstIndex { $0.chapterIndex == resumeChapter } ?? 0
            if let startingSentence, let index = sentenceIndex(matching: startingSentence) {
                currentIndex = index
            }
            chapterIndex = sentences[currentIndex].chapterIndex
            isLoading = false
            library.setReadingMode(book, mode: mode)
            library.open(book)
            if mode != .read {
                configureAudioSession()
                speakCurrent(fromOffset: startingSentence == nil ? 0 : wordOffset)
            }
        } catch {
            isLoading = false
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            stopSpeaking(clearBook: true)
        }
    }

    public func toggle() {
        isPlaying ? pause() : resume()
    }

    public func pause() {
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
        guard activeBook != nil else { return }
        if mode == .read { mode = .listen }
        configureAudioSession()
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

    public func stopSpeaking(clearBook: Bool) {
        sleepTask?.cancel()
        sleepTask = nil
        sleepTimer = .off
        sleepEndsAt = nil
        synthesizer.stopSpeaking(at: .immediate)
        isPlaying = false
        resetWordState()
        if clearBook {
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
        synthesizer.stopSpeaking(at: .immediate)
        isPlaying = false
        speakCurrent(fromOffset: offset)
    }

    // MARK: Transport

    public func nextSentence() {
        guard currentIndex + 1 < sentences.count else {
            finishBook()
            return
        }
        move(to: currentIndex + 1)
    }

    public func previousSentence() {
        guard currentIndex > 0 else { return }
        move(to: currentIndex - 1)
    }

    public func nextChapter() {
        guard let next = sentences.firstIndex(where: { $0.chapterIndex > chapterIndex }) else { return }
        move(to: next)
    }

    public func previousChapter() {
        guard let previous = sentences.lastIndex(where: { $0.chapterIndex < chapterIndex }) else { return }
        let chapter = sentences[previous].chapterIndex
        guard let start = sentences.firstIndex(where: { $0.chapterIndex == chapter }) else { return }
        move(to: start)
    }

    public func seek(to index: Int) {
        guard sentences.indices.contains(index) else { return }
        move(to: index)
    }

    public func setSpeed(_ multiplier: Double) {
        speedMultiplier = multiplier
        guard isPlaying else { return }
        let offset = currentWordRange?.location ?? 0
        synthesizer.stopSpeaking(at: .immediate)
        isPlaying = false
        speakCurrent(fromOffset: offset)
    }

    public func setVoice(_ voice: VoiceCatalog.Voice) {
        guard let book = activeBook else { return }
        library.setPreferredVoice(book, voiceID: voice.id)
        if isPlaying {
            let offset = currentWordRange?.location ?? 0
            synthesizer.stopSpeaking(at: .immediate)
            isPlaying = false
            speakCurrent(fromOffset: offset)
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
        sampleSynthesizer.stopSpeaking(at: .immediate)
        let sample = voice.language.hasPrefix("es")
            ? "Así suena esta voz al narrar tu biblioteca en Nodus Reader."
            : "This is how this voice sounds reading your library in Nodus Reader."
        let utterance = AVSpeechUtterance(string: sample)
        utterance.voice = AVSpeechSynthesisVoice(identifier: voice.id)
        utterance.rate = clampRate(Float(AVSpeechUtteranceDefaultSpeechRate) * 0.95)
        sampleSynthesizer.speak(utterance)
        isPlayingSample = true
        Task { @MainActor [weak self] in
            while self?.sampleSynthesizer.isSpeaking == true {
                try? await Task.sleep(for: .milliseconds(250))
            }
            self?.isPlayingSample = false
        }
    }

    // MARK: Internals

    private static func buildSentences(from chapters: [ExtractedChapter]) -> [NarrationSentence] {
        var result: [NarrationSentence] = []
        for (chapterIndex, chapter) in chapters.enumerated() {
            for sentence in SentenceTokenizer.sentences(from: chapter.text) {
                result.append(NarrationSentence(id: result.count, chapterIndex: chapterIndex, text: sentence))
            }
        }
        return result
    }

    private func move(to index: Int) {
        guard sentences.indices.contains(index) else { return }
        let wasPlaying = isPlaying
        synthesizer.stopSpeaking(at: .immediate)
        isPlaying = false
        currentIndex = index
        chapterIndex = sentences[index].chapterIndex
        saveProgress()
        if wasPlaying { speakCurrent() }
    }

    private func speakCurrent(fromOffset offset: Int = 0) {
        guard let book = activeBook, sentences.indices.contains(currentIndex) else { return }
        guard let voice = voices.resolvedVoice(preferredID: book.preferredVoiceID, language: book.language) else {
            errorMessage = "No system voice is available for this document."
            return
        }
        let fullText = sentences[currentIndex].text
        let clamped = min(max(offset, 0), max(fullText.count - 1, 0))
        let start = fullText.index(fullText.startIndex, offsetBy: clamped)
        let spokenText = String(fullText[start...])
        guard !spokenText.isEmpty else { return }
        utteranceStartOffset = clamped
        resetWordState()

        let utterance = AVSpeechUtterance(string: spokenText)
        utterance.voice = voice
        utterance.rate = clampRate(Float(AVSpeechUtteranceDefaultSpeechRate) * Float(speedMultiplier))
        utterance.pitchMultiplier = 1
        utterance.postUtteranceDelay = 0.05
        synthesizer.speak(utterance)
        isPlaying = true
        chapterIndex = sentences[currentIndex].chapterIndex
        saveProgress()
        updateNowPlaying()
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

    private func handleWillSpeak(_ range: NSRange) {
        guard sentences.indices.contains(currentIndex) else { return }
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

    private func handleUtteranceFinished() {
        guard isPlaying else { return }
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
        speakCurrent()
    }

    private func finishBook() {
        if let book = activeBook {
            library.updateProgress(book, locator: ReadingLocator(chapterIndex: max(chapters.count - 1, 0), scrollFraction: 1),
                                   progress: 1)
        }
        isPlaying = false
        updateNowPlaying()
    }

    private func saveProgress() {
        guard let book = activeBook, !sentences.isEmpty else { return }
        let locator = ReadingLocator(chapterIndex: chapterIndex, scrollFraction: chapterProgress)
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
    var onFinish: (() -> Void)?
    var onCancel: (() -> Void)?
    var onWillSpeakRange: ((NSRange) -> Void)?

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        onFinish?()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        onCancel?()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                           willSpeakRangeOfSpeechString characterRange: NSRange,
                           utterance: AVSpeechUtterance) {
        onWillSpeakRange?(characterRange)
    }
}
