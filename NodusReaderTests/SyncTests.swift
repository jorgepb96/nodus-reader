// SPDX-License-Identifier: AGPL-3.0-only
import CloudKit
import Foundation
import SwiftData
import Testing
@testable import Nodus_Reader

@Test @MainActor
func syncEventsDuringUploadRunAgainWithoutOverlapOrCancellation() async {
    var calls = 0
    var release: CheckedContinuation<Void, Never>?
    var wasCancelled = false
    let coordinator = SyncCoordinator {
        calls += 1
        if calls == 1 {
            await withCheckedContinuation { release = $0 }
            wasCancelled = Task.isCancelled
        }
        return nil
    }
    let first = Task { await coordinator.runNow() }
    while release == nil { await Task.yield() }
    for _ in 0..<20 { coordinator.request(at: Date().addingTimeInterval(60)) }
    await coordinator.runNow()
    #expect(calls == 1)
    #expect(coordinator.isRunning)
    release?.resume()
    await first.value
    #expect(!wasCancelled)
    // The overlapping immediate request runs automatically after completion.
    while calls < 2 { await Task.yield() }
    coordinator.stop()
    #expect(calls == 2)
}

@Test @MainActor
func syncEventBurstsCannotPostponeTheFirstDeadline() {
    let coordinator = SyncCoordinator { nil }
    let first = Date().addingTimeInterval(60)
    coordinator.request(at: first)
    for second in 61...100 { coordinator.request(at: first.addingTimeInterval(Double(second))) }
    #expect(coordinator.scheduledAt == first)
    let urgent = first.addingTimeInterval(-10)
    coordinator.request(at: urgent)
    #expect(coordinator.scheduledAt == urgent)
    coordinator.stop()
    #expect(coordinator.scheduledAt == nil)
}

@Test @MainActor
func failedSyncSchedulesARetryWithoutAnotherUserEvent() async {
    let retry = Date().addingTimeInterval(60)
    let coordinator = SyncCoordinator { retry }
    await coordinator.runNow()
    #expect(coordinator.scheduledAt == retry)
    coordinator.stop()
}

@Test @MainActor
func disablingSyncDiscardsFollowupsFromAnInFlightPass() async {
    var release: CheckedContinuation<Void, Never>?
    let coordinator = SyncCoordinator {
        await withCheckedContinuation { release = $0 }
        return Date().addingTimeInterval(60)
    }
    let first = Task { await coordinator.runNow() }
    while release == nil { await Task.yield() }
    coordinator.request()
    coordinator.stop()
    release?.resume()
    await first.value
    #expect(coordinator.scheduledAt == nil)
    #expect(!coordinator.isRunning)
}

@Test @MainActor
func syncReenableWhileAnOldPassFinishesKeepsItsRequest() async {
    var release: CheckedContinuation<Void, Never>?
    let coordinator = SyncCoordinator {
        await withCheckedContinuation { release = $0 }
        return nil
    }
    let first = Task { await coordinator.runNow() }
    while release == nil { await Task.yield() }
    coordinator.stop()
    let reenabled = Date().addingTimeInterval(30)
    coordinator.request(at: reenabled)
    release?.resume()
    await first.value
    #expect(coordinator.scheduledAt == reenabled)
    coordinator.stop()
}

@Test @MainActor
func cloudKitPerRecordFailuresAreNotAcknowledged() throws {
    let record = CKRecord(recordType: "Book", recordID: CKRecord.ID(recordName: "test"))
    #expect(throws: (any Error).self) {
        try CloudSyncService.requireSavedRecord(record.recordID,
            results: [record.recordID: .failure(CKError(.quotaExceeded))])
    }
    #expect(throws: (any Error).self) {
        try CloudSyncService.requireSavedRecord(record.recordID, results: [:])
    }
    try CloudSyncService.requireSavedRecord(record.recordID, results: [record.recordID: .success(record)])
    #expect(throws: (any Error).self) {
        try CloudSyncService.requireDeletedRecord(record.recordID,
            results: [record.recordID: .failure(CKError(.networkFailure))])
    }
    #expect(throws: (any Error).self) {
        try CloudSyncService.requireDeletedRecord(record.recordID, results: [:])
    }
    try CloudSyncService.requireDeletedRecord(record.recordID, results: [record.recordID: .success(())])
    try CloudSyncService.requireDeletedRecord(record.recordID,
        results: [record.recordID: .failure(CKError(.unknownItem))])
}

