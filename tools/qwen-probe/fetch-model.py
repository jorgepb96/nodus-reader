#!/usr/bin/env python3
"""Fetch the app's pinned Qwen files for local inference validation."""
import concurrent.futures
import argparse
import hashlib
import json
from pathlib import Path
import urllib.request

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("destination", type=Path)
parser.add_argument("--manifest", type=Path, default=Path(__file__).resolve().parents[2] /
                    "NodusReader/Resources/QwenModelManifest.json")
args = parser.parse_args()
manifest = json.loads(args.manifest.read_text())
root = args.destination
base = f"https://huggingface.co/{manifest['repository']}/resolve/{manifest['revision']}/"


def matches(path, item):
    if not path.is_file() or path.stat().st_size != item["bytes"]:
        return False
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest() == item["sha256"]


def fetch(item):
    dest = root / item["path"]
    if matches(dest, item):
        return
    dest.parent.mkdir(parents=True, exist_ok=True)
    temp = dest.with_name(dest.name + ".partial")
    with urllib.request.urlopen(base + item["path"], timeout=120) as response, temp.open("wb") as out:
        while chunk := response.read(8 << 20):
            out.write(chunk)
    if not matches(temp, item):
        raise RuntimeError(f"Integrity check failed: {item['path']}")
    temp.replace(dest)


with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
    for index, _ in enumerate(pool.map(fetch, manifest["files"]), 1):
        if index % 20 == 0 or index == len(manifest["files"]):
            print(f"Verified {index}/{len(manifest['files'])} files", flush=True)
