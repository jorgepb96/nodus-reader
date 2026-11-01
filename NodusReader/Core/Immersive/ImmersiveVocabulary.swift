// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// The normalised vocabulary of Immersive Audio. Scene analysis may only
/// answer with these values, the director reasons with them and the catalog
/// tags its tracks with them. Raw values are stored in scene maps and the
/// catalog manifest: change them only with a `SceneVocabulary.version` bump.
enum SceneVocabulary {
    static let version = 1
}

/// What kind of document a book is, decided once per book.
enum DocumentKind: String, Codable, CaseIterable, Sendable {
    case fiction
    /// History, biography, travel writing told as a story.
    case narrativeNonfiction
    case essay
    case academic
    case manual
    case reference
    case poetry
    case drama
    case other

    /// Kinds whose scenes are analysed one by one. Essays, academic texts,
    /// manuals and reference works get a steady atmosphere instead: a battle
    /// described in a history essay is not a battle scene.
    var hasScenes: Bool {
        switch self {
        case .fiction, .narrativeNonfiction, .drama: true
        default: false
        }
    }

    /// Kinds where music may follow dramatic moments (epic, tense, eerie).
    var allowsDramaticMusic: Bool {
        self == .fiction || self == .drama
    }
}

/// What a stretch of text is doing.
enum PassageKind: String, Codable, CaseIterable, Sendable {
    /// Events happening now, in a place.
    case scene
    case dialogue
    /// Time passing quickly, events told rather than shown.
    case summary
    /// A memory or flashback.
    case recollection
    /// Explanation, argument, description of ideas.
    case exposition
    /// Contents, preface, licence, notes.
    case frontMatter

    var isScene: Bool { self == .scene || self == .dialogue }
}

enum SceneSetting: String, Codable, CaseIterable, Sendable {
    case forest, sea, river, mountain, countryside, desert, snowfield, cave
    case city, village, home, tavern, library, sacred, castle, ship, space
    case unknown
}

enum SceneWeather: String, Codable, CaseIterable, Sendable {
    case clear, rain, storm, wind, snow, unknown
}

enum SceneTone: String, Codable, CaseIterable, Sendable {
    case calm, warm, romantic, melancholic, mysterious, eerie, tense, epic, joyful, solemn, comic, dramatic, neutral
}

enum SceneAction: String, Codable, CaseIterable, Sendable {
    case conversation, contemplation, travel, exploration, battle, chase
    case celebration, ritual, work, rest, none
}

/// How the passage begins compared with the one before it.
enum SceneChange: String, Codable, CaseIterable, Sendable {
    case none
    /// A new beat in the same scene (someone arrives, the talk turns).
    case minor
    /// A different place, time or set of characters.
    case clear
}

/// The base layer: a recorded environment, very persistent.
enum BaseAmbience: String, Codable, CaseIterable, Sendable, Identifiable {
    case none, rain, storm, forestDay, forestNight, sea, stream, wind
    case fireplace, tavern, city, library, cave

    var id: String { rawValue }

    /// When this bed is not installed, the closest one that may stand in.
    var fallbacks: [BaseAmbience] {
        switch self {
        case .storm: [.rain]
        case .forestNight: [.forestDay]
        case .stream: [.forestDay]
        default: []
        }
    }

    var label: String {
        switch self {
        case .none: String(localized: "No ambience")
        case .rain: String(localized: "Rain")
        case .storm: String(localized: "Storm")
        case .forestDay: String(localized: "Forest by day")
        case .forestNight: String(localized: "Forest at night")
        case .sea: String(localized: "Sea")
        case .stream: String(localized: "Stream")
        case .wind: String(localized: "Wind")
        case .fireplace: String(localized: "Fireplace")
        case .tavern: String(localized: "Tavern")
        case .city: String(localized: "City")
        case .library: String(localized: "Library")
        case .cave: String(localized: "Cave")
        }
    }

    var symbol: String {
        switch self {
        case .none: "speaker.slash"
        case .rain: "cloud.rain"
        case .storm: "cloud.bolt.rain"
        case .forestDay: "tree"
        case .forestNight: "moon.stars"
        case .sea: "water.waves"
        case .stream: "drop"
        case .wind: "wind"
        case .fireplace: "flame"
        case .tavern: "mug"
        case .city: "building.2"
        case .library: "books.vertical"
        case .cave: "mountain.2"
        }
    }
}

/// The music layer: instrumental pieces grouped by mood.
enum MusicMood: String, Codable, CaseIterable, Sendable, Identifiable {
    case calm, contemplative, melancholic, romantic, mysterious, eerie
    case tense, epic, adventure, joyful, solemn, comic, dramatic, focus

    var id: String { rawValue }

    /// Moods that may stand in, in order, when this one has no installed track.
    var fallbacks: [MusicMood] {
        switch self {
        case .epic: [.adventure, .tense, .mysterious, .calm]
        case .tense: [.mysterious, .calm]
        case .eerie: [.mysterious, .calm]
        case .adventure: [.calm]
        case .melancholic: [.contemplative, .calm]
        case .romantic: [.contemplative, .calm]
        case .joyful: [.adventure, .calm]
        case .solemn: [.contemplative, .calm]
        case .comic: [.joyful, .calm]
        case .dramatic: [.melancholic, .tense, .contemplative, .calm]
        case .mysterious: [.contemplative, .calm]
        case .contemplative: [.calm]
        case .focus: [.calm, .contemplative]
        case .calm: [.contemplative, .focus]
        }
    }

