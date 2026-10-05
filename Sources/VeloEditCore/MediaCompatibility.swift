import Foundation
import AVFoundation

/// Compatibility copies are project media, never disposable preview cache.
public enum MediaCompatibility {
    public static var converterURL: URL? {
        let paths = [Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/ffmpeg").path,
                     "/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]
        return paths.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    public static func convert(_ source: URL, directory: URL,
                               progress: (@Sendable (ImportProgress) -> Void)? = nil) async throws -> URL {
        guard let executable = converterURL else { throw MediaImportError.conversionUnavailable(source) }
        try Task.checkCancellation()
        let values = try source.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let hash = try MediaImporter.quickFingerprint(url: source, byteSize: Int64(values.fileSize ?? 0), modificationDate: values.contentModificationDate)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let output = directory.appendingPathComponent(hash + ".mp4")
        if FileManager.default.fileExists(atPath: output.path) { return output }
        let staging = directory.appendingPathComponent(".\(UUID()).mp4")
        let progressURL = directory.appendingPathComponent(".\(UUID()).progress")
        let logURL = directory.appendingPathComponent(".\(UUID()).log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let log = try FileHandle(forWritingTo: logURL)
        defer {
            try? log.close()
            for url in [staging, progressURL, logURL] { try? FileManager.default.removeItem(at: url) }
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["-nostdin", "-hide_banner", "-loglevel", "error", "-y", "-i", source.path,
                             "-map", "0:v:0", "-map", "0:a:0?", "-map_metadata", "0",
                             "-c:v", "libx264", "-preset", "veryfast", "-crf", "18",
                             "-vf", "pad=ceil(iw/2)*2:ceil(ih/2)*2", "-pix_fmt", "yuv420p",
                             "-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart",
                             "-progress", progressURL.path, staging.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = log
        let duration = (try? await AVURLAsset(url: source).load(.duration).seconds) ?? 0
        let started = ProcessInfo.processInfo.systemUptime
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try process.run()
            while process.isRunning {
                if Task.isCancelled {
                    process.terminate()
                    // The subprocess must not survive closing the application.
                    for _ in 0..<20 where process.isRunning { try? await Task.sleep(for: .milliseconds(50)) }
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                    throw CancellationError()
                }
                let report = (try? String(contentsOf: progressURL, encoding: .utf8)) ?? ""
                let micros = report.split(separator: "\n").last { $0.hasPrefix("out_time_us=") }
                    .flatMap { Double($0.dropFirst("out_time_us=".count)) } ?? 0
                let seconds = micros / 1_000_000
                let fraction = duration.isFinite && duration > 0 ? min(0.99, seconds / duration) : 0
                let elapsed = ProcessInfo.processInfo.systemUptime - started
                progress?(ImportProgress(completed: Int(fraction * 100), total: duration > 0 ? 100 : 0,
                    currentName: "Конвертирую в MP4 · \(source.lastPathComponent)", currentFileName: source.lastPathComponent,
                    estimatedSecondsRemaining: fraction > 0.01 ? elapsed / fraction * (1 - fraction) : nil))
                try? await Task.sleep(for: .milliseconds(250))
            }
            try Task.checkCancellation()
            guard process.terminationStatus == 0 else { throw MediaImportError.conversionFailed(source) }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
        // Validate before publishing; interrupted/invalid copies cannot poison retries.
        _ = try await MediaImporter().makeAsset(url: staging)
        try Task.checkCancellation()
        try FileManager.default.moveItem(at: staging, to: output)
        return output
    }
}
