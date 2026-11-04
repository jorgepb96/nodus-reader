# Progressive offline audio and Studio references

Audio generation is available from the player's **Offline audio** card and
**Settings → iCloud & Storage → Audio generation** on iOS and macOS. It uses
every installed narration engine, including Qwen and, on Mac, Ming.

## Generation modes

- **Follow my reading** is the default in the queue editor. Its configurable
  window starts at the current chapter/part; two means the current one plus
  the next one. Moving the reading position extends the window. Previous
  audio is kept, and moving backward can reuse it.
- Turning that option off prepares the entire book. The original **Generate
  for this book** button is a shortcut for this mode.
- EPUB and other multi-chapter text documents use their extracted chapters.
  A document without chapters, including PDF page extraction, is grouped by
  a configurable paragraph count (default ten). A part ends only after an
  entire sentence, including a continuation across a paragraph boundary.
- The job fixes the book version, voice and pronunciation rules. It never
  silently switches to a fallback voice. Changed text/rules require a new
  job, and an unavailable voice waits until it is available again.

Jobs continue independently of the open player/book. Narration and voice
previews have priority over the utility producer. During playback, only the
same book and voice can generate ahead; different jobs wait. Studio editing
also suspends background generation. The current reading book is preferred
when several jobs are runnable. The existing synthesis gate serializes live
and offline work, with live work ahead of background waiters.

Each complete sentence is saved as AAC/CAF with the existing word-timing
metadata, so it can be read with normal highlighting. No whole-book PCM array
is accumulated. The immutable plan is written once under `AudioJobs/<UUID>`;
a small state checkpoint records progress after each durable sentence.
Interrupted active jobs become queued on reopening; a user pause stays paused.
Resume checks previously completed cache entries and regenerates missing ones.
Both plans (which contain extracted text) and audio are local, excluded from
backup, and are not part of library sync.

The queue supports pause/resume, removing a job while keeping its audio,
deleting an individual chapter/part's audio, and deleting a job with its audio.
Deleting a library book also removes its audio plans. Shared cache entries
are invalidated in other affected plans when deleted. User recordings and the
original book are independent of generated-audio deletion.

On Mac, generation can run while the app stays open. On iPhone/iPad this does
not claim unrestricted background processing: the existing per-sentence
background-time request allows an in-flight sentence to finish when possible,
but iOS can suspend/terminate the app. Durable checkpoints allow resumption
when the app returns. No fake silent playback or background GPU exception is
used to keep the app alive.

## Studio references

Qwen and Ming support Studio voice creation; models with fixed voice banks do
not gain cloning from this feature. Import can take a long WAV, M4A, MP3 or
AIFF file. The editor selects a start and duration, prepares only that window,
and offers playback before saving. It keeps a security-scoped source URL while
editing, and stores only the selected reference after Save Voice. It does not
load the whole source into an audio buffer.

The limits are 3–20 seconds for Qwen (within its portable 256-codec-frame
reference format) and 3–30 for Ming, with 6–15 recommended. Microphone capture
stops at the chosen engine's limit. Selection changes invalidate stale
transcription results; the exact words must be reviewed, and the existing
voice permission confirmation remains required. Multiple voices can be saved,
renamed and deleted in Studio on both platforms.

## Validation

Tests use isolated temporary plans/caches and synthetic PCM, with no model
downloads or microphone permission. They cover progressive horizons, partial
deletion, checkpoint restoration, explicit pause, cache eviction, interactive
preemption, sentence boundaries, and seeking into a long imported reference.
The last test checks the selected signal's pitch as well as its duration.
Simulator UI checks exercise the queue controls and bundled CC0 reference
selection. Physical microphone capture and unrestricted iOS background jobs
are not claimed by these checks.

Validation on 2026-11-04: **217 Mac unit tests** and **218 iOS Simulator unit
tests** passed. The queue-mode and imported-reference selection UI checks passed,
as did the existing microphone-form UI check (without recording). Native iPhone
SDK and Mac builds passed. Screenshots were inspected; the long voice-editor
title was shortened and placed inline on mobile. No new physical-phone
inference or microphone run was needed for these checks.

Evidence is in `build/offline-audio-final-mac-checks.log`,
`build/offline-audio-final-ios-tests.log`, `build/offline-audio-ui-layout-final.log`
and `build/offline-audio-layout-captures/`.
