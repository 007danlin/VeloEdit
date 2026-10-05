import Foundation

// MARK: - P7 adaptive preference model

public enum TasteSignalPolarity: String, Codable, Hashable, Sendable {
    case positive
    case negative
    case neutral
}

/// A confidence-calibrated preference learned from natural edits. Unlike the
/// legacy Bayesian estimate, this value keeps explicit sample and polarity
/// counts so diagnostics can explain why a preference earned influence.
public struct AdaptiveTasteEstimate: Codable, Hashable, Sendable {
    public var value: Double
    public var confidence: Double
    public var sampleCount: Int
    public var positiveCount: Int
    public var negativeCount: Int
    public var neutralCount: Int
    public var evidenceWeight: Double
    public var lastUpdated: Date

    public init(
        value: Double = 0,
        confidence: Double = 0,
        sampleCount: Int = 0,
        positiveCount: Int = 0,
        negativeCount: Int = 0,
        neutralCount: Int = 0,
        evidenceWeight: Double = 0,
        lastUpdated: Date = Date()
    ) {
        self.value = min(max(-1, value), 1)
        self.confidence = confidence.clamped01
        self.sampleCount = max(0, sampleCount)
        self.positiveCount = max(0, positiveCount)
        self.negativeCount = max(0, negativeCount)
        self.neutralCount = max(0, neutralCount)
        self.evidenceWeight = max(0, evidenceWeight)
        self.lastUpdated = lastUpdated
    }

    public var polarity: TasteSignalPolarity {
        if value > 0.08 { return .positive }
        if value < -0.08 { return .negative }
        return .neutral
    }

    public func decayed(at now: Date, halfLifeDays: Double = 180) -> AdaptiveTasteEstimate {
        let ageDays = max(0, now.timeIntervalSince(lastUpdated) / 86_400)
        guard ageDays > 0.01, evidenceWeight > 0 else { return self }
        let factor = exp(-log(2) * ageDays / max(1, halfLifeDays))
        var copy = self
        copy.value *= factor
        copy.evidenceWeight *= factor
        copy.confidence = Self.confidence(for: copy.evidenceWeight)
        return copy
    }

    /// Calibrated against the P7 milestones: about 0.16 after one useful
    /// sample, 0.43 after five, 0.78 after twenty and 0.95 after fifty.
    public static func confidence(for evidence: Double) -> Double {
        (1 - exp(-0.175 * pow(max(0, evidence), 0.72))).clamped01
    }
}

public struct TasteContext: Codable, Hashable, Sendable {
    public var activity: String?
    public var projectType: String?
    public var eventType: String?
    public var cameraType: String?
    public var socialFormat: String?
    public var durationBucket: String?
    public var discoveredTokens: Set<String>

    public init(
        activity: String? = nil,
        projectType: String? = nil,
        eventType: String? = nil,
        cameraType: String? = nil,
        socialFormat: String? = nil,
        durationBucket: String? = nil,
        discoveredTokens: Set<String> = []
    ) {
        self.activity = Self.normalized(activity)
        self.projectType = Self.normalized(projectType)
        self.eventType = Self.normalized(eventType)
        self.cameraType = Self.normalized(cameraType)
        self.socialFormat = Self.normalized(socialFormat)
        self.durationBucket = Self.normalized(durationBucket)
        self.discoveredTokens = Set(discoveredTokens.compactMap(Self.normalized))
    }

    public var key: String {
        let named = [activity, projectType, eventType, cameraType, socialFormat, durationBucket].compactMap { $0 }
        let tokens = discoveredTokens.sorted().prefix(4)
        let all = named + tokens
        return all.isEmpty ? "adaptive-mixed" : all.joined(separator: "|")
    }

    private static func normalized(_ value: String?) -> String? {
        guard let clean = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !clean.isEmpty else { return nil }
        return clean.replacingOccurrences(of: " ", with: "-")
    }
}

public struct AdaptiveTasteContextProfile: Codable, Hashable, Sendable {
    public var context: TasteContext
    public var preferences: [String: AdaptiveTasteEstimate]
    public var sampleCount: Int
    public var lastUpdated: Date

    public init(context: TasteContext, preferences: [String: AdaptiveTasteEstimate] = [:], sampleCount: Int = 0, lastUpdated: Date = Date()) {
        self.context = context
        self.preferences = preferences
        self.sampleCount = max(0, sampleCount)
        self.lastUpdated = lastUpdated
    }
}

public struct TasteDurationPreferences: Codable, Hashable, Sendable {
    public var preferredFilmDuration: AdaptiveTasteEstimate?
    public var actionClipDuration: AdaptiveTasteEstimate?
    public var calmClipDuration: AdaptiveTasteEstimate?
    public var introDuration: AdaptiveTasteEstimate?
    public var climaxDuration: AdaptiveTasteEstimate?
    public var outroDuration: AdaptiveTasteEstimate?

    public init(
        preferredFilmDuration: AdaptiveTasteEstimate? = nil,
        actionClipDuration: AdaptiveTasteEstimate? = nil,
        calmClipDuration: AdaptiveTasteEstimate? = nil,
        introDuration: AdaptiveTasteEstimate? = nil,
        climaxDuration: AdaptiveTasteEstimate? = nil,
        outroDuration: AdaptiveTasteEstimate? = nil
    ) {
        self.preferredFilmDuration = preferredFilmDuration
        self.actionClipDuration = actionClipDuration
        self.calmClipDuration = calmClipDuration
        self.introDuration = introDuration
        self.climaxDuration = climaxDuration
        self.outroDuration = outroDuration
    }

    public func estimate(for feature: String) -> AdaptiveTasteEstimate? {
        switch feature {
        case "duration.film": return preferredFilmDuration
        case "duration.action": return actionClipDuration
        case "duration.calm": return calmClipDuration
        case "duration.intro": return introDuration
        case "duration.climax": return climaxDuration
        case "duration.outro": return outroDuration
        default: return nil
        }
    }

    mutating func set(_ value: AdaptiveTasteEstimate, for feature: String) {
        switch feature {
        case "duration.film": preferredFilmDuration = value
        case "duration.action": actionClipDuration = value
        case "duration.calm": calmClipDuration = value
        case "duration.intro": introDuration = value
        case "duration.climax": climaxDuration = value
        case "duration.outro": outroDuration = value
        default: break
        }
    }
}

/// A privacy-preserving visual preference. Only normalized centroids and broad
/// semantic tokens are stored; media paths, candidate IDs and frames are not.
public struct TasteEmbeddingProfile: Codable, Hashable, Sendable {
    public var modelIdentifier: String
    public var positiveCentroid: [Float]
    public var negativeCentroid: [Float]
    public var positiveTokens: [String: Double]
    public var negativeTokens: [String: Double]
    public var confidence: Double
    public var sampleCount: Int
    public var lastUpdated: Date

