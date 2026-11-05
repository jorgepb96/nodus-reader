# QwenANE

The `QwenANE`, `GVoiceKit` and `GVoiceProductionKit` sources and QwenANE tests
are copied from TinyTrashLabs/gloam-voice-studio at
`f46258b1889dd0c94d227c265831853f54fd9f7d` (MIT, see LICENSE).

Upstream: https://github.com/TinyTrashLabs/gloam-voice-studio

The MIT notice also ships as a QwenANE package resource in binary builds.
The local package exposes the Core ML engine without resolving the desktop
studio's MLX, Whisper and other unrelated engines. QwenProbe is Nodus's local
validation tool. No model weights are shipped in this package.

Model weights: Qwen/Qwen3-TTS-12Hz-0.6B-Base, Apache-2.0, converted by
TinyTrashLabs as tinytrashlabs/Qwen3-TTS-0.6B-Base-ANE. The app pins every
downloaded file in Resources/QwenModelManifest.json.

Local change: on macOS, `upMall` uses `cpuAndGPU`. The published model traps
inside BNNS with `cpuAndNeuralEngine` on the tested M2 / macOS 27.0.1, even
at its default input shape. iOS retains `cpuAndNeuralEngine`, without Metal,
for locked-screen narration. The other model placements are unchanged.

Further local changes expose per-stage prediction timings and untrimmed frame
counts, use monotonic render timers, and permit an explicit experimental
code-predictor override for the command-line probe. App callers leave the
override nil. QwenVoiceScore is an additional Nodus evaluation executable.
See `docs/QWEN_OPTIMIZATION.md` in the repository root for rejected INT8
experiments; the app's model manifest has not been changed by those probes.

The iOS hardening pass preserves a generation-limit stop after silence trimming,
adds cooperative cancellation between model loading/warm-up stages, and exposes
opt-in raw-render capture and fixed-code vocoder replay for diagnostics. Narration
does not retain diagnostic codes or samples. The default weights and sampling
remain unchanged pending physical-device comparisons. See
`docs/QWEN_IOS_HARDENING_2026-11-04.md` for evidence and remaining device checks.
