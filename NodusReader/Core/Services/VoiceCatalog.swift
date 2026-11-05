// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Observation
#if os(iOS)
import AVFoundation
#endif

/// A voice's gender as its publisher lists it. Voices without one (Phonon's
/// base and character voices) appear only when no gender filter is chosen.
public enum VoiceGender: String, Codable, CaseIterable, Hashable, Sendable {
    case female
    case male

    public var label: String {
        switch self {
        case .female: String(localized: "Female")
        case .male: String(localized: "Male")
        }
    }
}

/// Downloaded voices plus Apple's available voices on iOS. The inventory stays on device.
@MainActor
@Observable
public final class VoiceCatalog {
    public struct Voice: Identifiable, Hashable, Sendable {
        public var id: String
        public var name: String
        public var language: String
        public var languageName: String
        public var quality: Int
        public var gender: VoiceGender?
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

        /// A voice the user cloned (or the bundled clip) in Studio.
        public var isStudio: Bool { id.hasPrefix(StudioVoiceStore.voiceIDPrefix) || id.hasPrefix(QwenSpeech.clonePrefix) }

        public var engineLabel: String {
            if let modelName { return modelName }
            switch engineRaw {
            case "system": return String(localized: "iOS voices")
            case "kokoro": return "Kokoro"
            case "phonon": return "Phonon"
            case "qwen": return "Qwen"
            case "linnet": return "LinnetTTS"
            default: return String(localized: "Neural voice")
            }
        }
    }

    /// Voices of the global model. A book's own voice can belong to any
    /// installed model, independently of this selection.
    public private(set) var voices: [Voice] = []
    /// Voices of every installed neural model, selected or not. The Voices
    /// screen lists them so any model can be tried.
    public private(set) var systemVoices: [Voice] = []
    public private(set) var installedNeuralVoices: [Voice] = []
    public private(set) var favorites: Set<String> = []
    public private(set) var isLoading = false
    public var defaultVoiceID: String

    private let defaults: UserDefaults
    private let favoritesKey = "nodus.voices.favorites"
    private let defaultKey = "nodus.voices.default"
    static var systemLanguageCodes: [String] = []
    var onSystemVoicesChanged: (() -> Void)?
    @ObservationIgnored private var systemLoadTask: Task<Void, Never>?


    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.favorites = Set(defaults.stringArray(forKey: favoritesKey) ?? [])
        self.defaultVoiceID = defaults.string(forKey: defaultKey) ?? ""
        #if os(iOS)
        NotificationCenter.default.addObserver(forName: AVSpeechSynthesizer.availableVoicesDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshSystemVoices() }
        }
        #endif
    }

    /// Kept as the single asynchronous entry point used by screens that open
    /// before ModelManager publishes the installed neural catalogue.
    public func loadIfNeeded() async {
        if systemVoices.isEmpty { refreshSystemVoices() }
        await systemLoadTask?.value
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
        let available = allInstalledVoices
        if let exact = available.first(where: {
            $0.id == id && (engine == nil || $0.engineRaw == engine)
        }) {
            return exact
        }
        // Older builds saved Spanish Phonon voices as "phonon:<name>".
        // Current IDs include the checkpoint so equal names stay distinct.
        guard id.hasPrefix("phonon:"), engine == nil || engine == "phonon" else { return nil }
        let name = String(id.dropFirst("phonon:".count))
        return available.first {
            $0.modelID == "phonon-40m-es" && $0.name == name
        }
    }

    /// Voices of every installed neural model.
    public var allInstalledVoices: [Voice] { installedNeuralVoices.filter { $0.engineRaw != "system" } + systemVoices }

    /// Resolves a saved per-book voice ID to a real installed neural voice.
    /// Voice IDs identify the engine and checkpoint as well as the voice.
    /// A missing voice uses a temporary language-aware fallback; callers
    /// retain the saved preference so reinstalling its model restores it.
    public func narrationVoice(preferredID: String?, language: String?) -> Voice? {
        if let exact = voice(withID: preferredID) { return exact }
        return Self.replacement(in: allInstalledVoices, language: language, gender: nil, defaultID: defaultVoiceID)
    }

    public func refreshSystemVoices() {
        #if os(iOS)
        guard systemLoadTask == nil else { return }
        if systemVoices.isEmpty { isLoading = true }
        systemLoadTask = Task { [weak self] in
            let entries = await Task.detached(priority: .userInitiated) {
                AVSpeechSynthesisVoice.speechVoices().filter {
                    !$0.voiceTraits.contains(.isPersonalVoice) && !$0.voiceTraits.contains(.isNoveltyVoice)
                }.map { voice in
                    SystemVoiceDescriptor(id: voice.identifier, name: voice.name, language: voice.language,
                        quality: voice.quality.rawValue,
                        gender: voice.gender == .male ? .male : voice.gender == .female ? .female : nil)
                }
            }.value
            guard let self else { return }
            self.systemVoices = entries.map {
                Voice(id: $0.id, name: $0.name, language: $0.language,
                    languageName: Self.variantName(for: $0.language), quality: $0.quality, gender: $0.gender,
                    engineRaw: "system", modelID: "ios-system", modelName: String(localized: "iOS voices"))
            }
            Self.systemLanguageCodes = Array(Set(entries.map(\.language))).sorted()
            if self.voices.first?.engineRaw == "system" { self.voices = self.systemVoices }
            self.isLoading = false
            self.systemLoadTask = nil
            self.onSystemVoicesChanged?()
        }
        #endif
    }

    public static func replacement(in available: [Voice], language: String?, gender: VoiceGender?, defaultID: String) -> Voice? {
        let language = language.flatMap { $0.isEmpty ? nil : $0 } ?? Locale.current.identifier
        let matches = available.filter { languageCode($0.language) == languageCode(language) }
        return matches.sorted { a, b in
            func tier(_ v: Voice) -> Int {
                (v.engineRaw == "system" ? 2 : 0) + (gender == nil || v.gender == gender ? 0 : 1)
            }
            if tier(a) != tier(b) { return tier(a) < tier(b) }
            let exactA = a.language.lowercased() == language.replacingOccurrences(of: "_", with: "-").lowercased()
            let exactB = b.language.lowercased() == language.replacingOccurrences(of: "_", with: "-").lowercased()
            if exactA != exactB { return exactA }
            if (a.id == defaultID) != (b.id == defaultID) { return a.id == defaultID }
            if a.quality != b.quality { return a.quality > b.quality }
            return a.id < b.id
        }.first
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
    /// The genders present among `voices`, for a filter that offers only
    /// choices that match something.
    public static func genders(of voices: [Voice]) -> [VoiceGender] {
        VoiceGender.allCases.filter { gender in voices.contains { $0.gender == gender } }
    }

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
        if let data = try? JSONEncoder().encode(VoiceSelectionSnapshot.capture(voice.id, voice: voice)) {
            defaults.set(data, forKey: "nodus.voices.defaultSnapshot")
        }
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


private struct SystemVoiceDescriptor: Sendable {
    var id: String
    var name: String
    var language: String
    var quality: Int
    var gender: VoiceGender?
}
