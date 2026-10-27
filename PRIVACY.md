# Nodus Reader Privacy Policy

_Last updated: 2026-10-26_

Nodus Reader is local-first. Nodus Research does not operate a server for books, reading data, narration or analytics, and the app does not require a Nodus account.

## Data the app handles

- **Documents you import** — EPUB, PDF, TXT, Markdown, HTML and RTF files. The app copies the file into its own container and never modifies or deletes the original file.
- **Library metadata** — title, author, language, publication data, description, file hash, covers, collections, reading status, progress and per-book preferences.
- **Reading data** — position, bookmarks, highlights, notes and annotations.
- **Narration preferences** — voice identifiers and speed. Audio is generated locally and is not uploaded. Sentences you listen to may be cached as audio on this device.
- **Optional Hugging Face sign-in or token** — only if you choose to sign in or save a token; stored in the device Keychain.
- **Custom covers** — an image you choose from Photos is copied into the app's cover directory.

All of the above is stored locally by default. iCloud sync is optional and off by default. When you enable it, the app uses your personal iCloud account as described below.

## Data the app does not collect

- No telemetry, analytics, crash reporting SDK, advertising identifier or usage profiling.
- No location, contacts, calendar, health data, microphone or camera access.
- No Nodus account, email address or password.
- No remote inference, OCR or text-to-speech. System voices are provided by the operating system; Kokoro and Phonon run locally after an explicit model download. The gated Phonon 40M models are downloaded with your own Hugging Face access and converted to Core ML on the device.
- No microphone. Precise word timing (iOS 26 and later, on by default, Settings › Voices & Models) runs Apple's on-device speech recognition on the audio the app has just generated, never on recorded sound, to time the read-along highlight.

## Permissions

- **Files / document picker** — read-only access to files the user explicitly selects. The app copies them into its container. On macOS it supports Open With and drag & drop.
- **Photos** — only when you choose a custom cover; the selected image is converted and stored locally.
- **Audio session** — used for narration and background/lock-screen playback. No recording is performed.

## iCloud (optional)

When you enable sync, it uses your personal iCloud account through Apple frameworks: a CloudKit private database for metadata, collections, bookmarks, annotations, reading positions and deletions, and iCloud Documents for original files and covers. Nodus Research does not run a sync server and cannot read your library. Sync is off by default, and the app works fully with a local-only library.

The following will never be uploaded: neural model weights, voice embeddings, downloaded voices, generated audio, OCR caches, the Hugging Face token and hardware-specific settings.

## App privacy manifest

`NodusReader/PrivacyInfo.xcprivacy` declares no tracking and no collected data. It records the required reasons for UserDefaults and file-timestamp access. It is copied into the app bundle at build time.

## Data deletion

- **Delete from Library** removes the local file, metadata and narration cache on this device. When sync is enabled it also deletes the book from the user's iCloud library after confirmation.
- **Remove Download** removes only the local document copy while keeping the book in iCloud and on other devices.
- **Delete generated audio** removes cached narration without touching the book.
- Deleting a collection never deletes its documents.
- Uninstalling the app deletes its container, including the local library, covers and preferences.

## Network access

The app accesses the network only for explicit model downloads from pinned Hugging Face revisions, for the one-time download of Apple's speech recognition model for a language when precise word timing needs it (performed by the operating system, not by Nodus Research), for an optional Hugging Face sign-in or token verification you request (sign-in opens Hugging Face's own page in the system sign-in sheet; Nodus Reader never sees your password and receives only an access token limited to your public profile and the gated models you accepted), when you share a web link to Nodus Reader (the Share Extension downloads that page or file from its own site so it can be imported), and, when sync is enabled, Apple's CloudKit/iCloud services. It does not send documents, audio, reading data or telemetry to Nodus Research. The About/Privacy links open GitHub in the system browser.

## Children and sensitive data

The app has no accounts, profiles or social features. It does not knowingly collect personal information.

## Changes

Material changes will be documented in this file and in the release notes. The source code remains available under AGPL-3.0-only so that the claims above can be audited.

## Contact

Open an issue at <https://github.com/jorgepb96/nodus-reader>.
