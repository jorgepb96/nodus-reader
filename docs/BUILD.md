# Build, Test and Capture

## Requirements

- macOS with Xcode 27.1 or a compatible Xcode providing the iOS 18+ and macOS 15+ SDKs. The project is developed against Xcode 27.1 / Swift 6.4 toolchain in Swift 5 language mode.
- XcodeGen 2.44+ (`brew install xcodegen`).
- Network access the first time Swift Package Manager resolves ZIPFoundation.
- iOS 18+ simulators (iPhone and iPad) and macOS 15+ for the Mac app.

Deployment targets: iOS 18.0, macOS 15.0. The app is a single multiplatform target using `supportedDestinations: [iOS, macOS]`.

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

The tests build real EPUB and PDF fixtures with the debug sample generator, import them into an in-memory SwiftData store with a temporary `FileStore`, and assert metadata, chapters, duplicates, covers, collections, manual order, themes and utilities. As of the last run: **11 tests pass**.

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

The tests launch with `-NodusSampleLibrary`, which creates real EPUB/PDF files using public-domain text and original placeholder prose, imports them through the production pipeline, and seeds collections and reading state. Debug-only.

Covered flows: Home, Library, Reader, Appearance, Collections, Collection detail, Settings, Voices, Models, Typography, Search, Player (system voice), and tap-a-word Read & Listen. The tests skip the iPad layout on iPhone and vice versa.

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

# Open the reader sheet on Moby-Dick
... -NodusSampleLibrary -NodusOpenSampleReader

# Start narration and show the Mac player bar
... -NodusSampleLibrary -NodusStartSampleNarration
```

These arguments are compiled behind `#if DEBUG` and do nothing in Release.

## Signing and distribution

- Simulator and local Mac builds do not need a team.
- For a device build, select a development team in Xcode and set a unique bundle identifier if needed. Automatic signing is enabled in `project.yml`.
- The app is currently **not sandboxed for distribution** and has no iCloud entitlements. Before distribution:
  - add the macOS App Sandbox entitlement with user-selected read-only file access;
  - add CloudKit/iCloud Documents entitlements and the container identifier;
  - add the App Group for the Share Extension;
  - audit AGPL and third-party licences;
  - validate App Store/Mac App Store policy for model downloads and open-source licensing.
- `UIBackgroundModes: audio` is present so narration can continue when the screen is locked.

## Known environment notes

- The Mac app is a normal SwiftUI `WindowGroup`; the first launch uses `.defaultSize(1360 × 860)` and a minimum content size.
- The iOS 26 simulator was used for the screenshots (iPhone 17 Pro, iPad Pro 13-inch M5, iOS 26.5). iOS 18.2 runtime is also installed and supported by the deployment target.
- System voices come from the simulator/OS. Voice names and availability vary; the Tests do not assert a specific voice.
- The app icon is assembled in `Assets.xcassets/AppIcon.appiconset` from `design/icon/` masters.
