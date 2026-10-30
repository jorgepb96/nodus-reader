// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import SwiftData
#if os(iOS)
import UIKit
#endif

extension Notification.Name {
    static let nodusSyncOutboxChanged = Notification.Name("nodus.sync.outboxChanged")
}

/// Turns SwiftData saves into a durable CloudKit outbox. The journal never
/// uploads anything itself; `CloudSyncService` drains the queue when iCloud is
/// enabled and available.
@MainActor
final class SyncJournal {
    private let context: ModelContext
    private var observer: NSObjectProtocol?
    private var isRecording = false
    private var isSuspended = false

    init(context: ModelContext) {
        self.context = context
        observer = NotificationCenter.default.addObserver(
            forName: ModelContext.didSave,
            object: context,
            queue: nil
        ) { [weak self] notification in
            // A nil queue runs the block synchronously on the posting thread,
            // while `withSuspendedRecording` is still active. That is what
            // prevents programmatic remote applies from being re-enqueued.
            guard Thread.isMainThread else { return }
            MainActor.assumeIsolated {
                self?.handle(notification)
            }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    func withSuspendedRecording<T>(_ body: () throws -> T) rethrows -> T {
        let previous = isSuspended
        isSuspended = true
        defer { isSuspended = previous }
        return try body()
    }

    func recordDelete(_ type: SyncEntityType, id: UUID, payloadJSON: String = "") {
        enqueue(type: type, id: id, operation: .delete, payloadJSON: payloadJSON)
        let raw = type.rawValue
        var descriptor = FetchDescriptor<SyncTombstone>(
            predicate: #Predicate { $0.entityID == id && $0.entityTypeRaw == raw }
        )
        descriptor.fetchLimit = 1
        if let existing = (try? context.fetch(descriptor))?.first {
            existing.deletedAt = Date()
            existing.isPushed = false
        } else {
            context.insert(SyncTombstone(entityType: type, entityID: id))
        }
        persistJournal()
    }

    func enqueueAll() {
        let books = (try? context.fetch(FetchDescriptor<Book>())) ?? []
        let collections = (try? context.fetch(FetchDescriptor<LibraryCollection>())) ?? []
        let memberships = (try? context.fetch(FetchDescriptor<CollectionMembership>())) ?? []
        let bookmarks = (try? context.fetch(FetchDescriptor<Bookmark>())) ?? []
        let annotations = (try? context.fetch(FetchDescriptor<Annotation>())) ?? []
        for book in books { enqueue(type: .book, id: book.id, operation: .upsert) }
        for collection in collections { enqueue(type: .collection, id: collection.id, operation: .upsert) }
        for membership in memberships { enqueue(type: .membership, id: membership.id, operation: .upsert) }
        for bookmark in bookmarks { enqueue(type: .bookmark, id: bookmark.id, operation: .upsert) }
        for annotation in annotations { enqueue(type: .annotation, id: annotation.id, operation: .upsert) }
        let tombstones = (try? context.fetch(FetchDescriptor<SyncTombstone>())) ?? []
        for tombstone in tombstones where !tombstone.isPushed {
            enqueue(type: tombstone.entityType, id: tombstone.entityID, operation: .delete)
        }
        persistJournal()
    }

    /// Removes an outbox entry after its push succeeded, unless it was
    /// re-enqueued while the push was in flight. In that case a newer edit or a
    /// delete is still waiting to be sent and the entry must stay queued.
    func completePush(_ entry: SyncOutboxEntry, enqueuedAt: Date, operation: SyncOperationKind) {
        guard isCurrent(entry, enqueuedAt: enqueuedAt, operation: operation) else { return }
        context.delete(entry)
    }

    func isCurrent(_ entry: SyncOutboxEntry, enqueuedAt: Date, operation: SyncOperationKind) -> Bool {
        entry.modelContext != nil && entry.createdAt == enqueuedAt && entry.operation == operation
    }

    /// A failed older upload must not back off a newer edit or deletion.
    func failPush(_ entry: SyncOutboxEntry, enqueuedAt: Date, operation: SyncOperationKind,
                  error: Error, retryAfter: TimeInterval? = nil, now: Date = Date()) {
        guard isCurrent(entry, enqueuedAt: enqueuedAt, operation: operation) else { return }
        entry.attempts += 1
        let delay = min(300, pow(2, Double(min(entry.attempts, 6))) * 5)
        entry.nextAttemptAt = now.addingTimeInterval(max(delay, retryAfter ?? 0))
        entry.lastError = error.localizedDescription
    }

    func nextAttemptAt() throws -> Date? {
        var descriptor = FetchDescriptor<SyncOutboxEntry>(sortBy: [SortDescriptor(\SyncOutboxEntry.nextAttemptAt)])
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first?.nextAttemptAt
    }

    func pendingCount() -> Int {
        (try? context.fetchCount(FetchDescriptor<SyncOutboxEntry>())) ?? 0
    }

    private func handle(_ notification: Notification) {
        guard !isRecording, !isSuspended else { return }
        let inserted = Self.identifiers(notification, .insertedIdentifiers)
        let updated = Self.identifiers(notification, .updatedIdentifiers)
        guard !inserted.isEmpty || !updated.isEmpty else { return }

        var recorded = false
        for identifier in inserted.union(updated) {
            let model = context.model(for: identifier)
            switch model {
            case let book as Book:
                enqueue(type: .book, id: book.id, operation: .upsert)
            case let collection as LibraryCollection:
                enqueue(type: .collection, id: collection.id, operation: .upsert)
            case let membership as CollectionMembership:
                enqueue(type: .membership, id: membership.id, operation: .upsert)
            case let bookmark as Bookmark:
                enqueue(type: .bookmark, id: bookmark.id, operation: .upsert)
            case let annotation as Annotation:
                enqueue(type: .annotation, id: annotation.id, operation: .upsert)
            default:
                continue
            }
            recorded = true
        }
        if recorded { persistJournal() }
    }

    /// SwiftData posts the identifiers as an `Array`, not the `Set` one might
    /// expect; accept both so a save is never silently left out of the outbox.
    private static func identifiers(_ notification: Notification,
                                    _ key: ModelContext.NotificationKey) -> Set<PersistentIdentifier> {
        let value = notification.userInfo?[key.rawValue]
        if let array = value as? [PersistentIdentifier] { return Set(array) }
        return value as? Set<PersistentIdentifier> ?? []
    }

    private func enqueue(type: SyncEntityType, id: UUID, operation: SyncOperationKind,
                         payloadJSON: String = "") {
        // An indexed lookup: this runs for every changed object on every save,
        // so scanning the whole outbox would grow with the library.
        let raw = type.rawValue
        if operation == .upsert {
            let tombstone = FetchDescriptor<SyncTombstone>(
                predicate: #Predicate { $0.entityID == id && $0.entityTypeRaw == raw }
            )
            // recordDelete saves the tombstone before the model is removed.
            // Relationship updates in that save must not turn it into an upsert.
            if ((try? context.fetchCount(tombstone)) ?? 0) > 0 { return }
        }
        var descriptor = FetchDescriptor<SyncOutboxEntry>(
            predicate: #Predicate { $0.entityID == id && $0.entityTypeRaw == raw }
        )
        descriptor.fetchLimit = 1
        if let entry = (try? context.fetch(descriptor))?.first {
            entry.operationRaw = operation.rawValue
            entry.createdAt = Date()
            entry.nextAttemptAt = Date()
            entry.attempts = 0
            entry.lastError = ""
            if !payloadJSON.isEmpty { entry.payloadJSON = payloadJSON }
        } else {
            context.insert(SyncOutboxEntry(entityType: type, entityID: id,
                                           operation: operation, payloadJSON: payloadJSON))
        }
    }

    private func persistJournal() {
        guard !isRecording else { return }
        isRecording = true
        defer { isRecording = false }
        try? context.save()
        NotificationCenter.default.post(name: .nodusSyncOutboxChanged, object: self)
    }
}
