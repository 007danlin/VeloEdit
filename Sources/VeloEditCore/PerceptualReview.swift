import Foundation
import AVFoundation
import CoreGraphics

// MARK: - P6 public diagnostics

public enum PerceptualFindingSeverity: String, Codable, CaseIterable, Hashable, Sendable {
    case low, medium, high, critical

    public var weight: Double {
        switch self {
        case .low: return 0.22
        case .medium: return 0.48
        case .high: return 0.76
        case .critical: return 1
        }
    }
}

public enum PerceptualReviewScope: String, Codable, CaseIterable, Hashable, Sendable {
    case film, event, scene, shot, cut
}

public enum PerceptualFindingType: String, Codable, CaseIterable, Hashable, Sendable {
    case poorCut, motionDiscontinuity, compositionJump, subjectDiscontinuity
    case unnecessaryCut, jumpCutRisk, missingReaction, missingEstablishing, musicOvercut
    case incompleteMoment, pacingMonotony, musicMisalignment, audioDiscontinuity
    case visualRepetition, weakStoryArc, unmotivatedEffect, overlayOcclusion
    case titleReadability, blackFrame, frozenFrame, missingRenderContent, technicalFailure
}

public enum PerceptualRepairKind: String, Codable, CaseIterable, Hashable, Sendable {
    case trim, extend, replace, reorder, remove, hold, removeTransition, removeEffect
    case repositionTitle, repositionTelemetry, audioDucking, musicAlignment
}

public struct PerceptualTimeRange: Codable, Hashable, Sendable {
    public var start: Double
    public var end: Double

    public init(start: Double, end: Double) {
        self.start = max(0, start.isFinite ? start : 0)
        self.end = max(self.start, end.isFinite ? end : self.start)
    }

    public var duration: Double { end - start }
    public func contains(_ time: Double) -> Bool { time >= start && time <= end }
}

public struct PerceptualRepairSuggestion: Codable, Hashable, Sendable {
    public var kind: PerceptualRepairKind
    public var itemIDs: [UUID]
    public var confidence: Double
    public var explanation: String

    public init(kind: PerceptualRepairKind, itemIDs: [UUID] = [], confidence: Double, explanation: String) {
        self.kind = kind
        self.itemIDs = itemIDs
        self.confidence = confidence.clamped01
        self.explanation = explanation
    }
}

public struct PerceptualFinding: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var severity: PerceptualFindingSeverity
    public var scope: PerceptualReviewScope
    public var timelineRange: PerceptualTimeRange
    public var type: PerceptualFindingType
    public var confidence: Double
    public var explanation: String
    public var itemIDs: [UUID]
    public var suggestedRepairs: [PerceptualRepairSuggestion]

    public init(
        id: UUID = UUID(),
        severity: PerceptualFindingSeverity,
        scope: PerceptualReviewScope,
        timelineRange: PerceptualTimeRange,
        type: PerceptualFindingType,
        confidence: Double,
        explanation: String,
        itemIDs: [UUID] = [],
        suggestedRepairs: [PerceptualRepairSuggestion] = []
    ) {
        self.id = id
        self.severity = severity
        self.scope = scope
        self.timelineRange = timelineRange
        self.type = type
        self.confidence = confidence.clamped01
        self.explanation = explanation
        self.itemIDs = itemIDs
        self.suggestedRepairs = suggestedRepairs
    }
}

public struct CutQualityScore: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var outgoingItemID: UUID
    public var incomingItemID: UUID
    public var timelineTime: Double
    public var continuity: Double
    public var motionMatch: Double
    public var compositionMatch: Double
    public var subjectContinuity: Double
    public var actionCompletion: Double
    public var audioContinuity: Double
    public var technicalContinuity: Double
    public var total: Double

    public init(
        id: UUID = UUID(), outgoingItemID: UUID, incomingItemID: UUID, timelineTime: Double,
        continuity: Double, motionMatch: Double, compositionMatch: Double,
        subjectContinuity: Double, actionCompletion: Double, audioContinuity: Double,
        technicalContinuity: Double
    ) {
        self.id = id
        self.outgoingItemID = outgoingItemID
        self.incomingItemID = incomingItemID
        self.timelineTime = max(0, timelineTime)
        self.continuity = continuity.clamped01
        self.motionMatch = motionMatch.clamped01
        self.compositionMatch = compositionMatch.clamped01
        self.subjectContinuity = subjectContinuity.clamped01
        self.actionCompletion = actionCompletion.clamped01
        self.audioContinuity = audioContinuity.clamped01
        self.technicalContinuity = technicalContinuity.clamped01
        self.total = (continuity * 0.16 + motionMatch * 0.16 + compositionMatch * 0.10
            + subjectContinuity * 0.14 + actionCompletion * 0.18
            + audioContinuity * 0.14 + technicalContinuity * 0.12).clamped01
    }
}

/// Deliberately separate from MontageGlobalScore. Global scoring chooses a
/// montage; this score represents how the finished sequence is perceived.
public struct PerceptualScore: Codable, Hashable, Sendable {
    public var total: Double
    public var continuity: Double
    public var composition: Double
    public var momentCompleteness: Double
    public var pacing: Double
    public var musicAlignment: Double
    public var audioContinuity: Double
    public var visualVariety: Double
    public var storyCoherence: Double
    public var effectQuality: Double
    public var titleQuality: Double
    public var technicalIntegrity: Double

    public init(
        continuity: Double, composition: Double, momentCompleteness: Double,
        pacing: Double, musicAlignment: Double, audioContinuity: Double,
        visualVariety: Double, storyCoherence: Double, effectQuality: Double,
        titleQuality: Double, technicalIntegrity: Double
    ) {
        self.continuity = continuity.clamped01
        self.composition = composition.clamped01
        self.momentCompleteness = momentCompleteness.clamped01
        self.pacing = pacing.clamped01
        self.musicAlignment = musicAlignment.clamped01
        self.audioContinuity = audioContinuity.clamped01
        self.visualVariety = visualVariety.clamped01
        self.storyCoherence = storyCoherence.clamped01
        self.effectQuality = effectQuality.clamped01
        self.titleQuality = titleQuality.clamped01
        self.technicalIntegrity = technicalIntegrity.clamped01
        self.total = (continuity * 0.12 + composition * 0.08 + momentCompleteness * 0.13
            + pacing * 0.09 + musicAlignment * 0.10 + audioContinuity * 0.10
            + visualVariety * 0.08 + storyCoherence * 0.10 + effectQuality * 0.06
            + titleQuality * 0.05 + technicalIntegrity * 0.09).clamped01
    }
}

public struct PerceptualRenderedFrameEvidence: Codable, Hashable, Sendable {
    public var timelineTime: Double
    public var meanLuma: Double
    public var lumaDeviation: Double
    public var perceptualHash: UInt64?
    public var isBlack: Bool
    public var isFrozenComparedToPrevious: Bool
    public var expectedVisibleContent: Bool
    public var source: String

    public init(
        timelineTime: Double, meanLuma: Double, lumaDeviation: Double,
        perceptualHash: UInt64? = nil, isBlack: Bool,
        isFrozenComparedToPrevious: Bool = false, expectedVisibleContent: Bool = true,
        source: String = "rendered-preview"
    ) {
        self.timelineTime = max(0, timelineTime)
        self.meanLuma = max(0, meanLuma)
        self.lumaDeviation = max(0, lumaDeviation)
        self.perceptualHash = perceptualHash
        self.isBlack = isBlack
        self.isFrozenComparedToPrevious = isFrozenComparedToPrevious
        self.expectedVisibleContent = expectedVisibleContent
        self.source = source
    }
}

public struct PerceptualReviewBudget: Codable, Hashable, Sendable {
    public var maximumIterations: Int
    public var maximumRepairsPerIteration: Int
    public var maximumBeamCandidates: Int
    public var minimumScoreImprovement: Double
    public var automaticRepairConfidence: Double

    public init(
        maximumIterations: Int = 2,
        maximumRepairsPerIteration: Int = 8,
        maximumBeamCandidates: Int = 20,
        minimumScoreImprovement: Double = 0.004,
        automaticRepairConfidence: Double = 0.66
    ) {
        self.maximumIterations = min(max(0, maximumIterations), 3)
        self.maximumRepairsPerIteration = min(max(1, maximumRepairsPerIteration), 12)
        self.maximumBeamCandidates = min(max(1, maximumBeamCandidates), 32)
        self.minimumScoreImprovement = min(max(0.001, minimumScoreImprovement), 0.12)
        self.automaticRepairConfidence = automaticRepairConfidence.clamped01
    }
}

public struct PerceptualReviewResult: Codable, Hashable, Sendable {
    public var score: PerceptualScore
    public var findings: [PerceptualFinding]
    public var cutScores: [CutQualityScore]
    public var renderedFrameSampleCount: Int

    public init(score: PerceptualScore, findings: [PerceptualFinding], cutScores: [CutQualityScore], renderedFrameSampleCount: Int = 0) {
        self.score = score
        self.findings = findings
        self.cutScores = cutScores
        self.renderedFrameSampleCount = max(0, renderedFrameSampleCount)
    }
}

