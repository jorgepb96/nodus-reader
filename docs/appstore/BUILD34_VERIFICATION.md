# Build 34 — iPhone and iPad polish

Build 34 contains build 33 plus the iOS fixes found in fresh iPhone 17 Pro and iPad Pro 13" captures. Captures of the fixed screens are in `docs/screenshots/ios-build34/`.

## Fixes

- Reader measure: in single-page layouts the text column is limited to about 70 characters (`fontSize × 30`, at most 720 pt) instead of a fixed 720 pt, so iPad portrait and landscape no longer set 90+ character lines. Larger text sizes still widen the column up to the old limit.
- PDF Intelligent Reading: on narrow readers (≤ 820 pt) the original-page button sits in the mode bar beside the Original / Intelligent Reading switch instead of floating over the first line of text. It is disabled until the analysis is ready.
- Library (iPhone and iPad): "1 book" is singular.
- Voices: the Phonon 31M speaker formerly shown as "Default" is "Base voice" ("Voz base"); the global default badge reads "DEFAULT" instead of "BOOK DEFAULT", which was wrong outside a book. The voice ID (`phonon:default`) is unchanged, so saved choices keep working.
- Aa popover: the scroll indicator flashes on open and the bottom edge fades, so on iPhone the last visible row no longer looks cut off.

## Release contents

As in build 33: sample seeding and the Mac capture tour are Debug-only, so Release builds contain no sample books or collections.

## Checks

| Check | Result |
| --- | --- |
| iPhone 17 Pro unit/integration suite | 127 passed, 0 failures |
| macOS unit/integration suite | not run: the XCTest host hung waiting for `testmanagerd` (system daemon, needs a restart); macOS Debug and Release builds succeed and the signed archive was launched |
| iPhone UI: phone screens, library/collections, paged reader + bookmarks, appearance popover + continuous scroll, centred transport, voice picker by book language, PDF Intelligent Reading, PDF highlights/notes, PDF search + scrollbar, PDF contents + return to narration | 10 passed, 0 failures |
| iPad UI: iPad screens | 1 passed |
| English/Spanish catalog | 718 keys, 0 missing Spanish, 0 placeholder mismatches |

Not verifiable in the simulator: auto-scroll with a long real PDF on a device, two-device iCloud sync, the Share Extension on a device, a VoiceOver/large-text audit, and landscape iPad (the simulator did not rotate under XCUITest; the measure does not depend on window width).
