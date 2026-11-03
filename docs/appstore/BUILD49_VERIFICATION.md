# Build 49 — per-book pronunciation

Version 0.1.0 (49) adds a per-book pronunciation dictionary, original/corrected sentence previews, original-text highlighting, selective sentence-cache reuse and optional iCloud dictionary sync. The entry points are text selection (including PDF Intelligent Reading), the book menu and player options.

Validation before the version bump: 206 macOS test definitions passed; iPhone/iPad dictionary CRUD and iPhone PDF selection passed; real synthesis passed with Kokoro, Phonon 31M, Phonon 40M Spanish and Ming. A signed Mac–physical-iPhone metadata round trip passed in Development. The new CloudKit field was deployed to Production and a fresh export matches all 55 app payload fields. See ../PRONUNCIATION.md and CLOUDKIT_SCHEMA_DEPLOYMENT_2026-11-03.md.

Requested distribution: iOS Internal and Nodus Reader — Public Beta; macOS Internal only. English (US) and Spanish (Spain) What to Test notes accompany both platforms. No App Store production release is requested. Final delivery, processing, review and group assignments are verified below.

## Source and signed artifacts

Source commit: `2c9500b6d4f2e9bb33bddcdbaa8d7d609dc064cf` on GitHub main. Both archives use marketing version 0.1.0 and build 49. The exported apps and iOS extension were verified, with Production iCloud, the expected team and arm64 binaries. The Mac app is sandboxed and its installer signature is valid.

| Platform | Export | Bytes | SHA-256 |
| --- | --- | ---: | --- |
| ios | `build/export-ios-49/Nodus Reader.ipa` | 52,974,306 | `6973f588a0228254924d7978b6098220b2005e8c407bf51ec3b9f79c82bd781b` |
| mac | `build/export-macOS-49/Nodus Reader.pkg` | 48,175,689 | `9be3fd79b30050fe85a351240e46e55dde1de2c37714cbe4c4ce03987b2ba7da` |

These identify locally verified exports. Xcode subsequently re-exports the same archives for App Store Connect upload with symbols; container hashes can differ after re-signing.

The signed Release simulator app launched and remained running on iPhone 17 Pro and iPad Pro 13-inch (M5), iOS 26.5. The native signed Mac archive launched and its library window responded to accessibility queries. These checks used the build-49 Release binaries.

## TestFlight delivery — 3 November 2026

- Both uploads completed and processed as VALID without errors or warnings.
- iOS delivery/build ID: `5f4810bb-3cda-42f0-b1b0-cd129b684bc3`; uploaded at 10:15:44 Europe/Madrid. Assigned to Internal and Nodus Reader — Public Beta; Beta App Review APPROVED and externally IN_BETA_TESTING. Automatic tester notification is enabled.
- macOS delivery/build ID: `8f595bb1-5403-452d-a3d7-1ee737d64d4a`; uploaded at 10:18:32 Europe/Madrid. Assigned to Internal only and internally IN_BETA_TESTING. No public-group assignment or beta-review submission.
- Remote What to Test text matches the English (US) and Spanish (Spain) files for both platforms.
- The public iOS link remains enabled; iOS builds on Apple silicon Macs remain disabled for both groups.
- No App Store production release was submitted.

Final API snapshot and artifact hashes: [BUILD49_DELIVERY.json](BUILD49_DELIVERY.json).
