import Foundation

public struct MontageGlobalScore: Codable, Hashable, Sendable {
    public var total: Double
    public var highlightQuality: Double
    public var storyArc: Double
    public var diversity: Double
    public var durationFit: Double
    public var musicalAlignment: Double
    public var reviewQuality: Double
    public var semanticDiversity: Double
    public var sourceDiversity: Double
    public var momentCompleteness: Double
    public var energyCurve: Double
    public var audioContinuity: Double
    public var dropClimaxAlignment: Double
    public var continuity: Double
    public var rhythmQuality: Double
    public var technicalQuality: Double
    public var subjectComposition: Double
    public var speechContinuity: Double
    public var audioEventCoherence: Double
    public var visualSemanticQuality: Double
    public var musicStructureQuality: Double
    public var emotionalCurve: Double
    public var pacingQuality: Double
    public var projectStyleFit: Double
    public var personalTasteFit: Double
    public var eventOrder: Double
    public var eventDiversity: Double
    public var eventCoverage: Double
    public var chronology: Double
    public var sceneDiversity: Double
    public var interEventSeparation: Double

    private enum CodingKeys: String, CodingKey {
        case total, highlightQuality, storyArc, diversity, durationFit, musicalAlignment, reviewQuality
        case semanticDiversity, sourceDiversity, momentCompleteness, energyCurve, audioContinuity
        case dropClimaxAlignment, continuity, rhythmQuality, technicalQuality, subjectComposition
        case speechContinuity, audioEventCoherence, visualSemanticQuality, musicStructureQuality
        case emotionalCurve, pacingQuality, projectStyleFit, personalTasteFit
        case eventOrder, eventDiversity, eventCoverage, chronology, sceneDiversity, interEventSeparation
    }

    public init(
        total: Double,
        highlightQuality: Double,
        storyArc: Double,
        diversity: Double,
        durationFit: Double,
        musicalAlignment: Double,
        reviewQuality: Double,
        semanticDiversity: Double = 0.5,
        sourceDiversity: Double = 0.5,
        momentCompleteness: Double = 0.5,
        energyCurve: Double = 0.5,
        audioContinuity: Double = 0.5,
        dropClimaxAlignment: Double = 0.5,
        continuity: Double = 0.5,
        rhythmQuality: Double = 0.5,
        technicalQuality: Double = 0.5,
        subjectComposition: Double = 0.5,
        speechContinuity: Double = 0.5,
        audioEventCoherence: Double = 0.5,
        visualSemanticQuality: Double = 0.5,
        musicStructureQuality: Double = 0.5,
        emotionalCurve: Double = 0.5,
        pacingQuality: Double = 0.5,
        projectStyleFit: Double = 0.5,
        personalTasteFit: Double = 0.5,
        eventOrder: Double = 0.5,
        eventDiversity: Double = 0.5,
        eventCoverage: Double = 0.5,
        chronology: Double = 0.5,
        sceneDiversity: Double = 0.5,
        interEventSeparation: Double = 0.5
    ) {
        self.total = total.clamped01
        self.highlightQuality = highlightQuality.clamped01
        self.storyArc = storyArc.clamped01
        self.diversity = diversity.clamped01
        self.durationFit = durationFit.clamped01
        self.musicalAlignment = musicalAlignment.clamped01
        self.reviewQuality = reviewQuality.clamped01
        self.semanticDiversity = semanticDiversity.clamped01
        self.sourceDiversity = sourceDiversity.clamped01
        self.momentCompleteness = momentCompleteness.clamped01
        self.energyCurve = energyCurve.clamped01
        self.audioContinuity = audioContinuity.clamped01
        self.dropClimaxAlignment = dropClimaxAlignment.clamped01
        self.continuity = continuity.clamped01
        self.rhythmQuality = rhythmQuality.clamped01
        self.technicalQuality = technicalQuality.clamped01
        self.subjectComposition = subjectComposition.clamped01
        self.speechContinuity = speechContinuity.clamped01
        self.audioEventCoherence = audioEventCoherence.clamped01
        self.visualSemanticQuality = visualSemanticQuality.clamped01
        self.musicStructureQuality = musicStructureQuality.clamped01
        self.emotionalCurve = emotionalCurve.clamped01
        self.pacingQuality = pacingQuality.clamped01
        self.projectStyleFit = projectStyleFit.clamped01
        self.personalTasteFit = personalTasteFit.clamped01
        self.eventOrder = eventOrder.clamped01
        self.eventDiversity = eventDiversity.clamped01
        self.eventCoverage = eventCoverage.clamped01
        self.chronology = chronology.clamped01
        self.sceneDiversity = sceneDiversity.clamped01
        self.interEventSeparation = interEventSeparation.clamped01
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        func value(_ key: CodingKeys, fallback: Double = 0.5) -> Double {
            (try? values.decodeIfPresent(Double.self, forKey: key)) ?? fallback
        }
        self.init(
            total: value(.total, fallback: 0),
            highlightQuality: value(.highlightQuality),
            storyArc: value(.storyArc),
            diversity: value(.diversity),
            durationFit: value(.durationFit),
            musicalAlignment: value(.musicalAlignment),
            reviewQuality: value(.reviewQuality),
            semanticDiversity: value(.semanticDiversity),
            sourceDiversity: value(.sourceDiversity),
            momentCompleteness: value(.momentCompleteness),
            energyCurve: value(.energyCurve),
            audioContinuity: value(.audioContinuity),
            dropClimaxAlignment: value(.dropClimaxAlignment),
            continuity: value(.continuity),
            rhythmQuality: value(.rhythmQuality),
            technicalQuality: value(.technicalQuality),
            subjectComposition: value(.subjectComposition),
            speechContinuity: value(.speechContinuity),
            audioEventCoherence: value(.audioEventCoherence),
            visualSemanticQuality: value(.visualSemanticQuality),
            musicStructureQuality: value(.musicStructureQuality),
            emotionalCurve: value(.emotionalCurve),
            pacingQuality: value(.pacingQuality),
            projectStyleFit: value(.projectStyleFit),
            personalTasteFit: value(.personalTasteFit),
            eventOrder: value(.eventOrder),
            eventDiversity: value(.eventDiversity),
            eventCoverage: value(.eventCoverage),
            chronology: value(.chronology),
            sceneDiversity: value(.sceneDiversity),
            interEventSeparation: value(.interEventSeparation)
        )
    }

    public var strongestReasons: [String] {
        let values: [(String, Double)] = [
            ("highlight quality", highlightQuality), ("story arc", storyArc),
            ("semantic diversity", semanticDiversity), ("source diversity", sourceDiversity),
            ("moment completeness", momentCompleteness), ("energy curve", energyCurve),
            ("audio continuity", audioContinuity), ("drop–climax alignment", dropClimaxAlignment),
            ("continuity", continuity), ("rhythm", rhythmQuality),
            ("technical quality", technicalQuality), ("music alignment", musicalAlignment), ("duration fit", durationFit)
            , ("subject composition", subjectComposition), ("speech continuity", speechContinuity)
            , ("audio events", audioEventCoherence), ("visual semantics", visualSemanticQuality)
            , ("music structure", musicStructureQuality)
            , ("emotional curve", emotionalCurve), ("pacing fit", pacingQuality)
            , ("project style", projectStyleFit), ("personal taste", personalTasteFit)
            , ("event order", eventOrder), ("event diversity", eventDiversity)
            , ("event coverage", eventCoverage), ("chronology", chronology)
            , ("scene diversity", sceneDiversity), ("inter-event separation", interEventSeparation)
        ]
        return values.sorted { $0.1 > $1.1 }.prefix(3).map { "\($0.0) \(Int(($0.1 * 100).rounded()))%" }
    }
}

/// Immutable evidence shared by scoring multiple variants of the same project.
/// It avoids rebuilding scene-enriched candidate and asset indexes per variant.
public struct MontageScoringFeatures: Sendable {
    public var candidates: [UUID: Candidate]
    public var assets: [UUID: MediaAsset]
    public var semanticIndex: SemanticSceneIndex

    public init(assets: [MediaAsset], analyses: [AnalysisResult]) {
        self.candidates = Dictionary(uniqueKeysWithValues: analyses.flatMap(\.directorCandidates).map { ($0.id, $0) })
        self.assets = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) })
        self.semanticIndex = SemanticSceneIndex(candidates: Array(self.candidates.values))
    }
}

/// Injection point for automatic pairwise/global evaluation. It scores a
/// complete directed montage rather than isolated shots.
public protocol MontageGlobalScoring: Sendable {
    func score(plan: StoryPlan, timeline: Timeline, assets: [MediaAsset], analyses: [AnalysisResult]) -> MontageGlobalScore
}

public struct DefaultMontageGlobalScorer: MontageGlobalScoring, Sendable {
    public init() {}

    public func score(plan: StoryPlan, timeline: Timeline, assets: [MediaAsset], analyses: [AnalysisResult]) -> MontageGlobalScore {
        score(plan: plan, timeline: timeline, features: MontageScoringFeatures(assets: assets, analyses: analyses), analyses: analyses)
    }

