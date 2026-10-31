# Build 36 — Filter voices by gender

Build 36 contains build 35 plus a Gender filter for neural voices ([issue #39](https://github.com/jorgepb96/nodus-reader/issues/39), [PR #40](https://github.com/jorgepb96/nodus-reader/pull/40)). It is distributed on iOS only; macOS stays on build 35.

## Changes

- Every neural voice carries its publisher's gender: Kokoro's from the voice file name (`af_`/`am_`, `bf_`/`bm_`, `ef_`/`em_`), Phonon's from `gradium/phonon-voices` `voices.jsonl` at the pinned revision (48 female, 42 male; the 12 character voices and Phonon 31M's base voice have none).
- The Voices screen and the book's voice picker have a Gender filter chip (All, Female, Male). It offers only genders present among the installed voices and is hidden when none has one; voices without a gender appear only under All.
- `design/DESIGN.md` and the Voices mockup, preview and screenshot describe the chip.

## Checks

| Check | Result |
| --- | --- |
| iPhone 17 Pro unit/integration suite | 128 passed, 0 failures (includes `neuralVoicesCarryTheirPublishedGender`) |
| iOS Simulator and macOS Debug builds | Succeeded |
| iPhone UI suite | 14 passed, 4 skipped, 4 failed. `testPDFReflowHighlightAndNote` passed on rerun. `testPausedNarrationResumesAfterRelaunch`, `testPDFContentsSearchAndReturnToPausedNarration` and `testReaderNarrationChapterModeScrubberAndSavedSpeed` fail identically on `main` before this change (86ff6b5, same lines): the Simulator used had no neural model installed, so narration never starts. `testNeuralVoiceNarration` and `testVoicePickerStartsWithBookLanguage` were skipped for the same reason. |
| English/Spanish catalog | 721 keys, 0 missing Spanish, 0 placeholder mismatches |

Not verifiable in the simulator: Kokoro narration (MLX needs a Metal device), two-device iCloud sync, the Share Extension on a device and a VoiceOver/large-text audit.

## Distribution

Version 0.1.0 (36). The What to Test notes are [English](TestFlight-36-en.txt) / [Spanish](TestFlight-36-es.txt).
