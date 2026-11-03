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
