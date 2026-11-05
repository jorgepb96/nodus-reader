// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

struct VoiceSelectionSnapshot: Codable, Equatable {
    var id: String
    var language: String?
    var gender: VoiceGender?
    var revision: UUID

    @MainActor static func capture(_ id: String, voice: VoiceCatalog.Voice? = nil) -> Self {
        let known = ModelManager.catalogModels.flatMap(\.voices)
        let item = known.first { $0.id == id }
        return .init(id: id, language: voice?.language ?? item?.language,
                     gender: voice?.gender ?? item?.gender, revision: UUID())
    }
}

/// Device-only effective selections never overwrite the book's synced manual preference.
@MainActor
final class VoiceSelectionResolver {
    struct Replacement: Codable {
        var manualID: String?
        var manualRevision: UUID?
        var effective: VoiceSelectionSnapshot
    }
    private let defaults: UserDefaults
    private var replacements: [String: Replacement]
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        replacements = defaults.data(forKey: "nodus.voiceReplacements.v1")
            .flatMap { try? JSONDecoder().decode([String: Replacement].self, from: $0) } ?? [:]
    }
    func resolve(book: Book, catalog: VoiceCatalog, commit: Bool) -> VoiceCatalog.Voice? {
        let snapshot = book.preferredVoiceSnapshotJSON.data(using: .utf8)
            .flatMap { try? JSONDecoder().decode(VoiceSelectionSnapshot.self, from: $0) }
            .flatMap { $0.id == book.preferredVoiceID ? $0 : nil }
        let key = book.id.uuidString
        let saved = replacements[key].flatMap { $0.manualID == book.preferredVoiceID && $0.manualRevision == snapshot?.revision ? $0 : nil }
        let requested = saved?.effective.id ?? book.preferredVoiceID ?? catalog.defaultVoiceID
        if let voice = catalog.voice(withID: requested) { return voice }
        let descriptor = saved?.effective ?? snapshot ?? VoiceSelectionSnapshot.capture(requested)
        let language = descriptor.language ?? (book.language.isEmpty ? Locale.current.identifier : book.language)
        guard let voice = VoiceCatalog.replacement(in: catalog.allInstalledVoices, language: language,
                                                   gender: descriptor.gender, defaultID: catalog.defaultVoiceID) else { return nil }
        if commit {
            replacements[key] = Replacement(manualID: book.preferredVoiceID, manualRevision: snapshot?.revision,
                                            effective: .capture(voice.id, voice: voice))
            if let data = try? JSONEncoder().encode(replacements) { defaults.set(data, forKey: "nodus.voiceReplacements.v1") }
        }
        return voice
    }
    func clear(bookID: UUID) {
        replacements.removeValue(forKey: bookID.uuidString)
        if let data = try? JSONEncoder().encode(replacements) { defaults.set(data, forKey: "nodus.voiceReplacements.v1") }
    }
}
