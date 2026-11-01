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
