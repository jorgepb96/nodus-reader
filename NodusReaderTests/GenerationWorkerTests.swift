// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import StableAudioMLX
import Testing
@testable import Nodus_Reader

private let calm = AdmissionState(thermal: .nominal, lowPower: false, foreground: true, narrationWaiting: false,
                                  analysisRunning: false, availableMemory: 4_000_000_000)

private func job(_ mood: MusicMood = .tense, layer: CatalogTrack.Layer = .music, priority: Int = 1,
                 recipe: GenerationRecipe? = nil) -> GenerationJob {
    let request = PromptRequest(layer: layer, style: .noir, mood: layer == .music ? mood : nil,
                                bed: layer == .ambience ? .rain : nil, emotion: nil, situation: nil, intensity: 2,
                                setting: nil, studyOnly: false)
    let prompt = SoundscapePrompt(id: "p.\(mood.rawValue).\(layer.rawValue)", layer: layer, text: "Prompt text for tests, no vocals.",
                                  style: .noir, mood: request.mood, bed: request.bed, setting: nil, emotions: [.suspense],
                                  situations: [], intensity: 2, energy: 1, studySafe: false)
    return GenerationJob(request: request, prompt: prompt, recipe: recipe ?? .full(for: layer), bookID: nil, priority: priority)
}

/// Records the worker's events and waits for a condition on them.
private final class Events: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [WorkerEvent] = []
    func append(_ event: WorkerEvent) { lock.lock(); items.append(event); lock.unlock() }
    var all: [WorkerEvent] { lock.lock(); defer { lock.unlock() }; return items }

    func wait(timeout: Double = 20, until condition: ([WorkerEvent]) -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !condition(all) { try? await Task.sleep(for: .milliseconds(20)) }
    }
}

private final class Sleeps: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Double] = []
    func record(_ seconds: Double) { lock.lock(); items.append(seconds); lock.unlock() }
    var all: [Double] { lock.lock(); defer { lock.unlock() }; return items }
}

@MainActor
private func makeWorker(generator: SoundscapeGenerating, admission: AdmissionState = calm,
                        defaults: UserDefaults? = nil, sleeps: Sleeps = Sleeps()) -> (GenerationWorker, GeneratedLibrary, Events) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("worker-\(UUID())", isDirectory: true)
    let library = GeneratedLibrary(root: root)
    let events = Events()
    let worker = GenerationWorker(generator: generator, library: library,
                                  admission: { admission },
                                  sleep: { seconds in sleeps.record(seconds) },
                                  defaults: defaults ?? UserDefaults(suiteName: "worker.\(UUID())")!,
                                  onEvent: { events.append($0) })
    return (worker, library, events)
}

private func finished(_ events: [WorkerEvent]) -> Int {
    events.filter { if case .finished = $0 { return true } else { return false } }.count
}

/// Blocks its first render until cancelled and then throws the engine's own error (not
/// `CancellationError`), as `SA3Engine` does; later renders succeed. Records each recipe.
private final class InterruptibleGenerator: SoundscapeGenerating, @unchecked Sendable {
    struct EngineCancelled: Error {}
    private let lock = NSLock()
    private var recipes: [GenerationRecipe] = []
    var rendered: [GenerationRecipe] { lock.lock(); defer { lock.unlock() }; return recipes }

    func render(_ job: GenerationJob, recipe: GenerationRecipe, seed: UInt64) async throws -> RenderedPiece {
        lock.lock(); recipes.append(recipe); let first = recipes.count == 1; lock.unlock()
        if first {
            while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(10)) }
            throw EngineCancelled()
        }
        return try await FixtureGenerator().render(job, recipe: recipe, seed: seed)
    }
}

