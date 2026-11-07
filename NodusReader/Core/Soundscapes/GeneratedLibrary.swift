// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Observation

/// A piece generated on this device, with what it is for and how it was made.
struct GeneratedPiece: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var promptID: String
    var promptText: String
    var seed: UInt64
    var layer: CatalogTrack.Layer
    var style: SoundscapeStyle
    var mood: MusicMood?
    var bed: BaseAmbience?
    var emotions: [SceneEmotion]
    var situations: [SceneSituation]
    var intensity: Int
    var energy: Int
    var studySafe: Bool
    var fileName: String
    var frames: Int64
    var sampleRate: Int
    var bitRate: Int
    /// Where the next music piece may begin (seconds); nil for loops.
    var tailStart: Double?
    var gainDB: Double
    var lufs: Double
    var truePeak: Double
    var created: Date
    var lastPlayed: Date?
    var plays: Int
    var favorite: Bool
    /// Books it was generated for (statistics for variety; pieces are shared).
    var bookIDs: [UUID]
    var modelRevision: String
    var engineVersion: Int

    /// The piece in the catalog's shape, so selection, rotation and the engine treat it
    /// like any downloaded track.
    var track: CatalogTrack {
        let made = ISO8601DateFormatter().string(from: created)
        return CatalogTrack(
            id: id, layer: layer, title: promptText, author: "Generated on this device", authorURL: nil, addedIn: nil,
            source: .init(provider: "Stable Audio 3 Small (on device)", pageURL: "", fileURL: "", retrievedOn: made,
                          originalSHA256: "", originalBytes: 0,
                          originalFormat: .init(codec: "aac", sampleRate: sampleRate, channels: 2, bitRate: bitRate)),
            license: .init(spdx: "LicenseRef-Generated-Output", url: "https://stability.ai/license",
                           evidence: .init(url: "", snapshot: "", snapshotSHA256: "", quote: ""),
                           verifiedOn: made, verifiedBy: "Nodus Reader"),
            processing: .init(transformations: ["generated with seed \(seed) from prompt \(promptID)",
                                                String(format: "gain %+.1f dB", gainDB)],
                              tools: ["model": modelRevision]),
            file: .init(path: fileName, githubAssetName: nil, bytes: 0, sha256: "", sampleRate: sampleRate,
                        channels: 2, bitRateKbps: bitRate / 1_000, frames: frames),
            audio: .init(integratedLUFS: lufs, truePeakDBTP: truePeak, lra: nil, isLoop: layer == .ambience,
                         tailStartSeconds: tailStart),
            semantics: .init(moods: mood.map { [$0.rawValue] }, base: bed?.rawValue, energy: energy,
                             studySafe: studySafe, subPool: promptID, style: style.rawValue,
                             emotions: emotions.map(\.rawValue), situations: situations.map(\.rawValue),
                             origin: "generated"))
    }
}

/// The AI soundscape cache: `index.json` and one `.m4a` per piece in `root`
/// (`Application Support/Soundscapes/Generated`), excluded from backups and never
/// synced. Shared by every book; needs no model to play.
@MainActor
@Observable
final class GeneratedLibrary {
    static let defaultBudget: Int64 = 500_000_000

    let root: URL
    private(set) var pieces: [GeneratedPiece] = []
    private(set) var bytesOnDisk: Int64 = 0
    var budgetBytes: Int64 = GeneratedLibrary.defaultBudget
    @ObservationIgnored var onChange: (() -> Void)?

    init(root: URL) {
        self.root = root
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var url = root
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
        load()
    }

    var hasAnything: Bool { !pieces.isEmpty }
    var favoriteIDs: Set<String> { Set(pieces.filter(\.favorite).map(\.id)) }

    func piece(_ id: String) -> GeneratedPiece? { pieces.first { $0.id == id } }

    // MARK: Queries

    /// Pieces for a mood: the book's style first, then neutral, then any style.
    func musicTracks(_ mood: MusicMood, style: SoundscapeStyle) -> [CatalogTrack] {
        preferred(pieces.filter { $0.layer == .music && $0.mood == mood }, style: style).map(\.track)
    }

    func ambienceTracks(_ bed: BaseAmbience, style: SoundscapeStyle) -> [CatalogTrack] {
        preferred(pieces.filter { $0.layer == .ambience && $0.bed == bed }, style: style).map(\.track)
    }