    public init(
        modelIdentifier: String = "velo-taste-embedding-v1",
        positiveCentroid: [Float] = [],
        negativeCentroid: [Float] = [],
        positiveTokens: [String: Double] = [:],
        negativeTokens: [String: Double] = [:],
        confidence: Double = 0,
        sampleCount: Int = 0,
        lastUpdated: Date = Date()
    ) {
        self.modelIdentifier = modelIdentifier
        self.positiveCentroid = Self.normalized(positiveCentroid)
        self.negativeCentroid = Self.normalized(negativeCentroid)
        self.positiveTokens = positiveTokens
        self.negativeTokens = negativeTokens
        self.confidence = confidence.clamped01
        self.sampleCount = max(0, sampleCount)
        self.lastUpdated = lastUpdated
    }

    public func affinity(embedding: [Float]?, tokens: Set<String>) -> Double {
        let tokenPositive = tokens.map { positiveTokens[$0.lowercased(), default: 0] }.reduce(0, +)
        let tokenNegative = tokens.map { negativeTokens[$0.lowercased(), default: 0] }.reduce(0, +)
        let tokenEvidence = (0.5 + tanh((tokenPositive - tokenNegative) / 4) * 0.5).clamped01
        guard let embedding, !embedding.isEmpty else { return tokenEvidence }
        let normalized = Self.normalized(embedding)
        let positive = Self.cosine(normalized, positiveCentroid)
        let negative = Self.cosine(normalized, negativeCentroid)
        let vectorEvidence = (0.5 + (positive - negative) * 0.5).clamped01
        return vectorEvidence * 0.68 + tokenEvidence * 0.32
    }

    static func normalized(_ values: [Float]) -> [Float] {
        let finite = values.map { $0.isFinite ? $0 : 0 }
        let norm = sqrt(finite.reduce(Float.zero) { $0 + $1 * $1 })
        return norm > 0.000_001 ? finite.map { $0 / norm } : finite
    }

    private static func cosine(_ lhs: [Float], _ rhs: [Float]) -> Double {
        guard !lhs.isEmpty, lhs.count == rhs.count else { return 0 }
        return Double(zip(lhs, rhs).reduce(Float.zero) { $0 + $1.0 * $1.1 })
    }
}

public struct DiscoveredTasteStyle: Codable, Hashable, Sendable {
    public var label: String
    public var confidence: Double
    public var evidence: [String]
    public var lastUpdated: Date

    public init(label: String, confidence: Double, evidence: [String], lastUpdated: Date = Date()) {
        self.label = label
        self.confidence = confidence.clamped01
        self.evidence = evidence
        self.lastUpdated = lastUpdated
    }
}

public struct MusicTasteProfile: Codable, Hashable, Sendable {
    public var preferredBPM: AdaptiveTasteEstimate?
    public var energy: AdaptiveTasteEstimate?
    public var beatSync: AdaptiveTasteEstimate?
    public var preferredTrackLength: AdaptiveTasteEstimate?
    public var preferredGenres: [String: Double]
    public var preferredSections: [String: Double]
    public var replacementCount: Int

    public init(preferredBPM: AdaptiveTasteEstimate? = nil, energy: AdaptiveTasteEstimate? = nil, beatSync: AdaptiveTasteEstimate? = nil, preferredTrackLength: AdaptiveTasteEstimate? = nil, preferredGenres: [String: Double] = [:], preferredSections: [String: Double] = [:], replacementCount: Int = 0) {
        self.preferredBPM = preferredBPM
        self.energy = energy
        self.beatSync = beatSync
        self.preferredTrackLength = preferredTrackLength
        self.preferredGenres = preferredGenres
        self.preferredSections = preferredSections
        self.replacementCount = max(0, replacementCount)
    }
}

public struct TitleTasteProfile: Codable, Hashable, Sendable {
    public var size: AdaptiveTasteEstimate?
    public var duration: AdaptiveTasteEstimate?
    public var verticalPosition: AdaptiveTasteEstimate?
    public var count: AdaptiveTasteEstimate?
    public var animationIntensity: AdaptiveTasteEstimate?

    public init(size: AdaptiveTasteEstimate? = nil, duration: AdaptiveTasteEstimate? = nil, verticalPosition: AdaptiveTasteEstimate? = nil, count: AdaptiveTasteEstimate? = nil, animationIntensity: AdaptiveTasteEstimate? = nil) {
        self.size = size
        self.duration = duration
        self.verticalPosition = verticalPosition
        self.count = count
        self.animationIntensity = animationIntensity
    }
}

public struct TasteStructurePattern: Codable, Hashable, Sendable {
    public var roles: [StoryRole]
    public var count: Int
    public var confidence: Double
    public var lastUpdated: Date

    public init(roles: [StoryRole], count: Int = 1, confidence: Double = 0, lastUpdated: Date = Date()) {
        self.roles = roles
        self.count = max(1, count)
        self.confidence = confidence.clamped01
        self.lastUpdated = lastUpdated
    }
}

public struct TimelineTasteFeatures: Codable, Hashable, Sendable {
    public var duration: Double
    public var meanShotDuration: Double
    public var actionShare: Double
    public var calmShare: Double
    public var transitionShare: Double
    public var effectShare: Double
    public var slowMotionShare: Double
    public var telemetryShare: Double
    public var titleDensity: Double
    public var originalAudioShare: Double
    public var chronologicalOrder: Double
    public var endingEnergy: Double
    public var semanticTokens: Set<String>
    public var embeddingCentroid: [Float]

    public init(
        duration: Double,
        meanShotDuration: Double,
        actionShare: Double,
        calmShare: Double,
        transitionShare: Double,
        effectShare: Double,
        slowMotionShare: Double,
        telemetryShare: Double,
        titleDensity: Double,
        originalAudioShare: Double,
        chronologicalOrder: Double,
        endingEnergy: Double,
        semanticTokens: Set<String> = [],
        embeddingCentroid: [Float] = []
    ) {
        self.duration = max(0, duration)
        self.meanShotDuration = max(0, meanShotDuration)
        self.actionShare = actionShare.clamped01
        self.calmShare = calmShare.clamped01
        self.transitionShare = transitionShare.clamped01
        self.effectShare = effectShare.clamped01
        self.slowMotionShare = slowMotionShare.clamped01
        self.telemetryShare = telemetryShare.clamped01
        self.titleDensity = titleDensity.clamped01
        self.originalAudioShare = originalAudioShare.clamped01
        self.chronologicalOrder = chronologicalOrder.clamped01
        self.endingEnergy = endingEnergy.clamped01
        self.semanticTokens = semanticTokens
        self.embeddingCentroid = TasteEmbeddingProfile.normalized(embeddingCentroid)
    }
}

/// Automatic local regression fixture. It stores aggregate edit features and
/// machine quality scores only; there is no human rating or manual A/B flow.
public struct TasteRegressionSample: Codable, Hashable, Sendable {
    public var contextKey: String
    public var proposedFeatures: TimelineTasteFeatures
    public var acceptedFeatures: TimelineTasteFeatures
    public var proposedAutomaticQuality: Double
    public var acceptedAutomaticQuality: Double
    public var createdAt: Date

