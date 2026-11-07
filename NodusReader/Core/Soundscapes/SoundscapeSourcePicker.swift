// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// Where soundscapes come from: the downloadable CC0 catalog or pieces generated on
/// this device.
enum SoundscapeSource: String, Codable, CaseIterable, Sendable, Identifiable {
    case downloaded
    case ai

    var id: String { rawValue }

    var label: String {
        switch self {
        case .downloaded: String(localized: "Downloaded")
        case .ai: String(localized: "AI")
        }
    }
}

enum PoolDecision: Equatable {
    case play(CatalogTrack)
    /// Nothing is ready: keep what plays rather than fall silent.
    case keep
    case stop
}

/// Chooses between generated and downloaded pieces for the mood (or bed) the director
/// decided. With AI soundscapes, generated pieces come first, then downloaded ones;
/// with nothing ready, what plays continues. Never waits for a generation.
enum SoundscapeSourcePicker {
    static func decide(source: SoundscapeSource, generated: [CatalogTrack], downloaded: [CatalogTrack],
                       currentID: String?, pick: ([CatalogTrack]) -> CatalogTrack?) -> PoolDecision {
        switch source {
        case .downloaded:
            return pick(downloaded).map(PoolDecision.play) ?? .stop
        case .ai:
            if let track = pick(generated.isEmpty ? downloaded : generated) { return .play(track) }
            return currentID == nil ? .stop : .keep
        }
    }
}
