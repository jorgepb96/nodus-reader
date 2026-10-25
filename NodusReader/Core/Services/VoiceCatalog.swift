// SPDX-License-Identifier: AGPL-3.0-only
import AVFoundation
import Foundation
import Observation

/// The installed system voices. Nodus Reader never syncs or uploads them.
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

        public var qualityLabel: String {
            switch quality {
            case 3: "Premium"
            case 2: "Enhanced"
            default: "Standard"
            }
        }

        public var displayName: String { name }

        public var engineLabel: String {
            switch engineRaw {
            case "kokoro": "Kokoro"
            case "phonon": "Phonon"
            default: "System"
            }
        }

        public var isSystem: Bool { engineRaw == "system" }
    }

    public private(set) var voices: [Voice] = []
    public private(set) var favorites: Set<String> = []
    public private(set) var isLoading = true
    public var defaultVoiceID: String

    private let defaults: UserDefaults
    private let favoritesKey = "nodus.voices.favorites"
    private let defaultKey = "nodus.voices.default"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.favorites = Set(defaults.stringArray(forKey: favoritesKey) ?? [])
        self.defaultVoiceID = defaults.string(forKey: defaultKey) ?? ""
    }

    public func reload() {
        voices.removeAll { $0.isSystem }
        Task { await loadVoices() }
    }

    /// Enumerating system voices can take time on first launch. It is kept off
    /// the main thread so the interface appears immediately. A populated neural
    /// catalogue must not stop the system voices from loading.
    public func loadIfNeeded() async {
        guard !voices.contains(where: { $0.isSystem }) else { return }
        await loadVoices()
    }

    private func loadVoices() async {
        isLoading = true
        let mapped = await Task.detached(priority: .userInitiated) {
            AVSpeechSynthesisVoice.speechVoices().map { voice in
                Voice(
                    id: voice.identifier,
                    name: voice.name,
                    language: voice.language,
                    languageName: Locale.current.localizedString(forLanguageCode: voice.language)
                        ?? voice.language,
                    quality: Int(voice.quality.rawValue),
                    gender: voice.gender.rawValue == 0 ? nil : String(describing: voice.gender),
                    engineRaw: "system"
                )
            }
        }.value
        guard !mapped.isEmpty else {
            isLoading = false
            return
        }
        let neural = voices.filter { !$0.isSystem }
        let preferredLanguage = Locale.current.language.languageCode?.identifier ?? "en"
        voices = mapped.sorted { lhs, rhs in
            let lhsPreferred = lhs.language.hasPrefix(preferredLanguage)
            let rhsPreferred = rhs.language.hasPrefix(preferredLanguage)
            if lhsPreferred != rhsPreferred { return lhsPreferred }
            if lhs.language == rhs.language {
                if lhs.quality != rhs.quality { return lhs.quality > rhs.quality }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
            return lhs.languageName.localizedStandardCompare(rhs.languageName) == .orderedAscending
        }
        voices.append(contentsOf: neural)
        if defaultVoiceID.isEmpty || !voices.contains(where: { $0.id == defaultVoiceID }) {
            defaultVoiceID = bestDefaultVoiceID() ?? mapped.first?.id ?? ""
            defaults.set(defaultVoiceID, forKey: defaultKey)
        }
        isLoading = false
    }

    /// Replaces the neural voices while leaving the system catalogue untouched.
    /// Called when a model is installed, deleted or loaded at launch.
    public func setNeuralVoices(_ neural: [Voice]) {
        voices.removeAll { !$0.isSystem }
        voices.append(contentsOf: neural)
        if !defaultVoiceID.isEmpty, !voices.contains(where: { $0.id == defaultVoiceID }) {
            defaultVoiceID = bestDefaultVoiceID() ?? voices.first?.id ?? ""
            defaults.set(defaultVoiceID, forKey: defaultKey)
        }
    }

    public var neuralVoices: [Voice] {
        voices.filter { !$0.isSystem }
    }

    public func voice(withID id: String?,
                      engine: String? = nil) -> Voice? {
        guard let id else { return nil }
        return voices.first { $0.id == id && (engine == nil || $0.engineRaw == engine) }
    }

    /// Resolves a saved per-book voice ID to a real entry in this catalogue.
    /// A missing neural voice falls back to a system voice for the book's
    /// language, so a deleted model never breaks narration.
    public func narrationVoice(preferredID: String?, language: String?) -> Voice? {
        if let preferredID, let exact = voices.first(where: { $0.id == preferredID }) {
            return exact
        }
        if let language {
            let prefix = String(language.prefix(2)).lowercased()
            let matching = voices.filter { $0.language.lowercased().hasPrefix(prefix) }
            // A selected neural engine is the user's explicit choice; a system
            // voice is the fallback when that engine has no voice for the book.
            if let neural = matching.first(where: { !$0.isSystem }) {
                return neural
            }
            if let match = matching.first(where: { $0.quality >= 3 })
                ?? matching.first(where: { $0.quality >= 2 })
                ?? matching.first {
                return match
            }
        }
        return defaultVoice
    }

    public func systemVoice(for voice: Voice?) -> AVSpeechSynthesisVoice? {
        if let voice, let resolved = AVSpeechSynthesisVoice(identifier: voice.id) {
            return resolved
        }
        if let chosen = AVSpeechSynthesisVoice(identifier: defaultVoiceID) {
            return chosen
        }
        return fallbackVoice()
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
        Locale.current.localizedString(forLanguageCode: code) ?? code
    }

    /// "English (United Kingdom)" for `en-GB`; the plain language name when
    /// the code has no region.
    public static func variantName(for code: String) -> String {
        let identifier = code.replacingOccurrences(of: "-", with: "_")
        return Locale.current.localizedString(forIdentifier: identifier)
            ?? Locale.current.localizedString(forLanguageCode: code)
            ?? code
    }

    public var defaultVoice: Voice? {
        voice(withID: defaultVoiceID) ?? voices.first
    }

    /// A good installed system voice for the user's language, used when the
    /// selected neural model is removed or the user switches back to System.
    public var bestSystemVoice: Voice? {
        let preferred = Locale.current.language.languageCode?.identifier ?? "en"
        let candidates = voices.filter { $0.isSystem && $0.language.hasPrefix(preferred) }
        return candidates.first { $0.quality == 3 }
            ?? candidates.first { $0.quality == 2 }
            ?? candidates.first
            ?? voices.first { $0.isSystem }
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

    /// A voice that actually exists on this device, preferring the user's
    /// language and higher quality. Used when a synced per-book voice is missing.
    public func resolvedVoice(preferredID: String?, language: String?) -> AVSpeechSynthesisVoice? {
        if let preferredID, let chosen = AVSpeechSynthesisVoice(identifier: preferredID) {
            return chosen
        }
        if let language {
            let prefix = String(language.prefix(2)).lowercased()
            if let match = voices.first(where: { $0.language.lowercased().hasPrefix(prefix) && $0.quality >= 2 })
                ?? voices.first(where: { $0.language.hasPrefix(prefix) }),
               let voice = AVSpeechSynthesisVoice(identifier: match.id) {
                return voice
            }
        }
        if let chosen = AVSpeechSynthesisVoice(identifier: defaultVoiceID) {
            return chosen
        }
        return fallbackVoice()
    }

    private func fallbackVoice() -> AVSpeechSynthesisVoice? {
        AVSpeechSynthesisVoice(language: "en-US")
    }

    private func bestDefaultVoiceID() -> String? {
        let preferred = Locale.current.language.languageCode?.identifier ?? "en"
        let candidates = voices.filter { $0.language.hasPrefix(preferred) }
        return (candidates.first { $0.quality == 3 }
            ?? candidates.first { $0.quality == 2 }
            ?? candidates.first)?.id
    }
}
