# iOS system voices and App Store readiness — 5 November 2026

## Decision

**Wait before production submission.** Physical iPhone/iPad validation was explicitly deferred by the user. This does not prevent the requested TestFlight beta delivery. No production App Store review has been submitted; both drafts remain **1.0 / PREPARE_FOR_SUBMISSION**. The new beta uses **0.1.0 (56)**, which must be aligned with the production draft for a future submission. macOS remains private beta only; public descriptions say **Coming soon / Próximamente**.

## Implementation

- iOS/iPadOS welcome offers three equally sized choices: iOS voices, download a model, or just read. The compact centered mark and all choices fit the normal viewport. The choice persists independently of downloaded models; existing installations migrate without a forced download.
- Apple voices use public discovery and synthesis APIs; personal and novelty voices are excluded. The catalogue shows fixed speed 5/5 and indicative naturalness 1/5, languages and Apple terms. PCM conversion, native word markers, pronunciation projection, cancellation and a ten-second no-progress watchdog use the common narration/cache pipeline without speech recognition.
- Qwen and Studio are hidden and runtime-disabled on iOS/iPadOS. Existing files remain removable in storage; queued jobs retain their voice/cache identities and explain unavailability. Qwen remains experimental on Mac.
- Device-specific fallback prioritizes downloaded and then system voices in the requested language, respecting known gender and regional/quality/default ties. It persists locally, never overwrites the Mac selection through iCloud, and is invalidated by a new manual selection. No compatible language pauses narration rather than using an unrelated voice. Transient synthesis errors do not trigger substitution.
- Model cards have consistent ratings, language names/emojis, code/weight licences and capabilities. Language filtering persists; lists above ten languages expand/collapse. Player and Settings voice filters allow several models, languages and genders, remembered across books and sessions.
- Reader flow controls are unavailable while narration auto-scroll is active; the duplicate visual picker label is removed. Light-theme highlight backing, compact player layouts, margins, safe navigation and bottom-player space have been corrected.
- macOS adds Now Playing/media keys, word-click narration, arrow/page navigation, corrected toolbar order and sidebar spacing, responsive table columns, reserved mini-player space and a compact expanded player dismissible outside or with Escape.

## Verified evidence

| Check | Result |
|---|---|
| Final-source macOS Release build | Passed, native arm64; `build/build56-mac-check3.log`. |
| Final-source iOS Debug build | Passed, signed Simulator app and test runners; `build/build56-ios-test-build.log`. |
| iOS unit tests | **236 passed**, including multi-select filter logic/persistence, native PCM/cancellation and voice replacement; `build/build56-unit-ios.xcresult`. Optional real-model cases remain opt-in and are not claimed passed. |
| Spanish iPhone screenshot tour and welcome | Passed; ten native 1320 × 2868 captures; `build/build56-iphone-es/`. |
| Welcome choices and persistent language filter | Passed in final-source UI run, including English/Spanish welcome routes and language-list expansion/collapse; `build/build56-ios-regressions/`. |
| Screenshot delivery | **60/60 COMPLETE**, exact order and MD5 read back from Apple; `BUILD56_SCREENSHOTS.json`. Ten per language/device set: English/Spanish × iPhone/iPad/Duo. Duo includes genuine inner-display captures using Apple's official Open posture. Source pixels are copied without retouching; local SHA-256 provenance is in `build/layout-gallery-provenance.json`. |
| Signed iOS archive/export | Passed, build/share-extension 56, strict code signatures, arm64 and Production iCloud entitlements; `build/Build56-ios-verification.json`. |
| TestFlight and remaining release checks | Live results are recorded in `BUILD56_VERIFICATION.md` and `BUILD56_DELIVERY.json` when delivery finishes. |

Prior Simulator captures were retained for scenes unaffected by the final correction batch. The final Spanish iPhone tour was recaptured from build 56. Screenshots contain real app state and synthetic/public-domain sample documents. Dedicated unit/UI passes and a Simulator tour do not establish physical intelligibility, lock-screen behavior, interruptions or two-device iCloud sync.

## Listing, licences and privacy

English/Spanish App Store descriptions and reviewer notes describe no-download Apple voices, optional model downloads and reading without narration. Beta descriptions and build-56 reviewer instructions were also updated/read back, removing stale iOS Qwen/cloning claims and retaining Mac coming-soon status. App privacy remains Data Not Collected; optional iCloud uses the user's private database. Existing additive voice-selection schema deployment evidence is retained; no new authenticated two-device round trip is claimed.

Linnet exposes only bundled voices under its weight licence and attribution, with code/weight terms separated. Phonon 40M non-commercial restrictions remain visible. Qwen files and notices remain even though the engine is hidden on iOS. Signature/export verification checks the bundled Linnet licences, attribution and pinned manifest.

## Remaining before App Store production

1. Physical iPhone/iPad tests of engine changes, offline EPUB/PDF/text, position retention, lock-screen playback and interruptions, in individual sessions no longer than five minutes. These remain deferred rather than marked passed.
2. Confirm a production iCloud round trip for the additive manual-selection metadata.
3. Select a production candidate whose marketing version matches the 1.0 draft, complete physical regressions and reassess crashes, hangs, narration, licences and privacy before review.

This work authorizes TestFlight delivery and screenshot updates only. macOS public publication and production review submission are outside this delivery.