public struct PerceptualRepairAttempt: Codable, Hashable, Sendable {
    public var toolNames: [String]
    public var accepted: Bool
    public var scoreBefore: Double
    public var scoreAfter: Double
    public var combinedScoreBefore: Double
    public var combinedScoreAfter: Double
    public var reasons: [String]
}

public struct PerceptualReviewSummary: Codable, Hashable, Sendable {
    public var perceptualReviewIterations: Int
    public var findings: [PerceptualFinding]
    public var highSeverityFindings: Int
    public var repairsAttempted: Int
    public var repairsAccepted: Int
    public var repairsRejected: Int
    public var rollbackCount: Int
    public var perceptualScoreBefore: Double
    public var perceptualScoreAfter: Double
    public var initialScore: PerceptualScore
    public var finalScore: PerceptualScore
    public var cutScores: [CutQualityScore]
    public var repairAttempts: [PerceptualRepairAttempt]
    public var renderedFrameSampleCount: Int
    public var renderReviewStatus: String

    public init(
        perceptualReviewIterations: Int, findings: [PerceptualFinding], repairsAttempted: Int,
        repairsAccepted: Int, repairsRejected: Int, rollbackCount: Int,
        initialScore: PerceptualScore, finalScore: PerceptualScore,
        cutScores: [CutQualityScore], repairAttempts: [PerceptualRepairAttempt],
        renderedFrameSampleCount: Int = 0, renderReviewStatus: String = "metadata-and-analysis"
    ) {
        self.perceptualReviewIterations = max(0, perceptualReviewIterations)
        self.findings = findings
        self.highSeverityFindings = findings.filter { $0.severity == .high || $0.severity == .critical }.count
        self.repairsAttempted = max(0, repairsAttempted)
        self.repairsAccepted = max(0, repairsAccepted)
        self.repairsRejected = max(0, repairsRejected)
        self.rollbackCount = max(0, rollbackCount)
        self.perceptualScoreBefore = initialScore.total
        self.perceptualScoreAfter = finalScore.total
        self.initialScore = initialScore
        self.finalScore = finalScore
        self.cutScores = cutScores
        self.repairAttempts = repairAttempts
        self.renderedFrameSampleCount = max(0, renderedFrameSampleCount)
        self.renderReviewStatus = renderReviewStatus
    }
}

public extension DirectorRunSummary {
    mutating func recordPerceptualReview(_ summary: PerceptualReviewSummary) {
        perceptualReviewIterations = summary.perceptualReviewIterations
        perceptualFindings = summary.findings
        highSeverityFindings = summary.highSeverityFindings
        perceptualRepairsAttempted = summary.repairsAttempted
        perceptualRepairsAccepted = summary.repairsAccepted
        perceptualRepairsRejected = summary.repairsRejected
        perceptualRollbackCount = summary.rollbackCount
        perceptualScoreBefore = summary.perceptualScoreBefore
        perceptualScoreAfter = summary.perceptualScoreAfter
        perceptualReview = summary
    }
}

// MARK: - Hierarchical reviewer

public struct PerceptualMontageReviewer: Sendable {
    public init() {}

