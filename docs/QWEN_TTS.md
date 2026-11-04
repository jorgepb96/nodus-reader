# Qwen3-TTS with local voice creation

Qwen is an optional Base 0.6B engine on iPhone, iPad and Apple silicon Mac.
It is not offered in the Simulator. Status: **experimental**. Local voice
preparation and synthesis have been verified on a physical iPhone 16 Pro Max,
including background generation with the screen locked. The five-minute test
was slightly slower than playback and exhausted its audio queue repeatedly;
use **Offline audio → Generate for this book** before listening on iPhone.
The new **Audio generation** editor also supports a configurable chapter/part
window that follows reading progress; see [progressive audio](OFFLINE_AUDIO.md).
INT8 experiments did not pass quality gates and are not enabled; see
[optimization findings](QWEN_OPTIMIZATION.md).
Microphone capture and the complete Nodus UI workflow on a physical phone have
not been exercised; the device test used a separate diagnostic app.

## Integration

- `QwenModels` downloads 162 files (2,066,155,817 bytes) from a pinned public
  Hugging Face revision, checks size and SHA-256, and stages installation.
  Cancellation retains completed files for a later attempt. The download
  includes the speech and speaker encoders; creating a voice requires no server.
- `QwenSpeech` serializes the stateful engine on its own actor, prepares and
  caches a reference on first use, and rejects cancelled, non-finite, silent or
  truncated output. Model loading is shared by concurrent preview/prefetch calls.
- Studio now works on both platforms. Record or import a 3–30 s clip
  (6–15 s recommended), check its exact transcript, and confirm permission.
  The original Ming recording directory and voice IDs are retained; the same
  recording can serve Qwen and Ming with different voice/cache IDs.
- Dave, the existing bundled CC0 reference, is offered in each Qwen language.
  Voices, prepared references, models and narration stay local and are excluded
  from backup. Deleting a recording removes its prepared Qwen cache too.
- Narration uses the existing per-sentence PCM, timing, prefetch and `.caf` cache
  path. Engine-level streaming is available in QwenANE; this integration waits
  for a complete sentence so a failed take can be retried before playback.

## Runtime and licences

`Modules/QwenANE` vendors the MIT QwenANE, GVoiceKit and GVoiceProductionKit
targets at `f46258b1889dd0c94d227c265831853f54fd9f7d`. The rest of the desktop
studio and its unrelated engines are not dependencies. Weights are Apache-2.0.

On the tested M2 / macOS 27.0.1, the published `upMall` model traps in BNNS
under CPU/ANE placement, even at its default shape. Only that stage is placed
on CPU/GPU on Mac. iOS retains CPU/ANE placement throughout synthesis and CPU
reference encoders, so it does not depend on background GPU access. That iOS
  placement was verified in the five-minute device test below.

## Validation on 2026-11-03

- App builds for Mac, iOS Simulator and the native iPhone SDK (arm64).
- App unit tests: 209 passed on Mac, 210 on iOS Simulator.
- Studio recording-form UI test passed on iPhone 17 Pro Simulator; screenshots
  in `build/qwen-ui-captures`. Microphone capture was not exercised.
- Upstream QwenANE package: 103 tests, 35 intentionally skipped without model
  fixtures/environment, no failures.
- Real inference on M2, using the included 9.8 s Spanish Dave reference:

| Requested language | Generated audio | Warm synthesis time | Local Whisper base transcript |
| --- | ---: | ---: | --- |
| Spanish | 6.16 s | 7.98 s | All requested words present, no added words |
| English | 5.54 s | 7.84 s | All requested words present, no added words |

These are two short runs, not a quality benchmark or sustained-throughput
claim. English used the same Spanish reference. The English CLI process's
maximum RSS was 588 MB; this is not an iPhone memory measurement and does not
include every system service's cost. No subjective voice-similarity score was
measured. Download, pause and resume have not been exercised through the UI.

Local logs and sample WAVs are under `build/qwen-*`. Source/model reproduction
instructions are in `tools/qwen-probe/README.md`.

## Physical iPhone validation on 2026-11-04

The user limited continuous playback to five minutes. One completed run stopped
automatically after **300.012 s**; no 30-minute run was started. A separate
release-build diagnostic app used the same engine and checkpoint, loading the
engine before preparing the reference to mirror `QwenSpeech`. Its models and
data were exported for inspection, then the diagnostic app was uninstalled.
The existing Nodus installation and library were not changed.

| Measurement | Result |
| --- | --- |
| Device / system | iPhone 16 Pro Max / iOS 27.0.1 |
| Fresh on-device voice preparation | 2.135 s; 16 × 122 codec codes and 1024 speaker values |
| Reference parity with Mac | All codec codes identical; speaker-vector cosine approximately 1.0 |
| Model load after diagnostic-app reinstall | 92.97 s; warm-load time was not established |
| Completed utterances | 47, using six repeated Spanish texts |
| Total generated audio / synthesis time | 281.89 s / 312.88 s, including two prefilled sentences |
| Weighted real-time factor | 1.110 (time / audio); about 0.90× playback speed |
| Audio queue exhaustion events | 26; silence duration was not measured |
| Background generation | 40 completed utterances over 262.65 s in background |
| Maximum measured process footprint | 2.481 GB; stable after the first renders |
| Thermal state | Nominal throughout the sampled events |

Local Whisper base checked all 47 exported WAVs. This is a smoke check over
six repeated texts, not a benchmark or a guarantee of word fidelity. The first
sample matches all requested words. Raw transcription comparisons include
number-formatting differences and a few word differences; individual ASR
differences were not independently attributed to the synthesizer or recognizer.
No subjective speaker-similarity score was measured.

Battery went from 60% before model preparation to 55% after the run, while iOS
reported unplugged. This includes setup and the slow model load, so it does
not measure five-minute playback consumption or establish hourly battery life.

The first diagnostic attempt was killed during synthesis after the diagnostic
file verifier retained roughly 2 GB of autoreleased read buffers. Bounding the
per-read autorelease pool reduced verification footprint from 2,084 MB to
18 MB. The app's shared `ContentHash` reader received the same bounded-memory
fix; its 209 Mac unit tests passed afterward. The completed device run retained
the measured 2.48 GB synthesis footprint; no lower phone footprint is claimed.

Evidence: `build/qwen-iphone-five-events.json`, `qwen-iphone-five-summary.json`,
`qwen-iphone-clone-parity.json`, `qwen-iphone-five-asr-checks.json`, and the
47 WAVs under `build/qwen-iphone-five-audio/`.
