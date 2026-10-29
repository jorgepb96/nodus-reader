# Public TestFlight beta

Status on 29 October 2026. Build `0.1.0 (25)` is valid, assigned to the external group and approved by Beta App Review. The public link is enabled and serves the approved build. This does not publish an App Store version.

## Strategy in the other Nodus apps

| App | Distribution | Privacy policy | TestFlight |
| --- | --- | --- | --- |
| Nodus Presenter | Published on the App Store | `https://nodusresearch.com/presenter/privacy/` | Internal group only; no public link |
| Nodus Drift | Public TestFlight beta; App Store version still in review | `https://nodusresearch.com/drift/privacy/` | External group `Nodus Drift — Public Beta`; public link enabled |
| Nodus Reader | Public TestFlight beta only | `https://nodusresearch.com/reader/privacy/` | External group created; build 25 assigned and approved; public link enabled |

Reader follows Drift: the beta is tested through a public TestFlight link, not through an App Store release. Presenter is the App Store-published app and is not the model for this release.

## App Store Connect record

| Field | Value |
| --- | --- |
| App | Nodus Reader |
| App Store Connect app ID | `6826844742` |
| Bundle ID | `ai.nodus.reader` |
| SKU | `nodus-reader` |
| App Store state | Prepare for Submission |
| Build | `0.1.0 (25)` |
| Build processing state | Valid |
| Internal group | `Internal` |
| External group | `Nodus Reader — Public Beta` (`b2c18bee-362c-4fc0-804a-6869fb3ee638`) |
| Public link | `https://testflight.apple.com/join/SjCk8AZ1`; enabled |
| Beta App Review | `APPROVED` |

## TestFlight fields

**Beta App Description**

Nodus Reader is a free, open-source reading and listening app for iPhone, iPad and Mac. Import EPUB and PDF documents from Files or the Share button; keep a local library and collections; use reading themes, bookmarks, highlights, notes and search; and rebuild PDFs for reading with on-device OCR. Choose and download a Kokoro or Phonon voice on first launch, then listen with neural narration that runs on the device. Optional iCloud sync uses your own account. No Nodus accounts, ads, tracking or telemetry, and no book or audio is sent to a Nodus server.

**Feedback email**

`contact@nodusresearch.com`

**Privacy policy URL**

`https://nodusresearch.com/reader/privacy/`

**What to Test**

```text
Nodus Reader 0.1.0 (25)

This build fixes EPUB import for books with more than 2,000 chapters. Please test the areas below and report any problem with your device model, iOS version and a screenshot.

1. VOICE MODEL DOWNLOAD
- Open Settings > Voices & Models > Models.
- Download Phonon 31M (English, about 300 MB). On an iPhone or iPad with Apple silicon and Metal support, also download Kokoro.
- Confirm that the download completes, that the model appears as installed, and that narration still works after enabling Airplane Mode.

2. EPUB IMPORT
- Import an EPUB from Files. If you have a long serial novel, use one with more than 2,000 chapters.
- If you imported a long book in an earlier build, open it again without deleting or reimporting it. Confirm that the chapter list is complete and that the chapter label on Home uses the correct chapter after you read past chapter 2,000.
- Open the chapter list and scroll to the end. Confirm that every chapter is present, that the last chapter is the real last chapter of the book, and that the chapter numbers have no gaps.
- Open the last chapters and confirm that their text is present and readable.

3. READ & LISTEN SYNCHRONIZATION
- Open a book, choose Read & Listen, and start narration.
- Confirm that the current sentence and the current word are highlighted and advance together with the audio.
- Pause, resume, change speed, turn the page and lock the screen. Confirm that the highlight remains synchronized with the audio after each action.

4. PDF IMPORT AND READING
- Import a PDF with a text layer and a scanned PDF.
- Open both in Original and in Intelligent Reading. Check reading order, OCR text, tables, search and the page scrollbar.
- Add a highlight and a note to a PDF page and confirm that they appear on the correct page.

5. OPTIONAL CHECKS
- Enable iCloud sync with your own Apple ID (it is off by default).
- Import a document with the Share Extension.
- Switch the interface between English and Spanish.

Report bugs and screenshots through TestFlight. Deleting a book removes its local file and generated audio. The app does not send books or audio to a Nodus server.
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
3. Build 25 is approved for the external group **Nodus Reader — Public Beta**.
4. Confirm that the public link accepts testers and serves build 25. Do not submit an App Store version.

## API state after preparation

- `betaAppLocalizations` en-US: description, feedback email and privacy URL filled.
- `betaAppReviewDetails`: owner contact copied from Drift; notes and no demo account filled.
- `betaBuildLocalizations` build 25: What to Test filled in en-US and es-ES.
- `appInfoLocalizations` en-US and es-ES: privacy policy URL filled.
- External beta group **Nodus Reader — Public Beta**: build 25 assigned; the internal group receives builds automatically.
- Public link enabled: `https://testflight.apple.com/join/SjCk8AZ1`.
- Beta App Review approved for build 25; state `APPROVED`.
- No App Store submission was created.
- App Store 1.0 metadata, categories, 4+ age rating, review details and screenshots were also prepared. The App Store version is set to manual release, has no build attached and was not submitted.
