// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// How one piece is generated. Music is generated for `seconds` and then continued
/// (inpainting) to `continueTo`, keeping `0…keepUntil`; the base piece's composed ending
/// falls after `keepUntil` and is replaced, so the long piece keeps developing.
/// Ambience is a single generation that becomes a loop.
struct GenerationRecipe: Hashable, Sendable, Codable {
    var layer: CatalogTrack.Layer
    var seconds: Double
    var continueTo: Double?
    var keepUntil: Double?
    /// Useful seconds (after trimming the lead-in and the composed ending) below which
    /// the piece is rejected.
    var minimumUsefulSeconds: Double

    var isShort: Bool { self == .shortMusic || self == .shortAmbience }
    var finalSeconds: Double { continueTo ?? seconds }

    static let music = GenerationRecipe(layer: .music, seconds: 60, continueTo: 120, keepUntil: 55, minimumUsefulSeconds: 90)
    static let shortMusic = GenerationRecipe(layer: .music, seconds: 60, continueTo: nil, keepUntil: nil, minimumUsefulSeconds: 45)
    static let ambience = GenerationRecipe(layer: .ambience, seconds: 60, continueTo: nil, keepUntil: nil, minimumUsefulSeconds: 40)
    static let shortAmbience = GenerationRecipe(layer: .ambience, seconds: 30, continueTo: nil, keepUntil: nil, minimumUsefulSeconds: 20)

    static func full(for layer: CatalogTrack.Layer) -> GenerationRecipe { layer == .music ? .music : .ambience }
    static func short(for layer: CatalogTrack.Layer) -> GenerationRecipe { layer == .music ? .shortMusic : .shortAmbience }
}
