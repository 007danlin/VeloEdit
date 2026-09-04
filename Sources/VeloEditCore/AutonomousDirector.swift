import Foundation

/// Continuous editorial coordinates used by AI Director 3.0. Presets remain a
/// weak fallback, but never become a closed list of styles.
public struct DirectorStyleVector: Codable, Hashable, Sendable {
    public var energy: Double
    public var cinematic: Double
    public var emotional: Double
    public var action: Double
    public var intimacy: Double
    public var atmosphere: Double
    public var pacing: Double
    public var visualDensity: Double
    public var transitionIntensity: Double
    public var musicIntensity: Double
    /// Zero means short shots, one means deliberately long shots.
    public var shotDuration: Double

    public init(
        energy: Double = 0.5,
        cinematic: Double = 0.5,
        emotional: Double = 0.5,
        action: Double = 0.5,
        intimacy: Double = 0.5,
        atmosphere: Double = 0.5,
        pacing: Double = 0.5,
        visualDensity: Double = 0.5,
        transitionIntensity: Double = 0.2,
        musicIntensity: Double = 0.5,
        shotDuration: Double = 0.5
    ) {
        self.energy = energy.clamped01
        self.cinematic = cinematic.clamped01
        self.emotional = emotional.clamped01
        self.action = action.clamped01
        self.intimacy = intimacy.clamped01
        self.atmosphere = atmosphere.clamped01
        self.pacing = pacing.clamped01
        self.visualDensity = visualDensity.clamped01
        self.transitionIntensity = transitionIntensity.clamped01
        self.musicIntensity = musicIntensity.clamped01
        self.shotDuration = shotDuration.clamped01
    }

    public static let neutral = DirectorStyleVector()

    public func blended(with other: DirectorStyleVector, otherWeight: Double) -> DirectorStyleVector {
        let weight = otherWeight.clamped01
        func mix(_ lhs: Double, _ rhs: Double) -> Double { lhs * (1 - weight) + rhs * weight }
        return DirectorStyleVector(
            energy: mix(energy, other.energy),
            cinematic: mix(cinematic, other.cinematic),
            emotional: mix(emotional, other.emotional),
            action: mix(action, other.action),
            intimacy: mix(intimacy, other.intimacy),
            atmosphere: mix(atmosphere, other.atmosphere),
            pacing: mix(pacing, other.pacing),
            visualDensity: mix(visualDensity, other.visualDensity),
            transitionIntensity: mix(transitionIntensity, other.transitionIntensity),
            musicIntensity: mix(musicIntensity, other.musicIntensity),
            shotDuration: mix(shotDuration, other.shotDuration)
        )
    }

    public func distance(to other: DirectorStyleVector) -> Double {
        let deltas = [
            energy - other.energy, cinematic - other.cinematic, emotional - other.emotional,
            action - other.action, intimacy - other.intimacy, atmosphere - other.atmosphere,
            pacing - other.pacing, visualDensity - other.visualDensity,
            transitionIntensity - other.transitionIntensity, musicIntensity - other.musicIntensity,
            shotDuration - other.shotDuration
        ]
        return min(1, sqrt(deltas.reduce(0) { $0 + $1 * $1 } / Double(deltas.count)) * 1.8)
    }

    func adjusted(_ changes: [String: Double]) -> DirectorStyleVector {
        func value(_ key: String, _ current: Double) -> Double { (current + changes[key, default: 0]).clamped01 }
        return DirectorStyleVector(
            energy: value("energy", energy), cinematic: value("cinematic", cinematic),
            emotional: value("emotional", emotional), action: value("action", action),
            intimacy: value("intimacy", intimacy), atmosphere: value("atmosphere", atmosphere),
            pacing: value("pacing", pacing), visualDensity: value("visualDensity", visualDensity),
            transitionIntensity: value("transitionIntensity", transitionIntensity),
            musicIntensity: value("musicIntensity", musicIntensity), shotDuration: value("shotDuration", shotDuration)
        )
    }
}

public struct ProjectStyleProfile: Codable, Hashable, Sendable {
    public var internalLabel: String
    public var vector: DirectorStyleVector
    public var shotVariety: Double
    public var sceneVariety: Double
    public var peopleShare: Double
    public var actionShare: Double
    public var speechShare: Double
    public var telemetryShare: Double
    public var usableMomentCount: Int
    public var confidence: Double
    public var evidence: [String]

    public init(
        internalLabel: String,
        vector: DirectorStyleVector,
        shotVariety: Double,
        sceneVariety: Double,
        peopleShare: Double,
        actionShare: Double,
        speechShare: Double,
        telemetryShare: Double,
        usableMomentCount: Int,
        confidence: Double,
        evidence: [String]
    ) {
        self.internalLabel = internalLabel
        self.vector = vector
        self.shotVariety = shotVariety.clamped01
        self.sceneVariety = sceneVariety.clamped01
        self.peopleShare = peopleShare.clamped01
        self.actionShare = actionShare.clamped01
        self.speechShare = speechShare.clamped01
        self.telemetryShare = telemetryShare.clamped01
        self.usableMomentCount = max(0, usableMomentCount)
        self.confidence = confidence.clamped01
        self.evidence = evidence
    }
}

public struct PreferenceEstimate: Codable, Hashable, Sendable {
    /// Signed preference in -1...1.
    public var mean: Double
    public var evidenceWeight: Double
    public var confidence: Double
    public var updatedAt: Date

    public init(mean: Double = 0, evidenceWeight: Double = 0, confidence: Double = 0, updatedAt: Date = Date()) {
        self.mean = min(max(-1, mean), 1)
        self.evidenceWeight = max(0, evidenceWeight)
        self.confidence = confidence.clamped01
        self.updatedAt = updatedAt
    }
}

public enum PreferenceSignalSource: String, Codable, CaseIterable, Hashable, Sendable {
    case manualEdit = "manual-edit"
    case deletion
    case restoration
    case trim
    case reorder
    case speed
    case transition
    case music
    case title
    case crop
    case telemetry
    case regenerate
    case undo
    case acceptedEdit = "accepted-edit"
}

/// Contains no media path, transcript, thumbnail, candidate ID or user text.
/// Only an editorial direction and broad project context are persisted locally.
public struct PreferenceSignal: Codable, Hashable, Sendable {
    public var feature: String
    public var value: Double
    public var confidence: Double
    public var source: PreferenceSignalSource
    public var contextKey: String?
    public var createdAt: Date

    /// Optional P7 evidence is deliberately anonymous: no path, asset ID,
    /// transcript or frame is persisted. Embeddings are compact normalized
    /// descriptors and tokens are broad visual concepts only.
    public var semanticTokens: Set<String>?
    public var visualPreferenceEmbedding: [Float]?
    public var role: StoryRole?

    public init(feature: String, value: Double, confidence: Double, source: PreferenceSignalSource, contextKey: String? = nil, createdAt: Date = Date(), semanticTokens: Set<String>? = nil, visualPreferenceEmbedding: [Float]? = nil, role: StoryRole? = nil) {
        self.feature = feature
        self.value = min(max(-1, value), 1)
        self.confidence = confidence.clamped01
        self.source = source
        self.contextKey = contextKey
        self.createdAt = createdAt
        self.semanticTokens = semanticTokens
        self.visualPreferenceEmbedding = visualPreferenceEmbedding.map(TasteEmbeddingProfile.normalized)
        self.role = role
    }
}

public struct PersonalTasteProfile: Codable, Hashable, Sendable {
    public var preferences: [String: PreferenceEstimate]
    public var contextualPreferences: [String: [String: PreferenceEstimate]]
    public var totalSignalCount: Int
    public var updatedAt: Date

    /// P7 fields are optional so personal-taste-v1 files and older project
    /// manifests remain decodable without a migration prompt.
    public var pacingPreference: AdaptiveTasteEstimate?
    public var clipDurationPreference: AdaptiveTasteEstimate?
    public var storyDensity: AdaptiveTasteEstimate?
    public var actionPreference: AdaptiveTasteEstimate?
    public var calmMomentPreference: AdaptiveTasteEstimate?
    public var transitionPreference: AdaptiveTasteEstimate?
    public var effectPreference: AdaptiveTasteEstimate?
    public var slowMotionPreference: AdaptiveTasteEstimate?
    public var musicSyncPreference: AdaptiveTasteEstimate?
    public var titlePreference: AdaptiveTasteEstimate?
    public var telemetryPreference: AdaptiveTasteEstimate?
    public var colorPreference: AdaptiveTasteEstimate?
    public var photoMotionPreference: AdaptiveTasteEstimate?
    public var endingPreference: AdaptiveTasteEstimate?
    public var durationPreferences: TasteDurationPreferences?
    public var adaptiveContexts: [String: AdaptiveTasteContextProfile]?
    public var embeddingTaste: TasteEmbeddingProfile?
    public var discoveredStyle: DiscoveredTasteStyle?
    public var musicTaste: MusicTasteProfile?
    public var titleTaste: TitleTasteProfile?
    public var structurePatterns: [TasteStructurePattern]?
    public var regressionSamples: [TasteRegressionSample]?
    public var lastDecayAt: Date?

