// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// What Immersive Audio does when narration pauses.
enum ImmersivePausePolicy: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Pausing narration pauses music and ambience too (default).
    case pauseEverything
    /// Music and ambience keep playing while the reader has the app open.
    case keepPlaying

    var id: String { rawValue }

    var label: String {
        switch self {
        case .pauseEverything: String(localized: "Pause everything")
        case .keepPlaying: String(localized: "Keep the atmosphere playing")
        }
    }
}

/// When Immersive Audio plays: a pure reducer from events to play/pause,
/// with the fade each transition deserves.
struct ImmersivePlaybackPolicy: Equatable, Sendable {
    enum Narration: Equatable, Sendable {
        /// Silent reading: narration has not been used in this reading session.
        case none
        case playing
        case paused
    }

    enum Event: Equatable, Sendable {
        case enabled(Bool)
        case readerOpened
        case readerClosed
        case narrationStarted
        case narrationPaused
        case narrationStopped
        case appActive(Bool)
        case interruptionBegan
        case interruptionEnded
        case headphonesUnplugged
        /// The reader turned a page, scrolled or tapped (silent reading).
        case readerActivity
        /// No reader activity for the idle limit during silent reading.
        case idleTimeout
        case sleepTimerFired
        case bookFinished
        /// Play or pause from Immersive Audio's own controls.
        case userPlay
        case userPause
    }

    enum Transition: Equatable, Sendable {
        case play(fadeIn: TimeInterval)
        case pause(fadeOut: TimeInterval)
    }

    var pausePolicy: ImmersivePausePolicy = .pauseEverything
    var enabled = false
    var readerOpen = false
    var narration: Narration = .none
    var appActive = true
    var interrupted = false
    /// Held by an event until the reader acts again.
    var userPaused = false
    var unplugged = false
    var idle = false
    var finished = false

    /// Whether music and ambience should be audible in this state.
    var shouldPlay: Bool {
        guard enabled, readerOpen || narration == .playing, !interrupted, !userPaused,
              !unplugged, !finished else { return false }
        switch narration {
        case .playing:
            return true
        case .paused:
            return pausePolicy == .keepPlaying && appActive && !idle
        case .none:
            // Silent reading happens on screen: not in the background.
            return appActive && !idle
        }
    }

    /// Applies `event`; returns the transition if audibility changed.
    mutating func handle(_ event: Event) -> Transition? {
        let before = shouldPlay
        var fade: TimeInterval = 0.6
        switch event {
        case .enabled(let on):
            enabled = on
            userPaused = false
            fade = on ? 2 : 1
        case .readerOpened:
            readerOpen = true
            finished = false
            idle = false
            fade = 3
        case .readerClosed:
            readerOpen = false
            if narration != .playing { narration = .none }
            fade = 2
        case .narrationStarted:
            narration = .playing
            userPaused = false
            unplugged = false
            idle = false
            finished = false
            fade = 1.2
        case .narrationPaused:
            narration = .paused
            fade = 0.6
        case .narrationStopped:
            narration = .none
            fade = 1
        case .appActive(let active):
            appActive = active
            fade = active ? 1.2 : 3
        case .interruptionBegan:
            interrupted = true
            fade = 0
        case .interruptionEnded:
            interrupted = false
            fade = 2
        case .headphonesUnplugged:
            // Never blare music from the speaker when the headphones come out.
            unplugged = true
            fade = 0
        case .readerActivity:
            idle = false
            if narration != .playing { unplugged = false }
            fade = 2
        case .idleTimeout:
            idle = true
            fade = 30
        case .sleepTimerFired:
            userPaused = true
            fade = 3
        case .bookFinished:
            finished = true
            fade = 8
        case .userPlay:
            userPaused = false
            unplugged = false
            idle = false
            fade = 1.2
        case .userPause:
            userPaused = true
            fade = 0.6
        }
        let after = shouldPlay
        guard before != after else { return nil }
        return after ? .play(fadeIn: fade) : .pause(fadeOut: fade)
    }
}

/// Whether the automatic (scene-following) mode can run here, and why not.
/// Manual and study modes work on every device that plays audio.
enum ImmersiveAvailability: Equatable, Sendable {
    case available
    /// iOS/macOS before 26: no on-device language model.
    case unsupportedSystem
    case deviceNotEligible
    case appleIntelligenceOff
    case modelNotReady
    /// The model does not read the book's language.
    case languageUnsupported

    enum ModelState: Equatable, Sendable {
        case available, deviceNotEligible, appleIntelligenceOff, modelNotReady
    }

    static func resolve(systemHasModel: Bool, model: ModelState?, languageSupported: Bool?) -> ImmersiveAvailability {
        guard systemHasModel, let model else { return .unsupportedSystem }
        switch model {
        case .deviceNotEligible: return .deviceNotEligible
        case .appleIntelligenceOff: return .appleIntelligenceOff
        case .modelNotReady: return .modelNotReady
        case .available: return languageSupported == false ? .languageUnsupported : .available
        }
    }

    var allowsAutomatic: Bool { self == .available }

    /// Whether the automatic mode should be listed at all: not on devices
    /// that can never run it.
    var showsAutomatic: Bool {
        switch self {
        case .unsupportedSystem, .deviceNotEligible: false
        default: true
        }
    }

    var explanation: String? {
        switch self {
        case .available:
            nil
        case .unsupportedSystem, .deviceNotEligible:
            String(localized: "Automatic mode needs Apple Intelligence, which this device does not have. Manual and Study modes work fully.")
        case .appleIntelligenceOff:
            String(localized: "Turn on Apple Intelligence in Settings to let the atmosphere follow the story. Manual and Study modes work meanwhile.")
        case .modelNotReady:
            String(localized: "Apple Intelligence is getting ready on this device. Automatic mode will be available once it has finished.")
        case .languageUnsupported:
            String(localized: "Apple Intelligence does not read this book's language yet. Choose the atmosphere manually for this book.")
        }
    }
}