    public func review(
        timeline source: Timeline,
        plan: StoryPlan,
        features: MontageScoringFeatures,
        renderedFrames: [PerceptualRenderedFrameEvidence] = []
    ) -> PerceptualReviewResult {
        let timeline = normalized(source)
        let primaries = timeline.items.filter { $0.kind != .title && $0.overlay == nil }
        guard !primaries.isEmpty else {
            let zero = PerceptualScore(continuity: 0, composition: 0, momentCompleteness: 0, pacing: 0, musicAlignment: 0, audioContinuity: 0, visualVariety: 0, storyCoherence: 0, effectQuality: 0, titleQuality: 0, technicalIntegrity: 0)
            let finding = PerceptualFinding(severity: .critical, scope: .film, timelineRange: PerceptualTimeRange(start: 0, end: timeline.duration), type: .technicalFailure, confidence: 1, explanation: "Timeline не содержит воспринимаемого primary video")
            return PerceptualReviewResult(score: zero, findings: [finding], cutScores: [], renderedFrameSampleCount: renderedFrames.count)
        }

        let candidates = features.candidates
        let semantic = features.semanticIndex
        var findings: [PerceptualFinding] = []
        var momentValues: [Double] = []
        var compositionValues: [Double] = []
        var audioValues: [Double] = []
        var technicalValues: [Double] = []

        // Shot-level review: composition, hero visibility, complete moments and
        // intact speech/audio events are evaluated in source time.
        for item in primaries {
            guard let candidateID = item.candidateID, let candidate = candidates[candidateID] else { continue }
            let insight = candidate.insights
            let itemEnd = item.sourceStart + item.sourceDuration
            let itemRange = PerceptualTimeRange(start: item.timelineStart, end: item.timelineStart + item.timelineDuration)
            let subjectComposition = insight?.subjectTracking?.compositionQuality ?? insight?.composition ?? candidate.scores.quality
            compositionValues.append(subjectComposition)
            let technical = (candidate.scores.quality * 0.28 + candidate.scores.stability * 0.17
                + (insight?.sharpness ?? candidate.scores.quality) * 0.18
                + (insight?.exposureQuality ?? candidate.scores.quality) * 0.18
                + (1 - (insight?.noise ?? 0.2)) * 0.09 + (1 - (insight?.shake ?? 0.2)) * 0.10).clamped01
            technicalValues.append(technical)

            if let boundary = candidate.momentBoundary, boundary.confidence >= 0.34 {
                let anticipationHandle = min(0.28, max(0.08, (boundary.peakTime - boundary.anticipationStart) * 0.16))
                let reactionHandle = min(0.38, max(0.12, (boundary.effectiveReactionEnd - boundary.peakTime) * 0.20))
                let requiredStart = min(boundary.peakTime, boundary.anticipationStart + anticipationHandle)
                let requiredEnd = max(boundary.peakTime, boundary.effectiveReactionEnd - reactionHandle)
                let startCoverage = item.sourceStart <= requiredStart + 0.04 ? 1.0 : max(0, 1 - (item.sourceStart - requiredStart) / 0.8)
                let peakCoverage = item.sourceStart <= boundary.peakTime && itemEnd >= boundary.peakTime ? 1.0 : 0
                let reactionCoverage = itemEnd >= requiredEnd - 0.04 ? 1.0 : max(0, 1 - (requiredEnd - itemEnd) / 0.9)
                let completeness = startCoverage * 0.27 + peakCoverage * 0.43 + reactionCoverage * 0.30
                momentValues.append(completeness)
                if completeness < 0.72 {
                    let missesPeak = peakCoverage == 0
                    let severity: PerceptualFindingSeverity = missesPeak ? .critical : completeness < 0.48 ? .high : .medium
                    let reason = missesPeak
                        ? "Кадр обрезает peak момента"
                        : item.sourceStart > requiredStart ? "Монтаж входит слишком поздно и теряет anticipation" : "Монтаж выходит до completion/reaction"
                    findings.append(PerceptualFinding(
                        severity: severity, scope: .shot, timelineRange: itemRange,
                        type: .incompleteMoment, confidence: boundary.confidence,
                        explanation: "\(reason); требуемый source range \(format(requiredStart))–\(format(requiredEnd)) с",
                        itemIDs: [item.id],
                        suggestedRepairs: [
                            PerceptualRepairSuggestion(kind: .extend, itemIDs: [item.id], confidence: boundary.confidence, explanation: "Расширить trim до anticipation и reaction handles"),
                            PerceptualRepairSuggestion(kind: .replace, itemIDs: [item.id], confidence: boundary.confidence * 0.88, explanation: "Заменить полным дублем момента")
                        ]
                    ))
                }
            } else {
                momentValues.append(0.58)
            }

            if technical < 0.42 {
                findings.append(PerceptualFinding(
                    severity: technical < 0.28 ? .high : .medium, scope: .shot,
                    timelineRange: itemRange, type: .technicalFailure,
                    confidence: max(0.55, 1 - technical),
                    explanation: "Кадр воспринимается технически слабым: sharpness/exposure/stability ниже безопасного уровня",
                    itemIDs: [item.id],
                    suggestedRepairs: [PerceptualRepairSuggestion(kind: .replace, itemIDs: [item.id], confidence: max(0.55, 1 - technical), explanation: "Использовать лучший дубль той же роли")]
                ))
            }
            if let subject = insight?.subjectTracking?.mainSubject, subject.visibility < 0.36 || subject.observations.contains(where: { $0.region.touchesEdge }) {
                findings.append(PerceptualFinding(
                    severity: .medium, scope: .shot, timelineRange: itemRange,
                    type: .subjectDiscontinuity, confidence: insight?.subjectTracking?.confidence ?? 0.5,
                    explanation: "Главный объект теряется или опасно обрезается у края кадра",
                    itemIDs: [item.id]
                ))
            }

            let speech = insight?.speech
            let speechQuality: Double
            if let speech, speech.confidence >= 0.42 {
                speechQuality = speech.preservesCompletePhrase ? 1 : 0.28
                if !speech.preservesCompletePhrase {
                    findings.append(PerceptualFinding(
                        severity: .high, scope: .shot, timelineRange: itemRange,
                        type: .audioDiscontinuity, confidence: speech.confidence,
                        explanation: "Склейка обрезает речь до границы фразы или до естественной паузы",
                        itemIDs: [item.id],
                        suggestedRepairs: [PerceptualRepairSuggestion(kind: .extend, itemIDs: [item.id], confidence: speech.confidence, explanation: "Сохранить всю фразу и короткий room-tone handle")]
                    ))
                }
            } else { speechQuality = 0.66 }
            let cutEvents = (insight?.audioEvents ?? []).filter { event in
                [.laughter, .applause, .scream, .impact, .splash].contains(event.kind)
                    && event.confidence >= 0.55
                    && ((event.startTime < item.sourceStart && event.endTime > item.sourceStart)
                        || (event.startTime < itemEnd && event.endTime > itemEnd))
            }
            let eventQuality = cutEvents.isEmpty ? 0.76 : max(0.12, 1 - cutEvents.map(\.confidence).max()!)
            audioValues.append(speechQuality * 0.62 + eventQuality * 0.38)
            for event in cutEvents {
                findings.append(PerceptualFinding(
                    severity: .high, scope: .shot, timelineRange: itemRange,
                    type: .audioDiscontinuity, confidence: event.confidence,
                    explanation: "Оригинальный звук \(event.kind.rawValue) обрывается монтажной границей",
                    itemIDs: [item.id],
                    suggestedRepairs: [PerceptualRepairSuggestion(kind: .extend, itemIDs: [item.id], confidence: event.confidence, explanation: "Сохранить слышимое завершение события")]
                ))
            }
        }

        var cutScores: [CutQualityScore] = []
        var varietyValues: [Double] = []
        for (outgoing, incoming) in zip(primaries, primaries.dropFirst()) {
            guard let lhsID = outgoing.candidateID, let rhsID = incoming.candidateID,
                  let lhs = candidates[lhsID], let rhs = candidates[rhsID] else { continue }
            let lhsSubject = lhs.insights?.subjectTracking?.mainSubject
            let rhsSubject = rhs.insights?.subjectTracking?.mainSubject
            let motionMatch = Self.motionMatch(lhsSubject, rhsSubject)
            let subjectContinuity = Self.subjectContinuity(lhsSubject, rhsSubject)
            let similarity = semantic.similarity(between: lhs, and: rhs)
            let compositionDelta = abs((lhs.insights?.composition ?? lhs.scores.quality) - (rhs.insights?.composition ?? rhs.scores.quality))
            let compositionMatch = (1 - compositionDelta * 1.25).clamped01
            let exposureDelta = abs((lhs.insights?.exposureQuality ?? lhs.scores.quality) - (rhs.insights?.exposureQuality ?? rhs.scores.quality))
            let technicalContinuity = (1 - exposureDelta * 1.35).clamped01
            let actionCompletion = Self.actionCompletion(outgoing, candidate: lhs)
            let audioContinuity = Self.pairAudioContinuity(lhs, rhs)
            let repeatedRange = Self.sourceOverlap(outgoing, incoming)
            let shotScale = Self.shotScaleChange(lhsSubject, rhsSubject, sameScene: outgoing.eventSceneID != nil && outgoing.eventSceneID == incoming.eventSceneID)
            let eyeTrace = Self.eyeTrace(lhsSubject, rhsSubject)
            let continuity = (motionMatch * 0.18 + subjectContinuity * 0.18 + compositionMatch * 0.13
                + technicalContinuity * 0.12 + shotScale * 0.13 + eyeTrace * 0.12
                + (1 - repeatedRange) * 0.14).clamped01
            let score = CutQualityScore(
                outgoingItemID: outgoing.id, incomingItemID: incoming.id,
                timelineTime: incoming.timelineStart, continuity: continuity,
                motionMatch: motionMatch, compositionMatch: compositionMatch,
                subjectContinuity: subjectContinuity, actionCompletion: actionCompletion,
                audioContinuity: audioContinuity, technicalContinuity: technicalContinuity
            )
            cutScores.append(score)
            varietyValues.append((1 - similarity * 0.72 - repeatedRange * 0.28).clamped01)

            let cutRange = PerceptualTimeRange(start: max(0, incoming.timelineStart - 0.12), end: incoming.timelineStart + 0.12)
            if motionMatch < 0.35 && min(lhsSubject?.meanConfidence ?? 0, rhsSubject?.meanConfidence ?? 0) >= 0.45 {
                findings.append(PerceptualFinding(
                    severity: .high, scope: .cut, timelineRange: cutRange,
                    type: .motionDiscontinuity, confidence: min(lhsSubject?.meanConfidence ?? 0, rhsSubject?.meanConfidence ?? 0),
                    explanation: "Направление движения героя меняется через склейку без match-on-action",
                    itemIDs: [outgoing.id, incoming.id],
                    suggestedRepairs: [PerceptualRepairSuggestion(kind: .replace, itemIDs: [incoming.id], confidence: 0.76, explanation: "Подобрать входящий кадр с совпадающим screen direction")]
                ))
            }
            if actionCompletion < 0.52 {
                findings.append(PerceptualFinding(
                    severity: actionCompletion < 0.25 ? .critical : .high, scope: .cut,
                    timelineRange: cutRange, type: .poorCut,
                    confidence: lhs.momentBoundary?.confidence ?? 0.62,
                    explanation: "Склейка происходит до completion/reaction важного движения",
                    itemIDs: [outgoing.id, incoming.id],
                    suggestedRepairs: [PerceptualRepairSuggestion(kind: .extend, itemIDs: [outgoing.id], confidence: lhs.momentBoundary?.confidence ?? 0.62, explanation: "Досмотреть завершение действия")]
                ))
            }
            if similarity > 0.90 || repeatedRange > 0.30 {
                findings.append(PerceptualFinding(
                    severity: repeatedRange > 0.55 ? .high : .medium, scope: .cut,
                    timelineRange: cutRange, type: .visualRepetition,
                    confidence: max(similarity, repeatedRange),
                    explanation: "Соседние кадры повторяют source range или почти одинаковую композицию",
                    itemIDs: [outgoing.id, incoming.id],
                    suggestedRepairs: [PerceptualRepairSuggestion(kind: .replace, itemIDs: [incoming.id], confidence: max(similarity, repeatedRange), explanation: "Вставить визуально отличный план")]
                ))
            }
            let sameEditorialMoment = lhs.insights?.semanticEventID != nil
                && lhs.insights?.semanticEventID == rhs.insights?.semanticEventID
            let tagDelta = lhs.tags.symmetricDifference(rhs.tags).count
            let energyDelta = abs((lhs.insights?.dynamics ?? lhs.scores.action) - (rhs.insights?.dynamics ?? rhs.scores.action))
            let sameRole = outgoing.storyRole == incoming.storyRole
            if sameEditorialMoment, similarity > 0.80, tagDelta <= 2, energyDelta < 0.14, sameRole,
               incoming.incomingEditDecision?.choice != .transition {
                findings.append(PerceptualFinding(
                    severity: similarity > 0.91 ? .high : .medium, scope: .cut,
                    timelineRange: cutRange, type: .unnecessaryCut,
                    confidence: min(0.94, similarity * 0.68 + (1 - energyDelta) * 0.22),
                    explanation: "CUT не открывает новую информацию: соседние планы продолжают тот же момент, роль и энергию",
                    itemIDs: [outgoing.id, incoming.id],
                    suggestedRepairs: [PerceptualRepairSuggestion(kind: .hold, itemIDs: [outgoing.id, incoming.id], confidence: 0.72, explanation: "Сравнить склейку с более длинным HOLD на исходящем плане")]
                ))
            }
            if shotScale < 0.34, sameEditorialMoment, similarity > 0.62 {
                findings.append(PerceptualFinding(
                    severity: .high, scope: .cut, timelineRange: cutRange,
                    type: .jumpCutRisk, confidence: min(0.95, similarity * 0.72 + (1 - shotScale) * 0.28),
                    explanation: "Почти одинаковый размер того же героя создаёт jump-cut; нужен заметно иной план или B-roll с конкретной функцией",
                    itemIDs: [outgoing.id, incoming.id],
                    suggestedRepairs: [PerceptualRepairSuggestion(kind: .replace, itemIDs: [incoming.id], confidence: 0.78, explanation: "Выбрать другой shot scale или осмысленную перебивку")]
                ))
            }
            if score.total < 0.46 {
                findings.append(PerceptualFinding(
                    severity: score.total < 0.30 ? .high : .medium, scope: .cut,
                    timelineRange: cutRange, type: .poorCut,
                    confidence: (1 - score.total).clamped01,
                    explanation: "CutQualityScore \(Int((score.total * 100).rounded()))%: motion/composition/audio/action не складываются в чистую склейку",
                    itemIDs: [outgoing.id, incoming.id],
                    suggestedRepairs: [PerceptualRepairSuggestion(kind: .replace, itemIDs: [incoming.id], confidence: (1 - score.total).clamped01, explanation: "Проверить альтернативный входящий план")]
                ))
            }
        }

        let expectsReaction = plan.autonomousDecision?.story.roles(count: primaries.count).contains(.reaction) == true
            || plan.beatGraph?.beats.contains(where: { $0.kind == .reaction }) == true
        if expectsReaction, !primaries.contains(where: { $0.storyRole == .reaction }) {
            let climax = primaries.last { $0.storyRole == .climax }
            findings.append(PerceptualFinding(
                severity: .high, scope: .film,
                timelineRange: PerceptualTimeRange(start: climax?.timelineStart ?? 0, end: timeline.duration),
                type: .missingReaction, confidence: 0.82,
                explanation: "История обещает reaction beat, но после кульминации зрителю не показаны последствия",
                itemIDs: climax.map { [$0.id] } ?? []
            ))
        }
        if plan.eventStory != nil {
            let eventGroups = Dictionary(grouping: primaries.compactMap { item in item.eventID.map { ($0, item) } }, by: { $0.0 })
            for (_, values) in eventGroups {
                let ordered = values.map { $0.1 }.sorted { $0.timelineStart < $1.timelineStart }
                guard let first = ordered.first, first.storyRole == .action || first.storyRole == .climax else { continue }
                findings.append(PerceptualFinding(
                    severity: .medium, scope: .event,
                    timelineRange: PerceptualTimeRange(start: first.timelineStart, end: first.timelineStart + first.timelineDuration),
                    type: .missingEstablishing, confidence: 0.72,
                    explanation: "Событие начинается с действия без establishing/context shot",
                    itemIDs: [first.id]
                ))
            }
        }

        let overlayAssessment = reviewOverlays(timeline: timeline, primaries: primaries, candidates: candidates)
        findings.append(contentsOf: overlayAssessment.findings)
        let effectAssessment = reviewEffects(timeline: timeline, primaries: primaries, plan: plan)
        findings.append(contentsOf: effectAssessment.findings)
        let renderAssessment = reviewRenderedFrames(renderedFrames, timeline: timeline, primaries: primaries)
        findings.append(contentsOf: renderAssessment.findings)

        let pacing = pacingScore(primaries, plan: plan)
        if pacing < 0.48 && primaries.count >= 5 {
            findings.append(PerceptualFinding(
                severity: .medium, scope: .film,
                timelineRange: PerceptualTimeRange(start: 0, end: timeline.duration),
                type: .pacingMonotony, confidence: (1 - pacing).clamped01,
                explanation: "Ритм монотонен относительно ProjectStyleProfile: длительности не дают нужных акцентов и breathing shots",
                itemIDs: primaries.map(\.id)
            ))
        }
        let music = musicScore(timeline, primaries: primaries, candidates: candidates)
        if music < 0.45, timeline.music != nil {
            findings.append(PerceptualFinding(
                severity: .high, scope: .film,
                timelineRange: PerceptualTimeRange(start: 0, end: timeline.duration),
                type: .musicMisalignment, confidence: (1 - music).clamped01,
                explanation: "Ключевые склейки и video climax не совпадают с музыкальными phrase/drop accents",
                itemIDs: primaries.map(\.id),
                suggestedRepairs: [PerceptualRepairSuggestion(kind: .musicAlignment, confidence: (1 - music).clamped01, explanation: "Сдвинуть границы к сильным музыкальным акцентам")]
            ))
        }
        if let structure = timeline.music?.structure, primaries.count >= 8 {
            let beats = structure.downbeatTimestamps ?? structure.beatTimestamps ?? []
            let tolerance = max(0.08, structure.beatInterval * 0.22)
            let decorativeCuts = zip(primaries, primaries.dropFirst()).compactMap { previous, incoming -> TimelineItem? in
                let structural = previous.storyRole != incoming.storyRole
                    || (previous.eventSceneID != nil && incoming.eventSceneID != nil && previous.eventSceneID != incoming.eventSceneID)
                    || (previous.eventID != nil && incoming.eventID != nil && previous.eventID != incoming.eventID)
                    || incoming.storyRole == .climax || incoming.storyRole == .reaction
                return structural ? nil : incoming
            }
            let aligned = decorativeCuts.filter { cut in beats.contains { abs($0 - cut.timelineStart) <= tolerance } }
            if decorativeCuts.count >= 5, Double(aligned.count) / Double(decorativeCuts.count) > 0.72 {
                findings.append(PerceptualFinding(
                    severity: .medium, scope: .film,
                    timelineRange: PerceptualTimeRange(start: 0, end: timeline.duration),
                    type: .musicOvercut, confidence: min(0.92, Double(aligned.count) / Double(decorativeCuts.count)),
                    explanation: "Слишком много неструктурных склеек подчинены сетке бита; музыка должна акцентировать только важные изменения",
                    itemIDs: aligned.map(\.id)
                ))
            }
        }
        let story = storyScore(primaries, candidates: candidates, plan: plan)
        if story < 0.46 {
            findings.append(PerceptualFinding(
                severity: .high, scope: .film,
                timelineRange: PerceptualTimeRange(start: 0, end: timeline.duration),
                type: .weakStoryArc, confidence: (1 - story).clamped01,
                explanation: "Последовательность не формирует читаемый setup–build–climax–reaction arc",
                itemIDs: primaries.map(\.id)
            ))
        }

        let baseTechnical = average(technicalValues, fallback: 0.45)
        let score = PerceptualScore(
            continuity: average(cutScores.map(\.total), fallback: 0.64),
            composition: average(compositionValues, fallback: 0.5),
            momentCompleteness: average(momentValues, fallback: 0.56),
            pacing: pacing,
            musicAlignment: music,
            audioContinuity: average(audioValues + cutScores.map(\.audioContinuity), fallback: 0.62),
            visualVariety: average(varietyValues, fallback: 0.56),
            storyCoherence: story,
            effectQuality: effectAssessment.score,
            titleQuality: overlayAssessment.score,
            technicalIntegrity: min(baseTechnical, renderAssessment.score)
        )
        let ordered = findings.sorted {
            let lhs = $0.severity.weight * $0.confidence
            let rhs = $1.severity.weight * $1.confidence
            return lhs == rhs ? $0.timelineRange.start < $1.timelineRange.start : lhs > rhs
        }
        return PerceptualReviewResult(score: score, findings: ordered, cutScores: cutScores, renderedFrameSampleCount: renderedFrames.count)
    }

