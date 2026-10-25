# Build, Test and Capture

## Requirements

- macOS with Xcode 27.1 or a compatible Xcode providing the iOS 18+ and macOS 15+ SDKs. The project is developed against Xcode 27.1 / Swift 6.4 toolchain in Swift 5 language mode.
- XcodeGen 2.44+ (`brew install xcodegen`).
- Network access the first time Swift Package Manager resolves ZIPFoundation,
  KokoroTTS/MisakiSwift/MLX/NemoTextProcessing and the `PhononCore` binary target.
- The Metal Toolchain component for KokoroTTS (`xcodebuild -downloadComponent
  MetalToolchain`) if Xcode reports a missing `metal` tool.
- iOS 18+ simulators (iPhone and iPad) and macOS 15+ for the Mac app.

Deployment targets: iOS 18.0, macOS 15.0. The app is a single multiplatform target
using `supportedDestinations: [iOS, macOS]`. The neural engines require an Apple
Silicon Mac (the Phonon binary and Kokoro Core ML pipeline are arm64-only), so x86_64
is excluded for macOS and Simulator builds.

## Generate and open

```bash
xcodegen generate
open NodusReader.xcodeproj
```

Re-run `xcodegen generate` whenever files are added or removed. XcodeGen does not overwrite `NodusReader/Info.plist` anymore because the project uses `INFOPLIST_FILE` and there is no `info:` block. If an `info:` block is added, XcodeGen will replace the full plist with a minimal one and remove `UILaunchScreen`, document types and background audio modes.

## Command-line builds

Manual signing is not required for simulator or local Mac builds:

```bash
# iPhone simulator
xcodebuild -project NodusReader.xcodeproj -scheme NodusReader \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath build/DerivedData-ios CODE_SIGNING_ALLOWED=NO build

# iPad simulator
xcodebuild -project NodusReader.xcodeproj -scheme NodusReader \
  -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' \
  -derivedDataPath build/DerivedData-ios CODE_SIGNING_ALLOWED=NO build

# Mac
xcodebuild -project NodusReader.xcodeproj -scheme NodusReader \
  -destination 'platform=macOS' \
  -derivedDataPath build/DerivedData-mac CODE_SIGNING_ALLOWED=NO build
```

The iOS app embeds the `NodusReaderShare.appex`; the macOS target excludes it with
an XcodeGen `platformFilter`. The Phonon binary is arm64-only, so x86_64 is excluded
for simulator/macOS builds.

If `xcodebuild` reports `accessing build database ... disk I/O error`, delete the derived data and retry once. This has been observed as a transient CoreSimulator/Xcode issue, not an app failure:

```bash
rm -rf build/DerivedData-ios build/DerivedData-mac
```

## Unit tests

```bash
xcodebuild test -project NodusReader.xcodeproj -scheme NodusReader \
  -destination 'platform=macOS' \
  -only-testing:NodusReaderTests \
  -derivedDataPath build/DerivedData-mac CODE_SIGNING_ALLOWED=NO
```

The tests build real EPUB and PDF fixtures with the debug sample generator, import
them into an in-memory SwiftData store with a temporary `FileStore`, and assert
metadata, chapters, duplicates, covers, collections, manual order, themes, utilities,
pause-based word alignment and the durable sync outbox/tombstone rules. As of the last
run: **21 tests pass**.

The DesignSystem package has its own test target:

```bash
swift test --package-path Modules/DesignSystem
```

## UI tests and screenshots

```bash
xcodebuild test -project NodusReader.xcodeproj -scheme NodusReader \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:NodusReaderUITests \
  -resultBundlePath build/UITests-iPhone.xcresult \
  -derivedDataPath build/DerivedData-ios CODE_SIGNING_ALLOWED=NO
```

The tests launch with `-NodusSampleLibrary`, which creates real EPUB/PDF files using public-domain text and original placeholder prose, imports them through the production pipeline, and seeds collections and reading state. Reader-specific tests also pass `-NodusResetReadingState` so a previous test's page position cannot hide the chapter opener. Debug-only.