    public init(
        preferences: [String: PreferenceEstimate] = [:],
        contextualPreferences: [String: [String: PreferenceEstimate]] = [:],
        totalSignalCount: Int = 0,
        updatedAt: Date = Date(),
        pacingPreference: AdaptiveTasteEstimate? = nil,
        clipDurationPreference: AdaptiveTasteEstimate? = nil,
        storyDensity: AdaptiveTasteEstimate? = nil,
        actionPreference: AdaptiveTasteEstimate? = nil,
        calmMomentPreference: AdaptiveTasteEstimate? = nil,
        transitionPreference: AdaptiveTasteEstimate? = nil,
        effectPreference: AdaptiveTasteEstimate? = nil,
        slowMotionPreference: AdaptiveTasteEstimate? = nil,
        musicSyncPreference: AdaptiveTasteEstimate? = nil,
        titlePreference: AdaptiveTasteEstimate? = nil,
        telemetryPreference: AdaptiveTasteEstimate? = nil,
        colorPreference: AdaptiveTasteEstimate? = nil,
        photoMotionPreference: AdaptiveTasteEstimate? = nil,
        endingPreference: AdaptiveTasteEstimate? = nil,
        durationPreferences: TasteDurationPreferences? = nil,
        adaptiveContexts: [String: AdaptiveTasteContextProfile]? = nil,
        embeddingTaste: TasteEmbeddingProfile? = nil,
        discoveredStyle: DiscoveredTasteStyle? = nil,
        musicTaste: MusicTasteProfile? = nil,
        titleTaste: TitleTasteProfile? = nil,
        structurePatterns: [TasteStructurePattern]? = nil,
        regressionSamples: [TasteRegressionSample]? = nil,
        lastDecayAt: Date? = nil
    ) {
        self.preferences = preferences
        self.contextualPreferences = contextualPreferences
        self.totalSignalCount = max(0, totalSignalCount)
        self.updatedAt = updatedAt
        self.pacingPreference = pacingPreference
        self.clipDurationPreference = clipDurationPreference
        self.storyDensity = storyDensity
        self.actionPreference = actionPreference
        self.calmMomentPreference = calmMomentPreference
        self.transitionPreference = transitionPreference
        self.effectPreference = effectPreference
        self.slowMotionPreference = slowMotionPreference
        self.musicSyncPreference = musicSyncPreference
        self.titlePreference = titlePreference
        self.telemetryPreference = telemetryPreference
        self.colorPreference = colorPreference
        self.photoMotionPreference = photoMotionPreference
        self.endingPreference = endingPreference
        self.durationPreferences = durationPreferences
        self.adaptiveContexts = adaptiveContexts
        self.embeddingTaste = embeddingTaste
        self.discoveredStyle = discoveredStyle
        self.musicTaste = musicTaste
        self.titleTaste = titleTaste
        self.structurePatterns = structurePatterns
        self.regressionSamples = regressionSamples
        self.lastDecayAt = lastDecayAt
    }

    public var confidence: Double {
        guard !preferences.isEmpty else { return 0 }
        let mean = preferences.values.reduce(0) { $0 + $1.confidence } / Double(preferences.count)
        return (mean * min(1, Double(totalSignalCount) / 24)).clamped01
    }

    public func estimate(for feature: String, contextKey: String? = nil) -> PreferenceEstimate {
        let global = preferences[feature] ?? PreferenceEstimate()
        guard let contextKey, let contextual = contextualPreferences[contextKey]?[feature] else { return global }
        let weight = min(0.72, contextual.confidence * 0.72)
        return PreferenceEstimate(
            mean: global.mean * (1 - weight) + contextual.mean * weight,
            evidenceWeight: global.evidenceWeight + contextual.evidenceWeight,
            confidence: max(global.confidence, contextual.confidence * 0.9),
            updatedAt: max(global.updatedAt, contextual.updatedAt)
        )
    }

    public func styleVector(contextKey: String? = nil) -> DirectorStyleVector {
        let base = DirectorStyleVector.neutral
        func shifted(_ key: String, _ current: Double, scale: Double = 0.30) -> Double {
            let estimate = estimate(for: key, contextKey: contextKey)
            return (current + estimate.mean * estimate.confidence * scale).clamped01
        }
        return DirectorStyleVector(
            energy: shifted("energy", base.energy), cinematic: shifted("cinematic", base.cinematic),
            emotional: shifted("emotional", base.emotional), action: shifted("action", base.action),
            intimacy: shifted("intimacy", base.intimacy), atmosphere: shifted("atmosphere", base.atmosphere),
            pacing: shifted("pacing", base.pacing), visualDensity: shifted("visualDensity", base.visualDensity),
            transitionIntensity: shifted("transitionIntensity", base.transitionIntensity, scale: 0.22),
            musicIntensity: shifted("musicIntensity", base.musicIntensity), shotDuration: shifted("shotDuration", base.shotDuration)
        )
    }
}

public struct PreferenceLearningEngine: Sendable {
    public init() {}

    public func updating(_ profile: PersonalTasteProfile, with signals: [PreferenceSignal], now: Date = Date()) -> PersonalTasteProfile {
        guard !signals.isEmpty else { return profile }
        var result = profile
        for signal in signals {
            result.preferences[signal.feature] = update(result.preferences[signal.feature], signal: signal, now: now, contextualScale: 1)
            if let context = signal.contextKey {
                var values = result.contextualPreferences[context] ?? [:]
                values[signal.feature] = update(values[signal.feature], signal: signal, now: now, contextualScale: 0.78)
                result.contextualPreferences[context] = values
            }
        }
        result.totalSignalCount += signals.count
        result.updatedAt = now
        return AdaptiveTasteProfileUpdater().updating(result, with: signals, now: now)
    }

    private func update(_ previous: PreferenceEstimate?, signal: PreferenceSignal, now: Date, contextualScale: Double) -> PreferenceEstimate {
        let hadPrevious = previous != nil
        let previous = previous ?? PreferenceEstimate(updatedAt: now)
        let ageDays = max(0, now.timeIntervalSince(previous.updatedAt) / 86_400)
        let decayedWeight = previous.evidenceWeight * exp(-ageDays / 180)
        let signalWeight = max(0.05, signal.confidence * contextualScale)
        let neutralPriorWeight = hadPrevious ? 0 : 1.2
        let evidenceWeight = decayedWeight + signalWeight
        let posteriorWeight = evidenceWeight + neutralPriorWeight
        let posterior = (previous.mean * decayedWeight + signal.value * signalWeight) / max(0.000_001, posteriorWeight)
        return PreferenceEstimate(
            mean: posterior,
            evidenceWeight: evidenceWeight,
            confidence: 1 - exp(-evidenceWeight / 4.5),
            updatedAt: now
        )
    }
}

public actor LocalPersonalTasteStore {
    public let url: URL
    private var cached: PersonalTasteProfile?

    public init(url: URL = LocalPersonalTasteStore.defaultURL) {
        self.url = url
    }

    public static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("VeloEdit", isDirectory: true).appendingPathComponent("personal-taste-v1.json")
    }

    public func profile() -> PersonalTasteProfile {
        if let cached { return cached }
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder.veloEdit.decode(PersonalTasteProfile.self, from: data) else {
            let empty = PersonalTasteProfile()
            cached = empty
            return empty
        }
        cached = decoded
        return decoded
    }

    @discardableResult
    public func record(_ signals: [PreferenceSignal], now: Date = Date()) throws -> PersonalTasteProfile {
        try recordValidated(signals, regressionSample: nil, now: now).profile
    }

    public func recordValidated(_ signals: [PreferenceSignal], regressionSample: TasteRegressionSample?, now: Date = Date()) throws -> TasteLearningCommit {
        let previous = profile()
        var proposed = PreferenceLearningEngine().updating(previous, with: signals, now: now)
        var samples = previous.regressionSamples ?? []
        if let regressionSample { samples.append(regressionSample) }
        if samples.count > 48 { samples.removeFirst(samples.count - 48) }
        proposed.regressionSamples = samples
        let report = TasteRegressionGuard().evaluate(previous: previous, proposed: proposed, samples: samples)
        var updated = report.committed ? proposed : previous
        // A rejected learning update must not erase the automatic evidence
        // that exposed the regression; retain the bounded anonymous sample so
        // future proposed profiles are checked against it as well.
        updated.regressionSamples = samples
        guard updated != cached || !signals.isEmpty else { return TasteLearningCommit(profile: updated, report: report) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder.veloEdit.encode(updated).write(to: url, options: .atomic)
        cached = updated
        return TasteLearningCommit(profile: updated, report: report)
    }

    public func export(to destination: URL) throws {
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder.veloEdit.encode(profile()).write(to: destination, options: .atomic)
    }

    @discardableResult
    public func reset() throws -> PersonalTasteProfile {
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        let empty = PersonalTasteProfile()
        cached = empty
        return empty
    }
}

