# Nodus Reader Privacy Policy

_Last updated: 2026-10-24_

Nodus Reader is local-first. Nodus Research does not operate a server for books, reading data, narration or analytics, and the app does not require a Nodus account.

## Data the app handles

- **Documents you import** — EPUB, PDF, TXT, Markdown, HTML and RTF files. The app copies the file into its own container and never modifies or deletes the original file.
- **Library metadata** — title, author, language, publication data, description, file hash, covers, collections, reading status, progress and per-book preferences.
- **Reading data** — position, bookmarks, highlights, notes and annotations when those features are implemented.
- **Narration preferences** — voice identifiers and speed. Audio is generated locally and is not uploaded.
- **Custom covers** — an image you choose from Photos is copied into the app's cover directory.

All of the above is stored locally today. The iCloud sync described in `docs/ICLOUD.md` is **not enabled** in this build; the Settings screen states “Local only”.

## Data the app does not collect

- No telemetry, analytics, crash reporting SDK, advertising identifier or usage profiling.
- No location, contacts, calendar, health data, microphone or camera access.
- No Nodus account, email address or password.
- No remote inference, OCR or text-to-speech. System voices are provided by the operating system.

## Permissions

- **Files / document picker** — read-only access to files the user explicitly selects. The app copies them into its container. On macOS it supports Open With and drag & drop.
- **Photos** — only when you choose a custom cover; the selected image is converted and stored locally.
- **Audio session** — used for narration and background/lock-screen playback. No recording is performed.

## iCloud (planned, opt-in)

When Milestone 4 lands, sync will use the user's personal iCloud account through Apple frameworks: CloudKit private database for metadata and iCloud Documents for original files and covers. Nodus Research will not run a sync server. Sync will be optional, and the app will continue to work with a local-only library.

The following will never be uploaded: neural model weights, voice embeddings, downloaded voices, generated audio, OCR caches, the Hugging Face token and hardware-specific settings.

## App privacy manifest

`NodusReader/PrivacyInfo.xcprivacy` declares no tracking and no collected data. It records the required reasons for UserDefaults and file-timestamp access. It is copied into the app bundle at build time.

## Data deletion

- **Delete from Library** removes the local file and metadata from this device. Once sync exists it will also delete the book from the user's iCloud library after confirmation.
- **Remove Download** (once sync exists) will remove only the local copy while keeping the book in iCloud and on other devices.
- Deleting a collection never deletes its documents.
- Uninstalling the app deletes its container, including the local library, covers and preferences.

## Network access

This build accesses the network only if a future feature is used (for example model downloads). It does not send documents, audio or reading data anywhere. The About/Privacy links open GitHub in the system browser.

## Children and sensitive data

The app has no accounts, profiles or social features. It does not knowingly collect personal information.

## Changes

Material changes will be documented in this file and in the release notes. The source code remains available under AGPL-3.0-only so that the claims above can be audited.

## Contact

Open an issue at <https://github.com/jorgepb96/nodus-reader-mobile>.
