# Narration Sync, Tap-to-Play and Audio Cache

Status: **requirement added during the build; partially implemented in the system-voice engine, planned for the neural engines in Milestone 7.**

This document adds the user-requested behaviour around text/audio synchronisation to the original brief. It is now part of Nodus Reader's product scope:

- mark the **word** currently being spoken, not only the sentence;
- let the user **tap any word** to start narration from that word, in the spirit of ElevenReader;
- generate audio **partially**, manage the cache per book/chapter and allow deletion;
- keep the same local-first, no-upload, no-telemetry rules;
- learn from the Nodus approach of deriving timing from the generated audio (including pause analysis), but prefer deterministic engine timings when available.

## 1. Current implementation (system voices)

The current engine is `AVSpeechSynthesizer` (`PlaybackController`).

- `speechSynthesizer(_:willSpeakRangeOfSpeechString:utterance:)` provides character ranges while the system voice speaks. The delegate forwards them to the main actor.
- `PlaybackController.currentWordRange` and `currentWord` are absolute ranges inside the current sentence. The range is offset by `utteranceStartOffset` when playback starts mid-sentence.
- The reader splits a chapter into paragraphs. Each paragraph is a native text view (`UITextView` on iOS, `NSTextField` on macOS) with justified attributed text.
- On iOS, a tap gesture maps the touch point to a character with `closestPosition(to:)`, expands to the surrounding word, and reports the range to the reader.
- `ReaderView` finds the sentence containing the tapped word, then calls:
  `playback.start(book:mode:.readAndListen, startingSentence:sentence, wordOffset:offset)`.
- The sentence is highlighted with `theme.narration`; the current word gets a stronger background and an underline. The reader auto-scrolls to the active sentence and follows chapter changes in Read & Listen.
- Sentence-level timing is the fallback. Word-level highlighting is only shown when the engine reports a range; it never guesses silently.

Known limits of this implementation:

- Tap-to-play is wired for the native text reader on iOS/iPadOS. macOS paragraph tap mapping and PDF text-layer tap mapping are still pending.
- The system voice reports timing while speaking; it does not produce a reusable timing file. There is no audio cache yet, so partial generation/deletion is not applicable to this engine.
- Word highlighting is skipped for engines that cannot expose reliable timings.

## 2. Target engine contract

Introduce a `NarrationEngine` abstraction before the Kokoro/Phonon work (Milestone 6). The player and reader must not depend on `AVSpeechSynthesizer` directly.

```swift
public protocol NarrationEngine {
    var identifier: String { get }
    var capabilities: NarrationCapabilities { get }
    func voices() async throws -> [EngineVoice]
    func prepare(_ request: NarrationRequest) async throws -> NarrationPreparation
    func speak(_ segment: NarrationSegment) async throws -> AsyncStream<NarrationEvent>
    func cancel() async
    func evictCache(for bookID: UUID, chapter: Int?) async throws
}
```

`NarrationCapabilities` must state whether the engine provides word timings, sentence timings, streaming audio, cancellation and cache support. The UI reads capabilities instead of assuming.

### Alignment model

```swift
struct WordTiming: Codable, Sendable {
    let range: NSRange      // UTF-16 range in the sentence
    let start: TimeInterval
    let end: TimeInterval
    let confidence: Double  // 0...1
}

struct SentenceAlignment: Codable, Sendable {
    let text: String
    let audioRange: Range<TimeInterval>?
    let words: [WordTiming]?
    let confidence: Double
}
```

Rules:

- Prefer timings produced by the engine or its forced aligner. Do not invent word timings.
- If word confidence is below a configurable threshold (start at 0.8), fall back to sentence highlighting and log the decision in the manifest.
- Store ranges as UTF-16 offsets because the text controls use `NSRange`.
- Normalise punctuation and whitespace before alignment, but keep a mapping back to the displayed text.
- For PDFs, alignment is against the reconstructed reading-order text; the original page overlay continues to use page coordinates.

## 3. Partial audio cache

Audio is generated per **chapter segment**, never as one giant file for the whole book.

Cache layout (Application Support, excluded from iCloud):

