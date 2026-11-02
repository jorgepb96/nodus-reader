# Build 46 — Lock Screen and Dynamic Island controls

Build 46 contains build 45 plus a fix for narration missing from the Lock Screen, Control Center and the Dynamic Island (cover and controls) after leaving the app.

**Cause.** Since Immersive Audio, opening the reader can leave the audio session mixable (`.mixWithOthers`, for music under silent reading). Narration then switched the session with `.allowBluetooth` and `.allowAirPlay`, options Apple documents only for `.playAndRecord`; a failure there was swallowed by `try?`, which could leave the session mixable. A mixable session is never the Now Playing app.

**Fix.** `AudioSessionCoordinator.apply(_:to:)`:
- narration sets `.playback`/`.spokenAudio` with no extra options (AirPlay and Bluetooth A2DP are on by default for playback);
- ambience sets only `.mixWithOthers`;
- category or activation errors are logged instead of discarded.

A unit test checks that narration takes a non-mixable session after the ambience configuration.

## Checks

| Check | Result |
| --- | --- |
| iOS and macOS Release archives | Succeeded |
| Unit tests | **Not run.** The Mac's audio service (`coreaudiod`) had hung, so every simulator test host deadlocked at launch. The maintainer asked to ship without them. |

Not verified: whether the old options actually failed on device, and the fix itself on a real iPhone (Lock Screen, Control Center, Dynamic Island).

## Distribution

Version 0.1.0 (46), archived from the fix in [PR #64](https://github.com/jorgepb96/nodus-reader/pull/64). What to Test: iOS [English](TestFlight-46-ios-en.txt) / [Spanish](TestFlight-46-ios-es.txt); macOS [English](TestFlight-46-macos-en.txt) / [Spanish](TestFlight-46-macos-es.txt), entered in English (U.S.) and Spanish (Spain).

- The first upload failed: Xcode's Apple account session had expired ("missing Xcode-Token"). It succeeded after the maintainer signed in again.
- iOS 0.1.0 (46): uploaded at 15:54 (Europe/Madrid) on 2 November 2026. Internal and Nodus Reader — Public Beta (75 testers); submitted to beta review with automatic notification. Build 45 had passed beta review by then.
- macOS 0.1.0 (46): uploaded at 15:57. Internal (private beta) only, not submitted for review.
