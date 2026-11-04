# QwenANE

Qwen3-TTS (0.6B or 1.7B, same runtime) on the Neural Engine. The talker and code predictor (stateful Core ML, iOS 18 /
macOS 15) and the vocoder upsampler run as `.mlmodelc`; the text projection, tokenizer, prompt
building, sampler and the vocoder head run on the CPU (Accelerate). Foundation, CoreML and
Accelerate only: no MLX, no ONNX Runtime.

```swift
let engine = try QwenANEEngine(modelsDirectory: modelsURL)      // seconds; once per process
let voice = try engine.loadVoice(named: "jeff")                 // or QwenVoiceFiles(refText:refCodes:spkEmbedding:)
let r = try engine.render(text: "Good evening.", voice: voice, seed: 7,
                          cancelled: { false }, pace: { /* duty-cycle sleep */ })
// r.samples: [Float] mono, r.sampleRate == 24000, r.frames, r.stopReason, r.timings
```

Streaming: pass `onAudio: { chunk in ... }` to `render` to receive each decoded vocoder chunk (12 frames,
0.96 s) as soon as it is ready, in order, from the vocoder queue. The chunks are trimmed by
`QwenStreamTrimmer`: leading silence is capped at 0.05 s, trailing silence is held back (at most 0.1 s is
delivered at the end), and internal pauses are NOT shortened (the finished `QwenRender.samples` still gets
`Options.capPauses`, unchanged). Each delivered sample is a sample of the un-capped line, so the
concatenation is a contiguous slice of it.

One engine renders one line at a time (an internal lock serialises callers). `render` blocks for
about the length of the audio; call it off the main thread. `pace` runs between stages and after
every frame; sleeping in it is how a host limits the duty cycle.

## Model sizes

One runtime, two sets. The size comes from the set's `host/config.json` (a 0.6B set predates the keys and reads
as 0.6B): `hidden` (talker width: 1024 / 2048), `layers` + `talker_chunks` (28 layers in 2 chunks of 14 / 4 chunks of
7), `text_embedding_bits` (4 / 8), `cp_hidden` (1024 for both; when it differs from `hidden` the host applies the
checkpoint's `small_to_mtp_projection`, `host/cp_in_proj_{w,b}.npy`, to the talker's hidden state and to codec[g0]
before the code predictor, whose Core ML inputs stay 1024 wide). The vocoder (`upF`, `upMall`, `vochead`) and the speech
encoder are the same files in both sets (the speech tokenizer is one checkpoint); the speaker encoder is not (x-vector
1024 / 2048). A prepared voice lives in `engines/qwen3-0.6b/` or `engines/qwen3-1.7b/` (`QwenEngineFiles.Kind`): same
codes, different `spk_embed.npy`. Build a 1.7B set with qwen-onnx-cpu `tools/ship17.py`; run the tests per size with
`scripts/test-qwen-ane-sizes.sh`. Numbers: docs/qwen-ane-1-7b.md.

## Model directory

```
<models>/
  host/      config.json, tokenizer.json, text_embedding_{q,scales,biases}.npy,
             text_proj_linear_fc{1,2}_{w,b}.npy, talker_codec_embedding.npy, cp_codec_embedding.npy
             (text_embedding_scales/biases are fp16, bit-exact; the codec embeddings stay fp32 because
             fp16 flips near-tie sub-codes; fp32 .npy files are accepted wherever fp16 is)
  vochead/   the vocoder head weights, one fp16 .npy per tensor (quantizer.*, pre_conv.*, pre_transformer.*);
             fp16 is bit-exact for these, fp32 files also load. Matrices are widened per matmul.
  coreml/    talker0.mlmodelc, talker1.mlmodelc   (layers 0-13 and 14-27, NOT duplicates; each is
                                                   multifunction: "decode" and "prefill")
             cp_ane.mlmodelc
             upF.mlmodelc   (multifunction "w12" / "w20": one set of weights, two window widths;
                             the older upF_12 + upF_20 pair still loads)
             upMall.mlmodelc
  voices/<name>/   voice.json (ref_text), ref_codes.npy (int32 1x16xT), spk_embed.npy (float32)
```

Models must be compiled (`.mlmodelc`); compile a `.mlpackage` with `xcrun coremlcompiler compile`.
`voices/` is optional: a host can build `QwenVoiceFiles` itself and cache them next to its own voices.

### Voice prep models

Preparing a voice on the device (`QwenVoicePrep`) needs two more compiled models, both fp32 and
run on the CPU only (`.cpuOnly`; never CPU_AND_NE, it hung the ANE compiler):

```
<models>/coreml/  QwenSpeechEncoder.mlmodelc    (speech tokenizer, fixed 40 s input + valid length; 20 s on older sets)
                  QwenSpeakerEncoder.mlmodelc   (x-vector ECAPA-TDNN, mel input + valid length)
```

Source packages: `qwen-onnx-cpu/out/coreml_enc/`; compile with `xcrun coremlcompiler compile`.

A `.gvoice` pack can carry the prepared voice (`engines/qwen3-0.6b/`, docs/gvoice-format.md):
`QwenVoicePrep.prepared(fromPack:referenceWAV:transcript:cacheDirectory:modelsDirectory:)` checks the
cache, then the pack's files (sha256 of the audio, prep version, mel, transcript, array shapes), and
only then runs the encoders; `Prepared.origin` says which, and `Prepared.enginePayload(...)` makes the
folder to write back. `spike gvoice-qwen-prep <pack.gvoice>` adds or refreshes it.

```swift
// wav: mono 24 kHz PCM16, already through ReferenceStandard (or a GVoiceProductionKit PreparedReference)
let voice = try QwenVoicePrep.prepared(referenceWAV: wav, transcript: text,
                                       cacheDirectory: voiceDir, modelsDirectory: modelsURL)
```

