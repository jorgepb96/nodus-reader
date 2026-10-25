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
pause-based word alignment and the durable sync outbox/tombstone rules, queued and
folder imports, synced-book text rebuilding, synced preferences, background search and
off-main pagination, per-book appearance, continuous-scroll slicing and PDF note
anchoring. As of the last run: **46 tests pass** (plus the opt-in model test).

An opt-in integration test downloads every model this machine can run (Phonon 31M
and, on an Apple Silicon Mac, Kokoro 82M; about 500 MB), synthesizes a sentence with
each and checks the word alignment that drives the read-along highlight:

```bash
mkdir -p /tmp/nodus-models-home/Library/Preferences
TEST_RUNNER_NODUS_MODEL_DOWNLOAD_TESTS=1 TEST_RUNNER_CFFIXED_USER_HOME=/tmp/nodus-models-home \
xcodebuild test -project NodusReader.xcodeproj -scheme NodusReader \
  -destination 'platform=macOS' \
  -only-testing:'NodusReaderTests/modelDownloadsSynthesizeAndAlignWithText()' \
  -derivedDataPath build/DerivedData-mac CODE_SIGNING_ALLOWED=NO
```

`CFFIXED_USER_HOME` keeps the downloaded models out of the real Mac app container.

The DesignSystem package has its own test target:

```bash
swift test --package-path Modules/DesignSystem
```

## UI tests and screenshots

If more than one simulator has the same name (for example two “iPhone 17 Pro”
devices on different runtimes), `name=` is ambiguous; pass `id=<UDID>` from
`xcrun simctl list devices`. Uninstall a stale runner first:
`xcrun simctl uninstall <UDID> ai.nodus.reader.uitests.xctrunner`.

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

The Phonon test requires a Phonon bundle in the simulator app container; without one
it is reported as **skipped**, not passed. Install it
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

The Mac build is not sandboxed, so these runs write to the real
`~/Library/Application Support/NodusReader`. To test against a throwaway library,
prefix the command with `CFFIXED_USER_HOME=/tmp/nodus-home` (create
`/tmp/nodus-home/Library/Preferences` first).

## TestFlight (iOS/iPadOS)

The project signs automatically with team `6RPLS9EA4X`; `ITSAppUsesNonExemptEncryption`
is `false` (the app only uses HTTPS), so uploads need no export-compliance answer.
App Store Connect app: **Nodus Reader** (`ai.nodus.reader`, SKU `nodus-reader`).
Internal TestFlight group **Internal** receives every Xcode build automatically.

```bash
# Bump CURRENT_PROJECT_VERSION in project.yml for every upload, then:
xcodegen generate
xcodebuild archive -project NodusReader.xcodeproj -scheme NodusReader -configuration Release \
  -destination 'generic/platform=iOS' -archivePath build/NodusReader-iOS.xcarchive \
  -derivedDataPath build/DerivedData-ios -allowProvisioningUpdates
xcodebuild -exportArchive -archivePath build/NodusReader-iOS.xcarchive \
  -exportOptionsPlist Config/ExportOptions-AppStore.plist -exportPath build/export \
  -allowProvisioningUpdates
```

Before uploading, launch a **signed** Release build in the Simulator
(`xcodebuild -configuration Release -destination 'platform=iOS Simulator,id=<UDID>'
-allowProvisioningUpdates build`, then `simctl install` and `simctl launch`). Unsigned
test builds have no iCloud or App Group entitlements and cannot catch
entitlement-dependent failures such as the build 1 launch crash.

Use an existing `-derivedDataPath` with resolved packages: a fresh one may fail to
clone package submodules. The Mac app is not on TestFlight yet; it needs the App
Sandbox entitlement first (see below).

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

## Phonon 40M Spanish

Gradium publishes Phonon 40M Spanish only as PyTorch/GGUF (gated, CC BY-NC 4.0). The app
converts it on the device: Settings › Voices & Models › Phonon 40M Spanish › Download,
after signing in to Hugging Face with an account that accepted the model's conditions.
That needs the PhononCore build with `ptts_export_coreml` (`Modules/PhononTTS/engine/`).
Opt-in end-to-end check (downloads about 128 MB with the token in the given file):

```bash
TEST_RUNNER_NODUS_HF_TOKEN_FILE=$HOME/.cache/huggingface/token \
xcodebuild test -project NodusReader.xcodeproj -scheme NodusReader \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:'NodusReaderTests/phonon40SpanishConvertsOnDevice()'
```

### Alternative: convert on a Mac and install from file

To prepare the bundle elsewhere, convert it once on a
Mac with a Hugging Face account that accepted the model's access conditions
(`hf auth login`), with Gradium's exporter at the runtime version the app ships:

```bash
git clone --depth 1 --branch v0.4.1 https://github.com/gradium-ai/xn-ptts.git
cd xn-ptts && cargo build --release -p ptts --example export_coreml --features hub
# The 25 Spanish voices of gradium/phonon-voices (Apache-2.0), named as in voices.jsonl.
target/release/examples/export_coreml \
  --model hf://gradium/phonon-40m-es@f0d2f39c9b58ad4c19a189e3ba989ee4df393cc5 \
  --voices <folder of Spanish voice .safetensors> phonon-40m-es-coreml
```

The result (about 200 MB, `bundle.json` with `languages: ["es"]`) goes in Files, and
Settings › Voices & Models › Phonon 40M Spanish › Install from file installs it into its
own folder beside Phonon 31M. Keep the converted copy to your own devices: the licence
is non-commercial and the model is gated. Opt-in check:

```bash
TEST_RUNNER_NODUS_PHONON40_ES_BUNDLE=<converted folder> TEST_RUNNER_CFFIXED_USER_HOME=<scratch home> \
xcodebuild test -project NodusReader.xcodeproj -scheme NodusReader -destination 'platform=macOS' \
  -only-testing:'NodusReaderTests/convertedPhonon40SpanishBundleNarratesSpanish()' \
  -derivedDataPath build/DerivedData-mac CODE_SIGNING_ALLOWED=NO
```