@MainActor
private struct SyncFixture {
    let container: ModelContainer
    let library: LibraryService
    let journal: SyncJournal
    let service: CloudSyncService
    let root: URL
    let defaults: UserDefaults
    let suite: String

    init() throws {
        container = try Persistence.makeContainer(inMemory: true)
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        library = LibraryService(context: container.mainContext, fileStore: FileStore(root: root))
        journal = SyncJournal(context: container.mainContext)
        library.syncJournal = journal
        suite = "nodus.tests.sync.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        service = CloudSyncService(context: container.mainContext, library: library,
                                   journal: journal, fileStore: library.fileStore, defaults: defaults,
                                   documentStore: ICloudDocumentStore(fileStore: library.fileStore,
                                       containerURL: root.appendingPathComponent("cloud")))
    }

    func book() throws -> Book {
        let book = Book(title: "Queued", author: "Test", format: .txt,
                        fileName: "book.txt", relativePath: "Library/book.txt", fileSize: 4,
                        contentHash: UUID().uuidString)
        container.mainContext.insert(book)
        try container.mainContext.save()
        return book
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
        defaults.removePersistentDomain(forName: suite)
    }

    func tombstone(_ type: SyncEntityType, id: UUID, at date: Date) -> CKRecord {
        let record = CKRecord(recordType: "Tombstone")
        record["entityType"] = type.rawValue
        record["entityID"] = id.uuidString
        record["deletedAt"] = date
        return record
    }
}

