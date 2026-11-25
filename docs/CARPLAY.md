# CarPlay

Nodus Reader is a CarPlay **audio** app: narration only, never book text.

## What the car shows

- **Recent** — the book to continue and the next ones, as on Home.
- **All Books** — the library by title (up to the car's row limit).
  A book that is only in iCloud is listed but disabled ("Not downloaded").
- Choosing a book plays it from where it was left (`PlaybackController.start(book:mode: .listen)`)
  and opens **Now Playing**: play/pause, previous/next sentence (the existing remote
  commands), a speed button that steps through `PlaybackController.speedOptions`, and
  **Chapters**, which lists the chapters with text around the one playing
  (`CarPlayChapters`) and jumps to the first sentence of the one chosen.
- Errors from narration (for example a voice that cannot run) appear as a CarPlay alert.

Code: `NodusReader/Features/CarPlay/`. The app attaches its library, playback and model
manager to `CarPlayServices` at launch, so the car works even when it launches the app
without the phone's window. The scene is declared in `NodusReader/Info.plist`
(`CPTemplateApplicationSceneSessionRoleApplication` → `NodusCarPlaySceneDelegate`);
SwiftUI still provides the phone and iPad window scene.

## Entitlement

Apple granted the CarPlay Audio App entitlement to the account on 2026-11-25.
`com.apple.developer.carplay-audio` is in `Config/NodusReader.entitlements`, so every iOS
build carries it.

It is a managed capability: it must also be enabled on the App ID, or automatic signing
fails with "Entitlement com.apple.developer.carplay-audio not found and could not be
included in profile". In Certificates, Identifiers & Profiles › Identifiers ›
`ai.nodus.reader` › Additional Capabilities, enable **CarPlay Audio App** and save; the
next build with automatic signing regenerates the profiles. It was enabled on
2026-11-25, and a signed iOS build now embeds the entitlement in its profile.

## Verification status

- Builds for iOS and macOS; `CarPlayChaptersTests` covers the chapter list (chapters
  without text skipped, untitled chapters numbered, the window around the current
  chapter in a 2,400-chapter book).
- The phone app still launches normally with the CarPlay scene declared.
- **Not yet exercised on a CarPlay screen.** Xcode 27.1 replaced Simulator.app with
  Device Hub, which has no CarPlay display. Creating SimulatorKit's CarPlay HID service
  by hand (`IndigoHIDMessageToCreateCarPlayService`) does not bring the car screen up
  either. Check the templates with a signed build on an iPhone connected to the CarPlay
  Simulator (Additional Tools for Xcode), in a car, or with Xcode 26's Simulator
  (I/O › External Displays › CarPlay), before shipping.