@Suite("Generation worker")
struct GenerationWorkerTests {
    @Test func admissionRules() {
        func decide(_ change: (inout AdmissionState) -> Void, _ recipe: GenerationRecipe = .music) -> Admission {
            var state = calm
            change(&state)
            return GenerationAdmission.decide(state, recipe: recipe)
        }
        #expect(decide({ _ in }) == .run(.music))
        #expect(decide({ $0.thermal = .fair }) == .run(.music))
        #expect(decide({ $0.thermal = .serious }) == .wait("hot"))
        #expect(decide({ $0.thermal = .critical }) == .wait("hot"))
        #expect(decide({ $0.lowPower = true }) == .wait("low power"))
        #expect(decide({ $0.foreground = false }) == .wait("background"))
        #expect(decide({ $0.narrationWaiting = true }) == .wait("narration"))
        #expect(decide({ $0.analysisRunning = true }) == .wait("analysis"))
        let full = GenerationAdmission.required(.music)
        let short = GenerationAdmission.required(.shortMusic)
        #expect(short < full)
        #expect(decide({ $0.availableMemory = full }) == .run(.music))
        #expect(decide({ $0.availableMemory = short }) == .run(.shortMusic))
        #expect(decide({ $0.availableMemory = short - 1 }) == .wait("memory"))
        #expect(decide({ $0.availableMemory = nil }) == .run(.music))
    }

    @Test @MainActor func musicPipelineLevelsAndContinues() async throws {
        let (worker, library, events) = makeWorker(generator: FixtureGenerator())
        await worker.enqueue([job()])
        await events.wait { finished($0) == 1 }
        let piece = try #require(library.pieces.first, "events: \(events.all)")
        #expect(piece.frames == 5_292_000)
        #expect(abs(piece.lufs - -20) < 0.5 && piece.truePeak <= -1.5)
        #expect(piece.tailStart != nil && piece.tailStart! > 90 && piece.tailStart! < 120)
        #expect(library.url(for: piece.track) != nil)
    }

    @Test @MainActor func rejectedPieceIsNotStored() async {
        let (worker, library, events) = makeWorker(generator: FixtureGenerator(level: 0.0005))
        await worker.enqueue([job(layer: .ambience)])
        await events.wait { $0.contains { if case .rejected = $0 { return true } else { return false } } }
        #expect(library.pieces.isEmpty)
    }

    @Test @MainActor func cancelledJobLeavesNoEntry() async {
        let generator = FixtureGenerator(delay: 30)
        let (worker, library, events) = makeWorker(generator: generator)
        await worker.enqueue([job()])
        await events.wait { $0.contains { if case .started = $0 { return true } else { return false } } }
        await worker.cancelAll()
        try? await Task.sleep(for: .milliseconds(300))
        #expect(library.pieces.isEmpty)
        #expect(finished(events.all) == 0)
    }

    @Test @MainActor func pacing() async {
        let sleeps = Sleeps()
        let (worker, _, events) = makeWorker(generator: FixtureGenerator(), sleeps: sleeps)
        await worker.enqueue([job(.tense), job(.calm)])
        await events.wait { finished($0) == 2 }
        #expect(sleeps.all.contains(GenerationWorker.pause(for: .nominal)))
        #expect(GenerationWorker.pause(for: .nominal) == 20 && GenerationWorker.pause(for: .fair) == 60)
    }

    @Test func hourlyCap() {
        let now = Date(timeIntervalSince1970: 10_000)
        let recent = (0 ..< 12).map { now.addingTimeInterval(-Double($0) * 60) }
        #expect(GenerationWorker.waitForHourlyCap(started: recent, now: now) > 0)
        #expect(GenerationWorker.waitForHourlyCap(started: Array(recent.prefix(11)), now: now) == 0)
    }

    @Test @MainActor func queueDedupedAndPrioritised() async {
        let (worker, _, events) = makeWorker(generator: FixtureGenerator(delay: 30))
        await worker.enqueue([job(.tense, priority: 1)])
        await events.wait { $0.contains { if case .started = $0 { return true } else { return false } } }
        await worker.enqueue([job(.calm, priority: 1), job(.calm, priority: 1), job(.epic, priority: 3)])
        let pending = await worker.pending
        #expect(pending.map(\.request.mood) == [.epic, .calm])
        await worker.cancelAll()
    }

    @Test @MainActor func threeFailuresPause() async {
        let (worker, _, events) = makeWorker(generator: FixtureGenerator(fails: true))
        await worker.enqueue([job(.tense), job(.calm), job(.epic), job(.joyful)])
        await events.wait { $0.contains { if case .paused = $0 { return true } else { return false } } }
        let failures = events.all.filter { if case .failed = $0 { return true } else { return false } }.count
        #expect(failures == 3)
    }