It trims a cut-off tail (`ReferenceTail`), signals `referenceTooLong(seconds:)` past the encoder's input (40 s; `encoderLimitSamples` reads the real
limit from the model) so the caller can cut a window (`QwenANESpeechModel.prepare` does, automatically), and caches `voice.json` / `ref_codes.npy` / `spk_embed.npy` keyed by source
sha256 + transcript + prep version. The speaker mel is the upstream one (magnitude, Slaney, reflect
pad 384), not the mlx-audio-swift fork's. Parity tests: `QWEN_ANE_MODELS=... swift test --filter QwenVoicePrepTests`.

## Per-voice caches and chunk schedule

Every line of a voice builds the same ICL prompt rows for the voice (role, think/speaker rows, the reference
transcript's text rows and the reference's codec rows), so the engine keeps them per voice (`VoicePrompt`, four
voices, least recently used out, dropped by `dropCaches()`). The ICL layout is `[text rows ; codec rows]`, so the
line's own text sits BETWEEN the transcript and the reference codec rows: only the first `8 + n_transcript_tokens`
rows are identical across lines, and their talker KV can be reused (`KVPrefix`, MLState read/write through
`withMultiArray`) in whole 64-row prefill chunks. That is one chunk (about 35 ms) for a ~60-token transcript and
nothing for a short one, so the saving is small; the reused KV is bit-identical (`Options.prefixCache` off renders the
same codes, proven in `QwenPrefixCacheTests`). `warm(voice:)` builds all of it and runs three frames through every
Core ML graph.

`Options.chunkFrames` / `render(chunkFrames:)` sets the vocoder chunk schedule (default whole 12-frame chunks).
`[4, 8, 12]` delivers the first audio about 0.5 s sooner; the codes are unchanged and the samples agree to ANE
fp16 rounding (above 47 dB SNR in the tests). It only plays gaplessly while the render is faster than real time.

## A talk break: `QwenTalkSession`

A break longer than one render is split into parts (the KV window holds reference + text + frames). Render them
through one session, not `render` per part:

```swift
let session = QwenTalkSession(engine: engine, voice: voice, language: "es", seedText: wholeBreak)
for part in parts { let r = try session.render(part) /* r.samples */ }
```

- **One sampler stream per break**, seeded by `seed` or a stable hash of voice + language + `seedText`: the same
  break renders the same audio, and no part gets an unrelated fresh seed.
- **Each part continues the previous one**: the previous part's transcript and codec frames follow the reference
  in the ICL prompt (`[ref text ; prev text ; line ; tts_eos]` then `[codec_bos ; ref codes ; prev codes]`), and the
  vocoder head runs over the previous part's frames before the line, so pace, level and pitch carry across the
  join. Dropped (`QwenRender.contextFrames == 0`) for a part whose frame budget it would shrink.
- **A derailed take is drawn again** (`QwenTalkSession.derailed`: it ran to the frame cap, or holds more than 2 s of
  silence inside the line), from the same stream, at most `maxRedraws` (2) times; a clean take is never redrawn.
  Not with `onAudio` (streamed chunks cannot be recalled). A derailed take is never carried into the next part.

**One call for a whole break** (split → session → join, a report per part for logs):

```swift
let session = QwenTalkSession(engine: engine, voice: voice, language: "es", seed: QwenReadRules.randomSeed())
let b = try session.renderBreak(wholeBreak, maxPartChars: 160, gapSeconds: 0.15,
                                onPart: { NSLog("%@", $0.logLine) })      // b.samples, b.parts
// streaming: renderBreak(wholeBreak, onAudio: { play($0) }) -- gaps included, b.samples empty
// own split: renderBreak(parts: myParts, ...)
```

The rules behind it are `QwenReadRules` (split, `derailed`, `badness`, `carries`, `keptFrames`, `randomSeed`) and
`QwenCarry` (what the next part continues). They are pure, so the iPhone's MLX Qwen path
(gloam-voice-studio-ios `QwenMLXEngine`) applies the same ones: a part is carried only if it did not derail AND no
check that ran before the next part flagged it.

The runaway cap that stops a take that never ends follows the voice: `QwenReadRules.frameCap` allows the larger of
6 frames a text token (the old fixed cap: a 44-token part stopped at 21.1 s) and 2x the voice's own pace, measured
from its reference (`voiceFramesPerToken`: reference frames / transcript tokens, clamped to 3...20), within the
KV window. `QwenRender.frameCap` and the part log line report it.

Studio's `qwen3-0.6b-ane` backend (`QwenANESpeechModel`) does this for you: a line that fits one render is one
render, as before; a longer one is split at sentences (~160 characters a part) and rendered through one session
with a random seed (or the request's), so Regenerate still gives a new take.

The reference itself matters most: a reference whose audio says words its transcript does not (or the reverse)
makes Qwen continue the wrong thing. `QwenVoicePrep.prepareEngineFolder` checks a stored section's last sentence
against a transcription of the cut (`ReferenceSection.sentenceEndCandidates`, `wordDistance`) when a recogniser is
available.

## Notes

- The sampler reproduces numpy's `default_rng(seed)` stream (PCG64 + SeedSequence), so a render with
  a given seed is comparable to `render_fast.py --engine coreml` in qwen-onnx-cpu. fp16 on the ANE
  can flip a near-tie late in a line, so match is "nearly all frames", not bit-exact.
- The vocoder is primed with the voice's reference codes (their audio is dropped); without that the
  first word cracks. The primed state is cached per voice.
- The talker has 1024 KV slots: prompt (voice reference + text) plus generated frames must fit.
