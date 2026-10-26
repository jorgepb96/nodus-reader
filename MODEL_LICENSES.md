# Model and Voice Licences

> **Models are not covered by the AGPL-3.0.** Nodus Reader's code is AGPL-3.0-only;
> each model and voice keeps only its own licence. Phonon 40M Spanish and Multilingual
> are CC BY-NC 4.0 (Gradium): non-commercial use only, whatever the app's licence, and
> the same applies to the Core ML files converted from them on a user's device.

Nodus Reader does not bundle or redistribute neural model weights or voice
embeddings. Models are downloaded on the user's device, after an explicit action, and
remain local. This file records the verified licences for the engines that ship in
the app.

## Engines in this build

| Engine | Source | Licence | Distribution |
|---|---|---|---|
| Apple system voices (`AVSpeechSynthesizer`) | Operating system | Apple OS licence | No weights distributed by Nodus Reader |
| Kokoro 82M Core ML | [mattmireles/kokoro-coreml](https://github.com/mattmireles/kokoro-coreml), pinned at `43ef0237306c3c1ea0138098c9f92930ae4cf3f7`; weights [hexgrad/Kokoro-82M](https://huggingface.co/hexgrad/Kokoro-82M), hosted bundle [mattmireles/kokoro-coreml](https://huggingface.co/mattmireles/kokoro-coreml) | Apache-2.0 | Downloaded from a pinned Hugging Face revision; starter bundle plus the 27 other English voice files of the same pinned revision (each verified against its published SHA-256), 28 voices, English |
| Kokoro Spanish voices | `ef_dora`, `em_alex`, `em_santa` of [hexgrad/Kokoro-82M](https://huggingface.co/hexgrad/Kokoro-82M), downloaded as raw float32 tables from [onnx-community/Kokoro-82M-v1.0-ONNX](https://huggingface.co/onnx-community/Kokoro-82M-v1.0-ONNX) at `1939ad2a8e416c0acfeecc08a694d14ef25f2231` | Apache-2.0 | Three files of 510 KB, each verified against its pinned SHA-256 and added to the installed bundle's manifest; Spanish (Spain) |
| Kokoro Spanish G2P | `SpanishG2P` in this repository (rule-based, AGPL-3.0-only) | AGPL-3.0-only | Reproduces the espeak-ng phonemes the Spanish voices were trained with; espeak-ng itself (GPL-3.0) is not used or distributed |
| Kokoro G2P | [mattmireles/MisakiSwift](https://github.com/mattmireles/MisakiSwift) pinned revision `3a27756a…`, MIT-licensed [mlx-swift](https://github.com/ml-explore/mlx-swift), Apache-2.0 FluidAudio-derived G2P and NemoTextProcessing | Apache-2.0 / MIT | Swift Package dependencies |
| Phonon 31M Core ML | [gradium/phonon-31m-en](https://huggingface.co/gradium/phonon-31m-en) weights, Core ML bundle [mosiah/phonon-31m-en-coreml](https://huggingface.co/mosiah/phonon-31m-en-coreml), runtime [gradium-ai/xn-ptts](https://github.com/gradium-ai/xn-ptts) v0.4.1 | Apache-2.0 (`ptts` also offers MIT) | Downloaded from a pinned Hugging Face revision; English, nine voices |
| Phonon voices | [gradium/phonon-voices](https://huggingface.co/gradium/phonon-voices) | Apache-2.0 | Included in the Phonon bundle |
| Phonon 40M Spanish | [gradium/phonon-40m-es](https://huggingface.co/gradium/phonon-40m-es) @ `f0d2f39` | CC BY-NC 4.0, gated | **Never hosted or shipped by Nodus Reader.** Each user signs in to Hugging Face with an account that accepted Gradium's conditions; the app downloads the checkpoint with that access (SHA-256 verified), converts it to Core ML on the device with Gradium's exporter (built into PhononCore, see `Modules/PhononTTS/engine/`) and deletes the downloaded weights. Runs with the 25 Spanish voices of `gradium/phonon-voices` @ `0ee1720`. Non-commercial use |
| Phonon 40M Multilingual | [gradium/phonon-40m-multilingual](https://huggingface.co/gradium/phonon-40m-multilingual) @ `1537ce4` | CC BY-NC 4.0, gated | Same on-device path as Spanish: downloaded with the user's own access, verified, converted on the device; never hosted or shipped. Runs with all 102 voices of `gradium/phonon-voices` (English, Spanish, French, German, Portuguese), each normalizing text in its own language. Non-commercial use |

## Third-party runtime packages

| Package | Licence | Use |
|---|---|---|
| `KokoroCoreML` / `KokoroTTS` | Apache-2.0 | Kokoro inference and text preparation |
| `MisakiSwift` | Apache-2.0 | English phonemization |
| `mlx-swift` | MIT | Misaki runtime |
| `NemoTextProcessing` binary | Apache-2.0 | Text normalisation FSTs |
| `ptts` / `PhononCore` | Apache-2.0 (package also includes MIT) | Phonon Core ML inference |
| ZIPFoundation | MIT | EPUB container parsing |

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

## Attribution in the app

The Models screen links each model card, shows the licence and source, and links to
this file from About. The About screen also links to the third-party notices.
