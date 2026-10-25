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
        // Gradium's PhononCore 0.4.1 rebuilt with ptts_export_coreml (on-device Core ML
        // export); source change and build script in engine/.
        .binaryTarget(
            name: "PhononCore",
            url: "https://github.com/jorgepb96/nodus-reader-mobile/releases/download/phononcore-0.4.1-nodus.1/PhononCore.xcframework.zip",
            checksum: "58083b754f4d4c9d87e18007446bf5a671722dde82f68cc0884294a6e78bbc3b"
        ),
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
