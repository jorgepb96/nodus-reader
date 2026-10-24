# Roadmap and Status

Last updated: 2026-10-24.

## Milestone 1 — Native Multiplatform Foundation — **implemented**

- [x] Read `design/` and record the permanent design directive in `CLAUDE.md`.
- [x] One multiplatform target for iOS/iPadOS/macOS (`supportedDestinations`).
- [x] `DesignSystem` package with tokens, themes, typography, NodusMark, ReaderMark and shared components.
- [x] App icon from `design/icon/` (dark, light, tinted, macOS sizes).
- [x] Adaptive navigation: `TabView` + search role on iPhone, `NavigationSplitView` on iPad and Mac.
- [x] Home with Continue card, source-device eyebrow and Up next shelf.
- [x] Library: iPhone grid/list, iPad 5-column grid, Mac table/grid, search, filters, sorting, selection, context menus.
- [x] EPUB and PDF import; TXT, Markdown, HTML and RTF support.
- [x] Embedded covers, PDF thumbnails, deterministic typographic covers and custom covers.
- [x] Hierarchical collections, multi-membership, manual order, rename/move/delete without deleting books.
- [x] SwiftData local persistence and file store.
- [x] Settings with separate App/Reader themes, custom themes and typography.
- [x] Unit/integration tests and UI screenshot tests.
- [x] Reader and system-voice narration were implemented ahead of their milestones to validate the end-to-end experience.

## Milestone 2 — Advanced Document Import — **partially implemented**

- [x] Registered document types and Open In/Open With URLs.
- [x] Multi-file document picker (Files/Finder).
- [x] Drag & drop onto the app window (root `dropDestination`).
- [x] Duplicate detection and Inbox assignment.
- [ ] Share Extension with App Group staging.
- [ ] Recursive folder import and security-scoped bookmarks.
- [ ] Import progress UI beyond the toast, cancellation and retry controls.
- [ ] "Open in Nodus Reader" from other applications in all target scenarios.

## Milestone 3 — Reading Experience — **partially implemented**

- [x] EPUB text reading with chapter navigation and contents sheet.
- [x] PDF original reading with PDFKit, page tracking and outline/page navigation.
- [x] Reading themes, custom themes, typography, justification, margins.
- [x] Persistent chapter/page progress.
- [x] Sentence and word narration highlighting, tap-to-play (iOS text reader).
- [ ] Pagination, page-curl transition and dual-page spread.
- [ ] CFI or equivalent stable locators for EPUB.
- [ ] Bookmarks, highlights, notes and export.
- [ ] In-book search UI.
- [ ] Footer notes, footnotes, image zoom and table rendering in EPUB.
- [ ] Immersive auto-hiding reader chrome.

## Milestone 4 — iCloud Library Sync — **not implemented**

The Settings screen reports “Local only”. See `docs/ICLOUD.md` for the planned CloudKit/iCloud Documents architecture, conflict rules and device test procedure.

## Milestone 5 — Intelligent PDF Reader — **not implemented**

- Text extraction and columns exist only as import-time search text.
- Missing: reading-order reconstruction, tables, figure captions, OCR, reflow cache, original-page overlay and region toggles.

## Milestone 6 — Offline Neural TTS — **partially implemented**

- [x] Modular playback controller and voice catalog.
- [x] Real local narration using system voices.
- [x] Voices screen with search, quality/language filters, samples, favorites and default voice.
- [x] Compact mini player and expanded player.
- [x] Background audio session, Now Playing metadata and iOS remote commands.
- [ ] Kokoro 82M adapter.
- [ ] Phonon 31M / 40M Spanish / 40M Multilingual adapters.
- [ ] Hugging Face model catalog/downloads/resume/hash validation.
- [ ] Models screen with real downloads; the current screen honestly reports no neural engine installed.
- [ ] Neural word timings and audio cache (Milestone 7 dependency).

## Milestone 7 — Immersive Read & Listen — **partially implemented**

- [x] Sentence-level highlighting.
- [x] Word-level highlighting with system voice timings.
- [x] Tap a word to start narration from that word (iOS/iPadOS text reader).
- [x] Automatic chapter following in Read & Listen.
- [x] Speed, voice, sleep timer and modes.
- [x] Progress persistence with source device.
- [ ] Audio cache generation, partial state, prefetch, cancellation and deletion.
- [ ] Word tap in PDF Original and macOS paragraph tap.
- [ ] Reliable word timing for neural engines (engine timings or forced alignment).
- [ ] “Follow narration” toggle and page/TTS decoupling controls.

The detailed requirement is in [`docs/NARRATION_SYNC.md`](NARRATION_SYNC.md).

## Milestone 8 — Stabilization & Distribution — **not started**

- [ ] Full accessibility audit (VoiceOver, Dynamic Type, contrast, Reduce Motion).
- [ ] Performance work for large libraries and long books.
- [ ] Final design fidelity review.
- [ ] Licence audit and app-store policy check.
- [ ] TestFlight and macOS distribution/notarisation.
- [ ] Reproducible real-device iCloud test procedure.

## Known deviations from the design (documented, not accidental)

| Area | Design | Current build | Plan |
|---|---|---|---|
| iPhone mini player | `tabViewBottomAccessory` on iOS 26 | Stable `safeAreaInset` above the tab bar | Revisit when a stable accessory API/invalidation pattern is available; the accessory branch reset all tab state when playback started |
| Reader pagination | Pages, page curl, dual page | Continuous justified text, chapter navigation | Milestone 3 |
| Reader chrome | Auto-hides while reading | Always visible | Milestone 3, together with text selection |
| Mac reader | Separate window with Contents/Bookmarks/Notes sidebar and two-page spread | Reader sheet with contents sheet | Milestone 3 |
| PDF | Original + Intelligent Reading | Original PDF only | Milestone 5 |
| iCloud | Sync screen with storage/download controls | “iCloud & Storage” reports local-only | Milestone 4 |
| Voices/Models | Kokoro/Phonon catalog | Real system voices; neural models honestly marked absent | Milestone 6 |
| Mac inspector | No action buttons at the bottom | Same; Read/Read & Listen live in the context menu/double-click | Matches design |
| Sample content | Moby-Dick et al. | Real generated EPUB/PDF files, public-domain or original placeholder text | Debug-only |

## Immediate next steps

1. Add the Share Extension and folder import (Milestone 2).
2. Implement pagination and stable EPUB locators (Milestone 3).
3. Implement the CloudKit/iCloud Documents sync core and conflict resolver (Milestone 4).
4. Build the `NarrationEngine` abstraction, then the Kokoro adapter and the audio cache/alignment pipeline (Milestones 6–7).
5. Complete the accessibility and visual fidelity audit on real devices.
