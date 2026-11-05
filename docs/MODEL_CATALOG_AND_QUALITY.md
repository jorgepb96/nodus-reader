# Model catalogue and speech quality — 2026-11-04

All model cards share speed and naturalness meters, explicit supported locales,
parameter counts, model footprint and separate code/asset licence labels. Ming's
supported locales include languages beyond its bundled voices. Naturalness is an
editorial starting point (Qwen/Ming 5, Kokoro/Phonon 40M 4, Phonon 31M/Linnet 3),
not a listening benchmark. Qwen remains experimental.

Speed uses successful uncached generations after model load, including reference
preparation, retries and Qwen word verification. Cache playback never contributes.
The last thirty generations are retained locally, partitioned by model/revision,
OS and device resources. Three generations and thirty seconds of audio are required
before replacing an estimate. Bars represent <1x, 1–2x, 2–4x, 4–8x and >=8x audio
per second. Initial estimates are approximate architecture/precision profiles;
low-memory hardware receives a conservative adjustment. They are not guarantees.

## Qwen

The app now renders parts with at most three total takes, disables the runtime's
nested redraw budget, and starts a clean session with a different seed after a
rejected take. Each take is checked before any playback/cache commit. Checks cover
finite/nonempty signal, runtime derailment and, when available on iOS/macOS 26+,
local speech recognition. Ordered word coverage below 50% rejects a take; numeric
spellings are normalised, with character matching for CJK. This is a conservative
screen, not a word-fidelity guarantee. A recognizer can itself make errors.

Unsupported/missing recognition assets, errors and timeouts mean *unavailable*,
not *no words*. Audio may pass basic checks in that case, as selected by the user.
Successful recognition is reused for highlighting; missing timings fall back to
waveform estimates without a second transcription. Cancelled renders never commit.
The Qwen cache namespace changes for ordinary and pronunciation-adjusted text.
OSLog separates take/seed/stop/pause diagnostics from queue-wait events; production
code does not save diagnostic WAV files. Exhaustion pauses on the same sentence;
the player offers retry and voice selection. No automatic voice switch occurs.

The user's original no-words failure has not yet been reproduced with this wrapper.
The prior five-minute phone evidence remains in QWEN_TTS.md. No new quantization
is enabled and no subjective naturalness improvement is claimed.

## Linnet

The official 0.1.1 SDK is pinned and repackaged reproducibly as described in
Modules/LinnetTTS/NODUS_VENDOR.md. The model revision is
`afd7578a5f5a9652788b9913bed9e7e961348062`. All six downloaded files have pinned sizes
and SHA-256 hashes. The runtime weights have 41,425,219 parameters and occupy
83,075,620 bytes. Only the two authorised English voices are exposed. Assets stay
local and excluded from backup; download staging survives cancellation.

The actor adapter feeds 24 kHz PCM into existing playback/caching, handles
cancellation between steps, rejects the frame cap and splits at word boundaries
at about 120 characters. English numbers/prices/times/dates are expanded through
pronunciation spans so highlights still refer to the original text. Standard
voice creation and persistent weight conversion are not offered. The full weights
and source licences and mandatory credits are accessible from the card.

## Physical iPhone smoke check

A separate signed diagnostic app ran four short utterances on the user's iPhone
16 Pro Max. It was removed after exporting evidence; the Nodus app and library were
not replaced. The native Swift SDK generated 19.36 seconds of finite PCM in 2.206
seconds (about 8.77x playback), excluding model load. Both female and male voices
were exercised on two English sentences. Local Whisper base recovered the requested
words in all four files, with normal number/currency formatting changes. This is
a small foreground synthesis check, not a sustained/battery or naturalness benchmark.
No audio was played from that diagnostic app. Locked-screen playback, the full
installation workflow and the new Qwen verification on physical iPhone still need
end-to-end validation; no run longer than five minutes was started.

Evidence is under `build/linnet-device-audio/` (JSON, CAF, WAV and ASR transcripts),
with the disposable probe source/project under `build/linnet-device-probe/`.

## Automated validation

- macOS: complete suite, 224 tests passed, including real Linnet synthesis with
  both voices and the opt-in Qwen wrapper against the existing pinned checkpoint.
  Qwen's Spanish take ended at EOS, passed signal checks and local word recognition
  on the first attempt. Render plus recognition took 6.63 seconds; the complete
  smoke test took 76.23 seconds including its first model load. This is one short
  sample, not a speed or reliability benchmark.
- iPhone 17 Pro Simulator: complete app suite, 225 tests passed (real model probes
  require an explicit assets environment and are skipped there).
- Catalogue UI test passed and its two screenshots were exported to
  `build/model-catalog-ui/`. Speed/naturalness meters and the Linnet card were
  visually inspected. The final focused suite also passed all seven tests after the numeric-normalisation
  adjustments, including decimal and CJK cases and both real engine probes (9.37 s).

The real model tests are opt-in via `TEST_RUNNER_NODUS_LINNET_ASSETS` and
`TEST_RUNNER_NODUS_QWEN_ASSETS` pointing to verified fixture directories when
running xcodebuild. The seven focused tests are grouped in `ModelQualityTests`.
