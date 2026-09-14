import Foundation

public enum MediaKind: String, Codable, Sendable, CaseIterable {
    case video
    case photo
}

public enum DynamicRange: String, Codable, Sendable {
    case sdr
    case hdr
    case unknown
}

public enum MediaDateSource: String, Codable, Sendable {
    case embeddedMetadata = "embedded-metadata"
    case fileCreationDate = "file-creation-date"
    case fileModificationDate = "file-modification-date"
    case importDate = "import-date"
}

public struct MediaMetadata: Codable, Hashable, Sendable {
    public var duration: Double?
    public var width: Int?
    public var height: Int?
    public var frameRate: Double?
    public var codec: String?
    public var dynamicRange: DynamicRange
    /// Source color tags are persisted instead of being rediscovered at every
    /// preview/export. Optional values keep old project packages decodable.
    public var colorPrimaries: String?
    public var transferFunction: String?
    public var yCbCrMatrix: String?
    public var bitDepth: Int?
    public var hasAudio: Bool
    public var creationDate: Date?
    /// File modification time is intentionally retained only as a fallback for
    /// archives whose camera capture timestamp is unavailable.
    public var modificationDate: Date?
    public var timeZoneIdentifier: String?
    public var dateSource: MediaDateSource?
    public var dateConfidence: Double?
    public var latitude: Double?
    public var longitude: Double?
    public var cameraMake: String?
    public var cameraModel: String?
    public var orientationDegrees: Int

    public init(
        duration: Double? = nil,
        width: Int? = nil,
        height: Int? = nil,
        frameRate: Double? = nil,
        codec: String? = nil,
        dynamicRange: DynamicRange = .unknown,
        colorPrimaries: String? = nil,
        transferFunction: String? = nil,
        yCbCrMatrix: String? = nil,
        bitDepth: Int? = nil,
        hasAudio: Bool = false,
        creationDate: Date? = nil,
        modificationDate: Date? = nil,
        timeZoneIdentifier: String? = nil,
        dateSource: MediaDateSource? = nil,
        dateConfidence: Double? = nil,
        latitude: Double? = nil,
        longitude: Double? = nil,
        cameraMake: String? = nil,
        cameraModel: String? = nil,
        orientationDegrees: Int = 0
    ) {
        self.duration = duration
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.codec = codec
        self.dynamicRange = dynamicRange
        self.colorPrimaries = colorPrimaries
        self.transferFunction = transferFunction
        self.yCbCrMatrix = yCbCrMatrix
        self.bitDepth = bitDepth
        self.hasAudio = hasAudio
        self.creationDate = creationDate
        self.modificationDate = modificationDate
        self.timeZoneIdentifier = timeZoneIdentifier
        self.dateSource = dateSource
        self.dateConfidence = dateConfidence?.clamped01
        self.latitude = latitude
        self.longitude = longitude
        self.cameraMake = cameraMake
        self.cameraModel = cameraModel
        self.orientationDegrees = orientationDegrees
    }

    public var effectiveCaptureDate: Date? { creationDate ?? modificationDate }
}

public struct MediaAsset: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var originalURL: URL
    public var bookmarkData: Data?
    public var displayName: String
    public var kind: MediaKind
    public var byteSize: Int64
    /// Fast bounded-read identity used to make import immediate.
    public var contentHash: String
    /// Full-file SHA-256, populated only by an explicit/background integrity pass.
    public var fullContentHash: String?
    public var metadata: MediaMetadata
    public var importedAt: Date
    public var favorite: Bool
    public var excluded: Bool
    public var missing: Bool

    public init(
        id: UUID = UUID(),
        originalURL: URL,
        bookmarkData: Data? = nil,
        displayName: String? = nil,
        kind: MediaKind,
        byteSize: Int64,
        contentHash: String,
        fullContentHash: String? = nil,
        metadata: MediaMetadata,
        importedAt: Date = Date(),
        favorite: Bool = false,
        excluded: Bool = false,
        missing: Bool = false
    ) {
        self.id = id
        self.originalURL = originalURL
        self.bookmarkData = bookmarkData
        self.displayName = displayName ?? originalURL.lastPathComponent
        self.kind = kind
        self.byteSize = byteSize
        self.contentHash = contentHash
        self.fullContentHash = fullContentHash
        self.metadata = metadata
        self.importedAt = importedAt
        self.favorite = favorite
        self.excluded = excluded
        self.missing = missing
    }

    /// Display-oriented dimensions used by framing and rendering decisions.
    /// Video metadata is normalized by `MediaImporter` with the preferred
    /// transform already applied. Photo metadata keeps the raw pixel size and
    /// stores EXIF orientation separately, so only photos need a 90/270 swap.
    public var displayDimensions: (width: Int, height: Int)? {
        guard let width = metadata.width,
              let height = metadata.height,
              width > 0,
              height > 0 else { return nil }
        let normalizedOrientation = ((metadata.orientationDegrees % 360) + 360) % 360
        if kind == .photo, normalizedOrientation == 90 || normalizedOrientation == 270 {
            return (height, width)
        }
        return (width, height)
    }

    public var displayAspectRatio: Double? {
        guard let dimensions = displayDimensions else { return nil }
        return Double(dimensions.width) / Double(dimensions.height)
    }
}

public struct ClipScores: Codable, Hashable, Sendable {
    public var quality: Double
    public var interest: Double
    public var action: Double
    public var stability: Double
    public var uniqueness: Double

    public init(quality: Double, interest: Double, action: Double, stability: Double, uniqueness: Double = 1) {
        self.quality = quality.clamped01
        self.interest = interest.clamped01
        self.action = action.clamped01
        self.stability = stability.clamped01
        self.uniqueness = uniqueness.clamped01
    }

    public var composite: Double {
        (quality * 0.30) + (interest * 0.30) + (action * 0.20) + (stability * 0.10) + (uniqueness * 0.10)
    }
}

public enum EditorialMomentPhase: String, Codable, CaseIterable, Hashable, Sendable {
    case anticipation, action, peak, completion, reaction
}

public struct EditorialSourceRange: Codable, Hashable, Sendable {
    public var start: Double
    public var end: Double
    public var phase: EditorialMomentPhase?
    public var reason: String?
    public var confidence: Double

    public init(start: Double, end: Double, phase: EditorialMomentPhase? = nil, reason: String? = nil, confidence: Double = 1) {
        self.start = max(0, start)
        self.end = max(self.start, end)
        self.phase = phase
        self.reason = reason?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.confidence = confidence.clamped01
    }

    public var duration: Double { end - start }
    public func contains(_ time: Double) -> Bool { time > start && time < end }
}

/// Source-timeline phases of one editorial moment. Optional fine-grained
/// markers keep old project packages decodable while letting every downstream
/// editor distinguish action, completion and the reaction that follows it.
public struct MomentBoundary: Codable, Hashable, Sendable {
    public var anticipationStart: Double
    public var actionStart: Double?
    public var peakTime: Double
    public var actionEnd: Double?
    public var reactionStart: Double?
    public var reactionEnd: Double?
    public var completionEnd: Double
    public var doNotCutRanges: [EditorialSourceRange]?
    public var confidence: Double
    public var evidence: [String]

    public init(
        anticipationStart: Double,
        actionStart: Double? = nil,
        peakTime: Double,
        actionEnd: Double? = nil,
        reactionStart: Double? = nil,
        reactionEnd: Double? = nil,
        completionEnd: Double,
        doNotCutRanges: [EditorialSourceRange]? = nil,
        confidence: Double,
        evidence: [String] = []
    ) {
        let start = max(0, anticipationStart)
        let end = max(start, max(completionEnd, reactionEnd ?? 0))
        let peak = min(max(start, peakTime), end)
        self.anticipationStart = start
        self.actionStart = actionStart.map { min(peak, max(start, $0)) }
        self.peakTime = peak
        self.actionEnd = actionEnd.map { min(end, max(peak, $0)) }
        let resolvedActionEnd = self.actionEnd ?? peak
        self.reactionStart = reactionStart.map { min(end, max(resolvedActionEnd, $0)) }
        let resolvedReactionStart = self.reactionStart ?? resolvedActionEnd
        self.reactionEnd = reactionEnd.map { min(end, max(resolvedReactionStart, $0)) }
        self.completionEnd = end
        let safeRanges = (doNotCutRanges ?? []).compactMap { range -> EditorialSourceRange? in
            let lower = min(end, max(start, range.start))
            let upper = min(end, max(lower, range.end))
            guard upper - lower >= 0.04 else { return nil }
            return EditorialSourceRange(start: lower, end: upper, phase: range.phase, reason: range.reason, confidence: range.confidence)
        }
        self.doNotCutRanges = safeRanges.isEmpty ? nil : safeRanges
        self.confidence = confidence.clamped01
        self.evidence = evidence
    }

    public var duration: Double { max(0, completionEnd - anticipationStart) }
    public var effectiveActionStart: Double { actionStart ?? min(peakTime, anticipationStart + duration * 0.34) }
    public var effectiveActionEnd: Double { actionEnd ?? max(peakTime, completionEnd - duration * 0.28) }
    public var effectiveReactionStart: Double { reactionStart ?? effectiveActionEnd }
    public var effectiveReactionEnd: Double { reactionEnd ?? completionEnd }

    public func phase(at time: Double) -> EditorialMomentPhase? {
        guard time >= anticipationStart, time <= completionEnd else { return nil }
        if time < effectiveActionStart { return .anticipation }
        if time < peakTime { return .action }
        if abs(time - peakTime) <= 0.04 { return .peak }
        if time < effectiveReactionStart { return .completion }
        return .reaction
    }

    public func containsProtectedCut(_ time: Double) -> Bool {
        (doNotCutRanges ?? []).contains { $0.confidence >= 0.42 && $0.contains(time) }
    }
}

/// Semantic and technical evidence attached to one source range. All values
/// are measured or inferred during proxy-first analysis; the original media is
/// never modified. The optional property on `Candidate` keeps older projects
/// backward compatible.
public struct CandidateInsights: Codable, Hashable, Sendable {
    public var editorialEvidence: EditorialEvidence?
    public var sceneSummary: String?
    public var emotion: String?
    public var dynamics: Double
    public var visualAppeal: Double
    public var composition: Double
    public var sharpness: Double
    public var motionBlur: Double
    public var noise: Double
    public var shake: Double
    public var exposureQuality: Double
    public var slowMotionSuitability: Double
    public var speedRampSuitability: Double
    public var originalAudioUsefulness: Double
    public var storyValue: Double
    public var roleScores: [StoryRole: Double]
    /// Optional P2 evidence keeps old project packages backward compatible.
    public var visualEmbedding: VisualEmbedding?
    public var semanticEventID: String?
    public var bestTakeScore: Double?
    public var subjectTracking: SubjectTrackingSummary?
    public var speech: SpeechEditingEvidence?
    public var audioEvents: [AudioEventObservation]?
    public var audioQuality: Double?

    public init(
        sceneSummary: String? = nil,
        emotion: String? = nil,
        dynamics: Double = 0.5,
        visualAppeal: Double = 0.5,
        composition: Double = 0.5,
        sharpness: Double = 0.5,
        motionBlur: Double = 0,
        noise: Double = 0,
        shake: Double = 0,
        exposureQuality: Double = 0.5,
        slowMotionSuitability: Double = 0,
        speedRampSuitability: Double = 0,
        originalAudioUsefulness: Double = 0,
        storyValue: Double = 0.5,
        roleScores: [StoryRole: Double] = [:],
        visualEmbedding: VisualEmbedding? = nil,
        semanticEventID: String? = nil,
        bestTakeScore: Double? = nil,
        subjectTracking: SubjectTrackingSummary? = nil,
        speech: SpeechEditingEvidence? = nil,
        audioEvents: [AudioEventObservation]? = nil,
        audioQuality: Double? = nil
    ) {
        self.sceneSummary = sceneSummary?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.emotion = emotion?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.dynamics = dynamics.clamped01
        self.visualAppeal = visualAppeal.clamped01
        self.composition = composition.clamped01
        self.sharpness = sharpness.clamped01
        self.motionBlur = motionBlur.clamped01
        self.noise = noise.clamped01
        self.shake = shake.clamped01
        self.exposureQuality = exposureQuality.clamped01
        self.slowMotionSuitability = slowMotionSuitability.clamped01
        self.speedRampSuitability = speedRampSuitability.clamped01
        self.originalAudioUsefulness = originalAudioUsefulness.clamped01
        self.storyValue = storyValue.clamped01
        self.roleScores = roleScores.mapValues(\.clamped01)
        self.visualEmbedding = visualEmbedding
        self.semanticEventID = semanticEventID
        self.bestTakeScore = bestTakeScore?.clamped01
        self.subjectTracking = subjectTracking
        self.speech = speech
        self.audioEvents = audioEvents
        self.audioQuality = audioQuality?.clamped01
    }
}

