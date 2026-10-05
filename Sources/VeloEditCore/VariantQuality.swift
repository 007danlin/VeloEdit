import Foundation

public struct VariantDistanceMetrics: Codable, Hashable, Sendable {
    public var candidateJaccardDistance: Double
    public var sourceRangeDistance: Double
    public var semanticDistance: Double
    public var orderDistance: Double
    public var rhythmDistance: Double
    public var total: Double

    public init(
        candidateJaccardDistance: Double,
        sourceRangeDistance: Double,
        semanticDistance: Double,
        orderDistance: Double,
        rhythmDistance: Double,
        total: Double
    ) {
        self.candidateJaccardDistance = candidateJaccardDistance.clamped01
        self.sourceRangeDistance = sourceRangeDistance.clamped01
        self.semanticDistance = semanticDistance.clamped01
        self.orderDistance = orderDistance.clamped01
        self.rhythmDistance = rhythmDistance.clamped01
        self.total = total.clamped01
    }
}

public struct VariantPairDistance: Codable, Hashable, Sendable {
    public var firstStrategy: String
    public var secondStrategy: String
    public var metrics: VariantDistanceMetrics

    public init(firstStrategy: String, secondStrategy: String, metrics: VariantDistanceMetrics) {
        self.firstStrategy = firstStrategy
        self.secondStrategy = secondStrategy
        self.metrics = metrics
    }
}

public enum VariantEvaluationDisposition: String, Codable, Hashable, Sendable {
    case selected
    case evaluated
    case rejectedSimilar
    case rejectedWeak
}

public struct VariantEvaluationRecord: Codable, Hashable, Sendable {
    public var strategy: String
    public var score: MontageGlobalScore
    public var pairwiseUtility: Double
    public var tournamentScore: Double
    public var wins: Int
    public var losses: Int
    public var ties: Int
    public var disposition: VariantEvaluationDisposition
    public var reasons: [String]

    public init(
        strategy: String,
        score: MontageGlobalScore,
        pairwiseUtility: Double = 0,
        tournamentScore: Double = 0,
        wins: Int = 0,
        losses: Int = 0,
        ties: Int = 0,
        disposition: VariantEvaluationDisposition = .evaluated,
        reasons: [String] = []
    ) {
        self.strategy = strategy
        self.score = score
        self.pairwiseUtility = pairwiseUtility.clamped01
        self.tournamentScore = tournamentScore.clamped01
        self.wins = max(0, wins)
        self.losses = max(0, losses)
        self.ties = max(0, ties)
        self.disposition = disposition
        self.reasons = reasons
    }
}

public struct VariantPairwiseResult: Codable, Hashable, Sendable {
    public var firstStrategy: String
    public var secondStrategy: String
    public var firstPreferenceShare: Double
    public var preferredStrategy: String?
    public var distance: VariantDistanceMetrics
    public var reasons: [String]

    public init(firstStrategy: String, secondStrategy: String, firstPreferenceShare: Double, preferredStrategy: String?, distance: VariantDistanceMetrics, reasons: [String]) {
        self.firstStrategy = firstStrategy
        self.secondStrategy = secondStrategy
        self.firstPreferenceShare = firstPreferenceShare.clamped01
        self.preferredStrategy = preferredStrategy
        self.distance = distance
        self.reasons = reasons
    }
}

public struct VariantRejectionRecord: Codable, Hashable, Sendable {
    public var strategy: String
    public var stage: String
    public var reason: String
    public var comparedToStrategy: String?
    public var distance: VariantDistanceMetrics?
    public var absoluteScore: Double?

    public init(strategy: String, stage: String, reason: String, comparedToStrategy: String? = nil, distance: VariantDistanceMetrics? = nil, absoluteScore: Double? = nil) {
        self.strategy = strategy
        self.stage = stage
        self.reason = reason
        self.comparedToStrategy = comparedToStrategy
        self.distance = distance
        self.absoluteScore = absoluteScore?.clamped01
    }
}

