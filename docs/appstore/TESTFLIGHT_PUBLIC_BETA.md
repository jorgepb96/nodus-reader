# Public TestFlight beta: prepared fields

Status on 27 October 2026. This file records the values prepared for the public TestFlight beta. It does not submit the app for Beta App Review and does not publish an App Store version.

## Strategy in the other Nodus apps

| App | Distribution | Privacy policy | TestFlight |
| --- | --- | --- | --- |
| Nodus Presenter | Published on the App Store | `https://nodusresearch.com/presenter/privacy/` | Internal group only; no public link |
| Nodus Drift | Public TestFlight beta; App Store version still in review | `https://nodusresearch.com/drift/privacy/` | External group `Nodus Drift — Public Beta`; public link enabled |
| Nodus Reader | Public TestFlight beta only | `https://nodusresearch.com/reader/privacy/` | Internal group only; external group not created |

Reader follows Drift: the beta is tested through a public TestFlight link, not through an App Store release. Presenter is the App Store-published app and is not the model for this release.

## App Store Connect record

| Field | Value |
| --- | --- |
| App | Nodus Reader |
| App Store Connect app ID | `6826844742` |
| Bundle ID | `ai.nodus.reader` |
| SKU | `nodus-reader` |
| App Store state | Prepare for Submission |
| Build | `0.1.0 (24)` |
| Build processing state | Valid |
| Internal group | `Internal` |
| External group | Not created |
| Public link | Not created |
| Beta App Review | Not submitted |

## TestFlight fields

**Beta App Description**

Nodus Reader is a free, open-source reading and listening app for iPhone, iPad and Mac. Import EPUB and PDF documents from Files or the Share button; keep a local library and collections; use reading themes, bookmarks, highlights, notes and search; and rebuild PDFs for reading with on-device OCR. Choose and download a Kokoro or Phonon voice on first launch, then listen with neural narration that runs on the device. Optional iCloud sync uses your own account. No Nodus accounts, ads, tracking or telemetry, and no book or audio is sent to a Nodus server.

**Feedback email**

`contact@nodusresearch.com`

**Privacy policy URL**

`https://nodusresearch.com/reader/privacy/`

**What to Test**

```text
Nodus Reader 0.1.0 (24) — first public beta.

FIRST-RUN SETUP
• Voice setup is required. Tap “Choose a voice model”, install Phonon 31M (English, about 300 MB), and wait for the download to finish. No Hugging Face account is needed for Phonon.
• After the model is installed, the library opens. No demo account is required.

PLEASE CHECK
• Import an EPUB and a PDF from Files; check the reading themes, library, collections, search, bookmarks, highlights and notes.
• Open a book and start Read & Listen. Check sentence and word highlighting, voice selection, speed, sleep timer and lock-screen controls.
• Open a PDF in Original and Intelligent Reading. Check text order, OCR, tables and the page scrollbar.
• Optional: enable iCloud sync with your own Apple ID, import a book on one device and check it on another.
• Use the Share Extension to import a document or web link.
• Check the English and Spanish interface.

Deleting a book removes its local file and generated audio. The app does not send books or audio to a Nodus server. Report bugs and screenshots through TestFlight.
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
3. Create the external group **Nodus Reader — Public Beta** and add build 24.
4. Submit that build for Beta App Review. This is not an App Store submission.
5. After approval, enable the public link and share it. Do not submit an App Store version.

## API state after preparation

- `betaAppLocalizations` en-US: description, feedback email and privacy URL filled.
- `betaAppReviewDetails`: owner contact copied from Drift; notes and no demo account filled.
- `betaBuildLocalizations` build 24: What to Test filled.
- `appInfoLocalizations` en-US and es-ES: privacy policy URL filled.
- No external beta group, public link, Beta App Review submission or App Store submission was created.
