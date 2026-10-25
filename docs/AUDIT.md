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

## Second audit pass

The follow-up pass concentrated on recently changed code plus sync, narration and
platform navigation. The following real defects were corrected:

- **Sync suspension was ineffective.** The `didSave` observer used `queue: .main`,
  so its block ran after `withSuspendedRecording` had already been reset. Every
  remote apply was re-enqueued, creating a push/pull echo. The observer now runs
  synchronously on the posting thread (`queue: nil`), and the unit test yields to
  the main queue before asserting.
- **Pulls resurrected locally deleted items.** `applyRemote*` checked timestamps
  but not local tombstones, so a deletion whose push was queued or backing off
  could be undone by the next pull. A newer local tombstone now wins; a remote
  record newer than the deletion discards the stale tombstone instead.
- **Synced reading mode and preferred voice did not bump `updatedAt`.** A remote
  edit could silently overwrite a local change. Both setters now call `touch()`.
- **Same-book narration kept a stale mode.** Tapping a word while the same book
  was active in `.read` started audio without the read-along UI. The mode is now
  updated before the fast-path playback.
- **Sentence navigation retained the old word range.** Next/previous/seek could
  highlight a bogus word and resume from an out-of-range offset, speaking only
  the last character. `move(to:)` resets word state and offsets past the end fall
  back to zero.
- **Bookmark matching collided in long chapters.** A fixed 0.015 fraction
  tolerance treats adjacent pages as the same page once a chapter has ~68 pages.
  The tolerance now scales with the current chapter's page count.
- **Deleted books could leave orphan audio.** `forgetDeletedBook` now cancels
  cache generation, waits for the in-flight task and removes the cache again.
- **Read & Listen did not start following after a mode change.** Changes to
  `followNarration` and the narration chapter now trigger page following.
- **PDF narration used the array index as a page id.** A PDF page with no text
  shifted the start page, and progress saved array indices. PDFs now resume by
  original page id and preserve that page in the locator.
- **EPUB title stripping ate body text.** A nav title of “I” or “A” removed the
  first letter of “It…” / “A tale…”. The title is stripped only at a whitespace
  or line boundary.
- **Share extension lost extensions.** Providers returning extensionless temp
  files now get the preferred extension before validation. Oversize files are
  rejected before the App Group copy, and stale/orphan staging directories are
  swept.
- **Import froze the main actor.** Copying, size checking, hashing and extraction
  now run in one detached task. Cover generation stays on the main actor because
  `ImageRenderer` requires it.
- **Mac/iPad search could hide results.** Typing with a subcollection pushed left
  the search results under the old navigation stack. Search and sidebar changes
  now reset the detail path.
- **Deleting a collection could strand the sidebar selection.** Deletion now
  snapshots the subtree ids before the model is deleted and resets selection.
- **Mac Home “See all” was a no-op**, the Mac reader fallback used black text on
  black, and the bare Space shortcut stole spaces from text fields. These are
  corrected; Space inserts text when an editable text view is focused.
- **PDF reflow tables could drop prose.** Only wholly tabular blocks are replaced
  by a table image; mixed paragraphs keep their text.
- **Kokoro could look installed after a partial download.** Every path listed in
  the runtime manifest is checked, and loaded engines are assigned only after the
  install token is revalidated.
- **Small UI state errors:** per-row voice-sample state, default-voice VoiceOver
  state, filter-empty Library messaging, cover filename collisions, and a 0.25 pt
  Mac pagination width mismatch.

A new unit test covers the EPUB title-prefix case. The suite is now **21 unit
tests plus 9 UI tests**.

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
10. **PDF text extraction is capped at 80 pages.** `DocumentExtractor` indexes only the first 80 text-bearing pages; narration on a longer PDF stops at that point and `finishBook` still marks the book finished. Fixing this needs either full extraction or a stored PDF page count so completion can be distinguished from truncation.
11. **A failed parent push can still lose its children.** Parent-first ordering helps one pass, but if a Book/Collection upsert fails while a Membership/Bookmark/Annotation succeeds, the child can be skipped on another device and never re-delivered. A deferred-child fetch after the parent applies is the next sync fix.
12. **Import cover generation and search remain synchronous on the main actor.** `CoverGenerator` uses `ImageRenderer`; search still scans every book’s capped `searchText` on each keystroke. Both need background/debounced work for large libraries.
13. **Retained share failures are retried on every activation for up to 24 hours.** They are now eventually discarded and orphan staging dirs are swept, but there is no UI to discard a bad payload immediately.
14. **Engine install/delete races remain.** A cancelled Phonon download can finish its final move after deletion, and `delete` does not await the install task. The engine assignment token check prevents using the new engine, but the on-disk bundle may reappear and be reported installed on the next launch.
15. **Main navigation is app-scoped, not scene-scoped.** Multiple macOS/iPad windows share `NavigationModel` and `ImportCoordinator`, so tab/sidebar selection and import alerts mirror across windows.
16. **PDF Intelligent Reading still derives the source page from a uniform scroll fraction** and does not expose bookmarks/notes or page jumps; the 80-page extraction cap also limits its searchable text.
17. **`LibraryService.save()` still reports failures only via `assertionFailure`.** In a release build a disk-full/corrupt-store save can leave files and SwiftData rows out of sync (for example a deleted document whose row survives, or a cover whose import row was removed). Making saves throwing and rolling back is the next data-integrity fix.

## Verification

- iOS Simulator build: pass.
- macOS build: pass.
- 21 unit/integration tests: pass (including the new EPUB title-prefix test).
- 9 UI tests: pass; the iPad-specific capture test is skipped on iPhone and was run separately on iPad: pass.
- macOS clean QA bundle: main window plus a dedicated Reading window, no crash; the final build was launched with both `-NodusSampleLibrary` and `-NodusOpenSampleReader` and remained running.
- Visual audit (iPhone, iPad, Mac; Light, Sepia, Dark and High Contrast): complete; findings and remaining visual notes are in [`VISUAL_AUDIT.md`](VISUAL_AUDIT.md).