public struct OptimalDurationDecision: Codable, Hashable, Sendable {
    public var seconds: Double
    public var confidence: Double
    public var safeRange: ClosedRange<Double>
    public var strongMomentCount: Int
    public var reasons: [String]

    public init(seconds: Double, confidence: Double, safeRange: ClosedRange<Double>, strongMomentCount: Int, reasons: [String]) {
        self.seconds = max(5, seconds)
        self.confidence = confidence.clamped01
        let lower = max(5, safeRange.lowerBound)
        self.safeRange = lower...max(lower, safeRange.upperBound)
        self.strongMomentCount = max(0, strongMomentCount)
        self.reasons = reasons
    }
}

public struct AutonomousEditingGrammar: Codable, Hashable, Sendable {
    public var meanShotDuration: Double
    public var shotDurationVariation: Double
    public var cutDensity: Double
    public var transitionDensity: Double
    public var speedRampDensity: Double
    public var slowMotionDensity: Double
    public var bRollFrequency: Double
    public var reactionFrequency: Double
    public var photoMotionIntensity: Double
    public var telemetryDensity: Double
    public var titleDensity: Double
    public var effectDensity: Double
    public var confidence: Double
    public var reasons: [String]

    public init(style: DirectorStyleVector, project: ProjectStyleProfile, confidence: Double, personalAdjustments: [String: Double] = [:]) {
        let neutralWeight = max(0, 0.55 - confidence) * 0.75
        let safe = style.blended(with: .neutral, otherWeight: neutralWeight)
        meanShotDuration = 1.8 + safe.shotDuration * 5.8
        shotDurationVariation = (0.22 + project.shotVariety * 0.50).clamped01
        cutDensity = (0.25 + safe.pacing * 0.55 + safe.visualDensity * 0.20).clamped01
        // Clean cut is the default. A high style coordinate still only enables
        // a minority of motivated transitions.
        transitionDensity = (safe.transitionIntensity * 0.28 * confidence + 0.015 + personalAdjustments["transitionIntensity", default: 0] * 0.08).clamped01
        speedRampDensity = (safe.action * safe.energy * 0.20 * confidence + personalAdjustments["speedRamp", default: 0] * 0.10).clamped01
        slowMotionDensity = (safe.action * safe.cinematic * 0.14 * confidence + personalAdjustments["slowMotion", default: 0] * 0.10).clamped01
        bRollFrequency = (0.08 + safe.atmosphere * 0.20 + safe.visualDensity * 0.08 + personalAdjustments["bRoll", default: 0] * 0.08).clamped01
        reactionFrequency = (0.08 + safe.emotional * 0.26 + project.peopleShare * 0.16).clamped01
        photoMotionIntensity = (0.18 + safe.cinematic * 0.42 + personalAdjustments["photoMotion", default: 0] * 0.12).clamped01
        telemetryDensity = (project.telemetryShare * safe.action * 0.32 + personalAdjustments["telemetry", default: 0] * 0.14).clamped01
        titleDensity = ((project.speechShare > 0.45 ? 0.04 : 0.08) * confidence + personalAdjustments["titles", default: 0] * 0.10).clamped01
        effectDensity = ((safe.transitionIntensity * 0.08 + safe.action * 0.035) * confidence + personalAdjustments["effects", default: 0] * 0.07).clamped01
        self.confidence = confidence.clamped01
        let meanShotLabel = String(format: "%.1f", meanShotDuration)
        reasons = [
            "clean cut остаётся базовым переходом",
            "средняя длина кадра \(meanShotLabel) с",
            "плотность переходов \(Int((transitionDensity * 100).rounded()))%"
        ]
    }
}

public enum AutonomousStoryPattern: String, Codable, CaseIterable, Hashable, Sendable {
    case coldOpen = "cold-open"
    case journeyDiscovery = "journey-discovery"
    case emotionalJourney = "emotional-journey"
    case rapidPeakReaction = "rapid-peak-reaction"
    case atmosphericObservation = "atmospheric-observation"
    case minimalMontage = "minimal-montage"
    case adaptiveArc = "adaptive-arc"
}

public struct AutonomousStoryDecision: Codable, Hashable, Sendable {
    public var pattern: AutonomousStoryPattern
    public var confidence: Double
    public var energyCurve: [Double]
    public var reasons: [String]

    public init(pattern: AutonomousStoryPattern, confidence: Double, energyCurve: [Double], reasons: [String]) {
        self.pattern = pattern
        self.confidence = confidence.clamped01
        self.energyCurve = energyCurve.map(\.clamped01)
        self.reasons = reasons
    }

    public func roles(count: Int) -> [StoryRole] {
        guard count > 0 else { return [] }
        let templates: [StoryRole]
        switch pattern {
        case .coldOpen: templates = [.action, .setup, .buildup, .action, .climax, .reaction, .outro]
        case .journeyDiscovery: templates = [.intro, .setup, .buildup, .action, .climax, .reaction, .outro]
        case .emotionalJourney: templates = [.intro, .setup, .bRoll, .buildup, .climax, .reaction, .outro]
        case .rapidPeakReaction: templates = [.action, .action, .climax, .reaction, .outro]
        case .atmosphericObservation: templates = [.intro, .bRoll, .setup, .bRoll, .outro]
        case .minimalMontage: templates = count == 1 ? [.climax] : [.intro, .climax, .outro]
        case .adaptiveArc: templates = [.intro, .setup, .buildup, .action, .climax, .reaction, .outro]
        }
        if count == 1 { return [templates.contains(.climax) ? .climax : templates[0]] }
        return (0..<count).map { index in
            let position = Double(index) / Double(max(1, count - 1))
            let source = min(templates.count - 1, Int((position * Double(templates.count - 1)).rounded()))
            return templates[source]
        }
    }
}

public struct AutonomousMusicIntent: Codable, Hashable, Sendable {
    public var style: MusicStyle
    public var desiredEnergy: Double
    public var desiredBPM: Double
    public var desiredDuration: Double
    public var narrativeEnergyCurve: [Double]
    public var needsBuildAndDrop: Bool
    public var beatSyncIntensity: Double
    public var confidence: Double
    public var moodTokens: Set<String>
    public var reasons: [String]

    public init(style: MusicStyle, desiredEnergy: Double, desiredBPM: Double, desiredDuration: Double, narrativeEnergyCurve: [Double], needsBuildAndDrop: Bool, beatSyncIntensity: Double, confidence: Double, moodTokens: Set<String>, reasons: [String]) {
        self.style = style
        self.desiredEnergy = desiredEnergy.clamped01
        self.desiredBPM = min(max(55, desiredBPM), 180)
        self.desiredDuration = max(5, desiredDuration)
        self.narrativeEnergyCurve = narrativeEnergyCurve.map(\.clamped01)
        self.needsBuildAndDrop = needsBuildAndDrop
        self.beatSyncIntensity = beatSyncIntensity.clamped01
        self.confidence = confidence.clamped01
        self.moodTokens = moodTokens
        self.reasons = reasons
    }
}

public struct AutonomousDirectorDecision: Codable, Hashable, Sendable {
    public var projectStyle: ProjectStyleProfile
    public var personalTaste: DirectorStyleVector
    public var finalStyle: DirectorStyleVector
    public var projectConfidence: Double
    public var personalConfidence: Double
    public var personalSignalAdjustments: [String: Double]?
    public var duration: OptimalDurationDecision
    public var grammar: AutonomousEditingGrammar
    public var story: AutonomousStoryDecision
    public var music: AutonomousMusicIntent
    public var variantIntent: String
    public var explanations: [String]

