# Build 43 — Stop in the mini player

Build 43 contains build 42 plus a Stop button next to Play in the iPhone/iPad mini player and in the Mac player bar: it ends narration and closes the player (`PlaybackController.stopAndClose()`).

## Checks

| Check | Result |
| --- | --- |
| iPhone 17 Pro Simulator and macOS builds | Succeeded |
| Localization | 963 keys, 0 missing Spanish |

Not verified: the Stop button on a real device. Unit tests were last run on build 42 (185 passed); build 43 only adds the two buttons.

## Distribution

Version 0.1.0 (43). What to Test is the same as build 42: iOS [English](TestFlight-43-ios-en.txt) / [Spanish](TestFlight-43-ios-es.txt); macOS [English](TestFlight-43-macos-en.txt) / [Spanish](TestFlight-43-macos-es.txt). iOS: Internal and Nodus Reader — Public Beta. macOS: Internal (private beta) only.

Archived from `6588101` on `feature/immersive-audio` ([PR #59](https://github.com/jorgepb96/nodus-reader/pull/59)).

- iOS 0.1.0 (43): uploaded at 00:16 (Europe/Madrid) on 2 November 2026; Internal and Nodus Reader — Public Beta, submitted to beta review with automatic notification.
- macOS 0.1.0 (43): uploaded at 00:27 through `xcodebuild -exportArchive` (`destination` = `upload`); Internal (private beta) only, not submitted for review. macOS 42 is also in Internal with the same notes.
- What to Test entered in English (U.S.) and Spanish (Spain) on iOS 43, macOS 42 and macOS 43, the same text as build 42.
