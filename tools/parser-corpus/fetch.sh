#!/bin/zsh
# Download the public PDFs used by the parser corpus test. The files are not
# committed; run this once, then point NODUS_PARSER_CORPUS at the directory.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
OUT="$ROOT/tools/parser-corpus/pdfs"
mkdir -p "$OUT"

fetch() {
    local name="$1"
    local url="$2"
    if [[ -s "$OUT/$name" ]]; then
        echo "have $name"
        return
    fi
    echo "fetch $name"
    curl -L --fail --retry 2 --max-time 120 -sS -o "$OUT/$name" "$url"
}

fetch wikipedia-gatsby.pdf "https://en.wikipedia.org/api/rest_v1/page/pdf/The_Great_Gatsby"
fetch wikipedia-quijote-es.pdf "https://es.wikipedia.org/api/rest_v1/page/pdf/Don_Quijote_de_la_Mancha"
fetch arxiv-bert.pdf "https://arxiv.org/pdf/1810.04805"
fetch arxiv-attention.pdf "https://arxiv.org/pdf/1706.03762"
fetch rfc9110.pdf "https://www.rfc-editor.org/rfc/rfc9110.pdf"

echo "corpus: $OUT"
