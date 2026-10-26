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

EPUBs use a separate directory and opt-in variable:

```bash
./tools/parser-corpus/fetch-epubs.sh
TEST_RUNNER_NODUS_EPUB_CORPUS="$PWD/tools/parser-corpus/epubs" \
  xcodebuild test -project NodusReader.xcodeproj -scheme NodusReader \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:NodusReaderTests
```

The EPUB corpus includes Project Gutenberg prose, drama, poetry and illustrated
books, plus *Don Quijote* from Biblioteca Virtual Miguel de Cervantes. The
Cervantes EPUB is fetched from the Wayback Machine because the live download is
behind a Cloudflare challenge; `lluisvives.com` exposes the same catalogue. See
the test log for real-EPUB assertions.

Plain text and HTML use a third directory:

```bash
./tools/parser-corpus/fetch-formats.sh
TEST_RUNNER_NODUS_FORMAT_CORPUS="$PWD/tools/parser-corpus/formats" \
  xcodebuild test -project NodusReader.xcodeproj -scheme NodusReader \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:NodusReaderTests
```

That corpus has Gutenberg's *Pride and Prejudice* as `.txt`, RFC 9110 as `.txt`
and the Wikipedia HTML for *The Great Gatsby*. The generated fixtures in the
test suite cover Windows-1252, UTF-16, Markdown front matter/autolinks/footnotes,
HTML lists and tables, and RTF paragraphs and Unicode; none of them reads a
document from the machine.