    public init(projectStyle: ProjectStyleProfile, personalTaste: DirectorStyleVector, finalStyle: DirectorStyleVector, projectConfidence: Double, personalConfidence: Double, personalSignalAdjustments: [String: Double]? = nil, duration: OptimalDurationDecision, grammar: AutonomousEditingGrammar, story: AutonomousStoryDecision, music: AutonomousMusicIntent, variantIntent: String = "autonomous-balanced", explanations: [String]) {
        self.projectStyle = projectStyle
        self.personalTaste = personalTaste
        self.finalStyle = finalStyle
        self.projectConfidence = projectConfidence.clamped01
        self.personalConfidence = personalConfidence.clamped01
        self.personalSignalAdjustments = personalSignalAdjustments
        self.duration = duration
        self.grammar = grammar
        self.story = story
        self.music = music
        self.variantIntent = variantIntent
        self.explanations = explanations
    }

    public func variant(for strategy: String) -> AutonomousDirectorDecision {
        var result = self
        let lower = strategy.lowercased()
        var changes: [String: Double] = [:]
        if ["action", "telemetry", "opening-first", "rapid"].contains(where: lower.contains) {
            changes = ["energy": 0.13, "action": 0.15, "pacing": 0.12, "shotDuration": -0.12, "musicIntensity": 0.10]
        } else if ["cinematic", "scenic", "quiet", "atmosphere"].contains(where: lower.contains) {
            changes = ["cinematic": 0.14, "atmosphere": 0.15, "energy": -0.09, "pacing": -0.10, "shotDuration": 0.13]
        } else if ["emotional", "people", "original-audio", "closure"].contains(where: lower.contains) {
            changes = ["emotional": 0.16, "intimacy": 0.14, "action": -0.08, "pacing": -0.06, "shotDuration": 0.10, "musicIntensity": -0.07]
        } else if ["novelty", "contrast", "balanced-energy"].contains(where: lower.contains) {
            changes = ["visualDensity": 0.13, "energy": 0.05, "shotDuration": -0.04]
        }
        result.finalStyle = finalStyle.adjusted(changes)
        let durationScale = changes["shotDuration"].map { 1 + $0 * 0.55 } ?? 1
        result.duration.seconds = max(result.duration.safeRange.lowerBound, min(result.duration.safeRange.upperBound, result.duration.seconds * durationScale))
        result.grammar = AutonomousEditingGrammar(style: result.finalStyle, project: projectStyle, confidence: min(projectConfidence, max(0.35, result.grammar.confidence)), personalAdjustments: personalSignalAdjustments ?? [:])
        result.story = AutonomousDirectorEngine.storyDecision(project: projectStyle, style: result.finalStyle, strategy: strategy)
        result.music = AutonomousDirectorEngine.musicIntent(style: result.finalStyle, story: result.story, duration: result.duration, confidence: min(projectConfidence, result.story.confidence))
        result.variantIntent = strategy
        result.explanations.append("Вариант \(strategy) исследует отдельную область непрерывного style space")
        return result
    }
}

public struct AutonomousProjectStyleEngine: Sendable {
    public init() {}

    public func infer(assets: [MediaAsset], analyses: [AnalysisResult], fallbackPreset: FilmPreset, events: [Event] = []) -> ProjectStyleProfile {
        let validAssets = Dictionary(uniqueKeysWithValues: assets.filter { !$0.excluded && !$0.missing }.map { ($0.id, $0) })
        let candidates = analyses.flatMap(\.directorCandidates).filter { !$0.excluded && validAssets[$0.assetID] != nil }
        guard !candidates.isEmpty else {
            let vector = fallbackVector(fallbackPreset).blended(with: .neutral, otherWeight: 0.62)
            return ProjectStyleProfile(internalLabel: "NEUTRAL_LOW_CONFIDENCE", vector: vector, shotVariety: 0.3, sceneVariety: 0, peopleShare: 0, actionShare: 0, speechShare: 0, telemetryShare: 0, usableMomentCount: 0, confidence: 0.12, evidence: ["Недостаточно usable moments; выбрана безопасная нейтральная грамматика"])
        }
        func mean(_ value: (Candidate) -> Double) -> Double { candidates.reduce(0) { $0 + value($1) } / Double(candidates.count) }
        func share(_ predicate: (Candidate) -> Bool) -> Double { Double(candidates.filter(predicate).count) / Double(candidates.count) }
        let action = mean { $0.insights?.dynamics ?? $0.scores.action }
        let people = share { $0.tags.contains("people") || $0.insights?.subjectTracking?.tracks.contains(where: { [.person, .face, .cyclist].contains($0.kind) }) == true }
        let emotion = mean { candidate in
            let named = candidate.insights?.emotion?.isEmpty == false ? 1.0 : 0.28
            let events = candidate.insights?.audioEvents?.filter { [.laughter, .applause, .scream].contains($0.kind) }.map(\.confidence).max() ?? 0
            return min(1, named * 0.44 + people * 0.28 + events * 0.28)
        }
        let speech = share { ($0.insights?.speech?.confidence ?? 0) >= 0.42 }
        let telemetry = Double(analyses.filter { $0.telemetry?.hasTelemetry == true }.count) / Double(max(1, analyses.count))
        let atmosphere = share { !$0.tags.isDisjoint(with: ["nature", "landscape", "sunset", "atmosphere", "scenic"]) }
        let aesthetic = mean { candidate in
            let insight = candidate.insights
            return (candidate.scores.quality * 0.24 + candidate.scores.stability * 0.16
                + (insight?.composition ?? candidate.scores.quality) * 0.27
                + (insight?.visualAppeal ?? candidate.scores.interest) * 0.21
                + (insight?.exposureQuality ?? candidate.scores.quality) * 0.12).clamped01
        }
        let audioEnergy = mean { candidate in
            candidate.insights?.audioEvents?.map { $0.intensity * $0.confidence }.max() ?? 0.25
        }
        let uniqueEvents = Set(candidates.compactMap { $0.insights?.semanticEventID }).count
        let uniqueAssets = Set(candidates.map(\.assetID)).count
        let uniqueTags = Set(candidates.flatMap(\.tags)).count
        let eventSceneCount = events.reduce(0) { $0 + $1.effectiveScenes.count }
        let eventVariety = events.isEmpty ? 0 : min(1, Double(events.count) / 6 * 0.62 + Double(eventSceneCount) / 18 * 0.38)
        let legacySceneVariety = min(1, (Double(max(uniqueEvents, uniqueAssets)) / Double(max(3, min(candidates.count, 12)))) * 0.72 + min(1, Double(uniqueTags) / 18) * 0.28)
        let sceneVariety = events.isEmpty ? legacySceneVariety : (legacySceneVariety * 0.48 + eventVariety * 0.52).clamped01
        let energies = candidates.map { $0.insights?.dynamics ?? $0.scores.action }
        let energyMean = energies.reduce(0, +) / Double(energies.count)
        let shotVariety = min(1, sqrt(energies.reduce(0) { $0 + pow($1 - energyMean, 2) } / Double(energies.count)) * 2.8 + sceneVariety * 0.35)
        let usable = candidates.filter {
            ($0.scores.quality * 0.28 + $0.scores.interest * 0.28 + $0.scores.stability * 0.14
                + ($0.insights?.storyValue ?? $0.scores.interest) * 0.20 + $0.scores.uniqueness * 0.10) >= 0.52
        }.count
        let energy = (action * 0.48 + audioEnergy * 0.17 + telemetry * 0.12 + sceneVariety * 0.13 + min(1, Double(usable) / 16) * 0.10).clamped01
        let cinematic = (aesthetic * 0.48 + atmosphere * 0.25 + sceneVariety * 0.17 + (1 - action) * 0.10).clamped01
        let intimacy = (people * 0.42 + speech * 0.34 + emotion * 0.24).clamped01
        let pacing = (energy * 0.52 + action * 0.31 + (1 - atmosphere) * 0.17).clamped01
        let vector = DirectorStyleVector(
            energy: energy, cinematic: cinematic, emotional: emotion, action: action,
            intimacy: intimacy, atmosphere: (atmosphere * 0.72 + aesthetic * 0.28).clamped01,
            pacing: pacing, visualDensity: (sceneVariety * 0.62 + shotVariety * 0.38).clamped01,
            transitionIntensity: (0.08 + cinematic * 0.09 + emotion * 0.05).clamped01,
            musicIntensity: (energy * 0.62 + emotion * 0.18 + atmosphere * 0.20).clamped01,
            shotDuration: (0.67 - pacing * 0.45 + cinematic * 0.20 + emotion * 0.10).clamped01
        )
        let coverage = mean { candidate in
            var fields = 2.0
            if candidate.insights?.visualEmbedding != nil { fields += 1 }
            if candidate.insights?.subjectTracking != nil { fields += 1 }
            if candidate.insights?.audioEvents != nil { fields += 1 }
            if candidate.momentBoundary != nil { fields += 1 }
            return fields / 6
        }
        let confidence = (min(1, Double(candidates.count) / 14) * 0.52 + coverage * 0.32 + sceneVariety * 0.16).clamped01
        let label: String
        let datedEvents = events.compactMap(\.startDate)
        let archiveSpan = max(0, (datedEvents.max()?.timeIntervalSince(datedEvents.min() ?? .distantPast) ?? 0) / 86_400)
        if events.count >= 3 && archiveSpan >= 10 && people > 0.30 { label = "FAMILY_MEMORY_ARCHIVE" }
        else if events.count >= 3 && action > 0.56 && atmosphere > 0.30 { label = "ACTION_TRAVEL_ARCHIVE" }
        else if action > 0.68 && atmosphere > 0.35 { label = "ACTION_TRAVEL" }
        else if intimacy > 0.62 { label = "EMOTIONAL_PEOPLE" }
        else if cinematic > 0.68 && atmosphere > 0.45 { label = "CINEMATIC_ATMOSPHERE" }
        else if action > 0.67 { label = "ACTION_EVENT" }
        else if speech > 0.45 { label = "DOCUMENTARY_VLOG" }
        else { label = "ADAPTIVE_MIXED" }
        return ProjectStyleProfile(
            internalLabel: label, vector: vector, shotVariety: shotVariety, sceneVariety: sceneVariety,
            peopleShare: people, actionShare: share { ($0.insights?.dynamics ?? $0.scores.action) > 0.68 },
            speechShare: speech, telemetryShare: telemetry, usableMomentCount: usable, confidence: confidence,
            evidence: [
                "usable moments: \(usable) из \(candidates.count)",
                "action \(Int((action * 100).rounded()))%, people \(Int((people * 100).rounded()))%, atmosphere \(Int((atmosphere * 100).rounded()))%",
                "event hierarchy: \(events.count) events / \(eventSceneCount) scenes",
                "scene variety \(Int((sceneVariety * 100).rounded()))%, P2 feature coverage \(Int((coverage * 100).rounded()))%"
            ]
        )
    }

