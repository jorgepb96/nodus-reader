# Parser probe

A small macOS command-line tool for inspecting the document parser without
building or launching the app. It compiles only the parsing sources, so changes
to this tool cannot affect playback, narration or the UI.

```bash
./tools/parser-probe/build.sh
.build/probe pdf path/to/book.pdf --reflow --markdown out.md
.build/probe md path/to/notes.md
```

`--reflow` prints the Intelligent Reading blocks (kind, flags, geometry and
text) and can write the canonical Markdown. Without it, the import extractor
is used, which is useful for TXT, Markdown, HTML and RTF.

The real-world corpus is downloaded by `tools/parser-corpus/fetch.sh` and is
not committed.
