// swift-tools-version: 5.10
import PackageDescription
let package = Package(name: "ArgmaxOSS", platforms: [.macOS(.v14)], products: [.library(name: "WhisperKit", targets: ["WhisperKit"])], targets: [.target(name: "ArgmaxCore"), .target(name: "WhisperKit", dependencies: ["ArgmaxCore"]), .testTarget(name: "WhisperKitCompatibilityTests", dependencies: ["WhisperKit", "ArgmaxCore"])], swiftLanguageVersions: [.v5])
