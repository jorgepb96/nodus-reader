# Bug Audit — 2026-10-25

Scope: reader/pagination, narration/models/cache, import/Share Extension, iCloud sync, and a global pass for force unwraps, indexing and concurrency. The audit found real issues; the high-impact ones were corrected and the full test suite was re-run.

## Fixed in this pass

High impact:

- **iCloud outbox never suspended during remote pulls.** The `didSave` observer deferred handling with a `Task`, after `withSuspendedRecording` had already ended. Every pulled record was re-enqueued (push → pull → push echo). `SyncJournal` now handles the save synchronously on the main actor and the suspension scope is `rethrows` so a failed local save stops the change token from advancing.
- **Path traversal through synced paths.** `FileStore` now derives a book's document URL from its stable ID and sanitized file name instead of trusting `relativePath`, rejects relative paths outside `Library/`, sanitizes `..`/`.`/backslashes, and removes only the book's own folder. This prevents a corrupt or malicious CloudKit record from deleting `Application Support`, the whole library or files outside the container.
- **iPhone/Android-style audio cache corruption on canceled Phonon synthesis.** Cancelling `Phonon.speak` returns partial audio. Neural playback now checks cancellation and the generation token after synthesis and before caching, so partial audio is never stored as a full sentence.
- **System-voice delegate race.** A late `didFinish`/`didCancel` from a stopped utterance could advance an extra sentence or mark the new one paused. Delegate callbacks now carry the `AVSpeechUtterance` and are ignored unless it is the active utterance.
- **Concurrent `start(book:)` race.** Opening book B while A was loading could mix A's sentences with B's metadata and stop B if A failed. `loadToken` and an active-book check after every `await` make stale starts harmless.
- **Transport while loading.** Next/previous/seek now no-op while sentences are still loading; `finishBook` stops audio and cannot mark an empty book complete.
- **Wrong chapter for Mac page callbacks.** Word taps and text selections now carry the originating page's chapter instead of using the current `pageIndex`; this also fixes the equivalent iOS page-curl race.
- **PDF marked finished before loading.** The PDF progress writer now refuses to save when `pdfPageCount` is zero.
- **Mac stale text colour after theme change.** The page text storage is refreshed when the `ReaderPageStyle` changes, not only when the characters change.
- **Highlights crossing pages disappeared.** `ReaderPage.localRange` clips chapter ranges to the page before mapping to local text.
- **Bookmark positions depended on the current pagination.** Bookmarks are saved and matched by chapter + normalized page fraction, and the jump path recomputes the page from that fraction. Restoring a page no longer has the `k/n` vs `k/(n-1)` off-by-one, and repagination after a font/window change preserves the relative position.
- **Editing a note from the Notes tab did nothing.** The navigation sheet is dismissed before the editor sheet is presented.
- **PDF reflow work was uncancellable.** Extraction now cancels with the view, validates that referenced images exist before trusting a manifest, shows a failed image instead of an endless spinner, aligns region overlays to the fitted page, and deletes the reflow cache when the book is deleted.
- **Share Extension web links failed and file URLs took the HTTP path.** The specific file-URL type is checked first, downloaded pages use the MIME-derived filename/extension, staging validates the actual file, partial staging is rolled back, failed imports keep the shared payload for retry, and Cancel actually stops the staging task.
- **Import size limits.** Documents are capped at 250 MB before extraction; EPUB entries are capped at 64 MB and 256 MB total extracted bytes.
- **CloudKit deletions and downloads.** Tombstones use the local deletion time, partial failures are inspected, remote files are deleted only after a successful tombstone, outdated tombstones are not re-enqueued on every sync enable, downloads are deduplicated and size-checked, interrupted `.downloading` states are reconciled, and a missing zone resets the change token and recreates the zone.
- **Voice model changes while narrating.** Selecting/deleting a model now stops and restarts the current sentence safely; in-flight synthesis is serialized, stale engine loads are ignored, and cache generation is cancelled when the voice changes.
- **Kokoro offline startup.** Installed Kokoro bundles are loaded from the local directory instead of re-fetching `HostedManifest.json` on every launch; engine loads are shared, and failed states are cleared after a successful load.

## Remaining known risks

These are documented rather than silently ignored:

1. **CloudKit live sync still needs signed two-device validation.** The unsigned simulator cannot prove server behavior, schema deployment or the App Group.
2. **Child records can still be lost across record pages.** A membership/bookmark/annotation whose parent arrives in a later pull page is skipped while the token advances; push order is now parent-first, which removes the common case. A durable deferred-children queue is the next step.
3. **iCloud file and container work runs on the main actor.** `url(forUbiquityContainerIdentifier:)`, whole-file copies and cover `Data(contentsOf:)` can block the UI on slow iCloud Drive. Moving `ICloudDocumentStore` off the main actor is the next performance fix.
4. **In-flight sync is not force-cancelled when sync is disabled.** Generation checks stop it from overwriting the disabled state, but the current push/pull call can finish its current request.
5. **PDF Intelligent Reading does not expose bookmarks/notes or follow a page jump.** Original PDF has a contents/jump slider; the reflowed view does not yet synchronize `jumpToPage`.
6. **iOS page host cache is unbounded.** Hosts for visited pages keep their `UITextView`/TextKit layout until repagination. Very long books should evict non-adjacent hosts.
7. **Remote cover cleanup.** Clearing a custom cover removes the local file but not the iCloud cover; a cloud-only device can restore the old cover. Cover filenames are now sanitized and local covers are preserved when present.
8. **Hugging Face token is stored and verified but no current public bundle requires it.** Gated 40M Phonon weights remain unavailable for the same reason documented in `MODEL_LICENSES.md`.
9. **No global accessibility/performance audit yet.** VoiceOver, Reduce Motion, contrast and large-library profiling remain Milestone 8 work.

## Verification

- iOS Simulator build: pass.
- macOS build: pass.
- 20 unit/integration tests: pass (including new path, page-clipping, tombstone and suspension tests).
- 9 UI tests: pass; the iPad-specific capture test is skipped on iPhone and was run separately on iPad: pass.
- macOS clean QA bundle: main window plus a dedicated Reading window, no crash.
