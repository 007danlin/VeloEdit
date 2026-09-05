import Foundation
import AVFoundation
import CoreGraphics

// MARK: - Automatic color management

public enum VideoTransferFunction: String, Codable, CaseIterable, Sendable {
    case rec709
    case hlg
    case pq
}

public struct VideoColorProfile: Codable, Hashable, Sendable {
    public var dynamicRange: DynamicRange
    public var transferFunction: VideoTransferFunction
    public var bitDepth: Int
    public var containsMixedDynamicRange: Bool

    public init(
        dynamicRange: DynamicRange,
        transferFunction: VideoTransferFunction,
        bitDepth: Int,
        containsMixedDynamicRange: Bool = false
    ) {
        self.dynamicRange = dynamicRange
        self.transferFunction = transferFunction
        self.bitDepth = max(8, bitDepth)
        self.containsMixedDynamicRange = containsMixedDynamicRange
    }

    public static let rec709 = VideoColorProfile(dynamicRange: .sdr, transferFunction: .rec709, bitDepth: 8)

    public var primaries: String { dynamicRange == .hdr ? "ITU_R_2020" : "ITU_R_709_2" }
    public var matrix: String { dynamicRange == .hdr ? "ITU_R_2020" : "ITU_R_709_2" }
}

public enum VideoColorPipeline {
    /// Resolves one color contract for both preview and export. Mixed projects
    /// use an HDR working surface when at least one selected source is HDR;
    /// Core Image then color-manages SDR sources into that surface.
    public static func profile(timeline: Timeline, assets: [MediaAsset]) -> VideoColorProfile {
        let usedIDs = Set(timeline.items.compactMap(\.assetID))
        let used = assets.filter { usedIDs.contains($0.id) && $0.kind == .video }
        let hasHDR = used.contains { $0.metadata.dynamicRange == .hdr }
        let hasSDR = used.contains { $0.metadata.dynamicRange == .sdr || $0.metadata.dynamicRange == .unknown }
        guard hasHDR else { return .rec709 }
        let pq = used.contains {
            $0.metadata.transferFunction?.localizedCaseInsensitiveContains("2084") == true ||
            $0.metadata.transferFunction?.localizedCaseInsensitiveContains("PQ") == true
        }
        return VideoColorProfile(
            dynamicRange: .hdr,
            transferFunction: pq ? .pq : .hlg,
            bitDepth: max(10, used.compactMap(\.metadata.bitDepth).max() ?? 10),
            containsMixedDynamicRange: hasSDR
        )
    }

    public static func cgColorSpace(for profile: VideoColorProfile) -> CGColorSpace {
        if profile.dynamicRange == .hdr {
            return CGColorSpace(name: CGColorSpace.itur_2020)
                ?? CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)
                ?? CGColorSpaceCreateDeviceRGB()
        }
        return CGColorSpace(name: CGColorSpace.itur_709)
            ?? CGColorSpace(name: CGColorSpace.sRGB)
            ?? CGColorSpaceCreateDeviceRGB()
    }
}

public struct PreviewExportSignature: Hashable, Sendable {
    public var aspectRatio: Double
    public var frameRate: Double
    public var colorProfile: VideoColorProfile
    public var effectCount: Int
    public var titleCount: Int
    public var telemetryCount: Int
    public var transitionCount: Int

    public init(timeline: Timeline, assets: [MediaAsset]) {
        aspectRatio = Double(max(1, timeline.width)) / Double(max(1, timeline.height))
        frameRate = timeline.frameRate
        colorProfile = VideoColorPipeline.profile(timeline: timeline, assets: assets)
        effectCount = timeline.effectiveEffects.filter(\.enabled).count
        titleCount = timeline.effectiveTitleItems.filter(\.enabled).count
        telemetryCount = timeline.effectiveTelemetryItems.count
        transitionCount = timeline.effectiveTransitionItems.filter(\.enabled).count
    }
}

public enum PreviewExportConsistencyContract {
    public static func issues(preview: PreviewExportSignature, export: PreviewExportSignature) -> [String] {
        var issues: [String] = []
        if abs(preview.aspectRatio - export.aspectRatio) > 0.000_1 { issues.append("Preview и экспорт используют разный aspect ratio.") }
        if abs(preview.frameRate - export.frameRate) > 0.001 { issues.append("Preview и экспорт используют разный FPS.") }
        if preview.colorProfile != export.colorProfile { issues.append("Preview и экспорт используют разные color-space настройки.") }
        if preview.effectCount != export.effectCount || preview.titleCount != export.titleCount ||
            preview.telemetryCount != export.telemetryCount || preview.transitionCount != export.transitionCount {
            issues.append("Preview и экспорт используют разные слои монтажа.")
        }
        return issues
    }
}

// MARK: - Export preflight

