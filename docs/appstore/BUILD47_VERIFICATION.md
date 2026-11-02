# Build 47 — Mac toolbar in full screen and scroll bars (macOS only)

Build 47 contains build 46 plus two Mac fixes:

- **Toolbar in full screen.**
  - The cause: in a window the page shows through the toolbar, but in full screen macOS moves the toolbar into its own window with a grey material.
  - The fix: the sidebar and the detail column now set the toolbar background to the app's sidebar and page colours (`.toolbarBackground(_:for: .windowToolbar)`, visible).
- **Scroll bars.**
  - The cause: with a mouse connected, macOS draws the grey legacy track.
  - The fix: the app now asks for overlay scroll bars (`AppleShowScrollBars = WhenScrolling` in its own defaults). They are thin, appear while scrolling and are drawn light or dark to suit the page.
  - A reader who chose "Always" in System Settings › Appearance keeps scroll bars always shown.

## Checks

| Check | Result |
| --- | --- |
| macOS Debug and Release builds | Succeeded |
| Visual check in full screen and of the scroll bars | **Not done.** Access to the app was not granted for the check. |
| Unit tests | Not run (the Mac's audio service was still hung and simulator test hosts deadlock at launch) |

Only macOS 47 is uploaded; iOS stays at 46.
