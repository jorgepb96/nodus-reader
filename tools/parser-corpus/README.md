# Parser corpus

The parser tests can run against real PDFs when `NODUS_PARSER_CORPUS` points at
a directory with the downloaded files:

```bash
./tools/parser-corpus/fetch.sh
TEST_RUNNER_NODUS_PARSER_CORPUS="$PWD/tools/parser-corpus/pdfs" \
  xcodebuild test -project NodusReader.xcodeproj -scheme NodusReader \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:NodusReaderTests
```

The PDFs stay out of the repository (`.gitignore` covers `pdfs/`). The
self-contained tests in `NodusReaderTests/DocumentParserTests.swift` generate
their own PDF and always run.
