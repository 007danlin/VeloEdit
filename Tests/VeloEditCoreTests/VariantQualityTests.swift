import Foundation
import Testing
@testable import VeloEditCore

private func qualityFixture() -> ([MediaAsset], [AnalysisResult], [Candidate]) {
    let themes: [(String, Double, Double, Double)] = [
        ("landscape", 0.22, 0.78, 0.30), ("people", 0.38, 0.86, 0.92),
        ("road", 0.55, 0.72, 0.42), ("action", 0.82, 0.80, 0.72),
        ("jump", 0.98, 0.94, 0.80), ("reaction", 0.42, 0.90, 0.96),
        ("water", 0.30, 0.76, 0.36), ("sunset", 0.18, 0.88, 0.34)
    ]
    let assets = themes.indices.map { index in
        MediaAsset(
            originalURL: URL(fileURLWithPath: "/tmp/p1-quality-\(index).mov"),
            kind: .video,
            byteSize: 100,
            contentHash: "p1-quality-\(index)",
            metadata: MediaMetadata(duration: 90, frameRate: 60, hasAudio: true, creationDate: Date(timeIntervalSince1970: 1_700_100_000 + Double(index * 30)))
        )
    }
    let candidates = assets.enumerated().flatMap { assetIndex, asset in
        (0..<2).map { part -> Candidate in
            let theme = themes[assetIndex]
            let start = Double(5 + part * 30)
            let peak = start + 2.2
            let boundary = MomentBoundary(
                anticipationStart: start,
                peakTime: peak,
                completionEnd: start + 5.8,
                confidence: 0.88,
                evidence: ["production fixture anticipation → peak → reaction"]
            )
            return Candidate(
                assetID: asset.id,
                sourceStart: start,
                sourceDuration: 5.8,
                scores: ClipScores(quality: 0.78 + Double(part) * 0.04, interest: theme.2 - Double(part) * 0.03, action: theme.1, stability: 0.82, uniqueness: 0.82),
                tags: [theme.0, assetIndex == 4 ? "climax" : "story"],
                explanation: ["P1 fixture \(theme.0)"],
                insights: CandidateInsights(
                    sceneSummary: "\(theme.0) distinct scene",
                    emotion: [1, 5, 7].contains(assetIndex) ? "joy" : nil,
                    dynamics: theme.1,
                    visualAppeal: theme.2,
                    composition: theme.2,
                    sharpness: 0.84,
                    shake: 0.10,
                    exposureQuality: 0.82,
                    originalAudioUsefulness: theme.3,
                    storyValue: theme.2,
                    roleScores: [
                        .intro: assetIndex == 0 ? 0.96 : 0.35,
                        .setup: assetIndex == 1 ? 0.92 : 0.40,
                        .buildup: assetIndex == 2 ? 0.90 : 0.45,
                        .climax: assetIndex == 4 ? 0.99 : theme.1,
                        .outro: assetIndex == 7 ? 0.98 : 0.34
                    ]
                ),
                momentBoundary: boundary
            )
        }
    }
    let analyses = assets.map { asset in
        let own = candidates.filter { $0.assetID == asset.id }
        return AnalysisResult(assetID: asset.id, analyzedContentHash: asset.contentHash, sceneTags: Set(own.flatMap(\.tags)), candidates: own)
    }
    return (assets, analyses, candidates)
}

private func timeline(_ candidates: [Candidate], order: [Int], durations: [Double]) -> Timeline {
    var cursor = 0.0
    let items = zip(order, durations).enumerated().map { position, pair -> TimelineItem in
        let candidate = candidates[pair.0]
        let item = TimelineItem(
            candidateID: candidate.id,
            assetID: candidate.assetID,
            kind: .video,
            sourceStart: candidate.sourceStart,
            sourceDuration: min(candidate.sourceDuration, pair.1),
            timelineStart: cursor,
            timelineDuration: min(candidate.sourceDuration, pair.1),
            storyRole: position == order.count - 2 ? .climax : .action
        )
        cursor += item.timelineDuration
        return item
    }
    return Timeline(storyPlanID: UUID(), items: items)
}

@Test func variantDistanceMeasuresSelectionSourceSemanticsOrderAndRhythm() {
    let (_, _, candidates) = qualityFixture()
    let first = timeline(candidates, order: [0, 2, 4, 8], durations: [2, 3, 4, 5.5])
    var shifted = candidates
    shifted[0].sourceStart += 20
    let second = timeline(shifted, order: [8, 6, 10, 0], durations: [5.5, 1.5, 2, 2])
    let byID = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0) })
    let distance = VariantDistanceCalculator().distance(between: first, and: second, candidates: byID)

    #expect(distance.candidateJaccardDistance > 0.45)
    #expect(distance.sourceRangeDistance > 0.45)
    #expect(distance.semanticDistance > 0.15)
    #expect(distance.orderDistance > 0.60)
    #expect(distance.rhythmDistance > 0.10)
    #expect(distance.total > 0.35)
}

