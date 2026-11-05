# Native Simulator screenshots

Run from the repository root, after resolving the project's pinned packages. The capture helper drives the opt-in UI tests and saves the selected Simulator framebuffer without resizing, retouching or hiding errors. Each checkpoint is acknowledged through the UI runner's Documents directory. `manifest.json` records the native pixel dimensions; `test.log` retains assertions and results.

```sh
python3 tools/appstore/capture-native-display.py UDID en primary build/screenshots-en testAppStoreScreenshots testDuoWelcomeScreenshots
```

Use `es` for Spanish. `NODUS_CAPTURE_DERIVED_DATA` and `NODUS_CAPTURE_PACKAGES` override the local build/package directories. Set `NODUS_CAPTURE_WITHOUT_BUILD=1` only after building the current source for testing in that same directory.

`NODUS_CAPTURE_XCTESTRUN` can point to the generated `.xctestrun` file when running without building. This avoids resolving packages again. Every run writes its own result bundle and `run.json`; verbose automatic sysdiagnoses are disabled, while assertions, failure screenshots and normal test results are retained.

For iPhone Duo, select **Open** or **Closed** in Apple's Device Hub before starting the tour. Capture `primary-1` when open and `primary` when closed. `XCUIScreen.main.screenshot()` can capture the inactive exterior display even while UI automation runs inside; do not publish those black attachments. Do not change display power to emulate folding: it previously caused a Simulator SpringBoard restart loop.

Run one Simulator tour at a time and build the Mac target separately to avoid exhausting the host. Only synthetic/public-domain sample books are used. A passing Simulator tour does not replace physical-device playback, offline or interruption tests.
