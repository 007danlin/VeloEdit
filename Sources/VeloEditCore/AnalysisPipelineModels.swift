import Foundation
import Darwin

public enum AnalysisStage: String, Codable, CaseIterable, Sendable, Hashable {
    case metadata
    case telemetry
    case proxy
    case fastInspection
    case sceneSegmentation
    case adaptiveSampling
    case localScoring
    case vision
    case vlm
    case audio
    case embeddings
    case subjectTracking
    case audioEvents
    case asr
    case momentRefinement
    case fusion
    case crossVideo
    case sourceOrdering
    case eventDiscovery
    case eventClustering
    case eventSceneDiscovery
    case persistence

    public var localizedTitle: String {
        switch self {
        case .metadata: return "Метаданные"
        case .telemetry: return "Телеметрия"
        case .proxy: return "Proxy"
        case .fastInspection: return "Быстрая проверка видео"
        case .sceneSegmentation: return "Определение сцен"
        case .adaptiveSampling: return "Адаптивная выборка"
        case .localScoring: return "Локальная оценка"
        case .vision: return "Apple Vision"
        case .vlm: return "Qwen3-VL"
        case .audio: return "Анализ звука"
        case .embeddings: return "Семантический индекс"
        case .subjectTracking: return "Главные объекты"
        case .audioEvents: return "Аудиособытия"
        case .asr: return "Локальная речь"
        case .momentRefinement: return "Границы моментов"
        case .fusion: return "Объединение результатов"
        case .crossVideo: return "Сравнение роликов"
        case .sourceOrdering: return "Хронология исходников"
        case .eventDiscovery: return "Поиск событий"
        case .eventClustering: return "Кластеризация событий"
        case .eventSceneDiscovery: return "Сцены внутри событий"
        case .persistence: return "Сохранение анализа"
        }
    }
}

public struct SceneAnalysis: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var startTime: Double
    public var endTime: Double
    public var semanticDescription: String?
    public var qualityScore: Double
    public var motionScore: Double
    public var actionScore: Double
    public var beautyScore: Double
    public var stabilityScore: Double
    public var sharpnessScore: Double
    public var audioScore: Double
    public var people: [String]
    public var objects: [String]
    public var location: String?
    public var telemetry: TelemetryMoment?
    public var highlights: [String]
    public var recommendedUses: [String]
    public var boundaryConfidence: Double

    public init(
        id: UUID = UUID(),
        startTime: Double,
        endTime: Double,
        semanticDescription: String? = nil,
        qualityScore: Double = 0.5,
        motionScore: Double = 0,
        actionScore: Double = 0,
        beautyScore: Double = 0.5,
        stabilityScore: Double = 0.5,
        sharpnessScore: Double = 0.5,
        audioScore: Double = 0,
        people: [String] = [],
        objects: [String] = [],
        location: String? = nil,
        telemetry: TelemetryMoment? = nil,
        highlights: [String] = [],
        recommendedUses: [String] = [],
        boundaryConfidence: Double = 0.5
    ) {
        self.id = id
        self.startTime = max(0, startTime)
        self.endTime = max(self.startTime, endTime)
        self.semanticDescription = semanticDescription
        self.qualityScore = qualityScore.clamped01
        self.motionScore = motionScore.clamped01
        self.actionScore = actionScore.clamped01
        self.beautyScore = beautyScore.clamped01
        self.stabilityScore = stabilityScore.clamped01
        self.sharpnessScore = sharpnessScore.clamped01
        self.audioScore = audioScore.clamped01
        self.people = people
        self.objects = objects
        self.location = location
        self.telemetry = telemetry
        self.highlights = highlights
        self.recommendedUses = recommendedUses
        self.boundaryConfidence = boundaryConfidence.clamped01
    }

    public var duration: Double { max(0, endTime - startTime) }
}

public struct AudioAnalysisSummary: Codable, Hashable, Sendable {
    public var analyzedDuration: Double
    public var meanVolume: Double
    public var peakVolume: Double
    public var silenceRatio: Double
    public var speechProbability: Double
    public var musicProbability: Double
    public var onsetRate: Double
    public var originalSoundQuality: Double
    public var waveform: [Double]
    public var onsetEnvelope: [Double]?
    public var featureWindows: [AudioFeatureWindow]?
    public var events: [AudioEventObservation]?
    public var estimatedBPM: Double?
    public var tempoConfidence: Double?

