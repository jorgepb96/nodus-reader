# Visual Audit — 2026-10-25

Scope: every shipped screen on iPhone, iPad and Mac; light, sepia, dark and
High Contrast themes; the reader in both normal and Read & Listen modes; menus,
search fields, covers, sheet sizing, spacing, touch targets and transitions.

## Corrected in this pass

- **Library search moved into the content area** under the title, with a custom
  capsule field sized like the design. Search now also matches annotation quotes
  and notes, and the clear button has an explicit label.
- **Home scales by platform.** Continue-card covers, Up next covers, spacing and
  button widths now grow on iPad and Mac instead of using one fixed iPhone size.
  The Continue card always has its eyebrow; when the last position came from a
  different device it reads “Continue · from your Mac/iPad/iPhone”.
- **Reader chrome** uses 44 pt targets for back, contents, bookmark, Aa and page
  chevrons. The status bar is hidden on iOS, the page area fills the window, and
  the reader follows the app theme by default (dark, light, sepia, OLED or High
  Contrast). Custom theme colour edits repaint immediately.
- **Tab bar colour bleed.** iOS 26 samples the glass tab bar from the content
  underneath it. Each tab now draws a short gradient into the app background
  behind the bar; bright covers and labels no longer leak into the pill or the
  home-indicator strip, and scrolling text fades instead of being cut with a
  hard edge.
- **Theme tiles in Light mode.** Tiles without a theme-specific border inherited a
  hard-coded white stroke, which disappeared on the cream Light/Sepia background.
  The fallback border now comes from the active palette, so Light is visible next
  to the other tiles in every app theme.
- **High Contrast controls.** Outline buttons and the dashed custom-theme control
  used a 35%-opacity accent border. The palette now carries `isHighContrast` and
  those controls use a full-strength text-colour border (1.5 pt) in that theme.
- **Read & Listen highlight.** The sentence range included trailing whitespace and
  newlines, so TextKit painted the highlight to the end of the final line. The
  range is trimmed before drawing, and the sentence background now stops at the
  last glyph. Word highlights use the same trimming.
- **iPad Settings.** The form sheet clipped rows at its bottom edge. Settings now
  uses a full page sheet with a centered 820 pt content column; all General rows
  are visible and the 3 × 2 theme grid keeps a readable width.
- **Mac Library.** The toolbar Import action is a labelled accent pill rather than
  an unlabelled icon, and table covers were enlarged from 30 × 45 to 34 × 51 pt.
  The Library sort label now places the ⇅ icon before “Sort”, matching the design.
- **Sample-bookmark cleanup.** The debug `-NodusResetReadingState` fixture now
  removes bookmarks left by earlier runs, so the Bookmarks sheet shows one
  deterministic entry instead of accumulating duplicates across test runs.

## Verified

- Real screenshots in `docs/screenshots/` for iPhone (20 screens), iPad (5) and
  Mac (Library window), captured from the running app.
- Light, Sepia and High Contrast phone captures were reviewed for contrast,
  cover legibility, tab-bar treatment and theme consistency; final documentation
  captures use the default Dark theme.
- Library sort and Voices filter menus open as native iOS 26 glass menus; labels,
  checkmarks and row heights are readable. Other menus, pickers, context menus
  and sheets use the same native components.
- Page-curl pagination, bookmark addition, Read & Listen word tap, player
  transport, model/voice filtering and PDF reflow are exercised by the UI suite.
  The mini player uses a move-plus-fade transition above the tab bar.
- iPhone UI suite: 9 tests pass (iPad capture test skipped on phone); iPad capture
  suite passes separately. macOS build and all 21 unit tests pass.

## Remaining visual notes

1. The iOS 26 floating tab bar is translucent by platform design. The new
   background gradient keeps it visually clean, but it is intentionally not a
   hand-drawn opaque bar.
2. The Mac reader remains a dedicated two-page window rather than the design’s
   persistent contents sidebar; this is the accepted deviation documented in
   `DESIGN_FIDELITY.md`.
3. PDF Intelligent Reading still lacks bookmarks/notes and page-jump sync in the
   reflowed view; the original-page panel has them.
4. Full VoiceOver traversal, Reduce Motion handling for page transitions and
   large-library performance profiling remain part of the accessibility pass.