    public func score(
        plan: StoryPlan,
        timeline: Timeline,
        features: MontageScoringFeatures,
        analyses: [AnalysisResult]
    ) -> MontageGlobalScore {
        let primaries = timeline.items.filter { $0.kind != .title && $0.overlay == nil }
        guard !primaries.isEmpty else {
            return MontageGlobalScore(total: 0, highlightQuality: 0, storyArc: 0, diversity: 0, durationFit: 0, musicalAlignment: 0, reviewQuality: 0, semanticDiversity: 0, sourceDiversity: 0, momentCompleteness: 0, energyCurve: 0, audioContinuity: 0, dropClimaxAlignment: 0, continuity: 0, rhythmQuality: 0, technicalQuality: 0, subjectComposition: 0, speechContinuity: 0, audioEventCoherence: 0, visualSemanticQuality: 0, musicStructureQuality: 0)
        }
        let context = HighlightRankingContext(prompt: plan.prompt, preset: plan.preset, constraints: plan.constraints, autonomousStyle: plan.autonomousDecision?.finalStyle)
        let ranker = ContextualHighlightRanker()
        let weightedHighlights = primaries.reduce(into: (score: 0.0, duration: 0.0)) { result, item in
            guard let id = item.candidateID, let candidate = features.candidates[id] else { return }
            let duration = max(0.05, item.timelineDuration)
            result.score += min(1, ranker.score(candidate, asset: features.assets[candidate.assetID], context: context)) * duration
            result.duration += duration
        }
        let highlight = weightedHighlights.duration == 0 ? 0.35 : weightedHighlights.score / weightedHighlights.duration
        let roles = Set(primaries.compactMap(\.storyRole))
        let expectedRoles = plan.autonomousDecision?.story.roles(count: primaries.count)
        let required: Set<StoryRole> = expectedRoles.map(Set.init)
            ?? (primaries.count >= 6 ? [.intro, .climax, .reaction, .outro]
                : primaries.count >= 5 ? [.intro, .climax, .outro] : [.climax])
        let roleCoverage = Double(required.intersection(roles).count) / Double(required.count)
        let climaxPosition = primaries.firstIndex(where: { $0.storyRole == .climax }).map { Double($0) / Double(max(1, primaries.count - 1)) } ?? 0
        let expectedClimax = expectedRoles?.firstIndex(of: .climax).map { Double($0) / Double(max(1, (expectedRoles?.count ?? 1) - 1)) }
        let climaxPlacement = expectedClimax.map { max(0, 1 - abs(climaxPosition - $0) / 0.55) }
            ?? (required.contains(.climax) ? max(0, 1 - abs(climaxPosition - 0.80) / 0.55) : 1)
        let edgeQuality = beginningEndQuality(primaries, candidates: features.candidates)
        let emotion = emotionalCurve(primaries, candidates: features.candidates)
        let storyArc = roleCoverage * 0.50 + climaxPlacement * 0.20 + edgeQuality * 0.17 + emotion * 0.13
        let distinctAssets = Set(primaries.compactMap(\.assetID)).count
        let diversity = min(1, Double(distinctAssets) / Double(max(1, min(primaries.count, 5))))
        let durationFit = max(0, 1 - abs(timeline.duration - plan.constraints.targetDuration) / max(5, plan.constraints.targetDuration))
        let musical = musicalAlignment(timeline)
        let review = TimelineSelfReviewer().review(timeline, plan: plan, analyses: analyses).score
        let semantic = semanticDiversity(primaries, candidates: features.candidates, index: features.semanticIndex)
        let source = sourceDiversity(primaries)
        let completeness = momentCompleteness(primaries, candidates: features.candidates)
        let energy = energyCurve(primaries, candidates: features.candidates, desiredCurve: plan.autonomousDecision?.story.energyCurve)
        let audio = audioContinuity(primaries, candidates: features.candidates, assets: features.assets)
        let drop = dropClimaxAlignment(timeline, primaries: primaries)
        let continuity = continuity(primaries, candidates: features.candidates, index: features.semanticIndex)
        let rhythm = rhythmQuality(primaries, pacing: plan.constraints.pacing)
        let technical = technicalQuality(primaries, candidates: features.candidates)
        let subject = subjectComposition(primaries, candidates: features.candidates)
        let speech = speechContinuity(primaries, candidates: features.candidates)
        let audioEvents = audioEventCoherence(primaries, candidates: features.candidates)
        let visual = visualSemanticQuality(primaries, candidates: features.candidates)
        let musicStructure = musicStructureQuality(timeline, primaries: primaries, candidates: features.candidates)
        let emotional = emotionalCurve(primaries, candidates: features.candidates)
        let pacing = pacingFit(primaries, rhythm: rhythm, decision: plan.autonomousDecision)
        let projectStyle = styleFit(primaries, timeline: timeline, candidates: features.candidates, expected: plan.autonomousDecision?.projectStyle.vector)
        let personalTaste = plan.autonomousDecision.map {
            $0.personalConfidence < 0.04 ? 0.5 : styleFit(primaries, timeline: timeline, candidates: features.candidates, expected: $0.personalTaste)
        } ?? 0.5
        let eventScores = eventAwareScores(plan: plan, primaries: primaries, candidates: features.candidates)
        // Editorial priorities are hierarchical. Emotion, story, complete
        // moments and rhythm determine whether a variant works; craft and
        // style refine that decision but cannot outvote it through a pile of
        // small technical wins.
        let editorialPrimary = emotional * 0.26 + storyArc * 0.27 + completeness * 0.21
            + rhythm * 0.14 + audio * 0.12
        let craftSecondary = continuity * 0.23 + subject * 0.14 + speech * 0.14
            + audioEvents * 0.11 + visual * 0.11 + technical * 0.12
            + review * 0.09 + pacing * 0.06
        let supporting = highlight * 0.16 + diversity * 0.05 + semantic * 0.08
            + source * 0.07 + durationFit * 0.08 + energy * 0.14
            + musical * 0.07 + drop * 0.07 + musicStructure * 0.05
            + projectStyle * 0.08 + personalTaste * 0.05
        let baseTotal = editorialPrimary * 0.64 + craftSecondary * 0.25 + supporting * 0.11
        let eventAggregate = eventScores.order * 0.23 + eventScores.diversity * 0.13
            + eventScores.coverage * 0.18 + eventScores.chronology * 0.22
            + eventScores.sceneDiversity * 0.11 + eventScores.separation * 0.13
        let total = plan.eventStory == nil ? baseTotal : baseTotal * 0.84 + eventAggregate * 0.16
        return MontageGlobalScore(
            total: total,
            highlightQuality: highlight,
            storyArc: storyArc,
            diversity: diversity,
            durationFit: durationFit,
            musicalAlignment: musical,
            reviewQuality: review,
            semanticDiversity: semantic,
            sourceDiversity: source,
            momentCompleteness: completeness,
            energyCurve: energy,
            audioContinuity: audio,
            dropClimaxAlignment: drop,
            continuity: continuity,
            rhythmQuality: rhythm,
            technicalQuality: technical,
            subjectComposition: subject,
            speechContinuity: speech,
            audioEventCoherence: audioEvents,
            visualSemanticQuality: visual,
            musicStructureQuality: musicStructure,
            emotionalCurve: emotional,
            pacingQuality: pacing,
            projectStyleFit: projectStyle,
            personalTasteFit: personalTaste,
            eventOrder: eventScores.order,
            eventDiversity: eventScores.diversity,
            eventCoverage: eventScores.coverage,
            chronology: eventScores.chronology,
            sceneDiversity: eventScores.sceneDiversity,
            interEventSeparation: eventScores.separation
        )
    }

    private struct EventAwareScores {
        var order: Double
        var diversity: Double
        var coverage: Double
        var chronology: Double
        var sceneDiversity: Double
        var separation: Double
    }

    private func eventAwareScores(plan: StoryPlan, primaries: [TimelineItem], candidates: [UUID: Candidate]) -> EventAwareScores {
        guard let eventStory = plan.eventStory, !eventStory.entries.isEmpty else {
            return EventAwareScores(order: 0.5, diversity: 0.5, coverage: 0.5, chronology: 0.5, sceneDiversity: 0.5, separation: 0.5)
        }
        let expected = eventStory.entries.map(\.eventID)
        var actualItems = primaries
        if let coldOpenID = eventStory.coldOpenCandidateID,
           actualItems.first?.candidateID == coldOpenID {
            actualItems.removeFirst()
        }
        let actualSequence = actualItems.compactMap(\.eventID)
        let compressed = actualSequence.reduce(into: [UUID]()) { result, id in
            if result.last != id { result.append(id) }
        }
        let order = sequenceAgreement(compressed, expected)
        let uniqueEvents = Set(actualSequence)
        let diversity = min(1, Double(uniqueEvents.count) / Double(max(1, min(expected.count, 6))))
        let coverage = Double(uniqueEvents.intersection(expected).count) / Double(max(1, expected.count))
        let dateByEvent = Dictionary(uniqueKeysWithValues: eventStory.entries.compactMap { entry in
            entry.startDate.map { (entry.eventID, $0) }
        })
        let datedOrder = compressed.filter { dateByEvent[$0] != nil }
        var inversions = 0
        var comparisons = 0
        for first in datedOrder.indices {
            for second in datedOrder.indices where second > first {
                comparisons += 1
                if let lhs = dateByEvent[datedOrder[first]], let rhs = dateByEvent[datedOrder[second]], lhs > rhs { inversions += 1 }
            }
        }
        let chronology = comparisons == 0 ? order : 1 - Double(inversions) / Double(comparisons)
        let plannedSceneCount = eventStory.entries.reduce(0) { $0 + $1.sceneIDs.count }
        let actualScenes = Set(actualItems.compactMap(\.eventSceneID)).count
        let sceneDiversity = plannedSceneCount == 0
            ? min(1, Double(actualScenes) / Double(max(1, min(actualItems.count, 6))))
            : min(1, Double(actualScenes) / Double(max(1, min(plannedSceneCount, max(1, actualItems.count)))))
        let groupedCandidates = Dictionary(grouping: actualItems.compactMap { item -> (UUID, Candidate)? in
            guard let eventID = item.eventID, let candidateID = item.candidateID, let candidate = candidates[candidateID] else { return nil }
            return (eventID, candidate)
        }, by: { $0.0 }).mapValues { values in values.map(\.1) }
        let groups = Array(groupedCandidates.values)
        var similarities: [Double] = []
        if groups.count > 1 {
            for first in groups.indices {
                for second in groups.indices where second > first {
                    let lhs = groups[first].reduce(into: Set<String>()) { $0.formUnion(semanticTokens($1)) }
                    let rhs = groups[second].reduce(into: Set<String>()) { $0.formUnion(semanticTokens($1)) }
                    let union = lhs.union(rhs)
                    similarities.append(union.isEmpty ? 0 : Double(lhs.intersection(rhs).count) / Double(union.count))
                }
            }
        }
        let repetition = similarities.isEmpty ? 0 : similarities.reduce(0, +) / Double(similarities.count)
        return EventAwareScores(
            order: order,
            diversity: diversity,
            coverage: coverage,
            chronology: chronology.clamped01,
            sceneDiversity: sceneDiversity,
            separation: (1 - repetition).clamped01
        )
    }