public struct Candidate: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var assetID: UUID
    public var sourceStart: Double
    public var sourceDuration: Double
    public var scores: ClipScores
    public var tags: Set<String>
    public var explanation: [String]
    public var insights: CandidateInsights?
    public var momentBoundary: MomentBoundary?
    public var locked: Bool
    public var excluded: Bool

    public init(
        id: UUID = UUID(),
        assetID: UUID,
        sourceStart: Double,
        sourceDuration: Double,
        scores: ClipScores,
        tags: Set<String> = [],
        explanation: [String] = [],
        insights: CandidateInsights? = nil,
        momentBoundary: MomentBoundary? = nil,
        locked: Bool = false,
        excluded: Bool = false
    ) {
        self.id = id
        self.assetID = assetID
        self.sourceStart = max(0, sourceStart)
        self.sourceDuration = max(0, sourceDuration)
        self.scores = scores
        self.tags = tags
        self.explanation = explanation
        self.insights = insights
        self.momentBoundary = momentBoundary
        self.locked = locked
        self.excluded = excluded
    }
}

public enum StoryRole: String, Codable, CaseIterable, Identifiable, Sendable {
    case intro
    case setup
    case buildup = "build-up"
    case action
    case climax
    case reaction
    case outro
    case bRoll = "b-roll"

    public var id: String { rawValue }
    public var localizedTitle: String {
        switch self {
        case .intro: return "Вступление"
        case .setup: return "Завязка"
        case .buildup: return "Развитие"
        case .action: return "Действие"
        case .climax: return "Кульминация"
        case .reaction: return "Реакция"
        case .outro: return "Финал"
        case .bRoll: return "B-roll"
        }
    }
}

public struct AnalysisResult: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID { assetID }
    public var assetID: UUID
    public var schemaVersion: Int
    public var analyzedContentHash: String
    public var analyzedAt: Date
    public var sceneTags: Set<String>
    public var candidates: [Candidate]
    public var warnings: [String]
    public var telemetry: TelemetrySummary?
    public var analysisProfileKey: String?
    public var usedProxy: Bool?
    public var sampledFrameCount: Int?
    public var deepAnalyzedCandidateCount: Int?
    public var aiRuntimeLabel: String?
    /// Optional v4 fields keep project packages from earlier builds decodable.
    public var completedDepth: AnalysisDepth?
    public var scenes: [SceneAnalysis]?
    public var audioAnalysis: AudioAnalysisSummary?
    public var metrics: AnalysisMetrics?
    public var deepMediaVersion: Int?
    public var deepMediaDiagnostics: DeepMediaDiagnostics?

    public init(assetID: UUID, schemaVersion: Int = 1, analyzedContentHash: String, analyzedAt: Date = Date(), sceneTags: Set<String> = [], candidates: [Candidate], warnings: [String] = [], telemetry: TelemetrySummary? = nil, analysisProfileKey: String? = nil, usedProxy: Bool? = nil, sampledFrameCount: Int? = nil, deepAnalyzedCandidateCount: Int? = nil, aiRuntimeLabel: String? = nil, completedDepth: AnalysisDepth? = nil, scenes: [SceneAnalysis]? = nil, audioAnalysis: AudioAnalysisSummary? = nil, metrics: AnalysisMetrics? = nil, deepMediaVersion: Int? = nil, deepMediaDiagnostics: DeepMediaDiagnostics? = nil) {
        self.assetID = assetID
        self.schemaVersion = schemaVersion
        self.analyzedContentHash = analyzedContentHash
        self.analyzedAt = analyzedAt
        self.sceneTags = sceneTags
        self.candidates = candidates
        self.warnings = warnings
        self.telemetry = telemetry
        self.analysisProfileKey = analysisProfileKey
        self.usedProxy = usedProxy
        self.sampledFrameCount = sampledFrameCount
        self.deepAnalyzedCandidateCount = deepAnalyzedCandidateCount
        self.aiRuntimeLabel = aiRuntimeLabel
        self.completedDepth = completedDepth
        self.scenes = scenes
        self.audioAnalysis = audioAnalysis
        self.metrics = metrics
        self.deepMediaVersion = deepMediaVersion
        self.deepMediaDiagnostics = deepMediaDiagnostics
    }

    public func satisfies(_ profile: AIAnalysisProfile) -> Bool {
        (completedDepth ?? .quick) >= profile.targetDepth
    }

    /// Scene analysis is the canonical evidence used by AI Director. Existing
    /// candidates remain the editable selection units, but their ranking and
    /// semantics are projected from the overlapping scene before directing.
    public var directorCandidates: [Candidate] {
        guard let scenes, !scenes.isEmpty else { return candidates }
        return candidates.map { candidate in
            guard let scene = scenes.max(by: {
                Self.overlap(candidate: candidate, scene: $0) < Self.overlap(candidate: candidate, scene: $1)
            }), Self.overlap(candidate: candidate, scene: scene) > 0 else { return candidate }
            var enriched = candidate
            enriched.scores.quality = (enriched.scores.quality * 0.45 + scene.qualityScore * 0.55).clamped01
            enriched.scores.interest = (enriched.scores.interest * 0.35 + scene.beautyScore * 0.35 + scene.actionScore * 0.30).clamped01
            enriched.scores.action = (enriched.scores.action * 0.40 + scene.actionScore * 0.60).clamped01
            enriched.scores.stability = (enriched.scores.stability * 0.40 + scene.stabilityScore * 0.60).clamped01
            enriched.tags.formUnion(scene.people)
            enriched.tags.formUnion(scene.objects)
            enriched.tags.formUnion(scene.highlights)
            enriched.tags.formUnion(scene.recommendedUses)
            if let location = scene.location, !location.isEmpty { enriched.tags.insert(location) }
            if let summary = scene.semanticDescription, !summary.isEmpty,
               !enriched.explanation.contains(summary) {
                enriched.explanation.append(summary)
            }
            return enriched
        }
    }

    private static func overlap(candidate: Candidate, scene: SceneAnalysis) -> Double {
        max(0, min(candidate.sourceStart + candidate.sourceDuration, scene.endTime) - max(candidate.sourceStart, scene.startTime))
    }
}

public struct TelemetrySummary: Codable, Hashable, Sendable {
    public var hasGPMF: Bool
    public var sampleCount: Int
    public var maxSpeedMetersPerSecond: Double?
    public var distanceMeters: Double?
    public var minAltitudeMeters: Double?
    public var maxAltitudeMeters: Double?
    public var maxGForce: Double?
    public var route: [TelemetryCoordinate]?
    public var speedSamplesMetersPerSecond: [Double]?
    public var altitudeSamplesMeters: [Double]?
    /// Sensor values aligned to the source video's timeline. Older project
    /// manifests do not contain this optional field and remain decodable.
    public var timedSamples: [TelemetrySample]?
    public var streams: Set<String>
    /// Source format/provenance for external telemetry. Optional for projects
    /// created before the unified Telemetry Engine was introduced.
    public var sourceFormat: String?

    public init(hasGPMF: Bool = false, sampleCount: Int = 0, maxSpeedMetersPerSecond: Double? = nil, distanceMeters: Double? = nil, minAltitudeMeters: Double? = nil, maxAltitudeMeters: Double? = nil, maxGForce: Double? = nil, route: [TelemetryCoordinate]? = nil, speedSamplesMetersPerSecond: [Double]? = nil, altitudeSamplesMeters: [Double]? = nil, timedSamples: [TelemetrySample]? = nil, streams: Set<String> = [], sourceFormat: String? = nil) {
        self.hasGPMF = hasGPMF
        self.sampleCount = sampleCount
        self.maxSpeedMetersPerSecond = maxSpeedMetersPerSecond
        self.distanceMeters = distanceMeters
        self.minAltitudeMeters = minAltitudeMeters
        self.maxAltitudeMeters = maxAltitudeMeters
        self.maxGForce = maxGForce
        self.route = route
        self.speedSamplesMetersPerSecond = speedSamplesMetersPerSecond
        self.altitudeSamplesMeters = altitudeSamplesMeters
        self.timedSamples = timedSamples
        self.streams = streams
        self.sourceFormat = sourceFormat
    }

    public var hasTelemetry: Bool { hasGPMF || sampleCount > 0 || timedSamples?.isEmpty == false }
}

public struct TelemetrySample: Codable, Hashable, Sendable {
    public var timestamp: Double
    public var speedMetersPerSecond: Double?
    public var altitudeMeters: Double?
    public var gForce: Double?
    public var coordinate: TelemetryCoordinate?
    public var distanceMeters: Double?
    public var accelerationMetersPerSecondSquared: Double?
    public var gForceX: Double?
    public var gForceY: Double?
    public var gForceZ: Double?
    public var gyroX: Double?
    public var gyroY: Double?
    public var gyroZ: Double?
    public var headingDegrees: Double?
    public var heartRateBPM: Double?
    public var cadenceRPM: Double?
    public var powerWatts: Double?
    public var leanAngleDegrees: Double?
    public var rpm: Double?
    public var throttlePercent: Double?
    public var brakePercent: Double?
    public var lapNumber: Double?
    public var lapTimeSeconds: Double?
    public var temperatureCelsius: Double?
    public var gradientPercent: Double?
    public var verticalSpeedMetersPerSecond: Double?
    public var torqueNewtonMeters: Double?
    public var gear: Double?
    public var calories: Double?
    public var airPressureHPA: Double?
    public var strideLengthMeters: Double?
    public var verticalOscillationCentimeters: Double?
    public var groundContactTimeMilliseconds: Double?
    public var leftRightBalancePercent: Double?
    public var strokeRate: Double?
    public var cameraISO: Double?
    public var cameraAperture: Double?
    public var cameraShutterSeconds: Double?
    public var cameraFocalLengthMM: Double?
    public var cameraEV: Double?
    public var cameraColorTemperatureKelvin: Double?
    /// Numeric vendor/developer fields that do not yet have a standard widget.
    /// Keeping them here prevents lossy normalization and lets future OVRLEY
    /// releases expose them without reimporting the source file.
    public var customFields: [String: Double]?

    public init(
        timestamp: Double,
        speedMetersPerSecond: Double? = nil,
        altitudeMeters: Double? = nil,
        gForce: Double? = nil,
        coordinate: TelemetryCoordinate? = nil,
        distanceMeters: Double? = nil,
        accelerationMetersPerSecondSquared: Double? = nil,
        gForceX: Double? = nil,
        gForceY: Double? = nil,
        gForceZ: Double? = nil,
        gyroX: Double? = nil,
        gyroY: Double? = nil,
        gyroZ: Double? = nil,
        headingDegrees: Double? = nil,
        heartRateBPM: Double? = nil,
        cadenceRPM: Double? = nil,
        powerWatts: Double? = nil,
        leanAngleDegrees: Double? = nil,
        rpm: Double? = nil,
        throttlePercent: Double? = nil,
        brakePercent: Double? = nil,
        lapNumber: Double? = nil,
        lapTimeSeconds: Double? = nil,
        temperatureCelsius: Double? = nil,
        gradientPercent: Double? = nil,
        verticalSpeedMetersPerSecond: Double? = nil,
        torqueNewtonMeters: Double? = nil,
        gear: Double? = nil,
        calories: Double? = nil,
        airPressureHPA: Double? = nil,
        strideLengthMeters: Double? = nil,
        verticalOscillationCentimeters: Double? = nil,
        groundContactTimeMilliseconds: Double? = nil,
        leftRightBalancePercent: Double? = nil,
        strokeRate: Double? = nil,
        cameraISO: Double? = nil,
        cameraAperture: Double? = nil,
        cameraShutterSeconds: Double? = nil,
        cameraFocalLengthMM: Double? = nil,
        cameraEV: Double? = nil,
        cameraColorTemperatureKelvin: Double? = nil,
        customFields: [String: Double]? = nil
    ) {
        self.timestamp = max(0, timestamp.isFinite ? timestamp : 0)
        self.speedMetersPerSecond = speedMetersPerSecond?.isFinite == true ? speedMetersPerSecond : nil
        self.altitudeMeters = altitudeMeters?.isFinite == true ? altitudeMeters : nil
        self.gForce = gForce?.isFinite == true ? gForce : nil
        self.coordinate = coordinate
        self.distanceMeters = Self.finite(distanceMeters)
        self.accelerationMetersPerSecondSquared = Self.finite(accelerationMetersPerSecondSquared)
        self.gForceX = Self.finite(gForceX)
        self.gForceY = Self.finite(gForceY)
        self.gForceZ = Self.finite(gForceZ)
        self.gyroX = Self.finite(gyroX)
        self.gyroY = Self.finite(gyroY)
        self.gyroZ = Self.finite(gyroZ)
        self.headingDegrees = Self.finite(headingDegrees)
        self.heartRateBPM = Self.finite(heartRateBPM)
        self.cadenceRPM = Self.finite(cadenceRPM)
        self.powerWatts = Self.finite(powerWatts)
        self.leanAngleDegrees = Self.finite(leanAngleDegrees)
        self.rpm = Self.finite(rpm)
        self.throttlePercent = Self.finite(throttlePercent)
        self.brakePercent = Self.finite(brakePercent)
        self.lapNumber = Self.finite(lapNumber)
        self.lapTimeSeconds = Self.finite(lapTimeSeconds)
        self.temperatureCelsius = Self.finite(temperatureCelsius)
        self.gradientPercent = Self.finite(gradientPercent)
        self.verticalSpeedMetersPerSecond = Self.finite(verticalSpeedMetersPerSecond)
        self.torqueNewtonMeters = Self.finite(torqueNewtonMeters)
        self.gear = Self.finite(gear)
        self.calories = Self.finite(calories)
        self.airPressureHPA = Self.finite(airPressureHPA)
        self.strideLengthMeters = Self.finite(strideLengthMeters)
        self.verticalOscillationCentimeters = Self.finite(verticalOscillationCentimeters)
        self.groundContactTimeMilliseconds = Self.finite(groundContactTimeMilliseconds)
        self.leftRightBalancePercent = Self.finite(leftRightBalancePercent)
        self.strokeRate = Self.finite(strokeRate)
        self.cameraISO = Self.finite(cameraISO)
        self.cameraAperture = Self.finite(cameraAperture)
        self.cameraShutterSeconds = Self.finite(cameraShutterSeconds)
        self.cameraFocalLengthMM = Self.finite(cameraFocalLengthMM)
        self.cameraEV = Self.finite(cameraEV)
        self.cameraColorTemperatureKelvin = Self.finite(cameraColorTemperatureKelvin)
        let finiteCustom = customFields?.filter { $0.value.isFinite }
        self.customFields = finiteCustom?.isEmpty == false ? finiteCustom : nil
    }

