// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Observation

/// Immersive Audio settings for this device. Off by default: nothing plays
/// until the reader turns it on. Never synced (audio packs are per device).
@Observable
final class ImmersiveAudioPreferences {
    private enum Key {
        static let mode = "nodus.immersive.mode"
        static let lastMode = "nodus.immersive.lastMode"
        static let profile = "nodus.immersive.profile"
        static let musicVolume = "nodus.immersive.musicVolume"
        static let ambienceVolume = "nodus.immersive.ambienceVolume"
        static let intensity = "nodus.immersive.intensity"
        static let musicEnabled = "nodus.immersive.musicEnabled"
        static let ambienceEnabled = "nodus.immersive.ambienceEnabled"
        static let smoothTransitions = "nodus.immersive.smoothTransitions"
        static let crossfade = "nodus.immersive.crossfade"
        static let ducking = "nodus.immersive.ducking"
        static let pausePolicy = "nodus.immersive.pausePolicy"
        static let studyBlock = "nodus.immersive.studyBlock"
        static let defaultBase = "nodus.immersive.defaultBase"
        static let defaultMusic = "nodus.immersive.defaultMusic"
    }

    enum Ducking: String, CaseIterable, Identifiable, Sendable {
        case light, medium, strong

        var id: String { rawValue }
        var decibels: Double {
            switch self {
            case .light: -6
            case .medium: -10
            case .strong: -14
            }
        }
        var label: String {
            switch self {
            case .light: String(localized: "Light")
            case .medium: String(localized: "Medium")
            case .strong: String(localized: "Strong")
            }
        }
    }

    private let defaults: UserDefaults

    var mode: ImmersiveMode {
        didSet {
            defaults.set(mode.rawValue, forKey: Key.mode)
            if mode != .off { defaults.set(mode.rawValue, forKey: Key.lastMode) }
        }
    }
    /// The profile last applied, if the settings still match it.
    var profile: ImmersiveProfile? {
        didSet { defaults.set(profile?.rawValue, forKey: Key.profile) }
    }
    /// Slider positions, 0…1 (a squared taper is applied when playing).
    var musicVolume: Double {
        didSet { defaults.set(musicVolume, forKey: Key.musicVolume) }
    }
    var ambienceVolume: Double {
        didSet { defaults.set(ambienceVolume, forKey: Key.ambienceVolume) }
    }
    var intensity: MusicIntensity {
        didSet { defaults.set(intensity.rawValue, forKey: Key.intensity) }
    }
    var musicEnabled: Bool {
        didSet { defaults.set(musicEnabled, forKey: Key.musicEnabled) }
    }
    var ambienceEnabled: Bool {
        didSet { defaults.set(ambienceEnabled, forKey: Key.ambienceEnabled) }
    }
    /// Long crossfades; off uses short (3 s) transitions.
    var smoothTransitions: Bool {
        didSet { defaults.set(smoothTransitions, forKey: Key.smoothTransitions) }
    }
    /// Crossfade length when transitions are smooth, 8–15 s.
    var crossfadeSeconds: Double {
        didSet { defaults.set(crossfadeSeconds, forKey: Key.crossfade) }
    }
    var ducking: Ducking {
        didSet { defaults.set(ducking.rawValue, forKey: Key.ducking) }
    }
    var pausePolicy: ImmersivePausePolicy {
        didSet { defaults.set(pausePolicy.rawValue, forKey: Key.pausePolicy) }
    }
    /// Study blocks in minutes; 0 keeps one texture for the whole session.
    var studyBlockMinutes: Int {
        didSet { defaults.set(studyBlockMinutes, forKey: Key.studyBlock) }
    }
    /// What plays in manual and study modes, and when analysis says nothing.
    var defaultAtmosphere: Atmosphere {
        didSet {
            defaults.set(defaultAtmosphere.base.rawValue, forKey: Key.defaultBase)
            defaults.set(defaultAtmosphere.music?.rawValue ?? "", forKey: Key.defaultMusic)
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        mode = defaults.string(forKey: Key.mode).flatMap(ImmersiveMode.init(rawValue:)) ?? .off
        profile = defaults.string(forKey: Key.profile).flatMap(ImmersiveProfile.init(rawValue:))
        musicVolume = defaults.object(forKey: Key.musicVolume) as? Double ?? 0.5
        ambienceVolume = defaults.object(forKey: Key.ambienceVolume) as? Double ?? 0.5
        intensity = defaults.string(forKey: Key.intensity).flatMap(MusicIntensity.init(rawValue:)) ?? .balanced
        musicEnabled = defaults.object(forKey: Key.musicEnabled) as? Bool ?? true
        ambienceEnabled = defaults.object(forKey: Key.ambienceEnabled) as? Bool ?? true
        smoothTransitions = defaults.object(forKey: Key.smoothTransitions) as? Bool ?? true
        crossfadeSeconds = defaults.object(forKey: Key.crossfade) as? Double ?? 12
        ducking = defaults.string(forKey: Key.ducking).flatMap(Ducking.init(rawValue:)) ?? .medium
        pausePolicy = defaults.string(forKey: Key.pausePolicy).flatMap(ImmersivePausePolicy.init(rawValue:)) ?? .pauseEverything
        studyBlockMinutes = defaults.object(forKey: Key.studyBlock) as? Int ?? 45
        let base = defaults.string(forKey: Key.defaultBase).flatMap(BaseAmbience.init(rawValue:)) ?? .none
        let music = defaults.string(forKey: Key.defaultMusic).map { $0.isEmpty ? nil : MusicMood(rawValue: $0) }
        defaultAtmosphere = Atmosphere(base: base, music: music ?? .calm)
    }

    var isEnabled: Bool { mode != .off }

    /// The mode to return to when the feature is switched back on.
    func modeToEnable(automaticAvailable: Bool) -> ImmersiveMode {
        let last = defaults.string(forKey: Key.lastMode).flatMap(ImmersiveMode.init(rawValue:))
        if let last, last != .automatic || automaticAvailable { return last }
        return automaticAvailable ? .automatic : .manual
    }

    /// Crossfade to use for an atmosphere change.
    var crossfade: TimeInterval { smoothTransitions ? min(max(crossfadeSeconds, 8), 15) : 3 }

    func apply(_ profile: ImmersiveProfile, automaticAvailable: Bool) {
        let settings = profile.settings
        mode = settings.mode == .automatic && !automaticAvailable ? .manual : settings.mode
        defaultAtmosphere = settings.atmosphere
        intensity = settings.intensity
        musicEnabled = settings.atmosphere.music != nil
        ambienceEnabled = settings.atmosphere.base != .none
        if settings.mode == .study { studyBlockMinutes = settings.studyBlockMinutes ?? 0 }
        self.profile = profile
    }
}
