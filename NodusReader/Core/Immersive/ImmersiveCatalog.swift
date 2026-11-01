// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// The Immersive Audio catalog: every track, where it came from, its licence
/// evidence, how it was processed and where to download it. Only this
/// manifest ships in the app; the audio is downloaded on request, pinned by
/// size and SHA-256 (`tools/immersive-audio/` builds it).
struct ImmersiveCatalog: Codable, Sendable, Equatable {
    struct Host: Codable, Sendable, Equatable {
        var name: String
        /// Ends with "/"; a track's URL is `baseURL` + its path (Hugging Face)
        /// or its flat asset name (GitHub Release).
        var baseURL: String
    }

    struct Pack: Codable, Sendable, Equatable, Identifiable {
        var id: String
        var trackIDs: [String]
        var bytes: Int64
    }

    var schemaVersion: Int
    var catalogVersion: String
    /// Tried in order: Hugging Face first, then the GitHub Release mirror.
    var hosts: [Host]
    var packs: [Pack]
    var tracks: [CatalogTrack]

    static let supportedSchema = 1

    func track(_ id: String) -> CatalogTrack? { tracks.first { $0.id == id } }

    func tracks(in pack: Pack) -> [CatalogTrack] { pack.trackIDs.compactMap(track) }

    /// The URLs to try for a track, in host order.
    func urls(for track: CatalogTrack) -> [URL] {
        hosts.compactMap { host in
            let name = host.name == "github" ? (track.file.githubAssetName ?? track.file.path) : track.file.path
            guard !host.baseURL.contains("<") else { return nil } // not yet published
            let encoded = name.split(separator: "/").map {
                String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0)
            }.joined(separator: "/")
            return URL(string: host.baseURL + encoded)
        }
    }

    /// The catalog bundled with the app, or nil when it is missing or from a
    /// newer schema.
    static func bundled(_ bundle: Bundle = .main) -> ImmersiveCatalog? {
        let url = bundle.url(forResource: "catalog", withExtension: "json", subdirectory: "ImmersiveAudio")
            ?? bundle.url(forResource: "catalog", withExtension: "json")
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return try? decode(data)
    }

    static func decode(_ data: Data) throws -> ImmersiveCatalog {
        let catalog = try JSONDecoder().decode(ImmersiveCatalog.self, from: data)
        guard catalog.schemaVersion <= supportedSchema else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Unsupported catalog schema"))
        }
        return catalog
    }
}

struct CatalogTrack: Codable, Sendable, Equatable, Identifiable {
    enum Layer: String, Codable, Sendable {
        case music
        case ambience
    }

    struct Source: Codable, Sendable, Equatable {
        struct Format: Codable, Sendable, Equatable {
            var codec: String
            var sampleRate: Int
            var channels: Int
            var bitRate: Int?
        }
        var provider: String
        var pageURL: String
        var fileURL: String
        var retrievedOn: String
        var originalSHA256: String
        var originalBytes: Int64
        var originalFormat: Format
    }

    struct License: Codable, Sendable, Equatable {
        struct Evidence: Codable, Sendable, Equatable {
            var url: String
            var snapshot: String
            var snapshotSHA256: String
            var quote: String
        }
        var spdx: String
        var url: String
        var evidence: Evidence
        var verifiedOn: String
        var verifiedBy: String
    }

    struct Processing: Codable, Sendable, Equatable {
        var transformations: [String]
        var tools: [String: String]
    }

    struct File: Codable, Sendable, Equatable {
        var path: String
        var githubAssetName: String?
        var bytes: Int64
        var sha256: String
        var sampleRate: Int
        var channels: Int
        var bitRateKbps: Int
        var frames: Int64
    }

    struct Audio: Codable, Sendable, Equatable {
        var integratedLUFS: Double
        var truePeakDBTP: Double
        var lra: Double?
        var isLoop: Bool
        /// Where the next piece may start fading in (music); nil for loops.
        var tailStartSeconds: Double?
    }

    struct Semantics: Codable, Sendable, Equatable {
        var moods: [String]?
        var base: String?
        /// 0 still … 3 driving.
        var energy: Int
        var studySafe: Bool
        /// A texture family inside a mood ("piano", "strings", "pads").
        var subPool: String?
    }

    var id: String
    var layer: Layer
    var title: String
    var author: String
    var authorURL: String?
    var source: Source
    var license: License
    var processing: Processing
    var file: File
    var audio: Audio
    var semantics: Semantics

    var moods: [MusicMood] { (semantics.moods ?? []).compactMap(MusicMood.init(rawValue:)) }
    var bed: BaseAmbience? { semantics.base.flatMap(BaseAmbience.init(rawValue:)) }
    var duration: TimeInterval { Double(file.frames) / Double(max(file.sampleRate, 1)) }
}

/// When each track last played (engaged seconds), for rotation.
struct PlayHistory: Sendable, Equatable {
    private(set) var lastPlayed: [String: TimeInterval] = [:]

    mutating func played(_ id: String, at time: TimeInterval) { lastPlayed[id] = time }
}

/// Chooses the next piece within a mood: never the one playing, not one
/// heard in the last 45 minutes unless nothing else is left, preferring the
/// least recently played, a texture asked for, and the energy cap.
enum TrackSelector {
    static let repeatWindow: TimeInterval = 2_700

    static func next(from pool: [CatalogTrack], current: String?, history: PlayHistory, now: TimeInterval,
                     maximumEnergy: Int = 3, studyOnly: Bool = false,
                     preferSubPool: String? = nil, avoidSubPool: String? = nil) -> CatalogTrack? {
        var candidates = pool
        if studyOnly {
            let safe = candidates.filter(\.semantics.studySafe)
            if !safe.isEmpty { candidates = safe }
        }
        let gentle = candidates.filter { $0.semantics.energy <= maximumEnergy }
        if !gentle.isEmpty { candidates = gentle }
        if candidates.count > 1, let current { candidates.removeAll { $0.id == current } }
        let fresh = candidates.filter { track in
            history.lastPlayed[track.id].map { now - $0 >= repeatWindow } ?? true
        }
        if !fresh.isEmpty { candidates = fresh }
        if let avoidSubPool {
            let other = candidates.filter { $0.semantics.subPool != avoidSubPool }
            if !other.isEmpty { candidates = other }
        }
        if let preferSubPool {
            let preferred = candidates.filter { $0.semantics.subPool == preferSubPool }
            if !preferred.isEmpty { candidates = preferred }
        }
        return candidates.min { a, b in
            let la = history.lastPlayed[a.id] ?? -.infinity
            let lb = history.lastPlayed[b.id] ?? -.infinity
            return la != lb ? la < lb : a.id < b.id
        }
    }
}
