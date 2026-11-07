// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// A single producer survives normal sentence advances. Repeated requests
/// update demand through `next`; only an explicit cancel interrupts its work.
@MainActor
final class NarrationPrefetchWorker {
    private var task: Task<Void, Never>?
    var isRunning: Bool { task != nil }
    private var token = UUID()

    func start(next: @escaping () -> Int?, produce: @escaping (Int) async throws -> Void) {
        guard task == nil else { return }
        let generation = token
        task = Task { [weak self] in
            defer { if self?.token == generation { self?.task = nil } }
            while !Task.isCancelled, self?.token == generation, let target = next() {
                do { try await produce(target) } catch { return }
            }
        }
    }

    @discardableResult
    func cancel() -> Task<Void, Never>? {
        let pending = task
        token = UUID()
        task?.cancel()
        task = nil
        return pending
    }
}

enum NarrationPrefetchPolicy {
    /// Durations are in sentence order. A nil duration is the next cache miss;
    /// count and seconds bounds prevent an unbounded in-memory audio queue.
    static func nextOffset(durations: [TimeInterval?], rate: Double,
                           targetSeconds: Double = 30, maximumSentences: Int = 24) -> Int? {
        var seconds = 0.0
        for (offset, duration) in durations.prefix(maximumSentences).enumerated() {
            if seconds >= targetSeconds { return nil }
            guard let duration else { return offset }
            seconds += max(0, duration) / max(0.1, rate)
        }
        return nil
    }
}
