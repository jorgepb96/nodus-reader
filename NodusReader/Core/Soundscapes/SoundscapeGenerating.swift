// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import StableAudioMLX

/// What the worker asks for: a whole piece (music continued, ambience already a
/// seamless loop), before quality checks and levelling.
struct RenderedPiece: Sendable {
    var channels: [[Float]]
    var sampleRate: Int
}

protocol SoundscapeGenerating: Sendable {
    func render(_ job: GenerationJob, recipe: GenerationRecipe, seed: UInt64) async throws -> RenderedPiece
}

enum SoundscapeGenerationError: Error, Equatable {
    case seam
    case fixtureFailure
}

/// Stable Audio 3 Small on MLX, loaded stage by stage and freed after every piece.
struct SA3Generator: SoundscapeGenerating {
    let engine: SA3Engine

    init(directory: SA3ModelDirectory) {
        // Freed weights must return to the system: a small MLX buffer cache, set once when
        // AI soundscapes are first used (it also applies to the other MLX users).
        engine = SA3Engine(directory: directory, residency: .staged, cacheLimitBytes: 64 << 20)
    }

    func render(_ job: GenerationJob, recipe: GenerationRecipe, seed: UInt64) async throws -> RenderedPiece {
        let kind: SA3ModelKind = recipe.layer == .music ? .music : .sfx
        let text = job.prompt.modelText
        defer { Task { await engine.unloadAll() } }
        let base = try await engine.generate(.init(kind: kind, prompt: text, seconds: Float(recipe.seconds), seed: seed))
        if recipe.layer == .music {
            guard let total = recipe.continueTo, let keep = recipe.keepUntil else {
                return RenderedPiece(channels: base.channels, sampleRate: base.sampleRate)
            }
            // Keep the start, replace the composed ending and continue to `total`.
            let continued = try await engine.generate(
                .init(kind: kind, prompt: text, seconds: Float(total), seed: seed &+ 1),
                inpaint: .init(channels: base.channels, keep: [0 ... keep]))
            return RenderedPiece(channels: continued.channels, sampleRate: continued.sampleRate)
        }
        // Ambience: a seamless loop; a seam that fails the gate is regenerated in place.
        guard let loop = SA3Audio.loop(base.channels, sampleRate: base.sampleRate, seam: 3) else {
            throw SoundscapeGenerationError.seam
        }
        if QualityGate.seamAcceptable(loop, sampleRate: base.sampleRate) {
            return RenderedPiece(channels: loop, sampleRate: base.sampleRate)
        }
        let repaired = try await repairSeam(loop, sampleRate: base.sampleRate, kind: kind, text: text, seed: seed &+ 2)
        guard QualityGate.seamAcceptable(repaired, sampleRate: base.sampleRate) else { throw SoundscapeGenerationError.seam }
        return RenderedPiece(channels: repaired, sampleRate: base.sampleRate)
    }

    /// Rotates the loop so its seam sits in the middle, regenerates 4 s around it by
    /// inpainting (keeping both sides), and rotates back: the new loop point is a join
    /// that was continuous in the original.
    private func repairSeam(_ loop: [[Float]], sampleRate: Int, kind: SA3ModelKind, text: String,
                            seed: UInt64) async throws -> [[Float]] {
        let n = loop[0].count
        let half = n / 2
        let rotated = loop.map { Array($0[half...] + $0[..<half]) }
        let seconds = Double(n) / Double(sampleRate)
        let middle = Double(n - half) / Double(sampleRate)
        let output = try await engine.generate(
            .init(kind: kind, prompt: text, seconds: Float(seconds), seed: seed),
            inpaint: .init(channels: rotated, keep: [0 ... (middle - 2), (middle + 2) ... seconds]))
        let count = min(n, output.channels[0].count)
        let split = n - half
        return output.channels.map { channel in
            let clip = Array(channel[0 ..< count]) + [Float](repeating: 0, count: n - count)
            return Array(clip[split...] + clip[..<split])
        }
    }
}

/// Deterministic stand-in for tests and Simulator UI runs (MLX cannot run in the
/// Simulator): steady noise of the recipe's length.
struct FixtureGenerator: SoundscapeGenerating {
    var level: Float = 0.05
    var delay: Double = 0
    var fails = false

    func render(_ job: GenerationJob, recipe: GenerationRecipe, seed: UInt64) async throws -> RenderedPiece {
        if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
        try Task.checkCancellation()
        if fails { throw SoundscapeGenerationError.fixtureFailure }
        let rate = 44_100
        let frames = Int(recipe.finalSeconds * Double(rate))
        var state = seed | 1
        func sample() -> Float {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return level * (Float(Int64(bitPattern: state >> 11) % 2_000_000) / 1_000_000 - 1)
        }
        return RenderedPiece(channels: [(0 ..< frames).map { _ in sample() }, (0 ..< frames).map { _ in sample() }],
                             sampleRate: rate)
    }
}
