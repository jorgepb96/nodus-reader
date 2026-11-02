# Build 45 — Paste text, more music, new-sound detection

Build 45 contains build 44 plus:

- **Paste text.** The import "+" is a menu with Import Files… and Paste Text…; the Mac also has File › Paste Text… and the empty library states show a Paste text button.
  - The sheet takes an optional title (the first line when empty) and the text, with the system Paste button.
  - The text is imported as a `.txt` book through the usual import: language, cover, duplicates, narration and sync work as for any document.
  - The exact title is kept even when a file name could not hold it.
- **Immersive Audio catalog 2026.11.02.** 32 new pieces from OpenGameArt (14 CC0, 18 CC-BY 3.0/4.0) go into Narrative music, which grows from 72 to 104 pieces and from 238 to 359 MB.
  - They cover solemn, comic, romantic, dramatic and focus moments, plus fantasy and horror.
  - 14 more candidates were rejected by the pipeline: clipped masters, lossy sources below the floor, a bandwidth cut, or under 60 s.
  - Pixabay was not used (licence).
- **New sounds without an app update.**
  - Every new track records the catalog version that added it.
  - The app reads the catalog published in the `immersive-audio-v1` release while Immersive Audio is in use, at most once a day, or when the reader taps Check now.
  - It adopts that catalog only when it is newer and safe.
  - A downloaded pack that misses only new tracks shows "N new sounds · Download new sounds".

## Checks

| Check | Result |
| --- | --- |
| Catalog `verify`: 127 files (decode, length, loudness, true peak, clipping, loops, bitrate, duplicates, Nodus Drift register) | All passed |
| Opt-in: every processed file matches the manifest's SHA-256 and decodes | Passed (127 files) |
| Unit/integration suite (iPhone 17 Pro Simulator) | 191 passed, including paste-text import, title rules, catalog safety and the new-sounds state |
| iOS Simulator and macOS builds | Succeeded |
| Localization | 981 keys, 0 missing Spanish |
| GitHub Release `immersive-audio-v1` | 128 assets (127 tracks + `catalog.json`); `catalog.json` and 5 sampled tracks downloaded match their SHA-256 |

Not verified: listening to the 32 new pieces with headphones (the pipeline measures, it does not judge musical fit); the paste sheet and new-sounds flow on a real device.

## Distribution

Version 0.1.0 (45), archived from `30fad36` on `main` ([PR #62](https://github.com/jorgepb96/nodus-reader/pull/62)). What to Test: iOS [English](TestFlight-45-ios-en.txt) / [Spanish](TestFlight-45-ios-es.txt); macOS [English](TestFlight-45-macos-en.txt) / [Spanish](TestFlight-45-macos-es.txt), entered in English (U.S.) and Spanish (Spain).

- iOS 0.1.0 (45): uploaded at 14:22 (Europe/Madrid) on 2 November 2026 through `xcodebuild -exportArchive` (`destination` = `upload`). Internal and Nodus Reader — Public Beta (75 testers); submitted to beta review with automatic notification. Build 44 had passed beta review by then.
- macOS 0.1.0 (45): uploaded at 14:33. Internal (private beta) only, not submitted for review.