    private func fallbackVector(_ preset: FilmPreset) -> DirectorStyleVector {
        switch preset {
        case .highlight: return DirectorStyleVector(energy: 0.78, cinematic: 0.45, emotional: 0.35, action: 0.72, pacing: 0.82, visualDensity: 0.75, shotDuration: 0.25)
        case .adventure: return DirectorStyleVector(energy: 0.72, cinematic: 0.58, emotional: 0.42, action: 0.68, atmosphere: 0.62, pacing: 0.72, shotDuration: 0.38)
        case .story: return DirectorStyleVector(energy: 0.48, cinematic: 0.55, emotional: 0.64, action: 0.38, intimacy: 0.62, atmosphere: 0.52, pacing: 0.48, shotDuration: 0.58)
        case .summerFilm: return DirectorStyleVector(energy: 0.52, cinematic: 0.58, emotional: 0.62, action: 0.35, intimacy: 0.58, atmosphere: 0.70, pacing: 0.45, shotDuration: 0.62)
        case .memories: return DirectorStyleVector(energy: 0.34, cinematic: 0.58, emotional: 0.76, action: 0.24, intimacy: 0.74, atmosphere: 0.62, pacing: 0.32, shotDuration: 0.72)
        case .cinematic: return DirectorStyleVector(energy: 0.42, cinematic: 0.84, emotional: 0.52, action: 0.36, intimacy: 0.44, atmosphere: 0.78, pacing: 0.34, shotDuration: 0.78)
        }
    }
}

public struct AutonomousDurationOptimizer: Sendable {
    public init() {}

    public func decide(
        project: ProjectStyleProfile,
        style: DirectorStyleVector,
        analyses: [AnalysisResult],
        requestedDuration: Double? = nil,
        requestIsExplicit: Bool = false,
        events: [Event] = [],
        assets: [MediaAsset] = []
    ) -> OptimalDurationDecision {
        let candidates = analyses.flatMap(\.directorCandidates).filter { !$0.excluded }
        let sceneScopeByCandidate = events.reduce(into: [UUID: UUID]()) { index, event in
            for scene in event.effectiveScenes {
                for candidateID in scene.candidateIDs where index[candidateID] == nil {
                    index[candidateID] = scene.id
                }
            }
        }
        let unique = Dictionary(grouping: candidates, by: { candidate -> String in
            let sceneScope = sceneScopeByCandidate[candidate.id].map { "scene:\($0.uuidString):" } ?? ""
            if let event = candidate.insights?.semanticEventID, !event.isEmpty { return "\(sceneScope)event:\(event)" }
            if let summary = candidate.insights?.sceneSummary, !summary.isEmpty {
                return "\(sceneScope)legacy:\(candidate.assetID.uuidString):\(summary.lowercased())"
            }
            return "\(sceneScope)legacy:\(candidate.assetID.uuidString):\(candidate.tags.sorted().joined(separator: "|"))"
        }).compactMap { group in
            group.value.max { editorialStrength($0) < editorialStrength($1) }
        }
        let strong = unique.filter { editorialStrength($0) >= 0.54 }
        let averageShot = 1.8 + style.shotDuration * 5.8
        let usableSeconds = strong.reduce(0) { result, candidate in
            let quality = editorialStrength(candidate)
            let completeness = candidate.momentBoundary?.duration ?? candidate.sourceDuration
            let desired = averageShot * (0.72 + quality * 0.48)
            return result + min(candidate.sourceDuration, completeness > 0 ? completeness : candidate.sourceDuration, max(1.0, desired))
        }
        let structuralAllowance = strong.count >= 4 ? min(18, Double(strong.count) * (0.45 + project.sceneVariety * 0.45)) : 0
        var optimal = max(5, usableSeconds + structuralAllowance)
        // A low-confidence decision stays on the shorter safe side.
        let confidence = (min(1, Double(strong.count) / 12) * 0.48 + project.sceneVariety * 0.24 + project.confidence * 0.28).clamped01
        if confidence < 0.42 { optimal *= 0.82 }
        let analyzedMomentCeiling = max(5, candidates.reduce(0) { $0 + min($1.sourceDuration, averageShot * 1.45) })
        let candidateAssetIDs = Set(candidates.map(\.assetID))
        let sourceMaterialCeiling = assets.reduce(0) { partial, asset in
            guard candidateAssetIDs.contains(asset.id), !asset.excluded, !asset.missing else { return partial }
            switch asset.kind {
            case .video:
                return partial + max(0, asset.metadata.duration ?? 0)
            case .photo:
                return partial + 8
            }
        }
        // Candidate windows locate the best editorial moments; they are not a
        // declaration that the rest of a long camera take does not exist. For
        // a duration explicitly chosen by the user, Story/Timeline may extend
        // those selected moments into adjacent source material, without reuse.
        let contentCeiling = requestIsExplicit && sourceMaterialCeiling > 0
            ? max(analyzedMomentCeiling, sourceMaterialCeiling)
            : analyzedMomentCeiling
        optimal = min(optimal, contentCeiling)
        let explicitTarget = requestIsExplicit ? requestedDuration.map { max(5, $0) } : nil
        if let explicitTarget {
            // A duration explicitly chosen by the user is a hard target when
            // the analyzed candidate pool can cover it. Only a genuine
            // material ceiling may shorten the film; creative optimization
            // must not silently blend five requested minutes into a shorter
            // "preferred" duration.
            optimal = min(contentCeiling, explicitTarget)
        }
        let lower: Double
        let upper: Double
        if let explicitTarget, contentCeiling + 0.001 >= explicitTarget {
            lower = explicitTarget
            upper = explicitTarget
        } else {
            lower = max(5, optimal * (confidence < 0.45 ? 0.78 : 0.86))
            upper = max(lower, min(contentCeiling, optimal * (confidence < 0.45 ? 1.08 : 1.18)))
        }
        return OptimalDurationDecision(
            seconds: optimal, confidence: confidence, safeRange: lower...upper, strongMomentCount: strong.count,
            reasons: [
                "сильных уникальных моментов: \(strong.count)",
                "usable editorial duration: \(Int(usableSeconds.rounded())) с",
                explicitTarget.map { target in
                    optimal + 0.5 < target
                        ? "заданная длина сокращена: пригодного материала недостаточно"
                        : "явно заданная длительность обеспечена пригодным материалом"
                } ?? "длина покрывает сильные моменты без искусственного растягивания"
            ]
        )
    }

