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

---

# Independent audit — 2026-10-25

An end-to-end pass that did not rely on the two audits above: every claim used
below was re-checked in the code, in the unit tests or in the running app.
Branch `zcode/sess-session3`, baseline `2b5ef3b`.

## Scope and platforms

- Read in full: `CLAUDE.md`, `design/PROMPT.md`, `design/DESIGN.md`, the
  `design/screens/` renders, every file in `docs/`, `README.md` and `PRIVACY.md`.
- Code reviewed: persistence and models, import (`LibraryService`,
  `ImportCoordinator`, `FileStore`), Share Extension and App Group inbox, the whole
  sync stack (`SyncJournal`, `CloudSyncService`, `ICloudDocumentStore`),
  `PlaybackController`, `VoiceCatalog`, the reader (`ReaderView`, pagination, page
  curl), the player and the library context menus.
- Run: macOS app (fresh isolated home with `CFFIXED_USER_HOME`, sample library,
  main window, `Reading` window, narration and Settings launch paths); iPhone 17 Pro
  (iOS 26.5) and iPad Pro 13-inch M5 (iOS 26.5) simulators through the UI suite;
  unit tests on macOS; the DesignSystem package tests.
- Not possible here: signed CloudKit/iCloud Drive, the App Group with a signed
  Share Extension, Kokoro (needs a Metal device), real VoiceOver traversal on a
  device. Interactive control of the Mac app was declined for this session, so the
  Mac check is launch/liveness and window presence, not a click-through.

## Confirmed bugs fixed

| # | Severity | Where (baseline) | Trigger → consequence | Proof |
|---|---|---|---|---|
| 1 | Critical | `Features/Shared/BookCoverView.swift:68` | First launch of the Mac app with books in the library: the AppKit `Table` lays a cover cell out re-entrantly before the scene environment reaches it; the required `@Environment(LibraryService.self)` aborts with *No Observable object of type LibraryService found*. Matching crash reports exist from earlier builds (02:56 and 09:21). | Fresh-home launch without the fix: 3/3 crashes. With the fix (optional environment, falls back to the same shared `FileStore`): 3/3 stay running, plus the reader, narration and Settings launch paths. |
| 2 | Critical | `Core/Sync/SyncJournal.swift:87-88` | SwiftData posts `ModelContext.didSave` identifiers as `Array<PersistentIdentifier>` under the string keys `"inserted"`/`"updated"`; the journal subscripted with the enum and cast to `Set`, so every save produced an empty change set. **No insert or edit was ever recorded in the outbox.** With iCloud on, only the one-time `enqueueAll` on enable and explicit deletions were pushed; imports, progress, favourites, collections, bookmarks and notes made afterwards never left the device. The earlier "echo" fixes were never exercised for the same reason. | Probe test showed `didSave` delivered synchronously with the value type above and `pendingCount() == 0`. New test `syncJournalRecordsInsertsAndEditsFromSaves`. |
| 3 | High | `Core/Sync/CloudSyncService.swift:309` | The outbox entry was deleted after a successful push even if it had been re-enqueued while the push was on the network (two CloudKit round trips). A later edit was lost; a **delete recorded during an upsert was dropped**, so the book stayed in iCloud and on other devices while the local tombstone blocked its return here. | `SyncJournal.completePush` removes the entry only if `createdAt` and operation are unchanged. Test `outboxEntryReenqueuedDuringPushIsKept`. |
| 4 | High | `Core/Services/ImportCoordinator.swift:53` | A drop, Open With or picker result arriving while an import (or the Share inbox) was running returned silently: the files were never imported and no message appeared. | Requests are queued and drained in order, including after the Share inbox. Test `concurrentImportRequestsAreQueuedInsteadOfDropped` (failed before, passes now). |
| 5 | High | `ImportCoordinator` / `RootView` | The plan requires recursive folder import (Finder drag, Files). A folder URL reached `BookFormat(fileExtension: "")` and failed as *unsupported format*; the picker did not accept folders. | Folders are expanded recursively (hidden files and unsupported formats inside a folder are skipped, security scope kept open); `.folder` is allowed in the importer. Test `importingAFolderImportsSupportedFilesRecursively` (failed before). |
| 6 | Medium | `Core/Services/PlaybackController.swift:1268` | System-voice narration did not save the position when advancing sentences (the neural path did). A long listening session lost its position on quit/crash and never synced the narrated position. | Saves and resets the word range per sentence, like the neural path. Code parity; covered indirectly by the narration UI tests. |
| 7 | Medium | `CloudSyncService.swift:481` + download path | CloudKit `Book` records carry neither `searchText` nor `tocJSON`; a book that arrived from another device had no full-text search and no chapter titles, even after download. | `LibraryService.refreshExtractedTextIfNeeded` rebuilds both once the document is local (after download and on open), without touching `updatedAt` and without enqueueing a push. Test `syncedBooksRebuildSearchTextAndChaptersOnceLocal`. |
| 8 | Medium | `CloudSyncService.swift:830` | A remote tombstone applied during a (up to two-minute) iCloud download left the copied files on disk and the download code wrote into the deleted model. | After the await the book is re-fetched by id; if it is gone, its folder is removed and nothing is written. |
| 9 | Medium | `Features/Reader/ReaderView.swift:368` | Opening a cloud-only book that could not be downloaded (sync off or failure) still called `library.open`, marking it *In progress* and putting an unreadable book on the Home *Continue* card. | `open` runs only once the document exists locally. |
| 10 | Medium | `Pagination/IOSPageCurlReader.swift:25` | `DESIGN.md` → Motion: “Respect Reduce Motion … no page curl”. The reader always used `.pageCurl`. | With Reduce Motion the page controller is created with `.scroll` (finger-following slide; programmatic turns are already unanimated) and rebuilt when the setting changes. Not covered by a UI test. |
| 11 | Medium | `NodusShareExtension/ShareViewController.swift:296` | A shared web link was downloaded entirely into memory before the 200 MB check; extensions have a much smaller memory limit, so a large PDF link would kill the extension. | Downloads to a file, checks the size on disk, moves it into staging. Needs a signed App Group to exercise end to end. |
| 12 | Low | `Features/Library/LibraryComponents.swift:199` | *Remove Download* / *Download from iCloud* from a context menu failed silently (e.g. “This book has no iCloud copy yet”); the error was only visible in Settings. | The error is shown as an alert. |
| 13 | Low (design §4) | Player voice tile / voice picker | A per-book voice synced from another device but not installed here was silently replaced. The design asks to “show the book default with an Install voice affordance”. | The voice tile reads *Install voice* (highlighted, with an accessibility hint) and the picker explains the fallback and links to Voices & Models. |
| 14 | Low (a11y) | `BookCoverView` | The cover's accessibility label omitted the PDF badge and the iCloud download state that sighted users see. | Label now includes “PDF” and “in iCloud, not downloaded” / “downloading”. |

