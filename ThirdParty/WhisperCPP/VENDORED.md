# whisper.cpp CPU runtime

Upstream: https://github.com/ggml-org/whisper.cpp
Tag: v1.8.3
Commit: 2eeeba56e9edd762b4b38467bab96c2517163158
License: MIT (see LICENSE and ggml/LICENSE).

VeloEdit compiles the CPU backend and Apple's Accelerate BLAS backend (the
upstream macOS default), without Core ML, Metal,
OpenMP, or dynamically loaded backends. Source files are unchanged;
Package.swift, Public/, and Platform/ adapt the build for SwiftPM. Intel
uses AVX2/F16C/FMA (Haswell or later, covering Intel Macs supported by macOS 14).
ARM uses the portable NEON backend; the app uses WhisperKit on Apple silicon.
The CPU sources use -O3, matching upstream CMake Release optimization rather
than Xcode's default size optimization for Swift package C/C++ targets.
