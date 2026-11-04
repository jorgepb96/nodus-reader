# Qwen optimization experiments, 2026-11-04

**No experimental INT8 weights are enabled in Nodus.** The app retains the
pinned 0.6B FP16/ANE set and full on-device ICL voice preparation. Production
changes improve the producer/cache pipeline; the quantization experiments
remain opt-in local probes.

## Measurements and candidates

The probe now separates prompt, prefill, talker prediction, code-predictor
prediction, overlapped vocoder busy time, tail wait, and whole-request time.
It uses monotonic time, reports model loading separately, and samples the
process footprint. Stage totals describe the retained take; request time also
includes retries. Generated frame counts are distinct from silence-trimmed
frames. This avoids attributing an overlapping vocoder's entire busy time to
the critical path or counting a long silent tail as useful output.

Five texts (Spanish short/numbers/names/paragraph and English using the same
Spanish reference), repeated twice, form a small smoke matrix, not a general
quality or iPhone benchmark. The source reference is the bundled CC0 Dave
recording, with 122 codec frames and its exact transcript.

| Candidate | Finding | Decision |
| --- | --- | --- |
| Original pinned runtime | Warm second-pass weighted RTF 1.032 on this M2; predictor and talker dominate generation | Baseline retained |
| `itsmechico` Base INT8 export, revision `71bae50834848f8a60aa88d112f62094ce844358` | Different NCHW interfaces, 256 talker slots, 128-row prefill, 125-frame speech decoder. Predictor load under CPU+ANE did not complete within ten minutes on this Mac; process stopped before any prediction | Not a drop-in replacement; no throughput or phone claim |
| INT8 rewrite of our own 0.6B predictor | 35 linear matrices, 279.0 → 169.1 MB of weights. Warm matrix RTF 0.797, but Spanish ASR checks show substantial word corruption; one case generates a long silent tail | Rejected on quality |
| Same rewrite, FP16 classifier heads | 20 transformer matrices quantized. Short text and paragraph need repeated redraws; paragraph hits the generation cap and fails the probe | Rejected on stability |
| MLP-only INT8 | 10 matrices, 231.9 MB weights; one short sample RTF 1.052 and a Spanish transcription difference | Insufficient evidence/benefit; not promoted |

These are complete request timings with different generated takes, not a
claim of identical work per second. They do not establish iPhone speed,
energy savings, or a reduction of the measured 2.48 GB phone footprint.
No new phone inference run was started because no quantized candidate passed
the Mac quality gate. The user's five-minute phone limit remains in force.

Local Whisper base checks found, for example, the original short Spanish
sentence intact, whereas the fully quantized predictor's transcript corrupts
multiple words near its end. ASR can make mistakes, so this is a regression
screen rather than an independently adjudicated WER score. The same frozen
Qwen speaker encoder gives mean reference cosines of 0.9827 (original) and
0.9592 (full predictor INT8), showing why likeness scoring alone is not a
word-fidelity gate. No human listening score is claimed.

The compatible-looking INT8 predictor from TinyTrashLabs' **1.7B** set was
also inspected. Its learned parameters differ (the first normalization
vector already differs by relative RMS 0.26), so it was not substituted into
the 0.6B model. Matching dimensions do not imply interchangeable weights.

## Reproduction and evidence

- `tools/qwen-probe/optimization-cases.json` holds the text matrix.
- `tools/qwen-probe/int8-cp-manifest.json` pins only the external predictor's
  files. The fetcher accepts `--manifest` and verifies every SHA-256.
- `quantize-compiled-cp.py` is a research-only rewrite using coremltools 9.0's
  internal MIL blob reader/writer. It refuses an existing destination, keeps
  embeddings and small tensors FP16, and preserves the original graph and
  1024-slot talker. It is not a supported source export or release artifact.
- `qwen-probe --experimental-cp MODEL.mlmodelc` opts into an alternate predictor.
  For the external export, zero Gumbel noise retains greedy residual-code
  selection. The app never passes this override.
- `qwen-voice-score` applies the original reference encoders to generated clips
  and reports reference/baseline vector cosines without changing the samples.

Local JSON, logs and WAVs are under `build/qwen-optimization-*`. The first
baseline used wall-clock stage timers before the monotonic fix: its first
English prefill has a clock discontinuity and must not be used as a stage
latency measurement. The warm second pass above uses monotonic request time.
The source bundle remains unchanged under `/tmp/nodus-qwen-models-20261103`.

Sources: [external export](https://huggingface.co/itsmechico/qwen3-tts-0.6b-base-coreml-ane),
[upstream runtime](https://github.com/TinyTrashLabs/gloam-voice-studio),
[Core ML quantization guidance](https://apple.github.io/coremltools/docs-guides/source/opt-quantization-perf.html).
