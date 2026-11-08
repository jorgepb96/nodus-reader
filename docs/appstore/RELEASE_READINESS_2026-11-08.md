# iOS App Store release readiness — 8 November 2026

Reviewed against TestFlight build 74 (`main` at PR #79). Nothing was submitted to
App Review; the iOS and macOS 1.0 drafts remain **PREPARE_FOR_SUBMISSION** with no
build attached. macOS stays out of scope until requested.

## Verdict

**Not yet — about one to two weeks.** The product is complete and tested (358 unit
tests, 39 UI tests, public beta approved on every build). What remains is release
work: one version change, licence and policy paperwork, two physical-device checks
and refreshed listing material. None needs new features.

## Must do before submitting

| # | Item | Why | Who |
|---|---|---|---|
| 1 | Set `MARKETING_VERSION` to `1.0` (now `0.1.0`), upload a new build and attach it to the iOS 1.0 draft. | App Store Connect only accepts a build whose version string matches the App Store version. | Claude |
| 2 | Physical-device checks: iCloud sync between two devices/Apple IDs, and the Share Extension with the signed App Group (import a page and a file from Safari and Files). | The simulator cannot exercise CloudKit or the App Group; both are listed as unvalidated in `ROADMAP.md`. TestFlight builds are signed, so they can be tested now. | Jorge |
| 3 | Review the licences of the 127 Immersive Audio tracks (80 CC0, 34 CC-BY-3.0, 13 CC-BY-4.0). Every catalog entry still says "maintainer review pending", while Settings › Soundscapes › Credits says each sound was "checked one by one". Either confirm them (evidence snapshots are in `build/immersive-audio/evidence/`) and mark them verified in the catalog, or soften the in-app sentence. | App Store Connect declares "has the necessary rights" for third-party content; the claim and the record must agree. | Jorge, then Claude updates the catalog |
| 4 | **Done 8 November 2026.** Registered under the Stability AI Community License (individual developer, under US$1M revenue, customer-facing use); Stability confirmed the licence as activated (`evidence/stability-community-license-activated-2026-11-08.png`). "Powered by Stability AI", the licence texts and the Acceptable Use Policy are shown in the app. No other bundled or downloadable model requires registration. | Public distribution of a product built on the model. | Done |
| 5 | Update the privacy policy (repo `PRIVACY.md` and https://nodusresearch.com/reader/privacy/, last updated 3 November) to name the AI soundscape models: downloaded on request from `stabilityai/stable-audio-3-optimized` on Hugging Face, run on the device, generated audio stays local. | The policy lists Hugging Face downloads but not the soundscape models added since. | Claude drafts the repo text; Jorge publishes the web page |
| 6 | Write 1.0 review notes. `ReviewNotes-56-en.txt` describes a beta (five-minute sessions, pending validation). The 1.0 notes should cover: no account needed; how to get a book (import any DRM-free EPUB/PDF, e.g. from Project Gutenberg); iOS voices work without downloads; AI soundscapes are off by default, need an Apple-silicon iPhone and a ~2.6–2.9 GB download on request, and run on the device; the optional Hugging Face sign-in only unlocks gated non-commercial voices the user downloads with their own access. | Reviewers otherwise meet an empty library and multi-gigabyte downloads without context. | Claude |
| 7 | Refresh the screenshots. The current 60 captures come from build 56; the player, voice filters and Soundscapes settings have changed since. At minimum the iPhone 6.9" and iPad 13" sets in both languages. | The listing should show the app as shipped. | Claude (UI test capture) |

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
