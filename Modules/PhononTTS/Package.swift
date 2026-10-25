// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "ptts",
    // iOS 18 / macOS 15: the models are Core ML 8 programs. Apple silicon only; the Neural
    // Engine is what makes this fast.
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "ptts", targets: ["PhononTTS"]),
    ],
    targets: [
        // DEV: local build with ptts_export_coreml; replaced by the release URL before commit.
        .binaryTarget(name: "PhononCore", path: "PhononCore.xcframework"),
        .target(
            name: "PhononTTS",
            dependencies: ["PhononCore"],
            linkerSettings: [
                .linkedFramework("CoreML"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("Accelerate"),
                .linkedFramework("AVFoundation"),
            ]
        ),
    ]
)
