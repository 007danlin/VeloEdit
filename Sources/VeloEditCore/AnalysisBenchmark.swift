import Foundation

/// A benchmark row contains measured values only. Missing instrumentation is
/// represented by `nil`; the app never substitutes theoretical estimates.
public struct AnalysisBenchmarkRow: Codable, Hashable, Sendable {
    public var mode: AIPowerMode
    public var hardwareIdentifier: String
    public var fileCount: Int
    public var sourceDuration: TimeInterval
    public var wallClockDuration: TimeInterval
    public var computeDuration: TimeInterval? = nil
    public var wallClockMeasurement: String? = nil
    public var sourceSecondsPerWallSecond: Double?
    public var decodedFrames: Int
    public var frameCacheHits: Int
    public var visionCalls: Int
    public var vlmCacheHits: Int? = nil
    public var vlmCalls: Int
    public var vlmLatency: TimeInterval
    public var peakResidentMemoryBytes: UInt64?
    public var processCPUTime: TimeInterval?
    public var thermalStates: [String]
    public var fallbackFileCount: Int
    public var semanticRuntimeStatus: String
    public var successfulVLMScenes: Int? = nil
    public var plannedVLMScenes: Int? = nil
    public var successfulVLMRechecks: Int? = nil

    public init?(mode: AIPowerMode, assets: [MediaAsset], analyses: [AnalysisResult], operationDuration: TimeInterval? = nil) {
        let measured = analyses.compactMap(\.metrics).filter { $0.mode == mode }
        guard !measured.isEmpty else { return nil }
        self.mode = mode
        hardwareIdentifier = measured.first?.hardwareIdentifier ?? "unknown"
        fileCount = measured.count
        let measuredIDs = Set(analyses.filter { $0.metrics?.mode == mode }.map(\.assetID))
        sourceDuration = assets.filter { measuredIDs.contains($0.id) }.compactMap(\.metadata.duration).reduce(0, +)
        computeDuration = measured.map(\.totalDuration).reduce(0, +)
        // Legacy records can only provide a date envelope, never an operation
        // measurement. The CLI supplies its own monotonic end-to-end interval.
        wallClockDuration = operationDuration ?? max(0, (measured.map(\.endedAt).max() ?? Date())
            .timeIntervalSince(measured.map(\.startedAt).min() ?? Date()))
        wallClockMeasurement = operationDuration == nil ? "legacy-date-envelope" : "monotonic-operation"
        sourceSecondsPerWallSecond = wallClockDuration > 0 ? sourceDuration / wallClockDuration : nil
        decodedFrames = measured.map(\.decodedFrameCount).reduce(0, +)
        frameCacheHits = measured.map(\.frameCacheHitCount).reduce(0, +)
        visionCalls = measured.map(\.visionCallCount).reduce(0, +)
        vlmCalls = measured.map(\.vlmCallCount).reduce(0, +)
        vlmCacheHits = measured.compactMap(\.vlmCacheHitCount).reduce(0, +)
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
            // Unmeasured files (or files analyzed in another mode) cannot be
            // classified as metadata fallback in this mode's benchmark row.
            guard $0.kind == .video, let metrics = metricsByAsset[$0.id] else { return false }
            return metrics.decodedFrameCount + metrics.frameCacheHitCount == 0
        }.count
        let results = analyses.filter { $0.metrics?.mode == mode }
        let evidence = results.compactMap(\.aiExecution)
        successfulVLMScenes = evidence.map(\.evaluatedScenes).reduce(0, +)
        plannedVLMScenes = evidence.map(\.plannedScenes).reduce(0, +)
        successfulVLMRechecks = evidence.map(\.evaluatedRechecks).reduce(0, +)
        if fallbackFileCount > 0 {
            semanticRuntimeStatus = "metadata-fallback"
        } else if evidence.count != results.count {
            semanticRuntimeStatus = "unverified-legacy"
        } else if evidence.contains(where: { !$0.isComplete }) {
            if (successfulVLMScenes ?? 0) > 0 { semanticRuntimeStatus = "partial-vlm" }
            else if evidence.contains(where: { $0.plannedScenes > 0 && !$0.modelAvailable }) { semanticRuntimeStatus = "model-unavailable" }
            else { semanticRuntimeStatus = vlmCalls > 0 ? "vlm-failed" : "incomplete-local" }
        } else if (successfulVLMScenes ?? 0) > 0 {
            semanticRuntimeStatus = "valid-vlm"
        } else {
            semanticRuntimeStatus = "valid-local-no-vlm"
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
            String(format: "%.2f s", computeDuration ?? 0),
            wallClockMeasurement ?? "unknown",
            speed,
            "\(decodedFrames)",
            "\(frameCacheHits)",
            "\(visionCalls)",
            "\(vlmCalls)",
            "\(vlmCacheHits ?? 0)",
            String(format: "%.2f s", vlmLatency),
            memory,
            cpu,
            thermalStates.joined(separator: ","),
            semanticRuntimeStatus,
            "\(successfulVLMScenes ?? 0)/\(plannedVLMScenes ?? 0)",
            "\(successfulVLMRechecks ?? 0)"
        ].joined(separator: "\t")
    }

    public static let tabSeparatedHeader = [
        "mode", "files", "source", "wall", "compute-sum", "wall-measurement", "speed", "decoded", "cache-hits",
        "vision", "vlm", "vlm-cache-hits", "vlm-latency", "peak-process-rss", "process-cpu", "thermal", "status", "vlm-scenes-completed/planned", "vlm-rechecks-completed"
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
