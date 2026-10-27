# Narration Sync, Tap-to-Play and Audio Cache

Status: **implemented for Kokoro and Phonon.** System voices were removed: narration
requires an installed neural model.

This document records the word-level narration contract, how it is implemented in
Nodus Reader and where it remains approximate.

## Product contract

- Highlight the current **word**, not only the sentence.
- Tapping a word starts narration at that word (Read & Listen).
- Audio is generated locally, can be cached sentence by sentence, prefetched for a
  whole book, cancelled and deleted.
- Audio, models and alignment data never leave the device.
- Never invent a word that was not spoken: neural alignment is an estimate derived
  from the text and the generated waveform, and it degrades to sentence-level when
  the estimate is not usable.

## Implemented engines

| Engine | Audio path | Word timings | Cache |
|---|---|---|---|
| Kokoro 82M | `KokoroTTS` Core ML, 24 kHz mono Float PCM | Pause analysis + syllable-weighted DP | Per sentence `.caf` + `.json` |
| Phonon 31M | `ptts` Core ML, 24 kHz mono Float PCM | Pause analysis + syllable-weighted DP | Per sentence `.caf` + `.json` |

Kokoro's phonemizer uses MLX and needs a Metal device; the Simulator is excluded and
the Models screen explains why. Phonon runs in the Simulator and is covered by a UI
test.

## Playback

`PlaybackController` keeps the existing system-voice path and adds an
`AVAudioEngine` graph: `AVAudioPlayerNode → AVAudioUnitTimePitch → main mixer`.
Both neural engines return mono Float PCM at 24 kHz.

- A sentence is synthesized as a whole, then cached.
- Starting from a tapped word schedules the cached sentence from that word's start
  time (a sliced PCM buffer), so no second synthesis is needed.
- A per-frame (16 ms) loop maps the player's sample time to the word timing and sets
  `currentWordRange`/`currentWord`. The player clock counts audio handed to the
  hardware, which is heard `outputLatency` later (`AVAudioSession.outputLatency +
  ioBufferDuration`, or the output node's presentation latency: a few ms on the
  speaker, about 0.2 s over Bluetooth), so that is subtracted; the word is then set
  40 ms ahead, the time a highlight takes to reach the screen (main-actor hop,
  SwiftUI update, display refresh).
