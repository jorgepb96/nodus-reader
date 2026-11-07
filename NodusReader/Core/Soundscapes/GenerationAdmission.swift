// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// What the device is doing, sampled before each piece.
struct AdmissionState: Sendable, Equatable {
    var thermal: ProcessInfo.ThermalState
    var lowPower: Bool
    var foreground: Bool
    /// Narration is playing but waiting for a sentence: never compete with it.
    var narrationWaiting: Bool
    /// Scene analysis is using the on-device model: do not stack heat.
    var analysisRunning: Bool
    /// `os_proc_available_memory()`; nil where the system does not report it (macOS).
    var availableMemory: Int64?
}

enum Admission: Equatable, Sendable {
    case run(GenerationRecipe)
    case wait(String)
}

/// Whether a piece may start now, and with which recipe.
enum GenerationAdmission {
    /// Measured peaks above the app's own footprint with staged loading (iPhone 16 Pro
    /// Max and Mac M2, 2026-11-06): 120 s with continuation ≈ 1.36 GB, 60 s ≈ 1.27 GB,
    /// 30 s ≈ 1.21 GB. Rounded up.
    static func estimatedPeak(_ recipe: GenerationRecipe) -> Int64 {
        switch recipe {
        case .music: 1_400_000_000
        case .shortMusic, .ambience: 1_300_000_000
        default: 1_250_000_000
        }
    }

    static let margin: Int64 = 300_000_000

    static func required(_ recipe: GenerationRecipe) -> Int64 { estimatedPeak(recipe) + margin }

    /// `requested`: the reader asked for it (a pack, or an ambience or mood chosen with
    /// nothing composed). Low Power Mode then delays only what is planned ahead.
    static func decide(_ state: AdmissionState, recipe: GenerationRecipe, requested: Bool = false) -> Admission {
        if !state.foreground { return .wait("background") }
        if state.lowPower, !requested { return .wait("low power") }
        if state.thermal == .serious || state.thermal == .critical { return .wait("hot") }
        // Measured on the iPhone: composing does not delay the voice, so only pieces
        // planned ahead wait for a sentence to arrive.
        if state.narrationWaiting, !requested { return .wait("narration") }
        // Scene analysis runs out of process on the Neural Engine; only pieces planned
        // ahead give way to it.
        if state.analysisRunning, !requested { return .wait("analysis") }
        guard let available = state.availableMemory else { return .run(recipe) }
        if available >= required(recipe) { return .run(recipe) }
        let short = GenerationRecipe.short(for: recipe.layer)
        if recipe != short, available >= required(short) { return .run(short) }
        return .wait("memory")
    }
}