public struct VariantSelectionDiagnostics: Codable, Hashable, Sendable {
    public var minimumRequiredDistance: Double
    public var attemptedStrategyCount: Int
    public var acceptedVariantCount: Int
    public var evaluatedVariantCount: Int
    public var rejectedAsTooSimilar: Int
    public var pairDistances: [VariantPairDistance]
    public var minimumDistance: Double?
    public var meanDistance: Double?
    public var winningStrategy: String?
    public var selectionReasons: [String]
    /// Optional for backward compatibility with P1 project manifests.
    public var variantEvaluations: [VariantEvaluationRecord]?
    public var pairwiseResults: [VariantPairwiseResult]?
    public var rejectedVariants: [VariantRejectionRecord]?

    public init(
        minimumRequiredDistance: Double,
        attemptedStrategyCount: Int,
        acceptedVariantCount: Int,
        evaluatedVariantCount: Int = 0,
        rejectedAsTooSimilar: Int,
        pairDistances: [VariantPairDistance] = [],
        minimumDistance: Double? = nil,
        meanDistance: Double? = nil,
        winningStrategy: String? = nil,
        selectionReasons: [String] = [],
        variantEvaluations: [VariantEvaluationRecord]? = nil,
        pairwiseResults: [VariantPairwiseResult]? = nil,
        rejectedVariants: [VariantRejectionRecord]? = nil
    ) {
        self.minimumRequiredDistance = minimumRequiredDistance.clamped01
        self.attemptedStrategyCount = max(0, attemptedStrategyCount)
        self.acceptedVariantCount = max(0, acceptedVariantCount)
        self.evaluatedVariantCount = max(0, evaluatedVariantCount)
        self.rejectedAsTooSimilar = max(0, rejectedAsTooSimilar)
        self.pairDistances = pairDistances
        self.minimumDistance = minimumDistance?.clamped01
        self.meanDistance = meanDistance?.clamped01
        self.winningStrategy = winningStrategy
        self.selectionReasons = selectionReasons
        self.variantEvaluations = variantEvaluations
        self.pairwiseResults = pairwiseResults
        self.rejectedVariants = rejectedVariants
    }
}

public struct StoryVariantSearchResult: Sendable {
    public var variants: [StoryPlanVariant]
    public var diagnostics: VariantSelectionDiagnostics

    public init(variants: [StoryPlanVariant], diagnostics: VariantSelectionDiagnostics) {
        self.variants = variants
        self.diagnostics = diagnostics
    }
}

/// Shared definition of editorial distance. Story search uses it on rough cuts;
/// the final selector uses the same metrics on fully directed timelines.
public struct VariantDistanceCalculator: Sendable {
    public init() {}

    public func distance(
        between first: Timeline,
        and second: Timeline,
        candidates: [UUID: Candidate]
    ) -> VariantDistanceMetrics {
        let left = Self.primaries(first)
        let right = Self.primaries(second)
        let leftIDs = Set(left.compactMap(\.candidateID))
        let rightIDs = Set(right.compactMap(\.candidateID))
        let union = leftIDs.union(rightIDs)
        let candidateDistance = union.isEmpty
            ? 0
            : 1 - Double(leftIDs.intersection(rightIDs).count) / Double(union.count)
        let sourceDistance = 1 - symmetricSourceSimilarity(left, right)
        let semanticDistance = 1 - semanticSimilarity(leftIDs, rightIDs, candidates: candidates)
        let orderDistance = sequenceDistance(left.compactMap(\.candidateID), right.compactMap(\.candidateID))
        let rhythmDistance = rhythmDistance(left.map(\.timelineDuration), right.map(\.timelineDuration))
        let total = candidateDistance * 0.28
            + sourceDistance * 0.22
            + semanticDistance * 0.18
            + orderDistance * 0.17
            + rhythmDistance * 0.15
        return VariantDistanceMetrics(
            candidateJaccardDistance: candidateDistance,
            sourceRangeDistance: sourceDistance,
            semanticDistance: semanticDistance,
            orderDistance: orderDistance,
            rhythmDistance: rhythmDistance,
            total: total
        )
    }