```
NarrationCache/
  <book-id>/
    manifest.json
    <chapter-index>/
      segment-0001.m4a
      segment-0002.m4a
```

Manifest fields:

- book id, content hash, engine id/version, voice id, speed;
- chapter index;
- segment text hash, byte size, duration;
- status: `missing | partial | complete | stale | corrupt`;
- word alignment (optional) and confidence;
- created/last-used timestamps;
- total bytes.

Generation rules:

1. Generate on demand for the current sentence/chapter and pre-generate the next chapter in the background.
2. Write to a temporary file, validate it, then atomically rename it into place. A crash must never leave a half-written file marked complete.
3. Pause/cancel must stop work and leave the already completed segments usable.
4. Cache keys include engine version, voice, speed and text hash. A text or voice change invalidates only the affected entries.
5. Cap the cache (suggested default 500 MB, configurable). Evict least-recently-used completed segments first, never segments needed by the currently playing sentence.
6. Never store audio in CloudKit or iCloud Documents. Never sync model weights, voice embeddings or generated audio.
7. Deleting the library deletes its cache. `Remove Download` may optionally keep the audio cache; the UI must state which data remains.

### User controls

Add an “Audio & playback” section to the book inspector and storage settings:

- `Generate audio for this book` (with progress and cancel);
- `Remove audio download` (deletes only the narration cache);
- `Remove Download` (deletes only the document file once iCloud sync exists);
- `Delete from Library…` (deletes document, metadata and cache everywhere after confirmation);
- total cache size and per-book size.

The three delete operations must be visually and semantically distinct. A confirmation is required for library deletion, not for cache deletion.

## 4. Tap-to-play interactions

- **EPUB/text**: tapping a word starts narration at that word in Read & Listen mode. The engine may restart the current sentence; if the tapped word is in another sentence, the player jumps to that sentence first.
- **PDF Original**: map the tap through the PDF text layer/selection to a character, then to the reconstructed reading-order segment. If no reliable text layer exists, show an OCR/Intelligent Reading affordance instead of silently starting at the wrong place.
- **PDF Intelligent Reading**: the reflowed text uses the same word-tap path as EPUB.
- **Highlighting**: the active sentence is highlighted at all times; the active word is a stronger tint plus underline. User highlights (yellow/green/blue/pink/purple) remain visually distinct.
- **Page turning**: in Read & Listen, chapter/page changes follow narration. In Listen mode the visible reader does not jump unless the user enables “Follow narration”. The user can disable all page/TTS coupling.
- **Accessibility**: expose the current word/sentence in the accessibility value; provide actions “Play from here” and “Read from this sentence” for text views.

## 5. Nodus reference approach (reviewed implementation)

The request to review Nodus was carried out against the real code in the Nodus repository:

- `shared/narrationSync.ts` — pause detection, word tokenisation, pause/boundary pairing, word timing estimation and highlight granularity.
- `electron/tts/fragmentSync.ts` — reads the PCM of each generated fragment, collects its pauses and produces the saved clip’s sync map.
- `electron/tts/wavConcat.ts` — concatenates PCM16 fragments with a fixed 120 ms gap (`CLIP_FRAGMENT_GAP_MS`).
- `electron/tts/service.ts` — emits each fragment together with its pause list, then saves a `ClipSync` sidecar next to the saved clip.

The Nodus model is directly applicable to Nodus Reader and is licence-compatible (Nodus is AGPL-3.0-only as well). Its approach, in detail:

