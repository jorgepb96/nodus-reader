// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// Stop waiting for a shared/uninterruptible native load as soon as its caller is cancelled.
/// The underlying task still owns its resources until it finishes. Its owner decides whether
/// to cancel it; cancelling one waiter must not cancel another caller's shared load.
enum CancellableTaskValue {
    static func value<Value: Sendable, Failure: Error>(of task: Task<Value, Failure>) async throws -> Value {
        let result = Resolution<Value>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                result.install(continuation)
                Task.detached {
                    result.resolve(await task.result.mapError { $0 as Error })
                }
            }
        } onCancel: {
            result.resolve(.failure(CancellationError()))
        }
    }

    private final class Resolution<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var completed = false
        private var result: Result<Value, Error>?
        private var continuation: CheckedContinuation<Value, Error>?

        func install(_ continuation: CheckedContinuation<Value, Error>) {
            lock.lock()
            if let result {
                self.result = nil
                lock.unlock()
                continuation.resume(with: result)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }

        func resolve(_ result: Result<Value, Error>) {
            lock.lock()
            guard !completed else { lock.unlock(); return }
            completed = true
            let continuation = self.continuation
            self.continuation = nil
            if continuation == nil { self.result = result }
            lock.unlock()
            continuation?.resume(with: result)
        }
    }
}