public enum ExportPreflightIssueKind: String, Codable, CaseIterable, Sendable {
    case missingSource, unreadableSource, corruptSource, invalidTimeline
    case insufficientDiskSpace, colorMismatch, unsafeTitle, unsafeCrop
    case audioClipping, quietSpeech, abruptVolume, missingResource
    case previewExportMismatch
}

public enum ExportPreflightSeverity: String, Codable, Sendable {
    case warning
    case blocking
}

public struct ExportPreflightIssue: Codable, Hashable, Sendable {
    public var kind: ExportPreflightIssueKind
    public var severity: ExportPreflightSeverity
    public var message: String
    public var assetID: UUID?

    public init(kind: ExportPreflightIssueKind, severity: ExportPreflightSeverity, message: String, assetID: UUID? = nil) {
        self.kind = kind
        self.severity = severity
        self.message = message
        self.assetID = assetID
    }
}

public struct ExportPreflightReport: Codable, Hashable, Sendable {
    public var colorProfile: VideoColorProfile
    public var estimatedOutputBytes: Int64
    public var availableBytes: Int64?
    public var issues: [ExportPreflightIssue]

    public var blockingIssues: [ExportPreflightIssue] { issues.filter { $0.severity == .blocking } }
    public var warnings: [ExportPreflightIssue] { issues.filter { $0.severity == .warning } }
    public var canExport: Bool { blockingIssues.isEmpty }

    public var conciseWarning: String? {
        guard !issues.isEmpty else { return nil }
        let first = issues[0].message
        return issues.count == 1 ? first : "\(first) Ещё проблем: \(issues.count - 1)."
    }
}

public enum ExportPreflightError: LocalizedError, Sendable {
    case blocked(ExportPreflightReport)

    public var errorDescription: String? {
        switch self {
        case .blocked(let report):
            return report.conciseWarning ?? "Экспорт остановлен проверкой проекта."
        }
    }
}

public struct ExportPreflight: Sendable {
    public init() {}

