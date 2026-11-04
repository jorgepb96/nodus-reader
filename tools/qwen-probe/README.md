# Qwen inference probe

From the repository root:

```sh
python3 tools/qwen-probe/fetch-model.py /tmp/nodus-qwen-models
swift run --package-path Modules/QwenANE -c release qwen-probe \
  /tmp/nodus-qwen-models NodusReader/Resources/MingVoices/es-dave.wav \
  "$(cat NodusReader/Resources/MingVoices/es-dave.txt)" \
  es "La lluvia caía sobre la plaza mientras cerrábamos la biblioteca." \
  /tmp/qwen-spanish.wav
```

The fetcher uses the same pinned manifest as the app and verifies every file.
It downloads about 2.1 GB. The probe prepares the reference on the Mac, caches
it, synthesizes the requested words and writes 24 kHz mono WAV. It fails on
silent, non-finite or truncated output. No audio is sent to a service.

Run the inherited package tests with:

```sh
swift test --package-path Modules/QwenANE -c release
```

Tests needing the upstream reference fixtures or model environment are skipped
by default. See `Modules/QwenANE/Sources/QwenANE/README.md` for upstream details.

## Profiling and experimental INT8

The same six positional arguments also accept `--cases optimization-cases.json`,
`--repetitions 2`, `--warmup 1`, and `--report report.json`. The report separates
loading/preparation from synthesis and includes prediction-stage times,
generated versus retained frames and sampled process memory. The external
predictor is pinned separately:

```sh
python3 tools/qwen-probe/fetch-model.py /tmp/qwen-int8 \
  --manifest tools/qwen-probe/int8-cp-manifest.json
```

`--experimental-cp /path/to/MODEL.mlmodelc` is a probe-only opt-in. The app's
download manifest and default inference path do not use it. Experimental
compiled-MIL rewriting requires a separate environment with coremltools 9.0;
see `quantize-compiled-cp.py --help`. `qwen-voice-score` compares generated
references using the original speaker encoder. Consult
`docs/QWEN_OPTIMIZATION.md` before using any candidate: the tested INT8
variants were not promoted because of quality/stability results.

## Physical iPhone check

`device/` contains a separate SwiftUI diagnostic app, generated with
`xcodegen generate --spec tools/qwen-probe/device/project.yml`. Override its
development team if needed. Its bundle ID is `ai.nodus.reader.qwenprobe`;
it does not share Nodus's app groups, library or iCloud containers.

Copy the pinned model files to its `Documents/Models` folder using devicectl,
excluding the Mac probe's prepared-voice cache. Launch with argument `soak`
for five minutes of playback after setup, or `smoke` for short generation and
cancellation checks. There is no 30-minute option. The five-minute deadline
cancels any current synthesis and stops queued playback. The app uses the
included CC0 recording and does not request microphone access.

`Documents/events.json`, `Outputs/` and the fresh `Voice-<UUID>/` contain the
metrics, generated audio and on-device reference representation. Export those
before uninstalling the diagnostic app to free the model's storage. A phone
run uses the CPU/Neural Engine path, unlike the Mac's final GPU vocoder stage.
