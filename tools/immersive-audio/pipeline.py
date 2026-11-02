#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
"""Immersive Audio catalog pipeline: fetch, process, verify, manifest.

Run from the repository root, isolated (python3 -I), stdlib only:

  python3 -I tools/immersive-audio/pipeline.py fetch            # direct downloads + licence evidence
  python3 -I tools/immersive-audio/pipeline.py import ID FILE   # an original downloaded by hand (Freesound)
  python3 -I tools/immersive-audio/pipeline.py import-downloads # every listed original found in ~/Downloads
  python3 -I tools/immersive-audio/pipeline.py process [ID…]    # inspect, edit, level, loop, encode
  python3 -I tools/immersive-audio/pipeline.py verify           # every check on every output
  python3 -I tools/immersive-audio/pipeline.py manifest         # catalog.json + PROVENANCE.md

Downloads land in build/immersive-audio/ (git-ignored). Nothing here alters
audio for any reason other than a measured sonic one; every change is
recorded in the manifest's `transformations`.
"""
import csv
import datetime
import hashlib
import html
import json
import os
import re
import shutil
import subprocess
import sys
import urllib.parse
import urllib.request

ROOT = os.getcwd()
TOOLS = os.path.join(ROOT, "tools", "immersive-audio")
BUILD = os.path.join(ROOT, "build", "immersive-audio")
ORIGINALS = os.path.join(BUILD, "originals")
EVIDENCE = os.path.join(BUILD, "evidence")
STAGE = os.path.join(BUILD, "stage")
PACKS = os.path.join(BUILD, "packs")
PRINTS = os.path.join(BUILD, "fingerprints")
SOURCES = os.path.join(TOOLS, "sources.json")
STATE = os.path.join(BUILD, "state.json")
AUDIOTOOL = os.path.join(BUILD, "audiotool")
def _find_drift():
    """Nodus Drift's checkout (for the exclusion register): NODUS_DRIFT_REPO,
    or a `nodus-drift-mobile` folder beside one of this checkout's parents."""
    if os.environ.get("NODUS_DRIFT_REPO"):
        return os.environ["NODUS_DRIFT_REPO"]
    folder = ROOT
    while folder != os.path.dirname(folder):
        candidate = os.path.join(os.path.dirname(folder), "nodus-drift-mobile")
        if os.path.isdir(candidate):
            return candidate
        folder = os.path.dirname(folder)
    return ""


DRIFT = _find_drift()
APP_CATALOG = os.path.join(ROOT, "NodusReader", "Resources", "ImmersiveAudio", "catalog.json")
PROVENANCE = os.path.join(ROOT, "docs", "immersive-audio", "PROVENANCE.md")

CC0_URL = "https://creativecommons.org/publicdomain/zero/1.0/legalcode"
# Licences accepted for the catalog: public domain dedication, or attribution
# only (credited in the app and in PROVENANCE.md). No ShareAlike, no NC/ND.
LICENSES = {
    "CC0-1.0": {"url": CC0_URL, "oga": "CC0", "deed": "publicdomain/zero/1.0"},
    "CC-BY-3.0": {"url": "https://creativecommons.org/licenses/by/3.0/legalcode", "oga": "CC-BY 3.0", "deed": "licenses/by/3.0"},
    "CC-BY-4.0": {"url": "https://creativecommons.org/licenses/by/4.0/legalcode", "oga": "CC-BY 4.0", "deed": "licenses/by/4.0"},
}


def license_of(candidate):
    return candidate.get("license", "CC0-1.0")
TARGETS = {"music": {"I": -20.0, "TP": -1.5}, "ambience": {"I": -28.0, "TP": -3.0}}
BITRATE = {"music": (160, 196), "ambience": (96, 132)}
HOSTS = [
    {"name": "huggingface", "baseURL": "https://huggingface.co/datasets/jorgepb96/nodus-reader-immersive-audio/resolve/<commit>/"},
    {"name": "github", "baseURL": "https://github.com/jorgepb96/nodus-reader/releases/download/immersive-audio-v1/"},
]
USER_AGENT = "NodusReader-catalog-pipeline/1 (+https://github.com/jorgepb96/nodus-reader)"


def today():
    return datetime.date.today().isoformat()


def sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def run(args, check=True):
    result = subprocess.run(args, capture_output=True, text=True)
    if check and result.returncode != 0:
        raise SystemExit(f"command failed: {' '.join(args)}\n{result.stderr[-2000:]}")
    return result


