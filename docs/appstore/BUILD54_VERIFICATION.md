# Build 54 verification and TestFlight delivery

Version **0.1.0 (54)** adds consistent model cards, local speed measurements,
stronger Qwen take verification and retries, and LinnetTTS with two authorised
English voices. Licences and English/Spanish listings have been updated.

- iOS: **VALID**, Internal and Public Beta; external state **IN_BETA_TESTING**, beta review **APPROVED**. Build ID `4b1e9811-d6b8-476d-bd1b-6d9077d8d403`.
- macOS: **VALID**, **Internal only**, internally **IN_BETA_TESTING**. Build ID `77c10c93-7f3a-48c2-9def-2302a749e614`. No external group assignment or beta-review submission by this delivery.
- Both verified exports have valid signatures, arm64 architecture, Production iCloud and the expected team. The iOS extension is build 54; the Mac app is sandboxed and the installer signature is valid. Linnet's full publisher notice and code/asset licences are bundled. The signed Mac archive app stayed alive for a ten-second startup smoke check with sync disabled. Both Apple upload records reached COMPLETE without errors or warnings.
- All four English/Spanish What to Test notes were saved and read back. Four draft store descriptions and two TestFlight descriptions were also verified; see [copy verification](BUILD54_COPY_VERIFICATION.json).
- The public iOS link remains enabled. iOS builds on Apple silicon Macs remain disabled for both groups. No App Store production submission was made.

Pre-archive source validation: 224 macOS tests, 225 iOS Simulator tests, the model
catalogue UI test and a final seven-test focused suite passed. Real Qwen synthesis
and word verification passed on Mac. Four short physical iPhone Linnet samples
produced 19.36 seconds of audio in 2.206 seconds; independent local transcription
recovered the requested words. No sustained performance or naturalness benchmark
is claimed. No phone run exceeded five minutes.

Qwen remains experimental. The user's original intermittent phone failure and
locked-screen playback with the new wrapper still require end-to-end confirmation.
Preparing audio ahead is recommended where generation cannot keep up.

Verified on 2026-11-04T19:25:58.799204+01:00. Exact exported hashes, group memberships and API state:
[BUILD54_DELIVERY.json](BUILD54_DELIVERY.json). Source snapshot and a source archive
are preserved locally in `build/`; this delivery was built from the authorised
working tree rather than a new Git commit.
