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
    case finished(GeneratedPiece, GenerationJob)
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
    /// Room for a whole starter pack (nine) and a few pieces asked for now.
    static let maximumQueue = 12
    /// A piece the reader (or the director) wants now, ahead of a pack.
    static let immediatePriority = 30
    static let hourlyLimit = 12
    static let admissionRetry: Double = 15
    /// Waits for the on-device language model before composing anyway (a minute).
    static let maximumAnalysisWaits = 4

    /// Seconds between pieces: longer when the device is already warm.
    static func pause(for thermal: ProcessInfo.ThermalState) -> Double {
        thermal == .fair ? 60 : 20
    }

    /// Between pieces the reader asked for (a pack, or what plays now).
    static let requestedPause: Double = 5

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
    /// Multiplies every pause (pacing and admission retries); below 1 only for UI tests.
    private let pacing: Double

    private var queue: [GenerationJob] = []
    private var loop: Task<Void, Never>?
    /// Each loop knows whether it is still the current one when it ends.
    private var loopID = 0
    /// The job being generated, put back at the front if it is interrupted.
    private var inFlight: GenerationJob?
    /// After a memory warning, the next piece uses the short recipe.
    private var shortNext = false
    private var started: [Date] = []
    private var consecutiveFailures = 0
    private(set) var isPaused = false
    /// The app ended twice during a generation: only short recipes on this device.
    private(set) var forceShort: Bool

    init(generator: SoundscapeGenerating, library: GeneratedLibrary,
         admission: @escaping @Sendable () async -> AdmissionState,
         sleep: @escaping @Sendable (Double) async throws -> Void = { try await Task.sleep(for: .seconds($0)) },
         defaults: UserDefaults = .standard, pacing: Double = 1,
         onEvent: @escaping @Sendable (WorkerEvent) -> Void) {
        self.pacing = pacing
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
        for job in jobs where !queue.contains(where: { $0.key == job.key }) && !isAlreadyAskedFor(job) {
            queue.append(job)
        }
        queue = Array(queue.enumerated().sorted {
            $0.element.priority != $1.element.priority ? $0.element.priority > $1.element.priority : $0.offset < $1.offset
        }.map(\.element).prefix(Self.maximumQueue))
        startIfNeeded()
    }

    /// A piece asked for now is not queued twice for the same mood or ambience, even
    /// with another prompt.
    private func isAlreadyAskedFor(_ job: GenerationJob) -> Bool {
        guard job.priority >= Self.immediatePriority else { return false }
        func same(_ other: GenerationJob) -> Bool {
            other.priority >= Self.immediatePriority && other.request.layer == job.request.layer
                && other.request.mood == job.request.mood && other.request.bed == job.request.bed
        }
        return queue.contains(where: same) || inFlight.map(same) == true
    }

    /// Replaces the queue (a new plan); the piece in progress continues.
    func replace(with jobs: [GenerationJob]) {
        queue.removeAll()
        enqueue(jobs)
    }

    func cancelAll() {
        queue.removeAll()
        inFlight = nil
        loop?.cancel()
        loop = nil
        defaults.set(false, forKey: Self.inProgressKey)
    }

    /// Stops the piece in progress (memory warning, heat) without dropping the plan: the
    /// job goes back to the front and work resumes after `retryAfter` seconds, with the
    /// short recipe for the next piece when `shorter`.
    func interrupt(retryAfter: Double, shorter: Bool) {
        if let job = inFlight, !queue.contains(where: { $0.key == job.key }) {
            queue.insert(job, at: 0)
        }
        inFlight = nil
        if shorter { shortNext = true }
        loop?.cancel()
        loop = nil
        defaults.set(false, forKey: Self.inProgressKey)
        startIfNeeded(after: retryAfter)
    }

    /// Lifts the pause after repeated failures.
    func resume() {
        isPaused = false
        consecutiveFailures = 0
        startIfNeeded()
    }

    private func startIfNeeded(after delay: Double = 0) {
        guard loop == nil, !isPaused, !queue.isEmpty else { return }
        loopID += 1
        let id = loopID
        loop = Task { [weak self] in await self?.run(id: id, after: delay) }
    }

    private func run(id: Int, after delay: Double) async {
        defer { if loopID == id { loop = nil } }
        if delay > 0 {
            do { try await sleep(delay * pacing) } catch { return }
        }
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
                shortNext = false
                inFlight = current
                await generate(current, recipe: recipe)
                if loopID == id { inFlight = nil }
                if isPaused || Task.isCancelled { break }
                let thermal = await admission().thermal
                let requested = current.priority >= 10 && thermal == .nominal
                try await sleep((requested ? Self.requestedPause : Self.pause(for: thermal)) * pacing)
            } catch {
                break
            }
        }
    }

    /// Waits until the device admits a piece; returns the recipe to use.
    private func admit(_ job: GenerationJob) async throws -> GenerationRecipe {
        var analysisWaits = 0
        while true {
            try Task.checkCancellation()
            let wanted = forceShort || shortNext ? GenerationRecipe.short(for: job.recipe.layer) : job.recipe
            var state = await admission()
            // Scene analysis and recaps can keep the model busy for a whole long book.
            if analysisWaits >= Self.maximumAnalysisWaits { state.analysisRunning = false }
            // A pack (priority 10+) or a piece asked for now was requested by the reader.
            switch GenerationAdmission.decide(state, recipe: wanted, requested: job.priority >= 10) {
            case .run(let recipe): return recipe
            case .wait(let reason):
                if reason == "analysis" { analysisWaits += 1 }
                onEvent(.waiting(reason))
                try await sleep(Self.admissionRetry * pacing)
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
                onEvent(.finished(piece, job))
            case .rejected(let reason):
                consecutiveFailures = 0
                onEvent(.rejected(job, reason))
            }
        } catch {
            defaults.set(false, forKey: Self.inProgressKey)
            // The engine reports a cancelled piece with its own error: not a failure.
            if error is CancellationError || Task.isCancelled { return }
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
