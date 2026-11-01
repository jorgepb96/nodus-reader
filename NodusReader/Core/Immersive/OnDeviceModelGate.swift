// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// One request at a time to the on-device language model, for the whole app:
/// the system model refuses concurrent requests from the same app, and recaps
/// (Story Companion) and scene analysis (Immersive Audio) both use it.
/// Interactive requests are served before background ones; a waiter whose
/// task is cancelled leaves the queue at once.
actor OnDeviceModelGate {
    static let shared = OnDeviceModelGate()

    enum Priority: Sendable {
        /// The reader asked for something and is waiting (a recap).
        case interactive
        /// Work done ahead of time (passage notes, scene analysis).
        case background
    }

    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    private var busy = false
    private var interactive: [Waiter] = []
    private var background: [Waiter] = []

    /// Number of requests waiting (for tests and diagnostics).
    var waitingCount: Int { interactive.count + background.count }
    var isBusy: Bool { busy }

    func run<T: Sendable>(_ priority: Priority, _ work: @Sendable () async throws -> T) async throws -> T {
        try await acquire(priority)
        defer { release() }
        try Task.checkCancellation()
        return try await work()
    }

    private func acquire(_ priority: Priority) async throws {
        try Task.checkCancellation()
        if !busy {
            busy = true
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let waiter = Waiter(id: id, continuation: continuation)
                switch priority {
                case .interactive: interactive.append(waiter)
                case .background: background.append(waiter)
                }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    private func cancel(_ id: UUID) {
        if let index = interactive.firstIndex(where: { $0.id == id }) {
            interactive.remove(at: index).continuation.resume(throwing: CancellationError())
        } else if let index = background.firstIndex(where: { $0.id == id }) {
            background.remove(at: index).continuation.resume(throwing: CancellationError())
        }
    }

    /// Hands the model to the next waiter (still busy) or frees it.
    private func release() {
        if !interactive.isEmpty {
            interactive.removeFirst().continuation.resume()
        } else if !background.isEmpty {
            background.removeFirst().continuation.resume()
        } else {
            busy = false
        }
    }
}
