// swift-tools-version: 6.0
// Feasibility proof of concept: Stable Audio 3 Small (Music and SFX) on MLX Swift.
// The model code is vendored from kellyvv/StableAudio3-IOS (MIT), see NODUS_VENDOR.md.
// No model weights are part of this package.

import PackageDescription

let package = Package(
    name: "StableAudioMLX",
    platforms: [
        .iOS(.v18), .macOS(.v15),
    ],
    products: [
        .library(name: "StableAudioMLX", targets: ["StableAudioMLX"]),
        .executable(name: "sa3-bench", targets: ["sa3-bench"]),
    ],
    dependencies: [
        // Same MLX as the app (Kokoro's phonemizer, Ming), so one MLX is resolved.
        .package(url: "https://github.com/ml-explore/mlx-swift", exact: "0.33.0"),
    ],
    targets: [
        .target(
            name: "StableAudioMLX",
            dependencies: [
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
            ]
        ),
        .executableTarget(
            name: "sa3-bench",
            dependencies: ["StableAudioMLX"]
        ),
    ]
)
