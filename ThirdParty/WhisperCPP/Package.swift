// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "WhisperCPP",
    platforms: [.macOS(.v14)],
    products: [.library(name: "CWhisper", targets: ["CWhisper"])],
    targets: [.target(
        name: "CWhisper", path: ".",
        sources: [
            "src/whisper.cpp", "Platform/quants.c", "Platform/repack.cpp",
            "ggml/src/ggml.c", "ggml/src/ggml.cpp", "ggml/src/ggml-alloc.c",
            "ggml/src/ggml-backend.cpp", "ggml/src/ggml-backend-reg.cpp",
            "ggml/src/ggml-opt.cpp", "ggml/src/ggml-threading.cpp",
            "ggml/src/ggml-quants.c", "ggml/src/gguf.cpp", "ggml/src/ggml-blas/ggml-blas.cpp",
            "ggml/src/ggml-cpu/ggml-cpu.c", "ggml/src/ggml-cpu/ggml-cpu.cpp",
            "ggml/src/ggml-cpu/repack.cpp", "ggml/src/ggml-cpu/hbm.cpp",
            "ggml/src/ggml-cpu/quants.c", "ggml/src/ggml-cpu/traits.cpp",
            "ggml/src/ggml-cpu/amx/amx.cpp", "ggml/src/ggml-cpu/amx/mmq.cpp",
            "ggml/src/ggml-cpu/binary-ops.cpp", "ggml/src/ggml-cpu/unary-ops.cpp",
            "ggml/src/ggml-cpu/vec.cpp", "ggml/src/ggml-cpu/ops.cpp"
        ], publicHeadersPath: "Public",
        cSettings: [
            .headerSearchPath("include"), .headerSearchPath("ggml/include"),
            .headerSearchPath("ggml/src"), .headerSearchPath("ggml/src/ggml-cpu"),
            .define("GGML_USE_CPU"), .define("GGML_USE_ACCELERATE"),
            .define("GGML_USE_BLAS"), .define("GGML_BLAS_USE_ACCELERATE"),
            .define("ACCELERATE_NEW_LAPACK"), .define("ACCELERATE_LAPACK_ILP64"),
            .define("GGML_SCHED_MAX_COPIES", to: "4"),
            .define("WHISPER_VERSION", to: "\"1.8.3\""),
            .define("GGML_VERSION", to: "\"0.9.5\""), .define("GGML_COMMIT", to: "\"2eeeba56\""),
            .unsafeFlags(["-O3", "-Xarch_x86_64", "-mavx2", "-Xarch_x86_64", "-mfma", "-Xarch_x86_64", "-mf16c"])
        ], linkerSettings: [.linkedFramework("Accelerate")]
    )], cxxLanguageStandard: .cxx17
)