def load(path, default):
    if not os.path.exists(path):
        return default
    with open(path) as handle:
        return json.load(handle)


def save(path, value):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as handle:
        json.dump(value, handle, indent=2, ensure_ascii=False, sort_keys=False)
        handle.write("\n")


def sources():
    return load(SOURCES, {"candidates": []})["candidates"]


def included():
    return [c for c in sources() if c.get("status") == "include"]


def tool_versions():
    ffmpeg = run(["ffmpeg", "-hide_banner", "-version"]).stdout.split("\n")[0].split(" ")[2]
    macos = run(["sw_vers", "-productVersion"]).stdout.strip()
    return {"ffmpeg": ffmpeg, "afconvert": f"macOS {macos}", "audiotool": "tools/immersive-audio/audiotool.swift"}


# MARK: Drift exclusion

def drift_register():
    """Sources and hashes used by Nodus Drift: none may appear here."""
    ids, hashes, pages = set(), set(), set()
    base = os.path.join(DRIFT, "docs", "rights", "replacement-audio")
    data = load(os.path.join(base, "sources.json"), {})
    for key, value in data.items():
        ids.add(key)
        pages.add((value.get("page_url") or "").rstrip("/"))
        hashes.add(value.get("source_sha256"))
        match = re.search(r"freesound\.org/people/[^/]+/sounds/(\d+)", value.get("page_url") or "")
        if match:
            ids.add("freesound:" + match.group(1))
    path = os.path.join(base, "loop-register.csv")
    if os.path.exists(path):
        with open(path) as handle:
            for row in csv.DictReader(handle):
                hashes.update([row.get("source_sha256"), row.get("loop_sha256")])
                pages.add((row.get("source_url") or "").rstrip("/"))
                match = re.search(r"sounds/(\d+)", row.get("source_url") or "")
                if match:
                    ids.add("freesound:" + match.group(1))
    hashes.discard(None)
    hashes.discard("")
    pages.discard("")
    return {"ids": ids, "hashes": hashes, "pages": pages, "found": bool(data)}


def drift_conflict(candidate, original_hash=None):
    drift = drift_register()
    page = candidate["pageURL"].rstrip("/")
    match = re.search(r"freesound\.org/people/[^/]+/sounds/(\d+)", page)
    if page in drift["pages"]:
        return "same source page as Nodus Drift"
    if match and "freesound:" + match.group(1) in drift["ids"]:
        return "same Freesound sound as Nodus Drift"
    if original_hash and original_hash in drift["hashes"]:
        return "same file (SHA-256) as Nodus Drift"
    if "bigsoundbank.com" in page:
        return "BigSoundBank is Nodus Drift's main source library: not used"
    return None


# MARK: fetch

def fetch_url(url, destination):
    url = urllib.parse.quote(url, safe=":/?=&%#~+")
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(request, timeout=120) as response, open(destination + ".part", "wb") as out:
        shutil.copyfileobj(response, out)
    os.replace(destination + ".part", destination)


