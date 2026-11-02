# Build 48 — reader, replay, iCloud and format shelves

Version **0.1.0 (48)** contains the fixes merged in [PR #68](https://github.com/jorgepb96/nodus-reader/pull/68).
The build-number change and What to Test notes were archived from commit
`912eb35f76586d707bf6d2fd429629a58b120b76`.

## Changes

- PDF Intelligent Reading lets narration control line-following without a
  competing top anchor. Visible-page tracking and explicit jumps still work.
- iCloud originals and covers use coordinated reads. Downloads are shared by
  concurrent opening requests and staged before replacing a local file.
- Mac Read & Listen waits for the original; the window and toolbar use the app
  palette, including the top of the sidebar.
- Settings starts on App theme, including on return visits.
- Completed narration shows a circular replay control and restarts the document
  from its first sentence. Pauses retain their position.
- Home has nonempty EPUB, Texts, PDF, Markdown, HTML and RTF shelves, with
  format-specific See all destinations. Texts includes pasted/imported TXT files
  and finished documents.

## Validation

- iOS and native macOS Release archives and distribution exports succeeded.
- Exported IPA and Mac app signatures were verified. Both use build 48, the
  expected team and Production iCloud entitlements; the Mac app is sandboxed and
  arm64-only. The Mac installer signature was also checked.
- The iOS Share Extension's build number matches the containing app.
- A signed Release simulator build was installed and launched afresh on iPhone
  17 Pro and iPad Pro 13-inch (M5), both iOS 26.5. Both processes stayed running.
- The unchanged app code was validated before this version bump: iPhone 189,
  iPad 186 and Mac 183 passed test definitions, with no failures. See the
  [full report and exclusions](../READER_FIXES_2026-11-02.md).
- Sepia toolbar/sidebar appearance was subsequently verified in native Mac full
  screen; the follow-up is recorded on PR #68.
- The CloudKit payload contract still matches the existing schema (7 record
  types, 54 fields); this release does not add synced fields.

## Signed export artifacts

| Platform | Export | Bytes | SHA-256 |
| --- | --- | ---: | --- |
| iOS | `build/export-ios-48/Nodus Reader.ipa` | 52,887,284 | `49863c2c3606c69aba4208591121adf58870998562309887f54947678ca72735` |
| macOS | `build/export-macOS-48/Nodus Reader.pkg` | 48,077,439 | `209f11ca3477b5ce8066c4090a79754f6e85743191c2a7277c55e3af5640ec61` |

These hashes identify the locally verified exports. Xcode subsequently exported
the same archives for upload, including symbols; a re-signed upload package need
not have the same container hash.

## TestFlight distribution

- iOS upload `d8791706-0715-47dc-adb5-7d5d42d5085d` completed on 2 November 2026
  at 21:25:40 Europe/Madrid.
- macOS upload `670cd968-454e-4b7a-81e8-bb5d3640f709` completed at 21:27:47.
- Both builds finished processing as **VALID**, without upload errors or
  warnings.
- iOS 48 is assigned to **Internal** and **Nodus Reader — Public Beta**. Beta App
  Review returned **APPROVED** and the external state is **IN_BETA_TESTING**;
  automatic tester notification is enabled.
- macOS 48 is assigned to **Internal** only, with internal state
  **IN_BETA_TESTING**. It has no public-group assignment and no beta review
  submission; its external state remains **READY_FOR_BETA_SUBMISSION**.
- iOS builds on Apple silicon Macs remain disabled for both groups.

The English (U.S.) and Spanish (Spain) What to Test notes are saved on both
builds. No App Store production release was submitted.

What to Test: iOS [English](TestFlight-48-ios-en.txt) /
[Spanish](TestFlight-48-ios-es.txt); macOS
[English](TestFlight-48-macos-en.txt) / [Spanish](TestFlight-48-macos-es.txt).