Covered flows: Home, Library, Reader, Appearance, Collections, Collection detail,
Settings, Voices, Models, Typography, Search, Player (system voice), tap-a-word
Read & Listen, page turn/bookmarks, PDF Intelligent Reading and source panel, Phonon
narration (behavioural: proves playback advances to sentence 2), the Spanish
book-language voice picker and iCloud & Storage. The tests skip the iPad layout on
iPhone and vice versa.

The Phonon test requires a Phonon bundle in the simulator app container. Install it
from **Settings → Voices & Models → Models → Phonon 31M → Download**, or copy an
existing bundle:

```bash
DATA=$(xcrun simctl get_app_container booted ai.nodus.reader data)
mkdir -p "$DATA/Library/Application Support/NodusReader/Models/Phonon"
rsync -a --exclude '*.mlmodelc' /path/to/phonon-bundle/ \
  "$DATA/Library/Application Support/NodusReader/Models/Phonon/"
```

Kokoro is intentionally unavailable in the Simulator because MisakiSwift uses MLX and
requires a Metal device; install and test Kokoro on an iPhone, iPad or Mac. Its cache
can be preseeded in `Application Support/NodusReader/Models/Kokoro` without the
`compiled-v2` directory.

Export attachments (screenshots):

```bash
xcrun xcresulttool export attachments \
  --path build/UITests-iPhone.xcresult \
  --output-path docs/screenshots/raw-iphone
```

Use `manifest.json` to rename the exported files. `docs/screenshots/` contains the curated set used by the README and design comparison.

## Debug launch arguments (macOS)

```bash
# Seed/import sample documents and show the library
"build/DerivedData-mac/Build/Products/Debug/Nodus Reader.app/Contents/MacOS/Nodus Reader" \
  -NodusSampleLibrary

# Open the Settings scene
... -NodusSampleLibrary -NodusOpenSettings

# Open the full-window reader on Moby-Dick
... -NodusSampleLibrary -NodusOpenSampleReader

# Start narration and show the Mac player bar
... -NodusSampleLibrary -NodusStartSampleNarration
```

These arguments are compiled behind `#if DEBUG` and do nothing in Release.

## Signing and distribution

- Simulator and local Mac builds do not need a team when `CODE_SIGNING_ALLOWED=NO`.
- For a device build, select a development team that owns
  `iCloud.ai.nodus.reader` and `group.ai.nodus.reader`. Automatic signing is enabled
  in `project.yml`.
- `Config/NodusReader.entitlements` contains CloudKit, iCloud Documents, the
  ubiquity container and the App Group. `Config/NodusReaderShare.entitlements`
  contains the App Group.
- Unsigned builds deliberately report iCloud unavailable; constructing `CKContainer`
  without the entitlement would abort the process.
- Before distribution:
  - add the macOS App Sandbox entitlement with user-selected read-only file access if
    distributing through the Mac App Store (the current Mac build is not sandboxed);
  - deploy the CloudKit development schema to production;
  - audit AGPL and third-party licences;
  - validate App Store/Mac App Store policy for model downloads and open-source licensing.
- `UIBackgroundModes: audio` is present so narration can continue when the screen is locked.

## Known environment notes

- The Mac app is a normal SwiftUI `WindowGroup`; the first launch uses `.defaultSize(1360 × 860)` and a minimum content size.
- The iOS 26 simulator was used for the screenshots (iPhone 17 Pro, iPad Pro 13-inch M5, iOS 26.5). iOS 18.2 runtime is also installed and supported by the deployment target.
- System voices come from the simulator/OS. Voice names and availability vary; the Tests do not assert a specific voice.
- Phonon downloads about 300 MB and Kokoro about 210 MB; Core ML additionally
  compiles models beside the packages, so on-disk usage is larger than the download.
- All model and audio caches are excluded from backup and are never uploaded.
- The first Kokoro/Phonon synthesis after install is slower because Core ML compiles
  the model packages; later sentences are much faster.
- The app icon is assembled in `Assets.xcassets/AppIcon.appiconset` from `design/icon/` masters.