    public init(
        analyzedDuration: Double = 0,
        meanVolume: Double = 0,
        peakVolume: Double = 0,
        silenceRatio: Double = 1,
        speechProbability: Double = 0,
        musicProbability: Double = 0,
        onsetRate: Double = 0,
        originalSoundQuality: Double = 0,
        waveform: [Double] = [],
        onsetEnvelope: [Double]? = nil,
        featureWindows: [AudioFeatureWindow]? = nil,
        events: [AudioEventObservation]? = nil,
        estimatedBPM: Double? = nil,
        tempoConfidence: Double? = nil
    ) {
        self.analyzedDuration = max(0, analyzedDuration)
        self.meanVolume = meanVolume.clamped01
        self.peakVolume = peakVolume.clamped01
        self.silenceRatio = silenceRatio.clamped01
        self.speechProbability = speechProbability.clamped01
        self.musicProbability = musicProbability.clamped01
        self.onsetRate = max(0, onsetRate)
        self.originalSoundQuality = originalSoundQuality.clamped01
        self.waveform = waveform.map(\.clamped01)
        self.onsetEnvelope = onsetEnvelope?.map(\.clamped01)
        self.featureWindows = featureWindows
        self.events = events
        self.estimatedBPM = estimatedBPM.map { min(max(40, $0), 240) }
        self.tempoConfidence = tempoConfidence?.clamped01
    }
}

public struct AnalysisResourceSnapshot: Codable, Hashable, Sendable {
    public var residentMemoryBytes: UInt64?
    public var cpuTimeSeconds: Double?
    public var thermalState: String

    public static func capture() -> AnalysisResourceSnapshot {
        var usage = rusage()
        let status = getrusage(RUSAGE_SELF, &usage)
        let cpu: Double? = status == 0
            ? Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000
                + Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000
            : nil
        let memory: UInt64? = status == 0 ? UInt64(max(0, usage.ru_maxrss)) : nil
        return AnalysisResourceSnapshot(
            residentMemoryBytes: memory,
            cpuTimeSeconds: cpu,
            thermalState: ProcessInfo.processInfo.thermalState.analysisLabel
        )
    }
}

public struct AnalysisStageMetrics: Codable, Hashable, Sendable, Identifiable {
    public var id: AnalysisStage { stage }
    public var stage: AnalysisStage
    public var startedAt: Date
    public var endedAt: Date
    public var duration: TimeInterval
    public var workUnits: Int
    public var resourceStart: AnalysisResourceSnapshot
    public var resourceEnd: AnalysisResourceSnapshot
}

public struct AnalysisMetrics: Codable, Hashable, Sendable {
    public var startedAt: Date
    public var endedAt: Date
    public var totalDuration: TimeInterval
    public var stageMetrics: [AnalysisStageMetrics]
    public var frameCount: Int
    public var decodedFrameCount: Int
    public var analyzedFrameCount: Int
    public var frameCacheHitCount: Int
    public var visionCallCount: Int
    public var vlmCallCount: Int
    public var vlmLatency: TimeInterval
    public var queueWaitTime: TimeInterval
    public var hardwareIdentifier: String
    public var codec: String?
    public var resolution: String?
    public var mode: AIPowerMode
    public var thermalStates: [String]
}

