import Foundation
import AVFoundation

/// Repairs the encoded mix without rebuilding the edit or encoding its video.
/// Predictions select the operation; only an independent meter on the resulting
/// AAC can establish that the existing delivery policy has been satisfied.
enum EncodedAudioNormalizer {
    static func peakCorrectionGain(_ report: EditorialAudioMasteringReport, allowsQuietMix: Bool) -> Double? {
        guard let loudness = report.outputLUFS, let peak = report.outputTruePeakDBTP,
              loudness.isFinite, peak.isFinite, peak > EditorialLoudnessPolicy.maximumTruePeak,
              EditorialLoudnessPolicy.accepts(lufs: loudness, truePeak: peak, allowsQuietMix: allowsQuietMix) else { return nil }
        // AAC reconstruction can exceed the loudnorm filter's predicted peak.
        // Attenuate from the actual encoded measurement, leaving codec headroom.
        return EditorialLoudnessPolicy.maximumTruePeak - 0.5 - peak
    }
    static func needsRepair(_ report: EditorialAudioMasteringReport, allowsQuietMix: Bool) -> Bool {
        guard let loudness = report.outputLUFS ?? report.integratedLUFS,
              let peak = report.outputTruePeakDBTP ?? report.truePeakDBTP else { return false }
        return !EditorialLoudnessPolicy.accepts(lufs: loudness, truePeak: peak, allowsQuietMix: allowsQuietMix)
            || !peak.isFinite || peak > EditorialLoudnessPolicy.maximumTruePeak
    }

    @discardableResult
    static func normalize(source: URL, destination: URL, duration: Double,
                          measured: EditorialAudioMasteringReport, allowsQuietMix: Bool) async throws -> EditorialAudioMasteringReport {
        guard let executable = MediaCompatibility.converterURL,
              let loudness = measured.outputLUFS ?? measured.integratedLUFS,
              loudness.isFinite, duration.isFinite, duration > 0 else {
            throw DerivedMediaError.exportFailed("Не удалось подготовить измеренную нормализацию звука")
        }
        // Explicitly quiet mixes must never be amplified by automatic mastering.
        let target = allowsQuietMix ? min(EditorialLoudnessPolicy.targetLUFS, loudness) : EditorialLoudnessPolicy.targetLUFS
        let base = "loudnorm=I=\(target):TP=-1.5:LRA=50"
        let common = ["-nostdin", "-hide_banner", "-nostats", "-threads", "1", "-filter_threads", "1", "-n"]
        let scan = try await run(executable: executable, arguments: common + ["-i", source.path,
            "-map", "0:a:0", "-vn", "-af", base + ":print_format=json", "-f", "null", "-"],
            directory: destination.deletingLastPathComponent(), timeout: max(60, duration * 2))
        guard let start = scan.lastIndex(of: "{"), let end = scan.lastIndex(of: "}"), start < end,
              let data = String(scan[start...end]).data(using: .utf8),
              let stats = try JSONSerialization.jsonObject(with: data) as? [String: String] else {
            throw DerivedMediaError.exportFailed("Не получены измерения для нормализации звука")
        }
        let fields = [("measured_I", "input_i"), ("measured_TP", "input_tp"),
                      ("measured_LRA", "input_lra"), ("measured_thresh", "input_thresh"), ("offset", "target_offset")]
        var filter = base + ":linear=true"
        for (parameter, key) in fields {
            guard let text = stats[key], let value = Double(text), value.isFinite else {
                throw DerivedMediaError.exportFailed("Неполное измерение звука: \(key)")
            }
            filter += ":\(parameter)=\(value)"
        }
        // Bound only the audio samples. A container-wide -t could trim a copied
        // video packet near the endpoint of a variable-frame-rate source.
        filter += ",atrim=duration=\(duration)"
        _ = try await run(executable: executable, arguments: common + ["-i", source.path,
            "-map", "0:v:0", "-map", "0:a:0", "-map_metadata", "0", "-c:v", "copy",
            "-c:a", "aac", "-b:a", "192k", "-ar", "48000", "-ac", "2", "-af", filter,
            "-movflags", "+faststart", destination.path],
            directory: destination.deletingLastPathComponent(), timeout: max(60, duration * 2))
        guard var actual = try await EditorialDeliveryVerifier.measureEncodedAudio(asset: AVURLAsset(url: destination)) else {
            throw DerivedMediaError.exportFailed("Не удалось измерить звук после нормализации")
        }
        if let gain = peakCorrectionGain(actual, allowsQuietMix: allowsQuietMix) {
            let corrected = destination.deletingLastPathComponent().appendingPathComponent(".audio-peak-\(UUID()).mp4")
            defer { try? FileManager.default.removeItem(at: corrected) }
            PerformanceTrace.current?.event("delivery.audio-encoded-peak-correction", values: [
                "measuredPeakDBTP": actual.outputTruePeakDBTP ?? 0, "gainDB": gain])
            try await SoftwareCompositionExporter.remaster(source: destination, gainDB: gain,
                duration: duration, destination: corrected)
            guard let checked = try await EditorialDeliveryVerifier.measureEncodedAudio(asset: AVURLAsset(url: corrected)),
                  checked.measuredFrames > 0, !needsRepair(checked, allowsQuietMix: allowsQuietMix) else {
                throw DerivedMediaError.exportFailed("Пики звука записанного MP4 пока не прошли повторную проверку")
            }
            try Task.checkCancellation()
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: corrected)
            actual = checked
        }
        guard
              actual.measuredFrames > 0, actual.outputLUFS != nil, actual.outputTruePeakDBTP != nil,
              !needsRepair(actual, allowsQuietMix: allowsQuietMix) else {
            throw DerivedMediaError.exportFailed("Звук записанного MP4 пока не прошёл проверку громкости и пиков")
        }
        return actual
    }

    /// Publish only a successfully measured replacement. An interruption leaves
    /// the completed video intact, allowing recovery to reuse its visual work.
    static func repairIfNeeded(at url: URL, duration: Double, allowsQuietMix: Bool) async throws -> Bool {
        guard let measured = try await EditorialDeliveryVerifier.measureEncodedAudio(asset: AVURLAsset(url: url)),
              needsRepair(measured, allowsQuietMix: allowsQuietMix) else { return false }
        let staged = url.deletingLastPathComponent().appendingPathComponent(".audio-repair-\(UUID()).mp4")
        defer { try? FileManager.default.removeItem(at: staged) }
        _ = try await PerformanceTrace.measure(name: "delivery.audio-repair", fields: ["artifact": url.path]) {
            try await normalize(source: url, destination: staged, duration: duration,
                                measured: measured, allowsQuietMix: allowsQuietMix)
        }
        try Task.checkCancellation()
        _ = try FileManager.default.replaceItemAt(url, withItemAt: staged)
        return true
    }

    private static func run(executable: URL, arguments: [String], directory: URL, timeout: Double) async throws -> String {
        let logURL = directory.appendingPathComponent(".audio-mastering-\(UUID()).log")
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
                    throw DerivedMediaError.exportFailed("Истекло время обработки звука; завершённые проверки сохранены")
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
            try Task.checkCancellation()
            guard process.terminationStatus == 0 else {
                throw DerivedMediaError.exportFailed("Не удалось обработать звук MP4 (код \(process.terminationStatus))")
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
        return try String(contentsOf: logURL, encoding: .utf8)
    }
}
