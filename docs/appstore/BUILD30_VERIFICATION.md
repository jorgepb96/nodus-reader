# Build 30 — event-driven iCloud sync

30 October 2026. Nodus Reader **0.1.0 (30)** includes the iCloud queue and recovery changes merged in [PR #30](https://github.com/jorgepb96/nodus-reader/pull/30). App source commit: `54c7ac51d53b49b64859f6e8549e827b6d735c75`; merge commit: `2abce5ff8efae8b03809dfc3a5da3963873fb844`. Subsequent delivery-document changes do not alter app source.

## Behaviour

- Library saves (including paused narration positions, bookmarks, annotations, imports, collections and deletions) wake a serial sync coordinator. Event bursts coalesce without indefinitely postponing the first pass. New events never cancel an in-flight upload and remain eligible for a follow-up.
- Retry dates and errors are persisted in SwiftData and scheduled automatically, with exponential backoff and CloudKit retry-after support. Old successes/failures cannot acknowledge or delay a newer operation on the same entity.
- CloudKit save/delete results are checked per record; missing acknowledgements are failures. Saves use existing record change tags. Failed pull records do not advance the change token.
- Remote tombstones remain local to protect later-page records. Receiving an own tombstone does not discard pending iCloud file cleanup. Timestamped tombstones, rather than unversioned physical record deletions, authorize local removal.
- Originals and covers are staged before publishing metadata. Failed transfers/deletions remain queued. Covers are replaced atomically; cloud-only books reuse existing iCloud placeholders without requiring a local original or cover.
- Startup, foreground, network recovery and account events request reconciliation. While the app is active, a 60-second fallback discovers remote-only edits. APNs subscriptions are not registered in this release. iOS requests a bounded background pass; work survives suspension if the pass cannot finish.

## Checks

| Check | Result | Local evidence under `build/` |
| --- | --- | --- |
| Final iPhone unit/integration suite | 115 passed, 10 optional skips, 0 failures | `Build30-iPhone-Validated.xcresult` |
| Final macOS unit/integration suite | 115 passed, 10 optional skips, 0 failures | `Build30-macOS-Validated.xcresult` |
| iPhone UI: iCloud/storage, page/bookmark, paused narration after relaunch | 3 passed, 0 failures | `Build30-iPhone-Final.xcresult` |
| iPad unit/integration suite | 115 passed, 10 optional skips, 0 failures | `Build30-iPad-Validated.xcresult` |
| iPad iCloud/storage UI | 1 passed, 0 failures | `Build30-iPad.xcresult` |
| English/Spanish catalog | 709 keys, 0 missing Spanish, 0 placeholder mismatches | Current Debug extraction, both platforms |
| Whitespace | `git diff --check` passed | Source commit |

The 17 new sync tests cover in-flight events and cancellation, bounded coalescing, retry scheduling, disabling/re-enabling in flight, save/delete acknowledgements, server retry deadlines, stale failures versus newer deletes, scoped change notifications and bookkeeping without event loops, tombstone ordering and file cleanup, newer local edits, idempotent file operations, cover replacement/clearing, cloud-only placeholders, failed atomic copies and queue persistence across reopening an on-disk store. Existing suites exercise import batches, collections, bookmarks and exact narration cursor persistence. Narration UI tests use the existing silent-audio test flag.

Signed, authenticated two-device CloudKit/iCloud Drive validation remains outstanding. Simulator tests validate the local queue, coordinator and file behavior without an authenticated iCloud account; they do not establish live cross-device reliability.

## Delivery

The signed iOS archive passed deep/strict signature verification and was uploaded successfully through Xcode's App Store Connect export. Apple accepted the package for processing (`build/build30-upload-ios.log`, `EXPORT SUCCEEDED`). The binary is 0.1.0 (30). A source/binary fingerprint is in [BUILD30_SOURCE_FINGERPRINT.json](BUILD30_SOURCE_FINGERPRINT.json).

iOS build/delivery ID: `dfc62a01-e5ea-4dad-9e14-be9bb997d217`.

| Platform | Processing | Internal | Public Beta |
| --- | --- | --- | --- |
| iOS / iPadOS | VALID | IN_BETA_TESTING | APPROVED / IN_BETA_TESTING |
| Native macOS | Final archive in progress | Not uploaded yet | No submission |

iOS was uploaded and made available first, as requested. It is assigned to **Nodus Reader — Public Beta**; **Internal** has automatic access to all builds. English and Spanish release notes are set. The [public TestFlight link](https://testflight.apple.com/join/SjCk8AZ1) is unchanged. macOS public beta review remains withdrawn; no App Store production submission is part of this task.