    public static func requestContainsExplicitDuration(_ prompt: String) -> Bool {
        let lower = prompt.lowercased()
        // Do not rely on `\b` after Cyrillic abbreviations: ICU treats that
        // boundary inconsistently before punctuation, so the questionnaire
        // answer “5 мин.” was previously lost as a soft preference.
        let patterns = [
            #"\d+(?:[\.,]\d+)?\s*(?:минут(?:а|ы)?|мин\.?|min\.?)"#,
            #"\d+(?:[\.,]\d+)?\s*(?:секунд(?:а|ы)?|сек\.?|sec\.?)"#
        ]
        return patterns.contains { (try? NSRegularExpression(pattern: $0))?.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)) != nil }
    }

    private func editorialStrength(_ candidate: Candidate) -> Double {
        (candidate.scores.quality * 0.22 + candidate.scores.interest * 0.22 + candidate.scores.stability * 0.12
            + candidate.scores.uniqueness * 0.12 + (candidate.insights?.storyValue ?? candidate.scores.interest) * 0.20
            + (candidate.momentBoundary?.confidence ?? 0.42) * 0.12).clamped01
    }
}

public struct AutonomousDirectorEngine: Sendable {
    public init() {}

    public func decide(
        prompt: String,
        fallbackPreset: FilmPreset,
        requestedDuration: Double?,
        assets: [MediaAsset],
        analyses: [AnalysisResult],
        personalProfile: PersonalTasteProfile,
        events: [Event] = [],
        /// The opening questionnaire is a typed source of truth and may mark
        /// duration as exact even when no number is repeated in free-form text.
        requestIsExplicit: Bool? = nil
    ) -> AutonomousDirectorDecision {
        let project = AutonomousProjectStyleEngine().infer(assets: assets, analyses: analyses, fallbackPreset: fallbackPreset, events: events)
        let tasteContext = TasteContextResolver().resolve(projectStyle: project, assets: assets, analyses: analyses)
        let context = tasteContext.key
        let personal = personalProfile.styleVector(contextKey: context)
        // Personal taste earns influence only through repeated implicit signals.
        let personalConfidence = personalProfile.adaptiveConfidence
        let projectWeight = max(0.18, project.confidence)
        let personalWeight = personalConfidence * min(0.62, 1 - projectWeight * 0.34)
        let blendWeight = personalWeight / max(0.000_001, projectWeight + personalWeight)
        var final = project.vector.blended(with: personal, otherWeight: blendWeight)
        if let calm = personalProfile.adaptiveEstimate(for: "calmMomentPreference", contextKey: context) {
            final = final.adjusted(["atmosphere": calm.value * calm.confidence * 0.12, "action": -calm.value * calm.confidence * 0.06])
        }
        if let color = personalProfile.adaptiveEstimate(for: "colorPreference", contextKey: context) {
            final = final.adjusted(["cinematic": color.value * color.confidence * 0.10])
        }
        let fingerprint = assets.map(\.contentHash).sorted().joined(separator: "|") + "|" + project.internalLabel
        let explorationApplied = TasteExplorationPolicy().shouldExplore(profile: personalProfile, projectFingerprint: fingerprint)
        if explorationApplied { final = TasteExplorationPolicy().exploratoryStyle(from: final, profile: personalProfile) }
        let durationIsExplicit = requestIsExplicit
            ?? AutonomousDurationOptimizer.requestContainsExplicitDuration(prompt)
        let resolvedRequestedDuration = requestedDuration ?? (durationIsExplicit
            ? PromptInterpreter().interpret(prompt: prompt, preset: fallbackPreset).targetDuration
            : nil)
        var duration = AutonomousDurationOptimizer().decide(
            project: project, style: final, analyses: analyses, requestedDuration: resolvedRequestedDuration,
            requestIsExplicit: durationIsExplicit,
            events: events,
            assets: assets
        )
        if !durationIsExplicit,
           let learned = personalProfile.durationPreferences?.preferredFilmDuration,
           learned.confidence >= 0.18 {
            let learnedSeconds = max(5, (learned.value + 1) * 90)
            let weight = min(0.34, learned.confidence * 0.34)
            let blended = duration.seconds * (1 - weight) + learnedSeconds * weight
            duration.seconds = min(duration.safeRange.upperBound, max(duration.safeRange.lowerBound, blended))
            duration.reasons.append("Personal Taste duration \(Int(learnedSeconds.rounded())) с applied at \(Int((weight * 100).rounded()))% weight")
        }
        let confidence = (project.confidence * 0.82 + personalConfidence * 0.18).clamped01
        let adjustmentKeys = ["transitionIntensity", "slowMotion", "telemetry", "titles", "effects", "bRoll", "eventChronology", "chapterTitles", "eventDuration", "intermediateEvents"]
        var personalAdjustments = Dictionary(uniqueKeysWithValues: adjustmentKeys.map { key in
            let estimate = personalProfile.estimate(for: key, contextKey: context)
            return (key, estimate.mean * estimate.confidence)
        })
        personalAdjustments["transitionIntensity"] = personalProfile.adaptiveEstimate(for: "transitionPreference", contextKey: context).map { $0.value * $0.confidence } ?? personalAdjustments["transitionIntensity"]
        personalAdjustments["slowMotion"] = personalProfile.adaptiveEstimate(for: "slowMotionPreference", contextKey: context).map { $0.value * $0.confidence } ?? personalAdjustments["slowMotion"]
        personalAdjustments["telemetry"] = personalProfile.adaptiveEstimate(for: "telemetryPreference", contextKey: context).map { $0.value * $0.confidence } ?? personalAdjustments["telemetry"]
        personalAdjustments["titles"] = personalProfile.adaptiveEstimate(for: "titlePreference", contextKey: context).map { $0.value * $0.confidence } ?? personalAdjustments["titles"]
        personalAdjustments["effects"] = personalProfile.adaptiveEstimate(for: "effectPreference", contextKey: context).map { $0.value * $0.confidence } ?? personalAdjustments["effects"]
        personalAdjustments["speedRamp"] = personalProfile.estimate(for: "speedRamp", contextKey: context).mean * personalProfile.estimate(for: "speedRamp", contextKey: context).confidence
        personalAdjustments["photoMotion"] = personalProfile.adaptiveEstimate(for: "photoMotionPreference", contextKey: context).map { $0.value * $0.confidence } ?? 0
        var grammar = AutonomousEditingGrammar(style: final, project: project, confidence: confidence, personalAdjustments: personalAdjustments)
        if let learned = personalProfile.adaptiveEstimate(for: "clipDurationPreference", contextKey: context), learned.confidence >= 0.18 {
            let learnedSeconds = 1.2 + (learned.value + 1) * 3.4
            let weight = min(0.32, learned.confidence * 0.32)
            grammar.meanShotDuration = grammar.meanShotDuration * (1 - weight) + learnedSeconds * weight
            grammar.reasons.append("Personal Taste shot duration \(String(format: "%.1f", learnedSeconds)) с")
        }
        let story = Self.storyDecision(project: project, style: final, strategy: "autonomous-balanced")
        var music = Self.musicIntent(style: final, story: story, duration: duration, confidence: confidence)
        if personalConfidence >= 0.32,
           let preferred = personalProfile.musicTaste?.preferredGenres.max(by: { $0.value < $1.value }),
           preferred.value >= 1.5,
           let style = MusicStyle(rawValue: preferred.key) {
            music.style = style
            music.reasons.append("Personal Taste music style \(style.rawValue)")
        }
        if let learned = personalProfile.musicTaste?.energy, learned.confidence >= 0.18 {
            let expected = (learned.value + 1) * 0.5
            let weight = min(0.28, learned.confidence * 0.28)
            music.desiredEnergy = music.desiredEnergy * (1 - weight) + expected * weight
        }
        if let learned = personalProfile.musicTaste?.preferredBPM, learned.confidence >= 0.18 {
            let preferredBPM = 117.5 + learned.value * 62.5
            let weight = min(0.30, learned.confidence * 0.30)
            music.desiredBPM = music.desiredBPM * (1 - weight) + preferredBPM * weight
            music.reasons.append("Personal Taste BPM \(Int(preferredBPM.rounded()))")
        }
        if let learned = personalProfile.musicTaste?.beatSync, learned.confidence >= 0.18 {
            let expected = (learned.value + 1) * 0.5
            music.beatSyncIntensity = music.beatSyncIntensity * (1 - learned.confidence * 0.28) + expected * learned.confidence * 0.28
        }
        return AutonomousDirectorDecision(
            projectStyle: project, personalTaste: personal, finalStyle: final,
            projectConfidence: project.confidence, personalConfidence: personalConfidence,
            personalSignalAdjustments: personalAdjustments,
            duration: duration, grammar: grammar, story: story, music: music,
            variantIntent: explorationApplied ? "autonomous-exploration" : "autonomous-balanced",
            explanations: [
                "ProjectStyle \(project.internalLabel), confidence \(Int((project.confidence * 100).rounded()))%",
                "Personal Taste influence \(Int((blendWeight * 100).rounded()))% from \(personalProfile.totalSignalCount) implicit signals",
                "Оптимальная длительность \(Int(duration.seconds.rounded())) с, confidence \(Int((duration.confidence * 100).rounded()))%",
                "Story pattern: \(story.pattern.rawValue); music: \(music.style.rawValue) \(Int(music.desiredBPM.rounded())) BPM",
                "Taste context: \(context)",
                explorationApplied ? "Deterministic 10% explore: nearby under-observed style dimension" : "Deterministic 90% exploit: strongest learned preferences"
            ] + duration.reasons + grammar.reasons
        )
    }