    private func sequenceAgreement(_ actual: [UUID], _ expected: [UUID]) -> Double {
        guard !actual.isEmpty || !expected.isEmpty else { return 1 }
        var previous = Array(repeating: 0, count: expected.count + 1)
        for value in actual {
            var current = Array(repeating: 0, count: expected.count + 1)
            for index in expected.indices {
                current[index + 1] = value == expected[index]
                    ? previous[index] + 1
                    : max(previous[index + 1], current[index])
            }
            previous = current
        }
        return Double(previous.last ?? 0) / Double(max(1, max(actual.count, expected.count)))
    }

    private func musicalAlignment(_ timeline: Timeline) -> Double {
        guard let structure = timeline.music?.structure else { return 0.55 }
        let accents = structure.accents ?? []
        let roleWeights: [MusicAccentKind: Double] = [
            .beat: 0.42, .strongBeat: 0.66, .onset: 0.62, .peak: 0.72,
            .downbeat: 0.78, .phrase: 0.90, .drop: 1, .sectionPeak: 1,
            .transition: 0.76, .breakdown: 0.72
        ]
        guard !accents.isEmpty else { return (structure.downbeatTimestamps?.isEmpty == false) ? 0.52 : 0.42 }
        let primaries = timeline.items.filter { $0.kind != .title && $0.overlay == nil }
        let cuts = zip(primaries, primaries.dropFirst()).compactMap { previous, incoming -> TimelineItem? in
            let roleChanged = previous.storyRole != incoming.storyRole
            let sceneChanged = previous.eventSceneID != nil && incoming.eventSceneID != nil && previous.eventSceneID != incoming.eventSceneID
            let eventChanged = previous.eventID != nil && incoming.eventID != nil && previous.eventID != incoming.eventID
            let structuralRole: Set<StoryRole> = [.intro, .climax, .reaction, .outro]
            return roleChanged || sceneChanged || eventChanged || structuralRole.contains(incoming.storyRole ?? .bRoll) ? incoming : nil
        }
        guard !cuts.isEmpty else { return 0.7 }
        let tolerance = max(0.08, structure.beatInterval * 0.32)
        return cuts.reduce(0) { total, item in
            let preferredKinds: Set<MusicAccentKind>
            switch item.storyRole {
            case .climax: preferredKinds = [.drop, .sectionPeak, .phrase, .downbeat]
            case .action: preferredKinds = [.strongBeat, .downbeat, .onset, .transition]
            case .intro, .reaction, .outro: preferredKinds = [.phrase, .transition, .breakdown, .downbeat]
            default: preferredKinds = [.downbeat, .strongBeat, .beat, .phrase]
            }
            let scored = accents.map { accent -> Double in
                let distance = abs(accent.time - item.timelineStart)
                let timing = max(0, 1 - distance / tolerance)
                let kind = roleWeights[accent.kind] ?? 0.5
                let role = preferredKinds.contains(accent.kind) ? 1 : 0.58
                return timing * kind * role * (accent.confidence ?? 0.5)
            }
            return total + max(0.45, scored.max() ?? 0)
        } / Double(cuts.count)
    }

    private func semanticDiversity(_ items: [TimelineItem], candidates: [UUID: Candidate], index: SemanticSceneIndex) -> Double {
        let values = items.compactMap { $0.candidateID.flatMap { candidates[$0] } }
        guard values.count > 1 else { return 0.5 }
        var distances: [Double] = []
        for first in values.indices {
            for second in values.indices where second > first {
                distances.append(1 - index.similarity(between: values[first], and: values[second]))
            }
        }
        return distances.reduce(0, +) / Double(max(1, distances.count))
    }

