// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Testing
@testable import Nodus_Reader

private func eerieReading() -> SceneReading {
    SceneReading(passageKind: .scene, setting: .forest, settingClarity: 3, weather: .clear, tone: .eerie, action: .exploration,
                 intensity: 3, sceneChange: .none, evidence: "the trees", evidenceVerified: true, source: .contentTagging)
}

private func map(readings: [SceneReading?]) -> SceneMap {
    var windows: [SceneWindow] = []
    var status: [Int: WindowStatus] = [:]
    for (index, item) in readings.enumerated() {
        windows.append(SceneWindow(index: index, start: index * 3_000, end: (index + 1) * 3_000, chapter: 0,
                                   startsChapter: index == 0, startsAfterSceneBreak: false))
        if let item { status[index] = .analysed(item) }
    }
    var map = SceneMap(contentKey: "k", language: "en", windows: windows, status: status)
    map.profile = DocumentProfile(kind: .fiction, source: .model, votes: [.fiction], signals: .empty)
    return map
}

private func input(current: Atmosphere?, map: SceneMap? = nil, inventory: @escaping (PromptRequest) -> Int = { _ in 0 }) -> PlannerInput {
    PlannerInput(map: map, position: 0, current: current, style: .noir, intensity: .expressive, inventory: inventory,
                 used: [], studyOnly: false, bookID: nil, musicEnabled: true, ambienceEnabled: true)
}

@Suite("Soundscape planner")
struct SoundscapePlannerTests {
    let library = try! PromptLibrary.bundled()

    @Test func currentMoodNeedsTwoPieces() {
        let jobs = SoundscapePlanner.plan(input(current: Atmosphere(base: .none, music: .tense)), library: library, seed: 1)
        let tense = jobs.filter { $0.request.mood == .tense && $0.priority == 3 }
        #expect(tense.count == 2)
        #expect(Set(tense.map(\.prompt.id)).count == 2)
        #expect(tense.allSatisfy { $0.recipe == .music && $0.request.style == .noir })
    }

    @Test func currentBedNeedsOnePiece() {
        let jobs = SoundscapePlanner.plan(input(current: Atmosphere(base: .rain, music: nil)), library: library, seed: 1)
        #expect(jobs.filter { $0.request.bed == .rain && $0.priority == 3 }.count == 1)
        let covered = SoundscapePlanner.plan(input(current: Atmosphere(base: .rain, music: nil), inventory: { _ in 1 }),
                                             library: library, seed: 1)
        #expect(covered.filter { $0.request.bed == .rain && $0.priority == 3 }.isEmpty)
    }

    @Test func challengersGetOnePiece() {
        let ahead = map(readings: Array(repeating: eerieReading(), count: 6))
        let jobs = SoundscapePlanner.plan(input(current: Atmosphere(base: .none, music: .calm), map: ahead,
                                                inventory: { $0.mood == .calm ? 4 : 0 }), library: library, seed: 1)
        let eerie = jobs.filter { $0.request.mood == .eerie }
        #expect(eerie.count == 1 && eerie[0].priority == 2)
        #expect(eerie[0].request.emotion == .dread && eerie[0].request.situation == .discovery)
    }

    @Test func varietyCappedAtFour() {
        let three = SoundscapePlanner.plan(input(current: Atmosphere(base: .none, music: .tense), inventory: { _ in 3 }),
                                           library: library, seed: 1)
        #expect(three.filter { $0.request.mood == .tense && $0.priority == 1 }.count == 1)
        let four = SoundscapePlanner.plan(input(current: Atmosphere(base: .none, music: .tense), inventory: { _ in 4 }),
                                          library: library, seed: 1)
        #expect(four.isEmpty)
    }

    @Test func queueDedupedAndCapped() {
        let ahead = map(readings: Array(repeating: eerieReading(), count: 10))
        let jobs = SoundscapePlanner.plan(input(current: Atmosphere(base: .rain, music: .tense), map: ahead), library: library, seed: 1)
        #expect(jobs.count <= 6)
        #expect(Set(jobs.map(\.key)).count == jobs.count)
        #expect(jobs.map(\.priority) == jobs.map(\.priority).sorted(by: >))
    }

    @Test func disabledLayersAreNotPlanned() {
        var only = input(current: Atmosphere(base: .rain, music: .tense))
        only.musicEnabled = false
        #expect(SoundscapePlanner.plan(only, library: library, seed: 1).allSatisfy { $0.request.layer == .ambience })
    }

    @Test func starterPackSize() {
        let jobs = SoundscapePlanner.starterPack(style: .western, map: nil, bookID: nil, library: library, seed: 1)
        #expect(jobs.filter { $0.request.layer == .music }.count == 6)
        #expect(jobs.filter { $0.request.layer == .ambience }.count == 3)
        #expect(jobs.contains { $0.request.mood == .calm })
        #expect(Set(jobs.map(\.key)).count == jobs.count)
    }

    /// A three-page document does not need nine pieces: the pack follows the listening time.
    @Test func starterPackScalesWithLength() {
        func count(_ characters: Int?, _ layer: CatalogTrack.Layer) -> Int {
            SoundscapePlanner.starterPack(style: .western, map: nil, bookID: nil, library: library, seed: 1,
                                          textLength: characters).filter { $0.request.layer == layer }.count
        }
        #expect(count(6_000, .music) == 2 && count(6_000, .ambience) == 1)
        #expect(count(40_000, .music) == 6 && count(40_000, .ambience) == 2)
        #expect(count(2_000_000, .music) == 6 && count(2_000_000, .ambience) == 3)
        #expect(count(300, .music) == 1)
    }

    @Test func singleJobForAChosenBed() throws {
        let job = try #require(SoundscapePlanner.job(layer: .ambience, mood: nil, bed: .fireplace, style: .noir,
                                                     bookID: nil, library: library, seed: 3, priority: 30))
        #expect(job.request.bed == .fireplace && job.priority == 30 && job.recipe.layer == .ambience)
        // A piece wanted now is the quick recipe: it plays within seconds.
        #expect(job.recipe == .shortAmbience)
    }
}
