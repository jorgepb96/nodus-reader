# Build 56 — verification and delivery

Version **0.1.0 (56)** restores no-download iOS voices, hides Qwen/Studio on iOS, unifies model cards and persistent multi-select voice filters, and corrects reader/player/library layouts. Mac adds Now Playing, word-click narration, keyboard/page navigation and a compact dismissible player.

- iOS: VALID, assigned to Internal and Public Beta; external status **IN_BETA_TESTING**. Build `d90dd178-7813-4767-8d0a-2044bf4a5ec0`.
- macOS: VALID, Internal only. Build `c34a13a4-8146-4e42-b2bf-fdf08ec23126`. No external Mac review submission.
- **60/60 native screenshots COMPLETE**, exact order and checksums read back: English/Spanish on iPhone, iPad and Duo, including opened Duo scenes.
- **236 iOS unit tests passed**; final Spanish screenshot/welcome tour and bilingual welcome/language-filter persistence UI tests passed. Optional real-model tests are not claimed passed.
- Final-source Mac visual verification passed before rebuilding both signed Release archives. Sidebar branding, first-row visibility, horizontal scroll access and empty-card button centering were explicitly checked.
- Both exports passed strict signatures, team/version/arm64, bundled Linnet licence/attribution and Production CloudKit checks; signed startup liveness passed. Full Mac unit-host suite is not claimed passed.
- English/Spanish descriptions, beta notes and review instructions updated; Mac public release says Coming soon / Próximamente. Public beta: https://testflight.apple.com/join/SjCk8AZ1
- Physical iPhone/iPad playback/offline/interruption validation remains deferred. **Wait before production App Store submission**; beta 0.1.0 must also be aligned with the 1.0 production draft. No production review was submitted.

If the external status is waiting for beta review, public availability depends on Apple's approval; group assignment alone is not a claim of immediate availability. Verified 2026-11-05T19:07:02.350773+01:00. Full receipts: [BUILD56_DELIVERY.json](BUILD56_DELIVERY.json), [screenshots](BUILD56_SCREENSHOTS.json).
