# Reader, playback and Home fixes — 2026-11-02

Tracks [issue #67](https://github.com/jorgepb96/nodus-reader/issues/67).

## Behaviour

- PDF Intelligent Reading observes visible pages without binding a top scroll
  anchor. Narration follows the spoken line; explicit navigation remains a
  one-shot jump. The end of the reflow reports the final original page.
- iCloud originals and covers use coordinated reads, including dataless files
  and hidden placeholders. Downloads validate the staged original's size before
  replacing a local copy. Opening a book waits for an existing download, and
  file access can recover independently of CloudKit metadata availability.
- Mac Read & Listen waits for the original before starting narration. The reader
  marks the document opened after the file becomes available.
- The Mac window background and detail toolbar take the app palette. Settings
  initially selects App and resets that selection when revisited.
- Completed narration exposes a circular replay control in the reader, player,
  mini player and Mac bar. Play, the keyboard command and remote play restart at
  the first sentence after completion; a paused final sentence remains resumable.
- Home shows nonempty shelves in EPUB, Texts, PDF, Markdown, HTML and RTF order.
  Texts includes pasted and imported TXT documents. Finished documents remain
  available, and each shelf's See all destination contains that format only.

## Verification

The Xcode result summary counts below exclude skipped tests and count each
parameterized test definition once. There were no test failures.

| Destination | Passed | Skipped | Scope |
| --- | ---: | ---: | --- |
| iPhone 17 Pro, iOS 26.5 simulator | 189 | 12 | Unit/integration suite and three UI tests |
| iPad Pro 13-inch (M5), iOS 26.5 simulator | 186 | 12 | Unit/integration suite, using the same compiled test bundle |
| Apple Silicon Mac, macOS 27.0.1 | 183 | 12 | Unit/integration suite, with two OCR tests excluded |

The three iPhone UI tests cover Home's format destination and App theme default,
PDF search and its reflow scrollbar, and reader appearance with continuous flow.

New regressions cover completion versus a pause on the final sentence, replay
through toggle/resume/start, saved progress and speed, dynamic format shelves,
reflow stability and page IDs, cloud document/cover round trips, placeholders,
and preserving a local original when a download has an unexpected size.

The opt-in `realICloudDocumentsDownloadIntoAnIsolatedLibrary` test also passed on
Mac with `TEST_RUNNER_NODUS_ICLOUD_DOWNLOAD_CONTAINER` set locally. It copied the
five existing iCloud originals into a temporary library, read the local copies
and checked their sizes. It does not change personal library metadata or upload
documents. No personal paths, titles or contents are stored in this report.

## Limits

- Mac's `scannedPDFJoinsParagraphsAndDoesNotPromoteBodyLinesToHeadings` and
  `pdfWithAGarbledTextLayerIsReadWithOCR` were excluded after the host's Vision
  service stalled while reporting missing system recognition models. These
  tests passed in the iPhone and iPad runs. Model/corpus opt-in tests account for
  the other skipped definitions.
- Sepia title-bar colours were visually inspected in the Mac window. The Mac
  locked during the attempt to enter full screen, so full-screen appearance was
  not visually verified.
- Replay transport is exercised without loading a speech model. A new complete
  end-to-end neural synthesis run was not performed.
- Both new UI keys have Spanish translations. The complete localization
  generator still reports six unrelated, pre-existing missing translations; the
  committed catalog keeps only the two additions from this change.

Local result bundles are ignored build artifacts:
`ReaderFixes-Merge-iPhone.xcresult`, `ReaderFixes-Merge-iPad.xcresult` and
`ReaderFixes-Merge-Mac.xcresult` under `build/`.