def cmd_fetch(ids):
    state = load(STATE, {})
    for candidate in included():
        cid = candidate["id"]
        if ids and cid not in ids:
            continue
        conflict = drift_conflict(candidate)
        if conflict:
            raise SystemExit(f"{cid}: {conflict}")
        entry = state.setdefault(cid, {})
        # Licence evidence: the page as served today, its hash, and the
        # licence statement found in it. The page itself stays local.
        os.makedirs(EVIDENCE, exist_ok=True)
        page_path = os.path.join(EVIDENCE, cid + ".html")
        evidence_url = candidate.get("evidenceURL") or candidate["pageURL"]
        if not os.path.exists(page_path):
            fetch_url(evidence_url, page_path)
        with open(page_path, encoding="utf-8", errors="replace") as handle:
            page = handle.read()
        quote = candidate["licenseQuote"]
        plain = re.sub(r"\s+", " ", html.unescape(re.sub(r"<[^>]+>", " ", page)).replace("\xa0", " "))
        plain = re.sub(r"\s+([:;,.])", r"\1", plain)
        if quote not in plain:
            raise SystemExit(f"{cid}: licence statement {quote!r} not found on {evidence_url}")
        # The licence used must be one the page offers. A page offering
        # several lets the user choose; the most permissive one is used.
        if candidate["provider"] == "OpenGameArt":
            names = re.findall(r"class='license-name'>([^<]+)<", page)
            wanted = LICENSES[license_of(candidate)]["oga"]
            if wanted not in names:
                raise SystemExit(f"{cid}: OpenGameArt lists licences {names}, not {wanted}")
            if "CC0" in names and wanted != "CC0":
                raise SystemExit(f"{cid}: CC0 is offered; use it instead of {wanted}")
            quote = "License(s): " + ", ".join(names)
        if candidate["provider"] == "Freesound" and "publicdomain/zero/1.0" not in page:
            raise SystemExit(f"{cid}: Freesound page does not link the CC0 deed")
        entry["evidence"] = {"url": evidence_url, "sha256": sha256(page_path), "quote": quote, "checkedOn": today(),
                             "license": license_of(candidate)}
        if candidate["provider"] == "Free Music Archive" and "publicdomain/zero/1.0" not in page:
            raise SystemExit(f"{cid}: FMA page does not link the CC0 deed")
        if candidate["provider"] in ("Freesound", "Free Music Archive"):
            if not entry.get("original"):
                print(f"{cid}: download the original by hand from {candidate['pageURL']} and run: import {cid} FILE")
            continue
        folder = os.path.join(ORIGINALS, cid)
        os.makedirs(folder, exist_ok=True)
        name = os.path.basename(urllib.request.url2pathname(candidate["fileURL"].split("?")[0])) or "original"
        path = os.path.join(folder, name)
        if not os.path.exists(path):
            print(f"fetch {cid}")
            fetch_url(candidate["fileURL"], path)
        record_original(entry, path, candidate)
    save(STATE, state)


def record_original(entry, path, candidate):
    digest = sha256(path)
    conflict = drift_conflict(candidate, digest)
    if conflict:
        raise SystemExit(f"{candidate['id']}: {conflict}")
    probe = json.loads(run(["ffprobe", "-v", "error", "-show_streams", "-show_format", "-of", "json", path]).stdout)
    stream = next(s for s in probe["streams"] if s["codec_type"] == "audio")
    entry["original"] = {
        "path": os.path.relpath(path, ROOT), "sha256": digest, "bytes": os.path.getsize(path),
        "retrievedOn": entry.get("original", {}).get("retrievedOn") or today(),
        "format": {"codec": stream["codec_name"], "sampleRate": int(stream["sample_rate"]),
                   "channels": int(stream["channels"]),
                   "bitRate": int(stream.get("bit_rate") or probe["format"].get("bit_rate") or 0) or None},
        "duration": float(probe["format"]["duration"]),
    }


def cmd_import(cid, file):
    candidate = next((c for c in included() if c["id"] == cid), None)
    if not candidate:
        raise SystemExit(f"unknown or excluded candidate {cid}")
    folder = os.path.join(ORIGINALS, cid)
    os.makedirs(folder, exist_ok=True)
    path = os.path.join(folder, os.path.basename(file))
    shutil.copy2(file, path)
    state = load(STATE, {})
    record_original(state.setdefault(cid, {}), path, candidate)
    save(STATE, state)
    print(f"imported {cid}: {state[cid]['original']['sha256']}")


def cmd_import_downloads(folder):
    """Finds hand-downloaded originals in `folder` (default ~/Downloads):
    Freesound files by their leading sound ID ("525046__user__name.wav"),
    Free Music Archive MP3s by title, and imports each one once."""
    folder = os.path.expanduser(folder or "~/Downloads")
    state = load(STATE, {})
    names = sorted(os.listdir(folder))
    found = 0
    for candidate in included():
        cid = candidate["id"]
        if candidate["provider"] not in ("Freesound", "Free Music Archive") or state.get(cid, {}).get("original"):
            continue
        match = None
        if candidate["provider"] == "Freesound":
            match = next((n for n in names if n.startswith(candidate["freesoundID"] + "__")), None)
        else:
            simple = re.sub(r"[^a-z0-9]", "", candidate["title"].lower())
            match = next((n for n in names if n.lower().endswith(".mp3") and simple in re.sub(r"[^a-z0-9]", "", n.lower())), None)
        if match:
            cmd_import(cid, os.path.join(folder, match))
            found += 1
        else:
            print(f"not found in {folder}: {cid} ({candidate['title']})")
    print(f"imported {found}")


# MARK: process

