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
anchoring. As of build 28: **89 test functions pass (107 runs including
parameterised cases) and 10 opt-in model tests skip** on iPhone, iPad and macOS.
The ten opt-in cases were run separately against real Kokoro and Phonon models; see
the build 28 evidence below.

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
Settings, Voices, Models, Typography, Search, Player (neural voice), voice onboarding, tap-a-word
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

The Mac build is sandboxed; these runs write inside
`~/Library/Containers/ai.nodus.reader/Data/Library/Application Support/NodusReader`.
Remove that container to reset the debug library and its models. The unit tests still
use `CFFIXED_USER_HOME` because their test host is built with
`CODE_SIGNING_ALLOWED=NO` and is not sandboxed.

## TestFlight (iOS/iPadOS and macOS)

Current delivery: **0.1.0 (32)**. See [build 32 validation and TestFlight state](appstore/BUILD32_VERIFICATION.md).

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
clone package submodules. The Mac app is on TestFlight too (build 28); its archive uses
the sandbox entitlements and the same build number.

If Xcode reports `accessing build database ... disk I/O error` while archiving, use a
fresh DerivedData outside the repository (`/tmp/...`) plus
`-clonedSourcePackagesDirPath` pointing at an already-resolved `SourcePackages`. Build
28 was archived this way after repeated `build.db` failures inside `build/`.

### macOS

The Mac app is signed with `Config/NodusReader-macOS.entitlements` (App Sandbox,
user-selected read-only file access, outgoing network, CloudKit/iCloud Documents,
the ubiquity container and the App Group) through the
`CODE_SIGN_ENTITLEMENTS[sdk=macosx*]` setting. The narration stack is arm64-only,
so archive the Mac app for arm64 only.

The target also sets `LD_RUNPATH_SEARCH_PATHS[sdk=macosx*]` to
`@executable_path/../Frameworks`. XcodeGen's application preset uses the iOS runpath
(`@executable_path/Frameworks`); with that value the archived and exported Mac app
could not load its embedded SwiftPM frameworks (build 27 crashed in dyld before
`main`). Build 28 fixes it and was launched from the signed archive.

Register the build Mac as a Mac development device the first time. Then:

```bash
xcodebuild archive -project NodusReader.xcodeproj -scheme NodusReader -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath build/NodusReader-macOS-0.1.0-28.xcarchive \
  -derivedDataPath /tmp/nodus-reader-build28-mac-release \
  -clonedSourcePackagesDirPath "$PWD/build/DerivedData-mac/SourcePackages" \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=NO -allowProvisioningUpdates
xcodebuild -exportArchive -archivePath build/NodusReader-macOS-0.1.0-28.xcarchive \
  -exportOptionsPlist Config/ExportOptions-macOS.plist \
  -exportPath build/export-macOS-28 -allowProvisioningUpdates
xcrun altool --upload-app -f "build/export-macOS-28/Nodus Reader.pkg" \
  --apiKey <key-id> --apiIssuer <issuer-id> --p8-file-path <AuthKey.p8>
```

The App Store Connect record has a macOS version **1.0** in Prepare for Submission
(not submitted) so the platform accepts builds. The export produces a signed `.pkg`
whose `Distribution` declares macOS 15.0 and arm64. Allow the keychain prompts for
the Mac App Distribution and Mac Installer Distribution certificates once. Build 28
needed the login-keychain password for the legacy `mac-installer-legacy` key; the
authorization was entered interactively. If `productbuild` waits for the login-keychain
password, import both certificates into a temporary keychain with `security import ... -A`,
unlock it and put it first with `security list-keychains -s`; restore the original
search list after the export. A distribution-signed `.app` extracted from the `.pkg`
does not launch outside an installed App Store location (AMFI rejects its restricted
entitlements); verify launch with the signed archive app, not with a copied payload.

TestFlight: **Internal** receives every build automatically; assign the build to
**Nodus Reader — Public Beta** and submit it for Beta App Review. Keep
*Test iPhone and iPad apps on Apple silicon Macs* disabled for both groups so the iOS
build is not offered on Mac (build 26 crashed there; the native Mac build is the
supported path).

## Build 28 evidence (0.1.0 (28))

Archived and uploaded on 30 October 2026 from HEAD `53d453bc78a737a49f49c09dccb0789a943771ea`
plus the uncommitted working tree. Source fingerprint: `docs/appstore/BUILD28_SOURCE_FINGERPRINT.txt`.

- TestFlight deliveries: iOS `b0465230-3fec-4a6b-887f-0982ceabb4ce` (47,276,632 bytes)
  and macOS `2d23e765-7a58-4db6-a03c-ffc4c8bb4a52` (45,940,958 bytes).
- iOS/iPadOS: archive `build/NodusReader-iOS-0.1.0-28.xcarchive`; IPA
  `build/export-ios-28/Nodus Reader.ipa`, Apple Distribution, App Store provisioning
  profile, arm64. App Store Connect: processing **VALID**, Beta App Review
  **APPROVED**, external state **IN_BETA_TESTING**.
