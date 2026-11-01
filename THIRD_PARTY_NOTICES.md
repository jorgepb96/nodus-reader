# Third-Party Notices

Nodus Reader's own code is licensed under **AGPL-3.0-only** (see `LICENSE`). The following third-party components and assets are used under their own licences, which the AGPL-3.0 does not replace. Narration models in particular keep their own terms, including non-commercial ones (see *Narration models and voices*). This file must be kept accurate before distribution.

## NodusMark

- **Component:** `NodusMark` geometry and the Nodus ecosystem wordmark.
- **Source:** `nodus-drift-mobile/ios/NodusDrift/NodusMark.swift`.
- **Licence:** MIT.
- **Copyright:** © 2026 Jorge Pérez Burgueño.
- **Use in this project:** reused verbatim (with its SPDX header) in `Modules/DesignSystem/Sources/DesignSystem/NodusMark.swift`, and as the basis of `ReaderMark` (direction C · Pages) from `design/DESIGN.md`.
- **MIT text:** the full MIT permission notice is reproduced below.

```
MIT License

Copyright (c) 2026 Jorge Pérez Burgueño

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

No changes were made to the original Nodus Drift repository.

## Swift packages compiled into the app

Resolved versions are pinned in
`NodusReader.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`.

| Package | Source | Version | Licence | Use |
|---|---|---|---|---|
| ZIPFoundation | <https://github.com/weichsel/ZIPFoundation> | 0.9.20 | MIT, © 2017-2025 Thomas Zoechling | EPUB reading, EPUB folder packages, fixtures |
| KokoroTTS (`kokoro-coreml`) | <https://github.com/mattmireles/kokoro-coreml> | revision `43ef023` | Apache-2.0 | Kokoro Core ML pipeline and English G2P (`KokoroG2P`, derived from FluidAudio v0.17.4, Apache-2.0) |
| MisakiSwift | <https://github.com/mattmireles/MisakiSwift> | revision `3a27756`, vendored in `Modules/MisakiSwift/` with its mlx-swift pin raised to 0.33.0 (see `NODUS_VENDOR.md`) | Apache-2.0 | Kokoro English phonemizer |
| MLX Swift | <https://github.com/ml-explore/mlx-swift> | 0.33.0 | MIT, © 2023 ml-explore | MisakiSwift's fallback network and Ming; also linked directly to clear its GPU cache when voice engines unload |
| MLXAudio (`mlx-audio-swift`), macOS only | <https://github.com/Blaizzy/mlx-audio-swift> | revision `0dda61b` | MIT, © 2024 Prince Canuma | Ming 3.0 speech synthesis and its CAM++ speaker encoder (`MLXAudioTTS`, `MLXAudioCore`, `MLXAudioCodecs`) |
| swift-transformers | <https://github.com/huggingface/swift-transformers> | 1.3.5 | Apache-2.0 | MLXAudio dependency: Ming's tokenizer |
| swift-huggingface | <https://github.com/huggingface/swift-huggingface> | 0.13.0 | Apache-2.0 | MLXAudio dependency (the app downloads Ming itself) |
| swift-jinja | <https://github.com/huggingface/swift-jinja> | 2.5.2 | Apache-2.0 | swift-transformers dependency |
| swift-collections | <https://github.com/apple/swift-collections> | 1.7.5 | Apache-2.0 with Runtime Library Exception | swift-transformers dependency |
| swift-crypto, swift-asn1 | <https://github.com/apple/swift-crypto>, <https://github.com/apple/swift-asn1> | 4.5.2, 1.7.3 | Apache-2.0 | swift-huggingface dependencies |
| EventSource | <https://github.com/mattt/EventSource> | 1.5.1 | MIT, © 2025 Mattt | swift-huggingface dependency |
| yyjson | <https://github.com/ibireme/yyjson> | 0.12.0 | MIT, © 2020 YaoYuan | swift-transformers dependency |
| Zstandard | <https://github.com/facebook/zstd> | 1.5.7 | BSD-3-Clause (dual BSD/GPLv2; used under BSD) | MLXAudio dependency |
| MLXUtilsLibrary | <https://github.com/mlalma/MLXUtilsLibrary> | 0.0.6 | Apache-2.0 | MisakiSwift dependency |
| Swift Numerics | <https://github.com/apple/swift-numerics> | 1.1.1 | Apache-2.0 with Runtime Library Exception | MLX Swift dependency |
| NemoTextProcessing (binary) | <https://github.com/FluidInference/text-processing-rs> | v0.3.1 | Apache-2.0 | English text normalization for Kokoro |
| `ptts` / PhononTTS | <https://github.com/gradium-ai/xn-ptts> | v0.4.1 (Swift sources vendored in `Modules/PhononTTS/`) | MIT OR Apache-2.0 | Phonon narration |
| PhononCore (binary, **modified**) | xn-ptts v0.4.1, rebuilt by this project | `phononcore-0.4.1-nodus.1` release of this repository | MIT OR Apache-2.0 | Phonon runtime; see below |

The MIT notices keep their copyright lines; the Apache-2.0 licence text is at
<https://www.apache.org/licenses/LICENSE-2.0>. Each package's full licence ships in its
source checkout.

### Modified PhononCore

`PhononCore.xcframework` is Gradium's compiled Phonon core rebuilt from xn-ptts
v0.4.1 with one change, made by Nodus Reader in 2026: `ptts_export_coreml`, which moves
Gradium's own `ptts/examples/export_coreml.rs` exporter into `ptts-ffi` so a checkpoint
can be converted to Core ML on the device. The change is
`Modules/PhononTTS/engine/0001-ptts-ffi-export-coreml.patch`, built with
`Modules/PhononTTS/engine/build-phononcore.sh`. The binary contains no model weights.

## Narration models and voices (downloaded on the device, never bundled)

> **Models keep their own licences.** Nodus Reader's code is AGPL-3.0-only, but that
> licence does **not** apply to the narration models or voices. Each one is governed
> only by its own licence, listed below, whatever licence the app has. In particular,
> **Phonon 40M Spanish and Phonon 40M Multilingual are licensed by Gradium under
> CC BY-NC 4.0: non-commercial use only.** Using Nodus Reader does not grant any right
> to use those models commercially, and the AGPL-3.0 does not extend to them or to
> the Core ML files converted from them. Anyone who downloads them accepts Gradium's
> conditions on Hugging Face themselves.

No model weights or voices are stored in this repository or in the app. Each is
downloaded on request, checked against pinned sizes and SHA-256 hashes, and run only on
the device that downloaded it.

| Model or voices | Source | Licence | How the app gets it |
|---|---|---|---|
| Kokoro-82M by hexgrad | Core ML bundle and 28 voices from <https://huggingface.co/mattmireles/kokoro-coreml> at `034f774` | Apache-2.0 | Downloaded and verified by the KokoroTTS SDK |
| Kokoro-82M Spanish voices by hexgrad (`ef_dora`, `em_alex`, `em_santa`) | Voice tables from <https://huggingface.co/onnx-community/Kokoro-82M-v1.0-ONNX> at `1939ad2` (the same voices as [hexgrad/Kokoro-82M](https://huggingface.co/hexgrad/Kokoro-82M), as raw float32 tables) | Apache-2.0 | Downloaded on request and verified against pinned SHA-256 values; never bundled |
| Phonon 31M English by Gradium, built on Kyutai's Pocket TTS | Core ML bundle <https://huggingface.co/mosiah/phonon-31m-en-coreml> at `0a2596e`, from <https://huggingface.co/gradium/phonon-31m-en> | Apache-2.0 | Downloaded, verified by `bundle.json` |
| Phonon voices by Gradium | <https://huggingface.co/gradium/phonon-voices> at `0ee1720` (9 English voices with 31M; 25 Spanish voices with 40M Spanish; all 102 with 40M Multilingual) | Apache-2.0 | Downloaded and hash-checked |
| Phonon 40M Spanish by Gradium | <https://huggingface.co/gradium/phonon-40m-es> at `f0d2f39` | CC BY-NC 4.0, gated | Downloaded with **the user's own** Hugging Face access after they accept Gradium's conditions, converted to Core ML on the device, weights deleted after conversion |
| Phonon 40M Multilingual by Gradium | <https://huggingface.co/gradium/phonon-40m-multilingual> at `1537ce4` | CC BY-NC 4.0, gated | Same as Phonon 40M Spanish |
| Ming 3.0 0.5B by inclusionAI (Mac only) | 8-bit MLX conversion <https://huggingface.co/mlx-community/Ming-3.0-tts-0.5B-8bit> at `c807b99` (weights, tokenizer and CAM++ speaker encoder), from <https://huggingface.co/inclusionAI/Ming-3.0-tts-0.5B> | MIT (CAM++ from 3D-Speaker, Apache-2.0) | Downloaded on request; every file verified against its pinned size and SHA-256 |
| `es-dave` reference clip (bundled) | 9.8 s clip `0000000003` of `es_ES/dave` from <https://github.com/OHF-Voice/voice-datasets> (release v1.0.0), as Nodus ships it | CC0 1.0 | **Bundled** in `NodusReader/Resources/MingVoices/` as Ming's included cloned voice; `NOTICE.md` credits the dataset |

Phonon 40M models: the Core ML conversion is an adaptation of the original weights made
on the user's device for non-commercial use, as CC BY-NC 4.0
(<https://creativecommons.org/licenses/by-nc/4.0/>) allows. Nodus Reader is free and
carries no advertising. The converted files are not shared or synced. See
`MODEL_LICENSES.md` for details.

## Apple frameworks

The app links Apple SDK frameworks including SwiftUI, Foundation, SwiftData, CloudKit, PDFKit, AVFoundation, MediaPlayer, PhotosUI, CoreGraphics, CoreText, ImageIO, Vision, Core ML, Accelerate, CryptoKit, Security, AuthenticationServices and UniformTypeIdentifiers. These frameworks are provided with the Apple SDK and are not redistributed as part of this repository. Their use is governed by the Apple Developer Program License Agreement and the Xcode licence.

System voices used by `AVSpeechSynthesizer` are part of the operating system and are not distributed by Nodus Reader.

## Nodus narration sync design reference

The pause-detection and pause-to-word alignment design documented in
`docs/NARRATION_SYNC.md` was reviewed from the Nodus repository
(`shared/narrationSync.ts`, `electron/tts/fragmentSync.ts`,
`electron/tts/wavConcat.ts`), which is AGPL-3.0-only. The Swift implementation is an
independent reimplementation of the published algorithm; no Nodus source file was
copied. If code is ported later, it must retain the AGPL-3.0-only SPDX header and an
attribution here.

## Design assets

- `design/` contains the approved Nodus Reader visual system, screen references, brand marks and app icon masters. They are part of this repository and are distributed under the project's AGPL-3.0-only licence unless a file states otherwise.
- The ReaderMark direction C and the AppIcon Dark/Light/Tinted masters in `design/icon/` are derived from the Nodus visual language and the MIT-licensed NodusMark.
- Sample book text in the debug sample library is public-domain prose (Melville, Cervantes, Marcus Aurelius, Thoreau, Homer, Eliot, Mendel, Darwin) or original placeholder prose written for interface testing. Book titles and author names are facts.

## Fonts

No font files are bundled. Display and reading text use the Apple system serif (New York) and SF Pro; the HTML design references Newsreader/Inter only as web stand-ins.

## Immersive Audio sounds (downloaded on request, never bundled)

The music and ambient recordings that Immersive Audio downloads are CC0-1.0 (public
domain dedication) or CC-BY 3.0/4.0 (attribution: each author, source, licence and the
changes made are credited in the app and in the provenance record). They come from OpenGameArt.org, Freesound.org and the
Free Music Archive, selected for Nodus Reader one by one. The authors are credited in the app (Settings › Immersive Audio › Credits and licences)
and in `docs/immersive-audio/PROVENANCE.md`, which records for every file its source page,
licence evidence, original and processed SHA-256 and every transformation applied. Only
the catalog manifest (`NodusReader/Resources/ImmersiveAudio/catalog.json`) ships in the app.

## Services the app can contact

Only at the user's request: Hugging Face (model and voice downloads, optional sign-in
through Hugging Face's own OAuth page), jsDelivr (serves this repository's OAuth client
metadata, `oauth/huggingface-client.json`, which Hugging Face reads), Apple iCloud
(optional sync), the Immersive Audio catalog (Hugging Face dataset
`jorgepb96/nodus-reader-immersive-audio`, mirrored as a GitHub Release of this
repository) and the web pages a user shares to the app. See `PRIVACY.md`.

## Trademarks

EPUB is a registered trademark of the IDPF/W3C. PDF is a trademark of Adobe. Apple, iPhone, iPad, Mac, iCloud, App Store and TestFlight are trademarks of Apple Inc. Hugging Face is a trademark of Hugging Face, Inc. Nodus Reader is not affiliated with or endorsed by Apple, Hugging Face, Gradium, Kyutai or hexgrad.
