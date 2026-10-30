# Public TestFlight beta

## Current release — 30 October 2026

Build **0.1.0 (29)** has been uploaded and processed as VALID for iOS/iPadOS and native macOS. Both platforms are assigned to **Internal** (automatic access) and **Nodus Reader — Public Beta**.

- iOS/iPadOS 29: **APPROVED / IN_BETA_TESTING** for the public beta and available internally.
- macOS 29: **IN_BETA_TESTING** internally; **READY_FOR_BETA_SUBMISSION** externally. Withdrawn from Apple review at the user's request; do not resubmit until explicitly requested.
- The macOS 28 and 29 review submissions have both been withdrawn without expiring their builds. iOS 28 was unchanged.
- The [public link](https://testflight.apple.com/join/SjCk8AZ1) and screenshot feedback remain enabled. iOS builds on Apple silicon Macs remain disabled for both groups.
- No App Store production submission was created.

See [build 29 verification and delivery](BUILD29_VERIFICATION.md), the [source fingerprint](BUILD29_SOURCE_FINGERPRINT.txt), and the [English](TestFlight-29-en.txt) / [Spanish](TestFlight-29-es.txt) notes for the eight feedback fixes and exact test results.

See [post-build-29 macOS fixes and description updates](POST29_MACOS_AND_COPY.md) for changes not included in the uploaded binary.

## Previous-release reference — build 28

The following records describe the prior build and original beta setup.

Status on 30 October 2026. Build `0.1.0 (28)` is valid for iOS and macOS. The iOS build is approved, assigned to both groups and `IN_BETA_TESTING` for external testers. The native macOS build is `IN_BETA_TESTING` for the internal group and `WAITING_FOR_BETA_REVIEW` for the external group (submitted 29 October at 17:09 PDT). The earlier macOS build 27 was expired: it was stuck in beta review and its exported app crashed in dyld because of the runpath bug fixed in 28. The iOS build is no longer offered on Apple silicon Macs: *Test iPhone and iPad apps on Apple silicon Macs* is disabled for both groups. The public link remains enabled. This does not publish an App Store version.

## Strategy in the other Nodus apps

| App | Distribution | Privacy policy | TestFlight |
| --- | --- | --- | --- |
| Nodus Presenter | Published on the App Store | `https://nodusresearch.com/presenter/privacy/` | Internal group only; no public link |
| Nodus Drift | Public TestFlight beta; App Store version still in review | `https://nodusresearch.com/drift/privacy/` | External group `Nodus Drift — Public Beta`; public link enabled |
| Nodus Reader | Public TestFlight beta only | `https://nodusresearch.com/reader/privacy/` | External group; build 28 assigned (iOS approved and in testing, macOS in Beta App Review); public link enabled |

Reader follows Drift: the beta is tested through a public TestFlight link, not through an App Store release. Presenter is the App Store-published app and is not the model for this release.

## App Store Connect record

| Field | Value |
| --- | --- |
| App | Nodus Reader |
| App Store Connect app ID | `6826844742` |
| Bundle ID | `ai.nodus.reader` |
| SKU | `nodus-reader` |
| App Store state | Prepare for Submission |
| Build | `0.1.0 (28)` (iOS and macOS) |
| Build processing state | Valid for both platforms |
| iOS delivery UUID | `b0465230-3fec-4a6b-887f-0982ceabb4ce` |
| macOS delivery UUID | `2d23e765-7a58-4db6-a03c-ffc4c8bb4a52` |
| macOS App Store version | `1.0`, Prepare for Submission; not submitted |
| Internal group | `Internal` |
| External group | `Nodus Reader — Public Beta` (`b2c18bee-362c-4fc0-804a-6869fb3ee638`) |
| Public link | `https://testflight.apple.com/join/SjCk8AZ1`; enabled |
| Beta App Review | iOS approved and `IN_BETA_TESTING`; macOS `WAITING_FOR_BETA_REVIEW` |
| iOS builds on Apple silicon Macs | Disabled for both groups |

## TestFlight fields

**Beta App Description**

Nodus Reader is a free, open-source reading and listening app for iPhone, iPad and Mac. Import EPUB, PDF, TXT, Markdown, HTML and RTF documents; organize your local library with collections; and read with themes, bookmarks, highlights, notes and search. Intelligent Reading rebuilds PDF text with on-device OCR. Download a Kokoro or Phonon voice model, then listen offline with neural narration that runs on your device. Optional synchronization uses your personal iCloud account. Voice models and generated audio stay on each device. No ads, tracking or telemetry.

**Feedback email**

`contact@nodusresearch.com`

**Privacy policy URL**

`https://nodusresearch.com/reader/privacy/`

**What to Test**

```text
Nodus Reader 0.1.0 (28)

This build addresses reader and narration feedback on iPhone, iPad and Mac.

What to test:
- Open a book: playback controls are visible immediately. Play starts from the visible page.
- Search the contents and switch chapters repeatedly, including in long books. Narration should follow the selected chapter and preserve a paused state.
- Switch between Read, Listen and Read & Listen. The read-along mini player should reopen the reader at the current position.
- Select a speed, close the app completely and reopen it. The selected speed should remain in effect.
- The position bar now seeks only within the current chapter. Drag from its handle; tapping the track should not seek.
- Listen to long sentences with Kokoro and sentence starts with Phonon; check pauses and clicks.
- On Mac, verify normal launch and window responsiveness. The app requires Apple silicon and macOS 15 or later.

Screenshot feedback remains enabled for both TestFlight groups. If the screenshot editor omits beta feedback, use TestFlight > Nodus Reader > Send Beta Feedback > Include Screenshot.
```

**What to Test (macOS)**

The same build 28 text is used for macOS in en-US and es-ES. The source of truth is
`build/TestFlight-28-en.txt` and `build/TestFlight-28-es.txt`; both were set on the
macOS build through the App Store Connect API.

**Beta App Review notes**

```text
Nodus Reader is a free, open-source, local-first reading and listening app. No account or demo login is required. This is a public TestFlight beta, not an App Store submission.

FIRST-RUN SETUP (required)
The app opens on a mandatory voice setup screen. Tap “Choose a voice model”, choose Phonon 31M English (about 300 MB) and wait for the download. No Hugging Face account is needed for this model. Kokoro requires a physical device with Metal and is not required for review. After installation, the library opens.

TEST FLOW
1. Import a public-domain EPUB or PDF with Files. Open it and test paged/continuous reading.
2. Start Read & Listen. Check sentence and word highlighting, speed, voice, sleep timer and background playback.
3. Open a PDF in Original and Intelligent Reading. Check on-device OCR, reading order and the page scrollbar.
4. Optional: enable iCloud sync with your own Apple ID. It is off by default and is not needed to review the app.
5. Test the Share Extension with a local file.

The app does not collect data or include analytics. Books, notes and generated audio stay on the device unless the tester enables personal iCloud sync. Model downloads use Hugging Face; Phonon 31M is available without an account.

MAC BUILD (0.1.0 (28))
The same app record includes a native macOS build for Apple silicon Macs running macOS 15 or later. The Share Extension is iOS-only; on Mac, import documents with File > Import or by dragging them into the window. The first-run voice setup is the same: Phonon 31M English (about 300 MB) downloads without an account. The Reading window is a separate window. No Mac-specific account or login is required.
```

## Contact fields

The private Beta App Review contact fields use the same owner contact as Nodus Drift. They are stored in App Store Connect and are not repeated in source control.

## Manual steps left

1. Confirm that the App Privacy answer is still **Data Not Collected** for the current build. The app has no analytics or tracking; document processing and narration run on the device. Apple, Hugging Face and TestFlight are disclosed in the policy as separate services.
2. Confirm the free-app agreement, tax and banking sections are active.
3. The iOS build 28 is approved and assigned to **Nodus Reader — Public Beta**; external testers can install it.
4. The macOS build 28 is assigned to **Nodus Reader — Public Beta** and submitted for Beta App Review; wait for Apple's approval, then confirm it appears for the external group. Do not resubmit while it is `WAITING_FOR_REVIEW`.
5. Install the macOS build on a Mac running **macOS 15.8** (the tester's version) and verify launch, import, narration and iCloud once Apple approves it.
6. Confirm that *Test iPhone and iPad apps on Apple silicon Macs* stays disabled for both groups. Do not submit an App Store version.

## API state after preparation

- `betaAppLocalizations` en-US: description, feedback email and privacy URL filled.
- `betaAppReviewDetails`: owner contact copied from Drift; notes extended with the macOS build and the iOS-only Share Extension; no demo account filled.
- `betaBuildLocalizations` iOS build 28: What to Test from `build/TestFlight-28-en.txt` and `build/TestFlight-28-es.txt` in en-US and es-ES.
- `betaBuildLocalizations` macOS build 28: the same build 28 text in en-US and es-ES.
- `appInfoLocalizations` en-US and es-ES: privacy policy URL filled.
- External beta group **Nodus Reader — Public Beta**: iOS build 28 approved and assigned; macOS build 28 assigned and submitted for Beta App Review. The internal group receives both builds automatically (`IN_BETA_TESTING`).
- macOS build 27 was expired on 30 October 2026 to release the beta-review train; it remains in App Store Connect with state `EXPIRED`.
- Public link enabled: `https://testflight.apple.com/join/SjCk8AZ1`.
- `iosBuildsAvailableForAppleSiliconMac` is `false` for both beta groups.
- App Store macOS version `1.0` created in Prepare for Submission; no App Store submission was created.
- App Store 1.0 metadata, categories, 4+ age rating, review details and screenshots were also prepared. The iOS App Store version is set to manual release, has no build attached and was not submitted.

## Build 27 verification

- Source: merged PR [#24](https://github.com/jorgepb96/nodus-reader/pull/24), commit `a871e143e9e109a23141185eaad734f6886706f1`. Follow-up to the tester feedback in [#22](https://github.com/jorgepb96/nodus-reader/issues/22).
- The only change over build 26 is the centred “New collection / Nueva colección” button in the empty Collections state. Marketing version remains `0.1.0`; build number is `27`. No App Store version was submitted.
- The centred button was verified in the iOS Simulator in Spanish and the capture is stored in `docs/screenshots/iPhone-25-CollectionsEmpty.png`.
- Signed Release simulator build launched successfully; the Release device archive (`build/NodusReader-0.1.0-27.xcarchive`) and the App Store Connect upload succeeded (Delivery UUID `4ea8dd7e-4417-4974-870b-89ef9bb89394`).
- What to Test is the same text as build 26, saved in English (US) and Spanish (Spain); only the build number in the heading changed.
- Verified group assignments: **Internal** (internal) and **Nodus Reader — Public Beta** (external). The iOS build 27 remains **Approved** / **IN_BETA_TESTING**; the macOS build 27 was **WAITING_FOR_BETA_REVIEW** until it was expired on 30 October 2026 and is now `EXPIRED`.
- macOS build 27: archive `build/NodusReader-macOS-0.1.0-27.xcarchive`, signed package `build/export-macOS/Nodus Reader.pkg` (21.3 MB, macOS 15.0+, arm64), validated and uploaded (Delivery UUID `5d6c044a-901b-4285-a4b9-f8d6124c6067`). It was superseded by 28 because its exported app could not load the embedded frameworks (runpath bug); the build remains in App Store Connect as expired, not deleted.
- The macOS app is sandboxed (`Config/NodusReader-macOS.entitlements`) and was launched locally with `-NodusSampleLibrary` on macOS 27. The first run on macOS 15.8 is still the public beta's validation step.

## Build 28 verification (30 October 2026)

- Source: HEAD `53d453bc78a737a49f49c09dccb0789a943771ea` plus the uncommitted working tree; fingerprint in `docs/appstore/BUILD28_SOURCE_FINGERPRINT.txt`. Marketing `0.1.0`, build `28`.
- iOS/iPadOS archive `build/NodusReader-iOS-0.1.0-28.xcarchive`; IPA `build/export-ios-28/Nodus Reader.ipa` (47,276,632 bytes), Apple Distribution with the App Store provisioning profile, arm64. Delivery UUID `b0465230-3fec-4a6b-887f-0982ceabb4ce`.
- macOS archive `build/NodusReader-macOS-0.1.0-28.xcarchive`; package `build/export-macOS-28/Nodus Reader.pkg` (45,940,958 bytes), signed with the 3rd Party Mac Developer Installer identity; app signed with Apple Distribution, sandbox/iCloud/App Group, macOS 15.0+, arm64. Delivery UUID `2d23e765-7a58-4db6-a03c-ffc4c8bb4a52`.
- Groups: both 28 builds are in **Internal** and **Nodus Reader — Public Beta**; the public link is enabled; `iosBuildsAvailableForAppleSiliconMac` remains false.
- iOS 28: processing **VALID**, Beta App Review **APPROVED**, external state **IN_BETA_TESTING**.
- macOS 28: processing **VALID**, Beta App Review **WAITING_FOR_REVIEW** (submitted 17:09 PDT). macOS 27 was expired on 30 October to release the beta-review train; it remains in App Store Connect as expired.
- Player fix: the iOS player is now a `.page` sheet. The iPad regression reaches speed, voice, sleep and mode without scrolling, and the saved 1.35× survives relaunch. No assertion was weakened; the optional swipe remains as a fallback.
- Mac fix: `LD_RUNPATH_SEARCH_PATHS[sdk=macosx*] = @executable_path/../Frameworks`. The signed archive app launched, stayed responsive and the main thread sampled in `mach_msg`; the first-run voice sheet blocks AppKit termination, not the main thread. The exported distribution app is not runnable outside an installed location (AMFI rejects its restricted entitlements), so launch verification used the signed archive.
- Tests: unit suites on macOS, iPhone and iPad 89 functions passed / 10 opt-in skipped (107 runs including parameterised cases); full iPhone UI suite 17 passed / 2 skipped; the iPad player regression passed; signed Release simulator builds launched on iPhone and iPad. Real-model tests passed: long Kokoro+Phonon paragraph, Kokoro Spanish and out-of-dictionary English.
- The screenshot-feedback editor issue remains unresolved in code; this build does not claim a fix.

## Screenshot feedback report (29 October 2026)

- A tester on build 27, iPhone 16 Pro Max, iOS 26.7.1 reports that the screenshot editor no longer offers beta feedback; submitting a saved screenshot through the TestFlight app still works.
- Inspected App Store Connect group settings: **Internal** and **Nodus Reader — Public Beta** both show **Tester Feedback: Feedback On**. No group setting was changed.
- Apple's [tester feedback documentation](https://developer.apple.com/help/app-store-connect/test-a-beta-version/view-tester-feedback) explains that disabling feedback in any of a tester's groups prevents direct screenshot feedback. The two current groups do not have that restriction.
- Source inspection found no screenshot suppression or custom screenshot-editor integration. The screenshot feedback menu is supplied by iOS/TestFlight; its absence is not an app-owned menu item to restore.
- Status: unresolved, pending reproduction on the affected iOS/TestFlight versions. No application build or tests were run for this investigation. Do not mark the report fixed solely because feedback is enabled in App Store Connect.
- Available workaround: TestFlight → Nodus Reader → Send Beta Feedback → Include Screenshot, as described by [Apple](https://testflight.apple.com/).