Checked and **not** a bug: writes to a `Book` after it was deleted (Mac Reading
window `onDisappear`, late narration saves) neither crash nor resurrect the row in
the current SwiftData; kept as the regression test
`progressWritesAfterDeletionAreIgnored`.

## Deviations from the design or the original plan (not changed)

These need a product or design decision, so they are recorded rather than
implemented:

1. **Custom themes and per-document reading preferences do not sync** (plan §11–§12).
   `SyncEntityType.theme`/`.preference`/`.readingPosition` exist but are unused;
   typography is global `UserDefaults` and there is no per-book typography.
   `docs/ICLOUD.md` did not say so; it does now.
2. **Reader modes:** no vertical-scroll mode, no selectable horizontal slide and no
   in-app “disable animations” switch (plan §8, §11). Only Reduce Motion is honoured.
3. **Models → “Install from file…”** (design `iPhone-Models`, plan §14) is not
   implemented and was not listed as missing anywhere.
4. **Downloading state** has no badge or progress on covers; only *cloud-only* has
   a badge (design §4: “downloading (progress)”).
5. **Design-system rule:** 36 hex literals remain in `Features/` (reader highlight,
   player tiles, cover badges, PDF overlays, theme picker, sync storage bar) instead of
   DesignSystem tokens (CLAUDE.md, DESIGN.md §1).
6. **Progress semantics:** progress is `(page + 1) / pages`, so a one-page document
   becomes *Finished* as soon as it is opened, and on the Mac spread the right-hand
   last page never counts (a short document can never reach *Finished* there).
7. Importing a file whose book already exists as **cloud-only** is reported as a
   duplicate instead of attaching the local copy.

## Declared but not implemented / documentation corrected

- `README.md` said “iCloud sync is optional and not enabled in this build”; sync is
  built and opt-in. Corrected.
- The docs and the previous audits describe the outbox as recording every save; that
  was false until fix 2.
- “9 UI tests pass” hid that `testNeuralVoiceNarration` **skips** when no Phonon
  bundle is in the simulator (it skipped in the baseline run here). It was run with a
  copied bundle for this pass; BUILD.md now says so.
