# Build 33 — macOS layout fixes

Build 33 contains build 32 plus fixes found by capturing the Mac windows. The captures are in `docs/screenshots/mac-build33/` (Spanish interface, isolated sample library). They are produced with the Debug-only `-NodusCaptureScreens` launch argument (`NodusReader/App/MacScreenCapture.swift`): the app draws each of its own windows to PNG, so no screen-recording or UI-automation permission is needed. Release builds compile none of it.

## Fixes

- Library table: no empty alternating grey bars under short lists; the Last opened column is wide enough for its title.
- Sidebar: the Library and Collections headings and the add-collection button use the muted colour and are readable on the dark sidebar; the footer stays on one line.
- Inspector: Change Cover and Reset are plain links; Status and Voice are text menus with a chevron instead of large white pop-up buttons; the add-to-collection control is the dashed circle from the design, not a white box; the file state uses the text colour.
- Shared `nodusMenuLabelStyle()` draws a menu's own label on macOS. Also used for the reader's sleep timer (no stray box and chevron) and the Mac player bar's speed and voice chips.
- Reading window: the reader bar sits in the hidden title bar beside the window buttons; the bottom bar and its separator span the window again under the 640 pt capsule.
- PDF: the segmented Original / Intelligent Reading control no longer shows its label beside it on macOS.
- Home: Read and Listen keep the 190 pt width on Mac.
- Localization: "1 book" is singular (library subtitle, sidebar footer); collection rows translate their book and subcollection counts.

## Release contents

Release builds contain no sample books or collections: sample seeding (`SampleLibrary`) and the capture tour are compiled only in Debug. The only sample titles left in Release are the fallback cover colours in `DesignSystem` and the macOS legacy-fixture cleanup, which only removes identifiable old fixtures.

## Checks

| Check | Result |
| --- | --- |
| iPhone 17 Pro unit/integration suite | 127 passed, 0 failures |
| macOS unit/integration suite | 127 passed, 0 failures |
| iPhone UI: PDF Intelligent Reading, PDF highlights/notes, PDF contents + return to narration, paged reader + bookmarks, centred transport, library/collections navigation, iCloud and storage | 7 passed, 0 failures |
| English/Spanish catalog | 716 keys, 0 missing Spanish, 0 placeholder mismatches |