    private func semanticTokens(_ candidate: Candidate) -> Set<String> {
        var result = Set(candidate.tags.map { $0.lowercased() })
        if let summary = candidate.insights?.sceneSummary {
            result.formUnion(summary.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count >= 3 })
        }
        if let emotion = candidate.insights?.emotion, !emotion.isEmpty { result.insert("emotion:\(emotion.lowercased())") }
        return result
    }

    private func sourceDiversity(_ items: [TimelineItem]) -> Double {
        guard items.count > 1 else { return 0.5 }
        var values: [Double] = []
        for first in items.indices {
            for second in items.indices where second > first {
                let lhs = items[first]
                let rhs = items[second]
                guard lhs.assetID == rhs.assetID else { values.append(1); continue }
                let overlap = max(0, min(lhs.sourceStart + lhs.sourceDuration, rhs.sourceStart + rhs.sourceDuration) - max(lhs.sourceStart, rhs.sourceStart))
                let union = max(0.05, max(lhs.sourceStart + lhs.sourceDuration, rhs.sourceStart + rhs.sourceDuration) - min(lhs.sourceStart, rhs.sourceStart))
                values.append(1 - overlap / union)
            }
        }
        return values.reduce(0, +) / Double(max(1, values.count))
    }

    private func momentCompleteness(_ items: [TimelineItem], candidates: [UUID: Candidate]) -> Double {
        let values = items.compactMap { item -> Double? in
            guard let id = item.candidateID, let candidate = candidates[id], let boundary = candidate.momentBoundary else { return nil }
            let itemStart = item.sourceStart
            let itemEnd = item.sourceStart + item.sourceDuration
            let peak = boundary.peakTime
            let containsPeak = itemStart <= peak && itemEnd >= peak ? 1.0 : 0.0
            let availableLead = max(0.05, peak - boundary.anticipationStart)
            let availableTail = max(0.05, boundary.completionEnd - peak)
            let lead = max(0, peak - max(itemStart, boundary.anticipationStart)) / availableLead
            let tail = max(0, min(itemEnd, boundary.completionEnd) - peak) / availableTail
            return containsPeak * 0.36 + lead.clamped01 * 0.28 + tail.clamped01 * 0.36
        }
        return values.isEmpty ? 0.58 : values.reduce(0, +) / Double(values.count)
    }

    private func energyCurve(_ items: [TimelineItem], candidates: [UUID: Candidate], desiredCurve: [Double]? = nil) -> Double {
        let desired: [StoryRole: Double] = [.intro: 0.30, .setup: 0.40, .buildup: 0.58, .action: 0.76, .climax: 0.96, .reaction: 0.52, .outro: 0.34, .bRoll: 0.48]
        let matches = items.compactMap { item -> Double? in
            guard let id = item.candidateID, let candidate = candidates[id] else { return nil }
            let actual = candidate.insights?.dynamics ?? candidate.scores.action
            return 1 - abs(actual - (desired[item.storyRole ?? .bRoll] ?? 0.5))
        }
        guard !matches.isEmpty else { return 0.45 }
        let base = matches.reduce(0, +) / Double(matches.count)
        let climaxEnergy = items.compactMap { item -> Double? in
            guard item.storyRole == .climax, let id = item.candidateID, let candidate = candidates[id] else { return nil }
            return candidate.insights?.dynamics ?? candidate.scores.action
        }.max() ?? 0
        let otherEnergy = items.compactMap { item -> Double? in
            guard item.storyRole != .climax, let id = item.candidateID, let candidate = candidates[id] else { return nil }
            return candidate.insights?.dynamics ?? candidate.scores.action
        }.max() ?? climaxEnergy
        let peak = climaxEnergy >= otherEnergy - 0.05 ? 1.0 : max(0, 1 - (otherEnergy - climaxEnergy) * 2)
        let autonomousFit: Double = {
            guard let desiredCurve, !desiredCurve.isEmpty else { return base }
            let actual = items.compactMap { item in
                item.candidateID.flatMap { candidates[$0] }.map { $0.insights?.dynamics ?? $0.scores.action }
            }
            guard !actual.isEmpty else { return 0.45 }
            let count = max(3, min(10, max(actual.count, desiredCurve.count)))
            func sample(_ values: [Double], index: Int) -> Double {
                let position = Double(index) / Double(max(1, count - 1))
                return values[min(values.count - 1, Int((position * Double(values.count - 1)).rounded()))]
            }
            return (0..<count).reduce(0) { $0 + max(0, 1 - abs(sample(actual, index: $1) - sample(desiredCurve, index: $1))) } / Double(count)
        }()
        return desiredCurve == nil ? base * 0.72 + peak * 0.28 : autonomousFit * 0.70 + peak * 0.18 + base * 0.12
    }

    private func audioContinuity(_ items: [TimelineItem], candidates: [UUID: Candidate], assets: [UUID: MediaAsset]) -> Double {
        let audible = items.compactMap { item -> (Double, Double)? in
            guard let id = item.candidateID, let candidate = candidates[id], assets[candidate.assetID]?.metadata.hasAudio == true else { return nil }
            let usefulness = candidate.insights?.originalAudioUsefulness ?? 0.4
            return (item.effectiveAudioAdjustments.effectiveVolume, usefulness >= 0.65 ? 0.9 : 0.36)
        }
        guard !audible.isEmpty else { return 0.72 }
        let intent = audible.reduce(0) { $0 + max(0, 1 - abs($1.0 - $1.1)) } / Double(audible.count)
        let changes = zip(audible, audible.dropFirst()).map { abs($0.0.0 - $0.1.0) }
        let continuity = changes.isEmpty ? 1 : max(0, 1 - changes.reduce(0, +) / Double(changes.count) * 0.55)
        return intent * 0.78 + continuity * 0.22
    }

    private func dropClimaxAlignment(_ timeline: Timeline, primaries: [TimelineItem]) -> Double {
        guard let structure = timeline.music?.structure else { return 0.55 }
        let drops = Array(Set((structure.drops ?? []) + (structure.accents ?? []).filter { $0.kind == .drop }.map(\.time)))
        guard !drops.isEmpty else { return 0.48 }
        let climaxPoints = primaries.filter { $0.storyRole == .climax }.map { $0.timelineStart + $0.timelineDuration * 0.45 }
        guard !climaxPoints.isEmpty else { return 0 }
        let tolerance = max(1.25, structure.beatInterval * 4)
        let timing = climaxPoints.map { point in
            let nearest = drops.map { abs($0 - point) }.min() ?? tolerance * 2
            return max(0, 1 - nearest / tolerance)
        }.max() ?? 0
        let confidence = structure.dropConfidence
            ?? structure.accents?.filter { $0.kind == .drop }.compactMap(\.confidence).max()
            ?? 0.28
        return timing * (0.55 + confidence * 0.45)
    }

    private func continuity(_ items: [TimelineItem], candidates: [UUID: Candidate], index: SemanticSceneIndex) -> Double {
        guard items.count > 1 else { return 0.62 }
        let roleOrder: [StoryRole: Int] = [.intro: 0, .setup: 1, .buildup: 2, .action: 3, .climax: 4, .reaction: 5, .outro: 6, .bRoll: 3]
        var pairScores: [Double] = []
        for pair in zip(items, items.dropFirst()) {
            guard let leftID = pair.0.candidateID, let rightID = pair.1.candidateID,
                  let left = candidates[leftID], let right = candidates[rightID] else { continue }
            let similarity = index.similarity(between: left, and: right)
            // Neighboring shots need a semantic bridge, but exact repetition is
            // not continuity. A moderate overlap is editorially strongest.
            let repeatedEvent = left.insights?.semanticEventID != nil && left.insights?.semanticEventID == right.insights?.semanticEventID
            let semanticBridge = repeatedEvent
                ? max(0.22, 1 - abs(similarity - 0.62) / 0.62)
                : max(0, 1 - abs(similarity - 0.42) / 0.58)
            let leftEnergy = left.insights?.dynamics ?? left.scores.action
            let rightEnergy = right.insights?.dynamics ?? right.scores.action
            let energyBridge = pair.1.storyRole == .climax ? 1 : max(0, 1 - abs(rightEnergy - leftEnergy) * 0.9)
            let leftRole = roleOrder[pair.0.storyRole ?? .bRoll] ?? 3
            let rightRole = roleOrder[pair.1.storyRole ?? .bRoll] ?? 3
            let roleFlow = rightRole + 1 >= leftRole ? 1.0 : 0.35
            let leftSubject = left.insights?.subjectTracking?.mainSubject
            let rightSubject = right.insights?.subjectTracking?.mainSubject
            let motionDirection: Double = {
                guard let lhs = leftSubject, let rhs = rightSubject else { return 0.68 }
                if abs(lhs.movementX) < 0.035 || abs(rhs.movementX) < 0.035 { return 0.72 }
                return lhs.movementX.sign == rhs.movementX.sign ? 1 : 0.34
            }()
            let shotScale: Double = {
                guard let lhs = leftSubject?.observations.last?.region.area,
                      let rhs = rightSubject?.observations.first?.region.area else { return 0.68 }
                let ratio = max(lhs, rhs) / max(0.001, min(lhs, rhs))
                let sameSubject = leftSubject?.kind == rightSubject?.kind
                    && (leftSubject?.label == rightSubject?.label || repeatedEvent)
                guard sameSubject else { return 0.72 }
                if ratio < 1.18 { return 0.22 }
                if ratio < 1.55 { return 0.22 + (ratio - 1.18) / 0.37 * 0.68 }
                if ratio <= 3.8 { return 1 }
                return max(0.35, 1 - (ratio - 3.8) / 5.2)
            }()
            let eyeTrace: Double = {
                guard let lhs = leftSubject?.observations.last?.region,
                      let rhs = rightSubject?.observations.first?.region else { return 0.66 }
                return max(0, 1 - hypot(lhs.centerX - rhs.centerX, lhs.centerY - rhs.centerY) / 0.92)
            }()
            let composition = max(0, 1 - abs((left.insights?.composition ?? 0.5) - (right.insights?.composition ?? 0.5)))
            let exposure = max(0, 1 - abs((left.insights?.exposureQuality ?? 0.5) - (right.insights?.exposureQuality ?? 0.5)) * 1.2)
            let sourceOverlap: Double = {
                guard left.assetID == right.assetID else { return 1 }
                let overlap = max(0, min(pair.0.sourceStart + pair.0.sourceDuration, pair.1.sourceStart + pair.1.sourceDuration) - max(pair.0.sourceStart, pair.1.sourceStart))
                return max(0, 1 - overlap / max(0.05, min(pair.0.sourceDuration, pair.1.sourceDuration)))
            }()
            pairScores.append(semanticBridge * 0.20 + energyBridge * 0.12 + roleFlow * 0.10
                + motionDirection * 0.08 + shotScale * 0.12 + eyeTrace * 0.12
                + composition * 0.08 + exposure * 0.06 + sourceOverlap * 0.12)
        }
        return pairScores.isEmpty ? 0.5 : pairScores.reduce(0, +) / Double(pairScores.count)
    }

    private func rhythmQuality(_ items: [TimelineItem], pacing: Double) -> Double {
        guard !items.isEmpty else { return 0 }
        let roleBase: [StoryRole: Double] = [.intro: 6.8, .setup: 5.8, .buildup: 4.6, .action: 2.8, .climax: 4.2, .reaction: 5.2, .outro: 6.4, .bRoll: 2.4]
        let paceFactor = 1.18 - pacing.clamped01 * 0.42
        let roleFit = items.reduce(0) { total, item in
            let desired = (roleBase[item.storyRole ?? .bRoll] ?? 4) * paceFactor
            let error = abs(item.timelineDuration - desired) / max(1, desired)
            return total + max(0, 1 - error)
        } / Double(items.count)
        let durations = items.map(\.timelineDuration)
        let mean = durations.reduce(0, +) / Double(durations.count)
        let deviation = durations.reduce(0) { $0 + abs($1 - mean) } / Double(durations.count) / max(0.2, mean)
        let variation = items.count < 4 ? 0.7 : min(1, max(0, deviation / 0.28))
        let minimumGuard = durations.filter { $0 >= 0.75 }.count == durations.count ? 1.0 : 0.25
        return roleFit * 0.68 + variation * 0.20 + minimumGuard * 0.12
    }

    private func technicalQuality(_ items: [TimelineItem], candidates: [UUID: Candidate]) -> Double {
        let weighted = items.reduce(into: (score: 0.0, duration: 0.0)) { result, item in
            guard let id = item.candidateID, let candidate = candidates[id] else { return }
            let insights = candidate.insights
            let sharpness = insights?.sharpness ?? candidate.scores.quality
            let exposure = insights?.exposureQuality ?? candidate.scores.quality
            let shake = insights?.shake ?? max(0, 1 - candidate.scores.stability)
            let noise = insights?.noise ?? max(0, 1 - candidate.scores.quality)
            let value = candidate.scores.quality * 0.30 + candidate.scores.stability * 0.23
                + sharpness * 0.17 + exposure * 0.14 + (1 - shake) * 0.10 + (1 - noise) * 0.06
            let duration = max(0.05, item.timelineDuration)
            result.score += value.clamped01 * duration
            result.duration += duration
        }
        return weighted.duration == 0 ? 0.4 : weighted.score / weighted.duration
    }

    private func beginningEndQuality(_ items: [TimelineItem], candidates: [UUID: Candidate]) -> Double {
        guard let first = items.first, let last = items.last,
              let firstID = first.candidateID, let lastID = last.candidateID,
              let opening = candidates[firstID], let closing = candidates[lastID] else { return 0.45 }
        let openRole = opening.insights?.roleScores[.intro] ?? opening.scores.interest
        let closeRole = closing.insights?.roleScores[.outro] ?? closing.scores.interest
        let openingComposition = opening.insights?.composition ?? opening.scores.quality
        let closingCompletion = closing.momentBoundary.map { boundary in
            let end = last.sourceStart + last.sourceDuration
            return max(0, 1 - abs(end - boundary.completionEnd) / max(0.4, boundary.duration * 0.35))
        } ?? 0.58
        return (openRole * 0.30 + openingComposition * 0.20 + closeRole * 0.30 + closingCompletion * 0.20).clamped01
    }

    private func emotionalCurve(_ items: [TimelineItem], candidates: [UUID: Candidate]) -> Double {
        let values = items.compactMap { item -> (StoryRole, Double)? in
            guard let id = item.candidateID, let candidate = candidates[id] else { return nil }
            let emotion = candidate.insights?.emotion?.isEmpty == false ? 0.88 : candidate.tags.contains("people") ? 0.66 : 0.38
            let audio = candidate.insights?.audioEvents?.filter { [.laughter, .applause, .scream, .impact].contains($0.kind) }.map(\.confidence).max() ?? 0
            return (item.storyRole ?? .bRoll, min(1, emotion * 0.58 + candidate.scores.interest * 0.27 + audio * 0.25))
        }
        guard !values.isEmpty else { return 0.45 }
        let climax = values.filter { $0.0 == .climax }.map(\.1).max() ?? 0
        let intro = values.first?.1 ?? 0.4
        let outro = values.last?.1 ?? 0.4
        let peak = climax >= intro + 0.08 ? 1 : max(0, 0.55 + climax - intro)
        let release = outro <= max(climax, 0.5) ? 1 : 0.55
        return peak * 0.66 + release * 0.34
    }

    private func pacingFit(_ items: [TimelineItem], rhythm: Double, decision: AutonomousDirectorDecision?) -> Double {
        guard let decision, !items.isEmpty else { return rhythm }
        let mean = items.reduce(0) { $0 + $1.timelineDuration } / Double(items.count)
        let durationFit = max(0, 1 - abs(mean - decision.grammar.meanShotDuration) / max(1, decision.grammar.meanShotDuration))
        let transitionShare = Double(items.filter { $0.transition != nil }.count) / Double(items.count)
        let transitionFit = max(0, 1 - abs(transitionShare - decision.grammar.transitionDensity) * 2.4)
        return rhythm * 0.48 + durationFit * 0.38 + transitionFit * 0.14
    }

    private func styleFit(
        _ items: [TimelineItem],
        timeline: Timeline,
        candidates: [UUID: Candidate],
        expected: DirectorStyleVector?
    ) -> Double {
        guard let expected, !items.isEmpty else { return 0.5 }
        let values = items.compactMap { item in item.candidateID.flatMap { candidates[$0] } }
        guard !values.isEmpty else { return 0.42 }
        let action = values.reduce(0) { $0 + ($1.insights?.dynamics ?? $1.scores.action) } / Double(values.count)
        let cinematic = values.reduce(0) {
            $0 + (($1.insights?.composition ?? $1.scores.quality) * 0.48
                + $1.scores.stability * 0.24 + ($1.insights?.visualAppeal ?? $1.scores.interest) * 0.28)
        } / Double(values.count)
        let emotional = values.reduce(0) { total, candidate in
            total + (candidate.insights?.emotion?.isEmpty == false ? 0.88 : candidate.tags.contains("people") ? 0.62 : 0.28)
        } / Double(values.count)
        let meanDuration = items.reduce(0) { $0 + $1.timelineDuration } / Double(items.count)
        let shotDuration = ((meanDuration - 1.5) / 6.5).clamped01
        let pacing = (1 - shotDuration * 0.82).clamped01
        let transition = Double(items.filter { $0.transition != nil }.count) / Double(items.count)
        let music = timeline.music?.autonomousIntent?.desiredEnergy ?? {
            switch timeline.music?.style {
            case .energetic, .electronic: return 0.78
            case .cinematic, .joyful: return 0.60
            case .acoustic: return 0.42
            case .calm: return 0.24
            case nil: return 0.34
            }
        }()
        let actual = DirectorStyleVector(
            energy: action * 0.72 + pacing * 0.28,
            cinematic: cinematic,
            emotional: emotional,
            action: action,
            intimacy: emotional * 0.72,
            atmosphere: cinematic * (1 - action * 0.34),
            pacing: pacing,
            visualDensity: min(1, Double(Set(values.flatMap(\.tags)).count) / 14),
            transitionIntensity: transition,
            musicIntensity: music,
            shotDuration: shotDuration
        )
        return max(0, 1 - actual.distance(to: expected))
    }

    private func subjectComposition(_ items: [TimelineItem], candidates: [UUID: Candidate]) -> Double {
        let scores = items.compactMap { item -> Double? in
            guard let id = item.candidateID, let candidate = candidates[id],
                  let tracking = candidate.insights?.subjectTracking else { return nil }
            let reframe = item.effectiveVideoAdjustments.subjectReframe
            let reframeFit = reframe.map { $0.confidence } ?? tracking.compositionQuality
            let faceSafety = tracking.mainSubject?.kind == .face && tracking.mainSubject?.observations.contains(where: { $0.region.touchesEdge }) == true
                ? (reframe == nil ? 0.25 : 0.88)
                : 1
            return tracking.mainSubjectVisibility * 0.40 + tracking.compositionQuality * 0.25 + reframeFit * 0.20 + faceSafety * 0.15
        }
        return scores.isEmpty ? 0.54 : scores.reduce(0, +) / Double(scores.count)
    }

    private func speechContinuity(_ items: [TimelineItem], candidates: [UUID: Candidate]) -> Double {
        let values = items.compactMap { item -> Double? in
            guard let id = item.candidateID, let speech = candidates[id]?.insights?.speech else { return nil }
            let itemEnd = item.sourceStart + item.sourceDuration
            let keepsStart = item.sourceStart <= speech.phraseStart + 0.12 ? 1.0 : 0.15
            let keepsEnd = itemEnd >= speech.phraseEnd - 0.12 ? 1.0 : 0.10
            // Candidate evidence describes the analyzed source range. Score
            // the actual Timeline trim so a later cut cannot inherit a stale
            // "complete phrase" flag after removing its beginning or ending.
            let phrase = keepsStart * 0.48 + keepsEnd * 0.52
            return phrase * 0.68 + speech.confidence * 0.22 + min(1, (speech.silenceBefore + speech.silenceAfter) / 0.5) * 0.10
        }
        return values.isEmpty ? 0.66 : values.reduce(0, +) / Double(values.count)
    }

    private func audioEventCoherence(_ items: [TimelineItem], candidates: [UUID: Candidate]) -> Double {
        let values = items.compactMap { item -> Double? in
            guard let id = item.candidateID, let candidate = candidates[id],
                  let events = candidate.insights?.audioEvents, !events.isEmpty else { return nil }
            let useful = events.filter { ![.silence, .wind].contains($0.kind) }
            let evidence = useful.map { $0.confidence * max(0.35, $0.intensity) }.max() ?? 0
            let nuisance = events.filter { [.silence, .wind].contains($0.kind) }.map(\.confidence).max() ?? 0
            let audible = item.effectiveAudioAdjustments.effectiveVolume
            let intent = evidence > nuisance
                ? max(0, 1 - abs(audible - 0.90))
                : max(0, 1 - abs(audible - 0.34))
            let peakAlignment: Double = {
                guard let boundary = candidate.momentBoundary,
                      let event = useful.filter({ [.impact, .splash, .scream, .applause].contains($0.kind) }).max(by: { $0.confidence < $1.confidence }) else { return 0.62 }
                let eventPeak = (event.startTime + event.endTime) / 2
                return max(0, 1 - abs(eventPeak - boundary.peakTime) / max(0.35, boundary.duration * 0.30))
            }()
            return intent * 0.46 + evidence * 0.34 + peakAlignment * 0.20
        }
        return values.isEmpty ? 0.60 : values.reduce(0, +) / Double(values.count)
    }

    private func visualSemanticQuality(_ items: [TimelineItem], candidates: [UUID: Candidate]) -> Double {
        let values = items.compactMap { item -> Double? in
            guard let id = item.candidateID, let candidate = candidates[id] else { return nil }
            let insight = candidate.insights
            let embeddingConfidence = insight?.visualEmbedding?.confidence ?? 0.38
            let subject = insight?.subjectTracking?.mainSubjectVisibility ?? 0.48
            return candidate.scores.quality * 0.18 + candidate.scores.stability * 0.12
                + candidate.scores.uniqueness * 0.17 + (insight?.composition ?? candidate.scores.quality) * 0.17
                + (insight?.dynamics ?? candidate.scores.action) * 0.12 + subject * 0.12
                + embeddingConfidence * 0.12
        }
        return values.isEmpty ? 0.42 : values.reduce(0, +) / Double(values.count)
    }

    private func musicStructureQuality(_ timeline: Timeline, primaries: [TimelineItem], candidates: [UUID: Candidate]) -> Double {
        guard let structure = timeline.music?.structure else { return 0.48 }
        let confidences = [structure.tempoConfidence, structure.downbeatConfidence, structure.phraseConfidence, structure.sectionConfidence, structure.dropConfidence].compactMap { $0 }
        let confidence = confidences.isEmpty ? 0.28 : confidences.reduce(0, +) / Double(confidences.count)
        let sectionFit = primaries.compactMap { item -> Double? in
            guard let id = item.candidateID, let candidate = candidates[id],
                  let section = structure.sections.last(where: { item.timelineStart >= $0.start }) else { return nil }
            let desired = candidate.insights?.dynamics ?? candidate.scores.action
            return max(0, 1 - abs(desired - section.energy)) * (section.confidence ?? 0.5)
        }
        let fit = sectionFit.isEmpty ? 0.45 : sectionFit.reduce(0, +) / Double(sectionFit.count)
        let measured = structure.analysisIsMeasured == true ? 1.0 : 0.34
        return confidence * 0.38 + fit * 0.42 + measured * 0.20
    }
}