- `PRIVACY.md` → Network access did not mention that the Share Extension fetches a
  shared web link from that site. Added.

## Residual risks (not fixed)

1. **Outbox cost now that recording works:** `SyncJournal.enqueue` fetches every
   outbox row per changed object and each save triggers a second journal save. Fine
   for small libraries; large libraries need an indexed fetch (predicate on type+id).
2. **Pagination runs on the main actor** (`TextPaginator.paginate` over the whole
   book); very long books block the UI while paginating and after font changes.
3. The 250 MB import limit is checked **after** the coordinated copy, so a huge file
   is copied before being rejected.
4. Signed CloudKit/iCloud Drive and Share Extension validation are still required:
   fixes 2, 3, 7, 8 and 11 are proven at unit level or by reasoning, not against the
   server.
5. Earlier open items 2–17 above remain as described (child records across pages,
   main-actor iCloud I/O, sync cancellation, PDF reflow bookmarks, unbounded page-host
   cache, 80-page PDF extraction cap, scene-scoped navigation, non-throwing saves).
6. No real-device VoiceOver/Dynamic Type traversal was possible here.

## Commands and results

| Command | Result |
|---|---|
| `xcodebuild … -destination 'platform=macOS' -derivedDataPath build/DerivedData-mac CODE_SIGNING_ALLOWED=NO build` | **Succeeded** (baseline and final) |
| `xcodebuild … -destination 'platform=iOS Simulator,id=<iPhone 17 Pro, iOS 26.5>' -derivedDataPath build/DerivedData-ios CODE_SIGNING_ALLOWED=NO build` | **Succeeded** (baseline and final) |
| `xcodebuild test … -destination 'platform=macOS' -only-testing:NodusReaderTests` | Baseline 21/21; final **27/27 pass** |
| `xcodebuild test … iPhone 17 Pro -only-testing:NodusReaderUITests` | Baseline 7 pass, 2 skipped (iPad test; Phonon test without a bundle). Final: **8 pass, 1 skipped** (the iPad-only test); `testNeuralVoiceNarration` ran and passed with a Phonon bundle copied into the simulator |
| `xcodebuild test … iPad Pro 13-inch (M5) -only-testing:NodusReaderUITests/NodusReaderUITests/testPadScreens` | **1/1 pass** |
| `swift test --package-path Modules/DesignSystem` | **1/1 pass** |
| macOS app, fresh home, `-NodusSampleLibrary` (+ `-NodusOpenSampleReader`, `-NodusStartSampleNarration`, `-NodusOpenSettings`) | Without fix 1: 3/3 crash at launch. Final: running, `All Books` and `Reading` windows present |

The stale UI-test runner was uninstalled from both simulators
(`xcrun simctl uninstall <device> ai.nodus.reader.uitests.xctrunner`) before each
UI run. Note: two booted simulators are both named “iPhone 17 Pro” (iOS 26.2 and
26.5), so `name=iPhone 17 Pro` is ambiguous; use the device id.

No screenshots in `docs/screenshots/` were replaced in this pass; result bundles are
`build/UITests-Audit-iPhone.xcresult` and `build/UITests-Audit-iPad.xcresult`.

## Follow-up pass — main thread, focus and remaining items (2026-10-25)

Goal: close what the section above left open and make sure no work takes over
the main thread or the foreground.

### Main thread: work moved off it

| Before | Now |
|---|---|
| `TextPaginator` laid out the whole book with TextKit on the main actor, at open and after every font, theme or window change | Runs in a detached task (each pass owns its TextKit objects), cancelled by a newer pass; test `paginationRunsOffTheMainThread` |
| Full-text search scanned every book's `searchText` (up to 500 KB each) on the main thread on every re-render of Library/Search, not just per keystroke | Debounced (180 ms) and computed off the main actor from a snapshot; test `backgroundSearchMatchesTheSameBooksAsSearch` |
| `ICloudDocumentStore` was `@MainActor`: `url(forUbiquityContainerIdentifier:)` (documented as unsafe on the main thread) on every activation, whole-file copies, cover reads | All file work in background tasks; only the `NSMetadataQuery` starts on the main run loop |
| Cover JPEG decode on the main thread while grids scroll; same for PDF reflow images | Read and decoded (and pre-rendered on iOS) off the main thread |
| Import generated EPUB/PDF cover artwork on the main actor | Artwork in the background import task; only the typographic fallback (`ImageRenderer`) stays on main |
| Library, cover and model folder sizes walked on the main thread | Background tasks |
| `SyncJournal.enqueue`, tombstone and outbox lookups fetched every row per changed object | Predicate fetches with `fetchLimit` |

