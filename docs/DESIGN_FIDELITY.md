# Design Fidelity

The interface follows `design/DESIGN.md` and `design/screens/`. This document records what was compared, what matches, and every accepted deviation.

## Screenshot comparison

| Design | Implemented screenshot | Status |
|---|---|---|
| `iPhone-ReadingNow.png` | `docs/screenshots/iPhone-01-Home.png` | Matches layout, typography, cover language, Continue card and Up next. Native toolbar/nav bar adds standard top spacing. |
| `iPhone-Library.png` | `docs/screenshots/iPhone-02-Library.png` | 3-column grid, chips, sort, PDF badges, progress, toolbar. Filter chips overflow horizontally as in the design. |
| `iPhone-Collections.png` | `docs/screenshots/iPhone-05-Collections.png`, `iPhone-06-Collection.png` | Root collections plus breadcrumb/detail, subcollection cards, multi-membership text, manual order sheet. |
| `iPhone-Reader.png` | `docs/screenshots/iPhone-03-Reader.png`, `iPhone-13-ReadAndListen.png` | Light theme, chapter opener, justified serif, contents/Aa, progress, narration capsule, sentence + word highlight. Paginated with page curl; macOS uses a two-page spread. |
| `iPhone-NowPlaying.png` | `docs/screenshots/iPhone-12-Player.png`, `iPhone-18-NeuralNarration.png` | Cover, title, live 3-line context, scrubber, transport, speed/voice/sleep/mode grid, offline-audio card, “Voice generated on this iPhone”. Real system/Kokoro/Phonon voice names replace the illustrative catalogue. |
| `iPhone-Settings.png` | `docs/screenshots/iPhone-07-Settings.png`, `iPhone-08-Typography.png` | App/Reader segmented control, 6 theme tiles with “Aa”, selected ring/check, custom themes, general rows. |
| `iPhone-Voices.png` | `docs/screenshots/iPhone-09-Voices.png` | Real system voices plus installed Kokoro/Phonon voices, search, model/language/quality filters, samples, favorites and default badge. |
| `iPhone-Models.png` | `docs/screenshots/iPhone-10-Models.png` | Real engine list with installed/downloading/paused/unavailable states, licences, model-card links, Hugging Face token, storage and delete actions. |
| `iPhone-Sync.png` | `docs/screenshots/iPhone-20-ICloudStorage.png` | iCloud opt-in, real status, last sync, pending count, Sync Now, storage split, cloud-only books, Download All and troubleshooting. |
| `iPad-Library.png` | `docs/screenshots/iPad-01-Library.png` | Sidebar brand/smart lists/collection tree/footer, breadcrumb, 44 pt title, chips, 5-column grid, native controls. Search field is a visible native field in the sidebar. |
| `iPad-PDFReflow.png` | `docs/screenshots/iPhone-16-PDFReflow.png`, `iPhone-17-PDFSource.png` | Intelligent Reading reflow and original-page panel implemented; iPad captures retain the original PDF layout. |
| `Mac-Library.png` | `docs/screenshots/Mac-01-Library.png` | Inset sidebar, brand, smart lists/tree, Table with sortable columns, inspector with metadata/collections/status/voice/file, native toolbar. |
| `Mac-Reader.png` | `docs/screenshots/Mac-02-Reader.png` | Full-window reader with the native two-page spread; the library sidebar and toolbar are hidden while reading and restored on close. |
| `Main.png` | App icon, `BrandToolbar`, palette, theme tiles | Tokens and marks match. |
| iPhone mini player | `docs/screenshots/iPhone-14-MiniPlayer.png` | Capsule above the native tab bar, cover/title/chapter/voice/speed and play/pause. |
| Mac player | `docs/screenshots/Mac-04-Player.png` | Bottom bar with transport, progress, speed, voice and Space hint. |
| `Icon-Options.png` | Asset catalog | Direction C “Pages” used for dark/light/tinted and macOS sizes. |

The screenshots are real simulator/window captures of the app with a debug sample library; they are not HTML renders.

## What follows the design

- Colour tokens, reader themes, corner radii, spacing, capsule controls, cover shadows and serif display/reading type.
- Brand composition `NodusMark + NODUS / READER`, with one accessibility element labelled “Nodus Reader”.
- Native navigation, search, menus, sheets, table, inspector, toggles and segmented controls; system chrome is never drawn by hand.
- Copy and information hierarchy from the designed screens.
- Multi-membership display (“Also in …”), download badges, progress, PDF badge.
- Separation of “Remove Download”, “Delete generated audio” and “Delete from Library”; only the last is destructive and confirmed.

## Accepted deviations

1. **iPhone mini player** uses a stable `safeAreaInset` above the native tab bar rather than `tabViewBottomAccessory`. The iOS 26 accessory branch recreated the `TabView` when playback started and discarded the Home state (including the player sheet). The stable approach preserves state and still places the capsule above the tab bar.
2. **Reader chrome stays visible** rather than auto-hiding; pagination and page curl are implemented, text selection menus create highlights/notes, and bookmarks/annotations are available. The iOS/iPadOS reader hides the status bar and fills the screen. EPUB locators are chapter/page-based rather than CFI.
3. **Mac reader is a dedicated window**, not a persistent sidebar inspector layout; it uses a two-page spread and native page view, fills the window and can be taken full screen with the standard window control.
4. **iPad reader uses a single page**, not a two-page spread.
5. **The reader follows the App theme by default** (Dark app → Dark page, Sepia app → Sepia page); the Appearance sheet still allows an explicit reader theme or custom theme.
6. **Settings > iCloud Sync** is titled “iCloud & Storage”; it contains the real opt-in, CloudKit/iCloud Drive status, last sync, queue, storage and per-book download controls. Unsigned builds show an explicit unavailable message instead of claiming sync.
7. **Voices & Models** lets the user select one voice engine (System, Kokoro or Phonon); only that engine's voices appear in the reader/player lists. The voice picker starts with the book's detected language and offers an explicit All languages menu. Kokoro is English-only and unavailable in the Simulator; Phonon 40M Spanish/multilingual are displayed as unavailable with the reason, never as fake downloads.
8. **Book covers** always render a deterministic typographic cover underneath the stored artwork, so a missing or still-loading file never leaves an empty cell.
9. **Sample content** is generated at debug import time (public-domain prose or original placeholder prose). Titles/cover palettes are illustrative, as the design states.
10. **Mac inspector** omits the extra Read/Read & Listen/Delete buttons that briefly existed; those actions are available by double-click/context menu, matching the design’s inspector. The inspector fills with the most recently read book when nothing is selected.
11. **Theme segmented control** is a custom capsule (App/Reader) rather than the native segmented control, to match the design on both iOS and macOS.
12. **Sidebar search on iPad** is a visible native `TextField` styled as the design’s field; `.searchable(placement: .sidebar)` did not render a field in the split-view sidebar on the tested OS.
13. **Neural word timing is estimated** from real PCM pause analysis rather than engine-provided timings; the sentence timing is exact and the word estimate degrades gracefully when pauses are ambiguous.

## Accessibility

- Icon-only controls have labels (`Import documents`, `Appearance and typography`, `Contents`, `Previous/Next sentence`, etc.).
- Theme tiles expose selected state; switches are native toggles.
- Reader and player controls are at least 44 × 44 pt; the transport play button is 76 pt.
- Dynamic Type is used for interface text; display titles scale through `@ScaledMetric`. Reader typography is user-adjustable.
- Remaining: full VoiceOver pass on every screen, Reduce Motion behaviour for page transitions, and contrast verification for every custom theme.
