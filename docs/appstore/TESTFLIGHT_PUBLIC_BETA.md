# Public TestFlight beta

Status on 29 October 2026. Build `0.1.0 (26)` is valid, assigned to both internal and external groups and shown as **En pruebas** in App Store Connect. The public link is enabled and serves the approved build. This does not publish an App Store version.

## Strategy in the other Nodus apps

| App | Distribution | Privacy policy | TestFlight |
| --- | --- | --- | --- |
| Nodus Presenter | Published on the App Store | `https://nodusresearch.com/presenter/privacy/` | Internal group only; no public link |
| Nodus Drift | Public TestFlight beta; App Store version still in review | `https://nodusresearch.com/drift/privacy/` | External group `Nodus Drift — Public Beta`; public link enabled |
| Nodus Reader | Public TestFlight beta only | `https://nodusresearch.com/reader/privacy/` | External group created; build 26 assigned and approved; public link enabled |

Reader follows Drift: the beta is tested through a public TestFlight link, not through an App Store release. Presenter is the App Store-published app and is not the model for this release.

## App Store Connect record

| Field | Value |
| --- | --- |
| App | Nodus Reader |
| App Store Connect app ID | `6826844742` |
| Bundle ID | `ai.nodus.reader` |
| SKU | `nodus-reader` |
| App Store state | Prepare for Submission |
| Build | `0.1.0 (26)` |
| Build processing state | Valid |
| Internal group | `Internal` |
| External group | `Nodus Reader — Public Beta` (`b2c18bee-362c-4fc0-804a-6869fb3ee638`) |
| Public link | `https://testflight.apple.com/join/SjCk8AZ1`; enabled |
| Beta App Review | Submitted; external testing is enabled (`En pruebas`) |

## TestFlight fields

**Beta App Description**

Nodus Reader is a free, open-source reading and listening app for iPhone, iPad and Mac. Import EPUB and PDF documents from Files or the Share button; keep a local library and collections; use reading themes, bookmarks, highlights, notes and search; and rebuild PDFs for reading with on-device OCR. Choose and download a Kokoro or Phonon voice on first launch, then listen with neural narration that runs on the device. Optional iCloud sync uses your own account. No Nodus accounts, ads, tracking or telemetry, and no book or audio is sent to a Nodus server.

**Feedback email**

`contact@nodusresearch.com`

**Privacy policy URL**

`https://nodusresearch.com/reader/privacy/`

**What to Test**

```text
Nodus Reader 0.1.0 (26)

This build improves library organization, chapter navigation and narration controls based on tester feedback.

PLEASE TEST
- Open the new Collections tab. Search for collections and nested subcollections, switch between folder and list views, and create a collection.
- In Library, check that filters sit directly below the book search field and that search, filtering, sorting and adding books to collections still work.
- In a book with a long chapter list, open Contents and search by chapter title or number. Tap a result and confirm that the correct chapter opens.
- Drag the contents scrollbar thumb to move quickly through the list, both with the sheet half open and fully expanded. Check that the list stays visible and that chapter/page numbers remain on one line.
- Choose 1.35× narration speed and check playback and Read & Listen highlighting after pausing, resuming and changing speed.
- Check the English and Spanish interface, PDF reading, bookmarks, notes, imports and optional personal iCloud sync.

Report problems through TestFlight with your device, iOS version and a screenshot. Books and notes only sync through your personal iCloud if you enable it. Generated audio and voice models stay on the device. There is no Nodus account, tracking or remote processing of books or audio.

```

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
```

## Contact fields

The private Beta App Review contact fields use the same owner contact as Nodus Drift. They are stored in App Store Connect and are not repeated in source control.

## Manual steps left

1. Confirm that the App Privacy answer is still **Data Not Collected** for the current build. The app has no analytics, tracking or developer-operated server. Apple, Hugging Face and TestFlight are disclosed in the policy as separate services.
2. Confirm the free-app agreement, tax and banking sections are active.
3. Build 26 is approved for the external group **Nodus Reader — Public Beta**.
4. Confirm that the public link accepts testers and serves build 26. Do not submit an App Store version.

## API state after preparation

- `betaAppLocalizations` en-US: description, feedback email and privacy URL filled.
- `betaAppReviewDetails`: owner contact copied from Drift; notes and no demo account filled.
- `betaBuildLocalizations` build 26: What to Test filled in en-US and es-ES.
- `appInfoLocalizations` en-US and es-ES: privacy policy URL filled.
- External beta group **Nodus Reader — Public Beta**: build 26 assigned; the internal group receives builds automatically.
- Public link enabled: `https://testflight.apple.com/join/SjCk8AZ1`.
- Build 26 was submitted for Beta App Review and is shown as **En pruebas** with both groups assigned. Automatic tester notifications are enabled.
- No App Store submission was created.
- App Store 1.0 metadata, categories, 4+ age rating, review details and screenshots were also prepared. The App Store version is set to manual release, has no build attached and was not submitted.

## Build 26 verification

- Source: merged PR [#23](https://github.com/jorgepb96/nodus-reader/pull/23), commit `24081101c9dfffe855d1489849ee6e97d36bc87f`; closes [#22](https://github.com/jorgepb96/nodus-reader/issues/22).
- Marketing version remains `0.1.0`; build number is `26`. No App Store version was submitted.
- Signed Release simulator build launched successfully; the signed device archive and App Store Connect upload succeeded.
- What to Test is saved in English (US) and Spanish (Spain).
- Verified group assignments: **Internal** (internal) and **Nodus Reader — Public Beta** (external). App Store Connect shows build 26 **En pruebas**.
