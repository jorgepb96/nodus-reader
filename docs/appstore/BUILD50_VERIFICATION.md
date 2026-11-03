# Build 50 — preserve original book covers

Version 0.1.0 (50) fixes cross-device cover references. CloudKit metadata could replace a usable local cover filename with another device's filename; books with an already downloaded original then skipped the cover download and displayed generated artwork indefinitely.

Receiving metadata now keeps the usable local cover until its replacement arrives from personal iCloud. Cover copies retry after failure, and each successful metadata pull repairs missing local cover references even when no book metadata changed. Explicit cover resets still propagate; downloaded artwork is attached without echoing a metadata edit. No CloudKit schema changes are required.

## Validation

- A new regression test failed against the previous implementation: the local cover filename was replaced with a nonexistent remote filename.
- All 209 macOS test definitions passed after the fix.
- All three new regression tests passed on iPhone 17 Pro Simulator: retain the current image, retry a delayed replacement and respect a generated-cover reset, and recover a missing cover for an already downloaded book without another remote record.
- The installed Mac library showed its original artwork in grid and list views. Local original images were intact.
- The physical iPhone was unavailable during this follow-up; no physical-device recovery is claimed.

Distribution follows the requested channels: iOS Internal and Public Beta; macOS Internal only. No App Store production release.

## TestFlight delivery — 3 November 2026

Source commit: `386a3206ae39ef477d3f48cc6531ed97600473c5` on GitHub main. Both exports have verified signatures, Production iCloud, the expected team and arm64 binaries. The iOS extension is also build 50; the Mac app is sandboxed and its installer signature is valid.

- iOS build ID: `fb331f08-c603-4b1c-bec2-30c44040c3dc`. Processed as VALID; Internal and Public Beta groups. External state: **IN_BETA_TESTING**. Beta review: **APPROVED**.
- macOS build ID: `cac78783-8759-46e6-863a-e128dbf8c126`. Processed as VALID; Internal only, internally IN_BETA_TESTING. No public-group assignment or beta-review submission.
- English (US) and Spanish (Spain) What to Test text was read back and matched all four local files.
- The public iOS link remains enabled; iOS builds on Apple silicon Macs remain disabled for both groups.
- No App Store production release was submitted.

Final API snapshot and artifact hashes: [BUILD50_DELIVERY.json](BUILD50_DELIVERY.json).