@Test func storySearchKeepsOnlySubstantiallyDifferentCompleteCuts() {
    let (assets, analyses, _) = qualityFixture()
    let constraints = StoryConstraints(targetDuration: 24, targetClipCount: 4, pacing: 0.72)
    let search = StoryEngine().createPlanVariantSearch(
        prompt: "Разная динамичная история с людьми, прыжком и реакцией",
        preset: .story,
        constraints: constraints,
        assets: assets,
        analyses: analyses
    )

    #expect(search.variants.count >= 2)
    #expect(search.variants.count <= 10)
    #expect(search.diagnostics.attemptedStrategyCount >= search.variants.count)
    #expect(search.diagnostics.pairDistances.allSatisfy { $0.metrics.total + 0.000_001 >= search.diagnostics.minimumRequiredDistance })
    #expect(search.variants.allSatisfy { !$0.plan.chapters.flatMap(\.candidateIDs).isEmpty })
}

@Test func pairwiseComparatorPrefersBroadEditorialStrengthOverOneSpikyAbsoluteScore() {
    let spiky = MontageGlobalScore(
        total: 0.78, highlightQuality: 1, storyArc: 0.4, diversity: 0.4,
        durationFit: 1, musicalAlignment: 0.4, reviewQuality: 0.4,
        semanticDiversity: 0.4, sourceDiversity: 0.4, momentCompleteness: 0.4,
        energyCurve: 0.4, audioContinuity: 0.4, dropClimaxAlignment: 0.4,
        continuity: 0.4, rhythmQuality: 0.4, technicalQuality: 0.4
    )
    let balanced = MontageGlobalScore(
        total: 0.72, highlightQuality: 0.72, storyArc: 0.72, diversity: 0.72,
        durationFit: 0.72, musicalAlignment: 0.72, reviewQuality: 0.72,
        semanticDiversity: 0.72, sourceDiversity: 0.72, momentCompleteness: 0.72,
        energyCurve: 0.72, audioContinuity: 0.72, dropClimaxAlignment: 0.72,
        continuity: 0.72, rhythmQuality: 0.72, technicalQuality: 0.72
    )
    let decision = MontagePairwiseComparator().compare(
        firstStrategy: "spiky",
        first: spiky,
        secondStrategy: "balanced",
        second: balanced
    )

    #expect(decision.preferredStrategy == "balanced")
    #expect(decision.firstPreferenceShare < 0.35)
    #expect(decision.reasons.contains(where: { $0.contains("balanced") }))
}

@Test func storySelectionUsesSceneEnrichedDirectorCandidates() throws {
    let asset = MediaAsset(originalURL: URL(fileURLWithPath: "/tmp/enriched.mov"), kind: .video, byteSize: 1, contentHash: "enriched", metadata: MediaMetadata(duration: 30))
    let rawLeader = Candidate(assetID: asset.id, sourceStart: 0, sourceDuration: 5, scores: ClipScores(quality: 0.8, interest: 0.82, action: 0.3, stability: 0.8), tags: ["ordinary"])
    let sceneLeader = Candidate(assetID: asset.id, sourceStart: 10, sourceDuration: 5, scores: ClipScores(quality: 0.5, interest: 0.20, action: 0.2, stability: 0.6), tags: ["ordinary"])
    let scenes = [
        SceneAnalysis(startTime: 0, endTime: 5, semanticDescription: "flat", qualityScore: 0.3, actionScore: 0.1, beautyScore: 0.1, stabilityScore: 0.4),
        SceneAnalysis(startTime: 10, endTime: 15, semanticDescription: "decisive reaction", qualityScore: 0.95, actionScore: 1, beautyScore: 1, stabilityScore: 0.95, people: ["people"], recommendedUses: ["climax"])
    ]
    let analysis = AnalysisResult(assetID: asset.id, analyzedContentHash: asset.contentHash, candidates: [rawLeader, sceneLeader], scenes: scenes)
    let constraints = StoryConstraints(targetDuration: 5, targetClipCount: 1, pacing: 0.7)
    let plan = StoryEngine().createPlan(prompt: "Лучший момент", preset: .highlight, constraints: constraints, assets: [asset], analyses: [analysis])

    #expect(try #require(plan.chapters.first?.candidateIDs.first) == sceneLeader.id)
}

@Test func phaseAwareTrimKeepsAnticipationPeakAndReactionHandles() {
    let assetID = UUID()
    let boundary = MomentBoundary(anticipationStart: 10, peakTime: 12, completionEnd: 16, confidence: 0.9)
    let candidate = Candidate(assetID: assetID, sourceStart: 10, sourceDuration: 6, scores: ClipScores(quality: 0.8, interest: 0.8, action: 0.9, stability: 0.8), momentBoundary: boundary)
    let range = MomentPhaseTrimmer().range(for: candidate, desiredDuration: 2.4)

    #expect(range.sourceStart < boundary.peakTime)
    #expect(range.sourceStart + range.sourceDuration > boundary.peakTime)
    #expect(boundary.peakTime - range.sourceStart >= 0.22)
    #expect(range.sourceStart + range.sourceDuration - boundary.peakTime >= 0.30)
}