Narration synthesis was already off the main thread (Phonon on its own queue,
Kokoro is an actor, word alignment detached); unchanged.

### Foreground: nothing takes over the screen uninvited

- The Share Extension inbox kept a failed payload for 24 h and re-imported it,
  re-presenting the same alert **on every app activation**. Each payload is now
  attempted and reported once (“Share the document again to retry”).
- No code calls `NSApp.activate`, `orderFrontRegardless` or opens windows on its
  own; the Reading window opens only on an explicit open (or the DEBUG
  `-NodusOpenSampleReader` flag).
- Navigation is now per window/scene (`RootView` owns its `NavigationModel`; the
  Library menu acts on the focused window via `focusedSceneValue`), so two Mac or
  iPad windows no longer mirror each other.
- Failed saves no longer pass silently in release builds: the change is rolled
  back and one alert explains it (previously `assertionFailure` only).

### Remaining items fixed

- **Themes and reading preferences sync** (plan §11–§12) through one CloudKit
  `Preference` record; a fresh device adopts them instead of overwriting them.
  Test `syncedPreferencesRoundTripBetweenDevices`.
- **Page turn** setting: Page curl, Slide, Vertical (plan §8); Reduce Motion
  turns the curl into a slide.
- **Models → Install from file…** (design `iPhone-Models`): installs a complete
  local Kokoro/Phonon Core ML bundle folder; anything else is rejected with an
  explanation, nothing is converted or downloaded.
- **Downloading badge** on covers; **no hex literals** left in feature views
  (`DesignSystem/Tokens.swift`).
- **Progress:** restoring a position no longer rewrites progress; a one-page
  document is not Finished just by opening it; the Mac spread counts the
  right-hand page, so short documents can reach Finished there.
- **Cloud-only duplicate:** importing a file whose book exists only in iCloud
  attaches the local copy. Test `importingACloudOnlyBookAttachesTheLocalCopy`.
- **Import size limit** is checked before the coordinated copy.
- **Earlier open items closed:** child records across CloudKit pages (persisted
  deferred queue, retried every page); remote custom-cover cleanup; PDF narration
  and reading load every page (the 80-page cap now applies only to the import
  sample); PDF Intelligent Reading follows contents/bookmark jumps, keeps the
  position when switching from Original and maps scroll to real page numbers;
  the iOS page-host cache keeps only nearby pages; a cancelled model download
  that finishes after *Delete* is removed again.

### Still open (decision or validation needed)

1. **Per-document typography** (plan §11) needs a designed UI; preferences are
   global and now synced.
2. A **continuous (non-paged) scroll** reader mode is not implemented; Vertical
   is vertical paging.
3. **Highlights and notes inside PDF Intelligent Reading** (no selectable text
   layer in the reflow); bookmarks work by page in both modes.
4. **In-flight sync on disable** finishes its current CloudKit request; generation
   checks keep it from writing state.
5. **Signed validation** of CloudKit (including the new `Preference` record type,
   which must be deployed to production), iCloud Drive and the App Group, and a
   device VoiceOver pass.

### Verification for this pass

Same commands as the table above:

- macOS and iOS (iPhone 17 Pro, iOS 26.5) builds: **succeeded**.
- Unit tests (macOS): **31/31 pass**.
- UI tests iPhone: **8 pass, 1 skipped** (the iPad-only test), including the
  Phonon narration test.
- UI test iPad (`testPadScreens`): **1/1 pass**.
- DesignSystem package: **1/1 pass**.
- macOS app from a fresh isolated home with `-NodusSampleLibrary`, plus
  `-NodusOpenSampleReader`, `-NodusStartSampleNarration` and `-NodusOpenSettings`:
  running in all four cases.

Result bundles: `build/UITests-Audit2-iPhone.xcresult` and
`build/UITests-Audit2-iPad.xcresult`. No screenshots were replaced. Time spent in
the main thread was checked by code path (above), not with Instruments.

## Reader appearance, continuous reading and PDF notes (2026-10-25)

Implemented after the follow-up pass, at the product owner's request:

- **Appearance popover.** "Aa" opens a popover (also on iPhone) with theme,
  typography, reading mode and **This book only**. Global changes sync as
  preferences; a book's own appearance is stored in `Book.appearanceJSON` and syncs
  with the book. Settings › Reading & Typography uses the same component.
  Popovers and sheets presented from the reader take the palette matching the
  page's light/dark scheme: a light (Sepia) page previously produced dark labels on
  a dark panel. No interface string uses emoji (a "↕" label rendered as an emoji and
  was replaced by words; an error message arrow was replaced by "›").