def ebur128(path):
    """Integrated loudness, loudness range and true peak (ffmpeg ebur128)."""
    out = run(["ffmpeg", "-hide_banner", "-nostats", "-i", path, "-filter_complex", "ebur128=peak=true",
               "-f", "null", "-"]).stderr
    summary = out[out.rfind("Summary:"):]
    integrated = float(re.search(r"I:\s+(-?[\d.]+|-inf) LUFS", summary).group(1).replace("-inf", "-70"))
    lra = float(re.search(r"LRA:\s+([\d.]+) LU", summary).group(1))
    peak = float(re.search(r"Peak:\s+(-?[\d.]+|-inf) dBFS", summary).group(1).replace("-inf", "-120"))
    return {"I": integrated, "LRA": lra, "TP": peak}


def analyze(path):
    return json.loads(run([AUDIOTOOL, "analyze", path]).stdout)


def bitrate_kbps(path):
    probe = json.loads(run(["ffprobe", "-v", "error", "-show_streams", "-show_format", "-of", "json", path]).stdout)
    stream = next(s for s in probe["streams"] if s["codec_type"] == "audio")
    rate = stream.get("bit_rate") or probe["format"].get("bit_rate")
    return round(int(rate) / 1000)


def encode(wav, out, layer, rate):
    """AAC-LC VBR with Apple's encoder. The quality is searched so the
    average bitrate lands in the layer's range; material too sparse to
    reach it keeps the highest quality tried (fewer bits, not less quality)."""
    low, high = BITRATE[layer]
    tried = {}

    def attempt(quality):
        # The rate is pinned: at low bitrates afconvert would otherwise pick a
        # lower sample rate on its own.
        run(["afconvert", "-f", "m4af", "-d", f"aac@{rate}", "-s", "3", "-u", "vbrq", str(quality), wav, out])
        tried[quality] = bitrate_kbps(out)
        return tried[quality]

    lo, hi = 40, 127
    quality = 96 if layer == "music" else 64
    while lo <= hi:
        kbps = attempt(quality)
        if low <= kbps <= high:
            return quality, kbps
        if kbps < low:
            lo = quality + 1
        else:
            hi = quality - 1
        quality = (lo + hi) // 2
    # VBR quality moves in steps: none may land in the range. Prefer the
    # lightest setting at or above the range's floor (up to +64 kb/s, the
    # "complex music" allowance), never one below it when a richer one exists.
    above = [q for q, k in tried.items() if low <= k <= high + 64]
    if above:
        best = min(above, key=lambda q: tried[q])
    else:
        best = max(tried)
    return best, attempt(best)


def cmd_process(ids, only_new=False):
    state = load(STATE, {})
    for candidate in included():
        if ids and candidate["id"] not in ids:
            continue
        if only_new and state.get(candidate["id"], {}).get("output"):
            continue
        try:
            process_one(candidate, state)
        except SystemExit as failure:
            entry = state.setdefault(candidate["id"], {})
            entry["problems"] = [str(failure)[:300]]
            print(f"REJECT {candidate['id']}: processing failed: {str(failure)[:160]}")
        save(STATE, state)


