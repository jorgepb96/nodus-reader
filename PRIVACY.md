# Nodus Reader Privacy Policy

_Last updated: 2026-10-30_

Nodus Reader stores your library and reading data on your device. Narration and document processing run locally. Optional synchronization uses your personal iCloud account.

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
- No location, contacts, calendar, health data or camera access. The microphone is used only on the Mac, and only while you record a voice to clone for Ming (see below).
- No Nodus account, email address or password.
- No remote inference, OCR or text-to-speech. Kokoro and Phonon (and Ming on the Mac) run locally after an explicit model download. The gated Phonon 40M models are downloaded with your own Hugging Face access and converted to Core ML on the device.
- Recaps and characters (iOS and macOS 26 and later, on devices with Apple Intelligence; on by default, Settings › Recaps & Characters) are written by Apple Intelligence's on-device model from the pages before your reading position. The app uses only the on-device model, never Apple's Private Cloud Compute; the summaries are saved on the device, are not synced and can be deleted in that screen.
- Precise word timing (iOS 26 and later, on by default, Settings › Voices & Models) runs Apple's on-device speech recognition on the audio the app has just generated to time the read-along highlight.
- On the Mac, a Ming voice can be cloned from a recording or an audio file you choose. The recording is made only after you press Record and grant microphone access; the clip and its transcript (recognized on the Mac) stay on that Mac and are never synced.

## Permissions

- **Files / document picker** — read-only access to files the user explicitly selects. The app copies them into its container. On macOS it supports Open With and drag & drop.
- **Photos** — only when you choose a custom cover; the selected image is converted and stored locally.
- **Audio session** — used for narration and background/lock-screen playback.
- **Microphone (macOS only)** — used only while you record a voice to clone for Ming.

## iCloud (optional)

When you enable sync, it uses your personal iCloud account through Apple frameworks: a CloudKit private database for metadata, collections, bookmarks, annotations, reading positions and deletions, and iCloud Documents for original files and covers. Sync is off by default, and the app works fully with a local-only library.

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

The app accesses the network only for explicit model downloads from pinned Hugging Face revisions, for the one-time download of Apple's speech recognition model for a language when precise word timing needs it (performed by the operating system, not by Nodus Research), for an optional Hugging Face sign-in or token verification you request (sign-in opens Hugging Face's own page in the system sign-in sheet; Nodus Reader never sees your password and receives only an access token limited to your public profile and the gated models you accepted), when you share a web link to Nodus Reader (the Share Extension downloads that page or file from its own site so it can be imported), when you download an Immersive Audio sound pack (the files of Nodus Reader's own published catalog, from a pinned Hugging Face dataset or, if that fails, the project's GitHub Release; each file is checked against the SHA-256 shipped in the app), and, when sync is enabled, Apple's CloudKit/iCloud services. The About/Privacy links open GitHub in the system browser.

## Immersive Audio

Music and ambient sound are optional and off until you turn them on. The sound packs are downloaded once and played offline; they are excluded from backups and never synced. In Automatic mode, Apple Intelligence's on-device model reads the passages around your position to choose the atmosphere; the private cloud model is never used, and no text, position or audio leaves the device. The resulting scene analysis is stored on the device only and can be deleted in Settings › Immersive Audio.

## Children and sensitive data

The app has no accounts, profiles or social features. It does not knowingly collect personal information.

## Changes

Material changes will be documented in this file and in the release notes. The source code remains available under AGPL-3.0-only so that the claims above can be audited.

## Contact

This policy is published at <https://nodusresearch.com/reader/privacy/>. For support, open an issue at <https://github.com/jorgepb96/nodus-reader>. For a private security or privacy concern, use <https://github.com/jorgepb96/nodus/security/advisories/new>.