- **Continuous reading** on iPhone, iPad and Mac: a vertical column and a horizontal
  strip of columns, both built from the same page-sized TextKit slices as paged
  mode, so page numbers, progress, bookmarks, contents jumps, narration follow,
  word taps and highlights behave the same. Reaching the end of the content counts
  as the last page. Known limit: a selection cannot cross a slice boundary.
- **PDF Intelligent Reading highlights and notes.** Text blocks are selectable with
  the reader's Highlight / Add Note menu. Notes are anchored to the original page
  and an offset into a canonical page text (independent of the image/header
  switches); if the reflow cache changes, they are found again by their quote. They
  are listed by page in the PDF contents sheet, open in Intelligent Reading and
  export as "Page n".
- **Models.** Synthesis moved into `ModelManager.synthesize` (used by playback), and
  an opt-in integration test downloads every model the machine can run, synthesizes
  and checks word alignment against the text (see `docs/BUILD.md`).

Verification for this change:

- macOS and iOS builds: **succeeded**.
- Unit tests (macOS): **36 pass**, plus the opt-in model test skipped by default.
- **Model downloads (opt-in test, real network, isolated home):** Phonon 31M
  (302 MB) and Kokoro 82M (364 MB) downloaded from Hugging Face through the same
  install path as the Models screen, loaded, synthesized a sentence each (non-silent,
  > 1.5 s) and the word alignment returned one timing per word, in text and time
  order, ending at the audio duration: **pass** (58 s). Kokoro cannot run in the
  Simulator (MLX needs Metal); it was verified on the Mac.
- UI tests iPhone 17 Pro (iOS 26.5): **10 pass, 1 skipped** (iPad-only), including
  the Phonon narration test (playback advances and the sentence highlight follows),
  the appearance popover with continuous vertical and horizontal scrolling, and PDF
  Intelligent Reading highlight + note.
- UI tests iPad Pro 13-inch (M5): `testPadScreens` and the popover/continuous test
  **pass**.
- DesignSystem package: **1/1 pass**. macOS app (fresh home): main window, Reading
  window and narration launch paths keep running.

## TestFlight launch crash (2026-10-25)