    public init(contextKey: String, proposedFeatures: TimelineTasteFeatures, acceptedFeatures: TimelineTasteFeatures, proposedAutomaticQuality: Double, acceptedAutomaticQuality: Double, createdAt: Date = Date()) {
        self.contextKey = contextKey
        self.proposedFeatures = proposedFeatures
        self.acceptedFeatures = acceptedFeatures
        self.proposedAutomaticQuality = proposedAutomaticQuality.clamped01
        self.acceptedAutomaticQuality = acceptedAutomaticQuality.clamped01
        self.createdAt = createdAt
    }
}

public struct TasteRegressionReport: Codable, Hashable, Sendable {
    public var committed: Bool
    public var previousAgreement: Double
    public var proposedAgreement: Double
    public var qualityFloorPassed: Bool
    public var evaluatedSamples: Int
    public var reasons: [String]

    public init(committed: Bool, previousAgreement: Double, proposedAgreement: Double, qualityFloorPassed: Bool, evaluatedSamples: Int, reasons: [String]) {
        self.committed = committed
        self.previousAgreement = previousAgreement.clamped01
        self.proposedAgreement = proposedAgreement.clamped01
        self.qualityFloorPassed = qualityFloorPassed
        self.evaluatedSamples = max(0, evaluatedSamples)
        self.reasons = reasons
    }
}

public struct TasteLearningCommit: Sendable {
    public var profile: PersonalTasteProfile
    public var report: TasteRegressionReport
}

public struct PersonalTasteScore: Codable, Hashable, Sendable {
    public var technical: Double
    public var contextual: Double
    public var global: Double
    public var perceptual: Double
    public var personalTaste: Double
    public var combined: Double
    public var confidence: Double
    public var reasons: [String]

    public init(technical: Double, contextual: Double, global: Double, perceptual: Double, personalTaste: Double, combined: Double, confidence: Double, reasons: [String]) {
        self.technical = technical.clamped01
        self.contextual = contextual.clamped01
        self.global = global.clamped01
        self.perceptual = perceptual.clamped01
        self.personalTaste = personalTaste.clamped01
        self.combined = combined.clamped01
        self.confidence = confidence.clamped01
        self.reasons = reasons
    }
}

public struct PersonalTasteDiagnostics: Codable, Hashable, Sendable {
    public var contextKey: String
    public var profileConfidence: Double
    public var signalCount: Int
    public var discoveredStyle: DiscoveredTasteStyle?
    public var explorationApplied: Bool
    public var variantScores: [String: PersonalTasteScore]
    public var regressionReport: TasteRegressionReport?
    public var reasons: [String]

    public init(contextKey: String, profileConfidence: Double, signalCount: Int, discoveredStyle: DiscoveredTasteStyle?, explorationApplied: Bool, variantScores: [String: PersonalTasteScore] = [:], regressionReport: TasteRegressionReport? = nil, reasons: [String] = []) {
        self.contextKey = contextKey
        self.profileConfidence = profileConfidence.clamped01
        self.signalCount = max(0, signalCount)
        self.discoveredStyle = discoveredStyle
        self.explorationApplied = explorationApplied
        self.variantScores = variantScores
        self.regressionReport = regressionReport
        self.reasons = reasons
    }
}

// MARK: - Context and timeline feature extraction

public struct TasteContextResolver: Sendable {
    public init() {}

    public func resolve(projectStyle: ProjectStyleProfile, timeline: Timeline? = nil, assets: [MediaAsset] = [], analyses: [AnalysisResult] = []) -> TasteContext {
        let tags = Set(analyses.flatMap(\.sceneTags).map { $0.lowercased() })
        let activity: String?
        if !tags.isDisjoint(with: ["bicycle", "cycling", "bike", "велосипед"]) { activity = "cycling" }
        else if !tags.isDisjoint(with: ["fishing", "fish", "рыбалка"]) { activity = "fishing" }
        else if !tags.isDisjoint(with: ["travel", "journey", "trip", "путешествие"]) { activity = "travel" }
        else if projectStyle.peopleShare > 0.48 { activity = "family" }
        else { activity = nil }
        let camera: String?
        let fps = assets.compactMap { $0.metadata.frameRate }
        if projectStyle.telemetryShare > 0.15 { camera = "action-camera" }
        else if fps.contains(where: { $0 >= 50 }) { camera = "high-frame-rate" }
        else { camera = nil }
        let format: String?
        if let timeline {
            let ratio = Double(timeline.width) / Double(max(1, timeline.height))
            format = ratio < 0.85 ? "vertical" : ratio < 1.15 ? "square" : "landscape"
        } else { format = nil }
        let duration = timeline?.duration
        let bucket = duration.map { $0 < 35 ? "short" : $0 < 120 ? "medium" : "long" }
        let discovered = tags.filter { ["water", "sunset", "mountain", "people", "pov", "drone", "nature", "city"].contains($0) }
        return TasteContext(
            activity: activity,
            projectType: projectStyle.internalLabel,
            eventType: projectStyle.actionShare > 0.45 ? "action-event" : projectStyle.peopleShare > 0.45 ? "people-event" : "mixed-event",
            cameraType: camera,
            socialFormat: format,
            durationBucket: bucket,
            discoveredTokens: discovered
        )
    }
}

public struct TimelineTasteFeatureExtractor: Sendable {
    public init() {}

