import Foundation
import Testing
@testable import VeloEditCore

private func professionalAsset(_ index: Int, hasAudio: Bool = true) -> MediaAsset {
    MediaAsset(
        originalURL: URL(fileURLWithPath: "/tmp/professional-editing-\(index).mov"),
        kind: .video,
        byteSize: 1,
        contentHash: "professional-editing-\(index)",
        metadata: MediaMetadata(duration: 14, width: 1920, height: 1080, frameRate: 30, hasAudio: hasAudio)
    )
}

private func professionalTracking(area: Double = 0.12, centerX: Double = 0.46) -> SubjectTrackingSummary {
    let id = UUID()
    let width = sqrt(area)
    let region = NormalizedRegion(x: centerX - width / 2, y: 0.32, width: width, height: width)
    let track = SubjectTrack(
        id: id,
        kind: .person,
        label: "hero",
        observations: [
            SubjectTrackObservation(timestamp: 0, region: region, confidence: 0.92),
            SubjectTrackObservation(timestamp: 4, region: region, confidence: 0.92),
        ],
        meanConfidence: 0.92,
        visibility: 0.90,
        compositionQuality: 0.84
    )
    return SubjectTrackingSummary(tracks: [track], mainSubjectID: id, confidence: 0.92, analyzedFrameCount: 2)
}

private func professionalCandidate(
    asset: MediaAsset,
    start: Double,
    role: StoryRole,
    dynamics: Double = 0.52,
    speech: SpeechEditingEvidence? = nil,
    semanticEventID: String? = nil,
    tracking: SubjectTrackingSummary? = nil
) -> Candidate {
    Candidate(
        assetID: asset.id,
        sourceStart: start,
        sourceDuration: 4,
        scores: ClipScores(quality: 0.84, interest: 0.82, action: dynamics, stability: 0.86, uniqueness: 0.78),
        tags: ["hero", "shared-scene"],
        explanation: ["professional editing fixture"],
        insights: CandidateInsights(
            sceneSummary: "hero continues the same scene",
            emotion: role == .reaction ? "relief" : nil,
            dynamics: dynamics,
            visualAppeal: 0.84,
            composition: 0.84,
            sharpness: 0.86,
            exposureQuality: 0.86,
            originalAudioUsefulness: speech == nil ? 0.42 : 0.88,
            storyValue: 0.82,
            roleScores: [role: 0.94],
            semanticEventID: semanticEventID,
            subjectTracking: tracking,
            speech: speech,
            audioQuality: 0.86
        )
    )
}

@Test func oldMomentBoundaryJSONDecodesAndNewPhaseContractProtectsPeak() throws {
    let legacy = #"{"anticipationStart":1,"peakTime":2.5,"completionEnd":5,"confidence":0.8,"evidence":["legacy"]}"#
    let decoded = try JSONDecoder().decode(MomentBoundary.self, from: Data(legacy.utf8))
    #expect(decoded.actionStart == nil)
    #expect(decoded.reactionEnd == nil)

    let signals = [
        MomentSignal(timestamp: 0.8, motion: 0.12, interest: 0.30, semantic: 0.32),
        MomentSignal(timestamp: 1.5, motion: 0.55, interest: 0.58, semantic: 0.54),
        MomentSignal(timestamp: 2.2, motion: 0.96, interest: 0.90, semantic: 0.86, audioOnset: 0.88, audioEvent: 0.92, actionConfirmation: 0.94),
        MomentSignal(timestamp: 2.8, motion: 0.70, interest: 0.72, semantic: 0.68),
        MomentSignal(timestamp: 3.7, motion: 0.18, interest: 0.42, semantic: 0.46),
    ]
    let refined = MomentBoundaryRefiner().refine(around: 2.1, signals: signals, sourceDuration: 8, nominalDuration: 4)
    #expect(refined.actionStart != nil)
    #expect(refined.actionEnd != nil)
    #expect(refined.reactionStart != nil)
    #expect(refined.reactionEnd != nil)
    #expect(refined.doNotCutRanges?.isEmpty == false)
    #expect(refined.phase(at: refined.effectiveReactionEnd) == .reaction)
    #expect(refined.containsProtectedCut(refined.peakTime))
}