public struct TimelineSafetyValidator: Sendable {
    public init() {}

    public func violations(candidate: Timeline, comparedTo original: Timeline, plan: StoryPlan, analyses: [AnalysisResult]) -> [String] {
        let primaries = candidate.items.filter { $0.kind != .title && $0.overlay == nil }
        guard !primaries.isEmpty else { return ["Timeline не содержит primary clips"] }
        var issues: [String] = []
        let candidateByID = Dictionary(uniqueKeysWithValues: analyses.flatMap(\.directorCandidates).map { ($0.id, $0) })
        if primaries.contains(where: { $0.sourceDuration <= 0 || $0.timelineDuration <= 0 || !$0.sourceStart.isFinite }) {
            issues.append("Недопустимая длительность или source range")
        }
        for item in primaries {
            guard let id = item.candidateID, let source = candidateByID[id] else { continue }
            if item.sourceStart + 0.000_001 < source.sourceStart || item.sourceStart + item.sourceDuration > source.sourceStart + source.sourceDuration + 0.000_001 {
                issues.append("Source range вышел за границы кандидата")
                break
            }
        }
        let originalLocked = original.items.filter(\.locked)
        let candidateByItemID = Dictionary(uniqueKeysWithValues: candidate.items.map { ($0.id, $0) })
        if originalLocked.contains(where: { locked in
            guard let repaired = candidateByItemID[locked.id] else { return true }
            return repaired.candidateID != locked.candidateID
                || repaired.assetID != locked.assetID
                || abs(repaired.sourceStart - locked.sourceStart) > 0.000_001
                || abs(repaired.sourceDuration - locked.sourceDuration) > 0.000_001
                || repaired.speed != locked.speed
                || repaired.speedRamp != locked.speedRamp
        }) {
            issues.append("Repair удаляет или изменяет locked item")
        }
        let expectedStarts = TimelineTiming.retimed(candidate.items).map(\.timelineStart)
        if zip(candidate.items.map(\.timelineStart), expectedStarts).contains(where: { abs($0.0 - $0.1) > 0.001 }) {
            issues.append("Primary storyline содержит gap или неверный timing")
        }
        let originalRoles = Set(original.items.compactMap(\.storyRole))
        let repairedRoles = Set(primaries.compactMap(\.storyRole))
        if original.items.filter({ $0.kind != .title && $0.overlay == nil }).count >= 5,
           !Set([StoryRole.intro, .climax, .outro]).intersection(originalRoles).isSubset(of: repairedRoles) {
            issues.append("Repair разрушает существующий story arc")
        }
        let originalPrimaries = original.items.filter { $0.kind != .title && $0.overlay == nil }
        let explicitRoleAnchors: [(StoryRole, Set<String>)] = [
            (.intro, plan.constraints.preferredIntroTags ?? []),
            (.climax, plan.constraints.preferredClimaxTags ?? []),
            (.outro, plan.constraints.preferredOutroTags ?? [])
        ]
        for (role, requestedTags) in explicitRoleAnchors where !requestedTags.isEmpty {
            func satisfiesAnchor(_ item: TimelineItem) -> Bool {
                guard item.storyRole == role,
                      let candidateID = item.candidateID,
                      let source = candidateByID[candidateID] else { return false }
                return !requestedTags.isDisjoint(with: source.tags)
            }
            if originalPrimaries.contains(where: satisfiesAnchor),
               !primaries.contains(where: satisfiesAnchor) {
                issues.append("Repair нарушает явно заданный content anchor для роли «\(role.localizedTitle)»")
            }
        }
        if candidate.duration < min(3, original.duration * 0.5), plan.constraints.targetDuration >= 5 {
            issues.append("Repair чрезмерно сокращает фильм")
        }
        let titleReview = AutomatedTitlePolicy.reviewed(
            candidate.effectiveTitleItems,
            timelineDuration: candidate.duration,
            containmentByTitleID: AutomatedTitlePolicy.inferredContainmentByTitleID(
                candidate.effectiveTitleItems,
                timeline: candidate
            )
        )
        if titleReview.titles != candidate.effectiveTitleItems {
            issues.append("Repair нарушает provenance, containment или single-track размещение автотитров")
        }
        if plan.requiresExactDuration {
            let frame = 1 / max(1, candidate.frameRate)
            let target = plan.constraints.targetDuration
            if abs(original.duration - target) <= frame,
               abs(candidate.duration - target) > frame {
                issues.append("Repair нарушает явно заданную длительность")
            }
        }
        if let eventStory = plan.eventStory, eventStory.chronologicalByDefault {
            let originalEvent = eventSafety(original, eventStory: eventStory)
            let candidateEvent = eventSafety(candidate, eventStory: eventStory)
            if candidateEvent.order + 0.001 < originalEvent.order || candidateEvent.chronology + 0.001 < originalEvent.chronology {
                issues.append("Repair ухудшает порядок или хронологию событий")
            }
            if candidateEvent.coverage + 0.001 < originalEvent.coverage {
                issues.append("Repair удаляет покрытие события")
            }
            let plannedSceneIDs = Set(plan.chapters.compactMap(\.eventSceneID))
            let originalSceneIDs = Set(original.items.compactMap { item in
                item.overlay == nil && item.kind != .title ? item.eventSceneID : nil
            }).intersection(plannedSceneIDs)
            let candidateSceneIDs = Set(primaries.compactMap(\.eventSceneID))
            if !originalSceneIDs.isSubset(of: candidateSceneIDs) {
                issues.append("Repair удаляет подтверждённый scene block")
            }
        }
        return issues
    }

