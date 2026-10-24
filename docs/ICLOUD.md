# iCloud Sync Architecture (Milestone 4)

**Status: not implemented.** The app currently reports “Local only”. This document is the implementation plan required before the Sync screen can claim otherwise. It must not be presented as a working feature until real-device testing passes.

## Goals

- One library across the user's iPhone, iPad and Mac, using only the user's personal iCloud account.
- No Nodus account or Nodus server.
- Fully usable offline; changes queue locally and sync later.
- Never sync models, voices, generated audio, OCR caches or credentials.
- Preserve data on conflicts whenever possible.
- Keep “Remove Download” and “Delete from Library” semantically separate.

## Split of responsibilities

| Data | Mechanism |
|---|---|
| Bibliographic metadata, collections, memberships, bookmarks, annotations, highlights, reading progress, custom themes, per-book preferences | CloudKit private database |
| Original EPUB/PDF/document files, custom covers, generated cover fallbacks that cannot be regenerated | iCloud Documents container |
| Fast local queries and offline operation | SwiftData local replica |
| Models, voices, embeddings, TTS audio, OCR caches, temp files, Hugging Face token, hardware-specific settings | Local only, excluded |

iCloud Documents paths:

```
Documents/NodusReader/
  Books/<content-hash>/<original-file-name>
  Covers/<book-id>/<cover-file-name>
```

The iCloud container should be `iCloud.ai.nodus.reader` (to be created in the Developer portal; identifier may change). Metadata-then-file ordering must be allowed: a book can exist in CloudKit before its asset finishes downloading.

## CloudKit record types

All records use stable string/UUID identifiers and a `schemaVersion`, `updatedAt` and `updatedByDevice` field.

- `Book`: id, contentHash, title, author, language, published, description, format, fileRelativePath, fileSize, coverRelativePath, addedAt, status, favorite, readingMode, preferredVoiceID.
- `ReadingPosition`: bookID, locator JSON, progress, sourceDevice, updatedAt.
- `Collection`: id, name, parentID, sortIndex, createdAt.
- `Membership`: id (bookID+collectionID stable ID), bookID, collectionID, sortIndex, addedAt.
- `Bookmark`: id, bookID, locator JSON, title, createdAt.
- `Annotation`: id, bookID, locator/range, kind, color, text, note, createdAt, updatedAt.
- `CustomTheme`: id, name, colours, createdAt.
- `ReaderPreference`: per-book typography JSON.
- `Tombstone`: entity type, entity id, deletedAt, deletedByDevice. Deletions must be explicit and durable.

Sets (for example the collection membership of a book) are represented by explicit `Membership` records, not by mutating a single collection record. This avoids last-writer-wins destroying memberships added on another device.

## Sync engine

1. All local mutations go through `LibraryService`, which writes SwiftData in a transaction and appends an entry to a durable outbox table (`SyncOperation`): create/update/delete + entity ID + payload + attempt count.
2. A `CloudSyncEngine` observes connectivity (`NWPathMonitor`) and CloudKit account status. It drains the outbox in order with exponential backoff and jitter.
3. Remote changes are fetched with `CKFetchRecordZoneChangesOperation` using a persisted server change token. Each record is mapped to SwiftData by stable ID.
4. Files are uploaded to iCloud Documents only after metadata is committed. Downloads resume through `NSMetadataQuery`/UbiquitousItem APIs and update `downloadState`.
5. Use a private custom zone with server change tokens; never sync the SQLite file as a document.
6. Persist `lastSuccessfulSync` locally and display it honestly; never claim “instant”.

## Conflict resolution

- Scalar fields: compare `updatedAt`; newer wins per field where the model allows it. For collections and book metadata, merge non-conflicting fields instead of replacing the whole object.
- Sets/memberships: union by stable ID; deletions are tombstones, not absences.
- Reading positions: last writer wins, but preserve `sourceDevice` and `updatedAt` so the UI can say where the position came from. Never regress a position backwards solely because a device synced later with an older position.
- Annotations: merge by ID; if both edit the same note, keep both versions in a conflict field and surface a recoverable conflict UI rather than silently discarding.
- Tombstones are retained for a bounded period (for example 90 days) and prevent an offline device from resurrecting deleted content.
- A device that was offline during a deletion must not overwrite the tombstone on reconnect.

## Download states and deletion

- `downloaded`: metadata and file are local.
- `cloudOnly`: metadata is local, file is an iCloud placeholder; opening triggers a download.
- `downloading`: progress shown everywhere the book appears.
- `Remove Download`: delete the local document copy, keep metadata, annotations and the iCloud copy. Never delete the document from other devices.
- `Delete from Library…`: destructive confirmation, creates a tombstone and deletes metadata, local file, cover and (after sync) remote records. Must not be confused with cache deletion.
- Disabling iCloud must not silently delete local files. Explain the choice and require confirmation if anything will be removed.

## UI

- `iPhone-Sync.dc.html` / `iPhone-Sync.png` define the screen: toggle, status, last successful sync, downloaded books, download all/selected, storage bars, local-only note and troubleshooting.
- Add per-book context menu items once sync exists. Until then, keep only “Delete from Library…” and do not show a non-functional “Remove Download”.
- Surface queue state (“Changes queued while offline”) and per-book download failure with retry.
- Distinguish storage: Books (iCloud files), Voices/Models (local only), Caches (local only).

## Testing

1. Unit-test outbox ordering, retry/backoff, tombstone handling, merge rules and locator conflict resolution with a simulated sync service.
2. Integration-test with a real CloudKit development container: import on device A, verify metadata appears on B before the file, then verify download and opening.
3. Two real devices signed into the same iCloud account:
   - import on iPhone, sync, open on Mac;
   - read to chapter 5 on Mac, verify the iPhone Continue card says “from your Mac”;
   - edit the same annotation offline on both, reconnect, verify both versions are recoverable;
   - delete a book on one device, verify it disappears on the other but a stale offline device cannot resurrect it;
   - Remove Download on one device, verify others keep their downloads.
4. Network-loss tests: airplane mode during import, during annotation creation and during file download; verify the queue drains when connectivity returns.
5. Verify models/voices/caches are absent from the CloudKit container and iCloud Documents.
6. Do not mark sync as validated only because mock tests pass; real-device verification is required.

## Open decisions

- Zone granularity (one library zone vs per-book zones) and CloudKit asset limits.
- Whether large PDFs are always iCloud Documents or optionally chunked assets.
- Conflict UI scope for simultaneous annotation edits.
- Migration from a local-only library to iCloud when the user first enables sync.
- Apple Developer container/bundle identifiers and App Store review implications.
