// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// One network pass at a time. Events only advance the next deadline; they
/// never cancel an upload or postpone work indefinitely during continuous use.
@MainActor
final class SyncCoordinator {
    private let perform: () async -> Date?
    private var timer: Task<Void, Never>?
    private(set) var scheduledAt: Date?
    private(set) var isRunning = false
    private var requestedWhileRunning: Date?
    private var generation = 0

    init(perform: @escaping () async -> Date?) {
        self.perform = perform
    }

    deinit { timer?.cancel() }

    func request(at date: Date = Date()) {
        if isRunning {
            requestedWhileRunning = min(requestedWhileRunning ?? date, date)
            return
        }
        guard scheduledAt == nil || date < scheduledAt! else { return }
        timer?.cancel()
        scheduledAt = date
        timer = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(max(0, date.timeIntervalSinceNow))) }
            catch { return }
            guard !Task.isCancelled else { return }
            self?.timer = nil
            self?.scheduledAt = nil
            await self?.runNow()
        }
    }

    func runNow() async {
        if isRunning {
            request()
            return
        }
        // Detach the timer before awaiting. A later event must not cancel the
        // task which is currently transferring a document or saving a record.
        timer?.cancel()
        timer = nil
        scheduledAt = nil
        isRunning = true
        let currentGeneration = generation
        let nextAttempt = await perform()
        isRunning = false
        guard currentGeneration == generation else {
            if let pending = requestedWhileRunning {
                requestedWhileRunning = nil
                request(at: pending)
            }
            return
        }
        let pending = requestedWhileRunning
        requestedWhileRunning = nil
        if let nextAttempt { request(at: nextAttempt) }
        if let pending { request(at: pending) }
    }

    /// Invalidates scheduled follow-ups without cancelling an in-flight save.
    func stop() {
        generation += 1
        timer?.cancel()
        timer = nil
        scheduledAt = nil
        requestedWhileRunning = nil
    }
}