    private func eventSafety(_ timeline: Timeline, eventStory: EventStoryPlan) -> (order: Double, chronology: Double, coverage: Double) {
        var primaries = timeline.items.filter { $0.kind != .title && $0.overlay == nil }
        if let coldOpen = eventStory.coldOpenCandidateID, primaries.first?.candidateID == coldOpen { primaries.removeFirst() }
        let sequence = primaries.compactMap(\.eventID).reduce(into: [UUID]()) { result, id in
            if result.last != id { result.append(id) }
        }
        let expected = eventStory.entries.map(\.eventID)
        let expectedIndex = Dictionary(uniqueKeysWithValues: expected.enumerated().map { ($0.element, $0.offset) })
        let valid = sequence.filter { expectedIndex[$0] != nil }
        let inOrder = zip(valid, valid.dropFirst()).filter { pair in
            expectedIndex[pair.0, default: Int.max] <= expectedIndex[pair.1, default: Int.max]
        }.count
        let order = valid.count <= 1 ? (valid.isEmpty ? 0 : 1) : Double(inOrder) / Double(valid.count - 1)
        let dated = Dictionary(uniqueKeysWithValues: eventStory.entries.compactMap { entry in entry.startDate.map { (entry.eventID, $0) } })
        var inversions = 0
        var comparisons = 0
        for first in valid.indices {
            for second in valid.indices where second > first {
                guard let lhs = dated[valid[first]], let rhs = dated[valid[second]] else { continue }
                comparisons += 1
                if lhs > rhs { inversions += 1 }
            }
        }
        let chronology = comparisons == 0 ? order : 1 - Double(inversions) / Double(comparisons)
        let coverage = Double(Set(valid).count) / Double(max(1, expected.count))
        return (order.clamped01, chronology.clamped01, coverage.clamped01)
    }
}

public struct DirectedMontageVariant: Sendable {
    public var story: StoryPlanVariant
    public var timeline: Timeline
    public var score: MontageGlobalScore

    public init(story: StoryPlanVariant, timeline: Timeline, score: MontageGlobalScore) {
        self.story = story
        self.timeline = timeline
        self.score = score
    }
}

public struct MontagePairwiseDecision: Hashable, Sendable {
    public var firstPreferenceShare: Double
    public var preferredStrategy: String?
    public var reasons: [String]

    public init(firstPreferenceShare: Double, preferredStrategy: String?, reasons: [String]) {
        self.firstPreferenceShare = firstPreferenceShare.clamped01
        self.preferredStrategy = preferredStrategy
        self.reasons = reasons
    }
}

/// Relative comparison deliberately rewards winning many independent editorial
/// dimensions, not one unusually large absolute component. The final selector
/// combines this tournament utility with the calibrated absolute score.
public struct MontagePairwiseComparator: Sendable {
    public init() {}

