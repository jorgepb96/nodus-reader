# Architecture

## Targets

| Target | Type | Purpose |
|---|---|---|
| `NodusReader` | App, `supportedDestinations: [iOS, macOS]` | The shipping app for iPhone, iPad and Mac |
| `DesignSystem` | Local Swift package | Tokens, themes, marks, typography, shared visual components |
| `NodusReaderTests` | Unit/integration tests | Swift Testing, in-memory SwiftData, real fixture EPUB/PDF files |
| `NodusReaderUITests` | UI tests | Black-box flows and screenshot capture |

The app is a single multiplatform target so that navigation, library and settings code is shared while platform roots differ. Deployment targets are iOS 18.0 and macOS 15.0. iOS 26 APIs (for example a floating tab accessory) may be used behind availability checks, but native fallbacks must keep iOS 18 functional.

The project is generated from `project.yml` by XcodeGen 2.44. The generated `.xcodeproj` is committed for convenience. `NodusReader/Info.plist` is hand-maintained and referenced by `INFOPLIST_FILE`; never add an `info:` block to `project.yml`.

## Folder map

```
NodusReader/
  App/                Scene, environment objects, roots, navigation model, commands
  Core/
    Persistence/      SwiftData models, schema, container, DeviceInfo
    Services/         FileStore, Import, EPUBParser, DocumentExtractor, covers,
                      LibraryService, ImportCoordinator, VoiceCatalog, PlaybackController,
                      BookTextLoader, HTMLText, ImagePipeline
    Settings/         ReaderPreferences (typography)
    SampleData/       DEBUG-only real sample EPUB/PDF generator
  Features/
    Home/ Library/ Collections/ Reader/ Player/ Settings/ Search/ Sidebar/ Mac/ Shared/
  Resources/          Asset catalog and app icon
Modules/DesignSystem/
  Sources/DesignSystem/
    Theme.swift       App palettes, reader themes, custom themes, ThemeManager
    Components.swift  BrandToolbar, controls, covers, empty states
    Typography.swift  Scaled serif display, eyebrow, section headings
    NodusMark.swift   MIT mark reused verbatim
    ReaderMark.swift  App icon direction C
    Color+Hex.swift   Hex/rgb conversion
NodusReaderTests/
NodusReaderUITests/
design/               Approved design source of truth (do not edit)
docs/                 Architecture, build, roadmap, iCloud plan, narration sync, fidelity
```

Feature folders are namespaced by responsibility today. The DesignSystem is a real Swift package because it is shared and should not depend on app code. Other domains are kept as folders because SwiftData model identity and file coordination are simpler in one module; they can be split into packages if the app grows, but only with explicit dependency rules.

## Data model

`Book`:
- identity: `id: UUID`, `contentHash` (SHA-256), original `fileName`/`relativePath`, size, format;
- bibliographic: title, author, language, published, description, search text, TOC titles;
- state: added/last-opened dates, progress, JSON `ReadingLocator`, status, favorite, cover file name;
- placement: memberships, source device, last position device/date;
- preferences: preferred voice ID, reading mode;
- download state (downloaded/cloud-only/downloading) reserved for sync.

`LibraryCollection`:
- `id`, `name`, `parentID`, `sortIndex`, timestamps, memberships.
- Depth is unlimited; the tree is derived from `parentID`.

`CollectionMembership`:
- explicit join object with `book`, `collection`, `sortIndex`, `addedAt`.
- Enables multi-membership without duplicating a book and per-collection manual order.

Deleting a collection deletes its membership rows (cascade) but not the books. Deleting a book cascades its memberships. Deleting a parent collection recursively deletes its descendants and their memberships.

`ReadingLocator` is a small Codable value (`chapterIndex`, `scrollFraction`, optional `pageIndex`). EPUB CFI and exact PDF destinations will extend this in Milestone 3. Positions are stored as JSON to keep schema migration cheap.

## Persistence and file storage

- SwiftData local store in Application Support (`NodusReader.store`), configured in `Persistence`.
- Original files and covers are stored on disk, not in the database:
  - `Application Support/NodusReader/Library/<book-id>/<original name>`
  - `Application Support/NodusReader/Covers/<book-id>-<timestamp>.jpg`
  - `Application Support/NodusReader/Temporary/<uuid>/<name>`
- Only relative paths are persisted, because the container URL changes across launches/platforms.
- `FileStore` is `@unchecked Sendable` and serialises filesystem operations at the API level; callers do not assume a particular actor.
- Cover filenames carry a timestamp so the SwiftUI image cache naturally invalidates when a cover is replaced.
- The SQLite store is never treated as an iCloud document. Sync will use CloudKit records plus iCloud Documents (see `docs/ICLOUD.md`).

## Import pipeline

