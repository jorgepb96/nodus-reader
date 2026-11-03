# Build 51 — privacy and documentation

Version 0.1.0 (51) links the app to its dedicated privacy page at https://nodusresearch.com/reader/privacy/. About now contains the Nodus website, privacy, support and source-code links. The acknowledgements panel, the Drift logo attribution and promotional app-licence references have been removed from the interface. Required source licences and component permission notices remain in the repository.

English and Spanish copy has been revised in About, Privacy and Hugging Face model setup. Outdated claims about model availability have been corrected. README, the privacy policy, model documentation and listing text have been updated to match current features.

## Website and listing verification

- The Reader privacy page was updated in Nodus [PR #1331](https://github.com/jorgepb96/nodus/pull/1331), merged as `d5543f1d5a0c436f1d09c146d74f818bc7dc26bf`.
- All 115 website checks passed. Website deployment [41617875967](https://github.com/jorgepb96/nodus/actions/runs/41617875967) succeeded.
- The live canonical URL returned the updated policy and was inspected in the browser. It covers current on-device processing, optional iCloud, pronunciation rules, Mac voice recordings, sound downloads, permissions and deletion.
- All four English/Spanish App Store draft descriptions and both TestFlight descriptions were updated and read back. The official privacy URL was verified in every app-info localization. No App Store version was submitted.

## App validation

- iOS Simulator and macOS builds passed.
- All 209 macOS test definitions passed. The signed test products were copied to an isolated temporary directory to avoid a local launch stall in the workspace build directory; the test configuration and production entitlements were unchanged.
- The current Debug extraction contains 982 localization keys, with zero missing Spanish translations and zero placeholder mismatches. Old extraction output from previous archives is excluded when rebuilding the catalog.

Distribution follows the existing request: iOS Internal and Public Beta; native macOS Internal only.