    public func features(timeline: Timeline, candidates: [UUID: Candidate]) -> TimelineTasteFeatures {
        let items = timeline.items.filter { $0.kind != .title && $0.overlay == nil }
        let count = Double(max(1, items.count))
        let values = items.compactMap { $0.candidateID.flatMap { candidates[$0] } }
        let actionCount = items.filter { item in
            item.storyRole == .action || item.storyRole == .climax || item.candidateID.flatMap { candidates[$0] }.map { ($0.insights?.dynamics ?? $0.scores.action) > 0.62 } == true
        }.count
        let calmCount = items.filter { item in
            item.storyRole == .intro || item.storyRole == .outro || item.storyRole == .bRoll || item.candidateID.flatMap { candidates[$0] }.map { ($0.insights?.dynamics ?? $0.scores.action) < 0.38 } == true
        }.count
        let embeddings = values.compactMap { $0.insights?.visualEmbedding?.values }.filter { !$0.isEmpty }
        let dimensions = embeddings.map(\.count).min() ?? 0
        let centroid: [Float] = dimensions == 0 ? [] : (0..<dimensions).map { index in
            embeddings.reduce(Float.zero) { $0 + $1[index] } / Float(embeddings.count)
        }
        let orderedStarts = items.compactMap { item -> Double? in
            guard let id = item.candidateID, candidates[id] != nil else { return nil }
            return item.sourceStart
        }
        let chronologicalPairs = zip(orderedStarts, orderedStarts.dropFirst())
        let chronological = orderedStarts.count < 2 ? 1 : Double(chronologicalPairs.filter { $0 <= $1 }.count) / Double(orderedStarts.count - 1)
        let ending = items.suffix(max(1, items.count / 4)).compactMap { $0.candidateID.flatMap { candidates[$0] } }
        let endingEnergy = ending.isEmpty ? 0.5 : ending.reduce(0) { $0 + ($1.insights?.dynamics ?? $1.scores.action) } / Double(ending.count)
        let audible = items.filter { $0.effectiveAudioAdjustments.effectiveVolume > 0.55 }.count
        return TimelineTasteFeatures(
            duration: timeline.duration,
            meanShotDuration: items.isEmpty ? 0 : items.reduce(0) { $0 + $1.timelineDuration } / count,
            actionShare: Double(actionCount) / count,
            calmShare: Double(calmCount) / count,
            transitionShare: Double(items.filter { $0.transition != nil }.count + timeline.effectiveTransitionItems.count) / count,
            effectShare: Double(items.filter { $0.effect != nil }.count + timeline.effectiveEffects.count) / count,
            slowMotionShare: Double(items.filter { $0.speed < 0.95 || $0.speedRamp != nil }.count) / count,
            telemetryShare: Double(items.filter { $0.telemetryOverlay != nil }.count + timeline.effectiveTelemetryItems.count) / count,
            titleDensity: Double(timeline.effectiveTitleItems.count + timeline.items.filter { $0.kind == .title }.count) / count,
            originalAudioShare: Double(audible) / count,
            chronologicalOrder: chronological,
            endingEnergy: endingEnergy,
            semanticTokens: Set(values.flatMap(\.tags).map { $0.lowercased() }),
            embeddingCentroid: centroid
        )
    }
}

/// Adds P7 signals to the established P3 extractor. The base extractor remains
/// the single source for legacy feature names; this layer contributes role,
/// context, exact-duration, effect and anonymous semantic evidence.
public struct AdaptivePreferenceSignalExtractor: Sendable {
    public init() {}

