# Build 41 — Immersive Audio

Build 41 contains build 40 plus Immersive Audio (`docs/IMMERSIVE_AUDIO.md`): instrumental music and ambient loops under reading, narration and study, with on-device scene analysis (Apple Foundation Models), a stability-first director, a separate audio engine with ducking and a narration-aware limiter, and an optional downloadable CC0/CC-BY catalog (95 files, `docs/immersive-audio/PROVENANCE.md`). Narration gains route-change recovery and Ming 44.1 kHz conversion.

## Checks

| Check | Result |
| --- | --- |
| Unit/integration suite (iPhone 17 Pro Simulator) | 184 passed |
| Unit/integration suite (macOS) | 184 passed |
| Opt-in: every processed sound decodes, frame count and SHA-256 match the manifest | Passed (42 files at the time; the catalog verifier re-checked all 95) |
| UI: Immersive settings, profile, reader controls, lock | Passed on iPhone 17 Pro and iPad Pro 13-inch |
| UI: manual mode without Apple Intelligence | Passed (iPhone) |
| UI: narration regressions (Listen, appearance/transport, paused narration after relaunch) | Passed (the relaunch test on iPad, the iPhone simulator has no voice model installed) |
| Catalog verifier: decode, length, loudness, true peak, clipping, loop seams, bitrate, duplicates, Nodus Drift register | 95 files passed |
| Real on-device model on Treasure Island, The Hound of the Baskervilles, Decline and Fall (EN) and Don Quijote (ES) | Book kinds correct; 0–1 atmosphere changes per half hour; director rules held |
| Localization | 960 keys, 0 missing Spanish |
| GitHub Release `immersive-audio-v1` | 95 assets; sampled downloads match size and SHA-256 |

Not verified: listening with headphones, a real iPhone (routes, Bluetooth, calls, background narration with music), Ming with music on a Mac. The Hugging Face mirror is not published yet (the app skips it and downloads from the GitHub Release).

## Distribution

Version 0.1.0 (41). What to Test: iOS [English](TestFlight-41-ios-en.txt) / [Spanish](TestFlight-41-ios-es.txt); macOS [English](TestFlight-41-macos-en.txt) / [Spanish](TestFlight-41-macos-es.txt). Content rights in App Store Connect must change before external testing or review (see `metadata.md`).
