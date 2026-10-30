# iCloud Sync

Status: **implemented behind an opt-in switch. Production schema deployed on 30 October 2026; signed two-device validation still required.**

Synchronization uses the user's personal iCloud account and is off by default.
The library works fully without it.

## Container and entitlements

| Item | Value |
|---|---|
| CloudKit container | `iCloud.ai.nodus.reader` |
| iCloud Documents container | `iCloud.ai.nodus.reader` |
| App Group (Share Extension) | `group.ai.nodus.reader` |
| Entitlements file | `Config/NodusReader.entitlements` |
| CloudKit services | `CloudKit`, `CloudDocuments` |

`project.yml` points the app at that entitlements file. Xcode automatic signing must
have a team that owns the container, and the CloudKit record types must be deployed
from the development environment to production before a release.

An unsigned or simulator build has no iCloud entitlement. `CloudSyncService` detects
that (no ubiquity identity token) and reports iCloud as unavailable instead of
constructing `CKContainer`, which would terminate the process. This is deliberate.

## Split of responsibilities

| Data | Mechanism |
|---|---|
| Book metadata, reading position, status, favourite, per-book voice/mode, per-book appearance (`appearanceJSON`) | CloudKit private database, `Book` record |
| Collections and explicit memberships | `Collection`, `Membership` records |
| Bookmarks and annotations (highlights/notes) | `Bookmark`, `Annotation` records |
| Deletions | `Tombstone` records, never inferred from absence |
| Original documents and covers | iCloud Documents |
| Fast local queries and offline state | SwiftData local replica |
| Models, voices, TTS audio, OCR caches, temp files, Hugging Face token | Local only; never uploaded |

iCloud Documents layout:

```
Documents/NodusReader/
  Books/<book-id>/<original-file-name>
  Covers/<book-id>.jpg
```

The metadata can arrive before the file. A book whose file is not local is marked
`cloudOnly`; opening it triggers a download.

## Implementation map

| Piece | File |
|---|---|
| Serial event scheduling, follow-ups and retry deadlines | `NodusReader/Core/Sync/SyncCoordinator.swift` |
| Durable outbox and tombstones | `NodusReader/Core/Sync/SyncJournal.swift` |
| SwiftData models | `NodusReader/Core/Persistence/Models.swift` |
| CloudKit + downloads | `NodusReader/Core/Sync/CloudSyncService.swift` |
| iCloud Documents | `NodusReader/Core/Sync/ICloudDocumentStore.swift` |
| Settings UI | `NodusReader/Features/Settings/StorageSettingsView.swift` |
| Share staging | `Shared/SharedImportInbox.swift` |

### Outbox

`SyncJournal` observes `ModelContext.didSave` and enqueues an upsert for every
inserted/updated `Book`, `LibraryCollection`, `CollectionMembership`, `Bookmark` or
`Annotation`. It deduplicates by entity type + id. SwiftData delivers the changed
identifiers as an array under string keys; until the 2026-10-25 independent audit
the journal read them as a `Set` and recorded nothing. An entry re-enqueued while
its push is in flight is kept, so the newer edit or delete is pushed next. Deleting through `LibraryService`
records a durable `SyncTombstone` and a `delete` outbox entry with the book's file
name for remote-file cleanup. The queue survives launches because it is stored in
SwiftData.

### Push, pull and conflicts

1. `CloudSyncService.start()` refreshes account/iCloud Drive availability.
2. When enabled, it creates the custom zone `NodusReader` if needed.
3. `SyncCoordinator` serializes network passes. Local saves request a pass within
   one second; a burst cannot postpone the first deadline. Events during a pass
   request a follow-up and never cancel the active upload. Parents are pushed
   before memberships, bookmarks and annotations.
4. Each upsert reads the existing record and saves with its change tag using
   `ifServerRecordUnchanged`. A concurrent server edit causes a retry instead of
   an unconditional overwrite. Only `unknownItem` means a record is absent;
   network and authentication failures keep the operation queued.
5. A remote tombstone that is newer than the local record deletes the local record.
   A newer remote record is applied instead of being overwritten by a stale queued
   edit.
