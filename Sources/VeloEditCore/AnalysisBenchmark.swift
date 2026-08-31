import Foundation

/// A benchmark row contains measured values only. Missing instrumentation is
/// represented by `nil`; the app never substitutes theoretical estimates.
public struct AnalysisBenchmarkRow: Codable, Hashable, Sendable {
    public var mode: AIPowerMode
    public var hardwareIdentifier: String
    public var fileCount: Int
    public var sourceDuration: TimeInterval
    public var wallClockDuration: TimeInterval
    public var sourceSecondsPerWallSecond: Double?
    public var decodedFrames: Int
    public var frameCacheHits: Int
    public var visionCalls: Int
    public var vlmCalls: Int
    public var vlmLatency: TimeInterval
    public var peakResidentMemoryBytes: UInt64?
    public var processCPUTime: TimeInterval?
    public var thermalStates: [String]
    public var fallbackFileCount: Int
    public var semanticRuntimeStatus: String

    public init?(mode: AIPowerMode, assets: [MediaAsset], analyses: [AnalysisResult]) {
        let measured = analyses.compactMap(\.metrics).filter { $0.mode == mode }
        guard !measured.isEmpty else { return nil }
        self.mode = mode
        hardwareIdentifier = measured.first?.hardwareIdentifier ?? "unknown"
        fileCount = measured.count
        let measuredIDs = Set(analyses.filter { $0.metrics?.mode == mode }.map(\.assetID))
        sourceDuration = assets.filter { measuredIDs.contains($0.id) }.compactMap(\.metadata.duration).reduce(0, +)
        wallClockDuration = measured.map(\.totalDuration).reduce(0, +)
        sourceSecondsPerWallSecond = wallClockDuration > 0 ? sourceDuration / wallClockDuration : nil
        decodedFrames = measured.map(\.decodedFrameCount).reduce(0, +)
        frameCacheHits = measured.map(\.frameCacheHitCount).reduce(0, +)
        visionCalls = measured.map(\.visionCallCount).reduce(0, +)
        vlmCalls = measured.map(\.vlmCallCount).reduce(0, +)
        vlmLatency = measured.map(\.vlmLatency).reduce(0, +)
        peakResidentMemoryBytes = measured
            .flatMap(\.stageMetrics)
            .flatMap { [$0.resourceStart.residentMemoryBytes, $0.resourceEnd.residentMemoryBytes] }
            .compactMap { $0 }
            .max()
        let resourceSnapshots = measured.flatMap(\.stageMetrics).flatMap { [$0.resourceStart, $0.resourceEnd] }
        let cpuValues = resourceSnapshots.compactMap(\.cpuTimeSeconds)
        processCPUTime = cpuValues.isEmpty ? nil : max(0, (cpuValues.max() ?? 0) - (cpuValues.min() ?? 0))
        thermalStates = Array(Set(measured.flatMap(\.thermalStates))).sorted()
        let pairs: [(UUID, AnalysisMetrics)] = analyses.compactMap { result -> (UUID, AnalysisMetrics)? in
            guard let metrics = result.metrics, metrics.mode == mode else { return nil }
            return (result.assetID, metrics)
        }
        let metricsByAsset = Dictionary(uniqueKeysWithValues: pairs)
        fallbackFileCount = assets.filter {
            guard $0.kind == .video, let metrics = metricsByAsset[$0.id] else { return $0.kind == .video }
            return metrics.decodedFrameCount + metrics.frameCacheHitCount == 0
        }.count
        if fallbackFileCount > 0 {
            semanticRuntimeStatus = "metadata-fallback"
        } else if mode == .fast {
            semanticRuntimeStatus = "valid-local-fast"
        } else if vlmCalls == 0 {
            semanticRuntimeStatus = "valid-local-no-vlm"
        } else {
            semanticRuntimeStatus = "valid-vlm"
        }
    }

    public var tabSeparatedLine: String {
        let speed = sourceSecondsPerWallSecond.map { String(format: "%.2fx", $0) } ?? "—"
        let memory = peakResidentMemoryBytes.map { String(format: "%.2f GB", Double($0) / 1_073_741_824) } ?? "—"
        let cpu = processCPUTime.map { String(format: "%.2f s", $0) } ?? "—"
        return [
            mode.rawValue,
            "\(fileCount)",
            String(format: "%.2f s", sourceDuration),
            String(format: "%.2f s", wallClockDuration),
            speed,
            "\(decodedFrames)",
            "\(frameCacheHits)",
            "\(visionCalls)",
            "\(vlmCalls)",
            String(format: "%.2f s", vlmLatency),
            memory,
            cpu,
            thermalStates.joined(separator: ","),
            semanticRuntimeStatus
        ].joined(separator: "\t")
    }

    public static let tabSeparatedHeader = [
        "mode", "files", "source", "wall", "speed", "decoded", "cache-hits",
        "vision", "vlm", "vlm-latency", "peak-process-rss", "process-cpu", "thermal", "status"
    ].joined(separator: "\t")
}

public struct AnalysisBenchmarkReport: Codable, Hashable, Sendable {
    public var measuredAt: Date
    public var rows: [AnalysisBenchmarkRow]

    public init(measuredAt: Date = Date(), rows: [AnalysisBenchmarkRow]) {
        self.measuredAt = measuredAt
        self.rows = rows
    }

    public var tabSeparatedText: String {
        ([AnalysisBenchmarkRow.tabSeparatedHeader] + rows.map(\.tabSeparatedLine)).joined(separator: "\n")
    }
}
