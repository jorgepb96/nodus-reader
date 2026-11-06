# StableAudioMLX (feasibility proof of concept)

| | |
| --- | --- |
| Model code from | https://github.com/kellyvv/StableAudio3-IOS @ `9281022ed52b7d1a0f3f822191b459aa1219ac16` |
| Licence of that code | MIT, `LICENSE` (© 2026 stableaudio3-ios contributors) |
| Numerical reference | https://github.com/Stability-AI/stable-audio-3 `optimized/mlx` @ `790793b` (MIT) |
| Weights | `stabilityai/stable-audio-3-optimized` @ `30cb2644…`, **not in this package**; Stability AI Community License (DiT, SAME-S) and Gemma Terms of Use (T5Gemma) |

Vendored without changes in the network maths: `T5Gemma.swift`, `DiTSmallMusic.swift`,
`SAMESDecoder.swift`, `SA3Conditioning.swift` (their bundle-based test helpers were
removed). Nodus additions, AGPL-compatible and kept in this package:

- `SA3Engine.swift`: the pipeline reads a directory, frees each network after its stage
  (`staged`) or keeps them (`resident`), times every stage and samples `phys_footprint`.
  The sampler uses the same noise keys as Stability's runtime (`seed`, `seed + 1`).
- `NPZToSafetensors.swift`: streams the published uncompressed `.npz` files into
  `.safetensors` on the device (memory-mapped, no Python).
- `SentencePieceBPE.swift`: a dependency-free encoder for T5Gemma's `tokenizer.model`.
  It replaces `swift-sentencepiece`, whose static `xcframework` exports an
  `include/module.modulemap` that collides with the project's other binary targets.
- `SA3Installer.swift`, `SA3Manifest.swift`: pinned files, size and SHA-256 checks.
- `SA3Audio.swift`: WAV output, loop trimming and seam metrics.
- `sa3-bench`: macOS command-line benchmark and parity tools.

Verification (2026-11-06, Mac M2): the Swift output matches Stability's Python MLX
runtime for the same prompt and seed (correlation 0.99996 per channel, SNR 40 dB, the
residue being fp16 rounding across MLX 0.32/0.33); the tokenizer matches Google's
SentencePiece on 33,384 strings (1.2 M tokens) with no difference.

MLX aborts the process in the iOS Simulator; `SA3Engine.isSupported` is false there.
See `docs/SOUNDSCAPES_FEASIBILITY.md`.
