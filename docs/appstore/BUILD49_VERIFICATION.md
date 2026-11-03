# Build 49 — per-book pronunciation

Version 0.1.0 (49) adds a per-book pronunciation dictionary, original/corrected sentence previews, original-text highlighting, selective sentence-cache reuse and optional iCloud dictionary sync. The entry points are text selection (including PDF Intelligent Reading), the book menu and player options.

Validation before the version bump: 206 macOS test definitions passed; iPhone/iPad dictionary CRUD and iPhone PDF selection passed; real synthesis passed with Kokoro, Phonon 31M, Phonon 40M Spanish and Ming. A signed Mac–physical-iPhone metadata round trip passed in Development. The new CloudKit field was deployed to Production and a fresh export matches all 55 app payload fields. See ../PRONUNCIATION.md and CLOUDKIT_SCHEMA_DEPLOYMENT_2026-11-03.md.

Requested distribution: iOS Internal and Nodus Reader — Public Beta; macOS Internal only. English (US) and Spanish (Spain) What to Test notes accompany both platforms. No App Store production release is requested. Delivery and final verification results will be recorded after upload.
