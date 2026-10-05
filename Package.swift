// swift-tools-version: 6.0
import PackageDescription
import Foundation

let cliInfoPlist = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent("Resources/CLI-Info.plist").path

let package = Package(
    name: "VeloEdit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "VeloEditCore", targets: ["VeloEditCore"]),
        .executable(name: "VeloEdit", targets: ["VeloEdit"]),
        .executable(name: "veloedit-cli", targets: ["VeloEditCLI"])
    ],
    dependencies: [
        .package(path: "ThirdParty/ArgmaxOSS"),
        .package(url: "https://github.com/microsoft/onnxruntime-swift-package-manager.git", exact: "1.24.2")
    ],
    targets: [
        .target(
            name: "VeloEditCore",
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("Vision"),
                .linkedFramework("CoreImage"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreText"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("ImageIO"),
                .linkedFramework("Speech"),
                .linkedFramework("QuickLookThumbnailing")
            ]
        ),
        .executableTarget(
            name: "VeloEdit",
            dependencies: ["VeloEditCore"],
            linkerSettings: [
                .linkedFramework("SwiftUI"),
                .linkedFramework("AppKit"),
                .linkedFramework("AVKit"),
                .unsafeFlags(["-Xlinker", "-weak_framework", "-Xlinker", "FoundationModels"])
            ]
        ),
        .executableTarget(name: "VeloEditCLI", dependencies: ["VeloEditCore"], linkerSettings: [
            // A CLI has no main app bundle. TCC still requires the Speech usage
            // description before the on-device ASR authorization request.
            .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", cliInfoPlist])
        ]),
        .executableTarget(name: "VeloEditSpeechWorker", dependencies: ["VeloEditCore", .product(name: "WhisperKit", package: "ArgmaxOSS"), .product(name: "onnxruntime", package: "onnxruntime-swift-package-manager")]),
        .testTarget(
            name: "VeloEditCoreTests",
            dependencies: ["VeloEditCore"]
        ),
        .testTarget(
            name: "VeloEditAppTests",
            dependencies: ["VeloEdit"]
        )
    ],
    swiftLanguageModes: [.v5]
)
