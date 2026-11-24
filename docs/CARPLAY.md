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

`com.apple.developer.carplay-audio` must be granted by Apple before a signed build can
include it. Until then only Simulator builds carry it
(`Config/NodusReader-Simulator.entitlements`, selected with
`CODE_SIGN_ENTITLEMENTS[sdk=iphonesimulator*]` in `project.yml`). Without the
entitlement, device and TestFlight builds simply do not appear in CarPlay.

Requesting it: the Account Holder fills in the CarPlay entitlement request at
developer.apple.com/contact/carplay, category **Audio**, describing the app as offline
narration of the user's own books with no text shown in the car.

When Apple grants it:

1. Add `com.apple.developer.carplay-audio` = `true` to `Config/NodusReader.entitlements`.
2. Remove `Config/NodusReader-Simulator.entitlements` and its line in `project.yml`, then
   run `xcodegen generate`.
3. Regenerate the iOS provisioning profiles (automatic signing does this) and verify on
   a real head unit or the CarPlay Simulator (Additional Tools for Xcode).

## Verification status

- Builds for iOS and macOS; `CarPlayChaptersTests` covers the chapter list (chapters
  without text skipped, untitled chapters numbered, the window around the current
  chapter in a 2,400-chapter book).
- The phone app still launches normally with the CarPlay scene declared.
- **Not yet exercised on a CarPlay screen**: this Xcode has no Simulator.app, whose
  I/O › External Displays › CarPlay menu is what drives the car screen. Check the
  templates there, or with the CarPlay Simulator, before shipping.
