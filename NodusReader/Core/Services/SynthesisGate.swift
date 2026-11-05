// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// One mutable voice/synthesis at a time, with interactive priority and cancellable waiters.
actor SynthesisGate {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }
    private var busy = false
    private var waiters: [Waiter] = []
    private var backgroundWaiters: [Waiter] = []
    var queuedRequestCount: Int { waiters.count + backgroundWaiters.count }

    func run<T>(background: Bool = false, _ operation: () async throws -> T) async throws -> T {
        try await acquire(background: background)
        defer { release() }
        try Task.checkCancellation()
        return try await operation()
    }

    private func acquire(background: Bool) async throws {
        try Task.checkCancellation()
        if !busy { busy = true; return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()); return }
                let waiter = Waiter(id: id, continuation: continuation)
                if background { backgroundWaiters.append(waiter) }
                else { waiters.append(waiter) }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    private func cancelWaiter(_ id: UUID) {
        if let i = waiters.firstIndex(where: { $0.id == id }) {
            waiters.remove(at: i).continuation.resume(throwing: CancellationError())
        } else if let i = backgroundWaiters.firstIndex(where: { $0.id == id }) {
            backgroundWaiters.remove(at: i).continuation.resume(throwing: CancellationError())
        }
    }

    private func release() {
        if !waiters.isEmpty { waiters.removeFirst().continuation.resume() }
        else if !backgroundWaiters.isEmpty { backgroundWaiters.removeFirst().continuation.resume() }
        else { busy = false }
    }
}