    private func normalized(_ timeline: Timeline) -> Timeline {
        var result = timeline
        result.items = TimelineTiming.retimed(result.items)
        return result
    }

    fileprivate static func motionMatch(_ lhs: SubjectTrack?, _ rhs: SubjectTrack?) -> Double {
        guard let lhs, let rhs else { return 0.62 }
        let lhsMagnitude = hypot(lhs.movementX, lhs.movementY)
        let rhsMagnitude = hypot(rhs.movementX, rhs.movementY)
        if lhsMagnitude < 0.035 || rhsMagnitude < 0.035 { return 0.72 }
        let dot = (lhs.movementX * rhs.movementX + lhs.movementY * rhs.movementY) / max(0.000_1, lhsMagnitude * rhsMagnitude)
        let speed = max(0, 1 - abs(lhsMagnitude - rhsMagnitude) / max(0.08, max(lhsMagnitude, rhsMagnitude)))
        return (((dot + 1) / 2) * 0.72 + speed * 0.28).clamped01
    }

    private static func shotScaleChange(_ lhs: SubjectTrack?, _ rhs: SubjectTrack?, sameScene: Bool) -> Double {
        guard let left = lhs?.observations.last?.region.area,
              let right = rhs?.observations.first?.region.area else { return 0.66 }
        let sameSubject = lhs?.kind == rhs?.kind && (lhs?.label == rhs?.label || sameScene)
        guard sameSubject else { return 0.72 }
        let ratio = max(left, right) / max(0.001, min(left, right))
        if ratio < 1.18 { return 0.20 }
        if ratio < 1.55 { return 0.20 + (ratio - 1.18) / 0.37 * 0.70 }
        if ratio <= 3.8 { return 1 }
        return max(0.34, 1 - (ratio - 3.8) / 5.2)
    }

    private static func eyeTrace(_ lhs: SubjectTrack?, _ rhs: SubjectTrack?) -> Double {
        guard let left = lhs?.observations.last?.region,
              let right = rhs?.observations.first?.region else { return 0.64 }
        return max(0, 1 - hypot(left.centerX - right.centerX, left.centerY - right.centerY) / 0.92)
    }

    private static func subjectContinuity(_ lhs: SubjectTrack?, _ rhs: SubjectTrack?) -> Double {
        guard let lhs, let rhs else { return 0.60 }
        let kind = lhs.kind == rhs.kind ? 1.0 : 0.48
        let left = lhs.observations.last?.region
        let right = rhs.observations.first?.region
        let position: Double
        if let left, let right {
            position = max(0, 1 - hypot(left.centerX - right.centerX, left.centerY - right.centerY) / 0.82)
        } else {
            position = 0.55
        }
        return (kind * 0.48 + position * 0.32 + min(lhs.visibility, rhs.visibility) * 0.20).clamped01
    }

    private static func actionCompletion(_ item: TimelineItem, candidate: Candidate) -> Double {
        guard let boundary = candidate.momentBoundary, boundary.confidence >= 0.3 else { return 0.68 }
        let end = item.sourceStart + item.sourceDuration
        guard item.sourceStart <= boundary.peakTime else { return 0.08 }
        if end < boundary.peakTime { return 0.05 }
        let requiredReaction = max(0.12, min(0.45, (boundary.completionEnd - boundary.peakTime) * 0.22))
        let target = boundary.completionEnd - requiredReaction
        return end >= target ? 1 : max(0.12, 1 - (target - end) / max(0.25, boundary.duration * 0.35))
    }