    private static func primaries(_ timeline: Timeline) -> [TimelineItem] {
        timeline.items.filter { $0.kind != .title && $0.overlay == nil }
    }

    private func symmetricSourceSimilarity(_ left: [TimelineItem], _ right: [TimelineItem]) -> Double {
        guard !left.isEmpty || !right.isEmpty else { return 1 }
        func directed(_ source: [TimelineItem], _ target: [TimelineItem]) -> Double {
            guard !source.isEmpty else { return target.isEmpty ? 1 : 0 }
            let weighted = source.reduce(into: (score: 0.0, duration: 0.0)) { result, item in
                let duration = max(0.05, item.sourceDuration)
                let best = target.filter { $0.assetID == item.assetID }.map { other -> Double in
                    let start = max(item.sourceStart, other.sourceStart)
                    let end = min(item.sourceStart + item.sourceDuration, other.sourceStart + other.sourceDuration)
                    let overlap = max(0, end - start)
                    let union = max(0.05, max(item.sourceStart + item.sourceDuration, other.sourceStart + other.sourceDuration) - min(item.sourceStart, other.sourceStart))
                    return overlap / union
                }.max() ?? 0
                result.score += best * duration
                result.duration += duration
            }
            return weighted.score / max(0.05, weighted.duration)
        }
        return (directed(left, right) + directed(right, left)) * 0.5
    }

    private func semanticSimilarity(_ left: Set<UUID>, _ right: Set<UUID>, candidates: [UUID: Candidate]) -> Double {
        let leftTokens = semanticTokens(for: left, candidates: candidates)
        let rightTokens = semanticTokens(for: right, candidates: candidates)
        let union = leftTokens.union(rightTokens)
        guard !union.isEmpty else { return left == right ? 1 : 0 }
        return Double(leftTokens.intersection(rightTokens).count) / Double(union.count)
    }

    private func semanticTokens(for ids: Set<UUID>, candidates: [UUID: Candidate]) -> Set<String> {
        ids.reduce(into: Set<String>()) { result, id in
            guard let candidate = candidates[id] else { return }
            result.formUnion(candidate.tags.map { $0.lowercased() })
            if let summary = candidate.insights?.sceneSummary {
                result.formUnion(summary.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count >= 3 })
            }
            if let emotion = candidate.insights?.emotion, !emotion.isEmpty {
                result.insert("emotion:\(emotion.lowercased())")
            }
        }
    }

    private func sequenceDistance(_ left: [UUID], _ right: [UUID]) -> Double {
        guard !left.isEmpty || !right.isEmpty else { return 0 }
        var previous = Array(repeating: 0, count: right.count + 1)
        for leftID in left {
            var current = Array(repeating: 0, count: right.count + 1)
            for index in right.indices {
                current[index + 1] = leftID == right[index]
                    ? previous[index] + 1
                    : max(previous[index + 1], current[index])
            }
            previous = current
        }
        return 1 - Double(previous.last ?? 0) / Double(max(1, max(left.count, right.count)))
    }

    private func rhythmDistance(_ left: [Double], _ right: [Double]) -> Double {
        guard !left.isEmpty || !right.isEmpty else { return 0 }
        guard !left.isEmpty, !right.isEmpty else { return 1 }
        let sampleCount = max(4, min(12, max(left.count, right.count)))
        func normalizedSamples(_ values: [Double]) -> [Double] {
            let mean = values.reduce(0, +) / Double(values.count)
            return (0..<sampleCount).map { index in
                let position = sampleCount == 1 ? 0 : Double(index) / Double(sampleCount - 1)
                let sourceIndex = min(values.count - 1, Int((position * Double(values.count - 1)).rounded()))
                return values[sourceIndex] / max(0.1, mean)
            }
        }
        let lhs = normalizedSamples(left)
        let rhs = normalizedSamples(right)
        let shape = zip(lhs, rhs).reduce(0) { $0 + min(2, abs($1.0 - $1.1)) } / Double(sampleCount * 2)
        let count = Double(abs(left.count - right.count)) / Double(max(left.count, right.count))
        return (shape * 0.78 + count * 0.22).clamped01
    }
}