@Test func transactionalRepairCannotTradeAwayLockedEditorialSafety() {
    let (assets, analyses, candidates) = qualityFixture()
    let plan = StoryPlan(prompt: "Сохранить выбранный кадр", preset: .story, constraints: StoryConstraints(targetDuration: 10, targetClipCount: 2), chapters: [])
    let lockedCandidate = candidates[0]
    let secondCandidate = candidates[8]
    let locked = TimelineItem(candidateID: lockedCandidate.id, assetID: lockedCandidate.assetID, kind: .video, sourceStart: lockedCandidate.sourceStart, sourceDuration: 5, timelineStart: 0, timelineDuration: 5, storyRole: .intro, locked: true)
    let second = TimelineItem(candidateID: secondCandidate.id, assetID: secondCandidate.assetID, kind: .video, sourceStart: secondCandidate.sourceStart, sourceDuration: 5, timelineStart: 5, timelineDuration: 5, storyRole: .climax)
    let original = Timeline(storyPlanID: plan.id, items: [locked, second])
    var unsafe = original
    unsafe.items = [second]
    unsafe.items[0].timelineStart = 0
    let review = TimelineSelfReviewer().review(original, plan: plan, analyses: analyses)
    let result = TimelineReviewTransaction().commitIfImproved(original: original, candidate: unsafe, currentReview: review, plan: plan, analyses: analyses, assets: assets)

    #expect(!result.committed)
    #expect(result.timeline == original)
    #expect(result.safetyViolations.contains(where: { $0.contains("locked") }))
}

@Test func expandedGlobalScorerPrefersCompleteDiverseArcOverPlausibleFlatCut() {
    let (assets, analyses, candidates) = qualityFixture()
    let constraints = StoryConstraints(targetDuration: 20, targetClipCount: 5, pacing: 0.7)
    let plan = StoryPlan(prompt: "История с кульминацией", preset: .story, constraints: constraints, chapters: [])
    var structure = MusicSyncEngine().analyze(bpm: 120, duration: 20, energy: 0.8)
    structure.drops = [14]
    structure.accents = [MusicAccent(time: 14, strength: 1, kind: .drop)]
    let music = MusicDirective(style: .cinematic, bpm: 120, structure: structure)

    let goodIndices = [0, 2, 4, 8, 14]
    let goodRoles: [StoryRole] = [.intro, .setup, .buildup, .climax, .outro]
    var cursor = 0.0
    let goodItems = zip(goodIndices, goodRoles).map { index, role -> TimelineItem in
        let candidate = candidates[index]
        let range = MomentPhaseTrimmer().range(for: candidate, desiredDuration: 4)
        let item = TimelineItem(candidateID: candidate.id, assetID: candidate.assetID, kind: .video, sourceStart: range.sourceStart, sourceDuration: range.sourceDuration, timelineStart: cursor, timelineDuration: range.sourceDuration, audioAdjustments: AudioAdjustments(volume: (candidate.insights?.originalAudioUsefulness ?? 0) >= 0.65 ? 0.9 : 0.36), storyRole: role)
        cursor += item.timelineDuration
        return item
    }
    let good = Timeline(storyPlanID: plan.id, items: goodItems, music: music)

    cursor = 0
    let flatCandidates = Array(candidates[6...10])
    let flatItems = flatCandidates.enumerated().map { position, candidate -> TimelineItem in
        let sourceStart = (candidate.momentBoundary?.peakTime ?? candidate.sourceStart) + 0.1
        let duration = min(3.5, candidate.sourceStart + candidate.sourceDuration - sourceStart)
        let item = TimelineItem(candidateID: candidate.id, assetID: candidate.assetID, kind: .video, sourceStart: sourceStart, sourceDuration: duration, timelineStart: cursor, timelineDuration: duration, audioAdjustments: AudioAdjustments(volume: 1), storyRole: position == 0 ? .climax : .action)
        cursor += duration
        return item
    }
    let flat = Timeline(storyPlanID: plan.id, items: flatItems, music: music)
    let scorer = DefaultMontageGlobalScorer()
    let goodScore = scorer.score(plan: plan, timeline: good, assets: assets, analyses: analyses)
    let flatScore = scorer.score(plan: plan, timeline: flat, assets: assets, analyses: analyses)

    #expect(goodScore.total > flatScore.total + 0.05)
    #expect(goodScore.storyArc > flatScore.storyArc)
    #expect(goodScore.momentCompleteness >= flatScore.momentCompleteness)
    #expect(goodScore.dropClimaxAlignment > flatScore.dropClimaxAlignment)
}
