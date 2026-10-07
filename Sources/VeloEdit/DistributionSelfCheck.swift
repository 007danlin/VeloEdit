import Foundation
import Darwin

/// Exercises executable loading without opening a project or starting downloads.
enum DistributionSelfCheck {
    @MainActor static func exitIfRequested() {
        guard CommandLine.arguments.dropFirst().elementsEqual(["--self-check"]) else { return }
        #if arch(x86_64)
        let architecture = "x86_64"
        #else
        let architecture = "arm64"
        #endif
        let info = ["architecture": architecture, "directorModel": LocalDirectorAgent.ollamaModel]
        guard let data = try? JSONSerialization.data(withJSONObject: info, options: [.sortedKeys]) else { exit(1) }
        FileHandle.standardOutput.write(data + Data("\n".utf8))
        exit(0)
    }
}