def process_one(candidate, state):
    versions = tool_versions()
    cid = candidate["id"]
    entry = state.get(cid, {})
    if not entry.get("original"):
        print(f"skip {cid}: no original yet")
        return
    layer = candidate["layer"]
    stage = os.path.join(STAGE, cid)
    shutil.rmtree(stage, ignore_errors=True)
    os.makedirs(stage)
    original = os.path.join(ROOT, entry["original"]["path"])
    fmt = entry["original"]["format"]
    transformations = []
    problems = []
    # Rejections that no processing can fix.
    if fmt["sampleRate"] < 44_100:
        problems.append(f"source sample rate {fmt['sampleRate']} Hz is below 44.1 kHz")
    lossy = fmt["codec"] in ("mp3", "vorbis", "aac", "opus")
    # MP3 below 192 kb/s is audibly compromised; Vorbis/Opus from about
    # 150 kb/s (q5) is comparable.
    floor = 150_000 if fmt["codec"] in ("vorbis", "opus") else 192_000
    if layer == "music" and lossy and (fmt["bitRate"] or 0) < floor and not candidate.get("lossyAccepted"):
        problems.append(f"lossy music source at {round((fmt['bitRate'] or 0) / 1000)} kbps (< {floor // 1000})")
    # 1. Decode (and only reduce: never upsample).
    rate = fmt["sampleRate"] if fmt["sampleRate"] in (44_100, 48_000) else 48_000
    decoded = os.path.join(stage, "decoded.wav")
    resample = [] if rate == fmt["sampleRate"] else ["-af", "aresample=resampler=swr:filter_size=64:phase_shift=10:cutoff=0.97"]
    run(["ffmpeg", "-y", "-v", "error", "-i", original, *resample, "-ar", str(rate), "-c:a", "pcm_f32le", decoded])
    transformations.append(f"decoded from {fmt['codec']} {fmt['sampleRate']} Hz"
                           + ("" if rate == fmt["sampleRate"] else f", resampled to {rate} Hz (high-quality swr)"))
    inspection = analyze(decoded)
    entry["inspection"] = inspection
    if inspection["clippedRuns"] > 50:
        problems.append(f"{inspection['clippedRuns']} clipped runs in the source")
    if layer == "music" and inspection["seconds"] < 60 and not candidate.get("shortAccepted"):
        problems.append(f"only {inspection['seconds']:.0f} s long: would repeat audibly during reading")
    cliff = inspection.get("brickwallHz", 0)
    if 0 < cliff < 15_500 and not candidate.get("bandwidthAccepted"):
        problems.append(f"brickwall cut at {cliff:.0f} Hz ({inspection['brickwallDropDB']:.0f} dB): a lossy or upsampled master")
    if problems and not candidate.get("problemsAccepted"):
        entry["problems"] = problems
        print(f"REJECT {cid}: " + "; ".join(problems))
        state[cid] = entry
        return
    # 2. Edits with a measured reason only.
    filters = []
    if max(abs(x) for x in inspection["dcOffset"]) > 0.002:
        filters.append("highpass=f=20")
        transformations.append("20 Hz high-pass (DC offset measured)")
    # Silence is trimmed from music only: a bed is a continuous recording
    # (a quiet forest can sit below any fixed threshold).
    if layer == "music":
        filters.append("silenceremove=start_periods=1:start_threshold=-70dB:start_silence=0.05")
        filters.append("areverse,silenceremove=start_periods=1:start_threshold=-70dB:start_silence=0.6,areverse")
    else:
        filters.append("anull")
    if inspection["channels"] == 1:
        filters.append("pan=stereo|c0=c0|c1=c0")
        transformations.append("mono source duplicated to both channels (no widening)")
    trim = candidate.get("trim")
    if trim:
        filters.insert(0, f"atrim=start={trim[0]}:end={trim[1]},asetpts=PTS-STARTPTS")
        transformations.append(f"excerpt {trim[0]}–{trim[1]} s ({candidate.get('trimReason', 'see sources.json')})")
    edited = os.path.join(stage, "edited.wav")
    run(["ffmpeg", "-y", "-v", "error", "-i", decoded, "-af", ",".join(filters), "-c:a", "pcm_f32le", edited])
    before = float(json.loads(run(["ffprobe", "-v", "error", "-show_format", "-of", "json", decoded]).stdout)["format"]["duration"])
    after = float(json.loads(run(["ffprobe", "-v", "error", "-show_format", "-of", "json", edited]).stdout)["format"]["duration"])
    if not trim and before - after > 0.05:
        transformations.append(f"leading/trailing silence trimmed ({before - after:.2f} s)")
    # 3. Seamless loop for ambience.
    source_for_level = edited
    if layer == "ambience":
        loop = candidate.get("loop") or {}
        seam = loop.get("seam", 3.0)
        length = min(loop.get("length", 180.0), after - seam - loop.get("start", seam) - 0.5)
        start = loop.get("start", seam)
        if length < 60:
            print(f"REJECT {cid}: too short for a loop ({after:.1f} s)")
            entry["problems"] = ["too short for a seamless loop"]
            state[cid] = entry
            return
        looped = os.path.join(stage, "loop.wav")
        run([AUDIOTOOL, "loop", edited, looped, f"{start}", f"{length}", f"{seam}"])
        transformations.append(f"seamless loop of {length:.1f} s from {start:.1f} s, {seam:.1f} s equal-power seam")
        source_for_level = looped
    # 4. Level: one fixed gain (dynamics untouched), never above the true-peak target.
    measured = ebur128(source_for_level)
    target = TARGETS[layer]
    gain = min(target["I"] - measured["I"], target["TP"] - measured["TP"])
    leveled = os.path.join(stage, "leveled.wav")
    run(["ffmpeg", "-y", "-v", "error", "-i", source_for_level, "-af", f"volume={gain:.2f}dB",
         "-c:a", "pcm_f32le", leveled])
    transformations.append(f"gain {gain:+.2f} dB (measured {measured['I']:.1f} LUFS, {measured['TP']:.1f} dBTP; no compression)")
    # 5. Encode.
    folder = os.path.join(PACKS, candidate["packPath"])
    os.makedirs(folder, exist_ok=True)
    out = os.path.join(folder, cid + ".m4a")
    quality, kbps = encode(leveled, out, layer, rate)
    transformations.append(f"AAC-LC VBR (Apple encoder, quality {quality}, {kbps} kb/s), {rate} Hz stereo")
    # The encoded file is decoded again for every measurement.
    final = ebur128(out)
    frames = int(run([AUDIOTOOL, "frames", out]).stdout.strip())
    pcm_frames = int(run([AUDIOTOOL, "frames", leveled]).stdout.strip())
    entry["output"] = {
        "path": os.path.relpath(out, PACKS), "sha256": sha256(out), "bytes": os.path.getsize(out), "quality": quality,
        "sampleRate": rate, "channels": 2, "bitRateKbps": kbps, "frames": frames, "pcmFrames": pcm_frames,
        "loudness": final, "inspection": analyze(out),
        "seam": json.loads(run([AUDIOTOOL, "seam", out]).stdout) if layer == "ambience" else None,
    }
    entry["transformations"] = transformations
    entry["tools"] = versions
    entry.pop("problems", None)
    state[cid] = entry
    save(STATE, state)
    print(f"ok {cid}: {kbps} kb/s, {final['I']:.1f} LUFS, {final['TP']:.1f} dBTP, {os.path.getsize(out) / 1e6:.1f} MB")


