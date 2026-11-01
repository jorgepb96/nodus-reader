// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// A candidate value for one layer and how strongly one window supports it.
/// The strength is a heuristic evidence score from 0 to 3 built from what the
/// window reading says (kind of passage, clarity, intensity, verified quote).
/// It is not a probability and is never shown as one.
struct LayerEvidence<Value: Hashable & Sendable>: Hashable, Sendable {
    var value: Value
    var strength: Double
}

/// Turns one window reading into evidence for the music and base layers.
enum AtmosphereMapper {
    /// The music mood a reading supports, or nil when it supports none.
    /// Only scenes and dialogue count; summaries, memories, exposition and
    /// front matter never move the music.
    static func music(for reading: SceneReading, kind: DocumentKind?,
                      intensity: MusicIntensity) -> LayerEvidence<MusicMood>? {
        guard reading.passageKind.isScene else { return nil }
        if let kind, !kind.hasScenes { return nil }
        var mood = baseMood(reading)
        var strength = 1.0
        if reading.intensity >= 2 { strength += 1 }
        // Something happening now: a scene, or dialogue inside an action.
        let acting = reading.action != .conversation && reading.action != .none && reading.action != .rest
        if reading.passageKind == .scene || acting { strength += 1 }
        // Dramatic moods need an intense moment told as it happens: a scene
        // or lines of dialogue inside it (the model tags a storm with one
        // shouted order as dialogue), but not a conversation that is merely
        // tense in tone.
        let action = reading.action != .conversation && reading.action != .none && reading.action != .rest
        let intenseNow = reading.passageKind.isScene && reading.intensity >= 2
            && (action || reading.intensity == 3 || reading.tone == .eerie || reading.tone == .dramatic)
        if mood.isDramatic, !intenseNow {
            switch mood {
            case .epic: mood = .adventure
            case .dramatic: mood = .melancholic
            default: mood = .mysterious
            }
            strength = min(strength, 2)
        }
        // The reader's intensity setting caps how dramatic music may get.
        switch intensity {
        case .subtle:
            if mood == .dramatic { mood = .melancholic } else if mood.isDramatic { mood = .mysterious }
        case .balanced:
            if mood == .epic, reading.intensity < 3 { mood = .adventure }
        case .expressive:
            break
        }
        // Non-fiction told as a story never gets dramatic music.
        if let kind, !kind.allowsDramaticMusic, mood.isDramatic || mood == .adventure {
            mood = .contemplative
        }
        // The on-device model often summarises instead of quoting, so an
        // unmatched phrase only weakens the reading a little; no grounding
        // at all ("none", empty) weakens it more.
        if !reading.evidenceVerified { strength -= Self.isUngrounded(reading.evidence) ? 1 : 0.5 }
        return strength > 0 ? LayerEvidence(value: mood, strength: strength) : nil
    }

    /// The bed a reading supports, or nil. Weather heard in the scene comes
    /// before the place; a place must be clearly established.
    static func base(for reading: SceneReading, kind: DocumentKind?) -> LayerEvidence<BaseAmbience>? {
        if let kind, !kind.hasScenes { return nil }
        let cap: Double
        switch reading.passageKind {
        case .scene, .dialogue: cap = 3
        case .summary: cap = 1
        case .recollection, .exposition, .frontMatter: return nil
        }
        let clarity = Double(max(0, min(reading.settingClarity, 3)))
        var strength = min(clarity, cap) - (reading.evidenceVerified ? 0 : (Self.isUngrounded(reading.evidence) ? 1 : 0.5))
        guard strength > 0 else { return nil }
        let bed: BaseAmbience?
        if clarity >= 2, reading.weather == .storm {
            bed = .storm
        } else if clarity >= 2, reading.weather == .rain {
            bed = .rain
        } else {
            bed = bedForSetting(reading)
            if reading.weather == .wind, bed == nil { strength = min(strength, 2) }
        }
        guard let bed = bed ?? (reading.weather == .wind ? .wind : nil) else { return nil }
        return LayerEvidence(value: bed, strength: strength)
    }

    private static func baseMood(_ reading: SceneReading) -> MusicMood {
        switch (reading.action, reading.tone) {
        // A comic chase is still comedy.
        case (_, .comic): return .comic
        case (.battle, _), (.chase, _):
            return reading.intensity >= 2 ? .epic : .tense
        case (_, .epic): return .epic
        case (_, .tense): return .tense
        case (_, .eerie): return .eerie
        case (_, .mysterious): return .mysterious
        case (_, .dramatic): return .dramatic
        case (_, .romantic): return .romantic
        case (_, .melancholic): return .melancholic
        case (.celebration, _), (_, .joyful): return .joyful
        case (.ritual, _), (_, .solemn): return .solemn
        case (.travel, _), (.exploration, _): return .adventure
        case (.contemplation, _): return .contemplative
        default: return .calm
        }
    }

    private static func bedForSetting(_ reading: SceneReading) -> BaseAmbience? {
        let night = reading.tone == .eerie || reading.tone == .mysterious
        switch reading.setting {
        case .forest: return night ? .forestNight : .forestDay
        case .sea, .ship: return .sea
        case .river: return .stream
        case .mountain, .desert, .snowfield: return .wind
        case .countryside: return .forestDay
        case .cave: return .cave
        case .city: return .city
        case .village, .tavern: return .tavern
        case .home, .castle: return .fireplace
        case .library: return .library
        case .sacred, .space, .unknown: return nil
        }
    }

    static func isUngrounded(_ evidence: String) -> Bool {
        let text = evidence.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return text.count < 4 || text == "none" || text == "n/a" || text == "unknown"
    }

    /// The installed value nearest to `value`: itself, or its first installed
    /// fallback. Nil when nothing suitable is installed.
    static func playable(_ mood: MusicMood, installed: Set<MusicMood>) -> MusicMood? {
        if installed.contains(mood) { return mood }
        return mood.fallbacks.first(where: installed.contains)
    }

    static func playable(_ bed: BaseAmbience, installed: Set<BaseAmbience>) -> BaseAmbience? {
        if bed == .none || installed.contains(bed) { return bed }
        return bed.fallbacks.first(where: installed.contains)
    }
}
