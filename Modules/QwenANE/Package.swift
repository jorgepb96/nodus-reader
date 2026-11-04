// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "QwenANE",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "QwenANE", targets: ["QwenANE"]),
        .executable(name: "qwen-probe", targets: ["QwenProbe"]),
        .executable(name: "qwen-voice-score", targets: ["QwenVoiceScore"]),
    ],
    dependencies: [.package(url: "https://github.com/weichsel/ZIPFoundation", from: "0.9.19")],
    targets: [
        .target(name: "GVoiceKit", dependencies: [.product(name: "ZIPFoundation", package: "ZIPFoundation")]),
        .target(name: "GVoiceProductionKit", dependencies: ["GVoiceKit"]),
        .target(name: "QwenANE", dependencies: ["GVoiceKit", "GVoiceProductionKit"], exclude: ["README.md"],
                resources: [.copy("LICENSE")]),
        .executableTarget(name: "QwenProbe", dependencies: ["QwenANE"]),
        .executableTarget(name: "QwenVoiceScore", dependencies: ["QwenANE"]),
        .testTarget(name: "QwenANETests", dependencies: ["QwenANE", "GVoiceKit"],
                    exclude: ["make_reference.py", "make_voice_prep_reference.py"], resources: [.copy("Fixtures")]),
    ],
    swiftLanguageModes: [.v5]
)
