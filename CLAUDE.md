# Nodus Reader — Working Agreement

**La interfaz sigue `design/DESIGN.md` y `design/screens/`.** Esa carpeta es la fuente de verdad para tokens, marca, jerarquía, textos y comportamiento visual. No modifiques `design/` sin autorización expresa; si se autoriza un cambio, actualiza `DESIGN.md` y regenera `preview/` y `screens/` con `design/tools/render-mockups.js`.

## Product

Nodus Reader is a free, open-source, local-first reader for iPhone, iPad and Mac. One library through the user's own iCloud, native SwiftUI interfaces, EPUB/PDF/document import, offline reading and offline narration.

Non-negotiable principles:

- AGPL-3.0-only for original code, after the compatibility audit required for distribution.
- No ads, subscriptions, Nodus accounts or telemetry.
- No remote processing of books or audio.
- Library, reading and narration work offline.
- iCloud sync is optional and uses the user's personal account.
- TTS models and voices are downloaded and executed per device; they never sync.
- No DRM circumvention and no promise of DRM support.

## Stack

- Swift, SwiftUI, UIKit/AppKit where native behaviour requires it.
- SwiftData for the local replica; CloudKit and iCloud Documents planned for Milestone 4.
- PDFKit, Vision (planned), AVFoundation, Core ML/ONNX (planned).
- `Modules/DesignSystem` is a local Swift package for tokens, marks and shared components.
- ZIPFoundation (MIT) is the only third-party runtime dependency, used for EPUB container parsing.

## Commands

```bash
xcodegen generate                     # regenerate NodusReader.xcodeproj after adding files
xcodebuild -project NodusReader.xcodeproj -scheme NodusReader \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
xcodebuild -project NodusReader.xcodeproj -scheme NodusReader \
  -destination 'platform=macOS' build
xcodebuild test -project NodusReader.xcodeproj -scheme NodusReader \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:NodusReaderTests
xcodebuild test -project NodusReader.xcodeproj -scheme NodusReader \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:NodusReaderUITests
```

`NodusReader/Info.plist` is maintained by hand and referenced with `INFOPLIST_FILE`. Do not add an `info:` block to `project.yml`: XcodeGen would overwrite it.

## Architecture map

- `NodusReader/App` — scene, environment objects, adaptive roots (phone, iPad, Mac), navigation.
- `NodusReader/Core/Persistence` — SwiftData models and container.
- `NodusReader/Core/Services` — file store, import, EPUB parser, text extraction, covers, library, voices, playback.
- `NodusReader/Features` — Home, Library, Collections, Reader, Player, Settings, Search, Mac, shared components.
- `Modules/DesignSystem` — colour tokens, themes, typography, NodusMark, ReaderMark, cover language, shared controls.
- `NodusReaderTests` — Swift Testing unit/integration tests.
- `NodusReaderUITests` — black-box UI tests and screenshot capture.

## Rules for implementation

- Real functionality only. Do not ship buttons that simulate work, fake counts or placeholder actions. Empty states and explicit "not available in this build" explanations are preferred.
- Use native controls (`TabView`, `NavigationSplitView`, `NavigationStack`, `.searchable`, `Menu`, `Picker`, `Toggle`, `Table`, `.inspector`, `.contextMenu`, sheets). Never hand-draw system chrome.
- Put all visual constants in the DesignSystem. No hex values scattered through feature views.
- Every icon-only control has an accessibility label; touch targets are at least 44 × 44 pt; labels and switches expose their state.
- Keep the project compiling at every step. Tests must pass before a milestone is closed.
- When a feature is complex, implement the smallest real, tested version first and document what remains.
- Do not weaken privacy or licensing to make a distribution path easier.

## Current status

Milestone 1 is implemented end to end: multiplatform project, DesignSystem, app icon, adaptive navigation, Home, Library, EPUB/PDF/TXT/Markdown/HTML/RTF import, metadata, generated and custom covers, hierarchical collections with multi-membership, local persistence, themes and typography, settings, and tests.

A functional reader and a real system-voice narration path (`AVSpeechSynthesizer`) are already present: sentence and word highlighting, tap-a-word to start narration, transport, speed, voice selection, sleep timer and a compact/expanded player. Neural Kokoro/Phonon engines, audio cache management, iCloud sync, Share Extension and intelligent PDF reflow remain on the roadmap.

See `docs/ROADMAP.md` for milestone status and known deviations, and `docs/NARRATION_SYNC.md` for the required word-level audio/text synchronisation, tap-to-play and partial cache/deletion design.

## Verification

- Unit tests cover EPUB parsing, import, duplicate detection, PDF import, collection deletion preserving books, manual membership order, theme persistence and text utilities.
- UI tests cover Home, Library, Reader, Appearance, Collections, Settings, Voices/Models, Typography, Search, Player and tap-a-word Read & Listen.
- Screenshots are stored in `docs/screenshots/` and compared with `design/screens/` at each UI milestone.