# MARK: verify

def cmd_verify():
    state = load(STATE, {})
    failures = []
    os.makedirs(PRINTS, exist_ok=True)
    outputs = []
    for candidate in included():
        cid = candidate["id"]
        entry = state.get(cid, {})
        out = entry.get("output")
        if not out:
            if not entry.get("original"):
                print(f"PENDING {cid}: original not downloaded yet")
            else:
                failures.append(f"{cid}: not processed ({'; '.join(entry.get('problems', []))})")
            continue
        path = os.path.join(PACKS, out["path"])
        layer = candidate["layer"]
        if sha256(path) != out["sha256"]:
            failures.append(f"{cid}: output hash changed")
        errors = run(["ffmpeg", "-v", "error", "-i", path, "-f", "null", "-"], check=False).stderr.strip()
        if errors:
            failures.append(f"{cid}: decoding errors: {errors[:200]}")
        loud = ebur128(path)
        target = TARGETS[layer]
        if loud["TP"] > -1.0:
            failures.append(f"{cid}: true peak {loud['TP']:.2f} dBTP above -1")
        if loud["I"] > target["I"] + 1.0:
            failures.append(f"{cid}: loudness {loud['I']:.1f} LUFS above target")
        if loud["I"] < target["I"] - 1.0 and "TP" not in candidate.get("quietReason", "TP"):
            pass  # quieter than target only when the true-peak limit required it (recorded gain)
        if abs(out["frames"] - out["pcmFrames"]) > 1:
            failures.append(f"{cid}: decoded length {out['frames']} != {out['pcmFrames']} frames (priming not trimmed)")
        if out["inspection"]["clippedRuns"] > 0:
            failures.append(f"{cid}: clipping after encoding")
        low, high = BITRATE[layer]
        # Sparse material may stay below the range even at the highest VBR
        # quality (127): that is the encoder needing fewer bits, not a loss.
        too_low = out["bitRateKbps"] < low - 8 and out.get("quality", 0) < 127
        if too_low or out["bitRateKbps"] > high + 64:
            failures.append(f"{cid}: bitrate {out['bitRateKbps']} kb/s out of range")
        if layer == "ambience":
            seam = out.get("seam") or {}
            if seam.get("stepRatio", 99) > 3 or seam.get("fluxRatio", 99) > 3:
                failures.append(f"{cid}: loop seam not smooth ({seam})")
        if drift_conflict(candidate, entry["original"]["sha256"]):
            failures.append(f"{cid}: overlaps Nodus Drift")
        printed = os.path.join(PRINTS, cid + ".json")
        run([AUDIOTOOL, "fingerprint", path, printed])
        outputs.append((cid, printed, entry["original"]["sha256"], out["sha256"]))
    # Exact and perceptual duplicates across the catalog.
    for i, (a, pa, oa, ha) in enumerate(outputs):
        for b, pb, ob, hb in outputs[i + 1:]:
            if oa == ob or ha == hb:
                failures.append(f"{a} and {b} are the same file")
                continue
            result = json.loads(run([AUDIOTOOL, "compare", pa, pb]).stdout)
            if result["sameAudio"]:
                failures.append(f"{a} and {b} sound the same (fingerprint BER {result['ber']:.3f})")
    drift = drift_register()
    print(f"Drift register: {'found' if drift['found'] else 'NOT FOUND'} ({len(drift['ids'])} ids, {len(drift['hashes'])} hashes)")
    print(f"{len(outputs)} files checked")
    for failure in failures:
        print("FAIL", failure)
    if failures:
        raise SystemExit(1)
    print("verify: all checks passed")


