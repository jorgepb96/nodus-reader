"""Regenerates the voice-prep fixtures from qwen-onnx-cpu (Core ML encoders, fp32 CPU).
  python make_voice_prep_reference.py <qwen-onnx-cpu dir> <packs dir> <out dir>

  <slug>_enc_codes.npy   int16 (16,T): ref.wav -> ReferenceTail -> QwenSpeechEncoder.mlpackage
  <slug>_spk_ref.npy     float32 (1024,): out/voices/<slug>/spk_embed_python.npy (MLX, upstream mel)
"""
import sys, shutil, numpy as np, soundfile as sf
root, packs, out = sys.argv[1:4]
sys.path.insert(0, root); sys.path.insert(0, root + "/tools")
import coremltools as ct, enc_torch as E
from ref_tail import reference_tail_end
sp = ct.models.MLModel(root + "/out/coreml_enc/QwenSpeechEncoder.mlpackage", compute_units=ct.ComputeUnit.CPU_ONLY)
for s in ["jeff", "benson", "cruz", "billie-frost"]:
    x, sr = sf.read(f"{packs}/{s}/source/ref.wav", dtype="float32")
    assert sr == 24000 and x.ndim == 1
    x = x[:reference_tail_end(x, sr)]
    c = sp.predict({"wav": E.pad_wave(x), "n_samples": np.array([len(x)], np.int32)})["codes"][0, :, :E.n_code_frames(len(x))]
    np.save(f"{out}/{s}_enc_codes.npy", c.astype(np.int16))
    np.save(f"{out}/{s}_spk_ref.npy", np.load(f"{root}/out/voices/{s}/spk_embed_python.npy").astype(np.float32))
    print(s, len(x), c.shape)