public actor AnalysisMetricsRecorder {
    private struct ActiveStage: Sendable {
        let startedAt: Date
        let resource: AnalysisResourceSnapshot
    }

    private let startedAt = Date()
    private let mode: AIPowerMode
    private let codec: String?
    private let resolution: String?
    private var active: [AnalysisStage: ActiveStage] = [:]
    private var stages: [AnalysisStageMetrics] = []
    private var frameCount = 0
    private var decodedFrameCount = 0
    private var analyzedFrameCount = 0
    private var frameCacheHitCount = 0
    private var visionCallCount = 0
    private var vlmCallCount = 0
    private var vlmLatency: TimeInterval = 0
    private var queueWaitTime: TimeInterval = 0

    public init(mode: AIPowerMode, metadata: MediaMetadata) {
        self.mode = mode
        codec = metadata.codec
        if let width = metadata.width, let height = metadata.height {
            resolution = "\(width)x\(height)"
        } else {
            resolution = nil
        }
    }

    public func start(_ stage: AnalysisStage) {
        guard active[stage] == nil else { return }
        active[stage] = ActiveStage(startedAt: Date(), resource: .capture())
    }

    public func finish(_ stage: AnalysisStage, workUnits: Int = 0) {
        guard let start = active.removeValue(forKey: stage) else { return }
        let end = Date()
        stages.append(AnalysisStageMetrics(
            stage: stage,
            startedAt: start.startedAt,
            endedAt: end,
            duration: max(0, end.timeIntervalSince(start.startedAt)),
            workUnits: max(0, workUnits),
            resourceStart: start.resource,
            resourceEnd: .capture()
        ))
    }

    public func recordFrames(total: Int, decoded: Int, analyzed: Int, cacheHits: Int) {
        frameCount += max(0, total)
        decodedFrameCount += max(0, decoded)
        analyzedFrameCount += max(0, analyzed)
        frameCacheHitCount += max(0, cacheHits)
    }

    public func recordVisionCalls(_ count: Int) { visionCallCount += max(0, count) }

    public func recordVLMCall(latency: TimeInterval) {
        vlmCallCount += 1
        vlmLatency += max(0, latency)
    }

    public func recordQueueWait(_ duration: TimeInterval) {
        queueWaitTime += max(0, duration)
    }

    public func snapshot() -> AnalysisMetrics {
        for stage in Array(active.keys) { finish(stage) }
        let endedAt = Date()
        return AnalysisMetrics(
            startedAt: startedAt,
            endedAt: endedAt,
            totalDuration: max(0, endedAt.timeIntervalSince(startedAt)),
            stageMetrics: stages.sorted { $0.startedAt < $1.startedAt },
            frameCount: frameCount,
            decodedFrameCount: decodedFrameCount,
            analyzedFrameCount: analyzedFrameCount,
            frameCacheHitCount: frameCacheHitCount,
            visionCallCount: visionCallCount,
            vlmCallCount: vlmCallCount,
            vlmLatency: vlmLatency,
            queueWaitTime: queueWaitTime,
            hardwareIdentifier: Self.hardwareIdentifier,
            codec: codec,
            resolution: resolution,
            mode: mode,
            thermalStates: Array(Set(stages.flatMap { [$0.resourceStart.thermalState, $0.resourceEnd.thermalState] })).sorted()
        )
    }

    private static var hardwareIdentifier: String {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else {
            return "Apple Silicon"
        }
        var value = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &value, &size, nil, 0) == 0 else { return "Apple Silicon" }
        return String(cString: value)
    }
}

public struct AnalysisStageUpdate: Sendable {
    public var stage: AnalysisStage
    public var label: String
    public var fraction: Double
    public var currentScene: Int?
    public var sceneCount: Int?

    public init(stage: AnalysisStage, label: String? = nil, fraction: Double, currentScene: Int? = nil, sceneCount: Int? = nil) {
        self.stage = stage
        self.label = label ?? stage.localizedTitle
        self.fraction = fraction.clamped01
        self.currentScene = currentScene
        self.sceneCount = sceneCount
    }
}

public actor AnalysisETAEngine {
    private var completedDurations: [TimeInterval]
    private var currentStartedAt = Date()

    public init(history: [TimeInterval] = []) {
        completedDurations = history.filter { $0.isFinite && $0 > 0 }
    }

    public func startFile() { currentStartedAt = Date() }

    public func finishFile() {
        completedDurations.append(max(0.01, Date().timeIntervalSince(currentStartedAt)))
        if completedDurations.count > 50 { completedDurations.removeFirst(completedDurations.count - 50) }
    }

    public func estimate(fileFraction: Double, fileIndex: Int, totalFiles: Int, fallbackSecondsPerFile: TimeInterval) -> TimeInterval? {
        guard totalFiles > 0 else { return nil }
        let fraction = fileFraction.clamped01
        let elapsed = max(0.01, Date().timeIntervalSince(currentStartedAt))
        // Do not extrapolate from a few milliseconds of metadata work. The
        // fallback/history remains more honest until meaningful work elapsed.
        let projectedCurrent = fraction >= 0.08 && elapsed >= 0.5
            ? elapsed / fraction
            : fallbackSecondsPerFile
        let history = robustAverage(completedDurations) ?? projectedCurrent
        let smoothed = 0.60 * projectedCurrent + 0.40 * history
        let currentRemaining = smoothed * (1 - fraction)
        let queued = Double(max(0, totalFiles - fileIndex - 1)) * history
        return max(0, currentRemaining + queued)
    }

    private func robustAverage(_ values: [TimeInterval]) -> TimeInterval? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let median = sorted[sorted.count / 2]
        var ema = values[0]
        for value in values.dropFirst() { ema = 0.28 * value + 0.72 * ema }
        return 0.55 * median + 0.45 * ema
    }
}

