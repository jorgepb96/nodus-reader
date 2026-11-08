# iOS App Store release readiness — 8 November 2026

Reviewed against TestFlight build 74 (`main` at PR #79). Nothing was submitted to
App Review; the iOS and macOS 1.0 drafts remain **PREPARE_FOR_SUBMISSION** with no
build attached. macOS stays out of scope until requested.

## Verdict

**Ready for review whenever Jorge decides** (updated 8 November 2026, evening). Every must-do item below is done; nothing has been submitted. The product is complete and tested (358 unit
tests, 39 UI tests, public beta approved on every build). What remains is release
work: one version change, licence and policy paperwork, two physical-device checks
and refreshed listing material. None needs new features.

## Must do before submitting

| # | Item | Why | Who |
|---|---|---|---|
| 1 | **Done.** `MARKETING_VERSION` is 1.0.0; build 1.0.0 (76) is in TestFlight (Internal) and attached to the iOS draft, renamed 1.0.0 to match. Release type manual. | App Store Connect only accepts a build whose version matches. | Done |
| 2 | **Done 8 November 2026.** iCloud sync between iPhone and Mac checked by Jorge with TestFlight build 75 on both. On a real iPhone 16 Pro Max (iOS 27.2) the full UI suite passes and `ShareExtensionDeviceTests` shares a page from Safari to the Share Extension, which reaches the signed App Group and offers Import. | The simulator cannot exercise CloudKit or the App Group. | Done |
| 3 | **Done.** Settings › Soundscapes › Credits now says each sound comes from CC0 or CC-BY sources with its licence recorded, matching the catalog; the in-app credits list every author, licence, source and change. | The claim and the record agree. | Done |
| 4 | **Done 8 November 2026.** Registered under the Stability AI Community License (individual developer, under US$1M revenue, customer-facing use); Stability confirmed the licence as activated (`evidence/stability-community-license-activated-2026-11-08.png`). "Powered by Stability AI", the licence texts and the Acceptable Use Policy are shown in the app. No other bundled or downloadable model requires registration. | Public distribution of a product built on the model. | Done |
| 5 | **Done.** `PRIVACY.md` and https://nodusresearch.com/reader/privacy/ (jorgepb96/nodus#1334, live) name the AI soundscape models, their download from Stability AI on Hugging Face, local composition and no sync. Last updated 8 November 2026. | Done | Done |
| 6 | **Done.** `ReviewNotes-1.0.0-en.txt` saved in App Store Connect: no account, how to get a book, iOS voices without downloads, optional models and AI soundscapes (off by default, 2.6–2.9 GB, on device), microphone only on Mac, privacy policy and source links. | Done | Done |
| 7 | **Done.** 40 new screenshots (iPhone 6.9" and iPad 13", English and Spanish, 10 each) from build 75/76, uploaded and COMPLETE (`SCREENSHOTS_20261108.json`). The iPhone Duo sets are still from build 56. An App Preview video recorded on a real iPhone (to show AI soundscapes, which the Simulator cannot run) is left to Jorge. | Done | Done |

## Should do (not blocking review)

- Leave build 73/74 in the public beta for a week and read TestFlight crashes and
  feedback in App Store Connect before submitting.
- Accessibility pass (VoiceOver, Dynamic Type, contrast, Reduce Motion), still open in
  `ROADMAP.md`.
- Final re-check of every upstream model licence and card, as `MODEL_LICENSES.md`
  itself requires before an App Store release.
- AGPL-3.0-only and the App Store: all 236 commits are by the copyright holder and the
  vendored third-party code is MIT or Apache-2.0 only, so the author can distribute
  through the App Store. Adding an explicit App Store additional permission to
  `LICENSE`/`README.md` would let others redistribute builds too; optional.

## Already in order

| Check | State |
|---|---|
| Age rating | 4+, including the new 2025 questions (no UGC, chat, ads, web access). |
| App privacy | Data Not Collected; no analytics or tracking SDK. |
| Privacy manifests | App declares UserDefaults (CA92.1), file timestamps (C617.1), disk space (E174.1) and system boot time (35F9.1); the Share Extension declares file timestamps. Fixed in build 74. ZIPFoundation ships its own. |
| Export compliance | `ITSAppUsesNonExemptEncryption` = false. |
| Permissions | Microphone string present (Studio is Mac-only; iOS never asks). Word timing uses `SpeechAnalyzer` on the device. |
| Background audio | `UIBackgroundModes` = audio, used by narration. |
| Downloads | Sound pack catalog and files resolve on the GitHub Release; the Stability model pin and the Hugging Face OAuth client metadata resolve. The Hugging Face mirror of the packs is unpublished, and the catalog keeps GitHub as a host. |
| Source availability (AGPL) | Settings links to the public repository. |
| Third-party notices | `THIRD_PARTY_NOTICES.md` and `MODEL_LICENSES.md` cover every engine, model and package, including Stability and Gemma notices. |
| Metadata | Name, subtitle, description, keywords and categories filled in both languages; description already mentions soundscapes. |

## Submission sequence

1. Items 2–4 (Jorge) while the public beta runs.
2. Items 1, 5 (repo), 6 and 7 in one build (Claude), then a final TestFlight pass.
3. Attach the 1.0 build, paste the review notes, submit iOS for review with manual
   release. macOS remains private.
