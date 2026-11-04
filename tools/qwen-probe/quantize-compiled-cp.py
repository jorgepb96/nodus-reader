#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
"""Research-only INT8 rewrite of the pinned 0.6B compiled predictor's MIL.

Requires coremltools==9.0. This uses its internal blob reader/writer, preserves
the graph and all non-linear-weight tensors, and never edits the source. A
rewritten compiled bundle is an experimental artifact, not a supported source
export or an app update. Validate loading, placement, quality and speed before
considering deployment; keep the original Apache-2.0 model attribution.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil

import coremltools
from coremltools import libmilstoragepython as blob
import numpy as np

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("source", type=Path)
parser.add_argument("destination", type=Path)
parser.add_argument("--keep", default="", help="Comma-separated linear weight names to retain in FP16")
args = parser.parse_args()
if coremltools.__version__ != "9.0":
    parser.error("Use coremltools==9.0 for this reproducible experiment")
if args.destination.exists():
    parser.error("Destination already exists; choose a fresh experiment directory")
source = args.source.resolve()
mil = (source / "model.mil").read_text()
if "tensor<fp16, [1, 1024]> e0" not in mil or "tensor<fp16, [1, 1024]> hidden" not in mil:
    parser.error("This experiment only accepts the original 0.6B predictor interface")
if "constexpr_blockwise_shift_scale" in mil:
    parser.error("Source must be the FP16 predictor, not an already quantized artifact")
kept = set(filter(None, args.keep.split(",")))
pattern = re.compile(r'(?P<indent>\s*)tensor<fp16, \[(?P<shape>[^]]+)\]> (?P<name>\w+) = const\(\)\[name = string\("[^"]+"\), val = tensor<fp16, \[[^]]+\]>\(BLOBFILE\(path = string\("@model_path/weights/weight.bin"\), offset = uint64\((?P<offset>\d+)\)\)\)\];')
matches = list(pattern.finditer(mil))
all_blobs = re.findall(r'BLOBFILE\(path = string\("([^"]+)"\), offset = uint64\((\d+)\)\)', mil)
if len(matches) != len(all_blobs):
    parser.error("Unexpected source MIL blob contract; refusing a partial rewrite")
reader = blob._BlobStorageReader(str(source / "weights/weight.bin"))
args.destination.mkdir(parents=True)
(args.destination / "weights").mkdir()
writer = blob._BlobStorageWriter(str(args.destination / "weights/weight.bin"))
offsets = {}
quantized = []


def rewrite(match):
    shape = tuple(int(x.strip()) for x in match["shape"].split(","))
    name, offset = match["name"], int(match["offset"])
    quantize = len(shape) == 2 and re.fullmatch(r"linear_\d+_weight_0", name) and name not in kept
    key = (offset, bool(quantize))
    if key not in offsets:
        bits = reader.read_fp16_data(offset)
        if bits.size != int(np.prod(shape)):
            raise ValueError("Blob shape mismatch: " + name)
        if quantize:
            w = bits.view(np.float16).reshape(shape).astype(np.float32)
            if not np.isfinite(w).all():
                raise ValueError("Non-finite source weights: " + name)
            scales = (np.max(np.abs(w), axis=1, keepdims=True) / 127).astype(np.float16)
            scales[scales == 0] = 1
            q = np.clip(np.rint(w / scales.astype(np.float32)), -127, 127).astype(np.int8)
            qoff = writer.write_int8_data(q.ravel())
            soff = writer.write_fp16_data(scales.ravel().view(np.uint16))
            error = float(np.linalg.norm(w - q.astype(np.float32) * scales.astype(np.float32)) / max(float(np.linalg.norm(w)), 1e-12))
            offsets[key] = (qoff, soff)
            quantized.append({"name": name, "shape": shape, "relativeRMSError": error})
        else:
            offsets[key] = writer.write_fp16_data(bits)
    if not quantize:
        return match[0].replace("uint64(" + str(offset) + ")", "uint64(" + str(offsets[key]) + ")")
    qoff, soff = offsets[key]
    dims = ", ".join(map(str, shape))
    return (f'{match["indent"]}tensor<fp16, [{dims}]> {name} = constexpr_blockwise_shift_scale('
            f'data = tensor<int8, [{dims}]>(BLOBFILE(path = string("@model_path/weights/weight.bin"), offset = uint64({qoff}))), '
            f'scale = tensor<fp16, [{shape[0]}, 1]>(BLOBFILE(path = string("@model_path/weights/weight.bin"), offset = uint64({soff}))))'
            f'[name = string("{name}")];')


rewritten = pattern.sub(rewrite, mil)
del writer
(args.destination / "model.mil").write_text(rewritten)
for name in ["coremldata.bin", "analytics"]:
    p = source / name
    if p.is_dir():
        shutil.copytree(p, args.destination / name)
    elif p.is_file():
        shutil.copy2(p, args.destination / name)
metadata = json.loads((source / "metadata.json").read_text())
for entry in metadata:
    entry["storagePrecision"] = "Mixed (Float16, Int8)"
    hist = entry.get("mlProgramOperationTypeHistogram", {})
    hist["Ios18.constexprBlockwiseShiftScale"] = len(quantized)
(args.destination / "metadata.json").write_text(json.dumps(metadata, indent=2) + "\n")
report = {"experimental": True, "source": str(source), "coremltools": coremltools.__version__,
          "sourceMILSHA256": hashlib.sha256(mil.encode()).hexdigest(),
          "sourceWeightBytes": (source / "weights/weight.bin").stat().st_size,
          "quantizedWeightBytes": (args.destination / "weights/weight.bin").stat().st_size,
          "quantized": quantized, "kept": sorted(kept)}
(args.destination.parent / (args.destination.name + ".quantization.json")).write_text(json.dumps(report, indent=2) + "\n")
print(json.dumps({k: v for k, v in report.items() if k != "quantized"}, indent=2))
print("Quantized", len(quantized), "unique linear matrices; embeddings and small tensors remain FP16")