1. `ImportCoordinator` receives URLs from `.fileImporter`, Open With/Open URL or drag & drop.
2. Format is detected from the file extension; unsupported formats fail with a user-facing error.
3. `FileAccess.stageCopy` uses security-scoped access and `NSFileCoordinator` to copy the source into a temporary staging directory. The original file is never modified.
4. SHA-256 is computed with CryptoKit. A matching `contentHash` in SwiftData skips the import as a duplicate.
5. `DocumentExtractor` runs off the main actor:
   - EPUB: ZIPFoundation + XMLParser for container/OPF, navigation labels, spine text, cover image;
   - PDF: PDFKit metadata and page text (bounded for search);
   - TXT/Markdown/HTML/RTF: encoding-aware text extraction;
   - HTML is stripped by a local parser (`HTMLText`) rather than WebKit, so it is safe off-main.
6. `CoverGenerator` produces a JPEG from embedded artwork, a PDF first-page thumbnail, or the deterministic typographic cover. ImageIO downsamples.
7. The staged file is moved into its permanent directory, a `Book` is inserted and an optional collection membership is created, then SwiftData is saved.
8. Duplicates and failures are aggregated; the UI shows a toast or an alert. TEMP files older than a day are cleaned on the next import.

The import is sequential to keep memory bounded and progress deterministic. Background concurrency is limited to one extraction at a time.

## Reading

- `BookTextLoader` reuses `DocumentExtractor` off-main to load chapter text on demand. EPUB is parsed with the same import parser; PDF text is page-based.
- The native text reader uses `JustifiedText` (UITextView/NSTextField) so paragraphs can be justified and tapped. A chapter is rendered as paragraphs; scroll offset is tracked with `onScrollGeometryChange` and persisted with a debounce.
- PDF Original uses `PDFKitReader`, a thin `UIViewRepresentable`/`NSViewRepresentable` around `PDFView` with page-change notifications, outline/page jumps and background colouring.
- Reader themes are resolved by `ThemeManager`; reader typography is a separate observable (`ReaderPreferences`) so hardware-independent preferences remain simple.
- Progress is written through `LibraryService`, which always records the source device and last-position date. This is what enables the Home “Continue · from your Mac” eyebrow later.

## Narration

`PlaybackController` is the current system-voice engine and the de facto interface to replace later:
- loads chapter text, tokenises sentences, speaks them with `AVSpeechSynthesizer`;
- exposes sentence/word ranges from the delegate callbacks;
- supports start/pause/resume, sentence/chapter transport, seek, speed, voice, sleep timer and modes;
- starts from an arbitrary sentence and character offset (`startingSentence`, `wordOffset`);
- updates book progress, Now Playing metadata and iOS remote commands;
- uses an audio session with `.playback`/`.spokenAudio` and the `audio` background mode.

The target engine abstraction, word alignment and audio cache are specified in `docs/NARRATION_SYNC.md`.

## App state and injection

`NodusReaderApp` owns the `ModelContainer` and creates one instance of each observable service:
`ThemeManager`, `ReaderPreferences`, `NavigationModel`, `VoiceCatalog`, `LibraryService`, `ImportCoordinator`, `PlaybackController`. They are injected with `.environment(...)`; the model container is injected with `.modelContainer(...)`. SwiftData queries in views provide live updates. `LibraryService` is the only place that mutates the library.

## Platform roots

- `RootView` applies the resolved app palette, preferred colour scheme, tint, file importer, alerts, toast, Open URL and drop destination.
- `PhoneRootView`: native `TabView` with Home/Library/Collections/Settings and a search-role tab; mini player via `safeAreaInset`; sheets for the player.
- `PadRootView`: `NavigationSplitView` with brand, a visible search field, smart lists and a recursive collection outline; content `NavigationStack`; sheet for Settings.
- `MacRootView`: inset sidebar, native table/grid, inspector, toolbar search/import/view controls, bottom player bar, Settings scene, menu commands and shortcuts.
- `CollectionOutlineRow` is shared by iPad and Mac.

## Concurrency

- Services that touch SwiftData are `@MainActor`.
- Parsing, hashing and text extraction run in `Task.detached(priority: .userInitiated)` and return `Sendable` values.
- UI work and model mutation happen back on the main actor.
- The Swift language mode is 5 with minimal strict concurrency, intentional for the SDK's mutable framework APIs; new code should still avoid sharing non-Sendable models across actors.
- `PlaybackController` uses a separate delegate object and hops to the main actor for state changes.

## Security and privacy

- Security-scoped access is always released with `defer`; coordinated reads are used.
- The app does not use a network client for reading, store or narration.
- No telemetry, accounts or tokens are present in this build.
- Future iCloud and Hugging Face credentials have explicit storage rules in `docs/ICLOUD.md` and `MODEL_LICENSES.md`.

## Testing

- Unit tests build real EPUB and PDF fixtures, import through the production pipeline into in-memory SwiftData, and cover duplicates, collections, ordering, themes and utilities.
- UI tests launch the app with the debug sample library and capture Home, Library, Reader, Appearance, Collections, Settings, Voices, Models, Typography, Search, Player and Read & Listen.
- Screenshots are stored in `docs/screenshots/` and compared with `design/screens/`.