    private static func finite(_ value: Double?) -> Double? { value?.isFinite == true ? value : nil }
}

public struct TelemetryCoordinate: Codable, Hashable, Sendable {
    public var latitude: Double
    public var longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = min(max(-90, latitude), 90)
        self.longitude = min(max(-180, longitude), 180)
    }
}

public enum EventScenePhase: String, Codable, CaseIterable, Hashable, Sendable {
    case setup
    case preparation
    case action
    case peak
    case reaction
    case conclusion

    public var storyRole: StoryRole {
        switch self {
        case .setup: return .setup
        case .preparation: return .buildup
        case .action: return .action
        case .peak: return .climax
        case .reaction: return .reaction
        case .conclusion: return .outro
        }
    }
}

public struct EventLocation: Codable, Hashable, Sendable {
    public var latitude: Double?
    public var longitude: Double?
    public var semanticLabel: String?
    public var confidence: Double

    public init(latitude: Double? = nil, longitude: Double? = nil, semanticLabel: String? = nil, confidence: Double = 0) {
        self.latitude = latitude
        self.longitude = longitude
        self.semanticLabel = semanticLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.confidence = confidence.clamped01
    }
}

public struct EventClusteringEvidence: Codable, Hashable, Sendable {
    public var kind: String
    public var score: Double
    public var explanation: String

    public init(kind: String, score: Double, explanation: String) {
        self.kind = kind
        self.score = score.clamped01
        self.explanation = explanation
    }
}

public struct EventScene: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    public var startDate: Date?
    public var endDate: Date?
    public var assetIDs: [UUID]
    public var candidateIDs: [UUID]
    public var tags: Set<String>
    public var phase: EventScenePhase
    public var confidence: Double

    public init(
        id: UUID = UUID(),
        title: String,
        startDate: Date? = nil,
        endDate: Date? = nil,
        assetIDs: [UUID],
        candidateIDs: [UUID] = [],
        tags: Set<String> = [],
        phase: EventScenePhase = .action,
        confidence: Double = 0.5
    ) {
        self.id = id
        self.title = title
        self.startDate = startDate
        self.endDate = endDate
        self.assetIDs = assetIDs
        self.candidateIDs = candidateIDs
        self.tags = tags
        self.phase = phase
        self.confidence = confidence.clamped01
    }
}

public struct EventQuality: Codable, Hashable, Sendable {
    public var total: Double
    public var visualQuality: Double
    public var semanticCoherence: Double
    public var temporalCoherence: Double
    public var usableMaterial: Double
    public var emotionalValue: Double
    public var action: Double
    public var uniqueness: Double
    public var storyPotential: Double
    public var diversity: Double

    public init(
        total: Double,
        visualQuality: Double,
        semanticCoherence: Double,
        temporalCoherence: Double,
        usableMaterial: Double,
        emotionalValue: Double,
        action: Double,
        uniqueness: Double,
        storyPotential: Double,
        diversity: Double
    ) {
        self.total = total.clamped01
        self.visualQuality = visualQuality.clamped01
        self.semanticCoherence = semanticCoherence.clamped01
        self.temporalCoherence = temporalCoherence.clamped01
        self.usableMaterial = usableMaterial.clamped01
        self.emotionalValue = emotionalValue.clamped01
        self.action = action.clamped01
        self.uniqueness = uniqueness.clamped01
        self.storyPotential = storyPotential.clamped01
        self.diversity = diversity.clamped01
    }
}

public struct Event: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    public var startDate: Date?
    public var endDate: Date?
    public var assetIDs: [UUID]
    public var tags: Set<String>
    /// Optional P4 fields preserve project packages created before Event
    /// Intelligence while making the hierarchy available to every later stage.
    public var location: EventLocation?
    public var confidence: Double?
    public var titleConfidence: Double?
    public var evidence: [EventClusteringEvidence]?
    public var scenes: [EventScene]?
    public var quality: EventQuality?
    public var deviceTimeOffsets: [String: Double]?
    public var crossDeviceMatchCount: Int?

    public init(
        id: UUID = UUID(),
        title: String,
        startDate: Date? = nil,
        endDate: Date? = nil,
        assetIDs: [UUID],
        tags: Set<String> = [],
        location: EventLocation? = nil,
        confidence: Double? = nil,
        titleConfidence: Double? = nil,
        evidence: [EventClusteringEvidence]? = nil,
        scenes: [EventScene]? = nil,
        quality: EventQuality? = nil,
        deviceTimeOffsets: [String: Double]? = nil,
        crossDeviceMatchCount: Int? = nil
    ) {
        self.id = id
        self.title = title
        self.startDate = startDate
        self.endDate = endDate
        self.assetIDs = assetIDs
        self.tags = tags
        self.location = location
        self.confidence = confidence?.clamped01
        self.titleConfidence = titleConfidence?.clamped01
        self.evidence = evidence
        self.scenes = scenes
        self.quality = quality
        self.deviceTimeOffsets = deviceTimeOffsets
        self.crossDeviceMatchCount = crossDeviceMatchCount.map { max(0, $0) }
    }

    public var effectiveConfidence: Double { confidence ?? 0.35 }
    public var effectiveScenes: [EventScene] { scenes ?? [] }
    public var effectiveCrossDeviceMatchCount: Int { crossDeviceMatchCount ?? 0 }
}

public enum FilmPreset: String, Codable, CaseIterable, Identifiable, Sendable {
    case highlight
    case adventure
    case story
    case summerFilm
    case memories
    case cinematic

    public var id: String { rawValue }
    public var localizedTitle: String {
        switch self {
        case .highlight: return "Лучшие моменты"
        case .adventure: return "Приключение"
        case .story: return "История"
        case .summerFilm: return "Летний фильм"
        case .memories: return "Воспоминания"
        case .cinematic: return "Кинематографичный"
        }
    }
}

public enum DirectorNarrativeMood: String, Codable, CaseIterable, Identifiable, Sendable {
    case calm
    case cinematic
    case dynamic

    public var id: String { rawValue }
    public var pacing: Double {
        switch self {
        case .calm: return 0.30
        case .cinematic: return 0.52
        case .dynamic: return 0.86
        }
    }
}

public enum DirectorMusicPolicy: String, Codable, CaseIterable, Identifiable, Sendable {
    case matchVideo = "match-video"
    case soft
    case none
    case specificTrack = "specific-track"

    public var id: String { rawValue }
}

public enum DirectorSourceAudioPolicy: String, Codable, CaseIterable, Identifiable, Sendable {
    case preserve
    case duck
    case mute

    public var id: String { rawValue }
    public var volume: Double {
        switch self {
        case .preserve: return 1
        case .duck: return 0.20
        case .mute: return 0
        }
    }
}

public enum DirectorTitlePolicy: String, Codable, CaseIterable, Identifiable, Sendable {
    case minimal
    case keyOnly = "key-only"
    case none

    public var id: String { rawValue }
}

public struct DirectorBrief: Codable, Hashable, Sendable {
    public var durationMode: FilmDurationMode?
    public var canvasFormat: DirectorCanvasFormat
    /// `nil` preserves the explicit format of projects created before adaptive
    /// canvases. New projects opt into source-driven format selection.
    public var canvasFormatIsAutomatic: Bool?
    /// The user's requested final runtime. It remains separate from any
    /// optimizer-resolved duration so an impossible request cannot pass as met.
    public var requestedDuration: Double
    public var mood: DirectorNarrativeMood
    public var musicPolicy: DirectorMusicPolicy
    public var musicTrackID: UUID?
    public var sourceAudioPolicy: DirectorSourceAudioPolicy
    public var titlePolicy: DirectorTitlePolicy

    public init(
        canvasFormat: DirectorCanvasFormat = .landscape16x9,
        canvasFormatIsAutomatic: Bool = false,
        requestedDuration: Double = 120,
        mood: DirectorNarrativeMood = .cinematic,
        musicPolicy: DirectorMusicPolicy = .matchVideo,
        musicTrackID: UUID? = nil,
        sourceAudioPolicy: DirectorSourceAudioPolicy = .preserve,
        titlePolicy: DirectorTitlePolicy = .minimal,
        durationMode: FilmDurationMode = .exact
    ) {
        self.canvasFormat = canvasFormat
        self.durationMode = durationMode
        self.canvasFormatIsAutomatic = canvasFormatIsAutomatic
        self.requestedDuration = min(3_600, AutomaticFilmDurationPolicy.normalizedRequest(requestedDuration))
        self.mood = mood
        self.musicPolicy = musicPolicy
        self.musicTrackID = musicPolicy == .specificTrack ? musicTrackID : nil
        self.sourceAudioPolicy = sourceAudioPolicy
        self.titlePolicy = titlePolicy
    }

    public var usesAutomaticCanvasFormat: Bool { canvasFormatIsAutomatic ?? false }
    public var explicitRequestedDuration: Double? { durationMode == .automatic ? nil : requestedDuration }

    public static let legacyDefault = DirectorBrief(canvasFormatIsAutomatic: true, durationMode: .automatic)
}

/// Exact constraints stated by the user must survive creative variant search.
/// Unlocked values may still vary so the selector can compare meaningfully
/// different edits of the same material.
public struct StoryConstraintLocks: OptionSet, Hashable, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let targetDuration = StoryConstraintLocks(rawValue: 1 << 0)
    public static let pacing = StoryConstraintLocks(rawValue: 1 << 1)
    public static let transitionFrequency = StoryConstraintLocks(rawValue: 1 << 2)
    public static let allowSlowMotion = StoryConstraintLocks(rawValue: 1 << 3)
}

public struct StoryConstraints: Codable, Hashable, Sendable {
    public var targetDuration: Double
    public var targetClipCount: Int?
    public var includeTags: Set<String>
    public var excludeTags: Set<String>
    public var maximumTagShares: [String: Double]
    public var preferPhotos: Bool
    public var allowSlowMotion: Bool
    public var transitionFrequency: Double
    public var pacing: Double
    /// Optional semantic anchors allow natural-language requests such as
    /// "make the buggy ride the climax" to change the story structure.
    public var preferredIntroTags: Set<String>?
    public var preferredClimaxTags: Set<String>?
    public var preferredOutroTags: Set<String>?

    public init(targetDuration: Double = 120, targetClipCount: Int? = nil, includeTags: Set<String> = [], excludeTags: Set<String> = [], maximumTagShares: [String: Double] = [:], preferPhotos: Bool = false, allowSlowMotion: Bool = true, transitionFrequency: Double = 0.15, pacing: Double = 0.65, preferredIntroTags: Set<String>? = nil, preferredClimaxTags: Set<String>? = nil, preferredOutroTags: Set<String>? = nil) {
        self.targetDuration = AutomaticFilmDurationPolicy.normalizedRequest(targetDuration)
        self.targetClipCount = targetClipCount.map { min(200, max(1, $0)) }
        self.includeTags = includeTags
        self.excludeTags = excludeTags
        self.maximumTagShares = maximumTagShares.mapValues { $0.clamped01 }
        self.preferPhotos = preferPhotos
        self.allowSlowMotion = allowSlowMotion
        self.transitionFrequency = transitionFrequency.clamped01
        self.pacing = pacing.clamped01
        self.preferredIntroTags = preferredIntroTags
        self.preferredClimaxTags = preferredClimaxTags
        self.preferredOutroTags = preferredOutroTags
    }
}

