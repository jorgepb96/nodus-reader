#!/bin/bash
# Rebuild PhononCore.xcframework with on-device Core ML export (ptts_export_coreml):
# Gradium's xn-ptts v0.4.1 plus 0001-ptts-ffi-export-coreml.patch, built with their own script.
# Needs Rust (rustup) and Xcode. Output: PhononCore.xcframework.zip and its SwiftPM checksum.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="$(mktemp -d)"
git clone --depth 1 --branch v0.4.1 https://github.com/gradium-ai/xn-ptts.git "$WORK/xn-ptts"
cd "$WORK/xn-ptts"
git apply "$HERE/0001-ptts-ffi-export-coreml.patch"
./ios/build-xcframework.sh
cp ios/PhononTTS/PhononCore.xcframework.zip "$HERE/"
echo "checksum: $(swift package compute-checksum "$HERE/PhononCore.xcframework.zip")"
