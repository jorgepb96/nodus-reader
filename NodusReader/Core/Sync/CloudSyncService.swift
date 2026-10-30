// SPDX-License-Identifier: AGPL-3.0-only
import CloudKit
import DesignSystem
import Foundation
import Observation
import Network
#if os(iOS)
import UIKit
#endif
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
        case waiting
        case offline
        case error(String)

        var title: String {
            switch self {
            case .disabled: String(localized: "Sync is off")
            case .unavailable: String(localized: "iCloud unavailable")
            case .syncing: String(localized: "Syncing…")
            case .upToDate: String(localized: "Up to date")
            case .waiting: String(localized: "Waiting to sync")
            case .offline: String(localized: "Waiting for a connection")
            case .error: String(localized: "Sync error")
            }
        }

        var detail: String? {
            switch self {
            case .disabled: String(localized: "Your library stays on this device.")
            case .unavailable(let message): message
            case .syncing: String(localized: "Changes are moving through your personal iCloud.")
            case .upToDate: nil
            case .waiting: String(localized: "Changes are queued and will be retried automatically.")
            case .offline: String(localized: "Changes are queued and will be sent when you are back online.")
            case .error(let message): message
            }
        }
    }

    private enum Key {
        static let enabled = "nodus.sync.enabled"
        static let lastSync = "nodus.sync.last"
        static let changeToken = "nodus.sync.changeToken"
        static let initialPush = "nodus.sync.initialPush"
        static let prefsObserved = "nodus.sync.prefs.observed"
        static let prefsSynced = "nodus.sync.prefs.synced"
        static let prefsUpdatedAt = "nodus.sync.prefs.updatedAt"
        static let deferredChildren = "nodus.sync.deferredChildren"
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

    @ObservationIgnored private lazy var coordinator = SyncCoordinator { [weak self] in
        await self?.performSync()
    }
    @ObservationIgnored private var networkMonitor: NWPathMonitor?
    nonisolated(unsafe) private var accountObserver: NSObjectProtocol?
    private var consecutiveFailures = 0
    private var sceneIsActive = true
    #if os(iOS)
    private var backgroundSyncTask: UIBackgroundTaskIdentifier = .invalid
    #endif
    nonisolated(unsafe) private var outboxObserver: NSObjectProtocol?
    private var zoneReady = false
    private var started = false
    private var activeSyncGeneration = UUID()
    @ObservationIgnored private var pendingCoverDownloads: Set<UUID> = []
    @ObservationIgnored private var preferenceSources: (theme: ThemeManager, reading: ReaderPreferences)?
    nonisolated(unsafe) private var preferencesObserver: NSObjectProtocol?

    init(context: ModelContext, library: LibraryService, journal: SyncJournal,
         fileStore: FileStore = .shared, defaults: UserDefaults = .standard) {
        self.context = context
        self.library = library
        self.journal = journal
        self.documents = ICloudDocumentStore(fileStore: fileStore)
        self.defaults = defaults
        self.isEnabled = !LibraryStorageScope.isIsolated && defaults.bool(forKey: Key.enabled)
        self.lastSync = defaults.object(forKey: Key.lastSync) as? Date
        self.zoneID = CKRecordZone.ID(zoneName: Self.zoneName, ownerName: CKCurrentUserDefaultName)
        self.pendingCount = journal.pendingCount()

        outboxObserver = NotificationCenter.default.addObserver(
            forName: .nodusSyncOutboxChanged,
            object: journal,
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
        if let preferencesObserver { NotificationCenter.default.removeObserver(preferencesObserver) }
        if let accountObserver { NotificationCenter.default.removeObserver(accountObserver) }
        networkMonitor?.cancel()
    }

    // MARK: Preferences

    /// Themes and reading preferences live in `UserDefaults`, not SwiftData, so
    /// they are synced as one `Preference` record. Local edits are detected by
    /// comparing snapshots whenever defaults change.
    func attachPreferences(theme: ThemeManager, reading: ReaderPreferences) {
        preferenceSources = (theme, reading)
        if defaults.data(forKey: Key.prefsObserved) == nil {
            // A fresh install must not overwrite the user's synced choices with
            // this device's defaults: its snapshot starts older than anything.
            defaults.set(SyncedPreferences(theme: theme, reading: reading).encoded, forKey: Key.prefsObserved)
            defaults.set(Date.distantPast, forKey: Key.prefsUpdatedAt)
        }
        preferencesObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.noteLocalPreferenceChange() }
        }
    }

    private func noteLocalPreferenceChange() {
        guard let sources = preferenceSources else { return }
        let snapshot = SyncedPreferences(theme: sources.theme, reading: sources.reading).encoded
        guard snapshot != defaults.data(forKey: Key.prefsObserved) else { return }
        defaults.set(snapshot, forKey: Key.prefsObserved)
        defaults.set(Date(), forKey: Key.prefsUpdatedAt)
        scheduleSync()
    }

    private var preferencesRecordID: CKRecord.ID {
        CKRecord.ID(recordName: "preference-settings", zoneID: zoneID)
    }

    private func pushPreferencesIfNeeded(generation: UUID) async throws {
        guard let sources = preferenceSources, database != nil else { return }
        let current = SyncedPreferences(theme: sources.theme, reading: sources.reading).encoded
        guard current != defaults.data(forKey: Key.prefsSynced) else { return }
        let localDate = defaults.object(forKey: Key.prefsUpdatedAt) as? Date ?? .distantPast
        let remote = try await remoteRecord(preferencesRecordID)
        try checkSession(generation)
        guard current == SyncedPreferences(theme: sources.theme, reading: sources.reading).encoded else {
            scheduleSync()
            return
        }
        if let remote, let remoteDate = remote["updatedAt"] as? Date, remoteDate > localDate {
            applyRemotePreferences(remote)
            return
        }
        let record = CKRecord(recordType: "Preference", recordID: preferencesRecordID)
        record["payload"] = String(data: current, encoding: .utf8)
        record["updatedAt"] = localDate == .distantPast ? Date() : localDate
        try await saveRecord(record, replacing: remote)
        try checkSession(generation)
        defaults.set(current, forKey: Key.prefsSynced)
    }

    private func applyRemotePreferences(_ record: CKRecord) {
        guard let sources = preferenceSources,
              let remoteDate = record["updatedAt"] as? Date,
              let payload = (record["payload"] as? String)?.data(using: .utf8),
              let remote = SyncedPreferences.decode(payload) else { return }
        let localDate = defaults.object(forKey: Key.prefsUpdatedAt) as? Date ?? .distantPast
        guard remoteDate > localDate else { return }
        // Record the incoming snapshot first so the defaults writes below are
        // not mistaken for a local edit and pushed straight back.
        defaults.set(remote.encoded, forKey: Key.prefsObserved)
        defaults.set(remote.encoded, forKey: Key.prefsSynced)
        defaults.set(remoteDate, forKey: Key.prefsUpdatedAt)
        remote.apply(theme: sources.theme, reading: sources.reading)
        let applied = SyncedPreferences(theme: sources.theme, reading: sources.reading).encoded
        defaults.set(applied, forKey: Key.prefsObserved)
        defaults.set(applied, forKey: Key.prefsSynced)
    }

    var lastSyncText: String {
        guard let lastSync else { return String(localized: "Not yet synced") }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return "Last successful sync: \(formatter.localizedString(for: lastSync, relativeTo: Date()))"
    }

    // MARK: Lifecycle

    func start() async {
        guard !LibraryStorageScope.isIsolated else { return }
        guard !started else {
            if isEnabled { await syncNow() }
            return
        }
        started = true
        observeRecoveryEvents()
        await refreshAvailability()
        if isEnabled, isAvailable {
            if !defaults.bool(forKey: Key.initialPush) {
                journal.enqueueAll()
                defaults.set(true, forKey: Key.initialPush)
            }
            await syncNow()
        } else if isEnabled {
            scheduleSync(after: 60)
        }
    }

    private func observeRecoveryEvents() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor [weak self] in self?.scheduleSync(after: 0) }
        }
        monitor.start(queue: DispatchQueue(label: "ai.nodus.reader.sync.network"))
        networkMonitor = monitor
        accountObserver = NotificationCenter.default.addObserver(
            forName: .CKAccountChanged, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.activeSyncGeneration = UUID()
                self.zoneReady = false
                self.clearChangeToken()
                self.scheduleSync(after: 0)
            }
        }
    }

    func setSceneActive(_ active: Bool) {
        sceneIsActive = active
        if active { scheduleSync(after: 0) }
        else { coordinator.stop() }
    }

    /// Give the last saved reading/audio cursor a chance to leave the device
    /// before iOS suspends it. Unsent work remains in SwiftData on expiration.
    func syncBeforeSuspending() async {
        guard isEnabled else { return }
        #if os(iOS)
        if backgroundSyncTask == .invalid {
            backgroundSyncTask = UIApplication.shared.beginBackgroundTask(withName: "Library sync") { [weak self] in
                Task { @MainActor [weak self] in self?.endBackgroundSync() }
            }
        }
        #endif
        await syncNow()
    }

    private func endBackgroundSync() {
        #if os(iOS)
        if backgroundSyncTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundSyncTask)
            backgroundSyncTask = .invalid
        }
        #endif
    }

    func refreshAvailability() async {
        guard !LibraryStorageScope.isIsolated else { return }
        pendingCount = journal.pendingCount()
        reconcileDownloadStates()
        fileSyncAvailable = await documents.refreshAvailability()
        guard FileManager.default.ubiquityIdentityToken != nil,
              Self.hasCloudKitContainerEntitlement() else {
            isAvailable = false
            availabilityMessage = String(localized: "Sign in to iCloud and enable iCloud Drive for Nodus Reader to sync your library.")
            if !isEnabled { status = .disabled } else { status = .unavailable(availabilityMessage) }
            return
        }
        if container == nil {
            container = CKContainer(identifier: ICloudDocumentStore.containerIdentifier)
        }
        guard let container else {
            isAvailable = false
            availabilityMessage = String(localized: "This build is not signed for the Nodus Reader iCloud container.")
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
                availabilityMessage = String(localized: "Sign in to iCloud on this device to sync your library.")
            case .restricted:
                isAvailable = false
                availabilityMessage = "iCloud is restricted on this device."
            case .couldNotDetermine:
                isAvailable = false
                availabilityMessage = String(localized: "Nodus Reader could not determine the state of your iCloud account.")
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
            availabilityMessage = String(localized: "This build is not signed for the Nodus Reader iCloud container. Configure the CloudKit container and entitlements before using sync.")
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
        guard !LibraryStorageScope.isIsolated else { return }
        guard enabled != isEnabled else { return }
        defaults.set(enabled, forKey: Key.enabled)
        isEnabled = enabled
        activeSyncGeneration = UUID()
        coordinator.stop()
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
            scheduleSync(after: 60)
            return
        }
        status = .syncing
        journal.enqueueAll()
        defaults.set(true, forKey: Key.initialPush)
        await syncNow()
    }

    // MARK: Sync

    func syncNow() async {
        guard isEnabled else { return }
        await coordinator.runNow()
    }

    /// Returns the next deadline to the serial coordinator. Outbox retry dates
    /// survive launches; the foreground fallback also discovers remote-only edits.
    private func performSync() async -> Date? {
        guard isEnabled else { return nil }
        let generation = activeSyncGeneration
        isSyncing = true
        status = .syncing
        defer {
            isSyncing = false
            endBackgroundSync()
        }
        var syncError: Error?
        do {
            await refreshAvailability()
            try checkSession(generation)
            guard isAvailable else { return sceneIsActive ? Date().addingTimeInterval(60) : nil }
            try await ensureZone()
            try checkSession(generation)
            if !defaults.bool(forKey: Key.initialPush) {
                journal.enqueueAll()
                defaults.set(true, forKey: Key.initialPush)
            }
            do { try await pushOutbox(generation: generation) }
            catch { syncError = error }
            try checkSession(generation)
            do { try await pushPreferencesIfNeeded(generation: generation) }
            catch { syncError = syncError ?? error }
            try checkSession(generation)
            try await pullChanges(generation: generation)
            try checkSession(generation)
        } catch {
            guard isEnabled, generation == activeSyncGeneration else { return nil }
            syncError = error
        }
        pendingCount = journal.pendingCount()
        var next = sceneIsActive ? Date().addingTimeInterval(60) : nil
        if let syncError {
            consecutiveFailures += 1
            let delay = max(min(300, pow(2, Double(min(consecutiveFailures, 6))) * 5),
                            (syncError as? CKError)?.retryAfterSeconds ?? 0)
            next = Date().addingTimeInterval(delay)
            status = status(for: syncError)
        } else {
            consecutiveFailures = 0
            // Backing-off entries are not a completed synchronization.
            if pendingCount == 0 {
                lastSync = Date()
                defaults.set(lastSync, forKey: Key.lastSync)
                status = .upToDate
            } else {
                status = .waiting
            }
        }
        if let queued = try? journal.nextAttemptAt() {
            let deadline = max(queued, Date().addingTimeInterval(1))
            next = min(next ?? deadline, deadline)
        }
        return next
    }

    private func checkSession(_ generation: UUID) throws {
        guard isEnabled, generation == activeSyncGeneration else { throw CancellationError() }
        try Task.checkCancellation()
    }

    private func scheduleSync(after delay: TimeInterval = 1) {
        guard isEnabled else { return }
        coordinator.request(at: Date().addingTimeInterval(delay))
    }

    private func ensureZone() async throws {
        guard !zoneReady else { return }
        guard let database else { throw SyncServiceError.cloudKitUnavailable }
        _ = try await database.save(CKRecordZone(zoneID: zoneID))
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

    private func pushOutbox(generation: UUID) async throws {
        let descriptor = FetchDescriptor<SyncOutboxEntry>(sortBy: [SortDescriptor(\SyncOutboxEntry.createdAt)])
        let entries = try context.fetch(descriptor)
        let ordered = entries.sorted {
            let lhs = Self.pushPriority($0.entityType)
            let rhs = Self.pushPriority($1.entityType)
            return lhs == rhs ? $0.createdAt < $1.createdAt : lhs < rhs
        }
        var firstError: Error?
        for entry in ordered {
            try checkSession(generation)
            guard entry.modelContext != nil, entry.nextAttemptAt <= Date() else { continue }
            let enqueuedAt = entry.createdAt
            let operation = entry.operation
            do {
                switch operation {
                case .delete:
                    try await pushDeletion(entry, generation: generation)
                case .upsert:
                    try await pushUpsert(entry, generation: generation)
                }
                try checkSession(generation)
                journal.completePush(entry, enqueuedAt: enqueuedAt, operation: operation)
                try context.save()
            } catch {
                try checkSession(generation)
                journal.failPush(entry, enqueuedAt: enqueuedAt, operation: operation,
                                 error: error, retryAfter: (error as? CKError)?.retryAfterSeconds)
                try? context.save()
                if firstError == nil { firstError = error }
            }
        }
        pendingCount = journal.pendingCount()
        if let firstError { throw firstError }
    }

    /// Only absence is optional. Network/authentication errors must retain the
    /// queue entry instead of being treated as permission to overwrite iCloud.
    private func remoteRecord(_ id: CKRecord.ID) async throws -> CKRecord? {
        guard let database else { throw SyncServiceError.cloudKitUnavailable }
        do { return try await database.record(for: id) }
        catch let error as CKError where error.code == .unknownItem { return nil }
    }

    private func saveRecord(_ record: CKRecord, replacing remote: CKRecord?) async throws {
        guard let database else { throw SyncServiceError.cloudKitUnavailable }
        let target = remote ?? record
        if let remote {
            for key in record.allKeys() { remote[key] = record[key] }
        }
        let result = try await database.modifyRecords(saving: [target], deleting: [],
                                                       savePolicy: .ifServerRecordUnchanged,
                                                       atomically: true)
        try Self.requireSavedRecord(target.recordID, results: result.saveResults)
    }

    static func requireSavedRecord(_ id: CKRecord.ID,
                                   results: [CKRecord.ID: Result<CKRecord, Error>]) throws {
        guard let result = results[id] else { throw SyncServiceError.missingRecordResult }
        _ = try result.get()
    }

    static func requireDeletedRecord(_ id: CKRecord.ID,
                                     results: [CKRecord.ID: Result<Void, Error>]) throws {
        guard let result = results[id] else { throw SyncServiceError.missingRecordResult }
        do { try result.get() }
        catch let error as CKError where error.code == .unknownItem { /* idempotent delete */ }
    }

    private func pushUpsert(_ entry: SyncOutboxEntry, generation: UUID) async throws {
        let enqueuedAt = entry.createdAt
        let type = entry.entityType
        let id = entry.entityID
        guard let localDate = updatedAt(type: type, id: id),
              let record = buildRecord(for: entry) else { return }

        let tombstone = try await remoteRecord(tombstoneID(type: type, id: id))
        try checkSession(generation)
        guard journal.isCurrent(entry, enqueuedAt: enqueuedAt, operation: .upsert) else { return }
        if let tombstone, let deletedAt = tombstone["deletedAt"] as? Date, deletedAt >= localDate {
            try journal.withSuspendedRecording {
                applyRemoteTombstone(tombstone)
                try context.save()
            }
            return
        }

        let remote = try await remoteRecord(record.recordID)
        try checkSession(generation)
        guard journal.isCurrent(entry, enqueuedAt: enqueuedAt, operation: .upsert) else { return }
        if let remote, let remoteDate = remote["updatedAt"] as? Date, remoteDate > localDate {
            try journal.withSuspendedRecording {
                applyRemote(remote)
                try context.save()
            }
            return
        }

        if type == .book, let book = fetchBook(id: id) {
            let file = RemoteBookFile(book)
            // File failures are retryable, just like metadata failures. Stage
            // originals before publishing a book another device can discover.
            try await documents.upload(file)
            try checkSession(generation)
            guard journal.isCurrent(entry, enqueuedAt: enqueuedAt, operation: .upsert) else { return }
        }
        try await saveRecord(record, replacing: remote)
    }

    private func pushDeletion(_ entry: SyncOutboxEntry, generation: UUID) async throws {
        guard let database else { throw SyncServiceError.cloudKitUnavailable }
        let enqueuedAt = entry.createdAt
        let type = entry.entityType
        let id = entry.entityID
        let localTombstone = fetchTombstone(type: type, id: id)
        let deletedAt = localTombstone?.deletedAt ?? enqueuedAt
        let remote = try await remoteRecord(recordID(type: type, id: id))
        try checkSession(generation)
        guard journal.isCurrent(entry, enqueuedAt: enqueuedAt, operation: .delete) else { return }
        if let remote, let remoteDate = remote["updatedAt"] as? Date, remoteDate > deletedAt {
            try journal.withSuspendedRecording {
                applyRemote(remote)
                try context.save()
            }
            return
        }
        let tombstoneRecordID = tombstoneID(type: type, id: id)
        let tombstone = try await remoteRecord(tombstoneRecordID)
            ?? CKRecord(recordType: "Tombstone", recordID: tombstoneRecordID)
        try checkSession(generation)
        guard journal.isCurrent(entry, enqueuedAt: enqueuedAt, operation: .delete) else { return }
        tombstone["entityType"] = type.rawValue
        tombstone["entityID"] = id.uuidString
        tombstone["deletedAt"] = max(deletedAt, tombstone["deletedAt"] as? Date ?? .distantPast)
        let dataRecordID = recordID(type: type, id: id)
        let result = try await database.modifyRecords(saving: [tombstone],
                                                       deleting: remote == nil ? [] : [dataRecordID],
                                                       savePolicy: .ifServerRecordUnchanged,
                                                       atomically: false)
        try Self.requireSavedRecord(tombstoneRecordID, results: result.saveResults)
        if remote != nil {
            try Self.requireDeletedRecord(dataRecordID, results: result.deleteResults)
        }
        try checkSession(generation)
        guard journal.isCurrent(entry, enqueuedAt: enqueuedAt, operation: .delete) else { return }
        if type == .book {
            // Remove the whole UUID directory, including hidden iCloud placeholders.
            try await documents.deleteRemoteFiles(bookID: id)
            try checkSession(generation)
        }
        if journal.isCurrent(entry, enqueuedAt: enqueuedAt, operation: .delete) {
            localTombstone?.isPushed = true
        }
    }

    // MARK: Pull

    private func pullChanges(generation: UUID) async throws {
        guard let database else { throw SyncServiceError.cloudKitUnavailable }
        var token = loadChangeToken()
        var moreComing = true
        var retriedZone = false
        while moreComing {
            try checkSession(generation)
            do {
                let changes = try await database.recordZoneChanges(inZoneWith: zoneID, since: token)
                try checkSession(generation)
                // A per-record failure must not be skipped when advancing the token.
                for result in changes.modificationResultsByID.values { _ = try result.get() }
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
                    // Physical deletions carry no timestamp; Tombstone
                    // records are authoritative, including across pull pages.
                    retryDeferredChildren()
                    try context.save()
                }
                token = changes.changeToken
                persistDeferredChildren()
                saveChangeToken(changes.changeToken)
                moreComing = changes.moreComing
                await downloadPendingCovers()
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
                journal.enqueueAll()
                defaults.removeObject(forKey: Key.prefsSynced)
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
            record["appearanceJSON"] = book.appearanceJSON
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

    func applyRemote(_ record: CKRecord) {
        switch record.recordType {
        case "Book": applyRemoteBook(record)
        case "Collection": applyRemoteCollection(record)
        case "Membership": if !applyRemoteMembership(record) { deferChild(record) }
        case "Bookmark": if !applyRemoteBookmark(record) { deferChild(record) }
        case "Annotation": if !applyRemoteAnnotation(record) { deferChild(record) }
        case "Tombstone": applyRemoteTombstone(record)
        case "Preference": applyRemotePreferences(record)
        default: break
        }
    }

    private func applyRemoteBook(_ record: CKRecord) {
        guard let id = uuid(from: record.recordID), let remoteDate = record["updatedAt"] as? Date else { return }
        if remoteIsSupersededByLocalDeletion(.book, id: id, remoteDate: remoteDate) { return }
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
        if let coverName = record["coverFileName"] as? String, coverName.isEmpty,
           let localCover = book.coverFileName {
            // The cover was cleared on another device: fall back to the
            // typographic cover here as well.
            if let url = library.fileStore.coverURL(for: localCover) {
                try? FileManager.default.removeItem(at: url)
            }
            book.coverFileName = nil
        } else if let coverName = record["coverFileName"] as? String, !coverName.isEmpty {
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
        book.appearanceJSON = record["appearanceJSON"] as? String ?? book.appearanceJSON
        book.updatedAt = remoteDate

        let localExists = FileManager.default.fileExists(atPath: library.fileStore.documentURL(for: book).path)
        if !downloadingBookIDs.contains(book.id) {
            book.downloadState = localExists ? .downloaded : .cloudOnly
        }
        let remoteHasCover = !((record["coverFileName"] as? String) ?? "").isEmpty
        if remoteHasCover, !localExists || book.coverFileName == nil {
            pendingCoverDownloads.insert(book.id)
        }
    }

    /// Covers are copied from iCloud Drive after a pull page is applied, off
    /// the main thread, then attached without re-enqueueing the book.
    private func downloadPendingCovers() async {
        let ids = pendingCoverDownloads
        pendingCoverDownloads.removeAll()
        for id in ids {
            guard let name = await documents.downloadCover(bookID: id),
                  let book = fetchBook(id: id) else { continue }
            journal.withSuspendedRecording {
                book.coverFileName = name
                try? context.save()
            }
        }
    }

    private func applyRemoteCollection(_ record: CKRecord) {
        guard let id = uuid(from: record.recordID), let remoteDate = record["updatedAt"] as? Date else { return }
        if remoteIsSupersededByLocalDeletion(.collection, id: id, remoteDate: remoteDate) { return }
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

    /// Returns false when a parent has not arrived yet, so the record is kept
    /// and retried after later pages instead of being lost.
    private func applyRemoteMembership(_ record: CKRecord) -> Bool {
        guard let id = uuid(from: record.recordID),
              let bookIDString = record["bookID"] as? String,
              let collectionIDString = record["collectionID"] as? String,
              let bookID = UUID(uuidString: bookIDString),
              let collectionID = UUID(uuidString: collectionIDString) else { return true }
        if fetchTombstone(type: .book, id: bookID) != nil
            || fetchTombstone(type: .collection, id: collectionID) != nil { return true }
        guard let book = fetchBook(id: bookID),
              let collection = fetchCollection(id: collectionID) else { return false }
        let remoteDate = record["updatedAt"] as? Date ?? .distantPast
        if remoteIsSupersededByLocalDeletion(.membership, id: id, remoteDate: remoteDate) { return true }
        if let local = fetchMembership(id: id), local.updatedAt > remoteDate { return true }
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
        return true
    }

    private func applyRemoteBookmark(_ record: CKRecord) -> Bool {
        guard let id = uuid(from: record.recordID),
              let bookIDString = record["bookID"] as? String,
              let bookID = UUID(uuidString: bookIDString),
              let remoteDate = record["updatedAt"] as? Date else { return true }
        if fetchTombstone(type: .book, id: bookID) != nil { return true }
        guard let book = fetchBook(id: bookID) else { return false }
        if remoteIsSupersededByLocalDeletion(.bookmark, id: id, remoteDate: remoteDate) { return true }
        if let local = fetchBookmark(id: id), local.updatedAt > remoteDate { return true }
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
        return true
    }

    private func applyRemoteAnnotation(_ record: CKRecord) -> Bool {
        guard let id = uuid(from: record.recordID),
              let bookIDString = record["bookID"] as? String,
              let bookID = UUID(uuidString: bookIDString),
              let remoteDate = record["updatedAt"] as? Date else { return true }
        if fetchTombstone(type: .book, id: bookID) != nil { return true }
        guard let book = fetchBook(id: bookID) else { return false }
        if remoteIsSupersededByLocalDeletion(.annotation, id: id, remoteDate: remoteDate) { return true }
        if let local = fetchAnnotation(id: id), local.updatedAt > remoteDate { return true }
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
        return true
    }

    // MARK: Deferred children

    /// Children whose book or collection is in a later pull page (or whose
    /// parent push failed on the other device). Persisted, because the change
    /// token has already moved past them.
    @ObservationIgnored private lazy var deferredChildren: [CKRecord] = {
        guard let data = defaults.data(forKey: Key.deferredChildren) else { return [] }
        return (try? NSKeyedUnarchiver.unarchivedArrayOfObjects(ofClass: CKRecord.self, from: data)) ?? []
    }()

    private func deferChild(_ record: CKRecord) {
        deferredChildren.removeAll { $0.recordID == record.recordID }
        deferredChildren.append(record)
    }

    private func retryDeferredChildren() {
        guard !deferredChildren.isEmpty else { return }
        let pending = deferredChildren
        deferredChildren = []
        for record in pending { applyRemote(record) }
    }

    private func persistDeferredChildren() {
        if deferredChildren.isEmpty {
            defaults.removeObject(forKey: Key.deferredChildren)
        } else if let data = try? NSKeyedArchiver.archivedData(withRootObject: deferredChildren,
                                                               requiringSecureCoding: true) {
            defaults.set(data, forKey: Key.deferredChildren)
        }
    }

    /// A local tombstone that is newer than the incoming record must win even
    /// while its delete is still queued or backing off; otherwise a pull can
    /// resurrect an item the user deleted offline. If the remote record is
    /// newer than the deletion, the remote edit wins and the stale local delete
    /// is discarded.
    private func remoteIsSupersededByLocalDeletion(_ type: SyncEntityType, id: UUID,
                                                    remoteDate: Date) -> Bool {
        guard let tombstone = fetchTombstone(type: type, id: id) else { return false }
        if tombstone.deletedAt >= remoteDate { return true }
        context.delete(tombstone)
        removeOutbox(type: type, id: id)
        return false
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
        let deletedAt = record["deletedAt"] as? Date ?? .distantPast
        if let existing = fetchTombstone(type: type, id: id) {
            // Receiving our own tombstone is not an acknowledgement of file
            // cleanup. Keep a failed/pending local delete in the outbox.
            if !existing.isPushed {
                existing.deletedAt = max(existing.deletedAt, deletedAt)
                deleteLocal(type: type, id: id)
                return
            }
            guard existing.deletedAt <= deletedAt else { return }
            existing.deletedAt = deletedAt
            existing.isPushed = true
        } else {
            let marker = SyncTombstone(entityType: type, entityID: id)
            marker.deletedAt = deletedAt
            marker.isPushed = true
            context.insert(marker)
        }
        deleteLocal(type: type, id: id)
        removeOutbox(type: type, id: id)
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
        let raw = type.rawValue
        let descriptor = FetchDescriptor<SyncOutboxEntry>(
            predicate: #Predicate { $0.entityID == id && $0.entityTypeRaw == raw }
        )
        for entry in (try? context.fetch(descriptor)) ?? [] {
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
        let bookID = book.id
        downloadingBookIDs.insert(bookID)
        defer { downloadingBookIDs.remove(bookID) }
        downloadError = nil
        book.downloadState = .downloading
        library.save()
        do {
            let coverName = try await documents.download(RemoteBookFile(book))
            // A remote tombstone or a local delete can land during the wait.
            // Do not resurrect files for a book that no longer exists.
            guard fetchBook(id: bookID) != nil else {
                try? FileManager.default.removeItem(
                    at: library.fileStore.libraryDirectory.appendingPathComponent(bookID.uuidString, isDirectory: true))
                return
            }
            if let coverName { book.coverFileName = coverName }
            book.downloadState = .downloaded
            library.save()
            await library.refreshExtractedTextIfNeeded(book)
        } catch {
            guard fetchBook(id: bookID) != nil else { return }
            book.downloadState = .cloudOnly
            library.save()
            downloadError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
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
        let file = RemoteBookFile(book)
        guard await documents.hasRemoteCopy(for: file) else {
            downloadError = String(localized: "This book has no iCloud copy yet.")
            return
        }
        do {
            try await documents.removeLocalDownload(for: file)
            guard fetchBook(id: file.id) != nil else { return }
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
                return .unavailable(String(localized: "Sign in to iCloud on this device to sync your library."))
            case .quotaExceeded:
                return .error(String(localized: "Your iCloud storage is full."))
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
        let raw = type.rawValue
        var descriptor = FetchDescriptor<SyncTombstone>(
            predicate: #Predicate { $0.entityID == id && $0.entityTypeRaw == raw }
        )
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
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
    case missingRecordResult

    var errorDescription: String? {
        switch self {
        case .cloudKitUnavailable:
            String(localized: "CloudKit is unavailable in this build or on this device.")
        case .missingRecordResult:
            String(localized: "iCloud did not confirm the change. It will be retried.")
        }
    }
}
