# Immersive Audio catalog tools

These tools build the downloadable sound catalog the app plays (see `docs/IMMERSIVE_AUDIO.md`). Everything runs on a Mac with the Xcode command-line tools, ffmpeg (Homebrew) and `afconvert`, and Python stdlib only.

```bash
python3 -I tools/immersive-audio/pipeline.py fetch      # direct downloads + licence evidence (OpenGameArt)
python3 -I tools/immersive-audio/pipeline.py import ID FILE   # an original downloaded by hand (Freesound, FMA)
python3 -I tools/immersive-audio/pipeline.py process    # inspect, edit, level, loop, encode
python3 -I tools/immersive-audio/pipeline.py verify     # every check on every output; exits non-zero on failure
python3 -I tools/immersive-audio/pipeline.py manifest   # build/immersive-audio/catalog.json, the app copy, PROVENANCE.md
```

## Files

**In the repository:**
- `sources.json`: every candidate, kept with `status` include or reject, the reject reason, the semantics and the notes.
- `pipeline.py`: the steps above.
- `audiotool.swift`: the DSP. It is compiled to `build/immersive-audio/audiotool` on first use.
- `MANUAL_DOWNLOADS.md`: the originals that need a signed-in account (Freesound, Free Music Archive). Download each file as served, unconverted, then run `import`.

**Git-ignored, in `build/immersive-audio/`:**
- `originals/`: downloads.
- `evidence/`: licence page snapshots.
- `stage/`: intermediate WAVs.
- `packs/`: the files the app downloads.
- `state.json`: measurements and hashes.
- `fingerprints/`.

## Rules the pipeline enforces

**Licences.**
- CC0 only. On OpenGameArt, CC0 must be the only licence listed.
- Freesound and Free Music Archive pages must link the CC0 deed.
- The licence statement found on the page and the page's SHA-256 are recorded.

**Nodus Drift.**
- No source shared with Nodus Drift. The tools compare Freesound IDs, page URLs and SHA-256s against `nodus-drift-mobile/docs/rights/replacement-audio/`; set `NODUS_DRIFT_REPO` if it is elsewhere.
- BigSoundBank is not used.

**Rejections.** A file is rejected for:
- a source below 44.1 kHz;
- lossy music below 192 kb/s, unless accepted per candidate (Vorbis q8);
- a brickwall cut below 15.5 kHz;
- more than 50 clipped runs;
- music under 60 s;
- a loop shorter than 60 s.

**Edits.** Only edits with a measured reason:
- resampling only above 48 kHz, never up;
- silence trimming;
- a 20 Hz high-pass only when there is DC offset;
- mono duplicated to both channels, with no widening.

**Level.** One fixed gain per file: music −20 LUFS and ≤ −1.5 dBTP, ambience −28 LUFS and ≤ −3 dBTP. A file that cannot reach its target under the true-peak limit stays quieter; there is no compression.

**Encoding.** AAC-LC VBR (Apple's encoder) at a pinned rate. The VBR quality is searched to land in 160–196 kb/s for music and 96–132 kb/s for ambience. The next step up, at most +64 kb/s, is used only when no VBR step lands in the range.

**Verification.**
- Clean decode, and decoded length equal to the PCM length.
- True peak ≤ −1 dBTP, loudness within 1 LU, no clipping.
- Loop seams as smooth as the material: step and spectral-flux ratios ≤ 3.
- No exact or perceptual duplicates (fingerprint bit error rate < 0.35).

## Publishing (needs the maintainer's explicit approval)

Two mirrors host the same files; the app tries them in order.

1. **Hugging Face dataset**:
   ```bash
   hf upload jorgepb96/nodus-reader-immersive-audio build/immersive-audio/packs . --repo-type dataset
   ```
   Record the resulting commit.
2. **GitHub Release** `immersive-audio-v1` on `jorgepb96/nodus-reader`. Asset names are flat (`<id>.m4a`, the manifest's `githubAssetName`):
   ```bash
   gh release create immersive-audio-v1 build/immersive-audio/packs/*/*.m4a --title "Immersive Audio catalog v1"
   ```

Then replace `<commit>` in `HOSTS` (`pipeline.py`), run `manifest` again, rebuild the app and run the catalog tests. Until then the Hugging Face host is skipped and only the GitHub mirror is tried.
