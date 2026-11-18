import Foundation

enum DeliveryFFmpeg {
    static func run(executable: URL, arguments: [String], directory: URL, timeout: Double) async throws -> String {
        let logURL = directory.appendingPathComponent(".veloedit-media-\(UUID()).log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let log = try FileHandle(forWritingTo: logURL)
        defer { try? log.close(); try? FileManager.default.removeItem(at: logURL) }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = log
        let started = ProcessInfo.processInfo.systemUptime
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try process.run()
            while process.isRunning {
                if Task.isCancelled || ProcessInfo.processInfo.systemUptime - started > timeout {
                    process.terminate()
                    for _ in 0..<20 where process.isRunning { try? await Task.sleep(for: .milliseconds(50)) }
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                    if Task.isCancelled { throw CancellationError() }
                    throw DerivedMediaError.exportFailed("Истекло время обработки медиафайла")
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
            try Task.checkCancellation()
            guard process.terminationStatus == 0 else {
                throw DerivedMediaError.exportFailed("Не удалось обработать медиафайл (код \(process.terminationStatus))")
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
        return try String(contentsOf: logURL, encoding: .utf8)
    }
}
