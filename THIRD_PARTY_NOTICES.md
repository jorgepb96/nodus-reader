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

## Apple frameworks

The app links Apple SDK frameworks including SwiftUI, Foundation, SwiftData, PDFKit, AVFoundation, MediaPlayer, PhotosUI, CoreGraphics, CoreText, ImageIO, Vision (planned) and UniformTypeIdentifiers. These frameworks are provided with the Apple SDK and are not redistributed as part of this repository. Their use is governed by the Apple Developer Program License Agreement and the Xcode licence.

System voices used by `AVSpeechSynthesizer` are part of the operating system and are not distributed by Nodus Reader.

## Nodus narration sync design reference

The pause-detection and pause-to-word alignment design documented in `docs/NARRATION_SYNC.md` was reviewed from the Nodus repository (`shared/narrationSync.ts`, `electron/tts/fragmentSync.ts`, `electron/tts/wavConcat.ts`), which is AGPL-3.0-only. No Nodus source code has been copied into Nodus Reader yet. If the algorithm is ported, the ported files will retain the AGPL-3.0-only SPDX header and an attribution to the Nodus project will be added here.

## Design assets

- `design/` contains the approved Nodus Reader visual system, screen references, brand marks and app icon masters. They are part of this repository and are distributed under the project's AGPL-3.0-only licence unless a file states otherwise.
- The ReaderMark direction C and the AppIcon Dark/Light/Tinted masters in `design/icon/` are derived from the Nodus visual language and the MIT-licensed NodusMark.
- Sample book text in the debug sample library is public-domain prose (Melville, Cervantes, Marcus Aurelius, Thoreau, Homer, Eliot, Mendel, Darwin) or original placeholder prose written for interface testing. Book titles and author names are facts.

## Fonts

No font files are bundled. Display and reading text use the Apple system serif (New York) and SF Pro; the HTML design references Newsreader/Inter only as web stand-ins.

## Trademarks

EPUB is a registered trademark of the IDPF/W3C. PDF is a trademark of Adobe. Apple, iPhone, iPad, Mac, iCloud, App Store and TestFlight are trademarks of Apple Inc. Nodus Reader is not affiliated with or endorsed by Apple.