@Test @MainActor
func remoteBookMetadataPreservesTheLocalCoverUntilItsReplacementArrives() throws {
    let fixture = try SyncFixture()
    defer { fixture.cleanUp() }
    let book = try fixture.book()
    let local = fixture.library.fileStore.documentURL(for: book)
    try FileManager.default.createDirectory(at: local.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("book".utf8).write(to: local)
    let name = try fixture.library.fileStore.writeCover(Data("original artwork".utf8), bookID: book.id)
    book.coverFileName = name
    let record = CKRecord(recordType: "Book", recordID: CKRecord.ID(recordName: "book-\(book.id.uuidString)"))
    record["updatedAt"] = book.updatedAt.addingTimeInterval(1)
    record["coverFileName"] = "cover-on-another-device.jpg"

    fixture.service.applyRemote(record)

    #expect(book.downloadState == .downloaded)
    #expect(book.coverFileName == name)
    #expect(try Data(contentsOf: try #require(fixture.library.fileStore.coverForBook(book))) == Data("original artwork".utf8))
}

@Test @MainActor
func remoteCoverReplacementRetriesWithoutDiscardingTheOriginalArtwork() async throws {
    let fixture = try SyncFixture()
    defer { fixture.cleanUp() }
    let book = try fixture.book()
    let name = try fixture.library.fileStore.writeCover(Data("original artwork".utf8), bookID: book.id)
    book.coverFileName = name
    let record = CKRecord(recordType: "Book", recordID: CKRecord.ID(recordName: "book-\(book.id.uuidString)"))
    record["updatedAt"] = book.updatedAt.addingTimeInterval(1)
    record["coverFileName"] = "remote-custom-cover.jpg"
    fixture.service.applyRemote(record)
    try fixture.container.mainContext.save()
    let pending = fixture.journal.pendingCount()

    // Metadata can arrive before the image. Keep displaying the original.
    await fixture.service.downloadPendingCovers()
    #expect(book.coverFileName == name)
    let remote = fixture.root.appendingPathComponent("cloud/Documents/NodusReader/Covers/\(book.id.uuidString).jpg")
    try FileManager.default.createDirectory(at: remote.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("replacement artwork".utf8).write(to: remote)
    await fixture.service.downloadPendingCovers()
    #expect(book.coverFileName != name)
    #expect(try Data(contentsOf: try #require(fixture.library.fileStore.coverForBook(book))) == Data("replacement artwork".utf8))
    #expect(fixture.journal.pendingCount() == pending, "Cover downloads do not echo metadata back to iCloud")

    // An explicit generated-cover choice still propagates to this device.
    record["updatedAt"] = book.updatedAt.addingTimeInterval(1)
    record["coverFileName"] = ""
    fixture.service.applyRemote(record)
    await fixture.service.downloadPendingCovers()
    #expect(book.coverFileName == nil)
}

@Test @MainActor
func missingCoverIsRecoveredForDownloadedBooksWithoutANewRemoteRecord() async throws {
    let fixture = try SyncFixture()
    defer { fixture.cleanUp() }
    let book = try fixture.book()
    let local = fixture.library.fileStore.documentURL(for: book)
    try FileManager.default.createDirectory(at: local.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("book".utf8).write(to: local)
    book.downloadState = .downloaded
    book.coverFileName = "missing-on-this-device.jpg"
    let remote = fixture.root.appendingPathComponent("cloud/Documents/NodusReader/Covers/\(book.id.uuidString).jpg")
    try FileManager.default.createDirectory(at: remote.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("embedded artwork".utf8).write(to: remote)

    await fixture.service.downloadPendingCovers()

    #expect(book.downloadState == .downloaded)
    #expect(try Data(contentsOf: try #require(fixture.library.fileStore.coverForBook(book))) == Data("embedded artwork".utf8))
}

@Test @MainActor
func failedOldUploadDoesNotBackOffANewerDelete() throws {
    let fixture = try SyncFixture()
    defer { fixture.cleanUp() }
    let book = try fixture.book()
    let entry = try #require(try fixture.container.mainContext.fetch(FetchDescriptor<SyncOutboxEntry>()).first)
    let snapshot = entry.createdAt
    fixture.library.deleteBooks([book])
    fixture.journal.failPush(entry, enqueuedAt: snapshot, operation: .upsert,
                             error: CKError(.networkFailure), retryAfter: 120)
    #expect(entry.operation == .delete)
    #expect(entry.attempts == 0)
    #expect(entry.lastError.isEmpty)
    #expect(entry.nextAttemptAt <= Date())
}

@Test @MainActor
func outboxBackoffHonoursCloudKitRetryAfterAndKeepsEarliestDeadline() throws {
    let fixture = try SyncFixture()
    defer { fixture.cleanUp() }
    _ = try fixture.book()
    let entry = try #require(try fixture.container.mainContext.fetch(FetchDescriptor<SyncOutboxEntry>()).first)
    let now = Date()
    fixture.journal.failPush(entry, enqueuedAt: entry.createdAt, operation: .upsert,
                             error: CKError(.requestRateLimited), retryAfter: 900, now: now)
    #expect(entry.nextAttemptAt == now.addingTimeInterval(900))
    #expect(entry.attempts == 1)
    #expect(try fixture.journal.nextAttemptAt() == entry.nextAttemptAt)
    _ = fixture.library.createCollection(name: "Another event")
    #expect(try fixture.journal.nextAttemptAt()! < entry.nextAttemptAt)
}

@Test @MainActor
func queueBookkeepingDoesNotGenerateMoreSyncEvents() throws {
    let fixture = try SyncFixture()
    defer { fixture.cleanUp() }
    var events = 0
    let observer = NotificationCenter.default.addObserver(forName: .nodusSyncOutboxChanged,
                                                         object: fixture.journal, queue: nil) { _ in events += 1 }
    defer { NotificationCenter.default.removeObserver(observer) }
    _ = try fixture.book()
    #expect(events == 1, "Real edits must wake the service observing this journal")
    events = 0
    let entry = try #require(try fixture.container.mainContext.fetch(FetchDescriptor<SyncOutboxEntry>()).first)
    fixture.journal.failPush(entry, enqueuedAt: entry.createdAt, operation: .upsert,
                             error: CKError(.networkFailure))
    try fixture.container.mainContext.save()
    #expect(events == 0)
}

@Test @MainActor
func receivingOwnTombstoneCannotDiscardFailedFileCleanup() throws {
    let fixture = try SyncFixture()
    defer { fixture.cleanUp() }
    let book = try fixture.book()
    let id = book.id
    fixture.library.deleteBooks([book])
    let marker = try #require(try fixture.container.mainContext.fetch(FetchDescriptor<SyncTombstone>()).first)
    fixture.journal.withSuspendedRecording {
        fixture.service.applyRemote(fixture.tombstone(.book, id: id, at: marker.deletedAt))
    }
    #expect(fixture.journal.pendingCount() == 1)
    #expect(!marker.isPushed)
}

@Test @MainActor
func remoteTombstonesPersistAndPreventLaterPageResurrection() throws {
    let fixture = try SyncFixture()
    defer { fixture.cleanUp() }
    let id = UUID()
    let deletionDate = Date()
    try fixture.journal.withSuspendedRecording {
        fixture.service.applyRemote(fixture.tombstone(.book, id: id, at: deletionDate))
        let oldBook = CKRecord(recordType: "Book", recordID: CKRecord.ID(recordName: "book-\(id.uuidString)"))
        oldBook["title"] = "Old page"
        oldBook["updatedAt"] = deletionDate.addingTimeInterval(-60)
        fixture.service.applyRemote(oldBook)
        try fixture.container.mainContext.save()
    }
    #expect(fixture.library.allBooks().isEmpty)
    let marker = try #require(try fixture.container.mainContext.fetch(FetchDescriptor<SyncTombstone>()).first)
    #expect(marker.isPushed)
    #expect(marker.deletedAt == deletionDate)
    #expect(fixture.journal.pendingCount() == 0)
}

@Test @MainActor
func newerLocalEditSurvivesAnOlderRemoteTombstone() throws {
    let fixture = try SyncFixture()
    defer { fixture.cleanUp() }
    let book = try fixture.book()
    fixture.journal.withSuspendedRecording {
        fixture.service.applyRemote(fixture.tombstone(.book, id: book.id, at: book.updatedAt.addingTimeInterval(-1)))
    }
    #expect(fixture.library.allBooks().count == 1)
    #expect(fixture.journal.pendingCount() == 1)
}

@Test @MainActor
func fileUploadAndDeletionAreRetryableAndIdempotent() async throws {
    let fixture = try SyncFixture()
    defer { fixture.cleanUp() }
    let book = try fixture.book()
    let local = fixture.library.fileStore.documentURL(for: book)
    try FileManager.default.createDirectory(at: local.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("book".utf8).write(to: local)
    let cloud = fixture.root.appendingPathComponent("cloud")
    let documents = ICloudDocumentStore(fileStore: fixture.library.fileStore, containerURL: cloud)
    let file = RemoteBookFile(book)
    try await documents.upload(file)
    try await documents.upload(file)
    let remote = cloud.appendingPathComponent("Documents/NodusReader/Books/\(book.id.uuidString)/book.txt")
    #expect(try Data(contentsOf: remote) == Data("book".utf8))
    try await documents.deleteRemoteFiles(bookID: book.id)
    try await documents.deleteRemoteFiles(bookID: book.id)
    #expect(!FileManager.default.fileExists(atPath: remote.path))
    // Failed copies must throw rather than acknowledging the outbox.
    try FileManager.default.removeItem(at: local)
    await #expect(throws: (any Error).self) { try await documents.upload(file) }
}

@Test @MainActor
func cloudDocumentDownloadCopiesTheOriginalAndCoverBeforeOpening() async throws {
    let fixture = try SyncFixture()
    defer { fixture.cleanUp() }
    let book = try fixture.book()
    let local = fixture.library.fileStore.documentURL(for: book)
    try FileManager.default.createDirectory(at: local.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("book".utf8).write(to: local)
    book.coverFileName = try fixture.library.fileStore.writeCover(Data("cover".utf8), bookID: book.id)
    let cloud = fixture.root.appendingPathComponent("cloud")
    let documents = ICloudDocumentStore(fileStore: fixture.library.fileStore, containerURL: cloud)
    let remote = RemoteBookFile(book)
    try await documents.upload(remote)
    try await documents.removeLocalDownload(for: remote)
    try FileManager.default.removeItem(at: try #require(fixture.library.fileStore.coverForBook(book)))

    let cover = try await documents.download(remote)
    #expect(try Data(contentsOf: local) == Data("book".utf8))
    #expect(try Data(contentsOf: try #require(fixture.library.fileStore.coverURL(for: cover))) == Data("cover".utf8))
}

@Test @MainActor
func incompleteCloudDocumentNeverReplacesAPreviousLocalCopy() async throws {
    let fixture = try SyncFixture()
    defer { fixture.cleanUp() }
    let book = try fixture.book()
    let cloud = fixture.root.appendingPathComponent("cloud")
    let remote = cloud.appendingPathComponent("Documents/NodusReader/Books/\(book.id.uuidString)/book.txt")
    let local = fixture.library.fileStore.documentURL(for: book)
    try FileManager.default.createDirectory(at: remote.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: local.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("book".utf8).write(to: local)
    try Data("incomplete".utf8).write(to: remote)
    let documents = ICloudDocumentStore(fileStore: fixture.library.fileStore, containerURL: cloud)
    await #expect(throws: SyncFileError.sizeMismatch) { try await documents.download(RemoteBookFile(book)) }
    #expect(try Data(contentsOf: local) == Data("book".utf8))
    #expect(try FileManager.default.contentsOfDirectory(atPath: local.deletingLastPathComponent().path) == ["book.txt"])
}

@Test @MainActor
func iCloudPlaceholdersCountAsRemoteCopiesWithoutAMetadataIndex() async throws {
    let fixture = try SyncFixture()
    defer { fixture.cleanUp() }
    let book = try fixture.book()
    let cloud = fixture.root.appendingPathComponent("cloud")
    let folder = cloud.appendingPathComponent("Documents/NodusReader/Books/\(book.id.uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data().write(to: folder.appendingPathComponent(".book.txt.icloud"))
    let documents = ICloudDocumentStore(fileStore: fixture.library.fileStore, containerURL: cloud)
    #expect(await documents.hasRemoteCopy(for: RemoteBookFile(book)))
    #expect(!FileManager.default.fileExists(atPath: fixture.library.fileStore.documentURL(for: book).path))
}

#if os(macOS)
@Test(.enabled(if: ProcessInfo.processInfo.environment["NODUS_ICLOUD_DOWNLOAD_CONTAINER"] != nil))
@MainActor
func realICloudDocumentsDownloadIntoAnIsolatedLibrary() async throws {
    let fixture = try SyncFixture()
    defer { fixture.cleanUp() }
    let cloud = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["NODUS_ICLOUD_DOWNLOAD_CONTAINER"]))
    let folder = cloud.appendingPathComponent("Documents/NodusReader/Books")
    let documents = ICloudDocumentStore(fileStore: fixture.library.fileStore, containerURL: cloud)
    let manager = FileManager.default
    var copied = 0
    for directory in try manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
        guard let id = UUID(uuidString: directory.lastPathComponent) else { continue }
        for file in try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) {
            let values = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true, !file.lastPathComponent.hasPrefix(".") else { continue }
            let book = Book(id: id, title: "iCloud download validation", author: "",
                            format: BookFormat(rawValue: file.pathExtension) ?? .txt,
                            fileName: file.lastPathComponent, relativePath: "", fileSize: Int64(values.fileSize ?? 0),
                            contentHash: "validation")
            _ = try await documents.download(RemoteBookFile(book))
            let local = fixture.library.fileStore.documentURL(for: book)
            #expect(FileStore.fileSize(at: local) == book.fileSize)
            #expect((try Data(contentsOf: local)).count > 0)
            copied += 1
        }
    }
    #expect(copied > 0)
}
#endif

@Test @MainActor
func customCoverChangesReplaceTheExistingICloudCover() async throws {
    let fixture = try SyncFixture()
    defer { fixture.cleanUp() }
    let book = try fixture.book()
    let local = fixture.library.fileStore.documentURL(for: book)
    try FileManager.default.createDirectory(at: local.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("book".utf8).write(to: local)
    book.coverFileName = try fixture.library.fileStore.writeCover(Data("first".utf8), bookID: book.id)
    let cloud = fixture.root.appendingPathComponent("cloud")
    let documents = ICloudDocumentStore(fileStore: fixture.library.fileStore, containerURL: cloud)
    try await documents.upload(RemoteBookFile(book))
    book.coverFileName = try fixture.library.fileStore.writeCover(Data("second".utf8), bookID: book.id)
    try await documents.upload(RemoteBookFile(book))
    let remote = cloud.appendingPathComponent("Documents/NodusReader/Covers/\(book.id.uuidString).jpg")
    #expect(try Data(contentsOf: remote) == Data("second".utf8))
    book.coverFileName = nil
    try await documents.upload(RemoteBookFile(book))
    #expect(!FileManager.default.fileExists(atPath: remote.path))
}

@Test @MainActor
func cloudOnlyMetadataCanSyncWithoutDownloadingOriginalOrCover() async throws {
    let fixture = try SyncFixture()
    defer { fixture.cleanUp() }
    let book = try fixture.book()
    book.coverFileName = "\(book.id.uuidString).jpg"
    book.downloadState = .cloudOnly
    let cloud = fixture.root.appendingPathComponent("cloud")
    let remoteFolder = cloud.appendingPathComponent("Documents/NodusReader/Books/\(book.id.uuidString)")
    let covers = cloud.appendingPathComponent("Documents/NodusReader/Covers")
    try FileManager.default.createDirectory(at: remoteFolder, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: covers, withIntermediateDirectories: true)
    try Data().write(to: remoteFolder.appendingPathComponent(".book.txt.icloud"))
    try Data().write(to: covers.appendingPathComponent(".\(book.id.uuidString).jpg.icloud"))
    let documents = ICloudDocumentStore(fileStore: fixture.library.fileStore, containerURL: cloud)
    try await documents.upload(RemoteBookFile(book))
    #expect(!FileManager.default.fileExists(atPath: fixture.library.fileStore.documentURL(for: book).path))
    try await documents.deleteRemoteFiles(bookID: book.id)
    #expect(!FileManager.default.fileExists(atPath: remoteFolder.path))
    #expect(try FileManager.default.contentsOfDirectory(atPath: covers.path).isEmpty)
}

@Test @MainActor
func failedAtomicCopyPreservesThePreviousCloudFile() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let remote = root.appendingPathComponent("cover.jpg")
    try Data("previous".utf8).write(to: remote)
    #expect(throws: (any Error).self) {
        try ICloudDocumentStore.copyAtomically(from: root.appendingPathComponent("missing.jpg"), to: remote)
    }
    #expect(try Data(contentsOf: remote) == Data("previous".utf8))
}

@Test @MainActor
func pendingDeletionAndRetrySurviveReopeningTheLocalStore() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let configuration = ModelConfiguration("SyncRestart", schema: Persistence.schema,
        url: root.appendingPathComponent("library.store"), cloudKitDatabase: .none)
    let id = UUID()
    let now = Date()
    do {
        let container = try ModelContainer(for: Persistence.schema, configurations: [configuration])
        let journal = SyncJournal(context: container.mainContext)
        journal.recordDelete(.book, id: id)
        let entry = try #require(try container.mainContext.fetch(FetchDescriptor<SyncOutboxEntry>()).first)
        journal.failPush(entry, enqueuedAt: entry.createdAt, operation: .delete,
                         error: CKError(.networkFailure), retryAfter: 120, now: now)
        try container.mainContext.save()
    }
    let reopened = try ModelContainer(for: Persistence.schema, configurations: [configuration])
    let journal = SyncJournal(context: reopened.mainContext)
    let entry = try #require(try reopened.mainContext.fetch(FetchDescriptor<SyncOutboxEntry>()).first)
    #expect(entry.entityID == id)
    #expect(entry.operation == .delete)
    #expect(entry.attempts == 1)
    #expect(!entry.lastError.isEmpty)
    #expect(entry.nextAttemptAt == now.addingTimeInterval(120))
    #expect(try journal.nextAttemptAt() == entry.nextAttemptAt)
    #expect(try reopened.mainContext.fetchCount(FetchDescriptor<SyncTombstone>()) == 1)
}

@Test @MainActor
func pronunciationsSyncAndLegacyRecordsPreserveLocalDictionary() throws {
    let fixture = try SyncFixture()
    defer { fixture.cleanUp() }
    let book = try fixture.book()
    let rule = PronunciationRule(written: "Paul", spoken: "Pol")
    fixture.library.setPronunciations([rule], for: book)
    let record = CKRecord(recordType: "Book", recordID: CKRecord.ID(recordName: "book-\(book.id.uuidString)"))
    record["updatedAt"] = book.updatedAt.addingTimeInterval(10)
    fixture.service.applyRemote(record)
    #expect(book.pronunciations == [rule], "An older client's payload must preserve this field")
    record["updatedAt"] = book.updatedAt.addingTimeInterval(10)
    record["pronunciationsJSON"] = "[]"
    fixture.service.applyRemote(record)
    #expect(book.pronunciations.isEmpty, "Remote deletions must also sync")
    record["updatedAt"] = book.updatedAt.addingTimeInterval(10)
    record["pronunciationsJSON"] = String(data: try JSONEncoder().encode([rule]), encoding: .utf8)!
    fixture.service.applyRemote(record)
    #expect(book.pronunciations == [rule])
}

/// Two signed devices, one iCloud account and the same UUID session. Uses only a
/// temporary custom zone and synthetic Book records, never the personal library.
@Test(.enabled(if: ProcessInfo.processInfo.environment["NODUS_LIVE_PRONUNCIATION_SESSION"] != nil), .timeLimit(.minutes(5)))
@MainActor
func livePronunciationCloudKitRoundTrip() async throws {
    let environment = ProcessInfo.processInfo.environment
    let session = try #require(environment["NODUS_LIVE_PRONUNCIATION_SESSION"])
    let id = try #require(UUID(uuidString: session))
    let role = try #require(environment["NODUS_LIVE_PRONUNCIATION_ROLE"])
    #expect(role == "writer" || role == "reader")
    let cloud = CKContainer(identifier: "iCloud.ai.nodus.reader")
    let status = try await cloud.accountStatus()
    try #require(status == .available, "Signed host needs an available iCloud account")
    let database = cloud.privateCloudDatabase
    let zone = CKRecordZone.ID(zoneName: "NodusPronunciationTest-\(session)", ownerName: CKCurrentUserDefaultName)
    let recordID = CKRecord.ID(recordName: "book-\(id.uuidString)", zoneID: zone)
    let fixture = try SyncFixture()
    defer { fixture.cleanUp() }
    let original = PronunciationRule(written: "Rocinante", spoken: "Ro si nan te")
    let modified = PronunciationRule(id: original.id, written: "Rocinante", spoken: "Ro thi nan te")
    func payload() throws -> CKRecord {
        try #require(fixture.service.buildRecord(for: SyncOutboxEntry(entityType: .book, entityID: id, operation: .upsert)))
    }
    func copyPayload(_ source: CKRecord, to target: CKRecord) {
        for key in source.allKeys() { target[key] = source[key] }
    }
    func localBook() throws -> Book {
        try #require(fixture.library.context.fetch(FetchDescriptor<Book>()).first { $0.id == id })
    }
    func waitFor(_ predicate: (CKRecord) -> Bool) async throws -> CKRecord {
        let deadline = Date().addingTimeInterval(180)
        while Date() < deadline {
            do {
                let record = try await database.record(for: recordID)
                if predicate(record) { return record }
            } catch let error as CKError where error.code == .unknownItem || error.code == .zoneNotFound { }
            try await Task.sleep(for: .seconds(2))
        }
        throw NSError(domain: "NodusLivePronunciationTest", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for the other signed device in the same iCloud account/session"])
    }
    if role == "writer" {
        _ = try await database.save(CKRecordZone(zoneID: zone))
        do {
            let book = Book(id: id, title: "Nodus pronunciation verification", author: "Test", format: .txt,
                            fileName: "probe.txt", relativePath: "probe.txt", fileSize: 1, contentHash: session)
            fixture.library.context.insert(book)
            fixture.library.setPronunciations([original], for: book)
            let record = CKRecord(recordType: "Book", recordID: recordID)
            copyPayload(try payload(), to: record)
            _ = try await database.save(record)
            print("LIVE PRONUNCIATION: writer published", session)
            let changed = try await waitFor { ($0["pronunciationsJSON"] as? String)?.contains("Ro thi nan te") == true }
            fixture.service.applyRemote(changed)
            #expect(try localBook().pronunciations.first?.spoken == modified.spoken)
            fixture.library.setPronunciations([], for: try localBook())
            try localBook().updatedAt = (changed["updatedAt"] as? Date ?? Date()).addingTimeInterval(1)
            copyPayload(try payload(), to: changed)
            _ = try await database.save(changed)
            _ = try await waitFor { $0["title"] as? String == "Nodus verification complete" }
            _ = try await database.deleteRecordZone(withID: zone)
            print("LIVE PRONUNCIATION: writer verified return edit and deletion; temporary zone removed", session)
        } catch {
            _ = try? await database.deleteRecordZone(withID: zone)
            throw error
        }
    } else {
        let record = try await waitFor { ($0["pronunciationsJSON"] as? String)?.contains("Ro si nan te") == true }
        fixture.service.applyRemote(record)
        #expect(try localBook().pronunciations.first?.spoken == original.spoken)
        fixture.library.setPronunciations([modified], for: try localBook())
        try localBook().updatedAt = (record["updatedAt"] as? Date ?? Date()).addingTimeInterval(1)
        copyPayload(try payload(), to: record)
        _ = try await database.save(record)
        let cleared = try await waitFor { $0["pronunciationsJSON"] as? String == "[]" }
        fixture.service.applyRemote(cleared)
        #expect(try localBook().pronunciations.isEmpty)
        cleared["title"] = "Nodus verification complete"
        _ = try await database.save(cleared)
        print("LIVE PRONUNCIATION: reader received initial rule, sent edit and received deletion", session)
    }
}
