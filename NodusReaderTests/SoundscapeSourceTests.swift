// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Testing
@testable import Nodus_Reader

private func generated(_ id: String) -> CatalogTrack {
    GeneratedPiece(id: id, promptID: "p", promptText: "t", seed: 1, layer: .music, style: .noir, mood: .tense, bed: nil,
                   emotions: [], situations: [], intensity: 2, energy: 1, studySafe: false, fileName: "\(id).m4a",
                   frames: 1, sampleRate: 44_100, bitRate: 1, tailStart: nil, gainDB: 0, lufs: -20, truePeak: -2,
                   created: Date(), lastPlayed: nil, plays: 0, favorite: false, bookIDs: [], modelRevision: "r",
                   engineVersion: 1).track
}

private func downloaded(_ id: String) -> CatalogTrack {
    var track = generated(id)
    track.semantics.origin = nil
    return track
}

private let first: ([CatalogTrack]) -> CatalogTrack? = { $0.first }

@Suite("Soundscape source")
struct SoundscapeSourceTests {
    @Test func aiPrefersGenerated() {
        #expect(SoundscapeSourcePicker.decide(source: .ai, generated: [generated("g")], downloaded: [downloaded("d")],
                                              currentID: nil, pick: first) == .play(generated("g")))
    }

    @Test func aiSourceWithEmptyCacheFallsBackToDownloaded() {
        #expect(SoundscapeSourcePicker.decide(source: .ai, generated: [], downloaded: [downloaded("d")],
                                              currentID: nil, pick: first) == .play(downloaded("d")))
    }

    @Test func aiSourceKeepsPlayingWhenNothingReady() {
        #expect(SoundscapeSourcePicker.decide(source: .ai, generated: [], downloaded: [], currentID: "playing",
                                              pick: first) == .keep)
        #expect(SoundscapeSourcePicker.decide(source: .ai, generated: [], downloaded: [], currentID: nil,
                                              pick: first) == .stop)
    }

    @Test func downloadedSourceIgnoresGenerated() {
        #expect(SoundscapeSourcePicker.decide(source: .downloaded, generated: [generated("g")], downloaded: [],
                                              currentID: "playing", pick: first) == .stop)
    }

    @Test func sourcePreferencePersists() {
        let defaults = UserDefaults(suiteName: "source.\(UUID())")!
        let preferences = ImmersiveAudioPreferences(defaults: defaults)
        #expect(preferences.source == .downloaded && preferences.generatedBudgetMB == 500)
        preferences.source = .ai
        preferences.generatedBudgetMB = 1_000
        let reloaded = ImmersiveAudioPreferences(defaults: defaults)
        #expect(reloaded.source == .ai && reloaded.generatedBudgetMB == 1_000)
    }
}
