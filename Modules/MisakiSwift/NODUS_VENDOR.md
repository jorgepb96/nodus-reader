# Vendored: MisakiSwift

| | |
| --- | --- |
| Upstream | https://github.com/mattmireles/MisakiSwift (fork of https://github.com/mlalma/MisakiSwift) |
| Commit | `3a27756a780fc138e328a96e533fb440a3419d5b`, the revision `kokoro-coreml` pins |
| Licence | Apache-2.0, `LICENSE` |

Kokoro's English phonemizer. The only change: `Package.swift` resolves mlx-swift
`exact: "0.33.0"` instead of `exact: "0.31.4"`, the version MLXAudio (Ming on the Mac)
needs, and the test target is dropped. As a local package with the same identity it
overrides the remote one `kokoro-coreml` declares, so the app resolves one MLX.

Drop this directory once an upstream revision accepts mlx-swift 0.33.
