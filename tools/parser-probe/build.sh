#!/bin/zsh
# Build the standalone parser probe. It compiles only the document-parsing
# sources, not the app or any audio/player code.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
OUT="$ROOT/tools/parser-probe/.build"
mkdir -p "$OUT"

swiftc -O -swift-version 5 -o "$OUT/probe" \
    "$ROOT/NodusReader/Core/Services/TextNormalizer.swift" \
    "$ROOT/NodusReader/Core/Services/PDFPageText.swift" \
    "$ROOT/NodusReader/Core/Services/HTMLText.swift" \
    "$ROOT/NodusReader/Core/Services/DocumentExtraction.swift" \
    "$ROOT/NodusReader/Core/Services/DocumentExtractor.swift" \
    "$ROOT/NodusReader/Core/Services/LanguageDetector.swift" \
    "$ROOT/NodusReader/Core/Services/ImportError.swift" \
    "$ROOT/NodusReader/Features/Reader/PDF/PDFReflowEngine.swift" \
    "$ROOT/tools/parser-probe/Stubs.swift" \
    "$ROOT/tools/parser-probe/main.swift"

echo "$OUT/probe"
