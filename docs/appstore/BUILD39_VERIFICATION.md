# Build 39 — Recaps and characters

Build 39 contains build 38 plus recaps and characters with Apple Intelligence on iOS and macOS ([issue #52](https://github.com/jorgepb96/nodus-reader/issues/52), [PR #53](https://github.com/jorgepb96/nodus-reader/pull/53)). It is distributed on iOS to the Internal group and the public beta, and on macOS to the Internal group only.

## Changes

- On devices with Apple Intelligence (iOS/macOS 26+): "Where you left off", "The story so far" and a character list in the reader, written by the on-device model from the text before the reader's position, with front matter skipped; a Welcome back card after two days away; Settings › Recaps & Characters to turn it off and delete saved recaps.
- On iOS this is the first build since 37: Kokoro now runs on MLX 0.33.0 (MisakiSwift vendored), as on the Mac since build 38.

## Checks

| Check | Result |
| --- | --- |
| iPhone 17 Pro unit/integration suite | 138 passed (PR #53) |
| Six Project Gutenberg books at 3–97 % (Moby-Dick, Pride and Prejudice, Sherlock Holmes, Don Quijote, Niebla, Marianela) | "Where you left off" accurate almost everywhere; "The story so far" simplifies and mixes stories in a collection; about one character description in three has a slip (the sheet says it can make mistakes) |
| Mac app and iPhone 17 Pro Simulator, Spanish UI | Welcome back card, recap sheet, characters with page numbers, Settings |

Not verified: a real iPhone.

## Distribution

Version 0.1.0 (39). What to Test: iOS [English](TestFlight-39-ios-en.txt) / [Spanish](TestFlight-39-ios-es.txt); macOS [English](TestFlight-39-macos-en.txt) / [Spanish](TestFlight-39-macos-es.txt).

Archived from merge commit `34d7f45` ([PR #54](https://github.com/jorgepb96/nodus-reader/pull/54)) with fresh DerivedData in `/tmp`. Both archives are signed as 0.1.0 (39) and pass `codesign --verify --deep --strict`; neither contains the debug-hook strings. The Mac app is arm64 only and keeps the App Sandbox, iCloud and microphone entitlements. The signed Mac archive could not be launch-checked: a copy of Nodus Reader installed in `/Applications` was running, and a second instance exits at once (the build 38 archive does the same).

- macOS 0.1.0 (39): `Nodus Reader.pkg` uploaded at 13:27 (Europe/Madrid) on 1 November 2026; Internal group only, not submitted for review.
- iOS 0.1.0 (39): `Nodus Reader.ipa` uploaded at 13:29; Internal group and Nodus Reader — Public Beta (72 testers), submitted to beta review and In Testing the same afternoon.
- What to Test entered in App Store Connect in English (U.S.) and Spanish (Spain) on both builds, from the files above.