    private static func pairAudioContinuity(_ lhs: Candidate, _ rhs: Candidate) -> Double {
        let left = lhs.insights
        let right = rhs.insights
        var values: [Double] = []
        if let speech = left?.speech, speech.confidence >= 0.42 { values.append(speech.endsAtPhraseBoundary ? 1 : 0.18) }
        if let speech = right?.speech, speech.confidence >= 0.42 { values.append(speech.startsAtPhraseBoundary ? 1 : 0.24) }
        let qualityDelta = abs((left?.audioQuality ?? 0.55) - (right?.audioQuality ?? 0.55))
        values.append((1 - qualityDelta * 1.25).clamped01)
        let usefulDelta = abs((left?.originalAudioUsefulness ?? 0.45) - (right?.originalAudioUsefulness ?? 0.45))
        values.append((1 - usefulDelta).clamped01)
        return average(values, fallback: 0.62)
    }

    private static func sourceOverlap(_ lhs: TimelineItem, _ rhs: TimelineItem) -> Double {
        guard lhs.assetID == rhs.assetID else { return 0 }
        let overlap = max(0, min(lhs.sourceStart + lhs.sourceDuration, rhs.sourceStart + rhs.sourceDuration) - max(lhs.sourceStart, rhs.sourceStart))
        return (overlap / max(0.05, min(lhs.sourceDuration, rhs.sourceDuration))).clamped01
    }

    private func pacingScore(_ items: [TimelineItem], plan: StoryPlan) -> Double {
        guard !items.isEmpty else { return 0 }
        let durations = items.map(\.timelineDuration)
        let mean = average(durations, fallback: 3)
        let desired = plan.autonomousDecision?.grammar.meanShotDuration ?? (7.1 - plan.constraints.pacing * 4.9)
        let meanFit = max(0, 1 - abs(mean - desired) / max(1.2, desired))
        let deviation = sqrt(durations.reduce(0) { $0 + pow($1 - mean, 2) } / Double(durations.count)) / max(0.2, mean)
        let desiredVariation = plan.autonomousDecision?.grammar.shotDurationVariation ?? 0.38
        let variationFit = max(0, 1 - abs(deviation - desiredVariation) / 0.65)
        let calmRoles: Set<StoryRole> = [.intro, .setup, .bRoll, .outro]
        let breathing = items.enumerated().filter { index, item in
            calmRoles.contains(item.storyRole ?? .action) && item.timelineDuration >= mean
                && (index == 0 || index == items.count - 1 || items[max(0, index - 1)].timelineDuration < item.timelineDuration)
        }.count
        let desiredBreathing = (plan.autonomousDecision?.finalStyle.pacing ?? plan.constraints.pacing) > 0.72 ? 1 : 2
        let breathingFit = min(1, Double(breathing) / Double(max(1, desiredBreathing)))
        return (meanFit * 0.46 + variationFit * 0.34 + breathingFit * 0.20).clamped01
    }

    private func musicScore(_ timeline: Timeline, primaries: [TimelineItem], candidates: [UUID: Candidate]) -> Double {
        guard let structure = timeline.music?.structure else { return timeline.music == nil ? 0.72 : 0.45 }
        let accents = structure.accents ?? []
        guard !accents.isEmpty else { return structure.analysisIsMeasured == true ? 0.54 : 0.38 }
        let tolerance = max(0.09, structure.beatInterval * 0.34)
        let structuralCuts = zip(primaries, primaries.dropFirst()).compactMap { previous, incoming -> TimelineItem? in
            let roleChanged = previous.storyRole != incoming.storyRole
            let sceneChanged = previous.eventSceneID != nil && incoming.eventSceneID != nil && previous.eventSceneID != incoming.eventSceneID
            let eventChanged = previous.eventID != nil && incoming.eventID != nil && previous.eventID != incoming.eventID
            let structuralRole: Set<StoryRole> = [.intro, .climax, .reaction, .outro]
            return roleChanged || sceneChanged || eventChanged || structuralRole.contains(incoming.storyRole ?? .bRoll) ? incoming : nil
        }
        let cutValues = structuralCuts.map { item -> Double in
            let preferred: Set<MusicAccentKind> = item.storyRole == .climax
                ? [.drop, .sectionPeak, .phrase, .downbeat]
                : item.storyRole == .action ? [.strongBeat, .downbeat, .onset, .transition] : [.phrase, .downbeat, .transition]
            return accents.map { accent in
                let timing = max(0, 1 - abs(accent.time - item.timelineStart) / tolerance)
                return timing * (preferred.contains(accent.kind) ? 1 : 0.52) * (accent.confidence ?? 0.5)
            }.max().map { max(0.45, $0) } ?? 0.45
        }
        let cutFit = average(cutValues, fallback: 0.66)
        let climax = primaries.filter { $0.storyRole == .climax }.max { lhs, rhs in
            let a = lhs.candidateID.flatMap { candidates[$0]?.scores.action } ?? 0
            let b = rhs.candidateID.flatMap { candidates[$0]?.scores.action } ?? 0
            return a < b
        }
        let drops = accents.filter { $0.kind == .drop || $0.kind == .sectionPeak }
        let climaxFit: Double
        if let climax, !drops.isEmpty {
            let peakOffset: Double
            if let id = climax.candidateID, let boundary = candidates[id]?.momentBoundary {
                peakOffset = (boundary.peakTime - climax.sourceStart) / max(0.05, climax.sourceDuration) * climax.timelineDuration
            } else { peakOffset = climax.timelineDuration * 0.58 }
            let peak = climax.timelineStart + min(max(0, peakOffset), climax.timelineDuration)
            climaxFit = drops.map { max(0, 1 - abs($0.time - peak) / max(0.20, structure.beatInterval * 1.15)) * ($0.confidence ?? 0.5) }.max() ?? 0
        } else { climaxFit = 0.58 }
        let measured = structure.analysisIsMeasured == true ? 1.0 : 0.42
        return (cutFit * 0.45 + climaxFit * 0.40 + measured * 0.15).clamped01
    }

    private func storyScore(_ items: [TimelineItem], candidates: [UUID: Candidate], plan: StoryPlan) -> Double {
        guard !items.isEmpty else { return 0 }
        let roles = items.compactMap(\.storyRole)
        let required: Set<StoryRole> = items.count >= 5 ? [.intro, .climax, .outro] : [.climax]
        let coverage = Double(required.intersection(Set(roles)).count) / Double(required.count)
        let climaxPosition = items.firstIndex { $0.storyRole == .climax }.map { Double($0) / Double(max(1, items.count - 1)) } ?? 0
        let placement = max(0, 1 - abs(climaxPosition - 0.78) / 0.62)
        let energy = items.map { item in item.candidateID.flatMap { candidates[$0]?.insights?.dynamics ?? candidates[$0]?.scores.action } ?? 0.4 }
        let peakIndex = energy.indices.max { energy[$0] < energy[$1] } ?? 0
        let energyPlacement = max(0, 1 - abs(Double(peakIndex) / Double(max(1, energy.count - 1)) - 0.78) / 0.62)
        let endingCandidate: Candidate? = items.last?.candidateID.flatMap { candidates[$0] }
        let endingRole = endingCandidate?.insights?.roleScores[.outro] ?? 0.5
        let endingDynamics = endingCandidate.map { $0.insights?.dynamics ?? $0.scores.action } ?? 0.5
        let ending = endingRole * 0.55 + (1 - endingDynamics) * 0.45
        return (coverage * 0.38 + placement * 0.22 + energyPlacement * 0.22 + ending * 0.18).clamped01
    }

    private func reviewEffects(timeline: Timeline, primaries: [TimelineItem], plan: StoryPlan) -> (score: Double, findings: [PerceptualFinding]) {
        var findings: [PerceptualFinding] = []
        let effects = timeline.effectiveEffects.filter(\.enabled)
        let transitions = timeline.effectiveTransitionItems.filter(\.enabled)
        let expected = plan.autonomousDecision?.grammar.effectDensity ?? 0.05
        let density = Double(effects.count) / Double(max(1, primaries.count))
        for effect in effects where effect.intensity > 0.72 || density > expected + 0.24 {
            let targetEnergy = effect.targetClipID.flatMap { id in
                primaries.first(where: { $0.id == id })?.storyRole
            }
            let motivated = targetEnergy == .action || targetEnergy == .climax
            guard !motivated || effect.intensity > 0.9 else { continue }
            findings.append(PerceptualFinding(
                severity: .medium, scope: .shot,
                timelineRange: PerceptualTimeRange(start: effect.startTime, end: effect.endTime),
                type: .unmotivatedEffect, confidence: max(0.62, effect.intensity),
                explanation: "Эффект не улучшает читаемость момента и конкурирует с содержанием",
                itemIDs: effect.targetClipID.map { [$0] } ?? [],
                suggestedRepairs: [PerceptualRepairSuggestion(kind: .removeEffect, itemIDs: [effect.id], confidence: max(0.62, effect.intensity), explanation: "Сравнить чистый кадр без эффекта")]
            ))
        }
        let transitionDensity = Double(transitions.count + primaries.filter { $0.transition != nil }.count) / Double(max(1, primaries.count - 1))
        let targetTransitions = plan.autonomousDecision?.grammar.transitionDensity ?? plan.constraints.transitionFrequency
        if transitionDensity > targetTransitions + 0.28 {
            findings.append(PerceptualFinding(
                severity: .medium, scope: .film,
                timelineRange: PerceptualTimeRange(start: 0, end: timeline.duration),
                type: .unmotivatedEffect, confidence: min(1, transitionDensity),
                explanation: "Декоративные переходы заменяют clean cuts чаще, чем требует выбранный стиль",
                itemIDs: transitions.map(\.incomingClipID),
                suggestedRepairs: transitions.prefix(3).map { PerceptualRepairSuggestion(kind: .removeTransition, itemIDs: [$0.id], confidence: 0.72, explanation: "Вернуть прямую склейку") }
            ))
        }
        let penalty = findings.reduce(0) { $0 + $1.severity.weight * $1.confidence * 0.18 }
        return ((1 - penalty).clamped01, findings)
    }