public enum CoveragePurpose: String, Codable, CaseIterable, Hashable, Sendable {
    case establishing, context, action, peak, reaction, detail, exit
}

public struct SceneCoverageRequirement: Codable, Hashable, Sendable {
    public var purpose: CoveragePurpose
    public var minimumShots: Int
    public var priority: Double
    public var prefersOriginalAudio: Bool
    public var explanation: String

    public init(purpose: CoveragePurpose, minimumShots: Int = 1, priority: Double = 0.5, prefersOriginalAudio: Bool = false, explanation: String) {
        self.purpose = purpose
        self.minimumShots = min(6, max(0, minimumShots))
        self.priority = priority.clamped01
        self.prefersOriginalAudio = prefersOriginalAudio
        self.explanation = explanation
    }
}

public struct SceneCoveragePlan: Codable, Hashable, Sendable {
    public var eventID: UUID?
    public var sceneID: UUID?
    public var requirements: [SceneCoverageRequirement]
    public var maximumNearDuplicates: Int
    public var preserveChronology: Bool
    public var explanation: String

    public init(eventID: UUID? = nil, sceneID: UUID? = nil, requirements: [SceneCoverageRequirement], maximumNearDuplicates: Int = 1, preserveChronology: Bool = true, explanation: String) {
        self.eventID = eventID
        self.sceneID = sceneID
        self.requirements = requirements
        self.maximumNearDuplicates = min(4, max(0, maximumNearDuplicates))
        self.preserveChronology = preserveChronology
        self.explanation = explanation
    }
}

public struct StoryChapter: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    public var candidateIDs: [UUID]
    public var role: StoryRole?
    public var purpose: String?
    public var eventID: UUID?
    public var eventSceneID: UUID?
    public var chapterCardTitle: String?
    public var isColdOpen: Bool?
    public var allocatedDuration: Double?
    public var coveragePlan: SceneCoveragePlan?

    public init(
        id: UUID = UUID(),
        title: String,
        candidateIDs: [UUID],
        role: StoryRole? = nil,
        purpose: String? = nil,
        eventID: UUID? = nil,
        eventSceneID: UUID? = nil,
        chapterCardTitle: String? = nil,
        isColdOpen: Bool? = nil,
        allocatedDuration: Double? = nil,
        coveragePlan: SceneCoveragePlan? = nil
    ) {
        self.id = id
        self.title = title
        self.candidateIDs = candidateIDs
        self.role = role
        self.purpose = purpose
        self.eventID = eventID
        self.eventSceneID = eventSceneID
        self.chapterCardTitle = chapterCardTitle
        self.isColdOpen = isColdOpen
        self.allocatedDuration = allocatedDuration.map { max(0, $0) }
        self.coveragePlan = coveragePlan
    }
}

public enum NarrativeBeatKind: String, Codable, CaseIterable, Hashable, Sendable {
    case context, question, anticipation, action, payoff, reaction, closure
}

public struct NarrativeBeat: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var chapterID: UUID
    public var kind: NarrativeBeatKind
    public var information: String
    public var dependsOn: [UUID]
    public var eventID: UUID?

    public init(id: UUID = UUID(), chapterID: UUID, kind: NarrativeBeatKind, information: String, dependsOn: [UUID] = [], eventID: UUID? = nil) {
        self.id = id
        self.chapterID = chapterID
        self.kind = kind
        self.information = information.trimmingCharacters(in: .whitespacesAndNewlines)
        self.dependsOn = dependsOn
        self.eventID = eventID
    }
}

public struct NarrativeBeatGraph: Codable, Hashable, Sendable {
    public var beats: [NarrativeBeat]

    public init(beats: [NarrativeBeat]) {
        self.beats = beats
    }

    public static func inferred(from chapters: [StoryChapter]) -> NarrativeBeatGraph {
        var priorBeatID: UUID?
        let beats = chapters.map { chapter -> NarrativeBeat in
            let kind: NarrativeBeatKind
            switch chapter.role {
            case .intro: kind = .context
            case .setup: kind = .question
            case .buildup: kind = .anticipation
            case .action: kind = .action
            case .climax: kind = .payoff
            case .reaction: kind = .reaction
            case .outro: kind = .closure
            case .bRoll, nil: kind = .context
            }
            let beat = NarrativeBeat(
                chapterID: chapter.id,
                kind: kind,
                information: chapter.purpose ?? chapter.title,
                dependsOn: priorBeatID.map { [$0] } ?? [],
                eventID: chapter.eventID
            )
            priorBeatID = beat.id
            return beat
        }
        return NarrativeBeatGraph(beats: beats)
    }
}

public struct EventStoryEntry: Codable, Hashable, Sendable {
    public var eventID: UUID
    public var title: String
    public var startDate: Date?
    public var endDate: Date?
    public var allocatedDuration: Double
    public var quality: Double
    public var sceneIDs: [UUID]

    public init(eventID: UUID, title: String, startDate: Date?, endDate: Date?, allocatedDuration: Double, quality: Double, sceneIDs: [UUID]) {
        self.eventID = eventID
        self.title = title
        self.startDate = startDate
        self.endDate = endDate
        self.allocatedDuration = max(0, allocatedDuration)
        self.quality = quality.clamped01
        self.sceneIDs = sceneIDs
    }
}

public struct EventDateRangeSummary: Codable, Hashable, Sendable {
    public var eventID: UUID
    public var title: String
    public var startDate: Date?
    public var endDate: Date?

    public init(eventID: UUID, title: String, startDate: Date?, endDate: Date?) {
        self.eventID = eventID
        self.title = title
        self.startDate = startDate
        self.endDate = endDate
    }
}

public struct EventRunDiagnostics: Codable, Hashable, Sendable {
    public var eventsDetected: Int
    public var eventsMerged: Int
    public var eventsSplit: Int
    public var eventConfidence: [String: Double]
    public var eventTitles: [String]
    public var eventDateRanges: [EventDateRangeSummary]
    public var eventOrder: [UUID]
    public var sceneCount: Int
    public var crossDeviceMatches: Int
    public var deviceTimeOffsets: [String: Double]
    public var clusteringReasons: [String: [String]]
    /// The archive-wide source order and activity grouping used for this run.
    /// Optional keeps plans created before Media Timeline Analysis decodable.
    public var sourceMap: SourceMap?

    public init(
        eventsDetected: Int,
        eventsMerged: Int = 0,
        eventsSplit: Int = 0,
        eventConfidence: [String: Double],
        eventTitles: [String],
        eventDateRanges: [EventDateRangeSummary],
        eventOrder: [UUID],
        sceneCount: Int,
        crossDeviceMatches: Int,
        deviceTimeOffsets: [String: Double] = [:],
        clusteringReasons: [String: [String]] = [:],
        sourceMap: SourceMap? = nil
    ) {
        self.eventsDetected = max(0, eventsDetected)
        self.eventsMerged = max(0, eventsMerged)
        self.eventsSplit = max(0, eventsSplit)
        self.eventConfidence = eventConfidence.mapValues(\.clamped01)
        self.eventTitles = eventTitles
        self.eventDateRanges = eventDateRanges
        self.eventOrder = eventOrder
        self.sceneCount = max(0, sceneCount)
        self.crossDeviceMatches = max(0, crossDeviceMatches)
        self.deviceTimeOffsets = deviceTimeOffsets
        self.clusteringReasons = clusteringReasons
        self.sourceMap = sourceMap
    }
}

public struct EventStoryPlan: Codable, Hashable, Sendable {
    public var projectTitle: String?
    public var entries: [EventStoryEntry]
    public var chronologicalByDefault: Bool
    public var coldOpenCandidateID: UUID?
    public var chapterCardsEnabled: Bool
    public var diagnostics: EventRunDiagnostics?

    public init(
        projectTitle: String? = nil,
        entries: [EventStoryEntry],
        chronologicalByDefault: Bool = true,
        coldOpenCandidateID: UUID? = nil,
        chapterCardsEnabled: Bool = true,
        diagnostics: EventRunDiagnostics? = nil
    ) {
        self.projectTitle = projectTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.entries = entries
        self.chronologicalByDefault = chronologicalByDefault
        self.coldOpenCandidateID = coldOpenCandidateID
        self.chapterCardsEnabled = chapterCardsEnabled
        self.diagnostics = diagnostics
    }
}

public struct StoryPlan: Codable, Identifiable, Hashable, Sendable {
    public var preferredChapterTitleDuration: Double?
    public var chapterTitleReference: ChapterTitleReference?
    public var approvedSourceChapterLabels: [UUID: ChapterTitleReference.Label]?
    public var explicitMusicTrackID: UUID?
    public var contentBudget: ContentBudgetDecision?
    public var narrativeBeatPlan: NarrativeBeatPlan?
    public var id: UUID
    public var version: Int
    public var prompt: String
    public var preset: FilmPreset
    public var constraints: StoryConstraints
    public var chapters: [StoryChapter]
    /// P3 decisions are persisted with the plan so every downstream production
    /// stage uses the same autonomous style, duration, grammar and story intent.
    public var autonomousDecision: AutonomousDirectorDecision?
    public var eventStory: EventStoryPlan?
    public var beatGraph: NarrativeBeatGraph?
    /// Exact opening-questionnaire choices. Optional keeps older project
    /// packages decodable; consumers use `legacyDefault` when it is absent.
    public var directorBrief: DirectorBrief?
    public var createdAt: Date

    public init(id: UUID = UUID(), version: Int = 1, prompt: String, preset: FilmPreset, constraints: StoryConstraints, chapters: [StoryChapter], autonomousDecision: AutonomousDirectorDecision? = nil, eventStory: EventStoryPlan? = nil, beatGraph: NarrativeBeatGraph? = nil, directorBrief: DirectorBrief? = nil, createdAt: Date = Date()) {
        self.id = id
        self.version = version
        self.prompt = prompt
        self.preset = preset
        self.constraints = constraints
        self.chapters = chapters
        self.autonomousDecision = autonomousDecision
        self.eventStory = eventStory
        self.beatGraph = beatGraph ?? NarrativeBeatGraph.inferred(from: chapters)
        self.directorBrief = directorBrief
        self.createdAt = createdAt
    }

    /// The effective exact target is normally the duration explicitly chosen
    /// by the user. When the autonomous duration pass has proved that the
    /// source material cannot cover that request, the plan carries a smaller,
    /// material-bounded target in `constraints`; enforcing the impossible
    /// original value would discard an otherwise valid film at delivery time.
    public var exactDurationRequirement: Double? {
        let requirement = FilmDurationRequirement.parse(prompt: prompt,
            explicitSeconds: directorBrief?.explicitRequestedDuration ?? contentBudget?.requestedDuration,
            mode: directorBrief?.durationMode)
        return requirement.mode == .exact ? requirement.target : nil
    }

    /// Keeping the predicate on StoryPlan prevents composing, directing and
    /// final delivery from disagreeing about the effective duration contract.
    public var requiresExactDuration: Bool {
        exactDurationRequirement != nil
    }
}

public enum TimelineItemKind: String, Codable, Sendable {
    case video
    case photo
    case title
}

public enum TimelineAudioRole: String, Codable, CaseIterable, Identifiable, Sendable {
    case detached
    case dialogue
    case naturalSound = "natural-sound"
    case music
    case soundEffect = "sound-effect"
    case voice

    public var id: String { rawValue }
    public var localizedTitle: String {
        switch self {
        case .detached: return "Отделённое аудио"
        case .dialogue: return "Диалог"
        case .naturalSound: return "Синхронный звук"
        case .music: return "Музыка"
        case .soundEffect: return "Звуковой эффект"
        case .voice: return "Голос"
        }
    }
}