# MARK: manifest

def cmd_manifest():
    state = load(STATE, {})
    versions = tool_versions()
    tracks = []
    for candidate in included():
        cid = candidate["id"]
        entry = state.get(cid, {})
        if not entry.get("output"):
            print(f"not in this catalog: {cid} (not processed)")
            continue
        out = entry["output"]
        original = entry["original"]
        semantics = dict(candidate["semantics"])
        duration = out["frames"] / out["sampleRate"]
        tail = None
        if candidate["layer"] == "music":
            tail = round(max(duration - candidate.get("tailSeconds", 8.0), duration * 0.6), 2)
        tracks.append({
            "id": cid, "layer": candidate["layer"], "title": candidate["title"], "author": candidate["author"],
            "authorURL": candidate.get("authorURL"),
            "source": {"provider": candidate["provider"], "pageURL": candidate["pageURL"],
                       "fileURL": candidate["fileURL"], "retrievedOn": original["retrievedOn"],
                       "originalSHA256": original["sha256"], "originalBytes": original["bytes"],
                       "originalFormat": original["format"]},
            "license": {"spdx": license_of(candidate), "url": LICENSES[license_of(candidate)]["url"],
                        "evidence": {"url": entry["evidence"]["url"], "snapshot": f"build/immersive-audio/evidence/{cid}.html",
                                     "snapshotSHA256": entry["evidence"]["sha256"], "quote": entry["evidence"]["quote"]},
                        "verifiedOn": entry["evidence"]["checkedOn"],
                        "verifiedBy": candidate.get("verifiedBy", "automated check (tools/immersive-audio) — maintainer review pending")},
            "processing": {"transformations": entry["transformations"], "tools": entry.get("tools", versions)},
            "file": {"path": out["path"], "githubAssetName": cid + ".m4a", "bytes": out["bytes"], "sha256": out["sha256"],
                     "sampleRate": out["sampleRate"], "channels": out["channels"], "bitRateKbps": out["bitRateKbps"],
                     "frames": out["frames"]},
            "audio": {"integratedLUFS": out["loudness"]["I"], "truePeakDBTP": out["loudness"]["TP"],
                      "lra": out["loudness"]["LRA"], "isLoop": candidate["layer"] == "ambience", "tailStartSeconds": tail},
            "semantics": semantics,
        })
    packs = []
    for pack in ("essentials", "narrative", "ambience"):
        ids = [t["id"] for t in tracks if pack in next(c for c in included() if c["id"] == t["id"])["packs"]]
        if ids:
            packs.append({"id": pack, "trackIDs": ids, "bytes": sum(t["file"]["bytes"] for t in tracks if t["id"] in ids)})
    catalog = {"schemaVersion": 1, "catalogVersion": today().replace("-", "."), "hosts": HOSTS, "packs": packs, "tracks": tracks}
    save(os.path.join(BUILD, "catalog.json"), catalog)
    save(APP_CATALOG, catalog)
    write_provenance(catalog, state)
    total_original = sum(t["source"]["originalBytes"] for t in tracks)
    total = sum(t["file"]["bytes"] for t in tracks)
    print(f"manifest: {len(tracks)} tracks, originals {total_original / 1e6:.1f} MB, catalog {total / 1e6:.1f} MB")


