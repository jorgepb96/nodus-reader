# Model and Voice Licences

Each model and voice retains its publisher’s licence. Phonon 40M Spanish and Multilingual are provided by Gradium under CC BY-NC 4.0 for non-commercial use; those terms also apply to locally converted Core ML files.

Neural model weights and voice embeddings are downloaded on request and remain on the device. The bundled `es-dave` reference clip is identified separately below.

## Engines in this build

| Engine | Source | Licence | Distribution |
|---|---|---|---|
| Kokoro 82M Core ML | [mattmireles/kokoro-coreml](https://github.com/mattmireles/kokoro-coreml), pinned at `43ef0237306c3c1ea0138098c9f92930ae4cf3f7`; weights [hexgrad/Kokoro-82M](https://huggingface.co/hexgrad/Kokoro-82M), hosted bundle [mattmireles/kokoro-coreml](https://huggingface.co/mattmireles/kokoro-coreml) | Apache-2.0 | Downloaded from a pinned Hugging Face revision; starter bundle plus the 27 other English voice files of the same pinned revision (each verified against its published SHA-256), 28 voices, English |
| Kokoro Spanish voices | `ef_dora`, `em_alex`, `em_santa` of [hexgrad/Kokoro-82M](https://huggingface.co/hexgrad/Kokoro-82M), downloaded as raw float32 tables from [onnx-community/Kokoro-82M-v1.0-ONNX](https://huggingface.co/onnx-community/Kokoro-82M-v1.0-ONNX) at `1939ad2a8e416c0acfeecc08a694d14ef25f2231` | Apache-2.0 | Three files of 510 KB, each verified against its pinned SHA-256 and added to the installed bundle's manifest; Spanish (Spain) |
| Kokoro G2P | [mattmireles/MisakiSwift](https://github.com/mattmireles/MisakiSwift) pinned revision `3a27756a…`, MIT-licensed [mlx-swift](https://github.com/ml-explore/mlx-swift), Apache-2.0 FluidAudio-derived G2P and NemoTextProcessing | Apache-2.0 / MIT | Swift Package dependencies |
| Phonon 31M Core ML | [gradium/phonon-31m-en](https://huggingface.co/gradium/phonon-31m-en) weights, Core ML bundle [mosiah/phonon-31m-en-coreml](https://huggingface.co/mosiah/phonon-31m-en-coreml), runtime [gradium-ai/xn-ptts](https://github.com/gradium-ai/xn-ptts) v0.4.1 | Apache-2.0 (`ptts` also offers MIT) | Downloaded from a pinned Hugging Face revision; English, nine voices |
| Phonon voices | [gradium/phonon-voices](https://huggingface.co/gradium/phonon-voices) | Apache-2.0 | Included in the Phonon bundle |
| Phonon 40M Spanish | [gradium/phonon-40m-es](https://huggingface.co/gradium/phonon-40m-es) @ `f0d2f39` | CC BY-NC 4.0, gated | **Never hosted or shipped by Nodus Reader.** Each user signs in to Hugging Face with an account that accepted Gradium's conditions; the app downloads the checkpoint with that access (SHA-256 verified), converts it to Core ML on the device with Gradium's exporter (built into PhononCore, see `Modules/PhononTTS/engine/`) and deletes the downloaded weights. Runs with the 25 Spanish voices of `gradium/phonon-voices` @ `0ee1720`. Non-commercial use |
| Ming 3.0 0.5B (macOS only) | [mlx-community/Ming-3.0-tts-0.5B-8bit](https://huggingface.co/mlx-community/Ming-3.0-tts-0.5B-8bit) @ `c807b99d2ea77d896fcffc917f0330d36470bb29`, an 8-bit MLX conversion of [inclusionAI/Ming-3.0-tts-0.5B](https://huggingface.co/inclusionAI/Ming-3.0-tts-0.5B); runtime [Blaizzy/mlx-audio-swift](https://github.com/Blaizzy/mlx-audio-swift) @ `0dda61b` | MIT (CAM++ speaker encoder: Apache-2.0, 3D-Speaker) | Downloaded from the pinned revision; twelve files, each checked against its size and SHA-256. 106 built-in voices (5 English, 101 Mandarin, without those that imitate film and series characters); voices cloned on the Mac from the user's own clips stay on that Mac |
| Ming reference clip `es-dave` | [OHF-Voice/voice-datasets](https://github.com/OHF-Voice/voice-datasets) v1.0.0, `es_ES/dave` clip `0000000003` | CC0 1.0 | The one voice asset bundled in the app (9.8 s, 44.1 kHz mono), used as Ming's included Castilian voice |
| Qwen3-TTS 0.6B Base | [tinytrashlabs/Qwen3-TTS-0.6B-Base-ANE](https://huggingface.co/tinytrashlabs/Qwen3-TTS-0.6B-Base-ANE) @ `551e82a5618b4804a51559bc508fece40d63b6a7`, a Core ML conversion of [Qwen/Qwen3-TTS-12Hz-0.6B-Base](https://huggingface.co/Qwen/Qwen3-TTS-12Hz-0.6B-Base) | Apache-2.0 | 162 files pinned by size and SHA-256 in `QwenModelManifest.json`, including the upstream licence and both reference encoders. No weights are bundled. The CC0 `es-dave` clip is also Qwen's included reference. User recordings and prepared voices remain on the device |
| LinnetTTS 0.1.1 / `linnet-en-35m` | [VoxRT/LinnetTTS](https://github.com/VoxRT/LinnetTTS/tree/v0.1.1); assets [VoxRT/linnet-en-35m](https://huggingface.co/VoxRT/linnet-en-35m/tree/afd7578a5f5a9652788b9913bed9e7e961348062) | Code: Apache-2.0. Weights, tokenizer and voices: Linnet Weights License 1.0, **not open source** | Original FP16 weights (41,425,219 parameters; 83,075,620 bytes), tokenizer, two authorised US English voices and licence/model card downloaded from the official pinned revision. Six files checked by size/SHA-256. Read-aloud and local cache inside Nodus only; no cloning, weight conversion or standalone asset export. |
| Phonon 40M Multilingual | [gradium/phonon-40m-multilingual](https://huggingface.co/gradium/phonon-40m-multilingual) @ `1537ce4` | CC BY-NC 4.0, gated | Same on-device path as Spanish: downloaded with the user's own access, verified, converted on the device; never hosted or shipped. Runs with all 102 voices of `gradium/phonon-voices` (English, Spanish, French, German, Portuguese), each normalizing text in its own language. Non-commercial use |
| Stable Audio 3 Small Music and Small SFX (AI soundscapes) | [stabilityai/stable-audio-3-optimized](https://huggingface.co/stabilityai/stable-audio-3-optimized) @ `30cb2644da54bfa63275d1bc7f1fa67fc718680f`: `MLX/dit_sm-music_f16.npz`, `MLX/dit_sm-sfx_f16.npz`, `MLX/same_s_decoder_f32.npz`, `MLX/same_s_encoder_f32.npz`, `MLX/t5gemma_f16.npz`, `tokenizer.model` | Stability AI Community License (not open source; free for research, non-commercial use and organisations under US$1M revenue, subject to the Acceptable Use Policy); T5Gemma under the Gemma Terms of Use | Downloaded only when the reader turns on AI soundscapes; not gated. Every file checked against its size and SHA-256, converted to safetensors on the device, archives deleted. Music needs about 1.9 GB, both about 2.9 GB. Generated audio stays on the device and needs no model to play. «Powered by Stability AI» and the licence texts are shown in the app |

## Third-party runtime packages

| Package | Licence | Use |
|---|---|---|
| `KokoroCoreML` / `KokoroTTS` | Apache-2.0 | Kokoro inference and text preparation |
| `MisakiSwift` | Apache-2.0 | English phonemization |
| `mlx-swift` | MIT | Misaki runtime |
| `NemoTextProcessing` binary | Apache-2.0 | Text normalisation FSTs |
| `ptts` / `PhononCore` | Apache-2.0 (package also includes MIT) | Phonon Core ML inference |
| `QwenANE`, `GVoiceKit`, `GVoiceProductionKit` | MIT, © 2026 TinyTrashLabs | Qwen Core ML inference and on-device preparation of reference voices; vendored at `f46258b`, with Mac-only vocoder placement adaptation |
| LinnetTTS 0.1.1 / CLinnetTTS | Apache-2.0, © 2026 Wiseport Ltd. (VoxRT) | Swift sources vendored unchanged; official checksum-verified static SDK archives repackaged as frameworks to isolate module maps. No weights in the SDK. See `Modules/LinnetTTS/NODUS_VENDOR.md` |
| ZIPFoundation | MIT | EPUB container parsing |
| `StableAudioMLX` (vendored) | MIT | Stable Audio 3 Small inference for AI soundscapes |

Exact source, licence and attribution notices are in
[`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).

## Downloaded model pins

- Kokoro: the SDK pins `mattmireles/kokoro-coreml` revision
  `034f7741bf938fd6b4b9c75c22bc72cd795f908a` and verifies
  `HostedManifest.json` (`f3abd581…`) before any file is trusted. Each file is
  checked against its SHA-256.
- Phonon: Nodus Reader downloads from
  `https://huggingface.co/mosiah/phonon-31m-en-coreml/resolve/0a2596e9154f0340005b6445514fdd57f7bc9ddb`.
  `PhononModels.download` verifies `bundle.json`, file sizes and SHA-256 hashes, and
  resumes already verified files.

## Distribution rules

- Do not distribute restricted or gated model weights without explicit permission.
- Do not upload model files, voice embeddings, generated audio or OCR caches to
  iCloud. They are excluded from backup where the SDK permits it.
- Store the optional Hugging Face token in the Keychain only. Never write it to
  CloudKit, iCloud Drive, the library folder or logs.
- Downloads are per device. A book's preferred voice ID may sync, but if the voice is
  absent the app falls back to an installed voice without breaking narration.
- Kokoro speaks English through the SDK's own phonemizer and Spanish through
  `SpanishG2P`. Its other trained languages (French, Italian, Portuguese, Hindi,
  Japanese, Chinese) are not offered: they need espeak-ng or dictionary phonemizers
  that are not part of this build. Phonon 40M Spanish and Multilingual run only from bundles
  converted on the user's device (or Mac) from the user's own download.
- Re-check every upstream licence and model card before an App Store release. This
  file is not legal advice.

## Licence information

The Models screen links to each model card and shows the publisher’s licence.
Component copyright and permission notices are retained in
[`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).

## Linnet asset licence and credits

The [Linnet Weights License 1.0](https://huggingface.co/VoxRT/linnet-en-35m/blob/afd7578a5f5a9652788b9913bed9e7e961348062/WEIGHTS_LICENSE.md)
permits unmodified authorised assets for read-aloud within a product, including
commercial products. It does not grant general-purpose TTS service, custom voice
creation (including one's own voice), persistent weight modification/conversion,
model-training or standalone redistribution rights. These require separate written
authorisation from VoxRT. It is separate from Nodus Reader's AGPL-3.0-only source
licence; the app's licence does not grant rights to third-party model assets.

Nodus downloads assets from the publisher's official location for operation inside
the app. It includes the complete asset licence, Apache-2.0 code licence and VoxRT
NOTICE in Resources and makes them readable from the Linnet card. Required notices:

> Linnet model weights by VoxRT, licensed under the Linnet Weights License 1.0
>
> Powered by Linnet (VoxRT)

The free price of Nodus Reader does not expand the non-commercial grant of Phonon
40M or remove any publisher's conditions. Users must follow the licence applying
to the model they select. No change to the project's source licence is made here.

## iOS system voices

On iOS/iPadOS, Apple system voices are enumerated and rendered using public AVFAudio APIs. Nodus does not redistribute Apple voice assets, require a model download for this option or provide cloning of these voices. Apple software terms apply: https://www.apple.com/legal/sla/. Qwen inference and its third-party notices remain in the source/binary, but its iOS interface and runtime entrypoints are disabled; Mac availability is unchanged.
