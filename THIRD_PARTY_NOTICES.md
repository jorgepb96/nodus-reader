# Third-Party Notices

Nodus Reader is licensed as a whole under **AGPL-3.0-only** (see `LICENSE`). The following third-party components and assets are used under their own licences. This file must be kept accurate before distribution.

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

## ZIPFoundation

- **Component:** ZIP/ZIP64 archive reading and writing used by the EPUB importer.
- **Source:** <https://github.com/weichsel/ZIPFoundation>.
- **Version:** resolved through Swift Package Manager from 0.9.19.
- **Licence:** MIT.
- **Copyright:** © 2017 Thomas Zoechling.
- The MIT permission notice is the same as above, with Thomas Zoechling's copyright line.

## Kokoro Core ML SDK and G2P

- **Component:** `KokoroTTS`, `KokoroPipeline`, `KokoroG2P`.
- **Source:** <https://github.com/mattmireles/kokoro-coreml>, pinned at revision
  `43ef0237306c3c1ea0138098c9f92930ae4cf3f7`; product `KokoroTTS`.
- **Licence:** Apache-2.0.
- **Model:** Kokoro-82M by hexgrad, Apache-2.0; hosted starter bundle from
  `mattmireles/kokoro-coreml` at revision `034f7741bf938fd6b4b9c75c22bc72cd795f908a`.
- **G2P:** MisakiSwift (`https://github.com/mattmireles/MisakiSwift`, Apache-2.0),
  MLX Swift (`https://github.com/ml-explore/mlx-swift`, MIT), FluidAudio-derived
  English G2P (Apache-2.0) and the NemoTextProcessing binary
  (`https://github.com/FluidInference/text-processing-rs` v0.3.1, Apache-2.0).
- **Use:** downloaded and executed only on the user's device. The app never bundles
  weights. The pinned SDK verifies the hosted manifest and every file hash.

## Phonon Core ML SDK

- **Component:** `ptts` Swift package / `PhononTTS` / `PhononCore.xcframework`.
- **Source:** <https://github.com/gradium-ai/xn-ptts> release v0.4.1. The package is
  vendored under `Modules/PhononTTS/`; it declares Apache-2.0 and also includes an
  MIT licence for parts of the runtime.
- **Model:** Phonon 31M English by Gradium, Apache-2.0, from
  `https://huggingface.co/gradium/phonon-31m-en`. Core ML bundle
  `https://huggingface.co/mosiah/phonon-31m-en-coreml`, pinned revision
  `0a2596e9154f0340005b6445514fdd57f7bc9ddb`.
- **Voices:** `https://huggingface.co/gradium/phonon-voices`, Apache-2.0.
- **Use:** downloaded on request, verified by `bundle.json` size and SHA-256, and run
  locally. No weights are distributed in this repository.
- **Not used:** the gated, CC BY-NC 4.0 Phonon 40M Spanish and multilingual
  checkpoints. They have no published Core ML bundle and the app does not offer them
  for download.

## Apple frameworks

The app links Apple SDK frameworks including SwiftUI, Foundation, SwiftData, CloudKit, PDFKit, AVFoundation, MediaPlayer, PhotosUI, CoreGraphics, CoreText, ImageIO, Vision and UniformTypeIdentifiers. These frameworks are provided with the Apple SDK and are not redistributed as part of this repository. Their use is governed by the Apple Developer Program License Agreement and the Xcode licence.

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

## Trademarks

EPUB is a registered trademark of the IDPF/W3C. PDF is a trademark of Adobe. Apple, iPhone, iPad, Mac, iCloud, App Store and TestFlight are trademarks of Apple Inc. Nodus Reader is not affiliated with or endorsed by Apple.
