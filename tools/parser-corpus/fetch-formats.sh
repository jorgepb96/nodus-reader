#!/bin/zsh
# Public TXT/HTML samples for the format pass. Generated fixtures stay in the
# test suite; these downloads exercise real publisher and web markup.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
OUT="$ROOT/tools/parser-corpus/formats"
mkdir -p "$OUT"

fetch() {
    local name="$1"
    local url="$2"
    if [[ -s "$OUT/$name" ]]; then
        echo "have $name"
        return
    fi
    echo "fetch $name"
    curl -L --fail --retry 2 --max-time 120 -sS -A 'Nodus parser corpus' \
        -o "$OUT/$name" "$url"
}

fetch gutenberg-pride.txt "https://www.gutenberg.org/cache/epub/1342/pg1342.txt"
fetch rfc9110.txt "https://www.rfc-editor.org/rfc/rfc9110.txt"
fetch wikipedia-gatsby.html "https://en.wikipedia.org/api/rest_v1/page/html/The_Great_Gatsby"

echo "format corpus: $OUT"