    @Test @MainActor func crashMarkerSwitchesToShortRecipes() async {
        let defaults = UserDefaults(suiteName: "worker.crash.\(UUID())")!
        defaults.set(2, forKey: GenerationWorker.crashCountKey)
        let (worker, library, events) = makeWorker(generator: FixtureGenerator(), defaults: defaults)
        await worker.enqueue([job()])
        await events.wait { finished($0) == 1 }
        #expect(library.pieces.first?.frames == 2_646_000)
    }
    @Test @MainActor func engineCancellationIsNotAFailure() async {
        let generator = InterruptibleGenerator()
        let (worker, _, events) = makeWorker(generator: generator)
        await worker.enqueue([job()])
        await events.wait { $0.contains { if case .started = $0 { return true } else { return false } } }
        await worker.cancelAll()
        try? await Task.sleep(for: .milliseconds(300))
        #expect(!events.all.contains { if case .failed = $0 { return true } else { return false } })
    }

    /// A memory warning stops the piece in progress but not the plan: the same job comes
    /// back after a pause with the short recipe, and the rest of the queue follows.
    @Test @MainActor func interruptionKeepsTheQueueAndRetriesShorter() async {
        let generator = InterruptibleGenerator()
        let sleeps = Sleeps()
        let (worker, library, events) = makeWorker(generator: generator, sleeps: sleeps)
        await worker.enqueue([job(.tense), job(.calm)])
        await events.wait { $0.contains { if case .started = $0 { return true } else { return false } } }
        await worker.interrupt(retryAfter: 60, shorter: true)
        await events.wait { finished($0) == 2 }
        #expect(finished(events.all) == 2, "events: \(events.all)")
        #expect(!events.all.contains { if case .failed = $0 { return true } else { return false } })
        #expect(sleeps.all.contains(60))
        #expect(generator.rendered.count == 3)
        #expect(generator.rendered.dropFirst().first == .shortMusic)
        #expect(generator.rendered.last == .music)
        #expect(Set(library.pieces.compactMap(\.mood)) == [.tense, .calm])
    }

    /// The on-device language model can stay busy for a long book: the worker waits for
    /// it a minute at most, then composes anyway.
    @Test @MainActor func analysisWaitIsCapped() async {
        var busy = calm
        busy.analysisRunning = true
        let sleeps = Sleeps()
        let (worker, _, events) = makeWorker(generator: FixtureGenerator(), admission: busy, sleeps: sleeps)
        await worker.enqueue([job()])
        await events.wait { finished($0) == 1 }
        #expect(finished(events.all) == 1)
        let waits = events.all.filter { if case .waiting("analysis") = $0 { return true } else { return false } }.count
        #expect(waits == GenerationWorker.maximumAnalysisWaits)
    }

    /// A whole starter pack (nine pieces) stays queued: a pack cut to the queue's limit
    /// could never finish.
    @Test @MainActor func fullPackStaysQueued() async {
        let (worker, _, events) = makeWorker(generator: FixtureGenerator(delay: 30))
        let moods: [MusicMood] = [.calm, .tense, .epic, .joyful, .eerie, .solemn, .mysterious, .romantic, .dramatic]
        await worker.enqueue(moods.map { job($0, priority: 13) })
        await events.wait { $0.contains { if case .started = $0 { return true } else { return false } } }
        #expect(await worker.pending.count == 8)
        await worker.cancelAll()
    }

    /// Asking again for a piece already asked for now does not queue a second one.
    @Test @MainActor func immediateRequestsAreNotDuplicated() async {
        let (worker, _, events) = makeWorker(generator: FixtureGenerator(delay: 30))
        await worker.enqueue([job(.calm, priority: 1)])
        await events.wait { $0.contains { if case .started = $0 { return true } else { return false } } }
        var first = job(.tense, priority: GenerationWorker.immediatePriority)
        var second = first
        second.prompt.id = "another.prompt"
        first.prompt.id = "a.prompt"
        await worker.enqueue([first])
        await worker.enqueue([second])
        #expect(await worker.pending.filter { $0.request.mood == .tense }.count == 1)
        await worker.cancelAll()
    }
}