    public func signals(
        before: Timeline,
        after: Timeline,
        context: TasteContext,
        candidates: [UUID: Candidate],
        source: PreferenceSignalSource = .manualEdit
    ) -> [PreferenceSignal] {
        var result = PreferenceSignalExtractor().signals(before: before, after: after, contextKey: context.key, source: source)
        let old = before.items.filter { $0.kind != .title && $0.overlay == nil }
        let new = after.items.filter { $0.kind != .title && $0.overlay == nil }
        let oldByID = Dictionary(uniqueKeysWithValues: old.map { ($0.id, $0) })
        let newByID = Dictionary(uniqueKeysWithValues: new.map { ($0.id, $0) })

        func append(_ feature: String, _ value: Double, _ confidence: Double, _ source: PreferenceSignalSource, item: TimelineItem? = nil) {
            let candidate = item?.candidateID.flatMap { candidates[$0] }
            result.append(PreferenceSignal(
                feature: feature,
                value: value,
                confidence: confidence,
                source: source,
                contextKey: context.key,
                semanticTokens: candidate.map { Set($0.tags.map { $0.lowercased() }) },
                visualPreferenceEmbedding: candidate?.insights?.visualEmbedding?.values,
                role: item?.storyRole
            ))
        }

        let removed = old.filter { newByID[$0.id] == nil }
        let restored = new.filter { oldByID[$0.id] == nil }
        for item in removed.prefix(12) {
            let action = item.storyRole == .action || item.storyRole == .climax
                || item.candidateID.flatMap { candidates[$0] }.map { ($0.insights?.dynamics ?? $0.scores.action) > 0.62 } == true
            append(action ? "actionPreference" : "calmMomentPreference", -0.86, 0.82, .deletion, item: item)
        }
        for item in restored.prefix(12) {
            let action = item.storyRole == .action || item.storyRole == .climax
                || item.candidateID.flatMap { candidates[$0] }.map { ($0.insights?.dynamics ?? $0.scores.action) > 0.62 } == true
            append(action ? "actionPreference" : "calmMomentPreference", 0.72, 0.72, .restoration, item: item)
        }

        let common = old.compactMap { item in newByID[item.id].map { (item, $0) } }
        for pair in common where abs(pair.0.timelineDuration - pair.1.timelineDuration) > 0.08 {
            let roleFeature: String
            switch pair.1.storyRole {
            case .action: roleFeature = "duration.action"
            case .climax: roleFeature = "duration.climax"
            case .reaction: roleFeature = "duration.reaction"
            case .intro: roleFeature = "duration.intro"
            case .outro: roleFeature = "duration.outro"
            default: roleFeature = "duration.calm"
            }
            let normalizedDuration = min(1, max(-1, pair.1.timelineDuration / 6 - 1))
            append(roleFeature, normalizedDuration, min(0.92, 0.56 + abs(pair.1.timelineDuration - pair.0.timelineDuration) / 8), .trim, item: pair.1)
            append("clipDurationPreference", pair.1.timelineDuration > pair.0.timelineDuration ? 0.82 : -0.82, 0.78, .trim, item: pair.1)
            append(pair.1.timelineDuration > pair.0.timelineDuration ? "cut.holdPreference" : "cut.earlierExitPreference", 0.78, 0.74, .trim, item: pair.1)
        }
        let oldPredecessor = Dictionary(uniqueKeysWithValues: old.enumerated().dropFirst().map { (old[$0.offset].id, old[$0.offset - 1]) })
        let newPredecessor = Dictionary(uniqueKeysWithValues: new.enumerated().dropFirst().map { (new[$0.offset].id, new[$0.offset - 1]) })
        for item in new where oldPredecessor[item.id]?.id != newPredecessor[item.id]?.id {
            guard let incomingID = item.candidateID, let incoming = candidates[incomingID],
                  let predecessor = newPredecessor[item.id], let predecessorID = predecessor.candidateID,
                  let outgoing = candidates[predecessorID] else { continue }
            let shared = incoming.tags.intersection(outgoing.tags)
            let similarity = Double(shared.count) / Double(max(1, incoming.tags.union(outgoing.tags).count))
            let energyDelta = abs((incoming.insights?.dynamics ?? incoming.scores.action) - (outgoing.insights?.dynamics ?? outgoing.scores.action))
            append("cut.semanticBridgePreference", similarity * 2 - 1, 0.68, source, item: item)
            append("cut.energyContrastPreference", energyDelta * 2 - 1, 0.64, source, item: item)
            if let leftArea = outgoing.insights?.subjectTracking?.mainSubject?.observations.last?.region.area,
               let rightArea = incoming.insights?.subjectTracking?.mainSubject?.observations.first?.region.area {
                let scaleRatio = min(5, max(leftArea, rightArea) / max(0.001, min(leftArea, rightArea)))
                append("cut.shotScaleChangePreference", min(1, (scaleRatio - 1) / 3), 0.66, source, item: item)
            }
        }
        if abs(after.duration - before.duration) > 0.25 {
            let normalizedFilmDuration = min(1, max(-1, after.duration / 90 - 1))
            append("duration.film", normalizedFilmDuration, min(0.92, 0.58 + abs(after.duration - before.duration) / max(10, before.duration) * 0.32), .trim)
        }

        let oldRamp = old.filter { $0.speedRamp != nil }.count
        let newRamp = new.filter { $0.speedRamp != nil }.count
        if oldRamp != newRamp { append("speedRamp", newRamp > oldRamp ? 0.86 : -0.86, 0.78, .speed) }
        let oldZoom = old.filter { item in [ClipEffect.zoomIn.rawValue, ClipEffect.zoomOut.rawValue, ClipEffect.pushIn.rawValue, ClipEffect.pullOut.rawValue].contains(item.effect) }.count
        let newZoom = new.filter { item in [ClipEffect.zoomIn.rawValue, ClipEffect.zoomOut.rawValue, ClipEffect.pushIn.rawValue, ClipEffect.pullOut.rawValue].contains(item.effect) }.count
        if oldZoom != newZoom { append("zoom", newZoom > oldZoom ? 0.78 : -0.78, 0.70, source) }
        let oldStabilized = old.filter { ($0.effectiveVideoAdjustments.stabilization ?? 0) > 0.05 }.count
        let newStabilized = new.filter { ($0.effectiveVideoAdjustments.stabilization ?? 0) > 0.05 }.count
        if oldStabilized != newStabilized { append("stabilization", newStabilized > oldStabilized ? 0.74 : -0.74, 0.68, source) }
        let oldColor = old.filter { !$0.effectiveVideoAdjustments.isNeutral }.count
        let newColor = new.filter { !$0.effectiveVideoAdjustments.isNeutral }.count
        if oldColor != newColor { append("colorPreference", newColor > oldColor ? 0.72 : -0.72, 0.66, source) }
        let oldSFX = before.effectiveAudioClips.filter { $0.role == .soundEffect }.count
        let newSFX = after.effectiveAudioClips.filter { $0.role == .soundEffect }.count
        if oldSFX != newSFX { append("soundEffects", newSFX > oldSFX ? 0.82 : -0.82, 0.76, source) }
        let oldPhotos = old.filter { $0.kind == .photo && $0.effect != nil }.count
        let newPhotos = new.filter { $0.kind == .photo && $0.effect != nil }.count
        if oldPhotos != newPhotos { append("photoMotionPreference", newPhotos > oldPhotos ? 0.82 : -0.82, 0.74, source) }

        if before.music?.bpm != after.music?.bpm, let music = after.music {
            append("musicBPM", min(1, max(-1, (music.bpm - 117.5) / 62.5)), 0.82, .music)
        }
        if before.music?.style != after.music?.style, let music = after.music {
            append("musicGenre:\(music.style.rawValue)", 0.82, 0.78, .music)
            let energy: Double
            switch music.style {
            case .energetic, .electronic: energy = 0.82
            case .cinematic, .joyful: energy = 0.62
            case .acoustic: energy = 0.42
            case .calm: energy = 0.22
            }
            append("musicEnergy", energy * 2 - 1, 0.72, .music)
            append("musicDuration", min(1, max(-1, after.duration / 90 - 1)), 0.58, .music)
        }
        if before.music?.structure != after.music?.structure, after.music?.structure != nil {
            append("musicSyncPreference", 0.72, 0.70, .music)
            for section in (after.music?.structure?.sections ?? []).prefix(8) {
                append("musicSection:\(section.kind.rawValue)", section.energy * 2 - 1, section.confidence ?? 0.55, .music)
            }
        }
        if before.music?.trackID != after.music?.trackID, before.music?.trackID != nil {
            append("musicReplacement", 0.8, 0.84, .music)
        }

        let oldTitles = before.effectiveTitleItems
        let newTitles = after.effectiveTitleItems
        if let oldMean = meanTitleDuration(oldTitles), let newMean = meanTitleDuration(newTitles), abs(oldMean - newMean) > 0.1 {
            append("titleDuration", min(1, max(-1, newMean / 6 - 1)), 0.68, .title)
        }
        let oldTitlesByID = Dictionary(uniqueKeysWithValues: oldTitles.map { ($0.id, $0) })
        for title in newTitles {
            guard let oldTitle = oldTitlesByID[title.id] else { continue }
            if abs(title.style.fontSize - oldTitle.style.fontSize) > 1 {
                append("titleSize", min(1, max(-1, (title.style.fontSize - 96) / 78)), 0.72, .title)
            }
            if abs(title.style.effectiveYPosition - oldTitle.style.effectiveYPosition) > 0.02 {
                append("titlePosition", min(1, max(-1, title.style.effectiveYPosition * 2 - 1)), 0.68, .title)
            }
            if title.animation != oldTitle.animation {
                let animated = title.animation.entrance == .none && title.animation.exit == .none ? -0.85 : 0.72
                append("titleAnimation", animated, 0.70, .title)
            }
        }
        let roles = new.compactMap(\.storyRole)
        if roles != old.compactMap(\.storyRole), !roles.isEmpty {
            result.append(PreferenceSignal(feature: "structure:\(roles.map(\.rawValue).joined(separator: ">"))", value: 0.72, confidence: 0.66, source: .reorder, contextKey: context.key))
        }
        // A title, volume or colour edit does not approve the existing ending.
        // Learn it only when the closing source or its selected range changed.
        if let last = new.last,
           old.last?.assetID != last.assetID || old.last?.sourceStart != last.sourceStart || old.last?.sourceDuration != last.sourceDuration,
           let candidate = last.candidateID.flatMap({ candidates[$0] }) {
            let energy = candidate.insights?.dynamics ?? candidate.scores.action
            append("endingPreference", energy * 2 - 1, 0.58, source, item: last)
        }
        return result
    }

    private func meanTitleDuration(_ values: [TitleTimelineItem]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0) { $0 + $1.duration } / Double(values.count)
    }
}

// MARK: - Adaptive updates

public struct AdaptiveTasteProfileUpdater: Sendable {
    public init() {}

