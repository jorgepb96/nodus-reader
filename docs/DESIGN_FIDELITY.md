# Design Fidelity

The interface follows `design/DESIGN.md` and `design/screens/`. This document records what was compared, what matches, and every accepted deviation.

## Screenshot comparison

| Design | Implemented screenshot | Status |
|---|---|---|
| `iPhone-ReadingNow.png` | `docs/screenshots/iPhone-01-Home.png` | Matches layout, typography, cover language, Continue card and Up next. Native toolbar/nav bar adds standard top spacing. |
| `iPhone-Library.png` | `docs/screenshots/iPhone-02-Library.png` | 3-column grid, chips, sort, PDF badges, progress, toolbar. Filter chips overflow horizontally as in the design. |
| `iPhone-Collections.png` | `docs/screenshots/iPhone-05-Collections.png`, `iPhone-06-Collection.png` | Root collections plus breadcrumb/detail, subcollection cards, multi-membership text, manual order sheet. |
| `iPhone-Reader.png` | `docs/screenshots/iPhone-03-Reader.png`, `iPhone-13-ReadAndListen.png` | Light theme, chapter opener, justified serif, contents/Aa, progress, narration capsule, sentence + word highlight. Pagination/double page pending. |
| `iPhone-NowPlaying.png` | `docs/screenshots/iPhone-12-Player.png` | Cover, title, live 3-line context, scrubber, transport, speed/voice/sleep/mode grid, “Voice generated on this iPhone”. Real system voice names replace the illustrative Kokoro names. |
| `iPhone-Settings.png` | `docs/screenshots/iPhone-07-Settings.png`, `iPhone-08-Typography.png` | App/Reader segmented control, 6 theme tiles with “Aa”, selected ring/check, custom themes, general rows. |
| `iPhone-Voices.png` | `docs/screenshots/iPhone-09-Voices.png` | Real system voices, search, language/quality filters, samples, favorites, default badge. Kokoro/Phonon catalog is not available yet. |
| `iPhone-Models.png` | `docs/screenshots/iPhone-10-Models.png` | Honest empty state for neural engines; system voices installed. No fake “Get” buttons. |
| `iPhone-Sync.png` | `docs/screenshots` (not captured; screen exists) | Replaced by an honest “iCloud & Storage” local-only screen until Milestone 4. |
| `iPad-Library.png` | `docs/screenshots/iPad-01-Library.png` | Sidebar brand/smart lists/collection tree/footer, breadcrumb, 44 pt title, chips, 5-column grid, native controls. Search field is a visible native field in the sidebar. |
| `iPad-PDFReflow.png` | Not implemented | Milestone 5. Original PDF reader exists; reflow/source panel pending. |
| `Mac-Library.png` | `docs/screenshots/Mac-01-Library.png` | Inset sidebar, brand, smart lists/tree, Table with sortable columns, inspector with metadata/collections/status/voice/file, native toolbar. |
| `Mac-Reader.png` | `docs/screenshots/Mac-02-Reader.png` | Reader sheet with minimal top bar and justified text. Sidebar Contents/Bookmarks/Notes and two-page spread pending Milestone 3. |
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
- Separation of “Remove Download” and “Delete from Library” in the planned sync UI; the latter is destructive and confirmed.

## Accepted deviations

1. **iPhone mini player** uses a stable `safeAreaInset` above the native tab bar rather than `tabViewBottomAccessory`. The iOS 26 accessory branch recreated the `TabView` when playback started and discarded the Home state (including the player sheet). The stable approach preserves state and still places the capsule above the tab bar.
2. **Reader is a continuous justified text view**, not paginated. Page curl, dual page, auto-hiding chrome, text selection actions, bookmarks/highlights/notes and CFI locators are Milestone 3. A contents sheet and chapter navigation exist now.
3. **Mac reader is a sheet**, not a separate window with a Contents/Bookmarks/Notes sidebar and two-page spread. Same Milestone 3 scope.
4. **iPad reader is a single column**, not a two-page spread.
5. **Settings > iCloud Sync** is replaced by “iCloud & Storage”, which reports “Local only” and real storage usage. CloudKit/iCloud Documents are Milestone 4. The toggle is disabled and the screen explains why.
6. **Voices & Models** shows the real system voice catalog. The Models tab honestly says Kokoro/Phonon are not installed; no download buttons are simulated. Hugging Face integration is Milestone 6.
7. **Sample content** is generated at debug import time (public-domain prose or original placeholder prose). Titles/cover palettes are illustrative, as the design states.
8. **Mac inspector** omits the extra Read/Read & Listen/Delete buttons that briefly existed; those actions are available by double-click/context menu, matching the design’s inspector. The inspector fills with the most recently read book when nothing is selected.
9. **Theme segmented control** is a custom capsule (App/Reader) rather than the native segmented control, to match the design on both iOS and macOS.
10. **Sidebar search on iPad** is a visible native `TextField` styled as the design’s field; `.searchable(placement: .sidebar)` did not render a field in the split-view sidebar on the tested OS.

## Accessibility

- Icon-only controls have labels (`Import documents`, `Appearance and typography`, `Contents`, `Previous/Next sentence`, etc.).
- Theme tiles expose selected state; switches are native toggles.
- Reader and player controls are at least 44 × 44 pt; the transport play button is 76 pt.
- Dynamic Type is used for interface text; display titles scale through `@ScaledMetric`. Reader typography is user-adjustable.
- Remaining: full VoiceOver pass on every screen, Reduce Motion for page transitions (when pagination lands), and contrast verification for all custom themes.