def write_provenance(catalog, state):
    rejected = [c for c in sources() if c.get("status") == "reject"]
    lines = [
        "# Immersive Audio — provenance record",
        "",
        f"Generated by `tools/immersive-audio/pipeline.py manifest` on {today()}. Catalog version "
        f"`{catalog['catalogVersion']}`, {len(catalog['tracks'])} files. Every file is CC0-1.0 (public domain "
        "dedication) or CC-BY (attribution only: the author and source are credited here and in the app, and the "
        "changes made are listed). Licence evidence was read from each source page on the date given; "
        "the page snapshots and their SHA-256 are kept with the build outputs (`build/immersive-audio/evidence/`), "
        "not in the repository.",
        "",
        "Hashes: *original* is the file as downloaded from the source; *processed* is the file the app downloads. "
        "Loudness and true peak are measured on the processed file decoded again (ffmpeg `ebur128`).",
        "",
    ]
    for track in catalog["tracks"]:
        s, f, a = track["source"], track["file"], track["audio"]
        sem = track["semantics"]
        categories = ", ".join(sem.get("moods") or [sem.get("base") or ""])
        lines += [
            f"## {track['title']} — {track['author']}",
            "",
            f"- **ID:** `{track['id']}` ({track['layer']}; {categories}; energy {sem['energy']}; "
            f"study-safe: {'yes' if sem['studySafe'] else 'no'}; packs: "
            f"{', '.join(p['id'] for p in catalog['packs'] if track['id'] in p['trackIDs'])})",
            f"- **Source:** {s['provider']} — <{s['pageURL']}>",
            f"- **File URL:** <{s['fileURL']}> (retrieved {s['retrievedOn']})",
            f"- **Licence:** {track['license']['spdx']} — <{track['license']['url']}>; evidence <{track['license']['evidence']['url']}> "
            f"states “{track['license']['evidence']['quote']}” (checked {track['license']['verifiedOn']}; page SHA-256 "
            f"`{track['license']['evidence']['snapshotSHA256']}`); verified by {track['license']['verifiedBy']}",
            f"- **Original:** {s['originalFormat']['codec']}, {s['originalFormat']['sampleRate']} Hz, "
            f"{s['originalFormat']['channels']} ch, {s['originalBytes']:,} bytes, SHA-256 `{s['originalSHA256']}`",
            f"- **Processed:** `{f['path']}`, AAC-LC {f['bitRateKbps']} kb/s, {f['sampleRate']} Hz, {f['bytes']:,} bytes, "
            f"SHA-256 `{f['sha256']}`; {a['integratedLUFS']:.1f} LUFS, {a['truePeakDBTP']:.1f} dBTP, LRA {a['lra']:.1f} LU"
            + (", seamless loop" if a["isLoop"] else ""),
            "- **Transformations:** " + "; ".join(track["processing"]["transformations"]),
            "",
        ]
    lines += ["## Candidates not included", "", "| Candidate | Source | Reason |", "|---|---|---|"]
    for candidate in rejected:
        lines.append(f"| {candidate['title']} — {candidate['author']} | <{candidate['pageURL']}> | {candidate['rejectReason']} |")
    lines.append("")
    os.makedirs(os.path.dirname(PROVENANCE), exist_ok=True)
    with open(PROVENANCE, "w") as handle:
        handle.write("\n".join(lines))


def main():
    if not os.path.exists(AUDIOTOOL):
        os.makedirs(BUILD, exist_ok=True)
        run(["swiftc", "-O", "-o", AUDIOTOOL, os.path.join(TOOLS, "audiotool.swift")])
    command = sys.argv[1] if len(sys.argv) > 1 else ""
    if command == "fetch":
        cmd_fetch(set(sys.argv[2:]))
    elif command == "import-downloads":
        cmd_import_downloads(sys.argv[2] if len(sys.argv) > 2 else None)
    elif command == "import" and len(sys.argv) == 4:
        cmd_import(sys.argv[2], sys.argv[3])
    elif command == "process":
        args = [a for a in sys.argv[2:] if a != "--new"]
        cmd_process(set(args), only_new="--new" in sys.argv)
    elif command == "verify":
        cmd_verify()
    elif command == "manifest":
        cmd_manifest()
    else:
        print(__doc__)
        sys.exit(2)


if __name__ == "__main__":
    main()
