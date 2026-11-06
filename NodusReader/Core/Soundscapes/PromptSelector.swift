// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// What a piece is for: the mood (or bed) the director plays, refined by the book's
/// style and the passage's emotion and situation.
struct PromptRequest: Hashable, Sendable, Codable {
    var layer: CatalogTrack.Layer
    var style: SoundscapeStyle
    var mood: MusicMood?
    var bed: BaseAmbience?
    var emotion: SceneEmotion?
    var situation: SceneSituation?
    var intensity: Int
    var setting: SceneSetting?
    var studyOnly: Bool
}

/// Chooses a prompt. Pure and deterministic: the same request, history and seed always
/// give the same prompt.
enum PromptSelector {
    static func select(_ request: PromptRequest, from library: PromptLibrary, used: Set<String>,
                       seed: UInt64) -> SoundscapePrompt? {
        var best: (prompt: SoundscapePrompt, score: Int, tie: UInt64)?
        for prompt in library.prompts {
            guard let score = score(prompt, for: request, used: used) else { continue }
            let tie = fnv1a("\(seed)|\(prompt.id)")
            if best == nil || score > best!.score || (score == best!.score && tie < best!.tie) {
                best = (prompt, score, tie)
            }
        }
        return best?.prompt
    }

    /// nil when the prompt cannot serve the request. Same style +3, a neutral prompt +1
    /// (another style is excluded), matching emotion +2, situation +2, setting +1, −1 per
    /// level of intensity difference, −2 if already used for this book.
    static func score(_ prompt: SoundscapePrompt, for request: PromptRequest, used: Set<String>) -> Int? {
        guard prompt.layer == request.layer else { return nil }
        switch request.layer {
        case .music: guard let mood = request.mood, prompt.mood == mood else { return nil }
        case .ambience: guard let bed = request.bed, prompt.bed == bed else { return nil }
        }
        if request.studyOnly, !prompt.studySafe { return nil }
        var score = 0
        let style = prompt.style ?? .neutral
        if style == request.style {
            score += 3
        } else if style == .neutral {
            score += 1
        } else {
            return nil
        }
        if let emotion = request.emotion, prompt.emotions.contains(emotion) { score += 2 }
        if let situation = request.situation, prompt.situations.contains(situation) { score += 2 }
        if let setting = request.setting, prompt.setting == setting { score += 1 }
        score -= abs(prompt.intensity - request.intensity)
        if used.contains(prompt.id) { score -= 2 }
        return score
    }

    static func fnv1a(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return hash
    }
}