- macOS: archive `build/NodusReader-macOS-0.1.0-28.xcarchive`; package
  `build/export-macOS-28/Nodus Reader.pkg`, signed with the 3rd Party Mac Developer
  Installer identity; app signed with Apple Distribution and the sandbox/iCloud/App
  Group entitlements, macOS 15.0+, arm64. App Store Connect: **VALID**, Beta App
  Review **WAITING_FOR_REVIEW** (submitted 29 October 17:09 PDT). macOS build 27 was
  expired to free the train: it was still in beta review and its exported app had the
  dyld runpath failure.
- Signed archive app launch: the process stayed alive, the main thread was idle in
  `mach_msg`, and the window/accessibility hierarchy answered (opened the Voices
  settings sheet). The modal voice-setup sheet blocks AppKit termination; that is not
  a hang.
- Signed Release simulator builds launched on the iPhone 17 Pro and the iPad Pro
  13-inch (M5) as 0.1.0 (28) without crashing.
- Tests: macOS, iPhone and iPad unit suites 89 test functions passed / 10 opt-in
  skipped (107 runs including parameterised cases); full iPhone UI suite 17 passed /
  2 skipped; the iPad player regression passed and no longer needs the scroll
  workaround; the same regression passed on iPhone. Real-model opt-in tests passed
  for the long Kokoro/Phonon paragraph, Kokoro Spanish (three voices × five
  sentences) and Kokoro out-of-dictionary English.
- The iOS player is now a `.page` sheet, so the speed/voice/sleep/mode row is visible
  without scrolling on iPad.
- The iOS/TestFlight screenshot-feedback editor issue remains unresolved in code.

## Signing and distribution

- Simulator and local Mac builds do not need a team when `CODE_SIGNING_ALLOWED=NO`.
- For a device build, select a development team that owns
  `iCloud.ai.nodus.reader` and `group.ai.nodus.reader`. Automatic signing is enabled
  in `project.yml`.
- `Config/NodusReader.entitlements` contains CloudKit, iCloud Documents, the
  ubiquity container and the App Group for iOS. `Config/NodusReader-macOS.entitlements`
  adds the Mac App Sandbox, user-selected read-only file access and outgoing network
  access for macOS. `Config/NodusReaderShare.entitlements` contains the App Group.
- Unsigned builds deliberately report iCloud unavailable; constructing `CKContainer`
  without the entitlement would abort the process.
- Before distribution:
  - deploy the CloudKit development schema to production;
  - audit AGPL and third-party licences;
  - validate App Store/Mac App Store policy for model downloads and open-source licensing.
- `UIBackgroundModes: audio` is present so narration can continue when the screen is locked.

## Known environment notes

- The Mac app is a normal SwiftUI `WindowGroup`; the first launch uses `.defaultSize(1360 × 860)` and a minimum content size. It is sandboxed and stores its library in `~/Library/Containers/ai.nodus.reader/Data/Library/Application Support/NodusReader`.
- Build 28 of the Mac app was launched from its signed archive on macOS 27.0.1: the window rendered and answered accessibility queries; no hang was observed. The first run still shows the mandatory voice-setup sheet, and AppKit blocks termination while that modal sheet is open. macOS build 28 is waiting for Apple's beta review; macOS 15.8 remains the oldest tester system (the build 26 crash report).
- The iOS 26 simulator was used for the screenshots (iPhone 17 Pro, iPad Pro 13-inch M5, iOS 26.5). iOS 18.2 runtime is also installed and supported by the deployment target.
- Narration needs an installed Kokoro or Phonon model; there is no system-voice fallback. Tests that need narration skip when no model is installed.
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


## Build 29 — reader feedback (30 October 2026)

The eight screenshot/text feedback fixes are shipped in 0.1.0 (29) for iOS/iPadOS and native macOS. All applicable final unit and UI regressions passed, including exact-pause persistence, process relaunch, native line-following and per-book model/voice resolution. Localization: 710 keys, no missing Spanish or placeholder mismatches. Signed Release startup was checked on both simulators and the native Mac archive app; UI playback tests emitted no sound.

Both builds reached VALID and are assigned to Internal and Nodus Reader — Public Beta. iOS is approved and externally testing. macOS is internally testing; its beta review submission was withdrawn at the user's request and is now READY_FOR_BETA_SUBMISSION. Do not resubmit macOS until explicitly requested. The older Mac 28 review submission was also withdrawn without expiring its build. No App Store production version was submitted.

- iOS delivery: `7b916c92-b4df-431b-97e5-0f6288fee35f`.
- macOS delivery: `9a0e97c6-5905-4ae8-8046-815b9d746c57`.
- [Validation, artifacts and known limits](appstore/BUILD29_VERIFICATION.md).
- [App-source and artifact fingerprint](appstore/BUILD29_SOURCE_FINGERPRINT.txt).

Post-build-29 macOS cleanup, nonmodal model setup and product-copy updates are source changes pending a new binary; see [verification and review hold](appstore/POST29_MACOS_AND_COPY.md).

## Build 30 — iCloud event queue

The event-driven sync fixes were merged in [PR #30](https://github.com/jorgepb96/nodus-reader/pull/30). iOS/iPadOS 0.1.0 (30) is VALID and available to Internal and Public Beta testers. Final iPhone, iPad and macOS unit suites each passed 115 tests with 10 optional skips; the three selected iPhone UI regressions passed (the iCloud UI case is skipped on iPad). See [build 30 verification and delivery](appstore/BUILD30_VERIFICATION.md) for exact evidence, signed artifacts, source identity and live iCloud validation limits.