    public func updating(_ profile: PersonalTasteProfile, with signals: [PreferenceSignal], now: Date) -> PersonalTasteProfile {
        guard !signals.isEmpty else { return profile }
        var result = profile
        var contexts = result.adaptiveContexts ?? [:]
        var durations = result.durationPreferences ?? TasteDurationPreferences()
        var embedding = result.embeddingTaste ?? TasteEmbeddingProfile(lastUpdated: now)

        for signal in signals {
            let canonical = PersonalTasteProfile.canonicalAdaptiveFeature(signal.feature)
            // Do not seed a fresh P7 estimate from the legacy value updated in
            // the same pass; that would count every natural edit twice.
            let previous = result.adaptivePreferenceMap[canonical] ?? durations.estimate(for: signal.feature)
            let updated = update(previous, signal: signal, now: now)
            result.setAdaptiveEstimate(updated, for: signal.feature)
            if signal.feature.hasPrefix("duration.") { durations.set(updated, for: signal.feature) }

            if let key = signal.contextKey, !key.isEmpty {
                var contextual = contexts[key] ?? AdaptiveTasteContextProfile(context: TasteContext(projectType: key), lastUpdated: now)
                contextual.preferences[signal.feature] = update(contextual.preferences[signal.feature], signal: signal, now: now, scale: 0.78)
                contextual.sampleCount += 1
                contextual.lastUpdated = now
                contexts[key] = contextual
            }
            if let vector = signal.visualPreferenceEmbedding, !vector.isEmpty {
                embedding = updateEmbedding(embedding, vector: vector, tokens: signal.semanticTokens ?? [], positive: signal.value >= 0, weight: signal.confidence, now: now)
            } else if let tokens = signal.semanticTokens, !tokens.isEmpty {
                embedding = updateEmbedding(embedding, vector: [], tokens: tokens, positive: signal.value >= 0, weight: signal.confidence, now: now)
            }
        }
        result.adaptiveContexts = contexts
        result.durationPreferences = durations
        result.embeddingTaste = embedding.sampleCount > 0 ? embedding : result.embeddingTaste
        result.lastDecayAt = now
        result.structurePatterns = updateStructurePatterns(result.structurePatterns ?? [], signals: signals, now: now)
        result.discoveredStyle = discoverStyle(result, now: now)
        result.musicTaste = updateMusicDetails(result.musicTaste ?? MusicTasteProfile(), profile: result, signals: signals)
        result.musicTaste?.replacementCount += signals.filter { $0.feature == "musicReplacement" }.count
        result.titleTaste = updateTitleDetails(result.titleTaste ?? TitleTasteProfile(), profile: result)
        return result
    }

    private func update(_ previous: AdaptiveTasteEstimate?, signal: PreferenceSignal, now: Date, scale: Double = 1) -> AdaptiveTasteEstimate {
        let old = previous?.decayed(at: now) ?? AdaptiveTasteEstimate(lastUpdated: now)
        let weight = max(0.08, signal.confidence * scale)
        let evidence = old.evidenceWeight + weight
        let value = (old.value * old.evidenceWeight + signal.value * weight) / max(0.000_001, evidence)
        let polarity: TasteSignalPolarity = signal.value > 0.08 ? .positive : signal.value < -0.08 ? .negative : .neutral
        return AdaptiveTasteEstimate(
            value: value,
            confidence: AdaptiveTasteEstimate.confidence(for: evidence),
            sampleCount: old.sampleCount + 1,
            positiveCount: old.positiveCount + (polarity == .positive ? 1 : 0),
            negativeCount: old.negativeCount + (polarity == .negative ? 1 : 0),
            neutralCount: old.neutralCount + (polarity == .neutral ? 1 : 0),
            evidenceWeight: evidence,
            lastUpdated: now
        )
    }

    private func updateEmbedding(_ previous: TasteEmbeddingProfile, vector: [Float], tokens: Set<String>, positive: Bool, weight: Double, now: Date) -> TasteEmbeddingProfile {
        var result = previous
        let learningRate = min(0.28, max(0.04, weight / Double(max(2, previous.sampleCount + 1))))
        if !vector.isEmpty {
            let normalized = TasteEmbeddingProfile.normalized(vector)
            if positive { result.positiveCentroid = blend(result.positiveCentroid, normalized, rate: learningRate) }
            else { result.negativeCentroid = blend(result.negativeCentroid, normalized, rate: learningRate) }
        }
        for token in tokens.map({ $0.lowercased() }).prefix(24) {
            if positive { result.positiveTokens[token, default: 0] += weight }
            else { result.negativeTokens[token, default: 0] += weight }
        }
        result.sampleCount += 1
        result.confidence = AdaptiveTasteEstimate.confidence(for: Double(result.sampleCount) * 0.72)
        result.lastUpdated = now
        return result
    }

    private func blend(_ lhs: [Float], _ rhs: [Float], rate: Double) -> [Float] {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return rhs }
        return TasteEmbeddingProfile.normalized(zip(lhs, rhs).map { Float(1 - rate) * $0.0 + Float(rate) * $0.1 })
    }

    private func discoverStyle(_ profile: PersonalTasteProfile, now: Date) -> DiscoveredTasteStyle? {
        let action = profile.adaptiveEstimate(for: "actionPreference") ?? profile.adaptiveEstimate(for: "action")
        let cinematic = profile.adaptiveEstimate(for: "colorPreference") ?? profile.adaptiveEstimate(for: "cinematic")
        let atmosphere = profile.adaptiveEstimate(for: "calmMomentPreference") ?? profile.adaptiveEstimate(for: "atmosphere")
        let travelTokens = profile.embeddingTaste?.positiveTokens.filter { ["travel", "journey", "water", "sunset", "mountain", "pov", "cycling"].contains($0.key) }.values.reduce(0, +) ?? 0
        let confidence = max(action?.confidence ?? 0, cinematic?.confidence ?? 0, atmosphere?.confidence ?? 0, profile.embeddingTaste?.confidence ?? 0)
        guard confidence >= 0.28 else { return nil }
        let words: [String]
        if (action?.value ?? 0) > 0.25 && ((cinematic?.value ?? 0) > 0.12 || travelTokens > 0.5) { words = ["Cinematic", "Action", "Travel"] }
        else if (atmosphere?.value ?? 0) > 0.25 { words = ["Atmospheric", "Cinematic"] }
        else if (profile.adaptiveEstimate(for: "pacingPreference")?.value ?? 0) > 0.25 { words = ["Dynamic", "Compact"] }
        else { words = ["Adaptive", "Personal"] }
        return DiscoveredTasteStyle(label: words.joined(separator: " "), confidence: confidence, evidence: ["implicit edits: \(profile.totalSignalCount)", "context models: \(profile.adaptiveContexts?.count ?? 0)"], lastUpdated: now)
    }

    private func updateMusicDetails(_ value: MusicTasteProfile, profile: PersonalTasteProfile, signals: [PreferenceSignal]) -> MusicTasteProfile {
        var result = value
        result.preferredBPM = profile.adaptiveEstimate(for: "musicBPM") ?? result.preferredBPM
        result.energy = profile.adaptiveEstimate(for: "musicEnergy") ?? result.energy
        result.beatSync = profile.adaptiveEstimate(for: "musicSyncPreference") ?? result.beatSync
        result.preferredTrackLength = profile.adaptiveEstimate(for: "musicDuration") ?? result.preferredTrackLength
        for signal in signals where signal.value > 0 {
            if signal.feature.hasPrefix("musicGenre:") {
                let key = String(signal.feature.dropFirst("musicGenre:".count))
                result.preferredGenres[key, default: 0] += signal.confidence
            } else if signal.feature.hasPrefix("musicSection:") {
                let key = String(signal.feature.dropFirst("musicSection:".count))
                result.preferredSections[key, default: 0] += signal.confidence
            }
        }
        return result
    }

    private func updateTitleDetails(_ value: TitleTasteProfile, profile: PersonalTasteProfile) -> TitleTasteProfile {
        var result = value
        result.size = profile.adaptiveEstimate(for: "titleSize") ?? result.size
        result.duration = profile.adaptiveEstimate(for: "titleDuration") ?? result.duration
        result.verticalPosition = profile.adaptiveEstimate(for: "titlePosition") ?? result.verticalPosition
        result.count = profile.adaptiveEstimate(for: "titlePreference") ?? result.count
        result.animationIntensity = profile.adaptiveEstimate(for: "titleAnimation") ?? result.animationIntensity
        return result
    }

    private func updateStructurePatterns(_ patterns: [TasteStructurePattern], signals: [PreferenceSignal], now: Date) -> [TasteStructurePattern] {
        var result = patterns
        for signal in signals where signal.feature.hasPrefix("structure:") && signal.value > 0 {
            let raw = String(signal.feature.dropFirst("structure:".count))
            let roles = raw.split(separator: ">").compactMap { StoryRole(rawValue: String($0)) }
            guard !roles.isEmpty else { continue }
            if let index = result.firstIndex(where: { $0.roles == roles }) {
                result[index].count += 1
                result[index].confidence = AdaptiveTasteEstimate.confidence(for: Double(result[index].count))
                result[index].lastUpdated = now
            } else {
                result.append(TasteStructurePattern(roles: roles, confidence: AdaptiveTasteEstimate.confidence(for: 1), lastUpdated: now))
            }
        }
        return result.sorted { $0.confidence > $1.confidence }.prefix(12).map { $0 }
    }
}

