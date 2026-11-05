// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Testing
@testable import Nodus_Reader

private actor SuspendedSpeechLoad {
    private var continuation: CheckedContinuation<Int, Never>?
    private(set) var released = false
    let started: AsyncStream<Void>
    private let sender: AsyncStream<Void>.Continuation
    init() { (started, sender) = AsyncStream<Void>.makeStream() }
    func wait() async -> Int {
        await withCheckedContinuation {
            continuation = $0
            sender.yield(())
        }
    }
    func finish() {
        released = true
        continuation?.resume(returning: 42)
        continuation = nil
    }
}

@Test @MainActor
func switchingModelsDoesNotWaitForCancelledNativeLoad() async throws {
    let gate = SynthesisGate()
    let load = SuspendedSpeechLoad()
    let native = Task<Int, Never> { await load.wait() }
    var started = load.started.makeAsyncIterator()
    _ = await started.next()
    let (events, sender) = AsyncStream<String>.makeStream()
    var event = events.makeAsyncIterator()
    // A fallback makes regressions fail rather than leave the suite suspended forever.
    let fallback = Task {
        do { try await Task.sleep(for: .seconds(5)); await load.finish() } catch {}
    }
    defer { fallback.cancel() }
    let oldVoice = Task {
        do {
            _ = try await gate.run {
                sender.yield("old-started")
                return try await CancellableTaskValue.value(of: native)
            }
            sender.yield("old-finished")
        } catch is CancellationError { sender.yield("old-cancelled") }
        catch { sender.yield("old-error") }
    }
    #expect(await event.next() == "old-started")
    oldVoice.cancel()
    #expect(await event.next() == "old-cancelled")
    let fastVoice = try await gate.run { 7 }
    #expect(fastVoice == 7)
    #expect(await !load.released, "the new voice must proceed before the old native load returns")
    #expect(!native.isCancelled, "one cancelled waiter does not own a shared load")
    await load.finish()
    #expect(await native.value == 42)
    await oldVoice.value
}

@Test @MainActor
func cancelledQueuedSynthesisIsRemovedBeforeActiveWorkEnds() async throws {
    let gate = SynthesisGate()
    let load = SuspendedSpeechLoad()
    let active = Task { try await gate.run { await load.wait() } }
    var started = load.started.makeAsyncIterator()
    _ = await started.next()
    let fallback = Task {
        do { try await Task.sleep(for: .seconds(5)); await load.finish() } catch {}
    }
    defer { fallback.cancel() }
    let cancelled = Task { try await gate.run { Issue.record("cancelled synthesis ran"); return 0 } }
    while await gate.queuedRequestCount == 0, await !load.released { await Task.yield() }
    #expect(await gate.queuedRequestCount == 1)
    cancelled.cancel()
    do { _ = try await cancelled.value; Issue.record("expected cancellation") }
    catch { #expect(error is CancellationError) }
    #expect(await !load.released)
    await load.finish()
    #expect(try await active.value == 42)
    #expect(try await gate.run { 3 } == 3)
}

@Test
func cancellingOneLoadWaiterKeepsAnotherWaiterAlive() async throws {
    let load = SuspendedSpeechLoad()
    let native = Task<Int, Never> { await load.wait() }
    var started = load.started.makeAsyncIterator()
    _ = await started.next()
    let first = Task { try await CancellableTaskValue.value(of: native) }
    let second = Task { try await CancellableTaskValue.value(of: native) }
    first.cancel()
    do { _ = try await first.value; Issue.record("expected cancellation") }
    catch { #expect(error is CancellationError) }
    await load.finish()
    #expect(try await second.value == 42)
    #expect(!native.isCancelled)
}