    public static func storyDecision(project: ProjectStyleProfile, style: DirectorStyleVector, strategy: String) -> AutonomousStoryDecision {
        let lower = strategy.lowercased()
        let pattern: AutonomousStoryPattern
        if lower.contains("chronology") || lower.contains("documentary") { pattern = .journeyDiscovery }
        else if lower.contains("quiet") || lower.contains("scenic") { pattern = .atmosphericObservation }
        else if lower.contains("emotional") || lower.contains("people") || lower.contains("original-audio") { pattern = .emotionalJourney }
        else if lower.contains("action") || lower.contains("telemetry") { pattern = .rapidPeakReaction }
        else if project.usableMomentCount <= 3 { pattern = .minimalMontage }
        else if style.action > 0.72 && style.emotional < 0.52 { pattern = .coldOpen }
        else if style.emotional > 0.64 || project.speechShare > 0.42 { pattern = .emotionalJourney }
        else if style.atmosphere > 0.69 && style.energy < 0.58 { pattern = .atmosphericObservation }
        else if project.sceneVariety > 0.58 { pattern = .journeyDiscovery }
        else { pattern = .adaptiveArc }
        let curve: [Double]
        switch pattern {
        case .coldOpen: curve = [0.82, 0.36, 0.58, 0.78, 1, 0.38]
        case .journeyDiscovery: curve = [0.28, 0.40, 0.58, 0.74, 1, 0.34]
        case .emotionalJourney: curve = [0.32, 0.46, 0.42, 0.66, 0.94, 0.40]
        case .rapidPeakReaction: curve = [0.68, 0.82, 1, 0.34]
        case .atmosphericObservation: curve = [0.22, 0.34, 0.42, 0.32, 0.24]
        case .minimalMontage: curve = [0.42, 0.86, 0.32]
        case .adaptiveArc: curve = [0.30, 0.42, 0.58, 0.76, 1, 0.36]
        }
        return AutonomousStoryDecision(pattern: pattern, confidence: (project.confidence * 0.72 + project.sceneVariety * 0.28).clamped01, energyCurve: curve, reasons: ["Структура \(pattern.rawValue) выбрана из материала, а не из обязательного шаблона"])
    }

    public static func musicIntent(style: DirectorStyleVector, story: AutonomousStoryDecision, duration: OptimalDurationDecision, confidence: Double) -> AutonomousMusicIntent {
        let musicStyle: MusicStyle
        if style.action > 0.70 && style.musicIntensity > 0.60 { musicStyle = style.cinematic > 0.70 ? .cinematic : .energetic }
        else if style.cinematic > 0.70 { musicStyle = .cinematic }
        else if style.atmosphere > 0.68 && style.energy < 0.52 { musicStyle = .calm }
        else if style.emotional > 0.65 && style.intimacy > 0.60 { musicStyle = .acoustic }
        else if style.energy > 0.66 { musicStyle = .electronic }
        else if style.emotional > 0.55 { musicStyle = .joyful }
        else { musicStyle = .calm }
        let bpm = 68 + style.pacing * 54 + style.action * 18
        let buildAndDrop = story.energyCurve.max() ?? 0 > 0.85 && ((story.energyCurve.first ?? 0) + 0.22 < (story.energyCurve.max() ?? 0))
        let beatSync = confidence < 0.45 ? 0.18 : (style.pacing * 0.48 + style.musicIntensity * 0.34 + (buildAndDrop ? 0.18 : 0)).clamped01
        let moods: Set<String> = musicStyle == .calm ? ["calm", "ambient", "soft"]
            : musicStyle == .cinematic ? ["cinematic", "dynamic", "build"]
            : musicStyle == .acoustic ? ["acoustic", "warm", "emotional"]
            : ["energetic", "upbeat", "dynamic"]
        return AutonomousMusicIntent(
            style: musicStyle, desiredEnergy: style.musicIntensity, desiredBPM: bpm,
            desiredDuration: duration.seconds, narrativeEnergyCurve: story.energyCurve,
            needsBuildAndDrop: buildAndDrop, beatSyncIntensity: beatSync, confidence: confidence,
            moodTokens: moods,
            reasons: [
                buildAndDrop ? "Нужен трек с quiet/build → drop/climax" : "Нужен трек с ровной редактируемой структурой",
                confidence < 0.45 ? "Низкая confidence: агрессивный beat-sync отключён" : "Beat-sync intensity \(Int((beatSync * 100).rounded()))%"
            ]
        )
    }
}

public struct PreferenceSignalExtractor: Sendable {
    public init() {}

