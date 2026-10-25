# PhononCore with on-device export

`PhononCore.xcframework` is Gradium's compiled Phonon core (xn-ptts v0.4.1, MIT OR
Apache-2.0) with one addition: `ptts_export_coreml`, which exports a checkpoint folder
to a Core ML bundle on the device. It is the same code as Gradium's
`ptts/examples/export_coreml.rs`, moved into `ptts-ffi` (`src/export.rs`).

Nodus Reader uses it for Phonon 40M Spanish, which Gradium publishes only as PyTorch
weights behind a Hugging Face gate (CC BY-NC 4.0): the app downloads the checkpoint
with the user's own access and converts it locally, so the model is never hosted or
shipped by Nodus Reader.

- `0001-ptts-ffi-export-coreml.patch` — the change, against tag `v0.4.1`.
- `build-phononcore.sh` — applies it and runs Gradium's `ios/build-xcframework.sh`
  (iPhone, iOS simulator and Apple-silicon Mac slices).

The built zip is published as the `phononcore-0.4.1-nodus.1` release of this repository
and pinned by URL and checksum in `../Package.swift`. To update: rebuild, publish a new
release asset, and update the URL and checksum.
