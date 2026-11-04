# Build 53 verification and TestFlight delivery

Version **0.1.0 (53)** adds experimental local Qwen voice cloning, Studio voice creation on iOS/macOS, persistent whole-book and progressive audio generation, and improved narration prefetching.

- iOS: VALID, Internal and Public Beta groups, externally IN_BETA_TESTING with beta review APPROVED.
- macOS: VALID, Internal only, internally IN_BETA_TESTING, without an external group or beta-review submission.
- English (US) and Spanish (Spain) What to Test notes were saved and read back successfully for both platforms.
- Both Release archives and exported package signatures, Production iCloud entitlements, team identity and arm64 architecture were verified. The Mac installer is signed and sandboxed; the iOS extension also uses build 53.
- iOS builds on Apple silicon Macs remain disabled for both groups. No App Store production release was submitted.

Validation: 217 macOS unit tests, 218 iOS Simulator unit tests and two focused iPhone UI tests passed. A five-minute physical iPhone Qwen test included locked-screen playback. Physical microphone capture was not exercised in this validation pass.

Qwen remains experimental and can pause in live playback; prepare audio ahead where possible. iOS may suspend long background generation jobs, which resume when the app returns. INT8 experiments were not enabled because of quality regressions.

See [delivery state and exported artifact hashes](BUILD53_DELIVERY.json), [Qwen integration](../QWEN_TTS.md), [optimization results](../QWEN_OPTIMIZATION.md) and [offline audio](../OFFLINE_AUDIO.md).