6. `pullChanges()` uses `recordZoneChanges(inZoneWith:since:)` with a persisted
   server change token. An expired token resets and refetches.
7. Upserts and tombstones applied from the server suspend outbox recording, save on
   the main actor and update the UI.
8. Every CloudKit save/delete result is checked individually. Partial failures
   keep the operation queued. A failed per-record pull does not advance the
   change token past that failure.
9. Retries use exponential backoff (10 s initially, doubling to 300 s), respect
   CloudKit's longer `retryAfterSeconds`, and store the error and deadline in
   SwiftData. The coordinator automatically wakes for the earliest pending
   deadline; no additional user action is needed. A failed older push cannot
   back off or acknowledge a newer edit/delete for the same entity.
10. Own incoming tombstones cannot acknowledge unfinished iCloud file cleanup.
    Remote tombstones are retained locally so records from later pages cannot
    resurrect an older entity. Physical CloudKit deletions have no timestamp;
    only the corresponding tombstone authorizes removal.

Pausing narration already saves the complete narration cursor through
`LibraryService.updateProgress`, so it follows the same durable save event as
bookmarks, notes, imports, favourites, collection creation/renaming/membership and
single or bulk deletions. Queue bookkeeping and remote applies do not generate
additional user-change events.

Recovery is triggered on network restoration, iCloud account change, app startup,
foreground entry and Sync Now. While the app is active, a 60-second reconciliation
fallback discovers changes made only on another device. This release does not
register APNs subscriptions: remote changes are discovered at these reconciliation
points, not by a guaranteed immediate push. iOS background entry requests a final
pass under a bounded background-task assertion; iOS may suspend the app before it
finishes, and the durable queue resumes on the next opportunity. Disabling sync
invalidates future work without cancelling a network write already in progress.
A later generation cannot acknowledge the previous generation's operations.

Themes and reading preferences (app theme, reader theme, custom themes, typography,
page turn) sync as one `Preference` record (`preference-settings`), last writer
wins by its `updatedAt`. They live in `UserDefaults`; a local edit is detected by
comparing snapshots when defaults change. A fresh install starts with a snapshot
dated `distantPast`, so it adopts the synced choices instead of overwriting them
with its defaults. A book's own appearance ("This book only": theme and typography,
including the reading mode) travels with the book as the `appearanceJSON` field.
Before release, deploy the `Preference` record type and the new `Book` field to the
production CloudKit schema. A book's
full-text search index and chapter titles are not uploaded; they are rebuilt
locally once the document has been downloaded.

Children (memberships, bookmarks, annotations) whose book or collection has not
arrived yet are kept in a persisted deferred queue and retried after every pull
page, instead of being dropped while the change token moves on. Clearing a custom
cover also removes the iCloud cover, and other devices fall back to the
typographic cover.

All iCloud Drive file work (container lookup, copies, cover reads) runs off the
main thread; only the `NSMetadataQuery` is started on the main run loop.

Scalar conflicts are last-writer-wins by `updatedAt`. Memberships, bookmarks and
annotations are individual records, so an edit on one device does not erase
unrelated rows. A recoverable side-by-side conflict UI for simultaneous annotation
edits is still future work.

### Files

- Before publishing a local `Book`, its original and cover are staged into the
  ubiquity container. iCloud Drive performs the actual transfer. Failures throw
  and retain the outbox entry. Immutable originals and `.icloud` placeholders are
  reused; changed covers are atomically replaced even when the original already
  exists. A failed copy preserves the previous remote file.
- Downloading uses a scoped `NSMetadataQuery` to find the item even when only a
  hidden `.icloud` placeholder exists, calls
  `startDownloadingUbiquitousItem(at:)`, polls `ubiquitousItemDownloadingStatus`
  (up to two minutes), then copies the document and cover into the app container.
- `Remove Download` first checks that an iCloud copy really exists, then removes only
  the local file and marks the book `cloudOnly`. The cover and metadata remain.
- `Delete from Library…` creates a tombstone, deletes local files and, when the
  deletion is pushed, removes the iCloud Drive files and CloudKit records.

