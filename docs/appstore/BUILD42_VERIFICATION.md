# Build 42 — Immersive Audio downloads

Build 42 contains build 41 plus fixes from the first TestFlight test on an iPhone:

- Sound packs download in a background `URLSession`: every file of a pack is queued at once, keeps downloading when the reader leaves the app, and is verified (size and SHA-256) and installed even if the download finishes while the app is suspended or relaunched (`ImmersiveDownloadSession`, `NodusAppDelegate`).
- Download progress follows the bytes of each file, so a large file no longer looks stuck.
- Packs can be deleted while downloading, paused, failed or installed, and "Delete all sounds" removes every file.
- The Immersive Audio, Sound packs and Credits pages leave room above the mini player and tab bar, so the last row scrolls into view.

## Checks

| Check | Result |
| --- | --- |
| Unit/integration suite (iPhone 17 Pro Simulator) | 185 passed |
| Opt-in network test: a published file downloaded through the background session, SHA-256 verified | Passed |
| macOS build | Succeeded |
| Localization | 962 keys, 0 missing Spanish |

Not verified: a background download on a real iPhone with the app closed.

## Distribution

Version 0.1.0 (42). What to Test: iOS [English](TestFlight-42-ios-en.txt) / [Spanish](TestFlight-42-ios-es.txt); macOS [English](TestFlight-42-macos-en.txt) / [Spanish](TestFlight-42-macos-es.txt).

Archived from `733534e` on `feature/immersive-audio` ([PR #59](https://github.com/jorgepb96/nodus-reader/pull/59)).

- iOS 0.1.0 (42): `Nodus Reader.ipa` uploaded at 23:28 (Europe/Madrid) on 1 November 2026; Internal group and Nodus Reader — Public Beta (74 testers), submitted to beta review the same night with automatic tester notification.
- macOS 0.1.0 (42): signed `Nodus Reader.pkg` uploaded at 00:03 on 2 November 2026 through `xcodebuild -exportArchive` with `destination` set to `upload`; private beta (Internal group) only, not submitted for review.
- What to Test entered in App Store Connect in English (U.S.) and Spanish (Spain) on the iOS build, from the files above. Build 41 (iOS, Internal only) has no What to Test text: 42 supersedes it.
- Content rights in App Store Connect changed to "contains third-party content and has the necessary rights".
