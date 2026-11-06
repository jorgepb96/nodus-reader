// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Testing
@testable import Nodus_Reader

@Suite("Prompt library")
struct PromptLibraryTests {
    let library = try! PromptLibrary.bundled()

    private func words(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber && $0 != "'" && $0 != "-" }.map(String.init)
    }

    @Test func bundledLibraryDecodes() {
        #expect(library.prompts.count >= 280 && library.prompts.count <= 320)
        #expect(Set(library.prompts.map(\.id)).count == library.prompts.count)
    }

    @Test func textLengthAndEndings() {
        for prompt in library.prompts {
            let count = words(prompt.text).count
            #expect(count >= 8 && count <= 20, "\(prompt.id): \(count) words")
            if prompt.layer == .music {
                #expect(prompt.text.hasSuffix("no vocals."), "\(prompt.id)")
            } else {
                #expect(prompt.text.hasSuffix("no music or voices."), "\(prompt.id)")
            }
        }
    }

    @Test func musicHasMoodSfxHasBed() {
        for prompt in library.prompts {
            if prompt.layer == .music {
                #expect(prompt.mood != nil && prompt.bed == nil, "\(prompt.id)")
            } else {
                #expect(prompt.bed != nil && prompt.bed != BaseAmbience.none && prompt.mood == nil, "\(prompt.id)")
            }
            #expect((1 ... 3).contains(prompt.intensity) && (0 ... 3).contains(prompt.energy), "\(prompt.id)")
        }
    }

    @Test func noNearDuplicates() {
        let groups = Dictionary(grouping: library.prompts) {
            "\($0.layer.rawValue)|\($0.style?.rawValue ?? "-")|\($0.mood?.rawValue ?? "-")|\($0.bed?.rawValue ?? "-")"
        }
        for group in groups.values where group.count > 1 {
            for i in group.indices {
                for j in group.indices where j > i {
                    let a = Set(words(group[i].text)), b = Set(words(group[j].text))
                    let jaccard = Double(a.intersection(b).count) / Double(a.union(b).count)
                    #expect(jaccard <= 0.7, "\(group[i].id) ~ \(group[j].id): \(jaccard)")
                }
            }
        }
    }

    @Test func everyMoodHasNeutralPrompt() {
        for mood in MusicMood.allCases {
            #expect(library.prompts.contains { $0.mood == mood && $0.style == .neutral }, "\(mood)")
        }
    }

    @Test func everyBedHasThreeVariants() {
        for bed in BaseAmbience.allCases where bed != .none {
            #expect(library.prompts.filter { $0.bed == bed }.count >= 3, "\(bed)")
        }
    }

    @Test func everyStyleIsUsed() {
        for style in SoundscapeStyle.allCases {
            #expect(library.prompts.contains { $0.style == style && $0.layer == .music }, "\(style)")
        }
    }

    @Test func deriveFollowsToneAndAction() {
        #expect(SoundscapeVocabulary.derive(tone: .eerie, action: .chase, intensity: 3) == (.dread, .chase))
        #expect(SoundscapeVocabulary.derive(tone: .melancholic, action: .rest, intensity: 1) == (.sadness, .rest))
        #expect(SoundscapeVocabulary.derive(tone: .neutral, action: .conversation, intensity: 1) == (nil, nil))
        #expect(SoundscapeVocabulary.derive(tone: .comic, action: .celebration, intensity: 2) == (.absurd, .celebration))
    }
}
