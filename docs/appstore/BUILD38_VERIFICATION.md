# Build 38 — Ming 3.0 on the Mac

Build 38 contains build 37 plus Ming 3.0 narration and voice cloning on macOS ([issue #47](https://github.com/jorgepb96/nodus-reader/issues/47), [PR #48](https://github.com/jorgepb96/nodus-reader/pull/48)) and Ming's Mandarin voices ([PR #49](https://github.com/jorgepb96/nodus-reader/pull/49)). It is distributed on macOS only, to the Internal group; iOS stays on build 37.

## Changes (macOS)

- Ming 3.0 0.5B, the 8-bit MLX checkpoint (`mlx-community/Ming-3.0-tts-0.5B-8bit` @ `c807b99`, MIT), run with MLXAudio (`mlx-audio-swift` @ `0dda61b`, MIT) on the Mac GPU. Twelve pinned files, each checked against size and SHA-256.
- 106 built-in voices (5 English, 101 Mandarin), the bundled CC0 `es-dave` Castilian clip, and voices cloned by recording a paragraph or adding an audio file, with the transcript suggested by on-device recognition and explicit consent. Clips stay on the Mac.
- Narration through the per-sentence pipeline: audio cache, voice picker and read-along sync as for Kokoro and Phonon.
- MLX 0.33.0 for every engine; MisakiSwift vendored with its MLX pin raised. Microphone entitlement and usage description.

## Checks

| Check | Result |
| --- | --- |
| iPhone 17 Pro unit/integration suite | 130 passed |
| `testPhoneScreens`, `testVoiceSetupOpensModelCatalog` | Passed (PR #48) |
| `MingVoiceStore` test and on-device transcription of the bundled clip on macOS | Passed; transcript almost word for word |
| Mac app (optimized build): Moby-Dick with US_James and 灵信远, Don Quijote with the cloned `es-dave` voice | Speech generated into the narration cache, about real time |
| Kokoro narration on the Mac with MLX 0.33 | Six sentences in 40 s, no error |

Not verified by hand: the 1.6 GB download itself, recording through a real microphone and the file picker, a Chinese book.

## Distribution

Version 0.1.0 (38). What to Test: [English](TestFlight-38-macos-en.txt) / [Spanish](TestFlight-38-macos-es.txt).

Archived from merge commit `ebbed57` ([PR #50](https://github.com/jorgepb96/nodus-reader/pull/50)) with a fresh DerivedData in `/tmp`. The archive signs automatically with team `6RPLS9EA4X` and passes `codesign --verify --deep --strict`; the app is arm64 only, carries the App Sandbox, iCloud and microphone (`com.apple.security.device.audio-input`) entitlements and the microphone usage text, bundles the `es-dave` clip, contains none of the debug-hook strings, and the signed archive launched and stayed running.

- macOS 0.1.0 (38): `Nodus Reader.pkg` uploaded through Xcode's account at 08:41 (Europe/Madrid) on 1 November 2026, for the Internal group only. The What to Test notes are entered by hand in App Store Connect.