public struct MomentTrimRange: Hashable, Sendable {
    public var sourceStart: Double
    public var sourceDuration: Double

    public init(sourceStart: Double, sourceDuration: Double) {
        self.sourceStart = max(0, sourceStart)
        self.sourceDuration = max(0.05, sourceDuration)
    }
}

/// Preserves editorial handles on both sides of the detected peak whenever the
/// candidate contains enough source material. This is shared by rough compose
/// and Director repairs so later trims cannot silently discard the reaction.
public struct MomentPhaseTrimmer: Sendable {
    public init() {}

    public func range(for candidate: Candidate, desiredDuration: Double) -> MomentTrimRange {
        let candidateStart = candidate.sourceStart
        let candidateEnd = candidate.sourceStart + candidate.sourceDuration
        let desired = min(candidate.sourceDuration, max(0.05, desiredDuration))
        if let speech = candidate.insights?.speech, speech.confidence >= 0.48 {
            let phraseStart = max(candidateStart, speech.phraseStart)
            let phraseEnd = min(candidateEnd, speech.phraseEnd)
            let phraseDuration = phraseEnd - phraseStart
            if phraseDuration > 0.18, phraseDuration > desired + 0.000_001 {
                // Speech-aware editing values a complete sentence above a
                // nominal pacing target; the global scorer can still reject
                // the longer montage if the trade-off is not worthwhile.
                return MomentTrimRange(sourceStart: phraseStart, sourceDuration: phraseDuration)
            }
        }
        guard let boundary = candidate.momentBoundary, boundary.confirmedActionConfidence > 0,
              desired + 0.000_001 < candidate.sourceDuration else {
            return MomentTrimRange(sourceStart: candidateStart, sourceDuration: desired)
        }
        if boundary.confidence < 0.42, desired < candidate.sourceDuration * 0.78 {
            return MomentTrimRange(sourceStart: candidateStart, sourceDuration: candidate.sourceDuration)
        }
        let peak = min(candidateEnd, max(candidateStart, boundary.peakTime))
        let availableLead = max(0, peak - candidateStart)
        let availableTail = max(0, candidateEnd - peak)
        let minimumLead = min(availableLead, min(0.75, max(0.22, desired * 0.18)))
        let minimumTail = min(availableTail, min(1.0, max(0.30, desired * 0.24)))

        var lead = min(availableLead, max(minimumLead, desired * 0.42))
        var tail = desired - lead
        if tail > availableTail {
            tail = availableTail
            lead = min(availableLead, desired - tail)
        }
        if tail < minimumTail {
            tail = minimumTail
            lead = min(availableLead, desired - tail)
        }
        if lead < minimumLead {
            lead = minimumLead
            tail = min(availableTail, desired - lead)
        }
        var start = max(candidateStart, peak - lead)
        var duration = min(desired, candidateEnd - start)
        if let speech = candidate.insights?.speech, speech.confidence >= 0.48 {
            let phraseStart = max(candidateStart, speech.phraseStart)
            let phraseEnd = min(candidateEnd, speech.phraseEnd)
            if phraseEnd - phraseStart <= desired {
                start = min(start, phraseStart)
                if start + desired < phraseEnd { start = max(candidateStart, phraseEnd - desired) }
                duration = min(desired, candidateEnd - start)
            }
        }
        for protected in boundary.doNotCutRanges ?? [] where protected.confidence >= 0.42 {
            let end = start + duration
            if protected.contains(end) {
                start = min(max(candidateStart, protected.end - desired), max(candidateStart, candidateEnd - desired))
                duration = min(desired, candidateEnd - start)
            }
            if protected.contains(start) {
                start = max(candidateStart, protected.start)
                duration = min(desired, candidateEnd - start)
            }
        }
        return MomentTrimRange(sourceStart: start, sourceDuration: duration)
    }
}
