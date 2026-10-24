# Nodus Reader

**Your library, read aloud.** A free, local-first, open-source reader for iPhone, iPad and Mac with offline narration.

![Nodus Reader on iPhone](docs/screenshots/iPhone-01-Home.png)

Nodus Reader is part of the Nodus Research ecosystem. It is not a web wrapper: the interface is native SwiftUI, the library is local, and documents are never uploaded to Nodus servers.

## What works in this build

- Universal SwiftUI app for iPhone, iPad and Mac with a shared data layer.
- Native navigation: `TabView` on iPhone, `NavigationSplitView` with a collection tree on iPad and Mac, sortable `Table` and `.inspector` on Mac.
- Library: 3-column iPhone grid, 5-column iPad grid, Mac table/grid, search across titles/authors/text, filters, sorting, favorites, reading status and multi-selection actions.
- Real import from Files/Finder and drag & drop: EPUB, PDF, TXT, Markdown, HTML and RTF. Set as an alternative handler for those document types.
- Import pipeline: format validation, SHA-256 hashing, duplicate detection, metadata extraction, cover extraction/thumbnail/generation, coordinated file copy and optional collection assignment.
- Covers: embedded EPUB artwork, PDF first-page thumbnails and deterministic typographic covers; custom covers from Photos.
- Collections: unlimited nesting, rename, move, delete-without-deleting-documents, multiple memberships per book, manual order.
- Reader: real EPUB text extraction and PDFKit rendering, contents, chapter navigation, persistent progress, light/sepia/dark/OLED/high-contrast themes, custom themes, typography controls and justified text.
- Narration: real on-device system voices (`AVSpeechSynthesizer`), sentence and word highlighting, tap a word to start Read & Listen from that word, player with transport, speed, voice, sleep timer and modes. Background audio session, interruptions, headphone unplugging and lock-screen controls are wired for iOS.
- Settings: separate App/Reader themes, custom theme editor, reading typography, voice catalog with search/filters/samples, models screen, storage, privacy and about.
- Tests: 11 unit/integration tests plus UI tests with screenshot capture.

## Screenshots

| iPhone | iPad | Mac |
|---|---|---|
| ![Home](docs/screenshots/iPhone-01-Home.png) | ![Library](docs/screenshots/iPad-01-Library.png) | ![Library](docs/screenshots/Mac-01-Library.png) |
| ![Reader](docs/screenshots/iPhone-03-Reader.png) | ![Collection](docs/screenshots/iPad-04-Collection.png) | ![Reader](docs/screenshots/Mac-02-Reader.png) |
| ![Player](docs/screenshots/iPhone-12-Player.png) | ![Settings](docs/screenshots/iPad-05-Settings.png) | ![Settings](docs/screenshots/Mac-03-Settings.png) |

The Mac library also has a bottom player bar while narration is active; see `docs/screenshots/Mac-04-Player.png`.

The design source of truth is [`design/DESIGN.md`](design/DESIGN.md) and [`design/screens/`](design/screens/). See [`docs/DESIGN_FIDELITY.md`](docs/DESIGN_FIDELITY.md) for the comparison and documented deviations.

## Not in this build yet

- Share Extension and full folder import (Milestone 2).
- DOCX, FB2, CBZ and other phase-2 formats; DRM-protected content is not supported.
- Interface translations beyond English (the strings are localization-ready).
- Page-curl pagination, dual-page spread, bookmarks/highlights/notes and EPUB CFI locators (Milestone 3).
- iCloud library sync and conflict resolution (Milestone 4).
- Intelligent PDF reflow, OCR and original-page region overlays (Milestone 5).
- Kokoro 82M and Phonon neural TTS, Hugging Face model manager and model downloads (Milestone 6).
- Audio cache generation/prefetch/partial deletion and neural word alignment (Milestone 7).
- App Store/TestFlight distribution, notarisation and the final licence audit (Milestone 8).

The iCloud & Storage screen therefore reports **Local only** rather than claiming sync that does not exist.

## Build

Requirements: macOS with Xcode 27 (or a compatible Xcode with the iOS 18/macOS 15 SDKs), XcodeGen 2.44+, and network access the first time Swift Package Manager resolves ZIPFoundation.

```bash
xcodegen generate
open NodusReader.xcodeproj
```

Or from the command line:

```bash
xcodebuild -project NodusReader.xcodeproj -scheme NodusReader \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build

xcodebuild -project NodusReader.xcodeproj -scheme NodusReader \
  -destination 'platform=macOS' build
```

Full instructions, test commands and screenshot export are in [`docs/BUILD.md`](docs/BUILD.md).

### Sample library for development

Debug builds accept `-NodusSampleLibrary`, which creates valid EPUB/PDF files, imports them through the production pipeline and seeds collections and reading state. It is debug-only and never runs in release.

```bash
xcrun simctl launch booted ai.nodus.reader -NodusSampleLibrary
```

## Word-level sync and tap-to-play

Narration highlights the current sentence and the current word, and tapping a word on iPhone/iPad starts Read & Listen from that word. The requirement for neural-engine word alignment, partial audio caches, prefetch, cancellation and per-book cache deletion is specified in [`docs/NARRATION_SYNC.md`](docs/NARRATION_SYNC.md). Models and audio never sync.

## Tests

```bash
# Unit and integration tests
xcodebuild test -project NodusReader.xcodeproj -scheme NodusReader \
  -destination 'platform=macOS' -only-testing:NodusReaderTests

# UI tests and screenshots
xcodebuild test -project NodusReader.xcodeproj -scheme NodusReader \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:NodusReaderUITests
```

## Privacy and licence

- No telemetry, no ads, no accounts, no remote book or audio processing.
- iCloud sync is optional and not enabled in this build.
- Original code: AGPL-3.0-only (see [LICENSE](LICENSE)).
- NodusMark reused under MIT from Nodus Drift; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
- No model weights are bundled. See [MODEL_LICENSES.md](MODEL_LICENSES.md).
- Read [PRIVACY.md](PRIVACY.md) for the data-flow details.

Nodus Reader is not affiliated with Apple. EPUB is a registered trademark of the IDPF/W3C; PDF is a trademark of Adobe.