    public func compare(
        firstStrategy: String,
        first: MontageGlobalScore,
        secondStrategy: String,
        second: MontageGlobalScore
    ) -> MontagePairwiseDecision {
        let components: [(String, Double, Double, Double)] = [
            ("highlight", first.highlightQuality, second.highlightQuality, 0.04),
            ("story arc", first.storyArc, second.storyArc, 0.13),
            ("asset diversity", first.diversity, second.diversity, 0.02),
            ("duration", first.durationFit, second.durationFit, 0.03),
            ("music", first.musicalAlignment, second.musicalAlignment, 0.025),
            ("self-review", first.reviewQuality, second.reviewQuality, 0.035),
            ("semantic diversity", first.semanticDiversity, second.semanticDiversity, 0.05),
            ("source diversity", first.sourceDiversity, second.sourceDiversity, 0.05),
            ("moment completeness", first.momentCompleteness, second.momentCompleteness, 0.12),
            ("energy curve", first.energyCurve, second.energyCurve, 0.055),
            ("audio continuity", first.audioContinuity, second.audioContinuity, 0.045),
            ("drop–climax", first.dropClimaxAlignment, second.dropClimaxAlignment, 0.035),
            ("continuity", first.continuity, second.continuity, 0.08),
            ("rhythm", first.rhythmQuality, second.rhythmQuality, 0.09),
            ("technical quality", first.technicalQuality, second.technicalQuality, 0.05),
            ("subject composition", first.subjectComposition, second.subjectComposition, 0.06),
            ("speech continuity", first.speechContinuity, second.speechContinuity, 0.055),
            ("audio events", first.audioEventCoherence, second.audioEventCoherence, 0.05),
            ("visual semantics", first.visualSemanticQuality, second.visualSemanticQuality, 0.055),
            ("music structure", first.musicStructureQuality, second.musicStructureQuality, 0.04),
            ("emotional curve", first.emotionalCurve, second.emotionalCurve, 0.12),
            ("pacing fit", first.pacingQuality, second.pacingQuality, 0.045),
            ("project style", first.projectStyleFit, second.projectStyleFit, 0.065),
            ("personal taste", first.personalTasteFit, second.personalTasteFit, 0.055),
            ("event order", first.eventOrder, second.eventOrder, 0.085),
            ("event diversity", first.eventDiversity, second.eventDiversity, 0.055),
            ("event coverage", first.eventCoverage, second.eventCoverage, 0.065),
            ("chronology", first.chronology, second.chronology, 0.09),
            ("scene diversity", first.sceneDiversity, second.sceneDiversity, 0.05),
            ("inter-event separation", first.interEventSeparation, second.interEventSeparation, 0.055)
        ]
        var firstPoints = 0.0
        var secondPoints = 0.0
        for component in components {
            let delta = component.1 - component.2
            if delta > 0.025 { firstPoints += component.3 }
            else if delta < -0.025 { secondPoints += component.3 }
            else {
                firstPoints += component.3 * 0.5
                secondPoints += component.3 * 0.5
            }
        }
        let share = firstPoints / max(0.000_001, firstPoints + secondPoints)
        let preferred = share > 0.53 ? firstStrategy : share < 0.47 ? secondStrategy : nil
        var reasons = components
            .map { (name: $0.0, delta: $0.1 - $0.2, impact: abs($0.1 - $0.2) * $0.3) }
            .filter { abs($0.delta) > 0.025 }
            .sorted { $0.impact > $1.impact }
            .prefix(4)
            .map { component in
                let owner = component.delta > 0 ? firstStrategy : secondStrategy
                return "\(owner) сильнее по \(component.name) на \(Int((abs(component.delta) * 100).rounded())) п.п."
            }
        if reasons.isEmpty {
            reasons = ["Различия по всем quality components находятся в пределах pairwise tolerance"]
        }
        return MontagePairwiseDecision(firstPreferenceShare: share, preferredStrategy: preferred, reasons: reasons)
    }
}

public struct MontageVariantSelector: Sendable {
    private let scorer: any MontageGlobalScoring

    public init(scorer: any MontageGlobalScoring = DefaultMontageGlobalScorer()) {
        self.scorer = scorer
    }

