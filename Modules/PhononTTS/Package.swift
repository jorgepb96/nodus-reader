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
        .binaryTarget(
            name: "PhononCore",
            url: "https://github.com/gradium-ai/xn-ptts/releases/download/v0.4.1/PhononCore.xcframework.zip",
            checksum: "2b544125ab573d73a8a189008ddd182daf3934dedfe74b52af0832169e0857d2"
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
