# Build 37 — Mac fixes and model discoverability

Build 37 contains build 36, the Voices & Models changes ([issue #42](https://github.com/jorgepb96/nodus-reader/issues/42), [PR #43](https://github.com/jorgepb96/nodus-reader/pull/43)) and a round of macOS fixes. It is distributed on iOS and macOS, to the Internal group only.

## Changes

iOS and macOS:

- Voices & Models opens on Models; every model is in one list, Phonon 40M Multilingual before Spanish. Download on a gated model explains the Hugging Face requirement with a button to the guide; the account section is at the end.

macOS:

- The reader replaces the library in the main window instead of opening a Reading window; its back button returns to the library.
- Menus with custom labels (the player's Speed, Sleep and Mode tiles, its options menu, the voice filter chips, Sort) no longer get the pop-up bezel, so the player's tiles have one size.
- Text links and the Settings rows no longer get a push-button bezel behind them; switches are switches, not checkboxes.
- The book's voice picker and the player have a usable sheet size; the picker lists its voices.
- The contents list, PDF Intelligent Reading and the horizontal scroll reader use `.scrollIndicators(.never)`: with `.hidden`, the Mac drew its own scroller beside the custom one when scroll bars always show.
- MLX keeps its GPU default on the Mac. Forcing the CPU (meant for the locked iPhone) made MLX compile kernels with the system compiler, which the App Sandbox refuses: Kokoro narration ended in a fatal error.

## Checks

| Check | Result |
| --- | --- |
| iPhone 17 Pro unit/integration suite | 128 passed |
| `testPhoneScreens`, `testReaderAppearancePopoverAndContinuousScroll`, `testPDFSearchAndReflowScrollbar`, `testContentsSearchByTitleAndNumber` | Passed |
| iOS Simulator and macOS Debug builds | Succeeded |
| Mac Kokoro narration (`-NodusStartSampleNarration`), fresh MLX cache | Running after 40 s, no fatal error (before the fix: `Compile::eval_cpu … cannot be used within an App Sandbox`) |
| Mac window captures (reader, player, voice picker, Settings) | Reader in the main window, equal tiles, voices listed, plain rows, switch |
| English/Spanish catalog | 722 keys, 0 missing Spanish, 0 placeholder mismatches |

Not verified by hand: clicking through the Mac menus and filters (screen control was not available), two-device iCloud sync, the Share Extension on a device and a VoiceOver/large-text audit.

## Distribution

Version 0.1.0 (37). What to Test: iOS [English](TestFlight-37-ios-en.txt) / [Spanish](TestFlight-37-ios-es.txt); macOS [English](TestFlight-37-macos-en.txt) / [Spanish](TestFlight-37-macos-es.txt).
