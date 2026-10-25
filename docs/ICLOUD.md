# iCloud Sync

Status: **implemented behind an opt-in switch; signed real-device validation still required.**

The app uses only the user's personal iCloud account. There is no Nodus account and
no Nodus sync server. Sync is off by default; the library works fully without it.

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
| Book metadata, reading position, status, favourite, per-book voice/mode | CloudKit private database, `Book` record |
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
3. `pushOutbox()` drains entries in creation order. Each entry becomes a CloudKit
   record with an `updatedAt`.
4. A remote tombstone that is newer than the local record deletes the local record.
   A newer remote record is applied instead of being overwritten by a stale queued
   edit.
5. `pullChanges()` uses `recordZoneChanges(inZoneWith:since:)` with a persisted
   server change token. An expired token resets and refetches.
6. Upserts and tombstones applied from the server suspend outbox recording, save on
   the main actor and update the UI.
7. Retries use exponential backoff (5 s doubling to 300 s) and store the last error
   on the outbox entry.

Not synced yet: custom themes and reading/typography preferences (global
`UserDefaults`; there are no per-book typography settings). The `theme`,
`preference` and `readingPosition` entity types are reserved but unused. A book's
full-text search index and chapter titles are not uploaded either; they are rebuilt
locally once the document has been downloaded.

Scalar conflicts are last-writer-wins by `updatedAt`. Memberships, bookmarks and
annotations are individual records, so an edit on one device does not erase
unrelated rows. A recoverable side-by-side conflict UI for simultaneous annotation
edits is still future work.

### Files

- Uploading a `Book` after a successful metadata push copies the local document and
  cover into the ubiquity container. iCloud Drive performs the transfer.
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
