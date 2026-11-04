"""Regenerates Fixtures/ from qwen-onnx-cpu (the Python reference). Run with a venv that has
coremltools + torch + onnxruntime:  python make_reference.py <qwen-onnx-cpu dir> <out dir>

  jeff_codes.npy        int16 (64,16): render_fast.Pipeline(coreml_lm2, engine="coreml").render("jeff", LINE, seed=7)
  jeff_vocoder_ref.npy  int16 (N,): ORT vocoder.onnx on [ref_codes ; first 36 codes], reference audio dropped
"""
import sys, os, numpy as np
root, out = sys.argv[1], sys.argv[2]
sys.path.insert(0, root); sys.path.insert(0, root + "/tools")
import render_fast as rf, qonnx
from common import OUT
LINE = "Good evening, you are tuned in to Gloam F M. Up next, a slow burner to take us into the night."
p = rf.Pipeline(OUT + "/coreml_lm2", None, "ane", 1, "coreml")
_, codes, info = p.render("jeff", LINE, 7)
np.save(out + "/jeff_codes.npy", np.asarray(codes, dtype=np.int16))
v = qonnx.load_voice("jeff")
ref = np.asarray(v["ref_codes"])[0].T                          # (T,16)
c = np.concatenate([ref, np.asarray(codes)[:36]]).astype(np.int64)
sess = qonnx._sess(qonnx.ONNX_DIR + "/vocoder.onnx", 1, False)
w = sess.run(None, {"codes": c.T[None]})[0].ravel()[len(ref) * qonnx.FRAME:]
np.save(out + "/jeff_vocoder_ref.npy", np.round(np.clip(w, -1, 1) * 32767).astype(np.int16))
