// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Testing
@testable import Nodus_Reader

@Test @MainActor
func prefetchContinuesInFlightWorkWhenPlaybackAdvances() async {
    let worker = NarrationPrefetchWorker()
    defer { worker.cancel() }
    let (events, eventSender) = AsyncStream<Int>.makeStream()
    let (releases, releaseSender) = AsyncStream<Void>.makeStream()
    var event = events.makeAsyncIterator()
    var release = releases.makeAsyncIterator()
    var current = 0
    var ready: Set<Int> = []
    var replacementRan = false
    worker.start(next: { ((current + 1)..<3).first { !ready.contains($0) } }, produce: { target in
        eventSender.yield(target)
        _ = await release.next()
        try Task.checkCancellation()
        ready.insert(target)
        eventSender.yield(-target)
    })
    #expect(await event.next() == 1)
    current = 1
    worker.start(next: { 2 }, produce: { _ in replacementRan = true })
    releaseSender.yield(())
    #expect(await event.next() == -1)
    #expect(await event.next() == 2)
    releaseSender.yield(())
    #expect(await event.next() == -2)
    #expect(ready == [1, 2])
    #expect(!replacementRan)
}

@Test @MainActor
func cancelledPrefetchCannotCommitOrClearItsReplacement() async {
    let worker = NarrationPrefetchWorker()
    defer { worker.cancel() }
    let (events, eventSender) = AsyncStream<Int>.makeStream()
    var event = events.makeAsyncIterator()
    var oldRelease: CheckedContinuation<Void, Never>?
    var replacementRelease: CheckedContinuation<Void, Never>?
    var staleCommitted = false
    var replacementReady = false
    var thirdRan = false
    worker.start(next: { 1 }, produce: { _ in
        await withCheckedContinuation { continuation in
            oldRelease = continuation
            eventSender.yield(1)
        }
        do {
            try Task.checkCancellation()
            staleCommitted = true
        } catch {
            eventSender.yield(-1)
            throw error
        }
    })
    #expect(await event.next() == 1)
    let cancelled = worker.cancel()
    worker.start(next: { replacementReady ? nil : 2 }, produce: { _ in
        await withCheckedContinuation { continuation in
            replacementRelease = continuation
            eventSender.yield(2)
        }
        replacementReady = true
        eventSender.yield(-2)
    })
    #expect(await event.next() == 2)
    oldRelease?.resume()
    #expect(await event.next() == -1)
    // Its defer must finish without clearing the replacement's task handle.
    await cancelled?.value
    worker.start(next: { 3 }, produce: { _ in thirdRan = true })
    replacementRelease?.resume()
    #expect(await event.next() == -2)
    #expect(replacementReady)
    #expect(!staleCommitted)
    #expect(!thirdRan)
}

@Test
func prefetchBudgetTracksPlaybackSecondsAndHasACountLimit() {
    // Two long sentences suffice; two short ones don't. At 2×, thirty
    // seconds of stored audio cover only fifteen seconds of listening.
    #expect(NarrationPrefetchPolicy.nextOffset(durations: [15, 15, nil], rate: 1) == nil)
    #expect(NarrationPrefetchPolicy.nextOffset(durations: [2, 2, nil], rate: 1) == 2)
    #expect(NarrationPrefetchPolicy.nextOffset(durations: [15, 15, nil], rate: 2) == 2)
    #expect(NarrationPrefetchPolicy.nextOffset(durations: Array(repeating: 0.1, count: 24) + [nil], rate: 1) == nil)
    #expect(NarrationPrefetchPolicy.nextOffset(durations: [], rate: 1) == nil)
}