// MARK: - Personalized evaluation and safe exploration

public struct TasteExplorationPolicy: Sendable {
    public init() {}

    public func shouldExplore(profile: PersonalTasteProfile, projectFingerprint: String, rate: Double = 0.10) -> Bool {
        guard profile.totalSignalCount >= 5 else { return false }
        let hash = projectFingerprint.utf8.reduce(UInt64(14_695_981_039_346_656_037)) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
        return Double(hash % 10_000) / 10_000 < rate.clamped01
    }

    public func exploratoryStyle(from style: DirectorStyleVector, profile: PersonalTasteProfile) -> DirectorStyleVector {
        // Explore one nearby, under-observed direction; never jump to a remote
        // style that could dominate the user's edit with one sample.
        let dimensions: [(String, Double)] = [
            ("cinematic", profile.adaptiveEstimate(for: "colorPreference")?.confidence ?? 0),
            ("atmosphere", profile.adaptiveEstimate(for: "calmMomentPreference")?.confidence ?? 0),
            ("visualDensity", profile.adaptiveEstimate(for: "storyDensity")?.confidence ?? 0),
            ("shotDuration", profile.adaptiveEstimate(for: "clipDurationPreference")?.confidence ?? 0)
        ]
        let key = dimensions.min { $0.1 < $1.1 }?.0 ?? "cinematic"
        return style.adjusted([key: 0.08])
    }
}

public struct PersonalizedMontageScorer: Sendable {
    public init() {}

    public func personalize(
        base: MontageGlobalScore,
        timeline: Timeline,
        candidates: [UUID: Candidate],
        profile: PersonalTasteProfile,
        context: TasteContext
    ) -> (MontageGlobalScore, PersonalTasteScore) {
        let localSignalCount = profile.totalSignalCount
        let features = TimelineTasteFeatureExtractor().features(timeline: timeline, candidates: candidates)
        let resolved = BundledEditorialTaste.resolving(profile)
        let startingFit = tasteFit(features: features, profile: resolved, contextKey: context.key)
        let localConfidence = profile.adaptiveConfidence
        // Many inherited dimensions must not dilute strong personal evidence
        // in a few dimensions. The existing calibrated confidence controls
        // the handover; no inherited samples enter the personal learner.
        let localFit = tasteFit(features: features, profile: profile, contextKey: context.key)
        let personal = startingFit * (1 - localConfidence) + localFit * localConfidence
        let confidence = max(localConfidence, resolved.adaptiveConfidence)
        let perceptual = timeline.directorRun?.perceptualScoreAfter ?? timeline.directorRun?.perceptualScoreBefore ?? base.reviewQuality
        let contextual = (base.projectStyleFit * 0.58 + base.storyArc * 0.22 + base.pacingQuality * 0.20).clamped01
        // Personal taste starts as a tie-breaker and earns at most 16% after
        // substantial evidence. Technical/perceptual quality always retains a
        // majority of the combined safety contribution.
        let tasteWeight = min(0.16, confidence * 0.16)
        let core = base.total * 0.60 + base.technicalQuality * 0.12 + contextual * 0.10 + perceptual * 0.18
        let combined = (core * (1 - tasteWeight) + personal * tasteWeight).clamped01
        var score = base
        score.total = combined
        score.personalTasteFit = personal
        let reasons = [
            "global \(Int((base.total * 100).rounded()))%",
            "perceptual \(Int((perceptual * 100).rounded()))%",
            "base \(BundledEditorialTaste.version) + \(localSignalCount) local signals: style fit \(Int((personal * 100).rounded()))% at confidence \(Int((confidence * 100).rounded()))%"
        ]
        return (score, PersonalTasteScore(
            technical: base.technicalQuality, contextual: contextual, global: base.total,
            perceptual: perceptual, personalTaste: personal, combined: combined,
            confidence: confidence, reasons: reasons
        ))
    }

    public func tasteFit(features: TimelineTasteFeatures, profile: PersonalTasteProfile, contextKey: String?) -> Double {
        guard profile.totalSignalCount > 0 else { return 0.5 }
        func directional(_ feature: String, actual: Double) -> (Double, Double) {
            let estimate = profile.adaptiveEstimate(for: feature, contextKey: contextKey)
            guard let estimate, estimate.confidence > 0 else { return (0.5, 0) }
            let expected = (estimate.value + 1) * 0.5
            return (max(0, 1 - abs(actual - expected)), estimate.confidence)
        }
        let observations: [(Double, Double)] = [
            directional("pacingPreference", actual: (1 - min(1, features.meanShotDuration / 8)).clamped01),
            directional("clipDurationPreference", actual: min(1, features.meanShotDuration / 8)),
            directional("storyDensity", actual: min(1, features.titleDensity + features.transitionShare + features.effectShare)),
            directional("actionPreference", actual: features.actionShare),
            directional("calmMomentPreference", actual: features.calmShare),
            directional("transitionPreference", actual: features.transitionShare),
            directional("effectPreference", actual: features.effectShare),
            directional("slowMotionPreference", actual: features.slowMotionShare),
            directional("telemetryPreference", actual: features.telemetryShare),
            directional("titlePreference", actual: features.titleDensity),
            directional("endingPreference", actual: features.endingEnergy)
        ]
        let weighted = observations.reduce(into: (sum: 0.0, weight: 0.0)) { result, value in
            result.sum += value.0 * value.1
            result.weight += value.1
        }
        let embedding = profile.embeddingTaste.map { $0.affinity(embedding: features.embeddingCentroid, tokens: features.semanticTokens) } ?? 0.5
        let directionalScore = weighted.weight > 0 ? weighted.sum / weighted.weight : 0.5
        return (directionalScore * 0.74 + embedding * 0.26).clamped01
    }
}

