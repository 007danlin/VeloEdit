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
        .package(url: "https://github.com/sparkle-project/Sparkle.git", exact: "2.10.0"),
        .package(path: "ThirdParty/ArgmaxOSS"),
        .package(path: "ThirdParty/WhisperCPP"),
        .package(url: "https://github.com/microsoft/onnxruntime-swift-package-manager.git", exact: "1.24.2")
    ],
    targets: [
        .target(
            name: "CRNNoise",
            path: "ThirdParty/RNNoise",
            sources: ["src/denoise.c", "src/rnn.c", "src/pitch.c", "src/kiss_fft.c",
                      "src/celt_lpc.c", "src/nnet.c", "src/nnet_default.c",
                      "src/parse_lpcnet_weights.c", "src/rnnoise_data.c", "src/rnnoise_tables.c"],
            publicHeadersPath: "include",
            cSettings: [.headerSearchPath("src"), .headerSearchPath("compat"), .define("RNNOISE_BUILD")]
        ),
        .target(
            name: "VeloEditCore",
            dependencies: ["CRNNoise"],
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
            dependencies: ["VeloEditCore", .product(name: "Sparkle", package: "Sparkle")],
            linkerSettings: [
                .linkedFramework("SwiftUI"),
                .linkedFramework("AppKit"),
                .linkedFramework("AVKit"),
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
                .unsafeFlags(["-Xlinker", "-weak_framework", "-Xlinker", "FoundationModels"])
            ]
        ),
        .executableTarget(name: "VeloEditCLI", dependencies: ["VeloEditCore"], linkerSettings: [
            // A CLI has no main app bundle. TCC still requires the Speech usage
            // description before the on-device ASR authorization request.
            .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", cliInfoPlist])
        ]),
        .executableTarget(name: "VeloEditSpeechWorker", dependencies: ["VeloEditCore", .product(name: "WhisperKit", package: "ArgmaxOSS"), .product(name: "CWhisper", package: "WhisperCPP"), .product(name: "onnxruntime", package: "onnxruntime-swift-package-manager")]),
        .testTarget(
            name: "VeloEditCoreTests",
            dependencies: ["VeloEditCore"],
            resources: [.copy("Fixtures/NoiseReduction")]
        ),
        .testTarget(
            name: "VeloEditSpeechWorkerTests",
            dependencies: ["VeloEditSpeechWorker"]
        ),
        .testTarget(
            name: "VeloEditAppTests",
            dependencies: ["VeloEdit"]
        )
    ],
    swiftLanguageModes: [.v5]
)