Build 0.1.0 (1), the first signed build, crashed on launch on device. Signed builds
carry the iCloud and App Group entitlements, and `ModelConfiguration` defaults to
`cloudKitDatabase: .automatic` and `groupContainer: .automatic`. SwiftData therefore
tried NSPersistentCloudKitContainer mirroring, which rejects this schema (unique IDs,
required relationships); the container failed to load and the app hit its
`fatalError`. Unsigned simulator builds never had the entitlements, so tests could
not see it. Reproduced with a signed Release simulator build; fixed by configuring
the store with `cloudKitDatabase: .none` and `groupContainer: .none` (sync is
`CloudSyncService`'s job; the store stays in Application Support). Regression test
`localStoreNeverUsesSwiftDataCloudKitOrTheAppGroup`; verified by relaunching the
signed Release build; shipped as build 0.1.0 (2). Lesson recorded in `docs/BUILD.md`:
check a **signed** build before uploading.

## Feedback from the first TestFlight build (2026-10-25)

- **Kokoro showed one voice.** The hosted starter bundle installs only `af_heart`;
  the pinned repository publishes 28 American/British English voices. They are now
  downloaded from the same pinned revision, each checked against its published
  SHA-256, added to the local runtime manifest (the SDK only accepts listed voices)
  and published as installed voices. Existing installs add them once. Verified on the
  Mac: 28 voices installed and synthesis with `bm_george` aligns with the text. Phonon
  already exposed all 9 voices it publishes.
- **System voices repeated languages.** Language menus were built from full codes
  (`en-US`, `en-GB`, …), each shown as "English". They now list base languages once;
  each voice row shows its variant ("English (United Kingdom)").
- **Overlapping toolbar buttons.** Hand-drawn circles inside the iOS 26 glass toolbar
  capsule; buttons are now plain icons and the system draws the capsule.
- **Tabs and Library.** iPhone tabs are Home, Library, Settings (gear, last); Library
  shows collections as folders above the books; Library and collections each have a
  search field. See `docs/DESIGN_FIDELITY.md`.

## Feedback from build 3: reading quality and responsiveness (2026-10-25)

- **Narration highlight hid the text.** Sentence/word/annotation tint was drawn by an
  overlay *above* the text view, and the narration colours are opaque. The overlay is
  now a sibling *below* the (clear) text view on iOS and macOS, so glyphs are always
  drawn on top.
- **EPUB text read in fragments.** `HTMLText` kept the source's hard line breaks
  (Project Gutenberg wraps every line) and replaced every tag with a space ("Morals ."
  after `</i>`). It is now a single-pass scanner with HTML whitespace semantics: line
  breaks inside a paragraph collapse to spaces, block elements become paragraph
  breaks, `<br>` a line break, inline tags add nothing, and footnote calls
  (`noteref`) and page numbers (`pagebreak`, `pagenum`) are left out so narration
  does not read "12" mid-sentence. Test `htmlTextJoinsWrappedLinesAndSkipsMarkers`.
- **Chapter detection.** Navigation fragments were dropped, so a file holding several
  chapters became one chapter named after its *last* contents entry. The parser now
  reads the ordered contents (EPUB 3 `toc` nav only, not landmarks or page lists;
  NCX `navMap` only), records element ids while converting, and splits each spine
  file at the anchors the contents point to. A file the contents never mention and
  that has no `<h1>`–`<h3>` continues the previous chapter. Hrefs resolve relative to
  the navigation file. A heading is only removed from the body when it is a whole
  paragraph. Tests `epubChaptersFollowContentsAnchors`; checked on two real DRM-free
  EPUBs (22 and 9 chapters with correct titles).
- **DRM.** An EPUB whose chapters are listed in `META-INF/encryption.xml` is reported
  as "protected with DRM" instead of being imported as ciphertext. Font obfuscation
  alone is accepted. Nothing is decrypted. Test
  `epubWithEncryptedChaptersIsReportedAsDRM`; checked on a real Adobe-DRM EPUB.
- **Text disappeared and took long to return after any appearance change.** Every
  change (including theme only) re-laid out the whole book behind a spinner. Now the
  pages on screen stay visible until their replacement is ready; a colour-only change
  recolours the existing pages without layout; a layout change lays out the chapter
  on screen first (shown at once, footer "Page x of y in this chapter") and then the
  whole book with every chapter in parallel, keeping the exact page. The first-open
  spinner is centred (GeometryReader placed it top-leading). Switching between paged
  and continuous reading reuses the same pages.
- **Import error "Couldn't communicate with a helper application."** File-provider
  coordination can drop its XPC connection. Staging now falls back to a direct copy
  under the security scope, accepts EPUB folder packages (zipped into a regular
  `.epub`, `mimetype` first), opens the security scope before checking whether a
  picked item is a folder, and explains provider failures in plain words. Test
  `importsEPUBFolderPackage`. The original file could not be reproduced here; real
  device validation with the user's file provider remains.
- **Lock screen / Dynamic Island artwork** now shows the book cover (or the same
  typographic cover the library draws).
- **Voices filters** are one row of icon chips (Model, Language, Quality) with an
  icon-only Clear button (44 pt, labelled "Clear filters"); the row scrolls sideways
  on the narrowest widths instead of wrapping.
- **Hugging Face guide.** The optional-token card links to a plain-English sheet:
  what Hugging Face is, that the downloadable models (Kokoro 82M, Phonon 31M) are
  public, how to create a Read token, how to accept a gated model's licence, and links
  to the gated models (Gradium Phonon 40M Spanish and Multilingual, which this build
  lists but cannot run because no Core ML version exists).

## Spanish interface (2026-10-25)

- The interface is localized in English (base language) and Spanish with one String
  Catalog, `NodusReader/Resources/Localizable.xcstrings`, shared by the app and the
  Share Extension. `CFBundleLocalizations` lists `en` and `es`; iOS shows Spanish when
  Spanish is the device's (or the app's) preferred language and English otherwise.
- Every user-visible string goes through the catalog: SwiftUI literals, alerts and
  menus; `String(localized:)` for model labels, errors, sync and import messages,
  toasts, the Now Playing labels, fallback chapter and page titles; and
  `LocalizedStringKey` initialisers on the DesignSystem components (`DisplayTitle`,
  `SectionHeading`, the pill buttons, `CapsuleChip`, `CircleIconButton`,
  `NodusEmptyState`). `Eyebrow` takes a `LocalizedStringResource` and resolves it
  before drawing: a localized `Text` with `.textCase(.uppercase)` also capitalises its
  VoiceOver label ("COLLECTIONS"), which the UI tests caught. Their `String` initialisers stay for data (book and collection
  names), which is never looked up as a key. Sentences that used to glue an English
  noun into a count ("3 results", "1 book is not downloaded…") are whole sentences
  now. Language names from `Locale` are capitalised ("Inglés").
