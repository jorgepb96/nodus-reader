# Build 55 verification and TestFlight delivery

Version **0.1.0 (55)** changes engine switching/cancellation, preserves Qwen generation-limit failures after silence trimming, migrates saved Qwen audio jobs to the revised cache and distinguishes model loading from sentence generation.

- iOS/iPadOS: **VALID**, assigned to Internal and Public Beta. External state: **IN_BETA_TESTING**; beta review: **APPROVED**. Build ID `941bbdd3-77f6-4422-bc2d-6bf0f9fbc2ff`.
- Native macOS: **VALID**, **Internal only**, internally **IN_BETA_TESTING**. Build ID `80cbdf5b-925d-4074-96bc-33e60c9a1466`. No external Mac group or review submission.
- Both exports passed signature, arm64 architecture, build/version, team, Production iCloud and bundled licence checks. The share extension is build 55 and the Mac installer is signed/sandboxed.
- Signed Release simulator and signed Mac archive startup checks passed. English/Spanish beta notes and reviewer instructions were saved and read back.
- The existing public iOS link remains enabled. iOS availability on Apple silicon Macs remains disabled. This delivery did not submit an App Store production release.

Validation carried forward from the same application source: 233 iOS Simulator test executions passed, 16 skipped; Qwen package 71 passed/36 skipped; three cancellation regressions passed in a standalone Mac harness. Real-model Mac fixed-code replay and a small local-ASR sampling control passed. The earlier full Mac test-host run stalled in dyld before executing tests and is not counted as a passing Mac suite.

Qwen weights and sampling are unchanged. No new sustained speed or naturalness improvement is claimed. Full physical iPhone confirmation of switching and the reported watchdog termination remains pending and is stated in the beta notes. Qwen remains experimental; pre-generating audio is recommended when synthesis cannot keep up.

The first build attempts encountered unrelated stale MLX files in two local dependency caches and an Xcode build-database I/O failure under the repository. Final artifacts use a clean MLX checkout at the existing pinned revision and build directories under `/tmp`; no dependency version was changed.

Verified at 2026-11-05T08:45:30.448815+01:00. Hashes, startup evidence and live group memberships: [BUILD55_DELIVERY.json](BUILD55_DELIVERY.json). The authorised working-tree snapshot and source archive are retained locally under `build/`.