    private func reviewOverlays(timeline: Timeline, primaries: [TimelineItem], candidates: [UUID: Candidate]) -> (score: Double, findings: [PerceptualFinding]) {
        var findings: [PerceptualFinding] = []
        func primary(at time: Double) -> TimelineItem? {
            primaries.first { time >= $0.timelineStart && time <= $0.timelineStart + $0.timelineDuration }
        }
        for title in timeline.effectiveTitleItems where title.enabled {
            let middle = title.startTime + title.duration / 2
            guard let item = title.targetClipID.flatMap({ id in primaries.first { $0.id == id } }) ?? primary(at: middle),
                  let candidateID = item.candidateID,
                  let subject = candidates[candidateID]?.insights?.subjectTracking?.mainSubject,
                  let observation = subject.observations.min(by: { abs($0.timestamp - item.sourceTime(atTimelineTime: middle)) < abs($1.timestamp - item.sourceTime(atTimelineTime: middle)) }) else { continue }
            let style = title.style
            let titleWidth = min(0.82, max(0.24, Double(title.text.count) * style.fontSize / 2_700)) * style.effectiveScale
            let titleHeight = min(0.34, max(0.08, style.fontSize / 520)) * style.effectiveScale
            let region = NormalizedRegion(x: max(0, style.effectiveXPosition - titleWidth / 2), y: max(0, style.effectiveYPosition - titleHeight / 2), width: min(titleWidth, 1), height: min(titleHeight, 1))
            if overlap(region, observation.region) > 0.18 {
                findings.append(PerceptualFinding(
                    severity: .high, scope: .shot,
                    timelineRange: PerceptualTimeRange(start: title.startTime, end: title.endTime),
                    type: .overlayOcclusion, confidence: min(subject.meanConfidence, title.style.effectiveOpacity),
                    explanation: "Титр закрывает главного героя в отрендерованной композиции",
                    itemIDs: [title.id, item.id],
                    suggestedRepairs: [PerceptualRepairSuggestion(kind: .repositionTitle, itemIDs: [title.id], confidence: subject.meanConfidence, explanation: "Перенести текст в свободную safe-area")]
                ))
            }
            if title.duration < max(0.8, Double(title.text.count) / 18) {
                findings.append(PerceptualFinding(
                    severity: .medium, scope: .shot,
                    timelineRange: PerceptualTimeRange(start: title.startTime, end: title.endTime),
                    type: .titleReadability, confidence: 0.78,
                    explanation: "Титр исчезает раньше минимального времени чтения",
                    itemIDs: [title.id]
                ))
            }
        }
        for overlay in timeline.effectiveTelemetryItems {
            let middle = overlay.timelineStart + overlay.timelineDuration / 2
            guard let item = overlay.targetClipID.flatMap({ id in primaries.first { $0.id == id } }) ?? primary(at: middle),
                  let candidateID = item.candidateID,
                  let subject = candidates[candidateID]?.insights?.subjectTracking?.mainSubject,
                  let observation = subject.observations.min(by: { abs($0.timestamp - item.sourceTime(atTimelineTime: middle)) < abs($1.timestamp - item.sourceTime(atTimelineTime: middle)) }) else { continue }
            let overlaps = overlay.settings.resolvedWidgets.map {
                overlap(NormalizedRegion(x: $0.x, y: $0.y, width: min($0.width, 1 - $0.x), height: min($0.height, 1 - $0.y)), observation.region)
            }.max() ?? 0
            if overlaps > 0.20 {
                findings.append(PerceptualFinding(
                    severity: .high, scope: .shot,
                    timelineRange: PerceptualTimeRange(start: overlay.timelineStart, end: overlay.timelineEnd),
                    type: .overlayOcclusion, confidence: subject.meanConfidence,
                    explanation: "Telemetry overlay перекрывает отслеживаемого героя",
                    itemIDs: [overlay.id, item.id],
                    suggestedRepairs: [PerceptualRepairSuggestion(kind: .repositionTelemetry, itemIDs: [overlay.id], confidence: subject.meanConfidence, explanation: "Перенести widgets на противоположную сторону")]
                ))
            }
        }
        let penalty = findings.reduce(0) { $0 + $1.severity.weight * $1.confidence * 0.17 }
        return ((1 - penalty).clamped01, findings)
    }

    private func reviewRenderedFrames(_ frames: [PerceptualRenderedFrameEvidence], timeline: Timeline, primaries: [TimelineItem]) -> (score: Double, findings: [PerceptualFinding]) {
        guard !frames.isEmpty else { return (0.92, []) }
        var findings: [PerceptualFinding] = []
        for frame in frames where frame.expectedVisibleContent && frame.isBlack {
            let item = primaries.first { frame.timelineTime >= $0.timelineStart && frame.timelineTime <= $0.timelineStart + $0.timelineDuration }
            findings.append(PerceptualFinding(
                severity: .critical, scope: .shot,
                timelineRange: PerceptualTimeRange(start: max(0, frame.timelineTime - 0.05), end: frame.timelineTime + 0.05),
                type: .blackFrame, confidence: 0.99,
                explanation: "Selective rendered preview содержит необъяснимый black frame (mean luma \(format(frame.meanLuma)))",
                itemIDs: item.map { [$0.id] } ?? [],
                suggestedRepairs: item.map { [PerceptualRepairSuggestion(kind: .replace, itemIDs: [$0.id], confidence: 0.94, explanation: "Заменить клип с неисправным декодированием/transform")] } ?? []
            ))
        }
        for frame in frames where frame.expectedVisibleContent && frame.isFrozenComparedToPrevious {
            let item = primaries.first { frame.timelineTime >= $0.timelineStart && frame.timelineTime <= $0.timelineStart + $0.timelineDuration }
            guard item?.isFreezeFrame != true else { continue }
            findings.append(PerceptualFinding(
                severity: .high, scope: .shot,
                timelineRange: PerceptualTimeRange(start: max(0, frame.timelineTime - 0.12), end: frame.timelineTime + 0.12),
                type: .frozenFrame, confidence: 0.90,
                explanation: "Rendered preview повторяет один кадр без намеренного freeze-frame",
                itemIDs: item.map { [$0.id] } ?? []
            ))
        }
        let severe = findings.reduce(0) { $0 + $1.severity.weight * $1.confidence }
        return ((1 - severe / Double(max(1, frames.count))).clamped01, findings)
    }

    private func overlap(_ lhs: NormalizedRegion, _ rhs: NormalizedRegion) -> Double {
        let width = max(0, min(lhs.x + lhs.width, rhs.x + rhs.width) - max(lhs.x, rhs.x))
        let height = max(0, min(lhs.y + lhs.height, rhs.y + rhs.height) - max(lhs.y, rhs.y))
        return width * height / max(0.000_1, min(lhs.area, rhs.area))
    }
}

// MARK: - Transactional repair loop

public struct PerceptualReviewTransactionResult: Sendable {
    public var timeline: Timeline
    public var review: PerceptualReviewResult
    public var committed: Bool
    public var globalScore: MontageGlobalScore
    public var combinedScore: Double
    public var safetyViolations: [String]
    public var rejectionReasons: [String]
}

public struct PerceptualReviewTransaction: Sendable {
    public init() {}