- The neural engine's models leave memory when narration has not used them for
  three minutes, at once when the app goes to the background without narrating or
  on a memory warning, and the unselected engine is released when the engine
  changes (Kokoro's MLX buffer cache is cleared too). The next sentence reloads the
  engine.
- At the end of a sentence, playback advances to the next sentence. Chapter changes,
  sleep-at-end-of-chapter and book completion use the same path.
- Pause during synthesis cancels the synthesis; pause during playback pauses the
  player node. Resume continues the scheduled buffer.
- Speed is applied by `AVAudioUnitTimePitch`; changing speed restarts the current
  sentence so the word clock and audio stay aligned.
- Interruptions, headphone removal, remote commands and Now Playing metadata are
  shared with the system-voice path.

## Word alignment

`AudioWordAligner` (in `NodusReader/Core/Services/NarrationAudioCache.swift`) is a
pure, unit-tested estimator:

1. Tokenise the sentence with `NSString.enumerateSubstrings(.byWords)`, preserving
   UTF-16 ranges.
2. Split the PCM into 20 ms frames and compute RMS. Speech frames exceed
   `max(0.004, peak × 0.06)`.
3. Collect silent runs of at least 35 ms between the first and last speech frame and
   use their centres as pause candidates. A chosen pause places the next word's
   start where the voice resumes (the pause's end), not at its centre, which used to
   light the next word half a pause early and made the highlight drift; boundaries
   are kept strictly increasing afterwards.
4. Give each word a syllable weight (vowel groups) plus a punctuation bonus for
   clause/sentence endings, and interpolate expected boundaries over the speech span.
5. Select the subset of pauses that best matches those expected boundaries with
   dynamic programming; if there are fewer pauses than boundaries, snap to the
   nearest pause within 220 ms or keep the interpolated time.
6. Store UTF-16 locations and start/end seconds; the last word ends at audio duration.

This follows Nodus's principle of storing audio facts and deriving timings, but the
current sidecar stores the derived word timings directly. A future estimator version
can recompute them from the stored PCM without re-synthesizing.

Known limits: breaths and dramatic pauses can pull a boundary; very short function
words may share a pause window; there is no confidence score yet, so the reader
always shows the estimated word range. The sentence highlight is always exact.

## Partial audio cache

```
Application Support/NodusReader/Audio/
  <book-id>/
    <sha256(engine|voice|text)>.caf
    <sha256(engine|voice|text)>.json   # duration + word timings
```

- Written after a real synthesis completes, atomically per file; a crash cannot leave
  a half-written audio file, and a missing pair is treated as a cache miss.
- Excluded from backup and never placed in iCloud.
- Automatically populated as sentences are played.
- **Generate for this book** iterates every sentence of the open book with progress
  and cancellation. Already cached sentences are skipped.
- Audio is stored as AAC (48 kbps, mono) inside the `.caf`: about 22 MB per hour
  of narration instead of about 350 MB as 32-bit PCM. Caches written as PCM by
  earlier builds still play.
- **Delete cache** removes the current book only; **Delete generated audio** in
  iCloud & Storage removes every cached narration.
- Automatic cleanup (`StorageJanitor`, at launch and when the app goes to the
  background, or **Free space now**) deletes a book's audio and OCR cache when it
  has not been opened for 30 days (7, 30, 90 days or never), 7 days after a
  finished book was last opened (can be turned off), and keeps the audio under
  2 GB by freeing the books opened longest ago first. The book being narrated and
  the book opened last are never touched, nor are documents, annotations or models.
  Caches of books no longer in the library are removed too.
- `Remove Download` (iCloud document) and `Delete from Library` are separate actions
  and do not touch this cache unless the book is deleted from the library.

## Tap-to-play

- The iOS/iPadOS page text view maps the touch to the surrounding word range and
  reports the chapter offset.
- `PlaybackController.start(... startingChapterOffset:)` finds the sentence and
  starts from the word. Neural engines start at
  the estimated word start inside the cached sentence.
- The reader follows narration in Read & Listen and keeps the sentence visible.
- macOS text paragraphs use the same selection/tap infrastructure; PDF Original page
  mapping is still future work. PDF Intelligent Reading uses the normal text path.

## Nodus reference

The implementation was reviewed against the original Nodus code:
`shared/narrationSync.ts`, `electron/tts/fragmentSync.ts`,
`electron/tts/wavConcat.ts` and `electron/tts/service.ts`. Adopted ideas:

- RMS pause detection on decoded PCM;
- syllable/punctuation weights;
- DP pairing of pauses with word boundaries;
- storing audio facts and deriving timings;
- partial generation/cancellation and a fixed inter-fragment gap.

Nodus Reader differs in storing per-sentence PCM files, using AVAudioEngine instead
of a browser audio element, and mapping all ranges to UTF-16 for native text
controls. No Nodus code was copied; the algorithm was reimplemented in Swift.

## Tests

- `wordAlignmentMatchesTextRangesAndMonotonicTimes`
- `wordAlignmentHandlesOneWordAndSilence`
- `voiceCatalogPrefersTheBookLanguage`
- `testReaderWordTapStartsReadAndListen` (requires an installed neural model)
- `testNeuralVoiceNarration` (Phonon, asserts progress to sentence 2)
- `testVoicePickerStartsWithBookLanguage` (Spanish book, neural voice)
- `testListenStartsNarration`, `testPagedReaderTurnsPagesAndBookmarks`

The player and voice picker default to the book's detected language, fall back to
the selected voice engine's language, and expose an explicit "All languages" menu so
other installed voices remain reachable.

## Future work

- Confidence scoring and sentence-level fallback when alignment is poor.
- Streaming Phonon fragments into playback before the sentence completes.
- Multi-voice Kokoro bundle and Spanish G2P.
- Cache size limits/LRU eviction (the current UI allows explicit deletion but no cap).
- PDF Original tap-to-play.