    public func select(
        stories: [StoryPlanVariant],
        timelines: [Timeline],
        assets: [MediaAsset],
        analyses: [AnalysisResult],
        searchDiagnostics: VariantSelectionDiagnostics? = nil,
        personalTasteProfile: PersonalTasteProfile? = nil,
        tasteContext: TasteContext? = nil,
        avoidingTimeline: Timeline? = nil
    ) -> DirectedMontageVariant? {
        let features = MontageScoringFeatures(assets: assets, analyses: analyses)
        let candidates = features.candidates
        var personalScores: [String: PersonalTasteScore] = [:]
        let variants = zip(stories, timelines).map { story, timeline in
            let baseScore: MontageGlobalScore
            if let defaultScorer = scorer as? DefaultMontageGlobalScorer {
                baseScore = defaultScorer.score(plan: story.plan, timeline: timeline, features: features, analyses: analyses)
            } else {
                baseScore = scorer.score(plan: story.plan, timeline: timeline, assets: assets, analyses: analyses)
            }
            let score: MontageGlobalScore
            if let personalTasteProfile, personalTasteProfile.totalSignalCount > 0 {
                let context = tasteContext ?? story.plan.autonomousDecision.map {
                    TasteContextResolver().resolve(projectStyle: $0.projectStyle, timeline: timeline, assets: assets, analyses: analyses)
                } ?? TasteContext()
                let personalized = PersonalizedMontageScorer().personalize(
                    base: baseScore, timeline: timeline, candidates: candidates,
                    profile: personalTasteProfile, context: context
                )
                score = personalized.0
                personalScores[story.strategy] = personalized.1
            } else {
                score = baseScore
            }
            return DirectedMontageVariant(story: story, timeline: timeline, score: score)
        }
        guard !variants.isEmpty else { return nil }
        let distanceCalculator = VariantDistanceCalculator()
        let requiredDistance = searchDiagnostics?.minimumRequiredDistance ?? 0.16
        let sorted = variants.sorted { $0.score.total > $1.score.total }
        var diverse: [DirectedMontageVariant] = []
        var rejectionRecords = searchDiagnostics?.rejectedVariants ?? []
        var finalRejectedAsSimilar = 0
        for variant in sorted {
            let nearest = diverse.map { existing in
                (existing, distanceCalculator.distance(between: variant.timeline, and: existing.timeline, candidates: candidates))
            }.min { $0.1.total < $1.1.total }
            if diverse.isEmpty || (nearest?.1.total ?? 1) + 0.000_001 >= requiredDistance {
                diverse.append(variant)
            } else {
                finalRejectedAsSimilar += 1
                rejectionRecords.append(VariantRejectionRecord(
                    strategy: variant.story.strategy,
                    stage: "directed diversity gate",
                    reason: "Полный production-вариант слишком похож на более сильный монтаж",
                    comparedToStrategy: nearest?.0.story.strategy,
                    distance: nearest?.1,
                    absoluteScore: variant.score.total
                ))
            }
        }
        let bestAbsolute = diverse.map(\.score.total).max() ?? 0
        var viable: [DirectedMontageVariant] = []
        for variant in diverse {
            var weakReasons: [String] = []
            if variant.score.total + 0.14 < bestAbsolute { weakReasons.append("absolute score отстаёт от лидера более чем на 14 п.п.") }
            if variant.score.technicalQuality < 0.30 { weakReasons.append("technical quality ниже 30%") }
            if variant.score.momentCompleteness < 0.25 { weakReasons.append("moment completeness ниже 25%") }
            if variant.score.storyArc < 0.30 { weakReasons.append("story arc ниже 30%") }
            if variant.score.reviewQuality < 0.35 { weakReasons.append("self-review quality ниже 35%") }
            if variant.story.plan.eventStory != nil, variant.score.chronology < 0.78 { weakReasons.append("event chronology ниже 78%") }
            if variant.story.plan.eventStory != nil, variant.score.eventCoverage < 0.60 { weakReasons.append("event coverage ниже 60%") }
            // Always retain the strongest absolute variant as a tournament
            // anchor; every other clearly weak alternative is removed.
            if viable.isEmpty || weakReasons.isEmpty {
                viable.append(variant)
            } else {
                rejectionRecords.append(VariantRejectionRecord(
                    strategy: variant.story.strategy,
                    stage: "weak variant gate",
                    reason: weakReasons.joined(separator: "; "),
                    absoluteScore: variant.score.total
                ))
            }
        }
        if viable.isEmpty, let first = diverse.first ?? sorted.first { viable = [first] }

        // Weighted score remains useful for calibration, but it cannot erase a
        // serious loss in story, continuity or taste with one oversized win.
        // Only non-dominated alternatives enter the pairwise tournament.
        let paretoFront = MontageParetoAnalyzer().front(viable)
        if !paretoFront.isEmpty, paretoFront.count < viable.count {
            let frontStrategies = Set(paretoFront.map { $0.story.strategy })
            for dominated in viable where !frontStrategies.contains(dominated.story.strategy) {
                rejectionRecords.append(VariantRejectionRecord(
                    strategy: dominated.story.strategy,
                    stage: "Pareto multi-objective gate",
                    reason: "Вариант доминируется по нескольким независимым целям story/style/taste/continuity",
                    absoluteScore: dominated.score.total
                ))
            }
            viable = paretoFront
        }

        // A user-requested fresh cut must not silently return the same edit
        // just because it still has the highest absolute score. Prefer a
        // production-safe alternative with a materially different selection,
        // order, source ranges or rhythm. If every viable cut is identical,
        // retain the quality winner instead of deliberately degrading it.
        var avoidedTimelineDistance: Double?
        if let avoidingTimeline, viable.count > 1 {
            let distances = viable.map { variant in
                (variant, distanceCalculator.distance(
                    between: variant.timeline,
                    and: avoidingTimeline,
                    candidates: candidates
                ))
            }
            let substantiallyDifferent = distances.filter { $0.1.total + 0.000_001 >= requiredDistance }
            if !substantiallyDifferent.isEmpty {
                let retainedStrategies = Set(substantiallyDifferent.map { $0.0.story.strategy })
                for (variant, distance) in distances where !retainedStrategies.contains(variant.story.strategy) {
                    rejectionRecords.append(VariantRejectionRecord(
                        strategy: variant.story.strategy,
                        stage: "fresh-cut diversity gate",
                        reason: "Вариант слишком похож на предыдущий монтаж для команды «Переделать заново»",
                        distance: distance,
                        absoluteScore: variant.score.total
                    ))
                }
                viable = substantiallyDifferent.map(\.0)
                avoidedTimelineDistance = substantiallyDifferent.map { $0.1.total }.min()
            } else if let farthest = distances.max(by: { $0.1.total < $1.1.total }), farthest.1.total > 0.01 {
                for (variant, distance) in distances where variant.story.strategy != farthest.0.story.strategy {
                    rejectionRecords.append(VariantRejectionRecord(
                        strategy: variant.story.strategy,
                        stage: "fresh-cut diversity gate",
                        reason: "Другой вариант меньше отличается от предыдущего монтажа",
                        comparedToStrategy: farthest.0.story.strategy,
                        distance: distance,
                        absoluteScore: variant.score.total
                    ))
                }
                viable = [farthest.0]
                avoidedTimelineDistance = farthest.1.total
            }
        }

        let comparator = MontagePairwiseComparator()
        var utilities: [String: Double] = [:]
        var opponents: [String: Int] = [:]
        var wins: [String: Int] = [:]
        var losses: [String: Int] = [:]
        var ties: [String: Int] = [:]
        var pairwiseResults: [VariantPairwiseResult] = []
        var pairDistances: [VariantPairDistance] = []
        if viable.count > 1 {
            for first in viable.indices {
                for second in viable.indices where second > first {
                    let lhs = viable[first]
                    let rhs = viable[second]
                    let distance = distanceCalculator.distance(between: lhs.timeline, and: rhs.timeline, candidates: candidates)
                    let decision = comparator.compare(firstStrategy: lhs.story.strategy, first: lhs.score, secondStrategy: rhs.story.strategy, second: rhs.score)
                    pairDistances.append(VariantPairDistance(firstStrategy: lhs.story.strategy, secondStrategy: rhs.story.strategy, metrics: distance))
                    pairwiseResults.append(VariantPairwiseResult(
                        firstStrategy: lhs.story.strategy,
                        secondStrategy: rhs.story.strategy,
                        firstPreferenceShare: decision.firstPreferenceShare,
                        preferredStrategy: decision.preferredStrategy,
                        distance: distance,
                        reasons: decision.reasons
                    ))
                    utilities[lhs.story.strategy, default: 0] += decision.firstPreferenceShare
                    utilities[rhs.story.strategy, default: 0] += 1 - decision.firstPreferenceShare
                    opponents[lhs.story.strategy, default: 0] += 1
                    opponents[rhs.story.strategy, default: 0] += 1
                    if decision.preferredStrategy == lhs.story.strategy {
                        wins[lhs.story.strategy, default: 0] += 1
                        losses[rhs.story.strategy, default: 0] += 1
                    } else if decision.preferredStrategy == rhs.story.strategy {
                        wins[rhs.story.strategy, default: 0] += 1
                        losses[lhs.story.strategy, default: 0] += 1
                    } else {
                        ties[lhs.story.strategy, default: 0] += 1
                        ties[rhs.story.strategy, default: 0] += 1
                    }
                }
            }
        }
        var tournamentScores: [String: Double] = [:]
        for variant in viable {
            let strategy = variant.story.strategy
            let pairwiseUtility = opponents[strategy, default: 0] == 0
                ? 0.5
                : utilities[strategy, default: 0] / Double(opponents[strategy, default: 0])
            tournamentScores[strategy] = pairwiseUtility * 0.68 + variant.score.total * 0.32
        }
        guard var winner = viable.max(by: {
            let left = tournamentScores[$0.story.strategy, default: 0]
            let right = tournamentScores[$1.story.strategy, default: 0]
            return left == right ? $0.score.total < $1.score.total : left < right
        }) else { return nil }

        let rejectionByStrategy = Dictionary(grouping: rejectionRecords, by: \.strategy)
        var evaluations = variants.map { variant -> VariantEvaluationRecord in
            let strategy = variant.story.strategy
            let pairwiseUtility = opponents[strategy, default: 0] == 0
                ? (viable.contains(where: { $0.story.strategy == strategy }) ? 0.5 : 0)
                : utilities[strategy, default: 0] / Double(opponents[strategy, default: 0])
            let rejection = rejectionByStrategy[strategy]?.last
            let disposition: VariantEvaluationDisposition
            if strategy == winner.story.strategy { disposition = .selected }
            else if let rejection, rejection.stage.contains("diversity") { disposition = .rejectedSimilar }
            else if rejection != nil { disposition = .rejectedWeak }
            else { disposition = .evaluated }
            var reasons = variant.score.strongestReasons
            if let rejection { reasons.append("Отклонён: \(rejection.reason)") }
            return VariantEvaluationRecord(
                strategy: strategy,
                score: variant.score,
                pairwiseUtility: pairwiseUtility,
                tournamentScore: tournamentScores[strategy, default: 0],
                wins: wins[strategy, default: 0],
                losses: losses[strategy, default: 0],
                ties: ties[strategy, default: 0],
                disposition: disposition,
                reasons: reasons
            )
        }
        evaluations.sort { $0.tournamentScore == $1.tournamentScore ? $0.score.total > $1.score.total : $0.tournamentScore > $1.tournamentScore }
        let totals = pairDistances.map(\.metrics.total)
        var diagnostics = searchDiagnostics ?? VariantSelectionDiagnostics(
            minimumRequiredDistance: requiredDistance,
            attemptedStrategyCount: variants.count,
            acceptedVariantCount: variants.count,
            rejectedAsTooSimilar: 0
        )
        diagnostics.evaluatedVariantCount = variants.count
        diagnostics.rejectedAsTooSimilar += finalRejectedAsSimilar
        diagnostics.pairDistances = pairDistances
        diagnostics.minimumDistance = totals.min()
        diagnostics.meanDistance = totals.isEmpty ? nil : totals.reduce(0, +) / Double(totals.count)
        diagnostics.winningStrategy = winner.story.strategy
        diagnostics.variantEvaluations = evaluations
        diagnostics.pairwiseResults = pairwiseResults
        diagnostics.rejectedVariants = rejectionRecords
        diagnostics.selectionReasons += [
            "Полный production pipeline и global scorer прошли \(variants.count) вариантов",
            "Pairwise tournament сравнил \(pairwiseResults.count) пар среди \(viable.count) сильных и различных вариантов",
            "Global score \(Int((winner.score.total * 100).rounded()))%, pairwise utility \(Int(((evaluations.first(where: { $0.strategy == winner.story.strategy })?.pairwiseUtility ?? 0.5) * 100).rounded()))%",
            "Автоматический победитель: \(winner.story.strategy)",
            "Сильные стороны: \(winner.score.strongestReasons.joined(separator: ", "))"
        ]
        diagnostics.selectionReasons.append("Pareto-front: \(viable.map { $0.story.strategy }.joined(separator: ", "))")
        if let avoidedTimelineDistance {
            diagnostics.selectionReasons.append(
                "Полная пересборка выбрала новую трактовку; дистанция от прошлого монтажа \(Int((avoidedTimelineDistance * 100).rounded()))%"
            )
        }
        if var run = winner.timeline.directorRun {
            run.evaluatedVariantCount = variants.count
            run.globalScore = winner.score.total
            run.variantDiagnostics = diagnostics
            run.paretoFrontStrategies = viable.map { $0.story.strategy }
            run.decisionReasons.append("Pairwise global tournament выбрал вариант \(winner.story.strategy) из \(variants.count) production-вариантов")
            run.decisionReasons.append(contentsOf: winner.score.strongestReasons)
            if let personalTasteProfile, personalTasteProfile.totalSignalCount > 0 {
                let resolvedContext = tasteContext ?? winner.story.plan.autonomousDecision.map {
                    TasteContextResolver().resolve(projectStyle: $0.projectStyle, timeline: winner.timeline, assets: assets, analyses: analyses)
                } ?? TasteContext()
                let exploration = winner.story.plan.autonomousDecision?.variantIntent == "autonomous-exploration"
                run.personalTasteDiagnostics = PersonalTasteDiagnostics(
                    contextKey: resolvedContext.key,
                    profileConfidence: personalTasteProfile.adaptiveConfidence,
                    signalCount: personalTasteProfile.totalSignalCount,
                    discoveredStyle: personalTasteProfile.discoveredStyle,
                    explorationApplied: exploration,
                    variantScores: personalScores,
                    reasons: [
                        "Personalized scoring evaluated \(personalScores.count) production variants",
                        "Winner personal fit \(Int(((personalScores[winner.story.strategy]?.personalTaste ?? 0.5) * 100).rounded()))%",
                        "Taste remained bounded by technical and perceptual quality floors"
                    ]
                )
                run.decisionReasons.append("Personal Taste участвовал в global + pairwise selection с confidence \(Int((personalTasteProfile.adaptiveConfidence * 100).rounded()))%")
            }
            winner.timeline.directorRun = run
        }
        return winner
    }
}
