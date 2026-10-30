# Build 32 — PDF reader fixes and macOS parity

## PDF and EPUB readers

- A PDF reopened directly in Intelligent Reading (saved Read & Listen position) no longer stays on "Loading PDF…": the page count is read from the file when the reader opens, not from the PDFKit view, which Intelligent Reading never creates. Play is enabled at once.
- Read & Listen auto-scroll in Intelligent Reading no longer bounces. The next narrated page is already on screen and its text follows the spoken line, so the reflow no longer also snaps each new page to the top; only a seek to a distant page jumps. A jump uses one scroll instead of two competing ones, and a jump requested before the reflow loads is applied when it appears.
- Parity with EPUB: previous/next page buttons in the narration capsule work for PDFs (Intelligent Reading skips pages it did not analyse); progress is saved after the reader settles and only once a page is turned; opening a PDF note scrolls to the highlighted line; PDF bookmarks show their contents section instead of an English "PDF page N"; the notes export no longer labels PDF bookmarks as chapters.
- The original-page panel button is 44 × 44 pt. The narration capsule is a centred floating capsule (at most 640 pt) in wide windows. ⌘D toggles the bookmark.

## macOS

- iCloud sync no longer stops when the library window is minimised, in another Space or behind the Reading window: a Mac app keeps syncing while it runs.
- The sidebar footer (Mac and iPad) shows the real iCloud state instead of always "On this device · Local library".
- Library table columns sort, as the design specifies; the default order is last opened.
- The inspector's File row shows the real state (downloaded, in iCloud only, downloading) instead of always "Downloaded".
- Home uses the same Import toolbar capsule as the library instead of the iOS 44 pt "+" button.
- The Reading window no longer sets a second, app-level colour scheme that competed with the book's theme.

## Checks

| Check | Result |
| --- | --- |
| iPhone 17 Pro unit/integration suite | 127 passed, 0 failures |
| macOS unit/integration suite | 127 passed, 0 failures |
| iPhone UI: PDF Intelligent Reading, PDF highlights/notes, PDF contents + return to paused narration, PDF search + reflow scrollbar, paged reader + bookmarks, appearance popover + continuous scroll, centred transport | 7 passed, 0 failures |
| English/Spanish catalog | 711 keys, 0 missing Spanish, 0 placeholder mismatches |

`testPDFIntelligentReading` now resets the sample reading state: it depended on the Home order left by earlier runs.

Not verified here: the oscillation fix on a long real PDF on device, and live two-device iCloud sync on a signed Mac build.

## Distribution

Version 0.1.0 (32), archived from merge commit `0192678` ([PR #33](https://github.com/jorgepb96/nodus-reader/pull/33)). Both signed archives passed `codesign --verify --deep --strict`. The signed macOS archive app stayed running after launch (runpath `@executable_path/../Frameworks`); a signed Release simulator build launched and stayed running on the iPhone 17 Pro simulator.

Uploads succeeded through Xcode's account (`destination: upload`): macOS `Nodus Reader.pkg` first, then the iOS IPA. The **Internal** group receives both automatically. macOS stays internal only: no external macOS beta review. iOS 32 (`b72eb24d-4523-4991-ac3d-b21f09840a5e`) was added to **Nodus Reader — Public Beta**, submitted for Beta App Review and is **In testing** for both groups (53 invitations); the public link remains https://testflight.apple.com/join/SjCk8AZ1. macOS 32 (`0bfd5a27-d61f-4900-8828-e5a037b6780a`) is in **Internal** only. Both builds carry the [English](TestFlight-32-en.txt) / [Spanish](TestFlight-32-es.txt) What to Test notes.
