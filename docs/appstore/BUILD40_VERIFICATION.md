# Build 40 — One Mac window, Studio

Build 40 contains build 39 plus the interface fixes from the macOS review ([PR #56](https://github.com/jorgepb96/nodus-reader/pull/56)). It is distributed on iOS to the Internal group and on macOS to the Internal group only.

## Changes

- iPad and Mac: Settings is a sidebar destination shown in the detail column (sidebar gear; ⌘, on the Mac), not a sheet or a separate window.
- Mac: the reader opens in the detail column with the library sidebar folded; a reader-bar button or ⌃⌘S shows it. The sidebar reaches the top of the window and every page uses the app background.
- Mac: a Studio tab in Voices & Models for Ming voices (record, add an audio file, rename, delete after confirmation), listed with Ming's voices as Studio voices.
- All platforms: voice sample buttons spin while the sample is synthesised; Voices & Models opens on Models; the wordmark and the Import capsule no longer sit inside the toolbar glass.

## Checks

| Check | Result |
| --- | --- |
| iPhone 17 Pro unit/integration suite | 138 passed (PR #56) |
| macOS and iPhone 17 Pro Simulator builds | Succeeded |
| Localization | 824 keys, 0 missing Spanish, 0 placeholder mismatches |

Not verified: UI tests, a real iPhone, and the new Mac window on screen (reader in the detail column, sidebar toggling, Studio). A copy of Nodus Reader installed in `/Applications` was running, and a second instance exits at once.

## Distribution

Version 0.1.0 (40). What to Test: iOS [English](TestFlight-40-ios-en.txt) / [Spanish](TestFlight-40-ios-es.txt); macOS [English](TestFlight-40-macos-en.txt) / [Spanish](TestFlight-40-macos-es.txt).
