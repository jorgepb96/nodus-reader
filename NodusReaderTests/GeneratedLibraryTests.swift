// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Testing
@testable import Nodus_Reader

private func piece(_ id: String, layer: CatalogTrack.Layer = .music, mood: MusicMood? = .tense,
                   bed: BaseAmbience? = nil, style: SoundscapeStyle = .noir, created: TimeInterval = 0,
                   played: TimeInterval? = nil, favorite: Bool = false) -> GeneratedPiece {
    GeneratedPiece(id: id, promptID: "p.\(id)", promptText: "text", seed: 1, layer: layer, style: style,
                   mood: layer == .music ? mood : nil, bed: layer == .ambience ? (bed ?? .rain) : nil,
                   emotions: [.suspense], situations: [.chase], intensity: 2, energy: 1, studySafe: false,
                   fileName: "\(id).m4a", frames: 5_292_000, sampleRate: 44_100, bitRate: 160_000,
                   tailStart: layer == .music ? 110 : nil, gainDB: 0, lufs: layer == .music ? -20 : -28,
                   truePeak: -2, created: Date(timeIntervalSince1970: created),
                   lastPlayed: played.map { Date(timeIntervalSince1970: $0) }, plays: 0, favorite: favorite,
                   bookIDs: [], modelRevision: "r", engineVersion: 1)
}

@MainActor
private func library(_ root: URL) -> GeneratedLibrary { GeneratedLibrary(root: root) }

@MainActor
private func temporaryRoot() -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("generated-\(UUID())", isDirectory: true)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

/// A source file of `bytes` bytes to hand to `add`.
private func file(bytes: Int = 1_000) -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("src-\(UUID()).m4a")
    try? Data(count: bytes).write(to: url)
    return url
}

@MainActor
@Suite("Generated library")
struct GeneratedLibraryTests {
    @Test func addPersistsAndReloads() throws {
        let root = temporaryRoot()
        let first = library(root)
        try first.add(piece("a"), file: file())
        #expect(first.pieces.map(\.id) == ["a"])
        let second = library(root)
        #expect(second.pieces.map(\.id) == ["a"])
        #expect(second.url(for: second.pieces[0].track) != nil)
    }

    @Test func tracksMatchMoodAndPreferStyle() throws {
        let generated = library(temporaryRoot())
        try generated.add(piece("noir"), file: file())
        try generated.add(piece("neutral", style: .neutral), file: file())
        try generated.add(piece("western", style: .western), file: file())
        try generated.add(piece("calm", mood: .calm), file: file())
        #expect(generated.musicTracks(.tense, style: .noir).map(\.id) == ["noir"])
        #expect(generated.musicTracks(.tense, style: .fantasy).map(\.id) == ["neutral"])
        let other = library(temporaryRoot())
        try other.add(piece("western", style: .western), file: file())
        #expect(other.musicTracks(.tense, style: .noir).map(\.id) == ["western"])
        #expect(generated.musicTracks(.epic, style: .noir).isEmpty)
    }

    @Test func ambienceTracksByBed() throws {
        let generated = library(temporaryRoot())
        try generated.add(piece("rain", layer: .ambience, bed: .rain, style: .neutral), file: file())
        try generated.add(piece("sea", layer: .ambience, bed: .sea, style: .neutral), file: file())
        #expect(generated.ambienceTracks(.rain, style: .cyberpunk).map(\.id) == ["rain"])
        #expect(generated.ambienceTracks(.rain, style: .cyberpunk).first?.audio.isLoop == true)
    }

    @Test func evictionKeepsFavoritesAndActiveMinimum() throws {
        let generated = library(temporaryRoot())
        generated.budgetBytes = 3_000
        try generated.add(piece("old-favorite", created: 1, favorite: true), file: file())
        try generated.add(piece("old", created: 2), file: file())
        try generated.add(piece("calm-1", mood: .calm, created: 3), file: file())
        try generated.add(piece("tense-new", created: 4), file: file())
        try generated.add(piece("tense-newer", created: 5), file: file())
        generated.evict(activeMoods: [.tense], activeBeds: [])
        let left = Set(generated.pieces.map(\.id))
        #expect(left.contains("old-favorite"))
        #expect(left.contains("tense-new") && left.contains("tense-newer"))
        #expect(!left.contains("old") && !left.contains("calm-1"))
        #expect(generated.bytesOnDisk <= 3_000)
    }

    @Test func corruptIndexAndMissingFilesAreSkipped() throws {
        let root = temporaryRoot()
        let generated = library(root)
        try generated.add(piece("kept"), file: file())
        try generated.add(piece("gone"), file: file())
        try FileManager.default.removeItem(at: root.appendingPathComponent("gone.m4a"))
        #expect(library(root).pieces.map(\.id) == ["kept"])
        try Data("{not json".utf8).write(to: root.appendingPathComponent("index.json"))
        #expect(library(root).pieces.isEmpty)
    }

    @Test func piecesSurviveModelRemoval() throws {
        let base = temporaryRoot()
        let models = base.appendingPathComponent("Models", isDirectory: true)
        let generatedRoot = base.appendingPathComponent("Generated", isDirectory: true)
        try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
        try Data(count: 10).write(to: models.appendingPathComponent("dit.safetensors"))
        try library(generatedRoot).add(piece("a"), file: file())
        try FileManager.default.removeItem(at: models)
        let reloaded = library(generatedRoot)
        #expect(reloaded.pieces.count == 1 && reloaded.url(for: reloaded.pieces[0].track) != nil)
    }

    @Test func favoritesAndPlaysPersist() throws {
        let root = temporaryRoot()
        let generated = library(root)
        try generated.add(piece("a"), file: file())
        generated.setFavorite("a", true)
        generated.markPlayed("a")
        let reloaded = library(root)
        #expect(reloaded.pieces[0].favorite && reloaded.pieces[0].plays == 1 && reloaded.pieces[0].lastPlayed != nil)
        #expect(reloaded.favoriteIDs == ["a"])
    }

    @Test func generatedTrackHasUnitGainAndSemantics() {
        let track = piece("a").track
        #expect(track.semantics.origin == "generated" && track.semantics.style == "noir")
        #expect(track.moods == [.tense] && track.audio.tailStartSeconds == 110 && !track.audio.isLoop)
        #expect(track.audio.integratedLUFS == -20)
    }

    @Test func favoritesWeighDouble() {
        let tracks = [piece("plain").track, piece("favorite").track]
        var history = PlayHistory()
        history.played("plain", at: 0)
        history.played("favorite", at: 0)
        // Both heard 30 min ago: inside the 45 min window, but a favorite only waits half of it.
        let next = TrackSelector.next(from: tracks, current: nil, history: history, now: 1_800, favorites: ["favorite"])
        #expect(next?.id == "favorite")
    }
}