public enum TransitionStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case cut
    case crossDissolve = "cross-dissolve"
    case fade = "fade"
    case fadeThroughBlack = "fade-through-black"
    case fadeToWhite = "fade-to-white"
    case dipToColor = "dip-to-color"
    case blurDissolve = "blur-dissolve"
    case lightFlash = "light-flash"
    case slideLeft = "slide-left"
    case slideRight = "slide-right"
    case slideUp = "slide-up"
    case slideDown = "slide-down"
    case push = "push"
    case pushLeft = "push-left"
    case pushRight = "push-right"
    case pushUp = "push-up"
    case pushDown = "push-down"
    case zoom = "zoom"
    case zoomIn = "zoom-in"
    case zoomOut = "zoom-out"
    case whipLeft = "whip-left"
    case whipRight = "whip-right"
    case whipUp = "whip-up"
    case whipDown = "whip-down"
    case spin
    case cameraPush = "camera-push"
    case cameraPull = "camera-pull"
    case wipeLeft = "wipe-left"
    case wipeRight = "wipe-right"
    case wipeUp = "wipe-up"
    case wipeDown = "wipe-down"
    case filmDissolve = "film-dissolve"
    case filmBurn = "film-burn"
    case lightLeak = "light-leak"
    case lensBlur = "lens-blur"
    case exposureFlash = "exposure-flash"
    case glitch
    case rgbSplit = "rgb-split"
    case digitalDistortion = "digital-distortion"
    case pixelate
    case shatter
    case ripple
    case wave
    case circle
    case iris
    case radial
    case geometricWipe = "geometric-wipe"
    case maskReveal = "mask-reveal"

    public var id: String { rawValue }
    public var localizedTitle: String {
        switch self {
        case .cut: return "Склейка"
        case .crossDissolve: return "Растворение"
        case .fade: return "Мягкое затухание"
        case .fadeThroughBlack: return "Через чёрный"
        case .fadeToWhite: return "Через белый"
        case .dipToColor: return "Через цвет"
        case .blurDissolve: return "Размытие"
        case .lightFlash: return "Световая вспышка"
        case .slideLeft: return "Сдвиг влево"
        case .slideRight: return "Сдвиг вправо"
        case .slideUp: return "Сдвиг вверх"
        case .slideDown: return "Сдвиг вниз"
        case .push: return "Push"
        case .pushLeft: return "Push влево"
        case .pushRight: return "Push вправо"
        case .pushUp: return "Push вверх"
        case .pushDown: return "Push вниз"
        case .zoom: return "Zoom"
        case .zoomIn: return "Zoom In"
        case .zoomOut: return "Zoom Out"
        case .whipLeft: return "Whip влево"
        case .whipRight: return "Whip вправо"
        case .whipUp: return "Whip вверх"
        case .whipDown: return "Whip вниз"
        case .spin: return "Вращение"
        case .cameraPush: return "Camera Push"
        case .cameraPull: return "Camera Pull"
        case .wipeLeft: return "Шторка влево"
        case .wipeRight: return "Шторка вправо"
        case .wipeUp: return "Шторка вверх"
        case .wipeDown: return "Шторка вниз"
        case .filmDissolve: return "Плёночное растворение"
        case .filmBurn: return "Film Burn"
        case .lightLeak: return "Light Leak"
        case .lensBlur: return "Lens Blur"
        case .exposureFlash: return "Exposure Flash"
        case .glitch: return "Glitch"
        case .rgbSplit: return "RGB Split"
        case .digitalDistortion: return "Цифровое искажение"
        case .pixelate: return "Пикселизация"
        case .shatter: return "Осколки"
        case .ripple: return "Рябь"
        case .wave: return "Волна"
        case .circle: return "Круг"
        case .iris: return "Ирис"
        case .radial: return "Радиальный"
        case .geometricWipe: return "Геометрическая шторка"
        case .maskReveal: return "Проявление маской"
        }
    }
}

public enum EditorialEditChoice: String, Codable, CaseIterable, Hashable, Sendable {
    case cut, hold, transition
}

/// Records why a visual boundary exists. This turns CUT/HOLD into an explicit
/// editorial decision and gives P6 a stable contract for detecting decorative
/// transitions or cuts that do not reveal new information.
public struct EditorialBoundaryDecision: Codable, Hashable, Sendable {
    public var choice: EditorialEditChoice
    public var motivation: String
    public var confidence: Double
    public var transitionStyle: TransitionStyle?
    public var naturalTransition: NaturalChapterTransitionEvidence?

    public init(choice: EditorialEditChoice, motivation: String, confidence: Double, transitionStyle: TransitionStyle? = nil) {
        self.choice = choice
        self.motivation = motivation.trimmingCharacters(in: .whitespacesAndNewlines)
        self.confidence = confidence.clamped01
        self.transitionStyle = transitionStyle
    }
}

public enum ClipEffect: String, Codable, CaseIterable, Identifiable, Sendable {
    case kenBurns = "ken-burns"
    case zoomIn = "zoom-in"
    case zoomOut = "zoom-out"
    case pushIn = "push-in"
    case pullOut = "pull-out"
    case panLeft = "pan-left"
    case panRight = "pan-right"
    case mirror

    public var id: String { rawValue }
    public var localizedTitle: String {
        switch self {
        case .kenBurns: return "Ken Burns"
        case .zoomIn: return "Приближение"
        case .zoomOut: return "Отдаление"
        case .pushIn: return "Плавный наезд"
        case .pullOut: return "Плавный отъезд"
        case .panLeft: return "Панорама влево"
        case .panRight: return "Панорама вправо"
        case .mirror: return "Отражение"
        }
    }
}

public enum CropStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case fill
    case fit

    public var id: String { rawValue }
    public var localizedTitle: String {
        switch self {
        case .fill: return "Заполнить кадр"
        case .fit: return "Показать целиком"
        }
    }
}

public enum VideoFilter: String, Codable, CaseIterable, Identifiable, Sendable {
    case none
    case monochrome
    case noir
    case sepia
    case vivid
    case warm
    case cool
    case dramatic

    public var id: String { rawValue }
    public var localizedTitle: String {
        switch self {
        case .none: return "Без фильтра"
        case .monochrome: return "Чёрно-белый"
        case .noir: return "Нуар"
        case .sepia: return "Сепия"
        case .vivid: return "Яркий"
        case .warm: return "Тёплый"
        case .cool: return "Холодный"
        case .dramatic: return "Драматичный"
        }
    }
}

public enum AudioEffect: String, Codable, CaseIterable, Identifiable, Sendable {
    case none
    case voiceEnhance = "voice-enhance"
    case telephone
    case muffled
    case echo
    case room
    case robot

    public var id: String { rawValue }
    public var localizedTitle: String {
        switch self {
        case .none: return "Нет"
        case .voiceEnhance: return "Улучшение голоса"
        case .telephone: return "Телефон"
        case .muffled: return "Приглушённый"
        case .echo: return "Эхо"
        case .room: return "Комната"
        case .robot: return "Робот"
        }
    }
}

public struct VideoAdjustments: Codable, Hashable, Sendable {
    public var crop: CropStyle
    public var rotationQuarterTurns: Int
    public var filter: VideoFilter
    public var brightness: Double
    public var contrast: Double
    public var saturation: Double
    public var warmth: Double
    public var opacity: Double
    /// Optional to preserve decoding of projects created before the extended
    /// image pipeline was introduced.
    public var exposure: Double?
    public var highlights: Double?
    public var shadows: Double?
    public var vignette: Double?
    public var grain: Double?
    /// Optional viewer-tool fields keep older project packages decodable.
    public var tint: Double?
    public var filterIntensity: Double?
    public var stabilization: Double?
    public var rollingShutterCorrection: Bool?
    public var smoothSlowMotion: Bool?
    public var sharpening: Double?
    public var denoise: Double?
    public var blur: Double?
    public var subjectReframe: SubjectReframePlan?

    public init(
        crop: CropStyle = .fill,
        rotationQuarterTurns: Int = 0,
        filter: VideoFilter = .none,
        brightness: Double = 0,
        contrast: Double = 1,
        saturation: Double = 1,
        warmth: Double = 0,
        opacity: Double = 1,
        exposure: Double = 0,
        highlights: Double = 0,
        shadows: Double = 0,
        vignette: Double = 0,
        grain: Double = 0,
        tint: Double = 0,
        filterIntensity: Double = 1,
        stabilization: Double = 0,
        rollingShutterCorrection: Bool = false,
        smoothSlowMotion: Bool = false,
        sharpening: Double = 0,
        denoise: Double = 0,
        blur: Double = 0,
        subjectReframe: SubjectReframePlan? = nil
    ) {
        self.crop = crop
        self.rotationQuarterTurns = ((rotationQuarterTurns % 4) + 4) % 4
        self.filter = filter
        self.brightness = min(max(-1, brightness), 1)
        self.contrast = min(max(0.25, contrast), 4)
        self.saturation = min(max(0, saturation), 2)
        self.warmth = min(max(-1, warmth), 1)
        self.opacity = min(max(0, opacity), 1)
        self.exposure = min(max(-4, exposure), 4)
        self.highlights = min(max(-1, highlights), 1)
        self.shadows = min(max(-1, shadows), 1)
        self.vignette = min(max(0, vignette), 1)
        self.grain = min(max(0, grain), 1)
        self.tint = min(max(-1, tint), 1)
        self.filterIntensity = min(max(0, filterIntensity), 1)
        self.stabilization = min(max(0, stabilization), 1)
        self.rollingShutterCorrection = rollingShutterCorrection
        self.smoothSlowMotion = smoothSlowMotion
        self.sharpening = min(max(0, sharpening), 1)
        self.denoise = min(max(0, denoise), 1)
        self.blur = min(max(0, blur), 1)
        self.subjectReframe = subjectReframe
    }

    public var isNeutral: Bool {
        crop == .fill && rotationQuarterTurns == 0 && filter == .none &&
        abs(brightness) < 0.0001 && abs(contrast - 1) < 0.0001 &&
        abs(saturation - 1) < 0.0001 && abs(warmth) < 0.0001 &&
        abs(opacity - 1) < 0.0001 && abs(exposure ?? 0) < 0.0001 &&
        abs(highlights ?? 0) < 0.0001 && abs(shadows ?? 0) < 0.0001 &&
        abs(vignette ?? 0) < 0.0001 && abs(grain ?? 0) < 0.0001 &&
        abs(tint ?? 0) < 0.0001 && (filter == .none || abs((filterIntensity ?? 1) - 1) < 0.0001) &&
        abs(stabilization ?? 0) < 0.0001 && !(rollingShutterCorrection ?? false) &&
        !(smoothSlowMotion ?? false) && abs(sharpening ?? 0) < 0.0001 &&
        abs(denoise ?? 0) < 0.0001 && abs(blur ?? 0) < 0.0001 && subjectReframe == nil
    }
}

public enum AudioEQPreset: String, Codable, CaseIterable, Identifiable, Sendable {
    case flat
    case voice
    case music
    case bassReduction = "bass-reduction"
    case presence

    public var id: String { rawValue }
    public var localizedTitle: String {
        switch self {
        case .flat: return "Без коррекции"
        case .voice: return "Усиление голоса"
        case .music: return "Музыка"
        case .bassReduction: return "Снижение басов"
        case .presence: return "Присутствие"
        }
    }
}

public struct AudioAdjustments: Codable, Hashable, Sendable {
    public var volume: Double
    public var muted: Bool
    public var fadeIn: Double
    public var fadeOut: Double
    /// Optional extended fields keep old project JSON backward compatible.
    public var noiseReduction: Double?
    public var eqPreset: AudioEQPreset?
    public var normalize: Bool?
    public var duckOthers: Bool?
    public var duckingAmount: Double?
    public var preservePitch: Bool?
    public var effect: AudioEffect?

    public init(volume: Double = 1, muted: Bool = false, fadeIn: Double = 0, fadeOut: Double = 0, noiseReduction: Double = 0, eqPreset: AudioEQPreset = .flat, normalize: Bool = false, duckOthers: Bool = false, duckingAmount: Double = 0.5, preservePitch: Bool = true, effect: AudioEffect = .none) {
        self.volume = min(max(0, volume), 2)
        self.muted = muted
        self.fadeIn = min(max(0, fadeIn), 30)
        self.fadeOut = min(max(0, fadeOut), 30)
        self.noiseReduction = min(max(0, noiseReduction), 1)
        self.eqPreset = eqPreset
        self.normalize = normalize
        self.duckOthers = duckOthers
        self.duckingAmount = min(max(0, duckingAmount), 1)
        self.preservePitch = preservePitch
        self.effect = effect
    }

    public var effectiveVolume: Double { muted ? 0 : volume }
    public var isNeutral: Bool {
        !muted && abs(volume - 1) < 0.0001 && fadeIn < 0.0001 && fadeOut < 0.0001 &&
        abs(noiseReduction ?? 0) < 0.0001 && (eqPreset ?? .flat) == .flat &&
        !(normalize ?? false) && !(duckOthers ?? false) &&
        (preservePitch ?? true) && (effect ?? AudioEffect.none) == AudioEffect.none
    }
}

public struct SpeedRampPoint: Codable, Hashable, Sendable {
    public var position: Double
    public var rate: Double

    public init(position: Double, rate: Double) {
        self.position = min(max(0, position), 1)
        self.rate = min(max(0.1, rate), 8)
    }
}

public struct SpeedRamp: Codable, Hashable, Sendable {
    public var points: [SpeedRampPoint]

    public init(points: [SpeedRampPoint]) {
        let normalized = points.sorted { $0.position < $1.position }
        self.points = normalized.isEmpty
            ? [SpeedRampPoint(position: 0, rate: 1), SpeedRampPoint(position: 1, rate: 1)]
            : normalized
    }

    public static let easeIn = SpeedRamp(points: [
        SpeedRampPoint(position: 0, rate: 0.5),
        SpeedRampPoint(position: 0.35, rate: 1),
        SpeedRampPoint(position: 1, rate: 1)
    ])
    public static let easeOut = SpeedRamp(points: [
        SpeedRampPoint(position: 0, rate: 1),
        SpeedRampPoint(position: 0.65, rate: 1),
        SpeedRampPoint(position: 1, rate: 0.5)
    ])
    public static let action = SpeedRamp(points: [
        SpeedRampPoint(position: 0, rate: 1),
        SpeedRampPoint(position: 0.3, rate: 0.45),
        SpeedRampPoint(position: 0.65, rate: 0.45),
        SpeedRampPoint(position: 1, rate: 1.5)
    ])

