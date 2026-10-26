#!/bin/zsh
# Download the EPUB corpus used by the parser test. The files are not
# committed; point TEST_RUNNER_NODUS_EPUB_CORPUS at this directory.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
OUT="$ROOT/tools/parser-corpus/epubs"
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

# Project Gutenberg: prose, drama, poetry and illustrated books.
fetch gutenberg-pride-and-prejudice.epub "https://www.gutenberg.org/cache/epub/1342/pg1342.epub"
fetch gutenberg-quijote-es.epub "https://www.gutenberg.org/cache/epub/2000/pg2000.epub"
fetch gutenberg-shakespeare.epub "https://www.gutenberg.org/cache/epub/100/pg100.epub"
fetch gutenberg-divine-comedy.epub "https://www.gutenberg.org/cache/epub/8800/pg8800.epub"
fetch gutenberg-alice.epub "https://www.gutenberg.org/cache/epub/11/pg11.epub"
fetch gutenberg-beowulf.epub "https://www.gutenberg.org/cache/epub/16328/pg16328.epub"
fetch gutenberg-moby-dick.epub "https://www.gutenberg.org/cache/epub/2701/pg2701.epub"

# Biblioteca Virtual Miguel de Cervantes. The direct download is behind a
# Cloudflare challenge for command-line clients, so use the archived copy of
# the exact EPUB download. lluisvives.com is the same catalogue.
fetch_wayback() {
    local name="$1"
    local original="$2"
    if [[ -s "$OUT/$name" ]]; then
        echo "have $name"
        return
    fi
    local available timestamp
    available=$(curl -L --max-time 40 -sS "https://archive.org/wayback/available?url=$original")
    timestamp=$(printf '%s' "$available" | python3 -c \
        'import json,sys; d=json.load(sys.stdin); s=d.get("archived_snapshots",{}).get("closest"); print(s["timestamp"] if s else "")')
    if [[ -z "$timestamp" ]]; then
        echo "skip $name: no archived EPUB copy" >&2
        return
    fi
    echo "fetch $name (Wayback $timestamp)"
    curl -L --fail --retry 2 --max-time 120 -sS -o "$OUT/$name" \
        "https://web.archive.org/web/${timestamp}id_/https://$original"
}

fetch_wayback cervantes-quijote.epub \
    "www.cervantesvirtual.com/descargaepub/el-ingenioso-hidalgo-don-quijote-de-la-mancha-2012/"

echo "EPUB corpus: $OUT"
