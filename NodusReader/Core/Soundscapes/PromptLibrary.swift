// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// One short English prompt for Stable Audio 3 Small with what it is for.
struct SoundscapePrompt: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var layer: CatalogTrack.Layer
    var text: String
    /// nil for ambience that suits every style.
    var style: SoundscapeStyle?
    var mood: MusicMood?
    var bed: BaseAmbience?
    var setting: SceneSetting?
    var emotions: [SceneEmotion]
    var situations: [SceneSituation]
    /// 1 gentle … 3 strong.
    var intensity: Int
    /// 0 still … 3 driving, as in the catalog.
    var energy: Int
    var studySafe: Bool

    /// The text sent to the model: music gets the tags Stability's prompt guide
    /// recommends for coherent instrumentals.
    var modelText: String {
        layer == .music ? "TrackType: Music, VocalType: Instrumental. " + text : text
    }
}

/// The bundled, versioned prompt library (`Resources/Soundscapes/prompts.json`).
struct PromptLibrary: Sendable {
    let version: String
    let prompts: [SoundscapePrompt]

    private struct File: Codable {
        var version: String
        var prompts: [SoundscapePrompt]
    }

    init(version: String, prompts: [SoundscapePrompt]) {
        self.version = version
        self.prompts = prompts
    }

    static func bundled(bundle: Bundle = .main) throws -> PromptLibrary {
        let url = bundle.url(forResource: "prompts", withExtension: "json", subdirectory: "Soundscapes")
            ?? bundle.url(forResource: "prompts", withExtension: "json")
        guard let url else { throw CocoaError(.fileNoSuchFile) }
        let file = try JSONDecoder().decode(File.self, from: Data(contentsOf: url))
        return PromptLibrary(version: file.version, prompts: file.prompts)
    }
}
