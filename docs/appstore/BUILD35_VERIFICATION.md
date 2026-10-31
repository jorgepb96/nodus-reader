# Build 35 — Read & Listen scrolling and iPhone Duo

Build 35 contains build 34 plus fixes for two TestFlight reports on build 33 (iPad Pro 11" M4, iOS 27.0.1) and support for the iPhone Duo.

## Fixes

- Continuous reading with Read & Listen: auto-scroll no longer jumps up and down. `ContinuousReaderContent` bound `.scrollPosition(id:)` to the slice at the top edge; every small layout change re-anchored that slice's top edge while the narration follow scrolled line by line, so the column snapped back to the slice start about twice a second. Reproduced in the iPad simulator (458 offset jumps in 15 s, back to the slice top). The narration follow now owns the offset; contents jumps, bookmarks, search, restoring the position and distant narration seeks are one-shot `ScrollViewReader.scrollTo` calls, and the leading slice is reported by `onScrollTargetVisibilityChange`. After the fix: four minutes of narration across slice boundaries with no backward jump.
- Paragraphs split between slices (and pages): the continuation starts without a first-line indent; the slice that breaks the paragraph carries the next word hidden (`readerContinuation`, clear, never mapped to chapter offsets), so its last line stays justified with its hyphen and line spacing; the vertical stack restores the spacing after slices that end a paragraph; and a highlight that runs on into the next slice fills its last line down to the spacing, so the sentence highlight has no 10 pt gap (measured 20 px before, none after).
- Voice for this book: the installed models are a segmented control ("All | Kokoro 82M | Phonon 31M") beside the language filter, or on its own row on iPhone; with one model, or too many to fit, it stays the Model menu.
- iPhone Duo: the layout follows the window instead of the device idiom. iPad always uses the iPad layout; an iPhone uses it when its window is at least 600 pt both ways (the opened iPhone Duo), so a Pro Max in landscape keeps the iPhone layout. A book open full screen keeps reading while the device opens or closes; the library switches when it closes, carrying the tab/sidebar place across. Home, search and collection sizes follow the active layout; PDF Intelligent Reading follows the reader's own window.

## Checks

| Check | Result |
| --- | --- |
| iPhone 17 Pro unit/integration suite | 127 passed, 0 failures |
| macOS unit/integration suite | 127 passed, 0 failures |
| iPhone UI suite | 20 passed, 2 skipped (iPad capture, opt-in App Store screenshots); `testPhoneScreens` timed out synthesizing a tap on Voices › Models once and passed on rerun |
| iPhone UI layout, final code | `testPhoneScreens` passed |
| iPad UI: iPad screens, final code | 1 passed |
| iPhone Duo (iOS 27.1 simulator), cover screen | iPhone layout as before; iOS places the tab bar on the right edge |
| iPhone Duo, opened window | iPad layout: the sidebar shows Home alongside All Books, Favorites and To Read, with the device footer; a book stays open while the layout changes and the library switches when it closes |
| English/Spanish catalog | 717 keys, 0 missing Spanish, 0 placeholder mismatches (the unused "BOOK DEFAULT" key was removed) |

The Duo's fold control needs the simulator panel, so the opened window was emulated with the width rule applied while the book and library were checked; the temporary rule was then removed, the final code recompiled, and the cover screen confirmed on the iPhone layout. The final code switches on the small side of the window (at least 600 pt both ways).

Not verifiable in the simulator: Kokoro narration (MLX needs a Metal device), two-device iCloud sync, the Share Extension on a device and a VoiceOver/large-text audit.

## Distribution

Version 0.1.0 (35), archived from merge commit `51fefc7` ([PR #36](https://github.com/jorgepb96/nodus-reader/pull/36)). Both archives sign automatically with team `6RPLS9EA4X` and pass `codesign --verify --deep --strict`; the Mac app is arm64 only, its binary contains none of the capture-tour strings, and a Release build launched and stayed running on the iPhone 17 Pro simulator.

Both uploads succeeded through Xcode's account into App Store Connect:

- iOS 0.1.0 (35): `Nodus Reader.ipa` uploaded at 17:02 (Europe/Madrid) on 31 October 2026.
- macOS 0.1.0 (35): `Nodus Reader.pkg` uploaded at 17:04 (Europe/Madrid) on 31 October 2026.

The Internal group receives every Xcode build automatically. The What to Test notes are [English](TestFlight-35-en.txt) / [Spanish](TestFlight-35-es.txt); build IDs and the TestFlight state are confirmed in App Store Connect once processing finishes.