    public func commitIfImproved(
        original: Timeline,
        candidate: Timeline,
        currentReview: PerceptualReviewResult,
        currentGlobal: MontageGlobalScore,
        plan: StoryPlan,
        features: MontageScoringFeatures,
        analyses: [AnalysisResult],
        renderedFrames: [PerceptualRenderedFrameEvidence] = [],
        minimumImprovement: Double = 0.004
    ) -> PerceptualReviewTransactionResult {
        let safety = TimelineSafetyValidator().violations(candidate: candidate, comparedTo: original, plan: plan, analyses: analyses)
        let reviewer = PerceptualMontageReviewer()
        let candidateReview = reviewer.review(timeline: candidate, plan: plan, features: features, renderedFrames: renderedFrames)
        let candidateGlobal = DefaultMontageGlobalScorer().score(plan: plan, timeline: candidate, features: features, analyses: analyses)
        let currentCombined = currentGlobal.total * 0.62 + currentReview.score.total * 0.38
        let candidateCombined = candidateGlobal.total * 0.62 + candidateReview.score.total * 0.38
        var hardFailures = safety
        if candidateReview.score.technicalIntegrity + 0.015 < currentReview.score.technicalIntegrity {
            hardFailures.append("Perceptual repair ухудшает technical integrity")
        }
        if candidateReview.score.momentCompleteness + 0.025 < currentReview.score.momentCompleteness {
            hardFailures.append("Perceptual repair обрезает completeness другого момента")
        }
        let oldCritical = currentReview.findings.filter { $0.severity == .critical }.count
        let newCritical = candidateReview.findings.filter { $0.severity == .critical }.count
        if newCritical > oldCritical { hardFailures.append("Perceptual repair создаёт новое critical finding") }
        let candidateItems = Dictionary(uniqueKeysWithValues: candidate.items.map { ($0.id, $0) })
        let losesMotivatedTreatment = original.items.contains { before in
            guard let after = candidateItems[before.id], before.candidateID != after.candidateID else { return false }
            let protectedVideo = !before.effectiveVideoAdjustments.isNeutral && after.effectiveVideoAdjustments.isNeutral
            let protectedAudio = !before.effectiveAudioAdjustments.isNeutral && after.effectiveAudioAdjustments.isNeutral
            let protectedTiming = (before.speedRamp != nil && after.speedRamp == nil)
                || (abs(before.speed - 1) > 0.001 && abs(after.speed - 1) < 0.001)
            let protectedTelemetry = before.telemetryOverlay != nil && after.telemetryOverlay == nil
            return protectedVideo || protectedAudio || protectedTiming || protectedTelemetry
        }
        if losesMotivatedTreatment {
            hardFailures.append("Perceptual replacement удаляет уже мотивированный reframe/stabilization/audio/retime/telemetry treatment")
        }
        let improved = candidateCombined >= currentCombined + minimumImprovement
            && candidateReview.score.total + 0.001 >= currentReview.score.total
        var rejection: [String] = []
        if !improved { rejection.append("combined global + perceptual score не улучшился на минимальный порог") }
        rejection.append(contentsOf: hardFailures)
        guard improved, hardFailures.isEmpty else {
            return PerceptualReviewTransactionResult(timeline: original, review: currentReview, committed: false, globalScore: currentGlobal, combinedScore: currentCombined, safetyViolations: safety, rejectionReasons: rejection)
        }
        return PerceptualReviewTransactionResult(timeline: candidate, review: candidateReview, committed: true, globalScore: candidateGlobal, combinedScore: candidateCombined, safetyViolations: [], rejectionReasons: [])
    }
}

public struct PerceptualRepairRunResult: Sendable {
    public var timeline: Timeline
    public var summary: PerceptualReviewSummary
    public var appliedCalls: [DirectorToolCall]
    public var rejectedOperations: [String]
}

public struct PerceptualReviewEngine: Sendable {
    public init() {}

    public func run(
        timeline initialTimeline: Timeline,
        plan: StoryPlan,
        assets: [MediaAsset],
        analyses: [AnalysisResult],
        renderedFrames: [PerceptualRenderedFrameEvidence] = [],
        budget: PerceptualReviewBudget = PerceptualReviewBudget()
    ) -> PerceptualRepairRunResult {
        let features = MontageScoringFeatures(assets: assets, analyses: analyses)
        let reviewer = PerceptualMontageReviewer()
        let scorer = DefaultMontageGlobalScorer()
        let tools = DirectorEditingTools()
        var timeline = initialTimeline
        let initialReview = reviewer.review(timeline: timeline, plan: plan, features: features, renderedFrames: renderedFrames)
        var review = initialReview
        var global = scorer.score(plan: plan, timeline: timeline, features: features, analyses: analyses)
        var applied: [DirectorToolCall] = []
        var rejected: [String] = []
        var attempts: [PerceptualRepairAttempt] = []
        var iterations = 0
        var rollbackCount = 0
        var attemptedCount = 0

        while iterations < budget.maximumIterations {
            let calls = repairCalls(for: review, timeline: timeline, plan: plan, features: features, confidenceThreshold: budget.automaticRepairConfidence)
            let bounded = Array(calls.prefix(budget.maximumRepairsPerIteration))
            guard !bounded.isEmpty else { break }
            var beams = bounded.map { [$0] }
            if bounded.count > 1 {
                outer: for first in bounded.indices {
                    for second in bounded.indices where second > first {
                        if beams.count >= budget.maximumBeamCandidates { break outer }
                        if bounded[first].tool != bounded[second].tool || bounded[first].reason != bounded[second].reason {
                            beams.append([bounded[first], bounded[second]])
                        }
                    }
                }
            }
            let original = timeline
            let beforeReview = review
            let beforeGlobal = global
            let beforeCombined = global.total * 0.62 + review.score.total * 0.38
            var best: (transaction: PerceptualReviewTransactionResult, report: DirectorToolExecutionReport, beam: [DirectorToolCall])?
            for beam in beams {
                attemptedCount += 1
                let execution = tools.apply(beam, to: original, assets: assets, analyses: analyses, plan: plan)
                guard !execution.report.applied.isEmpty else {
                    rejected.append(contentsOf: execution.report.rejected)
                    continue
                }
                let transaction = PerceptualReviewTransaction().commitIfImproved(
                    original: original, candidate: execution.timeline,
                    currentReview: beforeReview, currentGlobal: beforeGlobal,
                    plan: plan, features: features, analyses: analyses,
                    renderedFrames: renderedFrames,
                    minimumImprovement: budget.minimumScoreImprovement
                )
                if transaction.committed {
                    if best.map({ transaction.combinedScore > $0.transaction.combinedScore }) ?? true {
                        best = (transaction, execution.report, beam)
                    }
                } else {
                    rollbackCount += 1
                    let reasons = transaction.rejectionReasons + execution.report.rejected
                    attempts.append(PerceptualRepairAttempt(
                        toolNames: execution.report.applied.map { $0.tool.rawValue }, accepted: false,
                        scoreBefore: beforeReview.score.total, scoreAfter: transaction.review.score.total,
                        combinedScoreBefore: beforeCombined, combinedScoreAfter: transaction.combinedScore,
                        reasons: reasons
                    ))
                }
            }
            guard let best else {
                rejected.append("Perceptual beam отклонён: ни один repair не улучшил combined score при hard safety constraints")
                break
            }
            timeline = best.transaction.timeline
            review = best.transaction.review
            global = best.transaction.globalScore
            applied.append(contentsOf: best.report.applied)
            rejected.append(contentsOf: best.report.rejected)
            attempts.append(PerceptualRepairAttempt(
                toolNames: best.report.applied.map { $0.tool.rawValue }, accepted: true,
                scoreBefore: beforeReview.score.total, scoreAfter: review.score.total,
                combinedScoreBefore: beforeCombined, combinedScoreAfter: best.transaction.combinedScore,
                reasons: best.report.applied.map(\.reason)
            ))
            iterations += 1
        }

        let accepted = attempts.filter(\.accepted).count
        let rejectedAttempts = attempts.filter { !$0.accepted }.count
        let summary = PerceptualReviewSummary(
            perceptualReviewIterations: iterations,
            findings: review.findings,
            repairsAttempted: attemptedCount,
            repairsAccepted: accepted,
            repairsRejected: rejectedAttempts,
            rollbackCount: rollbackCount,
            initialScore: initialReview.score,
            finalScore: review.score,
            cutScores: review.cutScores,
            repairAttempts: attempts,
            renderedFrameSampleCount: review.renderedFrameSampleCount,
            renderReviewStatus: renderedFrames.isEmpty ? "metadata-and-analysis" : "selective-render-reviewed"
        )
        return PerceptualRepairRunResult(timeline: timeline, summary: summary, appliedCalls: applied, rejectedOperations: rejected)
    }