@Test func storyPlanPersistsReactionBeatAndCoveragePurpose() {
    let chapters = [
        StoryChapter(title: "Контекст", candidateIDs: [], role: .setup),
        StoryChapter(title: "Пик", candidateIDs: [], role: .climax),
        StoryChapter(
            title: "Реакция",
            candidateIDs: [],
            role: .reaction,
            coveragePlan: SceneCoveragePlan(
                requirements: [SceneCoverageRequirement(purpose: .reaction, priority: 0.95, prefersOriginalAudio: true, explanation: "Сохранить последствия")],
                explanation: "Reaction coverage"
            )
        ),
    ]
    let plan = StoryPlan(prompt: "История", preset: .story, constraints: StoryConstraints(), chapters: chapters)
    #expect(EventScenePhase.reaction.storyRole == .reaction)
    #expect(plan.beatGraph?.beats.map(\.kind) == [.question, .payoff, .reaction])
    #expect(plan.beatGraph?.beats[1].dependsOn == [plan.beatGraph!.beats[0].id])
    #expect(chapters.last?.coveragePlan?.requirements.first?.purpose == .reaction)
}

@Test func composerUsesCleanCutsUnlessBoundaryHasAReason() {
    let assets = (0..<3).map { professionalAsset($0, hasAudio: false) }
    let candidates = [
        professionalCandidate(asset: assets[0], start: 0, role: .setup, dynamics: 0.42),
        professionalCandidate(asset: assets[1], start: 0, role: .buildup, dynamics: 0.52),
        professionalCandidate(asset: assets[2], start: 0, role: .action, dynamics: 0.62),
    ]
    let analyses = zip(assets, candidates).map { asset, candidate in
        AnalysisResult(assetID: asset.id, analyzedContentHash: asset.contentHash, candidates: [candidate])
    }
    let chapters = zip(candidates, [StoryRole.setup, .buildup, .action]).map { candidate, role in
        StoryChapter(title: role.localizedTitle, candidateIDs: [candidate.id], role: role)
    }
    let plan = StoryPlan(
        prompt: "Чистая история без музыки",
        preset: .story,
        constraints: StoryConstraints(targetDuration: 20, transitionFrequency: 1, pacing: 0.65),
        chapters: chapters
    )
    let timeline = TimelineComposer().compose(plan: plan, assets: assets, analyses: analyses)
    let primaries = timeline.items.filter { $0.kind != .title && $0.overlay == nil }
    #expect(primaries.dropFirst().allSatisfy { $0.transition == nil })
    #expect(primaries.dropFirst().allSatisfy { $0.incomingEditDecision?.choice == .cut })
}

@Test func composerBuildsEditableJLCutForUsefulDialogue() {
    let firstAsset = professionalAsset(10)
    let dialogueAsset = professionalAsset(11)
    let first = professionalCandidate(asset: firstAsset, start: 0, role: .setup, dynamics: 0.40)
    let speech = SpeechEditingEvidence(
        text: "Мы наконец добрались к тихому горному озеру!",
        phraseStart: 1.5,
        phraseEnd: 6.3,
        confidence: 0.92,
        startsAtPhraseBoundary: true,
        endsAtPhraseBoundary: true,
        silenceBefore: 0.35,
        silenceAfter: 0.24
    )
    let dialogue = professionalCandidate(asset: dialogueAsset, start: 2, role: .reaction, dynamics: 0.34, speech: speech)
    let analyses = [
        AnalysisResult(assetID: firstAsset.id, analyzedContentHash: firstAsset.contentHash, candidates: [first]),
        AnalysisResult(assetID: dialogueAsset.id, analyzedContentHash: dialogueAsset.contentHash, candidates: [dialogue]),
    ]
    let plan = StoryPlan(
        prompt: "История без музыки и без переходов",
        preset: .story,
        constraints: StoryConstraints(targetDuration: 12),
        chapters: [
            StoryChapter(title: "Контекст", candidateIDs: [first.id], role: .setup),
            StoryChapter(title: "Реакция", candidateIDs: [dialogue.id], role: .reaction),
        ]
    )
    let timeline = TimelineComposer().compose(plan: plan, assets: [firstAsset, dialogueAsset], analyses: analyses)
    let dialogueItem = timeline.items.first { $0.candidateID == dialogue.id }
    let bridge = timeline.effectiveAudioClips.first { $0.attachedToItemID == dialogueItem?.id }
    #expect(bridge?.role == .dialogue)
    #expect((bridge?.timelineStart ?? 99) < (dialogueItem?.timelineStart ?? 0))
    #expect(dialogueItem?.effectiveAudioAdjustments.muted == true)
    #expect(timeline.audioDucking?.enabled == true)
}

