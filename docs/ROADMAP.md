# Roadmap and Status

Last updated: 2026-10-25.

Nodus Reader is no longer a milestone shell. The reader, pagination, annotations,
Share Extension, PDF Intelligent Reading, optional iCloud sync, Phonon/Kokoro
engines, partial audio cache and word alignment are implemented. What remains is
real-device validation and distribution work, plus explicitly documented model
limitations.

## Implemented

### Foundation and library

- [x] One multiplatform target for iOS/iPadOS/macOS.
- [x] `DesignSystem` package with tokens, themes, typography, marks and shared controls.
- [x] Adaptive navigation: `TabView` + search role on iPhone, `NavigationSplitView` on iPad and Mac.
- [x] Home, Library, Collections, Search and Settings.
- [x] EPUB, PDF, TXT, Markdown, HTML and RTF import; duplicate detection; covers; custom covers.
- [x] Hierarchical collections, multiple memberships and manual order.
- [x] SwiftData local persistence and file store.

### Reading

- [x] TextKit pagination with chapter-aware page ranges and persistent locator.
- [x] iOS page-curl transition through `UIPageViewController`.
- [x] Two-page spread and native page text view on macOS.
- [x] Reader themes, custom themes, typography, margins and justification.
- [x] Contents, bookmarks, highlights, notes, annotation colours and notes export.
- [x] Text selection menus for Highlight and Add Note.
- [x] PDF original rendering with PDFKit.
- [x] PDF Intelligent Reading: reading-order reconstruction, multi-column handling,
      repeated-header filtering, Vision OCR fallback, table crops, original-page
      overlay and a versioned cache.

### Narration

- [x] System voices through `AVSpeechSynthesizer` with native word ranges.
- [x] Kokoro 82M Core ML through the pinned `mattmireles/kokoro-coreml` SDK
      (English, starter voice `af_heart`).
- [x] Phonon 31M Core ML through the pinned `ptts` 0.4.1 Swift package and the
      `mosiah/phonon-31m-en-coreml` Apache-2.0 bundle (English, nine voices).
- [x] Sentence and word highlighting for neural engines using pause detection and
      syllable-weighted dynamic programming.
- [x] Tap a word to start narration at that word.
- [x] Partial per-sentence audio cache, automatic caching while listening,
      “Generate for this book”, progress, cancellation and per-book/global deletion.
- [x] Player transport, speed, voice picker, sleep timer, modes, mini player and Mac player bar.
- [x] Background audio session, interruptions, route changes and iOS remote commands.
- [x] Model manager with Hugging Face downloads, hash verification by the SDKs,
      pause/resume, deletion, storage accounting and optional Keychain token.

### Sync and sharing

- [x] Share Extension with an App Group inbox; the extension only stages files and
      the app performs parsing, hashing and cover generation.
- [x] Optional iCloud sync: private CloudKit zone for metadata, annotations and
      positions; iCloud Documents for originals and covers.
- [x] Durable SwiftData outbox, tombstones, timestamp conflicts, retries.
- [x] `Remove Download` versus `Delete from Library`, cloud-only badges and
      download-on-open.
- [x] Sync settings screen with real status, availability, pending queue, storage,
      cloud-only book list, download all and troubleshooting.
- [x] `NSMetadataQuery` discovery for iCloud placeholders and download polling.

### Verification

- [x] 27 unit/integration tests, including word alignment, language-aware voice
      selection and the durable sync outbox.
- [x] 9 UI tests covering the phone screens, reader, page turn, bookmarks, PDF
      Intelligent Reading, system/neural narration, the book-language voice filter and
      iCloud settings.
- [x] Screenshots captured from the simulator.

## Known limitations

| Area | Limitation | Reason |
|---|---|---|
| Kokoro languages | English raw text only | The pinned `KokoroTTS` SDK ships English Misaki phonemization in V1; Spanish voice embeddings exist but are rejected |
| Kokoro in Simulator | Not offered | The SDK's phonemizer uses MLX, which requires a Metal device; the Simulator aborts in MLX |
| Kokoro bundle | One voice (`af_heart`) | The pinned hosted starter bundle contains one voice; a full multi-voice bundle needs a separate hosted manifest |
| Phonon Spanish/Multilingual | Listed as unavailable, no download | The CC BY-NC 40M checkpoints are gated and no Core ML bundle is published; Nodus Reader does not offer downloads it cannot run |
| iCloud live validation | Build must be signed with the `iCloud.ai.nodus.reader` container | Unsigned builds deliberately report iCloud unavailable instead of crashing |
| iCloud conflict UI | Scalar last-writer-wins with timestamps; concurrent annotation edits keep the newer record | A recoverable side-by-side conflict UI is still future work |
| PDF tap-to-play | Original PDF page does not map taps to narration | Intelligent Reading reflow does; original-page mapping is future work |
| EPUB locators | Chapter + page/fraction locator, not CFI | Stable chapter offsets survive re-parses; CFI is future work |
| Translation | Interface is English | Strings are localization-ready |
| Theme/typography sync | Custom themes and reading preferences stay on the device | Plan §11–§12 item not implemented; see `docs/AUDIT.md` (independent audit) |
| Reader modes | Paginated only (page curl, or a slide with Reduce Motion); no vertical scroll or animation switch | Plan §8 item not implemented |
| Models | No “Install from file…” | Design `iPhone-Models` item not implemented |

## Not started or not validated

- [ ] Real-device CloudKit test with two Apple IDs/devices (the code path is built,
      but an unsigned simulator cannot validate the server).
- [ ] Share Extension end-to-end test with signed App Group entitlements.
- [ ] Full VoiceOver, Dynamic Type, contrast and Reduce Motion audit.
- [ ] Large-library performance profiling.
- [ ] App Store/TestFlight and notarised macOS distribution.
- [ ] Final licence audit before distribution.

## Known deviations from the design

| Area | Design | Current build | Plan |
|---|---|---|---|
| iPhone mini player | `tabViewBottomAccessory` on iOS 26 | Stable `safeAreaInset` above the tab bar | Revisit when a stable accessory API/invalidation pattern is available; the accessory branch reset tab state when playback started |
| Voices/Models | Kokoro and Phonon catalogue with multiple model filters | Real system voices plus one Kokoro model and one Phonon model; unavailable entries are explicit | Add more hosted bundles and runtimes when published |
| Phonon voices | Spanish and multilingual catalogue | English Phonon 31M only; Spanish system voices remain available | Add Core ML 40M bundles if the vendor publishes them |
| Mac reader | Separate window with inspector | Dedicated `Reading` window with a two-page spread; contents/bookmarks/notes are reached from the reader | The window can be taken full screen natively; add the inspector if required |
| Sample content | Moby-Dick et al. | Real generated EPUB/PDF files, public-domain or original placeholder text | Debug-only |
