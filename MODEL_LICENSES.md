# Model and Voice Licences

Nodus Reader does not bundle or distribute any neural model weights or voice embeddings. This file records the licences that must be verified before the model manager ships.

## Voice engines in this build

| Engine | Weights | Licence | Status |
|---|---|---|---|
| Apple system voices (`AVSpeechSynthesizer`) | Provided by the OS | Apple OS licence | In use; no weights distributed by Nodus Reader |

System voices are installed by the operating system. Voice names, quality levels and availability vary by device and OS version. They never sync and are never uploaded.

## Planned neural engines

These engines are **not included** in this build. The Hugging Face model manager and neural engines are Milestone 6.

| Engine | Intended source | Licence to verify | Status |
|---|---|---|---|
| Kokoro 82M | <https://huggingface.co/hexgrad/Kokoro-82M> | Apache-2.0 (verify the model card and any third-party voice packs) | Not installed |
| Phonon 31M | Phonon release channel — verify before use | **Unknown / to verify** | Not installed |
| Phonon 40M Spanish | Phonon release channel — verify before use | **Unknown / to verify** | Not installed |
| Phonon 40M Multilingual | Phonon release channel — verify before use | **Unknown / to verify** | Not installed |
| sherpa-onnx / ONNX Runtime | <https://github.com/k2-fsa/sherpa-onnx> | Apache-2.0 (verify runtime and model conversions) | Not integrated |
| Core ML conversion tooling | Apple | Apple SDK licence | Not shipped |
| `xn-ptts` reference | <https://github.com/gradium-ai/xn-ptts> | Verify before reuse | Reference only |

The `[size]` and `[Voice name]` placeholders in `design/DESIGN.md` must stay unresolved until the corresponding model artefacts and licences are verified. Do not advertise sizes or voice names that have not been confirmed.

## Distribution rules

- Do not distribute restricted or gated model weights without explicit permission.
- Do not upload model files, voice embeddings, generated audio or OCR caches to iCloud.
- Store an optional Hugging Face token in the Keychain only. Never put it in CloudKit, the library folder or a shared file.
- Downloads are per device and strictly local. A book's preferred voice may sync, but a missing voice must fall back to the device default with an “Install voice” affordance.
- Any conversion scripts added for Core ML/ONNX must carry the source model's licence, attribution and conversion instructions.
- The final App Store/Mac App Store licence audit (Milestone 8) must re-check every engine, voice pack and model conversion before release.

## Attribution in the app

The Models screen links to this file. The About screen links to the third-party notices. Both must remain reachable without a network connection in a future release; consider bundling a generated copy of the licence texts.