public actor AnalysisProgressReporter {
    private let callback: (@Sendable (ImportProgress) -> Void)?
    private let eta: AnalysisETAEngine
    private let fileIndex: Int
    private let fileCount: Int
    private let totalUnits: Int
    private let fallbackSecondsPerFile: TimeInterval

    public init(
        callback: (@Sendable (ImportProgress) -> Void)?,
        eta: AnalysisETAEngine,
        fileIndex: Int,
        fileCount: Int,
        fallbackSecondsPerFile: TimeInterval
    ) {
        self.callback = callback
        self.eta = eta
        self.fileIndex = fileIndex
        self.fileCount = fileCount
        totalUnits = fileCount * 100
        self.fallbackSecondsPerFile = fallbackSecondsPerFile
    }

    public func publish(_ update: AnalysisStageUpdate, fileName: String, thermalThrottled: Bool = false) async {
        let fraction = update.fraction.clamped01
        let remaining = await eta.estimate(
            fileFraction: fraction,
            fileIndex: fileIndex,
            totalFiles: fileCount,
            fallbackSecondsPerFile: fallbackSecondsPerFile
        )
        callback?(ImportProgress(
            completed: fileIndex * 100 + Int((fraction * 100).rounded(.down)),
            total: totalUnits,
            currentName: "\(update.label) · \(fileName)",
            currentFileName: fileName,
            analysisStage: update.stage,
            currentFileIndex: fileIndex + 1,
            fileCount: fileCount,
            currentSceneIndex: update.currentScene,
            sceneCount: update.sceneCount,
            estimatedSecondsRemaining: remaining,
            thermalThrottled: thermalThrottled
        ))
    }
}

public enum AnalysisQueuePriority: Int, Codable, Comparable, Sendable, Hashable {
    case low = 0
    case normal = 1
    case high = 2

    public static func < (lhs: AnalysisQueuePriority, rhs: AnalysisQueuePriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public enum AnalysisQueueStatus: String, Codable, Sendable, Hashable {
    case queued
    case running
    case completed
    case cancelled
    case failed
}

public struct AnalysisQueueEntry: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var assetID: UUID
    public var priority: AnalysisQueuePriority
    public var status: AnalysisQueueStatus
    public var enqueuedAt: Date
    public var startedAt: Date?
    public var completedAt: Date?
    public var errorMessage: String?

    public init(
        id: UUID = UUID(),
        assetID: UUID,
        priority: AnalysisQueuePriority = .normal,
        status: AnalysisQueueStatus = .queued,
        enqueuedAt: Date = Date(),
        startedAt: Date? = nil,
        completedAt: Date? = nil,
        errorMessage: String? = nil
    ) {
        self.id = id
        self.assetID = assetID
        self.priority = priority
        self.status = status
        self.enqueuedAt = enqueuedAt
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.errorMessage = errorMessage
    }
}

public actor AnalysisBackgroundQueue {
    private var entries: [AnalysisQueueEntry] = []

    public init() {}

    public func replace(with assets: [MediaAsset], preferredAssetID: UUID?) -> [AnalysisQueueEntry] {
        entries = assets.map {
            AnalysisQueueEntry(assetID: $0.id, priority: $0.id == preferredAssetID ? .high : .normal)
        }
        return snapshot()
    }

    public func next() -> AnalysisQueueEntry? {
        guard let index = entries.indices
            .filter({ entries[$0].status == .queued })
            .sorted(by: {
                let lhs = entries[$0]
                let rhs = entries[$1]
                return lhs.priority == rhs.priority ? lhs.enqueuedAt < rhs.enqueuedAt : lhs.priority > rhs.priority
            })
            .first else { return nil }
        entries[index].status = .running
        entries[index].startedAt = Date()
        return entries[index]
    }

    public func promote(assetID: UUID) {
        guard let index = entries.firstIndex(where: { $0.assetID == assetID && $0.status == .queued }) else { return }
        entries[index].priority = .high
    }

    public func complete(assetID: UUID) {
        updateTerminal(assetID: assetID, status: .completed, error: nil)
    }

    public func fail(assetID: UUID, error: String) {
        updateTerminal(assetID: assetID, status: .failed, error: error)
    }

    public func cancel(assetID: UUID) {
        updateTerminal(assetID: assetID, status: .cancelled, error: nil)
    }

    public func cancelAll() {
        for index in entries.indices where entries[index].status == .queued || entries[index].status == .running {
            entries[index].status = .cancelled
            entries[index].completedAt = Date()
        }
    }

    public func isCancelled(assetID: UUID) -> Bool {
        entries.first(where: { $0.assetID == assetID })?.status == .cancelled
    }

    public func snapshot() -> [AnalysisQueueEntry] { entries }

    private func updateTerminal(assetID: UUID, status: AnalysisQueueStatus, error: String?) {
        guard let index = entries.firstIndex(where: { $0.assetID == assetID }) else { return }
        entries[index].status = status
        entries[index].completedAt = Date()
        entries[index].errorMessage = error
    }
}

public struct CrossVideoRelationshipAnalyzer: Sendable {
    public init() {}