    private func preferred(_ candidates: [GeneratedPiece], style: SoundscapeStyle) -> [GeneratedPiece] {
        let exact = candidates.filter { $0.style == style }
        if !exact.isEmpty { return exact }
        let neutral = candidates.filter { $0.style == .neutral }
        return neutral.isEmpty ? candidates : neutral
    }

    /// Pieces that serve this exact style and mood (or bed).
    func count(layer: CatalogTrack.Layer, style: SoundscapeStyle, mood: MusicMood?, bed: BaseAmbience?) -> Int {
        pieces.filter { $0.layer == layer && $0.style == style && $0.mood == mood && $0.bed == bed }.count
    }

    /// Pieces usable for a request: its style or neutral, same mood (or bed).
    func usableCount(for request: PromptRequest) -> Int {
        pieces.filter {
            $0.layer == request.layer && $0.mood == request.mood && $0.bed == request.bed
                && ($0.style == request.style || $0.style == .neutral)
        }.count
    }

    var installedMoods: Set<MusicMood> { Set(pieces.compactMap(\.mood)) }
    var installedBeds: Set<BaseAmbience> { Set(pieces.compactMap(\.bed)) }

    func url(for track: CatalogTrack) -> URL? {
        guard let piece = piece(track.id) else { return nil }
        let url = root.appendingPathComponent(piece.fileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: Changes

    /// Moves `file` into the cache and records `piece`.
    func add(_ piece: GeneratedPiece, file: URL) throws {
        let destination = root.appendingPathComponent(piece.fileName)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: file, to: destination)
        pieces.removeAll { $0.id == piece.id }
        pieces.append(piece)
        save()
    }

    func setFavorite(_ id: String, _ on: Bool) {
        guard let index = pieces.firstIndex(where: { $0.id == id }) else { return }
        pieces[index].favorite = on
        save()
    }

    func markPlayed(_ id: String) {
        guard let index = pieces.firstIndex(where: { $0.id == id }) else { return }
        pieces[index].plays += 1
        pieces[index].lastPlayed = Date()
        save()
    }

    func delete(_ id: String) {
        guard let piece = piece(id) else { return }
        try? FileManager.default.removeItem(at: root.appendingPathComponent(piece.fileName))
        pieces.removeAll { $0.id == id }
        save()
    }

    func deleteAll() {
        for piece in pieces { try? FileManager.default.removeItem(at: root.appendingPathComponent(piece.fileName)) }
        pieces.removeAll()
        save()
    }

    /// Frees space down to the budget, least recently played first. Never removes a
    /// favorite or the two newest pieces of a mood or bed that is playing.
    func evict(activeMoods: Set<MusicMood>, activeBeds: Set<BaseAmbience>) {
        guard bytesOnDisk > budgetBytes else { return }
        var protected = favoriteIDs
        for mood in activeMoods {
            pieces.filter { $0.mood == mood }.sorted { $0.created > $1.created }.prefix(2).forEach { protected.insert($0.id) }
        }
        for bed in activeBeds {
            pieces.filter { $0.bed == bed }.sorted { $0.created > $1.created }.prefix(2).forEach { protected.insert($0.id) }
        }
        let order = pieces.filter { !protected.contains($0.id) }
            .sorted { ($0.lastPlayed ?? $0.created) < ($1.lastPlayed ?? $1.created) }
        for piece in order {
            guard bytesOnDisk > budgetBytes else { break }
            try? FileManager.default.removeItem(at: root.appendingPathComponent(piece.fileName))
            pieces.removeAll { $0.id == piece.id }
            bytesOnDisk = measure()
        }
        save()
    }

    // MARK: Storage

    private var indexURL: URL { root.appendingPathComponent("index.json") }

    private struct Index: Codable {
        var version = 1
        var pieces: [GeneratedPiece]
    }

    private func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let index = try? JSONDecoder().decode(Index.self, from: data) else {
            pieces = []
            bytesOnDisk = measure()
            return
        }
        // A file removed by hand drops its entry.
        pieces = index.pieces.filter { FileManager.default.fileExists(atPath: root.appendingPathComponent($0.fileName).path) }
        bytesOnDisk = measure()
    }

    private func save() {
        bytesOnDisk = measure()
        if let data = try? JSONEncoder().encode(Index(pieces: pieces)) {
            try? data.write(to: indexURL, options: .atomic)
        }
        onChange?()
    }

    private func measure() -> Int64 {
        pieces.reduce(0) { total, piece in
            let path = root.appendingPathComponent(piece.fileName).path
            return total + ((try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) ?? 0)
        }
    }
}
