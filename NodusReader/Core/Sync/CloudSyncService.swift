// SPDX-License-Identifier: AGPL-3.0-only
import CloudKit
import Foundation
import Observation
import SwiftData
#if os(macOS)
import Security
#endif

/// CloudKit + iCloud Documents synchronisation for the personal library.
///
/// Metadata and annotations live in a private CloudKit database; originals and
/// covers live in the user's iCloud Documents container. Models, voices, audio
/// and OCR caches never enter either store. The service is opt-in, works from a
/// durable local outbox and resolves conflicts by timestamp, with explicit
/// tombstones for deletions.
@MainActor
@Observable
final class CloudSyncService {
    enum Status: Equatable {
        case disabled
        case unavailable(String)
        case syncing
        case upToDate
        case offline
        case error(String)

        var title: String {
            switch self {
            case .disabled: "Sync is off"
            case .unavailable: "iCloud unavailable"
            case .syncing: "Syncing…"
            case .upToDate: "Up to date"
            case .offline: "Waiting for a connection"
            case .error: "Sync error"
            }
        }

        var detail: String? {
            switch self {
            case .disabled: "Your library stays on this device."
            case .unavailable(let message): message
            case .syncing: "Changes are moving through your personal iCloud."
            case .upToDate: nil
            case .offline: "Changes are queued and will be sent when you are back online."
            case .error(let message): message
            }
        }
    }

    private enum Key {
        static let enabled = "nodus.sync.enabled"
        static let lastSync = "nodus.sync.last"
        static let changeToken = "nodus.sync.changeToken"
        static let initialPush = "nodus.sync.initialPush"
    }

    static let zoneName = "NodusReader"

    private let context: ModelContext
    private let library: LibraryService
    private let journal: SyncJournal
    private let documents: ICloudDocumentStore
    private let defaults: UserDefaults
    private var container: CKContainer?
    private var database: CKDatabase? { container?.privateCloudDatabase }
    private let zoneID: CKRecordZone.ID

    private(set) var isEnabled: Bool
    private(set) var status: Status = .disabled
    private(set) var isAvailable = false
    private(set) var fileSyncAvailable = false
    private(set) var availabilityMessage = ""
    private(set) var lastSync: Date?
    private(set) var pendingCount = 0
    private(set) var isSyncing = false
    private(set) var downloadingBookIDs: Set<UUID> = []
    private(set) var downloadError: String?

    private var syncTask: Task<Void, Never>?
    nonisolated(unsafe) private var outboxObserver: NSObjectProtocol?
    private var zoneReady = false
    private var started = false
    private var activeSyncGeneration = UUID()

