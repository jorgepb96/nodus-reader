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
- SwiftData for the local replica; CloudKit and iCloud Documents for optional sync.
- PDFKit, Vision OCR, AVFoundation, Core ML (KokoroTTS and `ptts`/Phonon).
- `Modules/DesignSystem` is a local Swift package for tokens, marks and shared components.
- `Modules/PhononTTS` vendors the Apache-2.0/MIT `ptts` 0.4.1 Swift package; its
  `PhononCore` binary target is downloaded from the pinned GitHub release.
- Swift packages: ZIPFoundation (MIT), KokoroTTS (Apache-2.0, pinned revision),
  MisakiSwift/MLX (Apache-2.0/MIT; MisakiSwift vendored in `Modules/MisakiSwift` so it
  resolves mlx-swift 0.33.0) and NemoTextProcessing (Apache-2.0 binary). On macOS only,
  MLXAudio (`mlx-audio-swift`, MIT, pinned revision) runs Ming 3.0 0.5B (8-bit). MLX is
  also linked directly (same version) only to clear its cache when engines unload.
- Hugging Face sign-in is OAuth with PKCE; its client id is the metadata document
  `oauth/huggingface-client.json` served by jsDelivr at tag `hf-oauth-v1`. Do not move
  or edit it without publishing a new tag and updating `HuggingFaceOAuth.clientID`.

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
- `NodusReader/Core/Services` — file store, import, EPUB parser, text extraction, covers, library, voices, playback, model manager, narration cache/alignment.
- `NodusReader/Core/Sync` — durable outbox, CloudKit/iCloud Documents service.
- `NodusReader/Features` — Home, Library, Collections, Reader (pagination, PDF reflow), Player, Settings, Search, Mac, shared components.
- `Modules/DesignSystem` — colour tokens, themes, typography, NodusMark, ReaderMark, cover language, shared controls.
- `Modules/PhononTTS` — vendored Phonon Swift runtime (no model weights).
- `Shared` and `NodusShareExtension` — App Group staging and the iOS Share Extension.
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

The app is implemented end to end: multiplatform project, DesignSystem, adaptive
navigation, Home/Library/Collections/Search, document import, covers, themes and
settings; paginated reader with page curl and macOS spread; bookmarks, highlights and
notes; PDF Intelligent Reading with OCR; Share Extension; optional CloudKit +
iCloud Documents sync with a durable outbox; system-voice narration plus Kokoro and
Phonon Core ML; word-level alignment; and a partial audio cache with prefetch and
deletion.

The reader follows the app theme by default, hides the status bar on iOS and opens
in place of the library in the main window on macOS (no second window). The iOS layout follows the window,
not the idiom: an iPhone window at least 600 pt both ways (the opened iPhone Duo)
uses the iPad layout, and the switch waits while a full-screen reader is open. The selected model supplies
the global default; each book can retain a voice from any installed model through
its stable engine/checkpoint-qualified voice ID. Narration uses the book's detected
language unless the user has chosen a per-book voice. Book covers always draw a typographic
fallback while the real cover loads. The interface is localized in English (base)
and Spanish through `NodusReader/Resources/Localizable.xcstrings`; see
`tools/localization/README.md` before adding UI text.

On the Mac, Ming 3.0 0.5B (8-bit MLX, MIT) narrates in seven languages at about real
time with five built-in English voices, the bundled CC0 `es-dave` clip and voices the
user clones by recording a paragraph or adding an audio file: the transcript is
suggested by on-device speech recognition, consent is required, and clips stay on the
Mac (`MingVoiceStore`). Ming is not offered on iOS.

Kokoro speaks English (SDK phonemizer) and Spanish (`SpanishG2P`, rule-based, matching
espeak-ng) and is unavailable in the Simulator (MLX needs a Metal device).
Phonon 31M is English and downloads in the app. Phonon 40M Spanish and Multilingual
(CC BY-NC, gated) are never hosted or shipped: the app downloads them with the user's own
Hugging Face access and converts them to Core ML on the device (`PhononOnDeviceConversion`,
PhononCore rebuilt with `ptts_export_coreml`, see `Modules/PhononTTS/engine/`). Real-device iCloud and Share
Extension validation, distribution and the final accessibility/licence audits remain.

See `docs/ROADMAP.md`, `docs/ICLOUD.md` and `docs/NARRATION_SYNC.md`.

## Verification

- 60 unit/integration tests (plus four opt-in model tests) cover EPUB/PDF import (chapter splitting at contents
  anchors, paragraph joining, folder packages, DRM detection), duplicate detection, collections,
  themes (including reader-follows-app), text utilities, pause-based word alignment,
  page-boundary highlight clipping, path-traversal defenses, language-aware voice
  choice and the durable sync outbox, including suspended remote saves.
- 12 UI tests cover the phone screens, reader search, the reader appearance popover with continuous
  scrolling, PDF Intelligent Reading highlights and notes, reader, page turn, bookmarks, system
  narration, tap-a-word, PDF Intelligent Reading, Phonon narration (behavioural:
  progress past sentence 1), iCloud settings and the Spanish book-language voice
  filter. The iPad capture test is skipped on an iPhone destination and vice versa.
- Screenshots are stored in `docs/screenshots/` and compared with `design/screens/`.
- Unsigned simulator builds cannot exercise CloudKit or the App Group; those paths
  report unavailability explicitly and are documented as requiring signed
  real-device validation.


## Post-build-29 macOS status

Development sample launches and test hosts use `NodusReaderSamples` storage and a
separate preference suite; iCloud sync and shared-inbox consumption are disabled
there. Production macOS startup backs up and removes only identifiable legacy
fixtures, preserving real imports and personal collections. Voice setup is
nonmodal window content with a Quit action. See
`docs/appstore/POST29_MACOS_AND_COPY.md` for verification. The user withdrew
macOS 29 from Apple review: do not resubmit macOS until explicitly requested.
These later fixes are not part of the uploaded build-29 binary.