    public func refine(_ analyses: [AnalysisResult]) -> [AnalysisResult] {
        var result = analyses
        let allCandidates = result.flatMap(\.candidates)
        let semanticIndex = SemanticSceneIndex(candidates: allCandidates)
        let embeddedClusters = semanticIndex.clusters(threshold: 0.88).filter { cluster in
            let assets = Set(cluster.candidateIDs.compactMap { id in allCandidates.first(where: { $0.id == id })?.assetID })
            return assets.count > 1
        }
        var embeddedDuplicateIDs: Set<UUID> = []
        for cluster in embeddedClusters {
            for id in cluster.candidateIDs where id != cluster.bestCandidateID { embeddedDuplicateIDs.insert(id) }
            for analysisIndex in result.indices {
                for candidateIndex in result[analysisIndex].candidates.indices
                where cluster.candidateIDs.contains(result[analysisIndex].candidates[candidateIndex].id) {
                    var insight = result[analysisIndex].candidates[candidateIndex].insights
                    insight?.semanticEventID = cluster.id
                    insight?.bestTakeScore = SemanticSceneIndex.bestTakeScore(result[analysisIndex].candidates[candidateIndex])
                    result[analysisIndex].candidates[candidateIndex].insights = insight
                    if result[analysisIndex].candidates[candidateIndex].id == cluster.bestCandidateID {
                        result[analysisIndex].candidates[candidateIndex].scores.uniqueness = max(
                            0.82,
                            result[analysisIndex].candidates[candidateIndex].scores.uniqueness
                        )
                    }
                }
            }
        }
        var seen: [(analysisIndex: Int, candidateIndex: Int)] = []
        for analysisIndex in result.indices {
            for candidateIndex in result[analysisIndex].candidates.indices {
                let currentID = result[analysisIndex].candidates[candidateIndex].id
                if embeddedDuplicateIDs.contains(currentID) {
                    let nearest = semanticIndex.nearest(to: result[analysisIndex].candidates[candidateIndex], limit: 1, excludingSameAsset: true).first?.similarity ?? 0.88
                    result[analysisIndex].candidates[candidateIndex].scores.uniqueness = max(0.10, min(0.24, 1 - nearest))
                    let explanation = "Embedding index: near-duplicate события в другом ролике; выбран более сильный дубль."
                    if !result[analysisIndex].candidates[candidateIndex].explanation.contains(explanation) {
                        result[analysisIndex].candidates[candidateIndex].explanation.append(explanation)
                    }
                    if result[analysisIndex].deepMediaDiagnostics != nil {
                        result[analysisIndex].deepMediaDiagnostics?.nearDuplicateCandidateIDs.append(currentID)
                        result[analysisIndex].deepMediaDiagnostics?.discardedCandidateIDs.append(currentID)
                    }
                    seen.append((analysisIndex, candidateIndex))
                    continue
                }
                var bestSimilarity = 0.0
                for prior in seen where result[prior.analysisIndex].assetID != result[analysisIndex].assetID {
                    let lhs = result[analysisIndex].candidates[candidateIndex]
                    let rhs = result[prior.analysisIndex].candidates[prior.candidateIndex]
                    bestSimilarity = max(bestSimilarity, semanticIndex.similarity(between: lhs, and: rhs))
                }
                if bestSimilarity >= 0.78 {
                    result[analysisIndex].candidates[candidateIndex].scores.uniqueness = max(0.15, 1 - bestSimilarity)
                    let explanation = "Похожий момент найден в другом ролике; AI Director выберет лучший дубль."
                    if !result[analysisIndex].candidates[candidateIndex].explanation.contains(explanation) {
                        result[analysisIndex].candidates[candidateIndex].explanation.append(explanation)
                    }
                }
                seen.append((analysisIndex, candidateIndex))
            }
        }
        for index in result.indices {
            guard var diagnostics = result[index].deepMediaDiagnostics else { continue }
            let nearDuplicateIDs = Array(Set(diagnostics.nearDuplicateCandidateIDs))
            let discardedIDs = Array(Set(diagnostics.discardedCandidateIDs))
            diagnostics.nearDuplicateCandidateIDs = nearDuplicateIDs
            diagnostics.discardedCandidateIDs = discardedIDs
            result[index].deepMediaDiagnostics = diagnostics
        }
        return result
    }
}

extension ProcessInfo.ThermalState {
    var analysisLabel: String {
        switch self {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }
}
