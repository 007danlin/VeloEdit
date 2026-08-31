// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VeloEdit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "VeloEditCore", targets: ["VeloEditCore"]),
        .executable(name: "VeloEdit", targets: ["VeloEdit"]),
        .executable(name: "veloedit-cli", targets: ["VeloEditCLI"])
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
        .executableTarget(name: "VeloEditCLI", dependencies: ["VeloEditCore"]),
        .testTarget(
            name: "VeloEditCoreTests",
            dependencies: ["VeloEditCore"]
        )
    ],
    swiftLanguageModes: [.v5]
)