- 634 keys, all translated; `tools/localization/gencat.py` regenerates the catalog
  from the compiler's extracted keys and reports missing translations and placeholder
  mismatches (0 and 0). Checked on the simulator in Spanish (Home, Library, Settings,
  Voices).
- UI tests read English labels and now launch the app with `-AppleLanguages (en)`, so
  they pass whatever language the simulator uses. Result: 42 unit tests pass; iPhone
  UI 10 pass + 1 iPad-only skip; iPad UI 2 pass; macOS build succeeds.
- Not translated: Info.plist document-type names, and names that come from data or
  the system (book titles, collection names, OS voice names such as "Default").

## Read-along timing, model memory and Hugging Face sign-in (2026-10-25)

- **Word highlight lagged the voice.** Causes found: the word clock was polled every
  60 ms (up to 60 ms late); the player's sample time counts audio handed to the
  hardware, not audio heard, and output latency was ignored (over Bluetooth the
  highlight even ran early); the highlight reaches the screen a couple of frames
  after it is set; and the aligner started each word in the middle of the preceding
  pause. Now the clock ticks per frame, subtracts the output latency the system
  reports, leads by 40 ms for drawing, and words start where the voice resumes.
  The real-model test then showed that moving boundaries could break their order, so
  they are kept increasing. Kokoro and Phonon do not expose word or phoneme timings
  through their public APIs (Kokoro computes durations internally but its
  `KokoroAudio` drops them), so timing remains an audio-based estimate.
- **Models stayed in RAM for the whole session.** A loaded engine was only released on
  uninstall or reinstall, and switching engines kept both. Now an engine is released
  three minutes after narration stops, immediately when the app goes to the
  background without narrating or on a memory warning (keeping only what playing
  narration needs), and the unselected engine is released when the engine changes.
  Kokoro's MLX buffer cache is cleared with it (MLX is linked directly, at the
  version Kokoro resolves, for that call), only when a loaded Kokoro is released and
  never in the Simulator: the UI tests caught that clearing the cache creates MLX's
  Metal device, which aborts where MLX cannot run. Verified with real models on the Mac:
  after synthesis, an idle release leaves no engine loaded and the next sentence
  reloads it; unit test `voiceEnginesAreReleasedOnlyWhenNarrationIsIdle`.
- **Sign in with Hugging Face** as an alternative to pasting a token: OAuth with PKCE
  as a public client (no secret in the app), scopes `openid profile gated-repos`,
  through the system authentication session; tokens and refresh tokens are kept in
  the device Keychain and refreshed when they expire. The client id is a Client ID
  Metadata Document in this repository (`oauth/huggingface-client.json`) served as
  JSON by jsDelivr at the `hf-oauth-v1` tag, so no app is registered on anyone's
  account; it must stay at that tag. Verified that Hugging Face accepts the client
  (its sign-in page opens in the app) and that cancelling is silent; unit tests
  cover PKCE (RFC 7636 vector), the callback checks and token decoding. The full
  sign-in needs a real account and is left to TestFlight.

## Reader sheets, popover labels and paragraph layout (2026-10-25)

- **Mixed themes in sheets and the "Aa" popover.** The reader forces its own colour
  scheme, but its sheets and popovers fell back to the app's. With a light app and a
  dark reader (or the reverse), the contents sheet showed a dark header with a black
  title over a white list with light text. Everything the reader presents (contents,
  appearance sheet and popover, player, annotation editor, PDF original-page panel)
  now goes through `readerPresentation(isDark:)`, which sets the palette, the SwiftUI
  colour scheme and `preferredColorScheme` for the system chrome together; list rows
  draw no background of their own. Checked on the simulator in Spanish with a light
  app and a dark reader.
- **Truncated reading-mode labels in Spanish.** Three segments share the popover's
  width; "Por páginas / Desplazar en vertical / Desplazar en horizontal" became
  "Páginas / Vertical / Horizontal", and the page-turn styles "Curva / Deslizar /
  Vertical". VoiceOver keeps the full descriptions.
- **Paragraph layout.** Paragraphs no longer have space between them and open with a
  first-line indent (1.5 × the font size); a chapter's first paragraph, short
  heading-like lines and the paragraph after them start flush. The extracted text
  keeps its blank line between paragraphs (chapter offsets for annotations, narration
  and bookmarks do not change), drawn with no height. PDF Intelligent Reading body
  blocks are indented too; lists and quotes are not. Test
  `readerParagraphsAreIndentedWithoutBlankLines`.

