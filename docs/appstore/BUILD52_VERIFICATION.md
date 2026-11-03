# Build 52 — immersive reading and public copy

Version 0.1.0 (52) is the final delivery for the revised privacy, About and documentation work. It includes local narration, per-book pronunciation, the cover synchronization repair and the cleaned-up information screens.

App Store descriptions now present the reading experience through on-device natural voices, reading recaps and immersive soundscapes. English and Spanish text identifies Apple Intelligence compatibility, local model/sound downloads, Mac-only voice creation and optional personal iCloud synchronization. All four App Store draft descriptions and both TestFlight descriptions were saved and read back. No App Store production version was submitted.

The official privacy page is https://nodusresearch.com/reader/privacy/. It is published on the original Nodus website, matches the repository policy and is linked from both Privacy and About. Website updates were delivered through English issues/pull requests: Nodus #1330, #1331 and #1332.

## Validation

- All 209 macOS and 210 iOS Simulator test definitions passed for the app code in build 51. Build 52 changes the build number and final documentation/listing text; it introduces no further Swift behavior changes.
- English and Spanish localization: 982 current keys, no missing translations or placeholder mismatches.
- About was inspected in Spanish on the running app: official website, Reader privacy, support and source-code links, with no acknowledgements or app-licence promotion.
- All 115 website checks passed. Both website deployments succeeded; the final live privacy policy was inspected and read back.
- Copy verification hashes and locales: [BUILD52_COPY_VERIFICATION.json](BUILD52_COPY_VERIFICATION.json).

Distribution: iOS Internal and Public Beta; native macOS Internal only. Build 51 remains an intermediate Internal validation build.

## TestFlight delivery — 3 November 2026

Source commit: `1b70ffabf8cfe3ee75d004b23f04d0688c459ae3` on GitHub main. Both exports have verified signatures, Production iCloud, the expected team and arm64 binaries. The iOS extension is also build 52; the Mac app is sandboxed and its installer signature is valid.

- iOS build ID: `e1e5521d-eef9-4358-bcd7-80fad8880874`. Processed as VALID; Internal and Public Beta groups. External state: **IN_BETA_TESTING**. Beta review: **APPROVED**.
- macOS build ID: `328c7711-c60c-4457-a8f8-14ae8b41527e`. Processed as VALID; Internal only, internally IN_BETA_TESTING. No public-group assignment or beta-review submission.
- English (US) and Spanish (Spain) What to Test text was read back and matched all four local files.
- The public iOS link remains enabled; iOS builds on Apple silicon Macs remain disabled for both groups.
- No App Store production release was submitted.

Final API snapshot and artifact hashes: [BUILD52_DELIVERY.json](BUILD52_DELIVERY.json).
