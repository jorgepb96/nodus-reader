// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// The musical style of a book: a "tense" moment sounds noir in one book and western in
/// another. Detected once per book and adjustable; never decides when music changes.
enum SoundscapeStyle: String, Codable, CaseIterable, Sendable, Identifiable {
    case neutral, fantasy, scienceFiction, cyberpunk, horror, noir, thriller, western
    case historical, war, romance, comedy, adventure, fairyTale

    var id: String { rawValue }

    var label: String {
        switch self {
        case .neutral: String(localized: "Neutral")
        case .fantasy: String(localized: "Fantasy")
        case .scienceFiction: String(localized: "Science fiction")
        case .cyberpunk: String(localized: "Cyberpunk")
        case .horror: String(localized: "Horror")
        case .noir: String(localized: "Noir")
        case .thriller: String(localized: "Thriller")
        case .western: String(localized: "Western")
        case .historical: String(localized: "Historical")
        case .war: String(localized: "War")
        case .romance: String(localized: "Romance")
        case .comedy: String(localized: "Comedy")
        case .adventure: String(localized: "Adventure")
        case .fairyTale: String(localized: "Fairy tale")
        }
    }
}

/// The feeling of a passage, finer than the director's 14 moods. It only chooses which
/// piece plays within the mood the director decided; it never triggers a change.
enum SceneEmotion: String, Codable, CaseIterable, Sendable {
    case sadness, nostalgia, hope, fear, unease, dread, irony, absurd, joy, tenderness
    case awe, wonder, anger, triumph, relief, determination, longing, serenity, grief, suspense
}

/// What is happening in a passage, for the same purpose as `SceneEmotion`.
enum SceneSituation: String, Codable, CaseIterable, Sendable {
    case chase, escape, discovery, revelation, farewell, reunion, battle, journey
    case investigation, celebration, ritual, mourning, confrontation, rest, romance, night
}

enum SoundscapeVocabulary {
    /// Emotion and situation implied by the analyser's tone, action and intensity, for
    /// readings made before the analyser reported them (or when it did not).
    static func derive(tone: SceneTone, action: SceneAction, intensity: Int) -> (SceneEmotion?, SceneSituation?) {
        let emotion: SceneEmotion? = switch tone {
        case .calm: .serenity
        case .warm, .romantic: .tenderness
        case .melancholic: intensity >= 2 ? .grief : .sadness
        case .mysterious: intensity >= 2 ? .suspense : .wonder
        case .eerie: intensity >= 2 ? .dread : .unease
        case .tense: intensity >= 3 ? .fear : .suspense
        case .epic: intensity >= 3 ? .triumph : .awe
        case .joyful: .joy
        case .solemn: .awe
        case .comic: intensity >= 2 ? .absurd : .irony
        case .dramatic: intensity >= 3 ? .anger : .determination
        case .neutral: nil
        }
        let situation: SceneSituation? = switch action {
        case .travel: .journey
        case .exploration: .discovery
        case .battle: .battle
        case .chase: .chase
        case .celebration: .celebration
        case .ritual: .ritual
        case .contemplation, .rest: .rest
        case .conversation, .work, .none: nil
        }
        return (emotion, situation)
    }
}
