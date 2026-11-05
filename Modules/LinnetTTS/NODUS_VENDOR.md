# LinnetTTS 0.1.1

Swift sources, LICENSE and NOTICE are vendored unchanged from
https://github.com/VoxRT/LinnetTTS/tree/v0.1.1 (Apache-2.0).

`python3 tools/prepare-linnet.py` runs before XcodeGen. It verifies the official
0.1.1 SDK ZIP against its published SwiftPM checksum and wraps the original
static archives as CLinnetTTS.framework slices. This isolates module maps from
PhononCore, which otherwise also produces `include/module.modulemap`. Mac slices
use versioned framework bundles. Wrapper plists declare the upstream minimum OS
(iOS 15 / macOS 12) and supported platforms for App Store validation. Generated frameworks are ignored by Git.

No model weights are contained in this package. Nodus downloads the byte-identical
FP16 checkpoint, tokenizer, two authorised voices and their notices separately
under Linnet Weights License 1.0. Voice creation is not exposed.