1. **Pause detection on real PCM.** Split mono PCM16 into 10 ms frames, compute RMS, take the 95th percentile of loud frames as the voice’s level, and mark a frame silent below `max(loud * 0.05, 0.003)`. Merge runs separated by at most two loud frames (clicks/breaths); ignore runs shorter than 80 ms except at the edges. Keep leading/trailing silence too: it tells where speech starts and ends.
2. **Tokenise the spoken text once.** Use locale-aware word segmentation, keep source character offsets, classify the boundary after each word as none / clause / sentence, and assign a syllable weight (vowel groups, syllabic scripts, digits spoken as longer units).
3. **Pair pauses with word boundaries using dynamic programming.** The score rewards a sentence end over a clause and a clause over a plain gap, minus a distance cost from the proportional position expected from syllable weights. Both pauses and boundaries may remain unpaired, so a breath or an unread comma does not corrupt the map.
4. **Interpolate between anchors.** Words between two paired pauses share that stretch of speech in proportion to their syllable weights. The error remains inside one clause. The estimator is pure, so timings can be recomputed without regenerating audio.
5. **Store audio facts, not guessed words.** The sidecar (`<file>.sync.json`) stores `version`, `gapS`, and per fragment `offsetS`, `durationS`, the spoken `text` and the raw `pauses`. Word timings are derived from these facts, so a better estimator can be shipped later.
6. **Partial generation and cancellation.** Each fragment is emitted as soon as it exists, with its pauses, and the UI can start playing it while later fragments are still generating. A cancelled job leaves completed fragments available briefly; the saved clip is concatenated only when the job completes. This is the model for Nodus Reader’s partial cache.
7. **Highlight granularity follows the listener’s clock.** Words per second of audio × playback rate determines whether to light a word, a short phrase or a sentence. The thresholds (about 5 and 9 words/s) include hysteresis so the choice does not flap; a ~50 ms lead compensates for audio latency; phrase groups stay visible for at least ~0.3 s and prefer clause boundaries.
8. **No network.** All analysis is local; the audio and the sync sidecar stay on the device.

What Nodus Reader will adopt for the neural engines:

- the pause sidecar and the “facts, not timings” storage model;
- the DP pause-to-boundary pairing and syllable-weighted interpolation as the fallback when an engine does not expose word timings;
- per-fragment generation events, early playback and cancellation;
- adaptive word/phrase/sentence highlighting with a lead and hysteresis;
- the 120 ms inter-fragment gap and a saved-clip sync sidecar.

Differences and additions required by the iOS/macOS app:

- Audio is written as compressed files (for example `.m4a`) by some engines; pause detection should run on decoded PCM before encoding, or on a PCM intermediate that is then encoded. Do not run RMS analysis on compressed bytes.
- All ranges must be mapped to UTF-16 offsets for `NSRange`-based text controls and to the reconstructed reading order for PDFs.
- Alignment must work with `AVAudioSession` interruptions and background generation; generation jobs need a durable state in the manifest.
- If an engine provides phoneme/word timings, use them directly and skip the estimator. The pause estimator is a fallback, never a silent replacement.

If code from Nodus is ported, keep its AGPL-3.0-only SPDX header, add the file to `THIRD_PARTY_NOTICES.md`, and preserve the attribution to the Nodus project. The algorithm above is a design reference for the planned Swift implementation; the current system-voice engine uses AVSpeechSynthesizer’s native word ranges instead.

## 6. Acceptance criteria

- Tapping a word in the EPUB reader starts playback at (or within the same sentence as) that word on iPhone and iPad, and highlights the spoken word within 300 ms of the audio starting.
- The sentence highlight and current-word highlight never disagree.
- The active word is visible in the viewport; automatic scrolling respects Reduce Motion.
- Playing, pausing, changing speed and changing voice keep the text/audio positions consistent.
- Partial cache: stopping halfway leaves completed segments reusable and does not mark the chapter complete.
- Deleting the audio cache does not remove the book; deleting the book removes its cache; `Remove Download` and `Delete from Library` remain distinct.
- No network request is made while reading or narrating.
- Word-level highlighting degrades to sentence-level when confidence is low; the app never invents alignment.
- Unit tests cover range mapping, mid-sentence start offsets, cache manifests and eviction. UI tests cover tap-a-word, player transport and cache deletion.

## 7. Open decisions

- Whether to bundle a small word aligner or rely on engine timings plus silence fallback.
- Exact cache limits and whether the user can pin audio for offline flights.
- PDF text-layer quality threshold for tap-to-play.
- How much alignment data to keep for very long books without bloating the manifest.
- Whether the per-book voice preference should also store the engine version used to create the cache.