@Test func composerKeepsUsefulContainedDialogueSynchronous() {
    let asset = professionalAsset(12)
    let speech = SpeechEditingEvidence(
        text: "Мы наконец добрались",
        phraseStart: 2.1,
        phraseEnd: 5.7,
        confidence: 0.94,
        startsAtPhraseBoundary: true,
        endsAtPhraseBoundary: true,
        silenceBefore: 0.3,
        silenceAfter: 0.3
    )
    let dialogue = professionalCandidate(asset: asset, start: 2, role: .reaction, dynamics: 0.34, speech: speech)
    let plan = StoryPlan(
        prompt: "История без музыки и без переходов",
        preset: .story,
        constraints: StoryConstraints(targetDuration: 4),
        chapters: [StoryChapter(title: "Реакция", candidateIDs: [dialogue.id], role: .reaction)]
    )

    let timeline = TimelineComposer().compose(
        plan: plan,
        assets: [asset],
        analyses: [AnalysisResult(assetID: asset.id, analyzedContentHash: asset.contentHash, candidates: [dialogue])]
    )

    #expect(timeline.effectiveAudioClips.allSatisfy { $0.attachedToItemID == nil })
    #expect(timeline.items.first?.effectiveAudioAdjustments.muted == false)
}

@Test func perceptualReviewFlagsUnnecessaryCutAndJumpCutRisk() {
    let firstAsset = professionalAsset(20)
    let secondAsset = professionalAsset(21)
    let tracking = professionalTracking()
    let first = professionalCandidate(asset: firstAsset, start: 0, role: .action, dynamics: 0.62, semanticEventID: "same-moment", tracking: tracking)
    let second = professionalCandidate(asset: secondAsset, start: 0, role: .action, dynamics: 0.64, semanticEventID: "same-moment", tracking: tracking)
    let firstItem = TimelineItem(candidateID: first.id, assetID: first.assetID, kind: .video, sourceDuration: 4, timelineStart: 0, timelineDuration: 4, storyRole: .action)
    let secondItem = TimelineItem(
        candidateID: second.id,
        assetID: second.assetID,
        kind: .video,
        sourceDuration: 4,
        timelineStart: 4,
        timelineDuration: 4,
        storyRole: .action,
        incomingEditDecision: EditorialBoundaryDecision(choice: .cut, motivation: "test cut", confidence: 0.8)
    )
    let timeline = Timeline(storyPlanID: UUID(), items: [firstItem, secondItem])
    let analyses = [
        AnalysisResult(assetID: firstAsset.id, analyzedContentHash: firstAsset.contentHash, candidates: [first]),
        AnalysisResult(assetID: secondAsset.id, analyzedContentHash: secondAsset.contentHash, candidates: [second]),
    ]
    let plan = StoryPlan(prompt: "Монтаж", preset: .story, constraints: StoryConstraints(targetDuration: 8), chapters: [])
    let review = PerceptualMontageReviewer().review(
        timeline: timeline,
        plan: plan,
        features: MontageScoringFeatures(assets: [firstAsset, secondAsset], analyses: analyses)
    )
    #expect(review.findings.contains { $0.type == .unnecessaryCut })
    #expect(review.findings.contains { $0.type == .jumpCutRisk })
}
