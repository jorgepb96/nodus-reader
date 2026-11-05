// swift-tools-version:5.9
import PackageDescription
let package = Package(name: "LinnetTTS", platforms: [.iOS(.v15), .macOS(.v12)], products: [.library(name: "LinnetTTS", targets: ["LinnetTTS"])], targets: [
    .binaryTarget(name: "CLinnetTTS", path: "CLinnetTTS.xcframework"),
    .target(name: "LinnetTTS", dependencies: ["CLinnetTTS"], linkerSettings: [.linkedFramework("AVFoundation")])
])