    init(context: ModelContext, library: LibraryService, journal: SyncJournal,
         fileStore: FileStore = .shared, defaults: UserDefaults = .standard) {
        self.context = context
        self.library = library
        self.journal = journal
        self.documents = ICloudDocumentStore(fileStore: fileStore)
        self.defaults = defaults
        self.isEnabled = defaults.bool(forKey: Key.enabled)
        self.lastSync = defaults.object(forKey: Key.lastSync) as? Date
        self.zoneID = CKRecordZone.ID(zoneName: Self.zoneName, ownerName: CKCurrentUserDefaultName)
        self.pendingCount = journal.pendingCount()

        outboxObserver = NotificationCenter.default.addObserver(
            forName: .nodusSyncOutboxChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.pendingCount = self?.journal.pendingCount() ?? 0
                self?.scheduleSync()
            }
        }
    }

    deinit {
        if let outboxObserver { NotificationCenter.default.removeObserver(outboxObserver) }
    }

    var lastSyncText: String {
        guard let lastSync else { return "Not yet synced" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return "Last successful sync: \(formatter.localizedString(for: lastSync, relativeTo: Date()))"
    }

    // MARK: Lifecycle

    func start() async {
        guard !started else {
            if isEnabled { await syncNow() }
            return
        }
        started = true
        await refreshAvailability()
        if isEnabled, isAvailable {
            if !defaults.bool(forKey: Key.initialPush) {
                journal.enqueueAll()
                defaults.set(true, forKey: Key.initialPush)
            }
            await syncNow()
        }
    }

    func refreshAvailability() async {
        pendingCount = journal.pendingCount()
        reconcileDownloadStates()
        fileSyncAvailable = documents.isAvailable
        guard FileManager.default.ubiquityIdentityToken != nil,
              Self.hasCloudKitContainerEntitlement() else {
            isAvailable = false
            availabilityMessage = "Sign in to iCloud and enable iCloud Drive for Nodus Reader to sync your library."
            if !isEnabled { status = .disabled } else { status = .unavailable(availabilityMessage) }
            return
        }
        if container == nil {
            container = CKContainer(identifier: ICloudDocumentStore.containerIdentifier)
        }
        guard let container else {
            isAvailable = false
            availabilityMessage = "This build is not signed for the Nodus Reader iCloud container."
            return
        }
        do {
            let account = try await container.accountStatus()
            switch account {
            case .available:
                if fileSyncAvailable {
                    isAvailable = true
                    availabilityMessage = ""
                } else {
                    isAvailable = false
                    availabilityMessage = "iCloud Drive is not available. Turn on iCloud Drive for Nodus Reader to sync documents and covers."
                }
            case .noAccount:
                isAvailable = false
                availabilityMessage = "Sign in to iCloud on this device to sync your library."
            case .restricted:
                isAvailable = false
                availabilityMessage = "iCloud is restricted on this device."
            case .couldNotDetermine:
                isAvailable = false
                availabilityMessage = "Nodus Reader could not determine the state of your iCloud account."
            case .temporarilyUnavailable:
                isAvailable = false
                availabilityMessage = "iCloud is temporarily unavailable. Try again shortly."
            @unknown default:
                isAvailable = false
                availabilityMessage = "iCloud is unavailable."
            }
        } catch {
            isAvailable = false
            fileSyncAvailable = false
            availabilityMessage = "This build is not signed for the Nodus Reader iCloud container. Configure the CloudKit container and entitlements before using sync."
        }

        if !isEnabled {
            status = .disabled
        } else if !isAvailable {
            status = .unavailable(availabilityMessage)
        } else if !isSyncing, status == .disabled || status == .unavailable(availabilityMessage) {
            status = .upToDate
        }
    }

    func setEnabled(_ enabled: Bool) async {
        guard enabled != isEnabled else { return }
        defaults.set(enabled, forKey: Key.enabled)
        isEnabled = enabled
        activeSyncGeneration = UUID()
        syncTask?.cancel()
        if !enabled {
            status = .disabled
            return
        }
        await refreshAvailability()
        guard isEnabled else {
            status = .disabled
            return
        }
        guard isAvailable else {
            status = .unavailable(availabilityMessage)
            return
        }
        status = .syncing
        journal.enqueueAll()
        defaults.set(true, forKey: Key.initialPush)
        await syncNow()
    }

    // MARK: Sync

    func syncNow() async {
        guard isEnabled, isAvailable, !isSyncing else { return }
        let generation = UUID()
        activeSyncGeneration = generation
        isSyncing = true
        status = .syncing
        defer { isSyncing = false }
        do {
            try await ensureZone()
            guard isEnabled, generation == activeSyncGeneration else { return }
            var pushError: Error?
            do {
                try await pushOutbox()
            } catch {
                pushError = error
            }
            guard isEnabled, generation == activeSyncGeneration else { return }
            try await pullChanges()
            guard isEnabled, generation == activeSyncGeneration else { return }
            lastSync = Date()
            defaults.set(lastSync, forKey: Key.lastSync)
            pendingCount = journal.pendingCount()
            status = pushError.map { status(for: $0) } ?? .upToDate
        } catch {
            guard isEnabled, generation == activeSyncGeneration else { return }
            pendingCount = journal.pendingCount()
            status = status(for: error)
        }
    }

    private func scheduleSync() {
        guard isEnabled, isAvailable else { return }
        syncTask?.cancel()
        syncTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await self?.syncNow()
        }
    }

    private func ensureZone() async throws {
        guard !zoneReady else { return }
        guard let database else { throw SyncServiceError.cloudKitUnavailable }
        do {
            _ = try await database.save(CKRecordZone(zoneID: zoneID))
        } catch let error as CKError where error.code == .serverRejectedRequest {
            // The zone already exists.
        }
        zoneReady = true
    }

    // MARK: Outbox

    private static func pushPriority(_ type: SyncEntityType) -> Int {
        switch type {
        case .book: 0
        case .collection: 1
        case .membership: 2
        case .bookmark: 3
        case .annotation: 4
        case .readingPosition, .theme, .preference: 5
        }
    }

    private func pushOutbox() async throws {
        let descriptor = FetchDescriptor<SyncOutboxEntry>(sortBy: [SortDescriptor(\SyncOutboxEntry.createdAt)])
        let entries = (try? context.fetch(descriptor)) ?? []
        let ordered = entries.sorted {
            let lhs = Self.pushPriority($0.entityType)
            let rhs = Self.pushPriority($1.entityType)
            return lhs == rhs ? $0.createdAt < $1.createdAt : lhs < rhs
        }
        var firstError: Error?
        for entry in ordered {
            guard entry.nextAttemptAt <= Date() else { continue }
            do {
                switch entry.operation {
                case .delete:
                    try await pushDeletion(entry)
                case .upsert:
                    try await pushUpsert(entry)
                }
                context.delete(entry)
                try context.save()
            } catch {
                entry.attempts += 1
                let delay = min(300, pow(2, Double(entry.attempts)) * 5)
                entry.nextAttemptAt = Date().addingTimeInterval(delay)
                entry.lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                try? context.save()
                if firstError == nil { firstError = error }
            }
        }
        pendingCount = journal.pendingCount()
        if let firstError { throw firstError }
    }

    private func pushUpsert(_ entry: SyncOutboxEntry) async throws {
        guard let database else { throw SyncServiceError.cloudKitUnavailable }
        guard let localDate = updatedAt(type: entry.entityType, id: entry.entityID),
              let record = buildRecord(for: entry) else {
            return
        }

        // A tombstone from another device wins over an offline upsert.
        if let tombstone = try? await database.record(for: tombstoneID(type: entry.entityType, id: entry.entityID)),
           let deletedAt = tombstone["deletedAt"] as? Date,
           deletedAt >= localDate {
            journal.withSuspendedRecording {
                deleteLocal(type: entry.entityType, id: entry.entityID)
                try? context.save()
            }
            return
        }

        // If the server already has a newer version, apply it instead of
        // overwriting it with this device's stale outbox entry.
        if let remote = try? await database.record(for: recordID(type: entry.entityType, id: entry.entityID)),
           let remoteDate = remote["updatedAt"] as? Date,
           remoteDate > localDate {
            journal.withSuspendedRecording {
                applyRemote(remote)
                try? context.save()
            }
            return
        }

        _ = try await database.modifyRecords(
            saving: [record],
            deleting: [],
            savePolicy: .allKeys,
            atomically: false
        )
        if entry.entityType == .book, let book = fetchBook(id: entry.entityID),
           !documents.hasRemoteFile(for: book) {
            documents.upload(book)
        }
    }

    private func pushDeletion(_ entry: SyncOutboxEntry) async throws {
        guard let database else { throw SyncServiceError.cloudKitUnavailable }
        let localTombstone = fetchTombstone(type: entry.entityType, id: entry.entityID)
        let deletedAt = localTombstone?.deletedAt ?? Date()
        let tombstone = CKRecord(recordType: "Tombstone",
                                  recordID: tombstoneID(type: entry.entityType, id: entry.entityID))
        tombstone["entityType"] = entry.entityType.rawValue
        tombstone["entityID"] = entry.entityID.uuidString
        tombstone["deletedAt"] = deletedAt

        let dataRecordID = recordID(type: entry.entityType, id: entry.entityID)
        do {
            _ = try await database.modifyRecords(
                saving: [tombstone],
                deleting: [dataRecordID],
                savePolicy: .allKeys,
                atomically: false
            )
        } catch let error as CKError where error.code == .partialFailure {
            let partial = error.partialErrorsByItemID ?? [:]
            if let tombstoneError = partial[tombstone.recordID] {
                throw tombstoneError
            }
            if let dataError = partial[dataRecordID] as? CKError,
               dataError.code != .unknownItem {
                throw dataError
            }
        } catch let error as CKError where error.code == .unknownItem {
            // The data record was already absent; the tombstone still saved.
        }

        localTombstone?.isPushed = true
        if entry.entityType == .book,
           let data = entry.payloadJSON.data(using: .utf8),
           let payload = try? JSONSerialization.jsonObject(with: data) as? [String: String],
           let fileName = payload["fileName"] {
            documents.deleteRemoteFiles(bookID: entry.entityID, fileName: fileName)
        }
    }

    // MARK: Pull

    private func pullChanges() async throws {
        guard let database else { throw SyncServiceError.cloudKitUnavailable }
        var token = loadChangeToken()
        var moreComing = true
        var retriedZone = false
        while moreComing {
            do {
                let changes = try await database.recordZoneChanges(inZoneWith: zoneID, since: token)
                try journal.withSuspendedRecording {
                    // Parents must exist before children: a membership or
                    // annotation can arrive in the same batch as its book.
                    let records = changes.modificationResultsByID.values.compactMap { result -> CKRecord? in
                        guard case .success(let modification) = result else { return nil }
                        return modification.record
                    }
                    for record in records.sorted(by: { Self.applyPriority($0.recordType) < Self.applyPriority($1.recordType) }) {
                        applyRemote(record)
                    }
                    for deletion in changes.deletions {
                        applyRemoteDeletion(deletion.recordID, recordType: deletion.recordType)
                    }
                    try context.save()
                }
                token = changes.changeToken
                saveChangeToken(changes.changeToken)
                moreComing = changes.moreComing
            } catch let error as CKError where error.code == .changeTokenExpired {
                token = nil
                clearChangeToken()
                moreComing = true
            } catch let error as CKError where error.code == .zoneNotFound || error.code == .userDeletedZone {
                guard !retriedZone else { throw error }
                retriedZone = true
                zoneReady = false
                token = nil
                clearChangeToken()
                try await ensureZone()
                moreComing = true
            }
        }
    }

    // MARK: Record construction

    private func buildRecord(for entry: SyncOutboxEntry) -> CKRecord? {
        guard let localUpdatedAt = updatedAt(type: entry.entityType, id: entry.entityID) else { return nil }
        let id = recordID(type: entry.entityType, id: entry.entityID)
        let record: CKRecord
        switch entry.entityType {
        case .book:
            guard let book = fetchBook(id: entry.entityID) else { return nil }
            record = CKRecord(recordType: "Book", recordID: id)
            record["title"] = book.title
            record["author"] = book.author
            record["format"] = book.formatRaw
            record["language"] = book.language
            record["published"] = book.published
            record["bookDescription"] = book.bookDescription
            record["fileName"] = book.fileName
            record["relativePath"] = book.relativePath
            record["fileSize"] = book.fileSize
            record["contentHash"] = book.contentHash
            record["addedAt"] = book.addedAt
            record["lastOpenedAt"] = book.lastOpenedAt
            record["progress"] = book.progress
            record["locatorJSON"] = book.locatorJSON
            record["status"] = book.statusRaw
            record["isFavorite"] = Int64(book.isFavorite ? 1 : 0)
            record["coverFileName"] = book.coverFileName ?? ""
            record["sourceDevice"] = book.sourceDevice
            record["lastPositionDevice"] = book.lastPositionDevice
            record["lastPositionDate"] = book.lastPositionDate
            record["preferredVoiceID"] = book.preferredVoiceID ?? ""
            record["readingMode"] = book.readingModeRaw
            record["updatedAt"] = localUpdatedAt
        case .collection:
            guard let collection = fetchCollection(id: entry.entityID) else { return nil }
            record = CKRecord(recordType: "Collection", recordID: id)
            record["name"] = collection.name
            record["parentID"] = collection.parentID?.uuidString ?? ""
            record["sortIndex"] = Int64(collection.sortIndex)
            record["createdAt"] = collection.createdAt
            record["updatedAt"] = collection.updatedAt
        case .membership:
            guard let membership = fetchMembership(id: entry.entityID),
                  let bookID = membership.book?.id,
                  let collectionID = membership.collection?.id else { return nil }
            record = CKRecord(recordType: "Membership", recordID: id)
            record["bookID"] = bookID.uuidString
            record["collectionID"] = collectionID.uuidString
            record["sortIndex"] = Int64(membership.sortIndex)
            record["addedAt"] = membership.addedAt
            record["updatedAt"] = membership.updatedAt
        case .bookmark:
            guard let bookmark = fetchBookmark(id: entry.entityID), let bookID = bookmark.book?.id else { return nil }
            record = CKRecord(recordType: "Bookmark", recordID: id)
            record["bookID"] = bookID.uuidString
            record["title"] = bookmark.title
            record["chapterTitle"] = bookmark.chapterTitle
            record["locatorJSON"] = bookmark.locatorJSON
            record["createdAt"] = bookmark.createdAt
            record["updatedAt"] = bookmark.updatedAt
        case .annotation:
            guard let annotation = fetchAnnotation(id: entry.entityID), let bookID = annotation.book?.id else { return nil }
            record = CKRecord(recordType: "Annotation", recordID: id)
            record["bookID"] = bookID.uuidString
            record["chapterIndex"] = Int64(annotation.chapterIndex)
            record["startOffset"] = Int64(annotation.startOffset)
            record["endOffset"] = Int64(annotation.endOffset)
            record["quote"] = annotation.quote
            record["note"] = annotation.note
            record["color"] = annotation.colorRaw
            record["createdAt"] = annotation.createdAt
            record["updatedAt"] = annotation.updatedAt
        case .readingPosition, .theme, .preference:
            return nil
        }
        return record
    }

    // MARK: Applying remote records

    private func applyRemote(_ record: CKRecord) {
        switch record.recordType {
        case "Book": applyRemoteBook(record)
        case "Collection": applyRemoteCollection(record)
        case "Membership": applyRemoteMembership(record)
        case "Bookmark": applyRemoteBookmark(record)
        case "Annotation": applyRemoteAnnotation(record)
        case "Tombstone": applyRemoteTombstone(record)
        default: break
        }
    }

    private func applyRemoteBook(_ record: CKRecord) {
        guard let id = uuid(from: record.recordID), let remoteDate = record["updatedAt"] as? Date else { return }
        if let local = fetchBook(id: id), local.updatedAt > remoteDate { return }
        let book: Book
        if let local = fetchBook(id: id) {
            book = local
        } else {
            book = Book(
                id: id,
                title: record["title"] as? String ?? "Untitled",
                author: record["author"] as? String ?? "",
                format: BookFormat(rawValue: record["format"] as? String ?? "") ?? .pdf,
                language: record["language"] as? String ?? "",
                published: record["published"] as? String ?? "",
                bookDescription: record["bookDescription"] as? String ?? "",
                fileName: record["fileName"] as? String ?? "",
                relativePath: record["relativePath"] as? String ?? "",
                fileSize: integer(record, "fileSize") ?? 0,
                contentHash: record["contentHash"] as? String ?? "",
                sourceDevice: record["sourceDevice"] as? String ?? ""
            )
            context.insert(book)
        }

        book.title = record["title"] as? String ?? book.title
        book.author = record["author"] as? String ?? book.author
        book.formatRaw = record["format"] as? String ?? book.formatRaw
        book.language = record["language"] as? String ?? book.language
        book.published = record["published"] as? String ?? book.published
        book.bookDescription = record["bookDescription"] as? String ?? book.bookDescription
        if let remoteName = record["fileName"] as? String, !remoteName.isEmpty {
            book.fileName = FileStore.sanitizedFileName(remoteName)
        }
        // Trust the stable ID, never a path string received from CloudKit.
        book.relativePath = "Library/\(book.id.uuidString)/\(book.fileName)"
        book.fileSize = integer(record, "fileSize") ?? book.fileSize
        book.contentHash = record["contentHash"] as? String ?? book.contentHash
        book.addedAt = record["addedAt"] as? Date ?? book.addedAt
        book.lastOpenedAt = record["lastOpenedAt"] as? Date
        book.progress = number(record, "progress") ?? book.progress
        book.locatorJSON = record["locatorJSON"] as? String ?? book.locatorJSON
        book.statusRaw = record["status"] as? String ?? book.statusRaw
        book.isFavorite = (integer(record, "isFavorite") ?? 0) == 1
        if let coverName = record["coverFileName"] as? String, !coverName.isEmpty {
            let safeCover = FileStore.sanitizedFileName(coverName)
            let localCover = library.fileStore.coverURL(for: safeCover)
            let hasLocalCover = localCover.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
            if book.coverFileName == nil || !hasLocalCover {
                book.coverFileName = safeCover
            }
        }
        book.sourceDevice = record["sourceDevice"] as? String ?? book.sourceDevice
        book.lastPositionDevice = record["lastPositionDevice"] as? String ?? book.lastPositionDevice
        book.lastPositionDate = record["lastPositionDate"] as? Date
        book.preferredVoiceID = (record["preferredVoiceID"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        book.readingModeRaw = record["readingMode"] as? String ?? book.readingModeRaw
        book.updatedAt = remoteDate

        let localExists = FileManager.default.fileExists(atPath: library.fileStore.documentURL(for: book).path)
        if !downloadingBookIDs.contains(book.id) {
            book.downloadState = localExists ? .downloaded : .cloudOnly
        }
        if !localExists || book.coverFileName == nil {
            documents.downloadCover(for: book)
        }
    }

    private func applyRemoteCollection(_ record: CKRecord) {
        guard let id = uuid(from: record.recordID), let remoteDate = record["updatedAt"] as? Date else { return }
        if let local = fetchCollection(id: id), local.updatedAt > remoteDate { return }
        let collection: LibraryCollection
        if let local = fetchCollection(id: id) {
            collection = local
        } else {
            collection = LibraryCollection(id: id, name: record["name"] as? String ?? "Collection")
            context.insert(collection)
        }
        collection.name = record["name"] as? String ?? collection.name
        if let parent = record["parentID"] as? String, !parent.isEmpty {
            collection.parentID = UUID(uuidString: parent)
        } else {
            collection.parentID = nil
        }
        collection.sortIndex = Int(integer(record, "sortIndex") ?? Int64(collection.sortIndex))
        collection.createdAt = record["createdAt"] as? Date ?? collection.createdAt
        collection.updatedAt = remoteDate
    }

    private func applyRemoteMembership(_ record: CKRecord) {
        guard let id = uuid(from: record.recordID),
              let bookIDString = record["bookID"] as? String,
              let collectionIDString = record["collectionID"] as? String,
              let bookID = UUID(uuidString: bookIDString),
              let collectionID = UUID(uuidString: collectionIDString),
              let book = fetchBook(id: bookID),
              let collection = fetchCollection(id: collectionID) else { return }
        let remoteDate = record["updatedAt"] as? Date ?? .distantPast
        if let local = fetchMembership(id: id), local.updatedAt > remoteDate { return }
        let membership: CollectionMembership
        if let existing = fetchMembership(id: id) {
            membership = existing
        } else {
            membership = CollectionMembership(id: id, book: book, collection: collection)
            context.insert(membership)
        }
        membership.book = book
        membership.collection = collection
        membership.sortIndex = Int(integer(record, "sortIndex") ?? Int64(membership.sortIndex))
        membership.addedAt = record["addedAt"] as? Date ?? membership.addedAt
        membership.updatedAt = remoteDate
    }

    private func applyRemoteBookmark(_ record: CKRecord) {
        guard let id = uuid(from: record.recordID),
              let bookIDString = record["bookID"] as? String,
              let bookID = UUID(uuidString: bookIDString),
              let book = fetchBook(id: bookID),
              let remoteDate = record["updatedAt"] as? Date else { return }
        if let local = fetchBookmark(id: id), local.updatedAt > remoteDate { return }
        let bookmark: Bookmark
        if let local = fetchBookmark(id: id) {
            bookmark = local
        } else {
            bookmark = Bookmark(id: id, book: book, title: record["title"] as? String ?? "Bookmark")
            context.insert(bookmark)
        }
        bookmark.book = book
        bookmark.title = record["title"] as? String ?? bookmark.title
        bookmark.chapterTitle = record["chapterTitle"] as? String ?? bookmark.chapterTitle
        bookmark.locatorJSON = record["locatorJSON"] as? String ?? bookmark.locatorJSON
        bookmark.createdAt = record["createdAt"] as? Date ?? bookmark.createdAt
        bookmark.updatedAt = remoteDate
    }

    private func applyRemoteAnnotation(_ record: CKRecord) {
        guard let id = uuid(from: record.recordID),
              let bookIDString = record["bookID"] as? String,
              let bookID = UUID(uuidString: bookIDString),
              let book = fetchBook(id: bookID),
              let remoteDate = record["updatedAt"] as? Date else { return }
        if let local = fetchAnnotation(id: id), local.updatedAt > remoteDate { return }
        let annotation: Annotation
        if let local = fetchAnnotation(id: id) {
            annotation = local
        } else {
            annotation = Annotation(
                id: id,
                book: book,
                chapterIndex: Int(integer(record, "chapterIndex") ?? 0),
                startOffset: Int(integer(record, "startOffset") ?? 0),
                endOffset: Int(integer(record, "endOffset") ?? 0),
                quote: record["quote"] as? String ?? ""
            )
            context.insert(annotation)
        }
        annotation.book = book
        annotation.chapterIndex = Int(integer(record, "chapterIndex") ?? Int64(annotation.chapterIndex))
        annotation.startOffset = Int(integer(record, "startOffset") ?? Int64(annotation.startOffset))
        annotation.endOffset = Int(integer(record, "endOffset") ?? Int64(annotation.endOffset))
        annotation.quote = record["quote"] as? String ?? annotation.quote
        annotation.note = record["note"] as? String ?? annotation.note
        annotation.colorRaw = record["color"] as? String ?? annotation.colorRaw
        annotation.createdAt = record["createdAt"] as? Date ?? annotation.createdAt
        annotation.updatedAt = remoteDate
    }

    private func applyRemoteTombstone(_ record: CKRecord) {
        guard let typeString = record["entityType"] as? String,
              let type = SyncEntityType(rawValue: typeString),
              let idString = record["entityID"] as? String,
              let id = UUID(uuidString: idString) else { return }
        if let deletedAt = record["deletedAt"] as? Date,
           let localDate = updatedAt(type: type, id: id),
           localDate > deletedAt {
            return
        }
        deleteLocal(type: type, id: id)
        removeOutbox(type: type, id: id)
        NotificationCenter.default.post(name: .nodusSyncOutboxChanged, object: nil)
    }

    private static func applyPriority(_ recordType: CKRecord.RecordType) -> Int {
        switch recordType {
        case "Book": 0
        case "Collection": 1
        case "Membership": 2
        case "Bookmark": 3
        case "Annotation": 4
        case "Tombstone": 5
        default: 6
        }
    }

    private func applyRemoteDeletion(_ recordID: CKRecord.ID, recordType: CKRecord.RecordType) {
        // The deletion of a tombstone record is not the deletion of the entity.
        guard recordType != "Tombstone",
              let type = entityType(forRecordName: recordID.recordName),
              let id = uuid(from: recordID) else { return }
        deleteLocal(type: type, id: id)
        removeOutbox(type: type, id: id)
    }

    // MARK: Local deletion

    private func deleteLocal(type: SyncEntityType, id: UUID) {
        switch type {
        case .book:
            if let book = fetchBook(id: id) {
                library.fileStore.removeBookFiles(book)
                context.delete(book)
                if let cache = library.narrationCache {
                    Task.detached { await cache.deleteBook(bookID: id) }
                }
                NotificationCenter.default.post(name: .nodusLibraryBooksDeleted,
                                                object: nil,
                                                userInfo: ["ids": [id]])
            }
        case .collection:
            if let collection = fetchCollection(id: id) {
                context.delete(collection)
            }
        case .membership:
            if let membership = fetchMembership(id: id) {
                context.delete(membership)
            }
        case .bookmark:
            if let bookmark = fetchBookmark(id: id) {
                context.delete(bookmark)
            }
        case .annotation:
            if let annotation = fetchAnnotation(id: id) {
                context.delete(annotation)
            }
        case .readingPosition, .theme, .preference:
            break
        }
    }

    private func removeOutbox(type: SyncEntityType, id: UUID) {
        let descriptor = FetchDescriptor<SyncOutboxEntry>()
        let entries = (try? context.fetch(descriptor)) ?? []
        for entry in entries where entry.entityType == type && entry.entityID == id {
            context.delete(entry)
        }
    }

    // MARK: Downloads

    private func reconcileDownloadStates() {
        var changed = false
        for book in library.allBooks()
            where book.downloadState == .downloading && !downloadingBookIDs.contains(book.id) {
            let url = library.fileStore.documentURL(for: book)
            let size = FileStore.fileSize(at: url)
            let exists = FileManager.default.fileExists(atPath: url.path)
            let complete = exists && (book.fileSize <= 0 || size == book.fileSize)
            book.downloadState = complete ? .downloaded : .cloudOnly
            changed = true
        }
        if changed { library.save() }
    }

    func download(_ book: Book) async {
        guard isEnabled, isAvailable, !downloadingBookIDs.contains(book.id) else { return }
        downloadingBookIDs.insert(book.id)
        downloadError = nil
        book.downloadState = .downloading
        library.save()
        do {
            try await documents.download(book)
            book.downloadState = .downloaded
            library.save()
        } catch {
            book.downloadState = .cloudOnly
            library.save()
            downloadError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        downloadingBookIDs.remove(book.id)
    }

    func downloadAllCloudOnlyBooks() async {
        let books = library.allBooks().filter { $0.downloadState == .cloudOnly }
        for book in books {
            await download(book)
        }
    }

    func removeLocalDownload(_ book: Book) async {
        guard isEnabled, isAvailable else { return }
        downloadError = nil
        guard await documents.hasRemoteCopy(for: book) else {
            downloadError = "This book has no iCloud copy yet."
            return
        }
        do {
            try documents.removeLocalDownload(for: book)
            book.downloadState = .cloudOnly
            library.save()
            downloadError = nil
        } catch {
            downloadError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    // MARK: Helpers

    private static func hasCloudKitContainerEntitlement() -> Bool {
        #if os(macOS)
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(
                task,
                "com.apple.developer.icloud-container-identifiers" as CFString,
                nil
              ) as? [String] else { return false }
        return value.contains(ICloudDocumentStore.containerIdentifier)
        #else
        return true
        #endif
    }

    private func status(for error: Error) -> Status {
        if error is URLError { return .offline }
        if let ck = error as? CKError {
            switch ck.code {
            case .networkUnavailable, .networkFailure:
                return .offline
            case .notAuthenticated:
                return .unavailable("Sign in to iCloud on this device to sync your library.")
            case .quotaExceeded:
                return .error("Your iCloud storage is full.")
            default:
                break
            }
        }
        return .error((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
    }

    private func recordID(type: SyncEntityType, id: UUID) -> CKRecord.ID {
        CKRecord.ID(recordName: "\(type.rawValue)-\(id.uuidString)", zoneID: zoneID)
    }

    private func tombstoneID(type: SyncEntityType, id: UUID) -> CKRecord.ID {
        CKRecord.ID(recordName: "tombstone-\(type.rawValue)-\(id.uuidString)", zoneID: zoneID)
    }

    private func uuid(from recordID: CKRecord.ID) -> UUID? {
        var name = recordID.recordName
        if name.hasPrefix("tombstone-") {
            name.removeFirst("tombstone-".count)
        }
        for type in SyncEntityType.allCases {
            let prefix = "\(type.rawValue)-"
            if name.hasPrefix(prefix) {
                return UUID(uuidString: String(name.dropFirst(prefix.count)))
            }
        }
        return nil
    }

    private func entityType(forRecordName recordName: String) -> SyncEntityType? {
        var name = recordName
        if name.hasPrefix("tombstone-") {
            name.removeFirst("tombstone-".count)
        }
        for type in SyncEntityType.allCases where name.hasPrefix("\(type.rawValue)-") {
            return type
        }
        return nil
    }

    private func updatedAt(type: SyncEntityType, id: UUID) -> Date? {
        switch type {
        case .book: fetchBook(id: id)?.updatedAt
        case .collection: fetchCollection(id: id)?.updatedAt
        case .membership: fetchMembership(id: id)?.updatedAt
        case .bookmark: fetchBookmark(id: id)?.updatedAt
        case .annotation: fetchAnnotation(id: id)?.updatedAt
        case .readingPosition, .theme, .preference: nil
        }
    }

    private func fetchBook(id: UUID) -> Book? {
        var descriptor = FetchDescriptor<Book>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    private func fetchCollection(id: UUID) -> LibraryCollection? {
        var descriptor = FetchDescriptor<LibraryCollection>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    private func fetchMembership(id: UUID) -> CollectionMembership? {
        var descriptor = FetchDescriptor<CollectionMembership>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    private func fetchBookmark(id: UUID) -> Bookmark? {
        var descriptor = FetchDescriptor<Bookmark>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    private func fetchTombstone(type: SyncEntityType, id: UUID) -> SyncTombstone? {
        let descriptor = FetchDescriptor<SyncTombstone>()
        return (try? context.fetch(descriptor))?.first {
            $0.entityType == type && $0.entityID == id
        }
    }

    private func fetchAnnotation(id: UUID) -> Annotation? {
        var descriptor = FetchDescriptor<Annotation>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    private func integer(_ record: CKRecord, _ key: String) -> Int64? {
        (record[key] as? NSNumber)?.int64Value
    }

    private func number(_ record: CKRecord, _ key: String) -> Double? {
        (record[key] as? NSNumber)?.doubleValue
    }

    private func loadChangeToken() -> CKServerChangeToken? {
        guard let data = defaults.data(forKey: Key.changeToken) else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: data)
    }

    private func saveChangeToken(_ token: CKServerChangeToken) {
        guard let data = try? NSKeyedArchiver.archivedData(withRootObject: token,
                                                            requiringSecureCoding: true) else { return }
        defaults.set(data, forKey: Key.changeToken)
    }

    private func clearChangeToken() {
        defaults.removeObject(forKey: Key.changeToken)
    }
}

enum SyncServiceError: LocalizedError {
    case cloudKitUnavailable

    var errorDescription: String? {
        switch self {
        case .cloudKitUnavailable:
            "CloudKit is unavailable in this build or on this device."
        }
    }
}
