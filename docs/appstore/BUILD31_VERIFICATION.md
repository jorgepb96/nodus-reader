# Build 31 — PDF navigation and return to narration

Source: PR #32, commit `f30797479cd04dab71f86fd28c56408d36e53d8d`, merged into main as `2c04868ea470805418ec120d0eb27e1247e3793f`.

PDF uses the EPUB contents interface, including title/number search and the bookmarks/notes tabs. Outline links resolve direct destinations and GoTo actions, with searchable pages when no outline exists. Narration follow resolves the original PDF page IDs, including gaps in extracted chapters.

The location control beside the sleep timer returns to the current spoken position without seeking or resuming paused audio. It retains the automatic-follow preference and is available in the reader and full player. English and Spanish text is included.

## Verification

- iPhone 17 Pro simulator, iOS 26.5: **121 tests passed, 10 optional corpus/model tests skipped, 0 failures** (117 unit/integration tests and four UI tests).
- UI cases: EPUB contents title/number search; PDF contents search, navigation and return to paused narration with automatic following disabled; PDF highlights/notes; reader appearance and centred transport.
- Unit coverage includes nested PDF outline headings, GoTo actions, stable destinations and the no-outline page fallback.
- macOS Debug compilation passed.
- Localization: 708 keys, 0 missing Spanish, 0 placeholder mismatches.
- Local test bundle: `build/PDFNavigation-iOS.xcresult`. Screenshots: `build/pdf-navigation-captures/`.

## Distribution

Version 0.1.0 (31). Both signed archives passed deep/strict signature verification. The macOS installer signature also passed. Uploads succeeded in the requested order: iOS (`73e4a625-cbcd-47a1-9b57-32cf2dddb490`), then macOS (`539f5858-02d5-4d52-9670-0737f5651c03`). Both builds are **VALID** in App Store Connect. iOS is **IN_BETA_TESTING**, with public-group membership verified and English/Spanish release notes saved. The public link remains https://testflight.apple.com/join/SjCk8AZ1. The internal group has automatic access to all builds. macOS release notes are saved; no public macOS beta review was submitted. macOS public beta review remains withdrawn.