    private func repairCalls(
        for review: PerceptualReviewResult,
        timeline: Timeline,
        plan: StoryPlan,
        features: MontageScoringFeatures,
        confidenceThreshold: Double
    ) -> [DirectorToolCall] {
        let used = Set(timeline.items.compactMap(\.candidateID))
        let available = features.candidates.values.filter { !$0.excluded }
        let ranker = ContextualHighlightRanker()
        let context = HighlightRankingContext(prompt: plan.prompt, preset: plan.preset, constraints: plan.constraints, autonomousStyle: plan.autonomousDecision?.finalStyle)
        var calls: [DirectorToolCall] = []
        for finding in review.findings where finding.confidence >= confidenceThreshold && (finding.severity == .high || finding.severity == .critical || finding.severity == .medium) {
            switch finding.type {
            case .incompleteMoment, .poorCut, .audioDiscontinuity:
                guard let itemID = finding.itemIDs.first,
                      let item = timeline.items.first(where: { $0.id == itemID }), !item.locked,
                      let candidateID = item.candidateID, let candidate = features.candidates[candidateID] else { continue }
                if let boundary = candidate.momentBoundary, boundary.confidence >= confidenceThreshold {
                    let start = max(candidate.sourceStart, boundary.anticipationStart)
                    let end = min(candidate.sourceStart + candidate.sourceDuration, boundary.effectiveReactionEnd)
                    if end - start >= 0.25,
                       abs(start - item.sourceStart) > 0.04 || abs((end - start) - item.sourceDuration) > 0.04 {
                        calls.append(.trim(itemID: item.id, sourceStart: start, sourceDuration: end - start, reason: "P6 сохраняет anticipation–peak–completion/reaction после perceptual review"))
                    }
                }
                if finding.severity == .critical, let replacement = replacement(for: item, available: available, used: used, features: features, ranker: ranker, context: context) {
                    let range = MomentPhaseTrimmer().range(for: replacement, desiredDuration: min(max(item.sourceDuration, 1.8), replacement.sourceDuration))
                    calls.append(.replace(itemID: item.id, candidateID: replacement.id, sourceStart: range.sourceStart, sourceDuration: range.sourceDuration, role: item.storyRole ?? .action, reason: "P6 проверяет альтернативный полный дубль для critical perceptual finding"))
                }

            case .motionDiscontinuity, .compositionJump, .subjectDiscontinuity, .visualRepetition, .jumpCutRisk, .technicalFailure, .blackFrame:
                guard let itemID = finding.itemIDs.last,
                      let item = timeline.items.first(where: { $0.id == itemID }), !item.locked,
                      let replacement = replacement(for: item, available: available, used: used, features: features, ranker: ranker, context: context) else { continue }
                let range = MomentPhaseTrimmer().range(for: replacement, desiredDuration: min(item.sourceDuration, replacement.sourceDuration))
                calls.append(.replace(itemID: item.id, candidateID: replacement.id, sourceStart: range.sourceStart, sourceDuration: range.sourceDuration, role: item.storyRole ?? .buildup, reason: "P6 проверяет визуально совместимый лучший дубль вместо perceptual defect"))

            case .unmotivatedEffect:
                for suggestion in finding.suggestedRepairs {
                    if suggestion.kind == .removeEffect, let id = suggestion.itemIDs.first {
                        calls.append(.removeEffect(effectID: id, reason: "P6 убирает эффект, не улучшающий воспринимаемое качество"))
                    } else if suggestion.kind == .removeTransition, let id = suggestion.itemIDs.first {
                        calls.append(.removeTransitionObject(transitionID: id, reason: "P6 возвращает clean cut вместо немотивированного перехода"))
                    }
                }

            case .overlayOcclusion:
                for suggestion in finding.suggestedRepairs {
                    if suggestion.kind == .repositionTitle, let id = suggestion.itemIDs.first,
                       let title = timeline.effectiveTitleItems.first(where: { $0.id == id }) {
                        var style = title.style
                        style.xPosition = style.effectiveXPosition < 0.5 ? 0.76 : 0.24
                        style.yPosition = style.effectiveYPosition < 0.5 ? 0.78 : 0.22
                        calls.append(.editTitleObject(titleID: id, text: nil, style: style, animation: nil, reason: "P6 переносит титр в свободную safe-area"))
                    } else if suggestion.kind == .repositionTelemetry, let id = suggestion.itemIDs.first,
                              let overlay = timeline.effectiveTelemetryItems.first(where: { $0.id == id }) {
                        var settings = overlay.settings
                        settings.widgets = settings.resolvedWidgets.map { widget in
                            var value = widget
                            value.x = widget.x < 0.5 ? min(0.92 - widget.width, widget.x + 0.48) : max(0.04, widget.x - 0.48)
                            return value
                        }
                        if let target = overlay.targetClipID {
                            calls.append(.setTelemetry(itemID: target, settings: settings, reason: "P6 переносит telemetry с главного объекта"))
                        }
                    }
                }

            case .musicMisalignment:
                if let bpm = timeline.music?.bpm, bpm > 0 {
                    calls.append(.syncToBeat(bpm: bpm, reason: "P6 повторно привязывает склейки к measured phrase/drop accents"))
                }

            case .unnecessaryCut, .missingReaction, .missingEstablishing, .musicOvercut,
                 .pacingMonotony, .weakStoryArc, .titleReadability, .frozenFrame, .missingRenderContent:
                continue
            }
        }
        var seen = Set<DirectorToolCall>()
        return calls.filter { call in
            seen.insert(call).inserted
        }
    }

    private func replacement(
        for item: TimelineItem,
        available: [Candidate],
        used: Set<UUID>,
        features: MontageScoringFeatures,
        ranker: ContextualHighlightRanker,
        context: HighlightRankingContext
    ) -> Candidate? {
        let current = item.candidateID.flatMap { features.candidates[$0] }
        let desiredMovement = current?.insights?.subjectTracking?.mainSubject
        return available.filter { candidate in
            !used.contains(candidate.id) && candidate.assetID != item.assetID
                && candidate.scores.quality >= max(0.48, (current?.scores.quality ?? 0.4) - 0.04)
        }.max { lhs, rhs in
            func score(_ candidate: Candidate) -> Double {
                let base = ranker.score(candidate, asset: features.assets[candidate.assetID], context: context)
                let role = candidate.insights?.roleScores[item.storyRole ?? .buildup] ?? 0.5
                let motion = PerceptualMontageReviewer.motionMatch(desiredMovement, candidate.insights?.subjectTracking?.mainSubject)
                return base * 0.54 + role * 0.24 + motion * 0.22
            }
            return score(lhs) < score(rhs)
        }
    }
}

// MARK: - Selective rendered-preview inspection

public struct PerceptualRenderInspector: Sendable {
    public init() {}

    /// Samples cut neighborhoods, effect/title/telemetry centers and a bounded
    /// set of film positions from the actual AVComposition. It is not a second
    /// full render and reuses PlaybackEngine's proxy/derived-media cache.
    public func inspect(playback: TimelinePlayback, timeline: Timeline, maximumSamples: Int = 36) -> [PerceptualRenderedFrameEvidence] {
        let limit = min(max(4, maximumSamples), 48)
        let frameStep = 1 / max(15, timeline.frameRate)
        let primaries = TimelineTiming.retimed(timeline.items).filter { $0.kind != .title && $0.overlay == nil }
        var requested: [Double] = []
        for item in primaries.dropFirst() {
            requested.append(max(0, item.timelineStart - frameStep))
            requested.append(min(timeline.duration, item.timelineStart + frameStep))
        }
        requested.append(contentsOf: timeline.effectiveEffects.map { $0.startTime + $0.duration / 2 })
        requested.append(contentsOf: timeline.effectiveTitleItems.map { $0.startTime + $0.duration / 2 })
        requested.append(contentsOf: timeline.effectiveTelemetryItems.map { $0.timelineStart + $0.timelineDuration / 2 })
        if requested.count < limit {
            let count = min(10, max(3, limit - requested.count))
            requested.append(contentsOf: (0..<count).map { timeline.duration * (Double($0) + 0.5) / Double(count) })
        }
        let times = Array(Set(requested.map { Int(($0 * 120).rounded()) })).map { Double($0) / 120 }.sorted().prefix(limit)
        let generator = AVAssetImageGenerator(asset: playback.composition)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 640)
        generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 60)
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 60)
        generator.videoComposition = playback.videoComposition
        var result: [PerceptualRenderedFrameEvidence] = []
        var previousHash: UInt64?
        var repeatedHashCount = 0
        for time in times {
            guard time >= 0, time < max(0.001, playback.duration),
                  let image = try? generator.copyCGImage(at: CMTime(seconds: time, preferredTimescale: 600), actualTime: nil) else { continue }
            let assessment = FrameQualityInspector.assess(image: image)
            let hash = Self.perceptualHash(image)
            if hash == previousHash { repeatedHashCount += 1 } else { repeatedHashCount = 0 }
            let item = primaries.first { time >= $0.timelineStart && time <= $0.timelineStart + $0.timelineDuration }
            let intentionalFreeze = item?.isFreezeFrame == true || item?.kind == .photo
            result.append(PerceptualRenderedFrameEvidence(
                timelineTime: time, meanLuma: assessment.meanLuma,
                lumaDeviation: assessment.lumaDeviation, perceptualHash: hash,
                isBlack: assessment.isBlack,
                isFrozenComparedToPrevious: repeatedHashCount >= 2 && !intentionalFreeze,
                expectedVisibleContent: item != nil,
                source: "AVComposition selective preview"
            ))
            previousHash = hash
        }
        return result
    }

    private static func perceptualHash(_ image: CGImage) -> UInt64 {
        let width = 8
        let height = 8
        var bytes = [UInt8](repeating: 0, count: width * height)
        guard let context = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return 0 }
        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let mean = Double(bytes.reduce(0) { $0 + UInt64($1) }) / Double(bytes.count)
        return bytes.enumerated().reduce(UInt64(0)) { result, pair in
            pair.element >= UInt8(mean.rounded()) ? result | (UInt64(1) << UInt64(pair.offset)) : result
        }
    }
}

private func average(_ values: [Double], fallback: Double) -> Double {
    values.isEmpty ? fallback : values.reduce(0, +) / Double(values.count)
}

private func format(_ value: Double) -> String {
    String(format: "%.2f", value)
}
