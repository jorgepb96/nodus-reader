// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import StableAudioMLX

/// One piece to generate.
struct GenerationJob: Hashable, Sendable {
    var request: PromptRequest
    var prompt: SoundscapePrompt
    var recipe: GenerationRecipe
    var bookID: UUID?
    /// Higher first.
    var priority: Int

    /// Two jobs with the same key would generate the same kind of piece.
    var key: String {
        "\(request.layer.rawValue)|\(request.style.rawValue)|\(request.mood?.rawValue ?? "-")|\(request.bed?.rawValue ?? "-")|\(prompt.id)"
    }
}

enum WorkerEvent: Sendable {
    case started(GenerationJob)
    case finished(GeneratedPiece)
    case rejected(GenerationJob, String)
    case failed(GenerationJob, String)
    case waiting(String)
    case paused(String)
}

/// Generates one piece at a time: waits for admission, paces itself, checks quality,
/// levels, encodes and stores. Cancellation (book closed, app backgrounded, memory
/// warning, heat) stops the piece between diffusion steps and stores nothing.
actor GenerationWorker {
    static let crashCountKey = "nodus.soundscapes.generationCrashCount"
    static let inProgressKey = "nodus.soundscapes.generationInProgress"
    static let maximumQueue = 6
    static let hourlyLimit = 12
    static let admissionRetry: Double = 15

    /// Seconds between pieces: longer when the device is already warm.
    static func pause(for thermal: ProcessInfo.ThermalState) -> Double {
        thermal == .fair ? 60 : 20
    }

    /// Seconds to wait so that no more than `hourlyLimit` pieces start in an hour.
    static func waitForHourlyCap(started: [Date], now: Date) -> Double {
        let recent = started.filter { now.timeIntervalSince($0) < 3_600 }.sorted()
        guard recent.count >= hourlyLimit, let oldest = recent.first else { return 0 }
        return max(0, 3_600 - now.timeIntervalSince(oldest))
    }

    private let generator: SoundscapeGenerating
    private let library: GeneratedLibrary
    private let admission: @Sendable () async -> AdmissionState
    private let sleep: @Sendable (Double) async throws -> Void
    private let defaults: UserDefaults
    private let onEvent: @Sendable (WorkerEvent) -> Void

    private var queue: [GenerationJob] = []
    private var loop: Task<Void, Never>?
    private var started: [Date] = []
    private var consecutiveFailures = 0
    private(set) var isPaused = false
    /// The app ended twice during a generation: only short recipes on this device.
    private(set) var forceShort: Bool

    init(generator: SoundscapeGenerating, library: GeneratedLibrary,
         admission: @escaping @Sendable () async -> AdmissionState,
         sleep: @escaping @Sendable (Double) async throws -> Void = { try await Task.sleep(for: .seconds($0)) },
         defaults: UserDefaults = .standard,
         onEvent: @escaping @Sendable (WorkerEvent) -> Void) {
        self.generator = generator
        self.library = library
        self.admission = admission
        self.sleep = sleep
        self.defaults = defaults
        self.onEvent = onEvent
        var crashes = defaults.integer(forKey: Self.crashCountKey)
        if defaults.bool(forKey: Self.inProgressKey) {
            crashes += 1
            defaults.set(crashes, forKey: Self.crashCountKey)
            defaults.set(false, forKey: Self.inProgressKey)
        }
        forceShort = crashes >= 2
    }

    var pending: [GenerationJob] { queue }
    var isBusy: Bool { loop != nil }

    /// Adds jobs (without duplicates), keeps the highest priorities and starts working.
    func enqueue(_ jobs: [GenerationJob]) {
        for job in jobs where !queue.contains(where: { $0.key == job.key }) {
            queue.append(job)
        }
        queue = Array(queue.enumerated().sorted {
            $0.element.priority != $1.element.priority ? $0.element.priority > $1.element.priority : $0.offset < $1.offset
        }.map(\.element).prefix(Self.maximumQueue))
        startIfNeeded()
    }

    /// Replaces the queue (a new plan); the piece in progress continues.
    func replace(with jobs: [GenerationJob]) {
        queue.removeAll()
        enqueue(jobs)
    }

    func cancelAll() {
        queue.removeAll()
        loop?.cancel()
        loop = nil
        defaults.set(false, forKey: Self.inProgressKey)
    }

    /// Lifts the pause after repeated failures.
    func resume() {
        isPaused = false
        consecutiveFailures = 0
        startIfNeeded()
    }

    private func startIfNeeded() {
        guard loop == nil, !isPaused, !queue.isEmpty else { return }
        loop = Task { [weak self] in await self?.run() }
    }

    private func run() async {
        defer { loop = nil }
        while !Task.isCancelled, !isPaused, !queue.isEmpty {
            do {
                let cap = Self.waitForHourlyCap(started: started, now: Date())
                if cap > 0 {
                    onEvent(.waiting("hourly limit"))
                    try await sleep(cap)
                }
                guard let job = queue.first else { break }
                let recipe = try await admit(job)
                guard let current = queue.first, current.key == job.key else { continue }
                queue.removeFirst()
                await generate(current, recipe: recipe)
                if isPaused || Task.isCancelled { break }
                try await sleep(Self.pause(for: await admission().thermal))
            } catch {
                break
            }
        }
    }

    /// Waits until the device admits a piece; returns the recipe to use.
    private func admit(_ job: GenerationJob) async throws -> GenerationRecipe {
        while true {
            try Task.checkCancellation()
            let wanted = forceShort ? GenerationRecipe.short(for: job.recipe.layer) : job.recipe
            switch GenerationAdmission.decide(await admission(), recipe: wanted) {
            case .run(let recipe): return recipe
            case .wait(let reason):
                onEvent(.waiting(reason))
                try await sleep(Self.admissionRetry)
            }
        }
    }

    private func generate(_ job: GenerationJob, recipe: GenerationRecipe) async {
        started.append(Date())
        onEvent(.started(job))
        defaults.set(true, forKey: Self.inProgressKey)
        let seed = UInt64.random(in: 1 ... UInt64.max / 2)
        do {
            let rendered = try await generator.render(job, recipe: recipe, seed: seed)
            defaults.set(false, forKey: Self.inProgressKey)
            try Task.checkCancellation()
            switch try finish(job, recipe: recipe, rendered: rendered, seed: seed) {
            case .stored(let piece, let file):
                try Task.checkCancellation()
                try await MainActor.run { try library.add(piece, file: file) }
                consecutiveFailures = 0
                onEvent(.finished(piece))
            case .rejected(let reason):
                consecutiveFailures = 0
                onEvent(.rejected(job, reason))
            }
        } catch is CancellationError {
            defaults.set(false, forKey: Self.inProgressKey)
        } catch {
            defaults.set(false, forKey: Self.inProgressKey)
            consecutiveFailures += 1
            onEvent(.failed(job, String(describing: error)))
            if consecutiveFailures >= 3 {
                isPaused = true
                onEvent(.paused("three generations failed in a row"))
            }
        }
    }

    private enum Outcome {
        case stored(GeneratedPiece, URL)
        case rejected(String)
    }

    /// Quality gate, levelling and AAC encoding.
    private func finish(_ job: GenerationJob, recipe: GenerationRecipe, rendered: RenderedPiece, seed: UInt64) throws -> Outcome {
        let rate = rendered.sampleRate
        if case .reject(let reason) = QualityGate.check(rendered.channels, sampleRate: rate, layer: recipe.layer,
                                                        minimumUsefulSeconds: recipe.minimumUsefulSeconds) {
            return .rejected(reason)
        }
        if (try? QualityGate.voiceFraction(rendered.channels, sampleRate: rate)) ?? 0 > QualityGate.maximumVoiceFraction {
            return .rejected("voice")
        }
        let target = QualityGate.target(for: recipe.layer)
        let leveled = SA3Audio.level(rendered.channels, sampleRate: rate, targetLUFS: target.lufs, ceilingDBTP: target.truePeak)
        var tailStart: Double?
        if recipe.layer == .music {
            let range = SA3Audio.loopableRange(leveled.channels, sampleRate: rate)
            tailStart = max(30, Double(range.upperBound) / Double(rate) - 8)
        }
        let id = UUID().uuidString.lowercased()
        let bitRate = recipe.layer == .music ? 176_000 : 112_000
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(id).m4a")
        let frames = try SA3Audio.writeAAC(leveled.channels, sampleRate: rate, bitRate: bitRate, to: file)
        let piece = GeneratedPiece(
            id: id, promptID: job.prompt.id, promptText: job.prompt.text, seed: seed, layer: recipe.layer,
            style: job.prompt.style ?? .neutral, mood: job.request.mood, bed: job.request.bed,
            emotions: job.prompt.emotions, situations: job.prompt.situations, intensity: job.prompt.intensity,
            energy: job.prompt.energy, studySafe: job.prompt.studySafe, fileName: "\(id).m4a", frames: frames,
            sampleRate: rate, bitRate: bitRate, tailStart: tailStart, gainDB: leveled.gainDB, lufs: leveled.loudness,
            truePeak: leveled.truePeak, created: Date(), lastPlayed: nil, plays: 0, favorite: false,
            bookIDs: job.bookID.map { [$0] } ?? [], modelRevision: SA3Manifest.revision, engineVersion: 1)
        return .stored(piece, file)
    }
}