## Gated Phonon models after signing in (2026-10-25)

Signing in to Hugging Face did not make Phonon 40M Spanish or Multilingual
downloadable, and could not: Gradium publishes them only as PyTorch/Transformers
weights and GGUF, while the app's Phonon runtime (`PhononCore`, ptts 0.4.x) loads only
Core ML bundles and exposes no export function. No Core ML conversion of any 40M model
exists on Hugging Face, and the latest xn-ptts release (v0.4.2) ships only Phonon 31M
English as Core ML. Gradium's `export_coreml` tool can build one on a Mac with a token
for the gated repository; the result is not ours to republish (gated, CC BY-NC 4.0).
The Voices & Models screen now lists the public models first, then the Hugging Face
account section, then the gated models, each saying plainly that signing in does not
make it downloadable and why.
- **Follow-up: Phonon 40M Spanish converted for personal use.** The licence (CC BY-NC
  4.0) allows adapting the model for non-commercial use. The gate asks each person to
  share their details with Gradium, so the converted copy is not published. It was
  converted with Gradium's exporter (xn-ptts v0.4.1, same runtime as the app) from the
  owner's account, with the 25 Spanish voices of `gradium/phonon-voices`, and placed
  in the owner's iCloud Drive. The app recognises a Phonon bundle's language from
  `bundle.json`, installs Spanish into its own folder beside 31M English, loads it with
  Spanish text normalization, lists its 25 voices (Spain and Mexico), and switches
  checkpoints when the selected model changes. Verified with the opt-in test
  `convertedPhonon40SpanishBundleNarratesSpanish` on the Mac (install through Install
  from file, selection, Spanish synthesis with Lucía-Sol, word timings).
- **Follow-up: Phonon 40M Spanish converted on the device.** Instead of a Mac step,
  PhononCore is rebuilt with `ptts_export_coreml` (Gradium's exporter moved into
  `ptts-ffi`; patch and script in `Modules/PhononTTS/engine/`). Download → convert →
  install in Settings: the app takes the user's pasted token or OAuth sign-in, downloads
  `config.json`, `tokenizer.json` and `model.safetensors` from the pinned revision and
  the 25 Spanish voices from `gradium/phonon-voices`, verifies sizes and SHA-256,
  exports the Core ML bundle, deletes the weights and loads it. No token: a plain
  "sign in first" message; gate not accepted (HTTP 403): a message pointing to the
  model page. Opt-in test `phonon40SpanishConvertsOnDevice` passes on the Mac (23 s)
  and in the iPhone simulator (20 s), including Spanish synthesis; a real iPhone
  converts on its CPU and will take longer.

## Phonon 40M Multilingual, lock screen state, icon-only Select (2026-10-26)

- **Phonon 40M Multilingual** uses the same on-device path as Spanish
  (`PhononOnDeviceConversion.Spec`, pinned revision `1537ce4`, SHA-256 checks) with
  all 102 voices of `gradium/phonon-voices` (37 English including 12 character voices,
  25 Spanish, 15 French, 13 German, 12 Portuguese). Before speaking, the engine is
  switched to the selected voice's language, so numbers and abbreviations are read in
  that language. A Phonon bundle from a file is routed by `bundle.json` languages: `es`
  → Spanish 40M, several → Multilingual, otherwise 31M English.
- **Accented voice names.** The file system stores names such as "Noémie" or
  "Lucía-Sol" decomposed, while the app asked for them composed, so the engine (which
  compares bytes) rejected them. Voices are now matched by Unicode equivalence and the
  engine receives its own stored name. Caught by the opt-in conversion test.
- **Lock screen showed "playing" while nothing played.** Pausing or stopping a neural
  voice left the `AVAudioEngine` running (rendering silence), which iOS reports as
  playing; several stop paths also left Now Playing at rate 1. The engine is now paused
  with the player, Now Playing follows every play/pause change, and the audio session
  is released when narration is closed or the book ends. The ±30 s lock-screen buttons
  (which jumped chapters) are replaced by previous/next sentence.
- **Select** in the Library toolbar is icon-only (check circle, filled while
  selecting), labelled "Select"/"Done" for VoiceOver.
- Opt-in test `phonon40ConvertsOnDevice` converts both checkpoints and speaks Spanish
  (and, for Multilingual, French and English) on the Mac (79 s) and in the iPhone
  simulator (72 s).