    public func inspect(
        timeline: Timeline,
        assets: [MediaAsset],
        analyses: [AnalysisResult] = [],
        destination: URL,
        quality: RenderQuality
    ) async -> ExportPreflightReport {
        let profile = VideoColorPipeline.profile(timeline: timeline, assets: assets)
        let estimate = Self.estimatedOutputBytes(timeline: timeline, quality: quality, profile: profile)
        let available = Self.availableCapacity(near: destination)
        let byID = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) })
        let usedIDs = Set(timeline.items.compactMap(\.assetID))
        var issues: [ExportPreflightIssue] = []

        if timeline.width < 2 || timeline.height < 2 || timeline.frameRate <= 0 || timeline.duration <= 0 {
            issues.append(.init(kind: .invalidTimeline, severity: .blocking, message: "Монтаж имеет некорректный размер, FPS или длительность."))
        }

        for id in usedIDs {
            guard let asset = byID[id] else {
                issues.append(.init(kind: .missingSource, severity: .blocking, message: "Один из исходников отсутствует в проекте.", assetID: id))
                continue
            }
            guard FileManager.default.fileExists(atPath: asset.originalURL.path) else {
                issues.append(.init(kind: .missingSource, severity: .blocking, message: "Не найден исходник «\(asset.displayName)».", assetID: id))
                continue
            }
            guard FileManager.default.isReadableFile(atPath: asset.originalURL.path) else {
                issues.append(.init(kind: .unreadableSource, severity: .blocking, message: "Нет доступа к исходнику «\(asset.displayName)».", assetID: id))
                continue
            }
            let actualSize = (try? asset.originalURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? Int(asset.byteSize)
            if actualSize <= 0 {
                issues.append(.init(kind: .corruptSource, severity: .blocking, message: "Исходник «\(asset.displayName)» пуст или повреждён.", assetID: id))
            }
        }

        if let available, available < estimate {
            issues.append(.init(
                kind: .insufficientDiskSpace,
                severity: .blocking,
                message: "Недостаточно места для экспорта: требуется примерно \(Self.storageString(estimate)), доступно \(Self.storageString(available))."
            ))
        }
        if profile.containsMixedDynamicRange {
            issues.append(.init(kind: .colorMismatch, severity: .warning, message: "В монтаже смешаны HDR и SDR. Экспорт будет выполнен в HDR с управляемым преобразованием SDR-кадров."))
        }

        for title in timeline.effectiveTitleItems where title.enabled {
            let x = title.style.effectiveXPosition
            let y = title.style.effectiveYPosition
            let scale = title.style.effectiveScale
            if x < 0.05 || x > 0.95 || y < 0.05 || y > 0.95 || scale > 2.5 {
                issues.append(.init(kind: .unsafeTitle, severity: .warning, message: "Титр «\(title.text)» может выходить за безопасную область."))
            }
        }
        for item in timeline.items where item.kind == .video {
            if let framing = item.effectiveVideoAdjustments.subjectReframe,
               (framing.startCenterX < 0.04 || framing.startCenterX > 0.96 || framing.endCenterX < 0.04 || framing.endCenterX > 0.96) {
                issues.append(.init(kind: .unsafeCrop, severity: .warning, message: "Кадрирование одного из клипов проходит слишком близко к краю."))
            }
        }

        for analysis in analyses where usedIDs.contains(analysis.assetID) {
            guard let audio = analysis.audioAnalysis else { continue }
            if audio.peakVolume >= 0.995 {
                issues.append(.init(kind: .audioClipping, severity: .warning, message: "В исходнике обнаружен риск перегрузки звука.", assetID: analysis.assetID))
            }
            if audio.speechProbability >= 0.45 && audio.meanVolume < 0.035 {
                issues.append(.init(kind: .quietSpeech, severity: .warning, message: "Речь в одном из клипов может быть слишком тихой.", assetID: analysis.assetID))
            }
            let peaks = audio.featureWindows?.map(\.peak) ?? []
            if zip(peaks, peaks.dropFirst()).contains(where: { abs($0 - $1) > 0.72 }) {
                issues.append(.init(kind: .abruptVolume, severity: .warning, message: "Обнаружен резкий скачок громкости.", assetID: analysis.assetID))
            }
        }

        return ExportPreflightReport(
            colorProfile: profile,
            estimatedOutputBytes: estimate,
            availableBytes: available,
            issues: Self.deduplicated(issues)
        )
    }

    public static func estimatedOutputBytes(timeline: Timeline, quality: RenderQuality, profile: VideoColorProfile) -> Int64 {
        let pixels = Double(max(2, timeline.width) * max(2, timeline.height))
        let fps = min(240, max(1, timeline.frameRate))
        let qualityFactor: Double
        switch quality {
        case .preview720p: qualityFactor = 0.55
        case .preview1080p: qualityFactor = 0.72
        case .final1080p: qualityFactor = 1
        case .final4K: qualityFactor = 1.28
        case .maximum: qualityFactor = 1.65
        }
        let hdrFactor = profile.dynamicRange == .hdr ? 1.45 : 1
        let bitsPerPixelPerFrame = 0.085 * qualityFactor * hdrFactor
        let video = pixels * fps * max(0.1, timeline.duration) * bitsPerPixelPerFrame / 8
        let audio = max(0.1, timeline.duration) * 32_000
        return Int64(max(8_000_000, (video + audio) * 1.25))
    }

    private static func availableCapacity(near destination: URL) -> Int64? {
        let directory = destination.deletingLastPathComponent()
        let values = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    private static func storageString(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private static func deduplicated(_ issues: [ExportPreflightIssue]) -> [ExportPreflightIssue] {
        var seen = Set<String>()
        return issues.filter { seen.insert("\($0.kind.rawValue):\($0.assetID?.uuidString ?? "-")").inserted }
    }
}

// MARK: - Persistent long-operation state

public enum PersistentJobKind: String, Codable, Sendable {
    case `import`, analysis, filmGeneration, render, export
}

public enum PersistentJobStage: String, Codable, Sendable {
    case queued, preflight, processing, completed, failed, cancelled
}

public struct PersistentJobState: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var kind: PersistentJobKind
    public var stage: PersistentJobStage
    public var completedUnits: Int
    public var totalUnits: Int
    public var resumableKey: String
    public var destinationPath: String?
    public var updatedAt: Date
    public var errorMessage: String?

    public init(
        id: UUID = UUID(),
        kind: PersistentJobKind,
        stage: PersistentJobStage = .queued,
        completedUnits: Int = 0,
        totalUnits: Int = 1,
        resumableKey: String,
        destinationPath: String? = nil,
        updatedAt: Date = Date(),
        errorMessage: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.stage = stage
        self.completedUnits = max(0, completedUnits)
        self.totalUnits = max(1, totalUnits)
        self.resumableKey = resumableKey
        self.destinationPath = destinationPath
        self.updatedAt = updatedAt
        self.errorMessage = errorMessage
    }
}

public actor PersistentJobStateStore {
    private let stateURL: URL

    public init(directory: URL) {
        self.stateURL = directory.appendingPathComponent("persistent-jobs.json")
    }

    public func states() -> [PersistentJobState] {
        guard let data = try? Data(contentsOf: stateURL) else { return [] }
        return (try? JSONDecoder.veloEdit.decode([PersistentJobState].self, from: data)) ?? []
    }

    public func save(_ state: PersistentJobState) throws {
        var values = states()
        if let index = values.firstIndex(where: { $0.id == state.id }) { values[index] = state }
        else { values.append(state) }
        // Keep a small audit trail without allowing multi-year projects to
        // accumulate an unbounded operational log.
        values = Array(values.sorted { $0.updatedAt > $1.updatedAt }.prefix(64))
        try FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder.veloEdit.encode(values).write(to: stateURL, options: .atomic)
    }

    public func unfinishedStates() -> [PersistentJobState] {
        states().filter { ![PersistentJobStage.completed, .cancelled].contains($0.stage) }
    }
}
