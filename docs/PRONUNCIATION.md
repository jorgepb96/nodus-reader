# Per-book pronunciation

Select a name in EPUB/text or PDF Intelligent Reading and choose Pronunciation. The book context menu and player options also open the dictionary, including for Original PDF. Enter the written name and how the selected voice should read it; compare Original and With correction before saving. Preview pauses narration without changing its cursor. Close the preview and resume explicitly.

Rules apply to complete names throughout that book, respecting case and accents (canonical Unicode equivalents match). Longer names at the same position win. Replacements are not applied recursively. Separate spellings need separate entries. All installed engines receive the same substituted text, so a spelling may need adjusting after a voice/language change. The original document, searches and annotations are unchanged.

The dictionary is stored on Book and optionally synced as private CloudKit metadata. Existing clients without the field preserve it. Conflict resolution follows the existing book timestamp policy. Audio is generated per device. The pronunciationsJSON STRING field was deployed to Production on 3 November 2026 and verified against a fresh schema export; see docs/appstore/CLOUDKIT_SCHEMA_DEPLOYMENT_2026-11-03.md.

Both live and bulk generation use the same sentence preparation and source-range map. Alignment runs on the spoken text, then maps to the visible original; a corrected name is highlighted as one span. Cache identity includes the effective replacement and map, so unaffected sentence audio is reusable. A changed current sentence resumes by its original word, not an obsolete audio time. Older audio files remain subject to the existing cache cleanup policy.

Verification: unit tests cover matching, Unicode, mapping, selective cache signatures, persistence, legacy cursors and inbound sync. UI tests cover dictionary CRUD and selection from PDF reflow. pronunciationSynthesizesWithInstalledEngines is opt-in via TEST_RUNNER_NODUS_PRONUNCIATION_AUDIO_TESTS=1. It uses models already installed in the test host’s model directory, never downloads models and never opens the personal library.

## Verification on 2026-11-03

- iOS Simulator and macOS builds pass.
- Seven new logic/persistence/sync tests pass. Dictionary CRUD passes on iPhone and iPad; selection-to-editor passes in PDF Intelligent Reading on iPhone, with screenshot inspection.
- Real synthesis and mapped ranges pass with Kokoro Spanish (Dora), Phonon 31M, Phonon 40M Spanish (Noa), and Ming (US James). Only temporary APFS copies of existing models were used, and those copies were removed afterward.
- Final macOS regression run: all 206 tests pass (12.809 seconds). The scanned-PDF OCR test passes its original content and layout assertions. Temporary OCR diagnostics were removed; the parser was not changed. Mixing signed and unsigned test artifacts required rebuilding and consistently ad-hoc signing the generated test app before the final test-without-building run.
- The Production schema deployment and fresh-export contract check pass. A signed Mac–physical-iPhone round trip in Development passes initial rule, return edit and deletion, using the app’s serializer, remote apply and isolated SwiftData storage. The temporary zone was removed. This does not claim a Production-data or original-file round trip.
