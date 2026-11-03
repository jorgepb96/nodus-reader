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