public struct TasteRegressionGuard: Sendable {
    public init() {}

    public func evaluate(previous: PersonalTasteProfile, proposed: PersonalTasteProfile, samples: [TasteRegressionSample]) -> TasteRegressionReport {
        guard !samples.isEmpty else {
            return TasteRegressionReport(committed: true, previousAgreement: 0.5, proposedAgreement: 0.5, qualityFloorPassed: true, evaluatedSamples: 0, reasons: ["Нет автоматических regression samples; gradual confidence ограничивает влияние первой правки"])
        }
        let scorer = PersonalizedMontageScorer()
        func agreement(_ profile: PersonalTasteProfile) -> Double {
            samples.reduce(0) { total, sample in
                let accepted = scorer.tasteFit(features: sample.acceptedFeatures, profile: profile, contextKey: sample.contextKey)
                let proposed = scorer.tasteFit(features: sample.proposedFeatures, profile: profile, contextKey: sample.contextKey)
                return total + (0.5 + (accepted - proposed) * 0.5).clamped01
            } / Double(samples.count)
        }
        let previousAgreement = agreement(previous)
        let proposedAgreement = agreement(proposed)
        let qualityFloor = samples.allSatisfy { sample in
            sample.acceptedAutomaticQuality + 0.08 >= sample.proposedAutomaticQuality
        }
        let committed = qualityFloor && proposedAgreement + 0.035 >= previousAgreement
        let reasons = [
            "automatic samples: \(samples.count)",
            "model agreement \(Int((previousAgreement * 100).rounded()))% → \(Int((proposedAgreement * 100).rounded()))%",
            qualityFloor ? "automatic quality floor passed" : "accepted edit falls below automatic quality floor"
        ]
        return TasteRegressionReport(committed: committed, previousAgreement: previousAgreement, proposedAgreement: proposedAgreement, qualityFloorPassed: qualityFloor, evaluatedSamples: samples.count, reasons: reasons)
    }
}

// MARK: - PersonalTasteProfile helpers

extension PersonalTasteProfile {
    public var adaptiveConfidence: Double {
        let values = adaptivePreferenceMap.values.filter { $0.sampleCount > 0 }
        guard !values.isEmpty else { return confidence }
        let weighted = values.reduce(0) { $0 + $1.confidence * min(1, Double($1.sampleCount) / 8) } / Double(values.count)
        return max(confidence, weighted).clamped01
    }

    public var adaptivePreferenceMap: [String: AdaptiveTasteEstimate] {
        var values: [String: AdaptiveTasteEstimate] = [:]
        let pairs: [(String, AdaptiveTasteEstimate?)] = [
            ("pacingPreference", pacingPreference), ("clipDurationPreference", clipDurationPreference),
            ("storyDensity", storyDensity), ("actionPreference", actionPreference),
            ("calmMomentPreference", calmMomentPreference), ("transitionPreference", transitionPreference),
            ("effectPreference", effectPreference), ("slowMotionPreference", slowMotionPreference),
            ("musicSyncPreference", musicSyncPreference), ("titlePreference", titlePreference),
            ("telemetryPreference", telemetryPreference), ("colorPreference", colorPreference),
            ("photoMotionPreference", photoMotionPreference), ("endingPreference", endingPreference)
        ]
        for (key, value) in pairs { if let value { values[key] = value } }
        return values
    }

    public func adaptiveEstimate(for feature: String, contextKey: String? = nil) -> AdaptiveTasteEstimate? {
        let canonical = Self.canonicalAdaptiveFeature(feature)
        let global = adaptivePreferenceMap[canonical]
            ?? durationPreferences?.estimate(for: feature)
            ?? preferences[feature].map { AdaptiveTasteEstimate(value: $0.mean, confidence: $0.confidence, sampleCount: max(0, Int($0.evidenceWeight.rounded())), evidenceWeight: $0.evidenceWeight, lastUpdated: $0.updatedAt) }
        guard let contextKey, let contextual = adaptiveContexts?[contextKey]?.preferences[feature] ?? adaptiveContexts?[contextKey]?.preferences[canonical] else { return global }
        guard let global else { return contextual }
        let weight = min(0.72, contextual.confidence * 0.72)
        return AdaptiveTasteEstimate(
            value: global.value * (1 - weight) + contextual.value * weight,
            confidence: max(global.confidence, contextual.confidence * 0.9),
            sampleCount: global.sampleCount + contextual.sampleCount,
            positiveCount: global.positiveCount + contextual.positiveCount,
            negativeCount: global.negativeCount + contextual.negativeCount,
            neutralCount: global.neutralCount + contextual.neutralCount,
            evidenceWeight: global.evidenceWeight + contextual.evidenceWeight,
            lastUpdated: max(global.lastUpdated, contextual.lastUpdated)
        )
    }

    mutating func setAdaptiveEstimate(_ value: AdaptiveTasteEstimate, for feature: String) {
        switch Self.canonicalAdaptiveFeature(feature) {
        case "pacingPreference": pacingPreference = value
        case "clipDurationPreference": clipDurationPreference = value
        case "storyDensity": storyDensity = value
        case "actionPreference": actionPreference = value
        case "calmMomentPreference": calmMomentPreference = value
        case "transitionPreference": transitionPreference = value
        case "effectPreference": effectPreference = value
        case "slowMotionPreference": slowMotionPreference = value
        case "musicSyncPreference": musicSyncPreference = value
        case "titlePreference": titlePreference = value
        case "telemetryPreference": telemetryPreference = value
        case "colorPreference": colorPreference = value
        case "photoMotionPreference": photoMotionPreference = value
        case "endingPreference": endingPreference = value
        default: break
        }
    }

    static func canonicalAdaptiveFeature(_ feature: String) -> String {
        switch feature {
        case "pacing": return "pacingPreference"
        case "shotDuration": return "clipDurationPreference"
        case "visualDensity": return "storyDensity"
        case "action": return "actionPreference"
        case "atmosphere", "calmMoment": return "calmMomentPreference"
        case "transitionIntensity", "transitions": return "transitionPreference"
        case "effects", "speedRamp", "zoom", "stabilization", "soundEffects": return "effectPreference"
        case "slowMotion": return "slowMotionPreference"
        case "beatSync", "musicSync": return "musicSyncPreference"
        case "titles", "chapterTitles": return "titlePreference"
        case "telemetry": return "telemetryPreference"
        case "color", "filter": return "colorPreference"
        case "photoMotion": return "photoMotionPreference"
        case "endingEnergy", "endingStyle": return "endingPreference"
        default: return feature
        }
    }
}
