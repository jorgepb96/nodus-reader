// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Testing
@testable import Nodus_Reader

private func music(_ id: String, mood: MusicMood = .tense, style: SoundscapeStyle = .neutral,
                   emotions: [SceneEmotion] = [], situations: [SceneSituation] = [],
                   intensity: Int = 2, study: Bool = false) -> SoundscapePrompt {
    SoundscapePrompt(id: id, layer: .music, text: "x", style: style, mood: mood, bed: nil, setting: nil,
                     emotions: emotions, situations: situations, intensity: intensity, energy: 1, studySafe: study)
}

private func bed(_ id: String, _ bed: BaseAmbience, style: SoundscapeStyle? = nil, setting: SceneSetting? = nil) -> SoundscapePrompt {
    SoundscapePrompt(id: id, layer: .ambience, text: "x", style: style, mood: nil, bed: bed, setting: setting,
                     emotions: [], situations: [], intensity: 1, energy: 0, studySafe: true)
}

private func request(_ mood: MusicMood = .tense, style: SoundscapeStyle = .noir, emotion: SceneEmotion? = nil,
                     situation: SceneSituation? = nil, intensity: Int = 2, study: Bool = false) -> PromptRequest {
    PromptRequest(layer: .music, style: style, mood: mood, bed: nil, emotion: emotion, situation: situation,
                  intensity: intensity, setting: nil, studyOnly: study)
}

@Suite("Prompt selector")
struct PromptSelectorTests {
    @Test func moodIsMandatory() {
        let library = PromptLibrary(version: "t", prompts: [music("a", mood: .calm)])
        #expect(PromptSelector.select(request(.tense), from: library, used: [], seed: 1) == nil)
    }

    @Test func styleBeatsNeutralBeatsOtherStyle() {
        let library = PromptLibrary(version: "t", prompts: [music("neutral"), music("noir", style: .noir),
                                                            music("western", style: .western)])
        #expect(PromptSelector.select(request(style: .noir), from: library, used: [], seed: 1)?.id == "noir")
        #expect(PromptSelector.select(request(style: .fantasy), from: library, used: [], seed: 1)?.id == "neutral")
        let onlyOther = PromptLibrary(version: "t", prompts: [music("western", style: .western)])
        #expect(PromptSelector.select(request(style: .noir), from: onlyOther, used: [], seed: 1) == nil)
    }

    @Test func emotionAndSituationScore() {
        // Neutral (+1) with emotion (+2) and situation (+2) beats same style (+3) without.
        let library = PromptLibrary(version: "t", prompts: [
            music("noir", style: .noir),
            music("neutral-fit", emotions: [.fear], situations: [.chase]),
        ])
        #expect(PromptSelector.select(request(emotion: .fear, situation: .chase), from: library, used: [], seed: 1)?.id == "neutral-fit")
        #expect(PromptSelector.score(music("neutral-fit", emotions: [.fear], situations: [.chase]),
                                     for: request(emotion: .fear, situation: .chase), used: []) == 5)
    }

    @Test func intensityPenalty() {
        let library = PromptLibrary(version: "t", prompts: [music("soft", style: .noir, intensity: 1),
                                                            music("strong", style: .noir, intensity: 3)])
        #expect(PromptSelector.select(request(intensity: 3), from: library, used: [], seed: 1)?.id == "strong")
        #expect(PromptSelector.score(music("soft", style: .noir, intensity: 1), for: request(intensity: 3), used: []) == 1)
    }

    @Test func usedPenalty() {
        let library = PromptLibrary(version: "t", prompts: [music("a", style: .noir), music("b", style: .noir)])
        let first = PromptSelector.select(request(), from: library, used: [], seed: 1)!
        let second = PromptSelector.select(request(), from: library, used: [first.id], seed: 1)!
        #expect(first.id != second.id)
        #expect(PromptSelector.score(music("a", style: .noir), for: request(), used: ["a"]) == 1)
    }

    @Test func studyOnlyFilters() {
        let library = PromptLibrary(version: "t", prompts: [music("loud", style: .noir), music("quiet", study: true)])
        #expect(PromptSelector.select(request(study: true), from: library, used: [], seed: 1)?.id == "quiet")
    }

    @Test func deterministicForSeed() {
        let library = PromptLibrary(version: "t", prompts: (0 ..< 8).map { music("p\($0)", style: .noir) })
        let a = PromptSelector.select(request(), from: library, used: [], seed: 42)
        #expect(a == PromptSelector.select(request(), from: library, used: [], seed: 42))
    }

    @Test func differentSeedsCanBreakTies() {
        let library = PromptLibrary(version: "t", prompts: (0 ..< 8).map { music("p\($0)", style: .noir) })
        let picks = Set((0 ..< 20).compactMap { PromptSelector.select(request(), from: library, used: [], seed: UInt64($0))?.id })
        #expect(picks.count > 1)
    }

    @Test func ambienceMatchesBedStyleAndSetting() {
        let library = PromptLibrary(version: "t", prompts: [bed("plain", .rain), bed("neon", .rain, style: .cyberpunk),
                                                            bed("tent", .rain, setting: .countryside), bed("storm", .storm)])
        var ambience = PromptRequest(layer: .ambience, style: .cyberpunk, mood: nil, bed: .rain, emotion: nil,
                                     situation: nil, intensity: 1, setting: nil, studyOnly: false)
        #expect(PromptSelector.select(ambience, from: library, used: [], seed: 1)?.id == "neon")
        ambience.style = .neutral
        ambience.setting = .countryside
        #expect(PromptSelector.select(ambience, from: library, used: [], seed: 1)?.id == "tent")
    }

    @Test func bundledLibraryAnswersEveryMoodAndStyle() throws {
        let library = try PromptLibrary.bundled()
        for mood in MusicMood.allCases {
            for style in SoundscapeStyle.allCases {
                #expect(PromptSelector.select(request(mood, style: style), from: library, used: [], seed: 3) != nil, "\(mood) \(style)")
            }
        }
    }
}