    public func outputDuration(sourceDuration: Double) -> Double {
        guard sourceDuration > 0 else { return 0 }
        let values = normalizedPoints
        return zip(values, values.dropFirst()).reduce(0) { partial, pair in
            let sourcePart = sourceDuration * (pair.1.position - pair.0.position)
            let averageRate = max(0.1, (pair.0.rate + pair.1.rate) * 0.5)
            return partial + sourcePart / averageRate
        }
    }

    public var normalizedPoints: [SpeedRampPoint] {
        var result = points.sorted { $0.position < $1.position }
        if result.first?.position ?? 1 > 0 { result.insert(SpeedRampPoint(position: 0, rate: result.first?.rate ?? 1), at: 0) }
        if result.last?.position ?? 0 < 1 { result.append(SpeedRampPoint(position: 1, rate: result.last?.rate ?? 1)) }
        return result
    }
}

public struct AudioDuckingSettings: Codable, Hashable, Sendable {
    public var enabled: Bool
    public var attenuation: Double
    public var attack: Double
    public var release: Double

    public init(enabled: Bool = true, attenuation: Double = 0.38, attack: Double = 0.18, release: Double = 0.35) {
        self.enabled = enabled
        self.attenuation = min(max(0.05, attenuation), 1)
        self.attack = min(max(0.02, attack), 3)
        self.release = min(max(0.02, release), 3)
    }
}

public enum TitleAlignment: String, Codable, CaseIterable, Identifiable, Sendable {
    case left
    case center
    case right
    public var id: String { rawValue }
}

public struct TitleStyle: Codable, Hashable, Sendable {
    public var fontSize: Double
    public var textColorHex: String
    public var backgroundColorHex: String
    public var alignment: TitleAlignment
    /// Optional properties preserve decoding of titles created by older builds.
    public var fontFamily: String?
    public var fontWeight: Double?
    public var xPosition: Double?
    public var yPosition: Double?
    public var scale: Double?
    public var rotation: Double?
    public var opacity: Double?
    public var shadow: Double?
    public var strokeWidth: Double?
    public var backgroundOpacity: Double?
    public var blur: Double?
    public var tracking: Double?
    public var lineSpacing: Double?
    public var activeWordColorHex: String?

    public init(
        fontSize: Double = 72,
        textColorHex: String = "#FFFFFF",
        backgroundColorHex: String = "#111111",
        alignment: TitleAlignment = .center,
        fontFamily: String = "Helvetica Neue",
        fontWeight: Double = 0.7,
        xPosition: Double = 0.5,
        yPosition: Double = 0.5,
        scale: Double = 1,
        rotation: Double = 0,
        opacity: Double = 1,
        shadow: Double = 0.35,
        strokeWidth: Double = 0,
        backgroundOpacity: Double = 1,
        blur: Double = 0,
        tracking: Double = 0,
        lineSpacing: Double = 1,
        activeWordColorHex: String = "#FFD60A"
    ) {
        self.fontSize = min(max(18, fontSize), 220)
        self.textColorHex = textColorHex
        self.backgroundColorHex = backgroundColorHex
        self.alignment = alignment
        self.fontFamily = fontFamily
        self.fontWeight = min(max(0, fontWeight), 1)
        self.xPosition = min(max(0, xPosition), 1)
        self.yPosition = min(max(0, yPosition), 1)
        self.scale = min(max(0.1, scale), 5)
        self.rotation = min(max(-180, rotation), 180)
        self.opacity = min(max(0, opacity), 1)
        self.shadow = min(max(0, shadow), 1)
        self.strokeWidth = min(max(0, strokeWidth), 20)
        self.backgroundOpacity = min(max(0, backgroundOpacity), 1)
        self.blur = min(max(0, blur), 100)
        self.tracking = min(max(-20, tracking), 80)
        self.lineSpacing = min(max(0.5, lineSpacing), 3)
        self.activeWordColorHex = activeWordColorHex
    }

    public var effectiveFontFamily: String { fontFamily ?? "Helvetica Neue" }
    public var effectiveFontWeight: Double { min(max(0, fontWeight ?? 0.7), 1) }
    public var effectiveXPosition: Double { min(max(0, xPosition ?? 0.5), 1) }
    public var effectiveYPosition: Double { min(max(0, yPosition ?? 0.5), 1) }
    public var effectiveScale: Double { min(max(0.1, scale ?? 1), 5) }
    public var effectiveRotation: Double { min(max(-180, rotation ?? 0), 180) }
    public var effectiveOpacity: Double { min(max(0, opacity ?? 1), 1) }
    public var effectiveBackgroundOpacity: Double { min(max(0, backgroundOpacity ?? 1), 1) }
}

public enum OverlayStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case cutaway
    case pictureInPicture = "picture-in-picture"
    case splitScreen = "split-screen"
    case greenScreen = "green-screen"

    public var id: String { rawValue }
    public var localizedTitle: String {
        switch self {
        case .cutaway: return "Перебивка"
        case .pictureInPicture: return "Картинка в картинке"
        case .splitScreen: return "Разделённый экран"
        case .greenScreen: return "Зелёный фон"
        }
    }
}

public enum OverlayCorner: String, Codable, CaseIterable, Identifiable, Sendable {
    case topLeft = "top-left"
    case topRight = "top-right"
    case bottomLeft = "bottom-left"
    case bottomRight = "bottom-right"
    public var id: String { rawValue }
}

public struct OverlaySettings: Codable, Hashable, Sendable {
    public var style: OverlayStyle
    public var baseItemID: UUID?
    public var corner: OverlayCorner
    public var scale: Double
    /// Offset from the connected primary clip. Optional so projects written by
    /// earlier versions continue to decode; a missing value means zero.
    public var startOffset: Double?

    public init(style: OverlayStyle, baseItemID: UUID? = nil, corner: OverlayCorner = .topRight, scale: Double = 0.34, startOffset: Double = 0) {
        self.style = style
        self.baseItemID = baseItemID
        self.corner = corner
        self.scale = min(max(0.15, scale), 0.75)
        self.startOffset = startOffset
    }

    public var effectiveStartOffset: Double { startOffset ?? 0 }
}

public enum TelemetryMetric: String, Codable, CaseIterable, Identifiable, Sendable {
    case speed
    case route
    case altitude
    case gForce = "g-force"
    case distance
    case acceleration
    case heading
    case heartRate = "heart-rate"
    case cadence
    case power
    case leanAngle = "lean-angle"
    case rpm
    case throttle
    case brake
    case lapTime = "lap-time"
    case lapNumber = "lap-number"
    case temperature
    case gradient
    case verticalSpeed = "vertical-speed"
    case torque
    case gear
    case calories
    case airPressure = "air-pressure"
    case strideLength = "stride-length"
    case verticalOscillation = "vertical-oscillation"
    case groundContactTime = "ground-contact-time"
    case leftRightBalance = "left-right-balance"
    case strokeRate = "stroke-rate"
    case cameraISO = "camera-iso"
    case cameraAperture = "camera-aperture"
    case cameraShutter = "camera-shutter"
    case cameraFocalLength = "camera-focal-length"
    case cameraEV = "camera-ev"
    case cameraColorTemperature = "camera-color-temperature"

    public var id: String { rawValue }
}

public struct TelemetryOverlaySettings: Codable, Hashable, Sendable {
    public var metrics: Set<TelemetryMetric>
    public var corner: OverlayCorner
    public var scale: Double
    public var style: TelemetryWidgetStyle?
    public var widgets: [TelemetryWidgetLayout]?
    public var opacity: Double?

    public init(metrics: Set<TelemetryMetric> = [.speed, .route, .altitude, .distance], corner: OverlayCorner = .bottomLeft, scale: Double = 0.32, style: TelemetryWidgetStyle? = nil, widgets: [TelemetryWidgetLayout]? = nil, opacity: Double? = nil) {
        self.metrics = metrics
        self.corner = corner
        self.scale = min(max(0.18, scale), 0.55)
        self.style = style
        self.widgets = widgets
        self.opacity = opacity.map { min(max(0, $0), 1) }
    }

    public var effectiveStyle: TelemetryWidgetStyle { style ?? .cleanApple }
    public var effectiveOpacity: Double { min(max(0, opacity ?? 1), 1) }
}

public enum MusicStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case energetic
    case cinematic
    case calm
    case joyful
    case electronic
    case acoustic

    public var id: String { rawValue }
    public var localizedTitle: String {
        switch self {
        case .energetic: return "Энергичная"
        case .cinematic: return "Кинематографичная"
        case .calm: return "Спокойная"
        case .joyful: return "Светлая"
        case .electronic: return "Электронная"
        case .acoustic: return "Акустическая"
        }
    }
}

public enum MusicSectionKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case intro, buildup, drop, chorus, climax, outro
    public var id: String { rawValue }
}

public enum MusicAccentKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case beat, strongBeat = "strong-beat", onset, peak, downbeat, drop, phrase
    case sectionPeak = "section-peak", transition, breakdown
    public var id: String { rawValue }
}

public struct MusicAccent: Codable, Hashable, Sendable {
    public var time: Double
    public var strength: Double
    public var kind: MusicAccentKind
    public var confidence: Double?

    public init(time: Double, strength: Double, kind: MusicAccentKind, confidence: Double? = nil) {
        self.time = max(0, time)
        self.strength = strength.clamped01
        self.kind = kind
        self.confidence = confidence?.clamped01
    }
}

public struct MusicSection: Codable, Hashable, Sendable {
    public var kind: MusicSectionKind
    public var start: Double
    public var duration: Double
    public var energy: Double
    public var confidence: Double?

    public init(kind: MusicSectionKind, start: Double, duration: Double, energy: Double, confidence: Double? = nil) {
        self.kind = kind
        self.start = max(0, start)
        self.duration = max(0, duration)
        self.energy = min(max(0, energy), 1)
        self.confidence = confidence?.clamped01
    }
}

public struct MusicStructure: Codable, Hashable, Sendable {
    public var bpm: Double
    public var beatInterval: Double
    public var sections: [MusicSection]
    public var beatTimestamps: [Double]?
    public var barBoundaries: [Double]?
    public var peaks: [Double]?
    public var quietRanges: [ClosedRange<Double>]?
    public var drops: [Double]?
    public var downbeatTimestamps: [Double]?
    public var phraseBoundaries: [Double]?
    public var accents: [MusicAccent]?
    public var beatsPerBar: Int?
    public var tempoConfidence: Double?
    public var downbeatConfidence: Double?
    public var phraseConfidence: Double?
    public var sectionConfidence: Double?
    public var dropConfidence: Double?
    public var analysisIsMeasured: Bool?

    public init(
        bpm: Double,
        beatInterval: Double,
        sections: [MusicSection],
        beatTimestamps: [Double]? = nil,
        barBoundaries: [Double]? = nil,
        peaks: [Double]? = nil,
        quietRanges: [ClosedRange<Double>]? = nil,
        drops: [Double]? = nil,
        downbeatTimestamps: [Double]? = nil,
        phraseBoundaries: [Double]? = nil,
        accents: [MusicAccent]? = nil,
        beatsPerBar: Int? = nil,
        tempoConfidence: Double? = nil,
        downbeatConfidence: Double? = nil,
        phraseConfidence: Double? = nil,
        sectionConfidence: Double? = nil,
        dropConfidence: Double? = nil,
        analysisIsMeasured: Bool? = nil
    ) {
        self.bpm = min(max(40, bpm), 240)
        self.beatInterval = max(0.05, beatInterval)
        self.sections = sections
        self.beatTimestamps = beatTimestamps
        self.barBoundaries = barBoundaries
        self.peaks = peaks
        self.quietRanges = quietRanges
        self.drops = drops
        self.downbeatTimestamps = downbeatTimestamps
        self.phraseBoundaries = phraseBoundaries
        self.accents = accents
        self.beatsPerBar = beatsPerBar.map { min(max(2, $0), 12) }
        self.tempoConfidence = tempoConfidence?.clamped01
        self.downbeatConfidence = downbeatConfidence?.clamped01
        self.phraseConfidence = phraseConfidence?.clamped01
        self.sectionConfidence = sectionConfidence?.clamped01
        self.dropConfidence = dropConfidence?.clamped01
        self.analysisIsMeasured = analysisIsMeasured
    }
}

