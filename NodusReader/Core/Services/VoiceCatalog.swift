// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Observation

/// The neural voices installed on this device. Nodus Reader never enumerates,
/// offers or uploads the system's AVSpeechSynthesisVoice list.
@MainActor
@Observable
public final class VoiceCatalog {
    public struct Voice: Identifiable, Hashable, Sendable {
        public var id: String
        public var name: String
        public var language: String
        public var languageName: String
        public var quality: Int
        public var gender: String?
        public var engineRaw: String
        /// The neural model this voice belongs to, and its display name: two
        /// Phonon checkpoints can share a voice name.
        public var modelID: String? = nil
        public var modelName: String? = nil

        public var qualityLabel: String {
            switch quality {
            case 3: String(localized: "Premium")
            case 2: String(localized: "Enhanced")
            default: String(localized: "Standard")
            }
        }

        public var displayName: String { name }

        public var engineLabel: String {
            if let modelName { return modelName }
            switch engineRaw {
            case "kokoro": return "Kokoro"
            case "phonon": return "Phonon"
            default: return String(localized: "Neural voice")
            }
        }
    }

    /// Voices of the selected model, which the reader and player offer.
    public private(set) var voices: [Voice] = []
    /// Voices of every installed neural model, selected or not. The Voices
    /// screen lists them so any model can be tried.
    public private(set) var installedNeuralVoices: [Voice] = []
    public private(set) var favorites: Set<String> = []
    public private(set) var isLoading = false
    public var defaultVoiceID: String

    private let defaults: UserDefaults
    private let favoritesKey = "nodus.voices.favorites"
    private let defaultKey = "nodus.voices.default"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.favorites = Set(defaults.stringArray(forKey: favoritesKey) ?? [])
        self.defaultVoiceID = defaults.string(forKey: defaultKey) ?? ""
    }

    /// Kept as the single asynchronous entry point used by screens that open
    /// before ModelManager publishes the installed neural catalogue.
    public func loadIfNeeded() async {
        isLoading = false
    }

    /// Replaces the selected model's voices and the catalogue of every
    /// installed model. Called when a model is installed, deleted or selected.
    public func setNeuralVoices(_ neural: [Voice], installed: [Voice]? = nil) {
        installedNeuralVoices = installed ?? neural
        voices = neural
        if defaultVoiceID.isEmpty || !voices.contains(where: { $0.id == defaultVoiceID }) {
            defaultVoiceID = bestDefaultVoiceID() ?? voices.first?.id ?? ""
            defaults.set(defaultVoiceID, forKey: defaultKey)
        }
    }

    public var neuralVoices: [Voice] { voices }

    public func voice(withID id: String?,
                      engine: String? = nil) -> Voice? {
        guard let id else { return nil }
        return (voices + installedNeuralVoices).first {
            $0.id == id && (engine == nil || $0.engineRaw == engine)
        }
    }

    /// Voices of every installed neural model.
    public var allInstalledVoices: [Voice] { installedNeuralVoices }

    /// Resolves a saved per-book voice ID to a real installed neural voice.
    /// A missing voice falls back to the selected model's first voice.
    public func narrationVoice(preferredID: String?, language: String?) -> Voice? {
        if let preferredID, let exact = voices.first(where: { $0.id == preferredID }) {
            return exact
        }
        if let language {
            let prefix = String(language.prefix(2)).lowercased()
            if let match = voices.first(where: { $0.language.lowercased().hasPrefix(prefix) }) {
                return match
            }
        }
        return defaultVoice
    }

    /// One entry per language (`en`, `es`, `zh`…), not per regional variant:
    /// `en-US`, `en-GB` and `en-AU` would otherwise all appear as "English".
    public var languages: [String] {
        Self.baseLanguages(of: voices)
    }

    public static func baseLanguages(of voices: [Voice]) -> [String] {
        Array(Set(voices.compactMap { languageCode($0.language) })).sorted {
            (Locale.current.localizedString(forLanguageCode: $0) ?? $0)
                .localizedStandardCompare(Locale.current.localizedString(forLanguageCode: $1) ?? $1) == .orderedAscending
        }
    }

    public func languageName(for code: String) -> String {
        Self.sentenceCase(Locale.current.localizedString(forLanguageCode: code) ?? code)
    }

    /// Spanish and other languages return lowercase names ("inglés"); they
    /// are shown as labels, so the first letter is capitalised.
    static func sentenceCase(_ name: String) -> String {
        guard let first = name.first else { return name }
        return String(first).uppercased(with: Locale.current) + name.dropFirst()
    }

    /// "English (United Kingdom)" for `en-GB`; the plain language name when
    /// the code has no region.
    public static func variantName(for code: String) -> String {
        let identifier = code.replacingOccurrences(of: "-", with: "_")
        return sentenceCase(Locale.current.localizedString(forIdentifier: identifier)
            ?? Locale.current.localizedString(forLanguageCode: code)
            ?? code)
    }

    public var defaultVoice: Voice? {
        voice(withID: defaultVoiceID) ?? voices.first
    }

    /// The base language of a BCP-47 or POSIX code: `en` for `en-US`/`en_GB`,
    /// `yue` for `yue-HK`.
    public static func languageCode(_ code: String?) -> String? {
        guard let code, !code.isEmpty,
              let base = code.split(whereSeparator: { $0 == "-" || $0 == "_" }).first else { return nil }
        return base.lowercased()
    }

    public func voices(matchingLanguage code: String?) -> [Voice] {
        guard let normalized = Self.languageCode(code) else { return voices }
        return voices.filter { $0.language.lowercased().hasPrefix(normalized) }
    }

    public func setDefault(_ voice: Voice) {
        defaultVoiceID = voice.id
        defaults.set(voice.id, forKey: defaultKey)
    }

    public func toggleFavorite(_ voice: Voice) {
        if favorites.contains(voice.id) {
            favorites.remove(voice.id)
        } else {
            favorites.insert(voice.id)
        }
        defaults.set(Array(favorites), forKey: favoritesKey)
    }

    public func isFavorite(_ voice: Voice) -> Bool {
        favorites.contains(voice.id)
    }

    /// A good first voice for the model: the user's language when available,
    /// then the first voice in the model's catalogue.
    private func bestDefaultVoiceID() -> String? {
        let preferred = Locale.current.language.languageCode?.identifier ?? "en"
        return voices.first { $0.language.lowercased().hasPrefix(preferred) }?.id
            ?? voices.first?.id
    }
}