    /// Dramatic moods follow only clear, intense scenes in fiction.
    var isDramatic: Bool { self == .epic || self == .tense || self == .eerie || self == .dramatic }

    var label: String {
        switch self {
        case .calm: String(localized: "Calm")
        case .contemplative: String(localized: "Contemplative")
        case .melancholic: String(localized: "Melancholic")
        case .romantic: String(localized: "Romantic")
        case .mysterious: String(localized: "Mysterious")
        case .eerie: String(localized: "Eerie")
        case .tense: String(localized: "Tense")
        case .epic: String(localized: "Epic")
        case .adventure: String(localized: "Adventure")
        case .joyful: String(localized: "Joyful")
        case .solemn: String(localized: "Solemn")
        case .comic: String(localized: "Comic")
        case .dramatic: String(localized: "Dramatic")
        case .focus: String(localized: "Focus")
        }
    }
}

/// What plays: one bed and, optionally, one music mood.
struct Atmosphere: Codable, Hashable, Sendable {
    var base: BaseAmbience
    var music: MusicMood?

    static let silent = Atmosphere(base: .none, music: nil)
}

enum ImmersiveMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case off
    /// Scenes are analysed on the device and the atmosphere follows them.
    case automatic
    /// A steady atmosphere for the whole session; the text is never analysed.
    case study
    /// The reader picks the bed and the music.
    case manual

    var id: String { rawValue }

    var label: String {
        switch self {
        case .off: String(localized: "Off")
        case .automatic: String(localized: "Automatic")
        case .study: String(localized: "Study")
        case .manual: String(localized: "Manual")
        }
    }
}

/// How far the music may follow dramatic moments.
enum MusicIntensity: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Never dramatic: epic and tense scenes keep a mysterious or calm mood.
    case subtle
    /// Dramatic music only for the most intense scenes.
    case balanced
    case expressive

    var id: String { rawValue }

    var label: String {
        switch self {
        case .subtle: String(localized: "Subtle")
        case .balanced: String(localized: "Balanced")
        case .expressive: String(localized: "Expressive")
        }
    }

    /// Highest track energy (0…3) the music layer chooses.
    var maximumEnergy: Int {
        switch self {
        case .subtle: 1
        case .balanced: 2
        case .expressive: 3
        }
    }
}

/// Presets that set the mode and the default atmosphere in one tap.
enum ImmersiveProfile: String, Codable, CaseIterable, Sendable, Identifiable {
    case calmReading, narrativeReading, study, deepFocus, rain, nature, library, instrumental

    var id: String { rawValue }

    struct Settings: Equatable, Sendable {
        var mode: ImmersiveMode
        var atmosphere: Atmosphere
        var intensity: MusicIntensity
        /// Study blocks in minutes; nil keeps one texture for the session.
        var studyBlockMinutes: Int?
    }

    var settings: Settings {
        switch self {
        case .calmReading:
            Settings(mode: .manual, atmosphere: Atmosphere(base: .none, music: .calm), intensity: .subtle)
        case .narrativeReading:
            Settings(mode: .automatic, atmosphere: Atmosphere(base: .none, music: .calm), intensity: .balanced)
        case .study:
            Settings(mode: .study, atmosphere: Atmosphere(base: .library, music: .focus), intensity: .subtle,
                     studyBlockMinutes: 45)
        case .deepFocus:
            Settings(mode: .study, atmosphere: Atmosphere(base: .rain, music: .focus), intensity: .subtle,
                     studyBlockMinutes: nil)
        case .rain:
            Settings(mode: .manual, atmosphere: Atmosphere(base: .rain, music: nil), intensity: .subtle)
        case .nature:
            Settings(mode: .manual, atmosphere: Atmosphere(base: .forestDay, music: nil), intensity: .subtle)
        case .library:
            Settings(mode: .manual, atmosphere: Atmosphere(base: .library, music: nil), intensity: .subtle)
        case .instrumental:
            Settings(mode: .manual, atmosphere: Atmosphere(base: .none, music: .contemplative), intensity: .subtle)
        }
    }

    var label: String {
        switch self {
        case .calmReading: String(localized: "Calm reading")
        case .narrativeReading: String(localized: "Narrative reading")
        case .study: String(localized: "Study")
        case .deepFocus: String(localized: "Deep focus")
        case .rain: String(localized: "Rain")
        case .nature: String(localized: "Nature")
        case .library: String(localized: "Library")
        case .instrumental: String(localized: "Instrumental music")
        }
    }

    var symbol: String {
        switch self {
        case .calmReading: "leaf"
        case .narrativeReading: "text.book.closed"
        case .study: "graduationcap"
        case .deepFocus: "scope"
        case .rain: "cloud.rain"
        case .nature: "tree"
        case .library: "books.vertical"
        case .instrumental: "pianokeys"
        }
    }
}