public struct MusicDirective: Codable, Hashable, Sendable {
    public var style: MusicStyle
    public var bpm: Double
    public var volume: Double
    /// Playback rate for the soundtrack. Optional for backward compatibility.
    public var speed: Double?
    /// The concrete file is resolved only from VeloEdit's local music catalog.
    /// `nil` means that a suitable local track still needs to be selected.
    public var trackID: UUID?
    public var trackTitle: String?
    public var preferDifferentTrack: Bool?
    public var structure: MusicStructure?
    /// Optional continuous P3 intent used for track structure and narrative
    /// matching. Older projects continue to use style/BPM selection.
    public var autonomousIntent: AutonomousMusicIntent?
    public var searchRequests: [MusicSearchRequest]?

    /// Source clock shared by preview and export. Missing in legacy projects.
    public var sourceStart: Double?
    public var selectionEvidence: SoundtrackSelectionEvidence?

    public init(style: MusicStyle, bpm: Double, volume: Double = 0.18, speed: Double? = nil, trackID: UUID? = nil, trackTitle: String? = nil, preferDifferentTrack: Bool? = nil, structure: MusicStructure? = nil, autonomousIntent: AutonomousMusicIntent? = nil, searchRequests: [MusicSearchRequest]? = nil) {
        self.style = style
        self.bpm = min(max(55, bpm), 180)
        self.volume = min(max(0, volume), 1)
        self.speed = speed.map { min(max(0.1, $0), 20) }
        self.trackID = trackID
        self.trackTitle = trackTitle
        self.preferDifferentTrack = preferDifferentTrack
        self.structure = structure
        self.autonomousIntent = autonomousIntent
        self.searchRequests = searchRequests
    }

    public var effectiveSpeed: Double { min(max(0.1, speed ?? 1), 20) }
}

/// One story-sized region of an automatically directed soundtrack. The region
/// is expressed on the editable Timeline clock; PlaybackEngine maps it to the
/// rendered clock so visual transition overlaps and music transitions stay in
/// lockstep.
public struct AdaptiveMusicSegment: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var timelineStart: Double
    public var timelineDuration: Double
    public var directive: MusicDirective
    public var sourceStart: Double
    /// Crossfade duration at the beginning of this region. The first region
    /// uses zero and receives a regular fade-in in the audio renderer.
    public var transitionDuration: Double
    public var semanticLabel: String
    public var activityKey: String?
    public var energy: Double
    public var confidence: Double
    public var boundaryItemID: UUID?
    public var explanation: [String]

    public init(
        id: UUID = UUID(),
        timelineStart: Double,
        timelineDuration: Double,
        directive: MusicDirective,
        sourceStart: Double = 0,
        transitionDuration: Double = 0,
        semanticLabel: String,
        activityKey: String? = nil,
        energy: Double,
        confidence: Double,
        boundaryItemID: UUID? = nil,
        explanation: [String] = []
    ) {
        self.id = id
        self.timelineStart = max(0, timelineStart)
        self.timelineDuration = max(0.05, timelineDuration)
        self.directive = directive
        self.sourceStart = max(0, sourceStart)
        self.transitionDuration = min(max(0, transitionDuration), 4)
        self.semanticLabel = semanticLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        self.activityKey = activityKey
        self.energy = energy.clamped01
        self.confidence = confidence.clamped01
        self.boundaryItemID = boundaryItemID
        self.explanation = explanation
    }

    public var timelineEnd: Double { timelineStart + timelineDuration }
}

/// A conservative, internal AI-director decision. `primaryTrackID` ties the
/// plan to the visible soundtrack control: assigning another track manually
/// invalidates the plan without exposing any new UI or migration step.
public struct AdaptiveSoundtrackPlan: Codable, Hashable, Sendable {
    public var primaryTrackID: UUID
    public var timelineDuration: Double
    /// Identifies the exact primary-storyline layout that produced the plan.
    /// Reordering clips can preserve total duration, so duration alone is not
    /// enough to decide that musical boundaries are still synchronized.
    public var timelineFingerprint: String?
    public var segments: [AdaptiveMusicSegment]
    public var confidence: Double
    public var explanation: [String]

    public init(
        primaryTrackID: UUID,
        timelineDuration: Double,
        timelineFingerprint: String? = nil,
        segments: [AdaptiveMusicSegment],
        confidence: Double,
        explanation: [String] = []
    ) {
        self.primaryTrackID = primaryTrackID
        self.timelineDuration = max(0, timelineDuration)
        self.timelineFingerprint = timelineFingerprint
        self.segments = segments.sorted { $0.timelineStart < $1.timelineStart }
        self.confidence = confidence.clamped01
        self.explanation = explanation
    }

    public func isValid(
        for timelineDuration: Double,
        primaryTrackID: UUID?,
        timelineFingerprint: String? = nil
    ) -> Bool {
        guard segments.count >= 2,
              Set(segments.compactMap(\.directive.trackID)).count >= 2,
              self.primaryTrackID == primaryTrackID,
              abs(self.timelineDuration - timelineDuration) <= 0.12,
              let first = segments.first,
              let last = segments.last,
              first.timelineStart <= 0.06,
              abs(last.timelineEnd - timelineDuration) <= 0.12 else { return false }
        if let expected = self.timelineFingerprint, expected != timelineFingerprint { return false }
        return zip(segments, segments.dropFirst()).allSatisfy { pair in
            abs(pair.0.timelineEnd - pair.1.timelineStart) <= 0.08
        }
    }
}

public struct TimelineItem: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var candidateID: UUID?
    public var assetID: UUID?
    public var kind: TimelineItemKind
    public var sourceStart: Double
    public var sourceDuration: Double
    public var timelineStart: Double
    public var timelineDuration: Double
    public var speed: Double
    public var title: String?
    public var transition: String?
    public var effect: String?
    /// Optional fields keep projects saved by earlier VeloEdit builds decodable.
    public var videoAdjustments: VideoAdjustments?
    public var audioAdjustments: AudioAdjustments?
    public var titleStyle: TitleStyle?
    public var overlay: OverlaySettings?
    public var freezeFrame: Bool?
    public var reversePlayback: Bool?
    public var speedRamp: SpeedRamp?
    public var telemetryOverlay: TelemetryOverlaySettings?
    public var storyRole: StoryRole?
    public var editorialPurpose: String?
    public var incomingEditDecision: EditorialBoundaryDecision?
    public var eventID: UUID?
    public var eventSceneID: UUID?
    public var locked: Bool
    public var explanation: [String]

    public init(id: UUID = UUID(), candidateID: UUID? = nil, assetID: UUID? = nil, kind: TimelineItemKind, sourceStart: Double = 0, sourceDuration: Double, timelineStart: Double, timelineDuration: Double, speed: Double = 1, title: String? = nil, transition: String? = nil, effect: String? = nil, videoAdjustments: VideoAdjustments? = nil, audioAdjustments: AudioAdjustments? = nil, titleStyle: TitleStyle? = nil, overlay: OverlaySettings? = nil, freezeFrame: Bool? = nil, reversePlayback: Bool? = nil, speedRamp: SpeedRamp? = nil, telemetryOverlay: TelemetryOverlaySettings? = nil, storyRole: StoryRole? = nil, editorialPurpose: String? = nil, incomingEditDecision: EditorialBoundaryDecision? = nil, eventID: UUID? = nil, eventSceneID: UUID? = nil, locked: Bool = false, explanation: [String] = []) {
        self.id = id
        self.candidateID = candidateID
        self.assetID = assetID
        self.kind = kind
        self.sourceStart = max(0, sourceStart)
        self.sourceDuration = max(0, sourceDuration)
        self.timelineStart = max(0, timelineStart)
        self.timelineDuration = max(0, timelineDuration)
        self.speed = max(0.05, speed)
        self.title = title
        self.transition = transition
        self.effect = effect
        self.videoAdjustments = videoAdjustments
        self.audioAdjustments = audioAdjustments
        self.titleStyle = titleStyle
        self.overlay = overlay
        self.freezeFrame = freezeFrame
        self.reversePlayback = reversePlayback
        self.speedRamp = speedRamp
        self.telemetryOverlay = telemetryOverlay
        self.storyRole = storyRole
        self.editorialPurpose = editorialPurpose
        self.incomingEditDecision = incomingEditDecision
        self.eventID = eventID
        self.eventSceneID = eventSceneID
        self.locked = locked
        self.explanation = explanation
    }

    public var effectiveVideoAdjustments: VideoAdjustments { videoAdjustments ?? VideoAdjustments() }
    public var effectiveAudioAdjustments: AudioAdjustments { audioAdjustments ?? AudioAdjustments() }
    public var effectiveTitleStyle: TitleStyle { titleStyle ?? TitleStyle() }
    public var isFreezeFrame: Bool { freezeFrame ?? false }
    public var isReversed: Bool { reversePlayback ?? false }

    /// Maps a position on the edited clip back to the original video's clock.
    /// Telemetry uses this same mapping so trims, constant speed, reverse and
    /// speed ramps cannot drift away from the picture.
    public func sourceTime(atTimelineTime timelineTime: Double) -> Double {
        guard sourceDuration > 0 else { return sourceStart }
        if isFreezeFrame { return sourceStart }

        let timelineFraction = min(max(
            0,
            (timelineTime - timelineStart) / max(0.000_001, timelineDuration)
        ), 1)
        let sourceFraction: Double
        if let speedRamp {
            let points = speedRamp.normalizedPoints
            let outputDuration = max(0.000_001, speedRamp.outputDuration(sourceDuration: sourceDuration))
            var remaining = timelineFraction * outputDuration
            var resolved = 1.0
            for (from, to) in zip(points, points.dropFirst()) where to.position > from.position {
                let averageRate = max(0.1, (from.rate + to.rate) * 0.5)
                let segmentSourceDuration = sourceDuration * (to.position - from.position)
                let segmentOutputDuration = segmentSourceDuration / averageRate
                if remaining <= segmentOutputDuration {
                    resolved = from.position + (remaining * averageRate / sourceDuration)
                    break
                }
                remaining -= segmentOutputDuration
            }
            sourceFraction = min(max(0, resolved), 1)
        } else {
            sourceFraction = timelineFraction
        }
        return sourceStart + sourceDuration * (isReversed ? 1 - sourceFraction : sourceFraction)
    }
}

/// A non-destructive audio region that can be positioned independently of the
/// magnetic video storyline. It may reference either a video's audio stream or
/// a track from VeloEdit's local music library.
public struct TimelineAudioClip: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var assetID: UUID?
    public var trackID: UUID?
    public var title: String
    public var role: TimelineAudioRole
    public var sourceStart: Double
    public var sourceDuration: Double
    public var timelineStart: Double
    public var timelineDuration: Double
    /// Playback rate. Optional so timelines created by older builds still decode.
    public var speed: Double?
    public var attachedToItemID: UUID?
    public var attachmentOffset: Double?
    public var adjustments: AudioAdjustments

    public init(
        id: UUID = UUID(),
        assetID: UUID? = nil,
        trackID: UUID? = nil,
        title: String,
        role: TimelineAudioRole,
        sourceStart: Double = 0,
        sourceDuration: Double,
        timelineStart: Double,
        timelineDuration: Double,
        speed: Double? = nil,
        attachedToItemID: UUID? = nil,
        attachmentOffset: Double? = nil,
        adjustments: AudioAdjustments = AudioAdjustments()
    ) {
        self.id = id
        self.assetID = assetID
        self.trackID = trackID
        self.title = title
        self.role = role
        self.sourceStart = max(0, sourceStart)
        self.sourceDuration = max(0.05, sourceDuration)
        self.timelineStart = max(0, timelineStart)
        self.timelineDuration = max(0.05, timelineDuration)
        self.speed = speed.map { min(max(0.1, $0), 20) }
        self.attachedToItemID = attachedToItemID
        self.attachmentOffset = attachmentOffset
        self.adjustments = adjustments
    }

    public var timelineEnd: Double { timelineStart + timelineDuration }
    public var effectiveSpeed: Double { min(max(0.1, speed ?? 1), 20) }
}

public struct Timeline: Codable, Identifiable, Hashable, Sendable {
    public var editorialRegeneration: EditorialRegenerationRecord?
    public var editorialBeatPlan: NarrativeBeatPlan?
    public var editorialReview: EditorialReview?
    public var id: UUID
    public var storyPlanID: UUID
    public var width: Int
    public var height: Int
    public var frameRate: Double
    public var items: [TimelineItem]
    /// Optional for backward-compatible decoding of existing project packages.
    public var audioClips: [TimelineAudioClip]?
    /// Independent, non-destructive telemetry regions. They stay editable until
    /// final render and never change the magnetic primary storyline duration.
    public var telemetryItems: [TimelineTelemetryItem]?
    /// Independent timeline objects introduced by the OpenCut-inspired editor.
    /// They do not alter the magnetic primary storyline duration.
    public var effects: [EffectTimelineItem]?
    public var titleItems: [TitleTimelineItem]?
    public var transitionItems: [TimelineTransitionItem]?
    public var music: MusicDirective?
    /// Optional so every project created before adaptive soundtracks remains
    /// directly decodable. A valid plan is rendered instead of the global
    /// music loop while `music` remains its backward-compatible master control.
    public var adaptiveSoundtrack: AdaptiveSoundtrackPlan?
    /// `nil` keeps projects created before audio controls backward compatible.
    /// Playback treats it as full source volume.
    public var originalAudioVolume: Double?
    /// Movie-level fade to black. Missing on legacy/manual timelines; zero
    /// explicitly disables it. New automatic films save a three-second finish.
    public var endingFadeDuration: Double?
    public var audioDucking: AudioDuckingSettings?
    public var versionName: String?
    public var directorRun: DirectorRunSummary?
    /// P8 keeps an execution-level audit trail separate from the conversational
    /// UI history. Optional preserves all pre-P8 project packages.
    public var naturalLanguageHistory: [NaturalLanguageCommandRecord]?
    public var createdAt: Date