## UI behaviour

- **Settings → iCloud & Storage** shows the opt-in toggle, real account status, last
  successful sync, pending queue count, a Sync Now action, local storage, cloud-only
  books with individual downloads, Download All, troubleshooting and the privacy
  explanation.
- Books show an iCloud-download badge when their document is not local.
- The context menu exposes `Remove Download` and `Download from iCloud` only when
  sync is enabled.
- Opening a cloud-only book attempts a download and shows the real failure reason if
  it cannot complete.
- Disabling sync does not delete local files, metadata or iCloud data.

## Setup for a signed build

1. Create the `iCloud.ai.nodus.reader` container in the Apple Developer portal.
2. Enable iCloud → CloudKit and iCloud Documents for the app identifier.
3. Enable the `group.ai.nodus.reader` App Group for both the app and the Share
   Extension.
4. Select the team in Xcode and let automatic signing update the provisioning
   profiles.
5. Run on two signed devices with the same iCloud account.
6. Open the CloudKit Dashboard, verify the development record types, then deploy the
   schema to production.

## Validation checklist

- [ ] Import on iPhone; verify metadata on Mac before the file finishes.
- [ ] Open the cloud-only book on Mac and confirm the document downloads.
- [ ] Read ahead on Mac; verify the iPhone Continue card shows the Mac as source and
      does not regress.
- [ ] Create bookmarks/notes on both devices; verify they merge by id.
- [ ] Delete on one device; verify the other removes it and a stale offline device
      cannot resurrect it.
- [ ] `Remove Download` on one device; verify other devices keep their downloads.
- [ ] Airplane mode during import/annotation/download; verify the queue drains later.
- [ ] Confirm models, audio and OCR caches are absent from CloudKit and iCloud Drive.

## Build 30 regression coverage

`NodusReaderTests/SyncTests.swift` exercises event bursts, requests during an
in-flight pass, automatic retry scheduling, disabling/re-enabling in flight,
CloudKit per-record acknowledgement, server retry-after deadlines, stale failure
versus a newer delete, bookkeeping without event loops, own-tombstone file cleanup,
remote tombstone ordering, newer local edits, idempotent file upload/removal,
replacement/clearing of covers, failed atomic replacement and queue persistence
after reopening an on-disk store. Existing tests cover import batches, bookmarks,
collections and exact narration cursor persistence. Live two-device iCloud testing
remains a separate signed-device validation; simulator tests do not exercise an
authenticated CloudKit account.

CloudKit result semantics and change-tag conflicts follow Apple's documentation:
[modifyRecords](https://developer.apple.com/documentation/cloudkit/ckdatabase/modifyrecords(saving:deleting:savepolicy:atomically:))
and [serverRecordChanged](https://developer.apple.com/documentation/cloudkit/ckerror/serverrecordchanged).

## Versioned schema and release gate

The canonical production schema is [Config/CloudKitSchema.ckdb](../Config/CloudKitSchema.ckdb). It contains the seven application types and 54 payload fields. The app uses the private database; these types have no PUBLIC database grants. The built-in Users definition is preserved.

Before release, run:

```bash
python3 tools/cloudkit/check-schema.py
```

This checks field coverage against CloudSyncService and rejects public grants on application types. It does **not** prove deployment. Export a fresh **Production** schema from CloudKit Console (or authenticated `cktool export-schema`) and run the same check with its path as an argument. Import any required additive changes into Development, review Deploy Schema Changes, deploy, and verify a fresh Production export before declaring server sync ready. TestFlight VALID/APPROVED and local unit tests do not validate the CloudKit schema.

On 30 October, the user reported `Cannot create new type Book in production schema`. Both environments contained only Users. The full schema was imported and validated by Apple, then deployed to Production: seven new record types, seven record-name indexes, zero security-role changes. A fresh Production export was checked against all payload fields and their expected types; Users remained unchanged. This server correction applies to existing builds without another binary upload. See [deployment record](appstore/CLOUDKIT_SCHEMA_DEPLOYMENT_2026-10-30.md).
