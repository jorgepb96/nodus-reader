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
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor [weak self] in
                self?.handle(notification)
            }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    func withSuspendedRecording(_ body: () -> Void) {
        let previous = isSuspended
        isSuspended = true
        body()
        isSuspended = previous
    }

    func recordDelete(_ type: SyncEntityType, id: UUID, payloadJSON: String = "") {
        enqueue(type: type, id: id, operation: .delete, payloadJSON: payloadJSON)
        let descriptors = FetchDescriptor<SyncTombstone>()
        let tombstones = (try? context.fetch(descriptors)) ?? []
        if !tombstones.contains(where: { $0.entityType == type && $0.entityID == id }) {
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
        for tombstone in tombstones {
            enqueue(type: tombstone.entityType, id: tombstone.entityID, operation: .delete)
        }
        persistJournal()
    }

    func pendingCount() -> Int {
        (try? context.fetchCount(FetchDescriptor<SyncOutboxEntry>())) ?? 0
    }

    private func handle(_ notification: Notification) {
        guard !isRecording, !isSuspended else { return }
        let inserted = notification.userInfo?[ModelContext.NotificationKey.insertedIdentifiers] as? Set<PersistentIdentifier> ?? []
        let updated = notification.userInfo?[ModelContext.NotificationKey.updatedIdentifiers] as? Set<PersistentIdentifier> ?? []
        guard !inserted.isEmpty || !updated.isEmpty else { return }

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
                break
            }
        }
        persistJournal()
    }

    private func enqueue(type: SyncEntityType, id: UUID, operation: SyncOperationKind,
                         payloadJSON: String = "") {
        let descriptor = FetchDescriptor<SyncOutboxEntry>()
        let existing = (try? context.fetch(descriptor)) ?? []
        if let entry = existing.first(where: { $0.entityType == type && $0.entityID == id }) {
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
        NotificationCenter.default.post(name: .nodusSyncOutboxChanged, object: nil)
    }
}