    public func signals(before: Timeline, after: Timeline, contextKey: String?, source: PreferenceSignalSource = .manualEdit) -> [PreferenceSignal] {
        let old = before.items.filter { $0.kind != .title && $0.overlay == nil }
        let new = after.items.filter { $0.kind != .title && $0.overlay == nil }
        let oldByID = Dictionary(uniqueKeysWithValues: old.map { ($0.id, $0) })
        let newByID = Dictionary(uniqueKeysWithValues: new.map { ($0.id, $0) })
        var result: [PreferenceSignal] = []
        func add(_ feature: String, _ value: Double, _ confidence: Double, _ signalSource: PreferenceSignalSource? = nil) {
            result.append(PreferenceSignal(feature: feature, value: value, confidence: confidence, source: signalSource ?? source, contextKey: contextKey))
        }
        if source == .regenerate { add("aiSelection", -0.35, 0.52, .regenerate) }
        if source == .undo { add("aiSelection", -0.28, 0.48, .undo) }
        let removed = old.filter { newByID[$0.id] == nil }
        let restored = new.filter { oldByID[$0.id] == nil }
        if !removed.isEmpty { add("visualDensity", -1, min(0.9, 0.45 + Double(removed.count) / Double(max(1, old.count)) * 0.45), .deletion) }
        if !restored.isEmpty { add("visualDensity", 0.65, min(0.78, 0.40 + Double(restored.count) / Double(max(1, new.count)) * 0.38), .restoration) }
        let removedActionShare = Double(removed.filter { $0.storyRole == .action || $0.storyRole == .climax }.count) / Double(max(1, removed.count))
        if removedActionShare > 0.35 { add("action", -0.55, min(0.72, 0.42 + removedActionShare * 0.28), .deletion) }
        let restoredActionShare = Double(restored.filter { $0.storyRole == .action || $0.storyRole == .climax }.count) / Double(max(1, restored.count))
        if restoredActionShare > 0.35 { add("action", 0.45, min(0.68, 0.40 + restoredActionShare * 0.24), .restoration) }
        let common = old.compactMap { lhs in newByID[lhs.id].map { (lhs, $0) } }
        if !common.isEmpty {
            let durationRatios = common.map { $0.1.timelineDuration / max(0.05, $0.0.timelineDuration) }
            let ratio = durationRatios.reduce(0, +) / Double(durationRatios.count)
            if abs(ratio - 1) > 0.045 { add("shotDuration", ratio > 1 ? 0.8 : -0.8, min(0.9, abs(ratio - 1) * 1.5 + 0.42), .trim) }
            let oldOrder = old.map(\.id).filter { newByID[$0] != nil }
            let newOrder = new.map(\.id).filter { oldByID[$0] != nil }
            if oldOrder != newOrder { add("chronologicalOrder", -0.35, 0.58, .reorder) }
        }
        let oldTransitions = old.filter { $0.transition != nil }.count
        let newTransitions = new.filter { $0.transition != nil }.count
        if oldTransitions != newTransitions { add("transitionIntensity", newTransitions > oldTransitions ? 0.85 : -0.85, 0.72, .transition) }
        let oldSlow = old.filter { $0.speed < 0.95 || $0.speedRamp != nil }.count
        let newSlow = new.filter { $0.speed < 0.95 || $0.speedRamp != nil }.count
        if oldSlow != newSlow {
            add("action", newSlow > oldSlow ? 0.45 : -0.35, 0.60, .speed)
            add("cinematic", newSlow > oldSlow ? 0.32 : -0.20, 0.48, .speed)
            add("slowMotion", newSlow > oldSlow ? 0.85 : -0.85, 0.72, .speed)
        }
        let oldTelemetry = before.effectiveTelemetryItems.count + old.filter { $0.telemetryOverlay != nil }.count
        let newTelemetry = after.effectiveTelemetryItems.count + new.filter { $0.telemetryOverlay != nil }.count
        if oldTelemetry != newTelemetry { add("telemetry", newTelemetry > oldTelemetry ? 0.9 : -0.9, 0.76, .telemetry) }
        let oldTitles = before.effectiveTitleItems.count + before.items.filter { $0.kind == .title }.count
        let newTitles = after.effectiveTitleItems.count + after.items.filter { $0.kind == .title }.count
        if oldTitles != newTitles { add("titles", newTitles > oldTitles ? 0.8 : -0.8, 0.68, .title) }
        let oldChapterTitles = before.items.filter { $0.kind == .title && $0.eventID != nil }.count
        let newChapterTitles = after.items.filter { $0.kind == .title && $0.eventID != nil }.count
        if oldChapterTitles != newChapterTitles { add("chapterTitles", newChapterTitles > oldChapterTitles ? 0.88 : -0.88, 0.76, .title) }
        let oldEventOrder = old.compactMap(\.eventID).reduce(into: [UUID]()) { values, id in if values.last != id { values.append(id) } }
        let newEventOrder = new.compactMap(\.eventID).reduce(into: [UUID]()) { values, id in if values.last != id { values.append(id) } }
        if !oldEventOrder.isEmpty, !newEventOrder.isEmpty {
            let commonEvents = Set(oldEventOrder).intersection(newEventOrder)
            let oldCommon = oldEventOrder.filter(commonEvents.contains)
            let newCommon = newEventOrder.filter(commonEvents.contains)
            if oldCommon != newCommon { add("eventChronology", -0.72, 0.74, .reorder) }
            let removedEvents = Set(oldEventOrder).subtracting(newEventOrder).count
            if removedEvents > 0 { add("intermediateEvents", -0.62, min(0.84, 0.50 + Double(removedEvents) * 0.08), .deletion) }
            let oldDurations = Dictionary(grouping: old.compactMap { item in item.eventID.map { ($0, item.timelineDuration) } }, by: { $0.0 }).mapValues { $0.reduce(0) { $0 + $1.1 } }
            let newDurations = Dictionary(grouping: new.compactMap { item in item.eventID.map { ($0, item.timelineDuration) } }, by: { $0.0 }).mapValues { $0.reduce(0) { $0 + $1.1 } }
            let ratios = commonEvents.compactMap { id -> Double? in
                guard let oldDuration = oldDurations[id], let newDuration = newDurations[id], oldDuration > 0.05 else { return nil }
                return newDuration / oldDuration
            }
            if !ratios.isEmpty {
                let ratio = ratios.reduce(0, +) / Double(ratios.count)
                if abs(ratio - 1) > 0.08 { add("eventDuration", ratio > 1 ? 0.72 : -0.72, min(0.82, 0.46 + abs(ratio - 1)), .trim) }
            }
        }
        let oldEffects = before.effectiveEffects.count + old.filter { $0.effect != nil }.count
        let newEffects = after.effectiveEffects.count + new.filter { $0.effect != nil }.count
        if oldEffects != newEffects { add("effects", newEffects > oldEffects ? 0.82 : -0.82, 0.68, source) }
        let cropChanges = common.filter { $0.0.effectiveVideoAdjustments.crop != $0.1.effectiveVideoAdjustments.crop || $0.0.effectiveVideoAdjustments.subjectReframe != $0.1.effectiveVideoAdjustments.subjectReframe }.count
        if cropChanges > 0 { add("reframing", 0.55, min(0.78, 0.42 + Double(cropChanges) / Double(common.count) * 0.35), .crop) }
        if before.music?.trackID != after.music?.trackID || before.music?.style != after.music?.style {
            add("musicMatch", before.music != nil && after.music == nil ? -0.9 : 0.65, 0.82, .music)
            if let music = after.music { add("musicIntensity", Self.musicEnergy(music.style) > 0.55 ? 0.58 : -0.42, 0.56, .music) }
        }
        // Retained AI choices are weak positive evidence; one edit must never
        // overwhelm explicit removals or repeated behavior.
        if !common.isEmpty { add("aiSelection", 0.18, min(0.38, Double(common.count) / 40 + 0.14), source) }
        return result
    }

    private static func musicEnergy(_ style: MusicStyle) -> Double {
        switch style {
        case .energetic, .electronic: return 0.78
        case .cinematic, .joyful: return 0.60
        case .acoustic: return 0.42
        case .calm: return 0.24
        }
    }
}

public struct AutonomousMusicTrackScorer: Sendable {
    public init() {}

    public func score(track: LocalMusicTrack, structure: MusicStructure?, intent: AutonomousMusicIntent) -> Double {
        let tokens = Set((track.genres + track.moods).map { $0.lowercased() })
        let semantic = Double(tokens.intersection(intent.moodTokens).count) / Double(max(1, intent.moodTokens.count))
        let tempo = max(0, 1 - abs(track.bpm - intent.desiredBPM) / 72)
        let energy = max(0, 1 - abs(track.energy - intent.desiredEnergy))
        let duration = track.duration <= 0 ? 0.45 : min(1, track.duration / max(5, intent.desiredDuration))
        let editability: Double
        let narrative: Double
        if let structure {
            let measured = structure.analysisIsMeasured == true ? 1.0 : 0.42
            let structuralConfidence = [structure.downbeatConfidence, structure.phraseConfidence, structure.sectionConfidence, structure.dropConfidence].compactMap { $0 }.reduce(0, +) / Double(max(1, [structure.downbeatConfidence, structure.phraseConfidence, structure.sectionConfidence, structure.dropConfidence].compactMap { $0 }.count))
            editability = measured * 0.32 + structuralConfidence * 0.38 + min(1, Double(structure.sections.count) / 6) * 0.30
            let sections = structure.sections.map(\.energy)
            narrative = Self.curveSimilarity(sections, intent.narrativeEnergyCurve) * (intent.needsBuildAndDrop ? ((structure.drops?.isEmpty == false) ? 1 : 0.45) : 1)
        } else {
            editability = track.bpmIsEstimated == false ? 0.52 : 0.32
            narrative = 0.42
        }
        return (semantic * 0.18 + tempo * 0.13 + energy * 0.18 + duration * 0.10 + editability * 0.19 + narrative * 0.22).clamped01
    }

    private static func curveSimilarity(_ source: [Double], _ target: [Double]) -> Double {
        guard !source.isEmpty, !target.isEmpty else { return 0.42 }
        let count = max(3, min(8, max(source.count, target.count)))
        func sample(_ values: [Double], _ index: Int) -> Double {
            let position = Double(index) / Double(max(1, count - 1))
            return values[min(values.count - 1, Int((position * Double(values.count - 1)).rounded()))]
        }
        return (0..<count).reduce(0) { $0 + max(0, 1 - abs(sample(source, $1) - sample(target, $1))) } / Double(count)
    }
}

public struct MontageParetoAnalyzer: Sendable {
    public init() {}

    public func front(_ variants: [DirectedMontageVariant]) -> [DirectedMontageVariant] {
        variants.filter { candidate in
            !variants.contains { other in
                other.story.strategy != candidate.story.strategy && dominates(other.score, candidate.score)
            }
        }
    }

    public func dominates(_ lhs: MontageGlobalScore, _ rhs: MontageGlobalScore, tolerance: Double = 0.015) -> Bool {
        let left = objectives(lhs)
        let right = objectives(rhs)
        let noWorse = zip(left, right).allSatisfy { $0.0 + tolerance >= $0.1 }
        let materiallyBetter = zip(left, right).filter { $0.0 > $0.1 + 0.035 }.count >= 2
        return noWorse && materiallyBetter
    }

    private func objectives(_ score: MontageGlobalScore) -> [Double] {
        [
            score.storyArc, score.continuity, score.emotionalCurve,
            score.pacingQuality, score.musicalAlignment, score.audioContinuity,
            score.technicalQuality, score.projectStyleFit, score.personalTasteFit,
            score.durationFit, score.momentCompleteness
        ]
    }
}