    public init(id: UUID = UUID(), storyPlanID: UUID, width: Int = 1920, height: Int = 1080, frameRate: Double = 30, items: [TimelineItem], audioClips: [TimelineAudioClip]? = nil, telemetryItems: [TimelineTelemetryItem]? = nil, effects: [EffectTimelineItem]? = nil, titleItems: [TitleTimelineItem]? = nil, transitionItems: [TimelineTransitionItem]? = nil, music: MusicDirective? = nil, adaptiveSoundtrack: AdaptiveSoundtrackPlan? = nil, originalAudioVolume: Double? = nil, endingFadeDuration: Double? = nil, audioDucking: AudioDuckingSettings? = nil, versionName: String? = nil, directorRun: DirectorRunSummary? = nil, naturalLanguageHistory: [NaturalLanguageCommandRecord]? = nil, createdAt: Date = Date()) {
        self.id = id
        self.storyPlanID = storyPlanID
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.items = items
        self.audioClips = audioClips
        self.telemetryItems = telemetryItems
        self.effects = effects
        self.titleItems = titleItems
        self.transitionItems = transitionItems
        self.music = music
        self.adaptiveSoundtrack = adaptiveSoundtrack
        self.originalAudioVolume = originalAudioVolume.map { min(max(0, $0), 1) }
        self.endingFadeDuration = endingFadeDuration.map { $0.isFinite ? max(0, $0) : 0 }
        self.audioDucking = audioDucking
        self.versionName = versionName
        self.directorRun = directorRun
        self.naturalLanguageHistory = naturalLanguageHistory
        self.createdAt = createdAt
    }

    /// The magnetic primary storyline defines movie duration. Connected visuals
    /// and independent audio are clamped at playback and never lengthen it.
    public var duration: Double {
        items.filter { $0.overlay == nil }.map { $0.timelineStart + $0.timelineDuration }.max() ?? 0
    }
    public var effectiveOriginalAudioVolume: Double { originalAudioVolume ?? 1 }
    public var effectiveAudioClips: [TimelineAudioClip] { audioClips ?? [] }
    public var effectiveAdaptiveSoundtrack: AdaptiveSoundtrackPlan? {
        guard let adaptiveSoundtrack,
              adaptiveSoundtrack.isValid(
                for: duration,
                primaryTrackID: music?.trackID,
                timelineFingerprint: adaptiveSoundtrackFingerprint
              ) else { return nil }
        return adaptiveSoundtrack
    }
    public var adaptiveSoundtrackFingerprint: String {
        items
            .filter { $0.overlay == nil }
            .sorted {
                $0.timelineStart == $1.timelineStart
                    ? $0.id.uuidString < $1.id.uuidString
                    : $0.timelineStart < $1.timelineStart
            }
            .map { item in
                [
                    item.id.uuidString.lowercased(),
                    String(Int((item.timelineStart * 1_000).rounded())),
                    String(Int((item.timelineDuration * 1_000).rounded())),
                    item.candidateID?.uuidString.lowercased() ?? "candidate:none",
                    item.eventID?.uuidString.lowercased() ?? "event:none",
                    item.eventSceneID?.uuidString.lowercased() ?? "scene:none",
                    item.transition ?? "transition:none"
                ].joined(separator: "|")
            }
            .joined(separator: ";")
    }
    public var effectiveTelemetryItems: [TimelineTelemetryItem] { telemetryItems ?? [] }
    public var effectiveEffects: [EffectTimelineItem] { effects ?? [] }
    public var effectiveTitleItems: [TitleTimelineItem] { titleItems ?? [] }
    public var effectiveTransitionItems: [TimelineTransitionItem] { transitionItems ?? [] }
}

public enum RenderQuality: String, Codable, Sendable { case preview720p, preview1080p, final1080p, final4K, maximum }
public enum RenderJobStatus: String, Codable, Sendable { case queued, running, paused, completed, failed, cancelled }

public struct RenderJob: Codable, Identifiable, Hashable, Sendable {
    public var frameRate: Double?
    public var inputSignature: String?
    public var artifactHash: String?
    public var verifiedStagingURL: URL?
    public var videoSummary: String?
    public var completedAt: Date?
    public var replacesExistingFile: Bool?
    public var id: UUID
    public var timelineID: UUID
    public var quality: RenderQuality
    public var outputURL: URL
    public var status: RenderJobStatus
    public var progress: Double
    public var errorMessage: String?
    public init(id: UUID = UUID(), timelineID: UUID, quality: RenderQuality, outputURL: URL, status: RenderJobStatus = .queued, progress: Double = 0, errorMessage: String? = nil) {
        self.id = id
        self.timelineID = timelineID
        self.quality = quality
        self.outputURL = outputURL
        self.status = status
        self.progress = progress.clamped01
        self.errorMessage = errorMessage
    }
}

public struct UserPreferences: Codable, Hashable, Sendable {
    public var chapterTitleReference: ChapterTitleReference?
    public var likedTags: Set<String> = []
    public var dislikedTags: Set<String> = []
    public var preferredPacing: Double = 0.65
    public var preferredTransitionFrequency: Double = 0.15
    public var preferredPhotoShare: Double = 0.20
    /// Optional fields preserve decoding of projects created before AI power
    /// profiles existed. Their effective values are intentionally non-optional.
    public var aiPowerMode: AIPowerMode?
    public var advancedAISettings: AdvancedAISettings?
    public init() {
        aiPowerMode = .fast
    }

    public var effectiveAIPowerMode: AIPowerMode { aiPowerMode ?? .fast }
    public var effectiveAdvancedAISettings: AdvancedAISettings { advancedAISettings ?? AdvancedAISettings() }
}

public struct ProjectManifest: Codable, Identifiable, Sendable {
    public var autonomousJob: AutonomousJob?
    public var authorizedMediaFolders: [AuthorizedMediaFolder]?
    public var removedMedia: [RemovedMediaArchive]?
    public var packagedMediaPaths: [UUID: String]?
    public var packagedFilePaths: [String: String]?
    /// Exact unfinished request and its last durable build checkpoint.
    public var filmBuildRecovery: FilmBuildRecovery?
    public var filmBuildContentRevision: UUID?
    public var editorialDevelopmentEnabled: Bool?
    public var editorialHumanEvaluation: EditorialHumanEvaluation?
    public var intentLedger: IntentLedger?
    public var id: UUID
    public var name: String
    public var projectVersion: Int
    public var analysisSchemaVersion: Int
    public var storySchemaVersion: Int
    public var createdAt: Date
    public var updatedAt: Date
    public var assets: [MediaAsset]
    public var analyses: [AnalysisResult]
    /// Persisted output of the pre-Story Media Timeline Analysis pass.
    public var sourceMap: SourceMap?
    public var events: [Event]
    public var storyPlans: [StoryPlan]
    public var timelines: [Timeline]
    public var renderJobs: [RenderJob]
    /// Unified embedded and sidecar telemetry sources. Optional preserves
    /// decoding of project packages written before Telemetry Engine 2.
    public var telemetrySources: [TelemetrySource]?
    /// Version of the embedded-camera discovery pass already applied to this
    /// project. Optional keeps older project packages decodable.
    public var telemetryExtractionVersion: Int?
    public var timelineCheckpoints: [TimelineCheckpoint]?
    public var preferences: UserPreferences
    /// Editor-only draft state. Optional so projects created by older builds
    /// remain decodable without a migration pass.
    public var workspaceState: ProjectWorkspaceState?
    public var analysisQueue: [AnalysisQueueEntry]?
    /// Local, anonymized P3 preference state. It is also mirrored into the
    /// device-local taste store for learning across projects.
    public var personalTasteProfile: PersonalTasteProfile?
    public var preferenceSignals: [PreferenceSignal]?
    /// License and attribution records for music used by this project. The
    /// actual audio cache remains in MusicLibrary, while credits travel with
    /// the project manifest and can be shown or exported independently.
    public var musicCredits: [MusicCredit]?

    public init(id: UUID = UUID(), name: String, projectVersion: Int = 1, analysisSchemaVersion: Int = 1, storySchemaVersion: Int = 1, createdAt: Date = Date(), updatedAt: Date = Date(), assets: [MediaAsset] = [], analyses: [AnalysisResult] = [], sourceMap: SourceMap? = nil, events: [Event] = [], storyPlans: [StoryPlan] = [], timelines: [Timeline] = [], renderJobs: [RenderJob] = [], telemetrySources: [TelemetrySource]? = nil, telemetryExtractionVersion: Int? = nil, timelineCheckpoints: [TimelineCheckpoint]? = nil, preferences: UserPreferences = UserPreferences(), workspaceState: ProjectWorkspaceState? = nil, analysisQueue: [AnalysisQueueEntry]? = nil, personalTasteProfile: PersonalTasteProfile? = nil, preferenceSignals: [PreferenceSignal]? = nil, musicCredits: [MusicCredit]? = nil) {
        self.id = id
        self.name = name
        self.projectVersion = projectVersion
        self.analysisSchemaVersion = analysisSchemaVersion
        self.storySchemaVersion = storySchemaVersion
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.assets = assets
        self.analyses = analyses
        self.sourceMap = sourceMap
        self.events = events
        self.storyPlans = storyPlans
        self.timelines = timelines
        self.renderJobs = renderJobs
        self.telemetrySources = telemetrySources
        self.telemetryExtractionVersion = telemetryExtractionVersion
        self.timelineCheckpoints = timelineCheckpoints
        self.preferences = preferences
        self.workspaceState = workspaceState
        self.analysisQueue = analysisQueue
        self.personalTasteProfile = personalTasteProfile
        self.preferenceSignals = preferenceSignals
        self.musicCredits = musicCredits
    }

    public var effectiveTelemetrySources: [TelemetrySource] { telemetrySources ?? [] }
    public var effectiveAnalysisQueue: [AnalysisQueueEntry] { analysisQueue ?? [] }
    public var effectiveMusicCredits: [MusicCredit] { musicCredits ?? [] }
}

public struct ProjectWorkspaceState: Codable, Hashable, Sendable {
    public var prompt: String
    public var preset: FilmPreset
    public var targetMinutes: Double
    /// A user-imported track explicitly chosen for the next director build.
    /// Optional keeps older project packages source-compatible.
    public var directorMusicTrackID: UUID?
    /// Structured mandatory AI Director choices. Optional for project packages
    /// saved before the opening questionnaire became a production contract.
    public var directorBrief: DirectorBrief?
    public var directorDraft: String
    public var feedbackDraft: String
    public var pendingDirectorInstructions: [String]
    public var hasPendingFilmChanges: Bool
    /// Conversation belongs to the project package. Optional preserves
    /// compatibility with projects created before chat history was persisted.
    public var directorMessages: [ProjectDirectorMessage]?

    public init(
        prompt: String,
        preset: FilmPreset,
        targetMinutes: Double,
        directorMusicTrackID: UUID? = nil,
        directorBrief: DirectorBrief? = nil,
        directorDraft: String = "",
        feedbackDraft: String = "",
        pendingDirectorInstructions: [String] = [],
        hasPendingFilmChanges: Bool = false,
        directorMessages: [ProjectDirectorMessage]? = nil
    ) {
        self.prompt = prompt
        self.preset = preset
        self.targetMinutes = min(60, max(0.5, targetMinutes))
        self.directorMusicTrackID = directorMusicTrackID
        self.directorBrief = directorBrief
        self.directorDraft = directorDraft
        self.feedbackDraft = feedbackDraft
        self.pendingDirectorInstructions = pendingDirectorInstructions
        self.hasPendingFilmChanges = hasPendingFilmChanges
        self.directorMessages = directorMessages
    }
}

public enum ProjectDirectorMessageRole: String, Codable, Hashable, Sendable {
    case user
    case assistant
}

public struct ProjectDirectorMessage: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var role: ProjectDirectorMessageRole
    public var text: String
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        role: ProjectDirectorMessageRole,
        text: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.role = role
        self.text = text
        // Project JSON uses ISO-8601 second precision. Normalize at the model
        // boundary so an in-memory message and its persisted copy stay equal.
        self.createdAt = Date(timeIntervalSince1970: createdAt.timeIntervalSince1970.rounded(.down))
    }
}

extension Double {
    var clamped01: Double { min(1, max(0, self)) }
}
