import Foundation
import Testing
@testable import VeloEditCore

private func p3Fixture(count: Int = 14, energetic: Bool = true) -> ([MediaAsset], [AnalysisResult]) {
    let assets = (0..<3).map { index in
        MediaAsset(
            originalURL: URL(fileURLWithPath: "/tmp/p3-\(index).mov"),
            kind: .video,
            byteSize: 100,
            contentHash: "p3-\(index)",
            metadata: MediaMetadata(duration: 180, frameRate: index == 0 ? 60 : 30, hasAudio: true)
        )
    }
    let tags = ["people", "mountain", "bicycle", "sunset", "water", "forest", "city", "reaction", "journey", "landscape", "vehicle", "discovery", "friends", "atmosphere"]
    var grouped: [UUID: [Candidate]] = [:]
    for index in 0..<count {
        let asset = assets[index % assets.count]
        let action = energetic ? 0.58 + Double(index % 5) * 0.085 : 0.12 + Double(index % 4) * 0.055
        let people = index.isMultiple(of: 4)
        let quality = 0.66 + Double(index % 4) * 0.07
        let start = Double(index * 9)
        let candidate = Candidate(
            assetID: asset.id,
            sourceStart: start,
            sourceDuration: 6.5,
            scores: ClipScores(quality: quality, interest: 0.64 + Double(index % 6) * 0.055, action: action, stability: 0.72 + Double(index % 3) * 0.07, uniqueness: 0.72 + Double(index % 5) * 0.05),
            tags: Set([tags[index % tags.count], energetic ? "action" : "scenic"] + (people ? ["people"] : [])),
            explanation: ["P3 fixture moment \(index)"],
            insights: CandidateInsights(
                sceneSummary: "\(tags[index % tags.count]) event \(index)",
                emotion: people ? (index.isMultiple(of: 2) ? "joy" : "anticipation") : nil,
                dynamics: action,
                visualAppeal: quality,
                composition: energetic ? 0.68 + Double(index % 3) * 0.08 : 0.84,
                sharpness: quality,
                exposureQuality: 0.82,
                slowMotionSuitability: action,
                speedRampSuitability: action,
                originalAudioUsefulness: people ? 0.82 : 0.48,
                storyValue: 0.66 + Double(index % 5) * 0.06,
                roleScores: [
                    .intro: index < 3 ? 0.88 : 0.42,
                    .action: action,
                    .climax: index == count - 3 ? 0.98 : action,
                    .outro: index >= count - 2 ? 0.92 : 0.38
                ],
                semanticEventID: "event-\(index)",
                bestTakeScore: quality,
                audioQuality: 0.78
            ),
            momentBoundary: MomentBoundary(
                anticipationStart: start,
                peakTime: start + 2.6,
                completionEnd: start + 6.2,
                confidence: 0.84
            )
        )
        grouped[asset.id, default: []].append(candidate)
    }
    let analyses = assets.map { asset in
        AnalysisResult(
            assetID: asset.id,
            schemaVersion: 4,
            analyzedContentHash: asset.contentHash,
            sceneTags: Set(grouped[asset.id, default: []].flatMap(\.tags)),
            candidates: grouped[asset.id, default: []],
            completedDepth: .deep,
            deepMediaVersion: 2
        )
    }
    return (assets, analyses)
}

@Test func autonomousStyleInferenceUsesProjectEvidenceInsteadOfPresetLabel() {
    let (actionAssets, actionAnalyses) = p3Fixture(energetic: true)
    let (calmAssets, calmAnalyses) = p3Fixture(energetic: false)
    let engine = AutonomousProjectStyleEngine()
    let action = engine.infer(assets: actionAssets, analyses: actionAnalyses, fallbackPreset: .memories)
    let calm = engine.infer(assets: calmAssets, analyses: calmAnalyses, fallbackPreset: .highlight)

    #expect(action.vector.action > calm.vector.action + 0.30)
    #expect(action.vector.pacing > calm.vector.pacing + 0.18)
    #expect(calm.vector.cinematic > 0.60)
    #expect(action.confidence > 0.60)
    #expect(action.internalLabel != "NEUTRAL_LOW_CONFIDENCE")
}

@Test func autonomousDurationDoesNotPadWeakOrSparseMaterialToTheRequestedNumber() {
    let (assets, analyses) = p3Fixture(count: 3, energetic: false)
    let project = AutonomousProjectStyleEngine().infer(assets: assets, analyses: analyses, fallbackPreset: .story)
    let decision = AutonomousDurationOptimizer().decide(
        project: project,
        style: project.vector,
        analyses: analyses,
        requestedDuration: 90,
        requestIsExplicit: false
    )

    #expect(decision.seconds < 35)
    #expect(decision.safeRange.upperBound < 45)
    #expect(decision.reasons.contains { $0.contains("без искусственного") || $0.contains("повторами") })
}

@Test func explicitDurationIsExactWhenCandidateMaterialCanCoverIt() {
    let (assets, analyses) = p3Fixture(count: 18, energetic: true)
    let project = AutonomousProjectStyleEngine().infer(assets: assets, analyses: analyses, fallbackPreset: .story)
    let decision = AutonomousDurationOptimizer().decide(
        project: project,
        style: project.vector,
        analyses: analyses,
        requestedDuration: 60,
        requestIsExplicit: true
    )

    #expect(decision.seconds == 60)
    #expect(decision.safeRange == 60...60)
    #expect(decision.reasons.contains { $0.contains("явно заданная длительность") })
}

@Test func abbreviatedQuestionnaireDurationIsStillAHardConstraint() {
    #expect(AutonomousDurationOptimizer.requestContainsExplicitDuration("Какой должна быть длительность? 5 мин."))
    #expect(AutonomousDurationOptimizer.requestContainsExplicitDuration("Ролик 45 сек."))
    let (assets, analyses) = p3Fixture(count: 6, energetic: true)
    let decision = AutonomousDirectorEngine().decide(
        prompt: "Какой должна быть длительность? 5 мин.",
        fallbackPreset: .story,
        requestedDuration: nil,
        assets: assets,
        analyses: analyses,
        personalProfile: PersonalTasteProfile()
    )
    #expect(decision.duration.safeRange == 300...300)
}

@Test func typedQuestionnaireDurationIsHardWithoutRepeatingItInPrompt() {
    let (assets, analyses) = p3Fixture(count: 6, energetic: true)
    let decision = AutonomousDirectorEngine().decide(
        prompt: "Собери историю о поездке",
        fallbackPreset: .story,
        requestedDuration: 60,
        assets: assets,
        analyses: analyses,
        personalProfile: PersonalTasteProfile(),
        requestIsExplicit: true
    )

    #expect(decision.duration.safeRange == 60...60)
    #expect(decision.duration.seconds == 60)
}

@Test func explicitDurationStillShortensWhenCandidateMaterialCannotCoverIt() {
    let (assets, analyses) = p3Fixture(count: 3, energetic: false)
    let project = AutonomousProjectStyleEngine().infer(assets: assets, analyses: analyses, fallbackPreset: .story)
    let decision = AutonomousDurationOptimizer().decide(
        project: project,
        style: project.vector,
        analyses: analyses,
        requestedDuration: 90,
        requestIsExplicit: true
    )

    #expect(decision.seconds < 35)
    #expect(decision.reasons.contains { $0.contains("материала недостаточно") })
}

@Test func fullDirectorPathKeepsExplicitDurationWhenMaterialIsSufficient() {
    let (assets, analyses) = p3Fixture(count: 18, energetic: true)
    let prompt = "Сделай динамичный фильм ровно на 60 секунд. Без музыки."
    let autonomous = AutonomousDirectorEngine().decide(
        prompt: prompt,
        fallbackPreset: .adventure,
        requestedDuration: 60,
        assets: assets,
        analyses: analyses,
        personalProfile: PersonalTasteProfile()
    )
    var constraints = PromptInterpreter().interpret(prompt: prompt, preset: .adventure)
    constraints.targetDuration = autonomous.duration.seconds
    constraints.pacing = autonomous.finalStyle.pacing
    constraints.transitionFrequency = autonomous.grammar.transitionDensity
    constraints.allowSlowMotion = autonomous.grammar.slowMotionDensity > 0.025
    let plan = StoryEngine().createPlan(
        prompt: prompt,
        preset: .adventure,
        constraints: constraints,
        assets: assets,
        analyses: analyses,
        autonomousDecision: autonomous
    )
    let rough = TimelineComposer().compose(plan: plan, assets: assets, analyses: analyses)
    let timeline = AIDirectorEngine().direct(
        plan: plan,
        initialTimeline: rough,
        assets: assets,
        analyses: analyses
    )

    #expect(abs(timeline.duration - 60) <= 1 / timeline.frameRate)
    #expect(timeline.items.allSatisfy { $0.transition == nil })
    #expect(timeline.effectiveTransitionItems.isEmpty)
}

@Test func fiveMinuteBriefExtendsLongCameraTakesWithoutReusingSourceRanges() {
    let (assets, analyses) = p3Fixture(count: 18, energetic: true)
    let prompt = "Сделай киношный фильм ровно на 5 минут. Звук исходников приглушить."
    let autonomous = AutonomousDirectorEngine().decide(
        prompt: prompt,
        fallbackPreset: .cinematic,
        requestedDuration: 300,
        assets: assets,
        analyses: analyses,
        personalProfile: PersonalTasteProfile()
    )
    var constraints = PromptInterpreter().interpret(prompt: prompt, preset: .cinematic)
    constraints.targetDuration = autonomous.duration.seconds
    constraints.pacing = autonomous.finalStyle.pacing
    let plan = StoryEngine().createPlan(
        prompt: prompt,
        preset: .cinematic,
        constraints: constraints,
        assets: assets,
        analyses: analyses,
        autonomousDecision: autonomous
    )
    let timeline = TimelineComposer().compose(plan: plan, assets: assets, analyses: analyses)

    #expect(autonomous.duration.safeRange == 300...300)
    #expect(abs(timeline.duration - 300) <= 1 / timeline.frameRate)
    #expect(timeline.effectiveOriginalAudioVolume == 0.30)
    #expect(timeline.items.contains { $0.sourceDuration > 6.5 })
    for asset in assets {
        let ranges = timeline.items.filter { $0.assetID == asset.id }.sorted { $0.sourceStart < $1.sourceStart }
        for pair in zip(ranges, ranges.dropFirst()) {
            #expect(pair.0.sourceStart + pair.0.sourceDuration <= pair.1.sourceStart + 0.001)
        }
    }
}

@Test func typedFiveMinuteBriefRedistributesEventCapacityAndSurvivesDirectorReview() {
    let sourceDurations = [100.0, 260.0]
    let assets = sourceDurations.enumerated().map { index, duration in
        MediaAsset(
            originalURL: URL(fileURLWithPath: "/tmp/typed-five-minute-\(index).mov"),
            kind: .video,
            byteSize: 100,
            contentHash: "typed-five-minute-\(index)",
            metadata: MediaMetadata(duration: duration, frameRate: 30, hasAudio: true)
        )
    }
    let candidates = assets.enumerated().map { index, asset in
        Candidate(
            assetID: asset.id,
            sourceStart: index == 0 ? 45 : 120,
            sourceDuration: 6.5,
            scores: ClipScores(
                quality: 0.84,
                interest: 0.86,
                action: 0.68,
                stability: 0.82,
                uniqueness: 0.84
            ),
            tags: [index == 0 ? "setup" : "journey"],
            insights: CandidateInsights(
                sceneSummary: index == 0 ? "trip setup" : "long journey",
                dynamics: 0.68,
                storyValue: 0.86
            )
        )
    }
    let analyses = zip(assets, candidates).map { asset, candidate in
        AnalysisResult(
            assetID: asset.id,
            analyzedContentHash: asset.contentHash,
            candidates: [candidate],
            completedDepth: .deep
        )
    }
    let events = zip(assets, candidates).enumerated().map { index, pair in
        let (asset, candidate) = pair
        let scene = EventScene(
            title: "Сцена \(index + 1)",
            assetIDs: [asset.id],
            candidateIDs: [candidate.id],
            phase: index == 0 ? .setup : .conclusion,
            confidence: 0.9
        )
        return Event(
            title: "Событие \(index + 1)",
            startDate: Date(timeIntervalSince1970: Double(index * 100)),
            assetIDs: [asset.id],
            confidence: 0.9,
            titleConfidence: 0.8,
            scenes: [scene],
            quality: EventQuality(
                total: 0.82,
                visualQuality: 0.84,
                semanticCoherence: 0.82,
                temporalCoherence: 0.84,
                usableMaterial: index == 0 ? 0.80 : 0.82,
                emotionalValue: 0.68,
                action: 0.66,
                uniqueness: 0.82,
                storyPotential: 0.84,
                diversity: 0.76
            )
        )
    }
    let prompt = "Собери цельную историю поездки"
    let brief = DirectorBrief(
        requestedDuration: 300,
        mood: .cinematic,
        musicPolicy: .none,
        sourceAudioPolicy: .duck,
        titlePolicy: .none
    )
    let autonomous = AutonomousDirectorEngine().decide(
        prompt: prompt,
        fallbackPreset: .cinematic,
        requestedDuration: brief.requestedDuration,
        assets: assets,
        analyses: analyses,
        personalProfile: PersonalTasteProfile(),
        events: events,
        requestIsExplicit: true
    )
    var constraints = PromptInterpreter.defaults(for: .cinematic)
    constraints.targetDuration = brief.requestedDuration
    constraints.pacing = brief.mood.pacing
    let plan = StoryEngine().createPlan(
        prompt: prompt,
        preset: .cinematic,
        constraints: constraints,
        assets: assets,
        analyses: analyses,
        events: events,
        autonomousDecision: autonomous,
        directorBrief: brief
    )
    let rough = TimelineComposer().compose(plan: plan, assets: assets, analyses: analyses)
    let directed = AIDirectorEngine().direct(
        plan: plan,
        initialTimeline: rough,
        assets: assets,
        analyses: analyses
    )
    let delivery = TimelineDeliveryContract().validateAndRepair(
        timeline: directed,
        plan: plan,
        assets: assets,
        analyses: analyses
    )

    #expect(autonomous.duration.safeRange == 300...300)
    #expect(abs((plan.eventStory?.entries.reduce(0) { $0 + $1.allocatedDuration } ?? 0) - 300) < 0.001)
    #expect(abs(rough.duration - 300) <= 1 / rough.frameRate)
    #expect(abs(directed.duration - 300) <= 1 / directed.frameRate)
    #expect(delivery.canPersist)
}

@Test func explicitDurationPartitionsContainedSourceAnchorsWithoutReuse() throws {
    let asset = MediaAsset(
        originalURL: URL(fileURLWithPath: "/tmp/contained-anchors.mov"),
        kind: .video,
        byteSize: 100,
        contentHash: "contained-anchors",
        metadata: MediaMetadata(duration: 120, frameRate: 30, hasAudio: true)
    )
    let outer = Candidate(
        assetID: asset.id,
        sourceStart: 0,
        sourceDuration: 100,
        scores: ClipScores(quality: 0.86, interest: 0.84, action: 0.72, stability: 0.82, uniqueness: 0.88),
        tags: ["cycling", "wide"],
        insights: CandidateInsights(sceneSummary: "wide cycling route", dynamics: 0.72, storyValue: 0.84),
        locked: true
    )
    let nested = Candidate(
        assetID: asset.id,
        sourceStart: 10,
        sourceDuration: 5,
        scores: ClipScores(quality: 0.91, interest: 0.92, action: 0.88, stability: 0.80, uniqueness: 0.90),
        tags: ["cycling", "detail"],
        insights: CandidateInsights(sceneSummary: "cycling detail", dynamics: 0.88, storyValue: 0.92),
        locked: true
    )
    let analysis = AnalysisResult(
        assetID: asset.id,
        analyzedContentHash: asset.contentHash,
        sceneTags: ["cycling"],
        candidates: [outer, nested],
        completedDepth: .deep
    )
    let prompt = "Сделай фильм ровно на 60 секунд. Без музыки."
    let autonomous = AutonomousDirectorEngine().decide(
        prompt: prompt,
        fallbackPreset: .story,
        requestedDuration: 60,
        assets: [asset],
        analyses: [analysis],
        personalProfile: PersonalTasteProfile()
    )
    var constraints = PromptInterpreter().interpret(prompt: prompt, preset: .story)
    constraints.targetDuration = autonomous.duration.seconds
    constraints.targetClipCount = 2
    let plan = StoryEngine().createPlan(
        prompt: prompt,
        preset: .story,
        constraints: constraints,
        assets: [asset],
        analyses: [analysis],
        autonomousDecision: autonomous
    )
    let timeline = TimelineComposer().compose(plan: plan, assets: [asset], analyses: [analysis])
    let ranges = timeline.items.sorted { $0.sourceStart < $1.sourceStart }

    #expect(autonomous.duration.safeRange == 60...60)
    #expect(ranges.count == 2)
    #expect(abs(timeline.duration - 60) <= 1 / timeline.frameRate)
    #expect(ranges[0].sourceStart + ranges[0].sourceDuration <= ranges[1].sourceStart + 0.001)
}

@Test func generatedActivityTitlesStayInsideTheirOwnReadableBlock() throws {
    let firstAsset = MediaAsset(
        originalURL: URL(fileURLWithPath: "/tmp/short-cycling.mov"),
        kind: .video,
        byteSize: 100,
        contentHash: "short-cycling",
        metadata: MediaMetadata(duration: 1, frameRate: 30, hasAudio: true)
    )
    let secondAsset = MediaAsset(
        originalURL: URL(fileURLWithPath: "/tmp/readable-buggy.mov"),
        kind: .video,
        byteSize: 100,
        contentHash: "readable-buggy",
        metadata: MediaMetadata(duration: 6, frameRate: 30, hasAudio: true)
    )
    let cycling = Candidate(
        assetID: firstAsset.id,
        sourceStart: 0,
        sourceDuration: 1,
        scores: ClipScores(quality: 0.8, interest: 0.8, action: 0.7, stability: 0.8),
        tags: ["cycling", "bicycle"]
    )
    let buggy = Candidate(
        assetID: secondAsset.id,
        sourceStart: 0,
        sourceDuration: 6,
        scores: ClipScores(quality: 0.86, interest: 0.88, action: 0.82, stability: 0.8),
        tags: ["buggy", "automobile", "helmet"]
    )
    let eventID = UUID()
    let cyclingSceneID = UUID()
    let buggySceneID = UUID()
    let chapters = [
        StoryChapter(
            title: "Велопрогулка",
            candidateIDs: [cycling.id],
            role: .intro,
            eventID: eventID,
            eventSceneID: cyclingSceneID,
            chapterCardTitle: "Велопрогулка"
        ),
        StoryChapter(
            title: "Багги",
            candidateIDs: [buggy.id],
            role: .action,
            eventID: eventID,
            eventSceneID: buggySceneID,
            chapterCardTitle: "Багги"
        )
    ]
    let plan = StoryPlan(
        prompt: "Только ключевые титры. Без музыки.",
        preset: .story,
        constraints: StoryConstraints(targetDuration: 10, targetClipCount: 2),
        chapters: chapters,
        eventStory: EventStoryPlan(
            entries: [EventStoryEntry(
                eventID: eventID,
                title: "Активный день",
                startDate: nil,
                endDate: nil,
                allocatedDuration: 10,
                quality: 0.8,
                sceneIDs: [cyclingSceneID, buggySceneID]
            )],
            chapterCardsEnabled: true
        )
    )
    let analyses = [
        AnalysisResult(assetID: firstAsset.id, analyzedContentHash: firstAsset.contentHash, candidates: [cycling]),
        AnalysisResult(assetID: secondAsset.id, analyzedContentHash: secondAsset.contentHash, candidates: [buggy])
    ]
    let timeline = TimelineComposer().compose(plan: plan, assets: [firstAsset, secondAsset], analyses: analyses)
    #expect(timeline.effectiveTitleItems.count == 1)
    let title = try #require(timeline.effectiveTitleItems.first)
    let buggyItems = timeline.items.filter { $0.eventSceneID == buggySceneID }
    let buggyStart = try #require(buggyItems.map(\.timelineStart).min())
    let buggyEnd = try #require(buggyItems.map { $0.timelineStart + $0.timelineDuration }.max())

    #expect(title.text == "Багги")
    #expect(abs(title.startTime - buggyStart) < 0.001)
    #expect(title.endTime <= buggyEnd + 0.001)
}

@Test func eventAwareDirectorPathKeepsExplicitDurationWhenMaterialIsSufficient() {
    let (assets, analyses) = p3Fixture(count: 18, energetic: true)
    let events = assets.enumerated().map { index, asset in
        let ids = analyses.first(where: { $0.assetID == asset.id })?.candidates.map(\.id) ?? []
        let scene = EventScene(
            title: "Сцена \(index + 1)",
            startDate: Date(timeIntervalSince1970: Double(index * 100)),
            assetIDs: [asset.id],
            candidateIDs: ids,
            phase: index == 0 ? .setup : index == 2 ? .reaction : .action,
            confidence: 0.9
        )
        return Event(
            title: "Событие \(index + 1)",
            startDate: scene.startDate,
            assetIDs: [asset.id],
            confidence: 0.9,
            titleConfidence: 0.8,
            scenes: [scene],
            quality: EventQuality(
                total: 0.82,
                visualQuality: 0.82,
                semanticCoherence: 0.82,
                temporalCoherence: 0.82,
                usableMaterial: 0.9,
                emotionalValue: 0.72,
                action: 0.72,
                uniqueness: 0.82,
                storyPotential: 0.82,
                diversity: 0.78
            )
        )
    }
    let prompt = "Сделай фильм ровно на 60 секунд. Без музыки."
    let autonomous = AutonomousDirectorEngine().decide(
        prompt: prompt,
        fallbackPreset: .story,
        requestedDuration: 60,
        assets: assets,
        analyses: analyses,
        personalProfile: PersonalTasteProfile(),
        events: events
    )
    var constraints = PromptInterpreter().interpret(prompt: prompt, preset: .story)
    constraints.targetDuration = autonomous.duration.seconds
    constraints.pacing = autonomous.finalStyle.pacing
    let plan = StoryEngine().createPlan(
        prompt: prompt,
        preset: .story,
        constraints: constraints,
        assets: assets,
        analyses: analyses,
        events: events,
        autonomousDecision: autonomous
    )
    let rough = TimelineComposer().compose(plan: plan, assets: assets, analyses: analyses)
    let timeline = AIDirectorEngine().direct(
        plan: plan,
        initialTimeline: rough,
        assets: assets,
        analyses: analyses
    )

    #expect(plan.eventStory != nil)
    #expect(plan.chapters.contains { [.intro, .setup].contains($0.role) })
    #expect(plan.chapters.contains { $0.role == .climax })
    #expect(plan.chapters.contains { $0.role == .outro })
    #expect(abs(timeline.duration - 60) <= 1 / timeline.frameRate)
    #expect(timeline.items.allSatisfy { $0.transition == nil })
    #expect(timeline.effectiveTransitionItems.isEmpty)
}

@Test func autonomousDurationPreservesUniqueMomentsAcrossSourceActivityGroups() {
    let (assets, initialAnalyses) = p3Fixture(count: 3, energetic: true)
    var analyses = initialAnalyses
    for analysisIndex in analyses.indices {
        for candidateIndex in analyses[analysisIndex].candidates.indices {
            analyses[analysisIndex].candidates[candidateIndex].insights?.semanticEventID = "shared-cross-video-event"
        }
    }
    let scenes = assets.map { asset in
        EventScene(
            title: asset.displayName,
            assetIDs: [asset.id],
            candidateIDs: analyses.first(where: { $0.assetID == asset.id })?.candidates.map(\.id) ?? [],
            confidence: 0.9
        )
    }
    let event = Event(title: "Source Map", assetIDs: assets.map(\.id), scenes: scenes)
    let project = AutonomousProjectStyleEngine().infer(
        assets: assets,
        analyses: analyses,
        fallbackPreset: .story,
        events: [event]
    )

    let withoutSourceGroups = AutonomousDurationOptimizer().decide(
        project: project,
        style: project.vector,
        analyses: analyses
    )
    let withSourceGroups = AutonomousDurationOptimizer().decide(
        project: project,
        style: project.vector,
        analyses: analyses,
        events: [event]
    )

    #expect(withoutSourceGroups.strongMomentCount == 1)
    #expect(withSourceGroups.strongMomentCount == 3)
    #expect(withSourceGroups.seconds > withoutSourceGroups.seconds)
}

@Test func preferenceLearningIsGradualContextualAndCanReverse() throws {
    let engine = PreferenceLearningEngine()
    let positive = PreferenceSignal(feature: "shotDuration", value: -1, confidence: 0.8, source: .trim, contextKey: "ACTION_TRAVEL")
    var profile = engine.updating(PersonalTasteProfile(), with: [positive], now: Date(timeIntervalSince1970: 1_000))
    #expect(profile.preferences["shotDuration"]?.mean ?? 0 > -1)
    #expect(profile.preferences["shotDuration"]?.confidence ?? 1 < 0.25)
    profile = engine.updating(profile, with: Array(repeating: positive, count: 12), now: Date(timeIntervalSince1970: 2_000))
    let learned = try #require(profile.preferences["shotDuration"])
    #expect(learned.mean < -0.85)
    #expect(profile.estimate(for: "shotDuration", contextKey: "ACTION_TRAVEL").confidence > 0.6)

    let reverse = PreferenceSignal(feature: "shotDuration", value: 1, confidence: 0.95, source: .restoration, contextKey: "ACTION_TRAVEL")
    let changed = engine.updating(profile, with: Array(repeating: reverse, count: 8), now: Date(timeIntervalSince1970: 20_000))
    #expect(changed.preferences["shotDuration"]!.mean > learned.mean + 0.45)
}

@Test func personalTasteInfluenceGrowsOnlyAfterRepeatedImplicitSignals() {
    let (assets, analyses) = p3Fixture(energetic: true)
    let neutral = AutonomousDirectorEngine().decide(prompt: "Собери лучший фильм", fallbackPreset: .story, requestedDuration: 120, assets: assets, analyses: analyses, personalProfile: PersonalTasteProfile())
    let signals = (0..<36).flatMap { _ in [
        PreferenceSignal(feature: "pacing", value: -1, confidence: 0.82, source: .trim),
        PreferenceSignal(feature: "shotDuration", value: 1, confidence: 0.82, source: .trim),
        PreferenceSignal(feature: "transitionIntensity", value: -1, confidence: 0.9, source: .transition)
    ] }
    let profile = PreferenceLearningEngine().updating(PersonalTasteProfile(), with: signals)
    let learned = AutonomousDirectorEngine().decide(prompt: "Собери лучший фильм", fallbackPreset: .story, requestedDuration: 120, assets: assets, analyses: analyses, personalProfile: profile)

    #expect(learned.personalConfidence > 0.70)
    #expect(learned.finalStyle.pacing < neutral.finalStyle.pacing)
    #expect(learned.finalStyle.shotDuration > neutral.finalStyle.shotDuration)
    #expect(learned.grammar.transitionDensity < neutral.grammar.transitionDensity)
}

@Test func autonomousMusicScoringRewardsEditableStructureAndNarrativeDrop() {
    let intent = AutonomousMusicIntent(
        style: .cinematic, desiredEnergy: 0.72, desiredBPM: 112, desiredDuration: 70,
        narrativeEnergyCurve: [0.2, 0.42, 0.68, 1, 0.38], needsBuildAndDrop: true,
        beatSyncIntensity: 0.7, confidence: 0.8, moodTokens: ["cinematic", "dynamic"], reasons: []
    )
    func track(_ title: String, energy: Double) -> LocalMusicTrack {
        LocalMusicTrack(
            title: title, author: "Fixture", bpm: 112, genres: ["cinematic"], moods: ["dynamic"], energy: energy, duration: 100,
            license: .userFile(), sourceProvider: .user, sourcePageURL: URL(string: "about:blank")!,
            localFileURL: URL(fileURLWithPath: "/tmp/\(title).wav"), originalFileName: "\(title).wav"
        )
    }
    let editable = MusicStructure(
        bpm: 112, beatInterval: 60 / 112,
        sections: [
            MusicSection(kind: .intro, start: 0, duration: 14, energy: 0.2, confidence: 0.9),
            MusicSection(kind: .buildup, start: 14, duration: 24, energy: 0.52, confidence: 0.9),
            MusicSection(kind: .drop, start: 38, duration: 24, energy: 0.96, confidence: 0.9),
            MusicSection(kind: .outro, start: 62, duration: 20, energy: 0.36, confidence: 0.9)
        ], drops: [38], downbeatTimestamps: [0, 2, 4], phraseBoundaries: [0, 14, 38, 62],
        tempoConfidence: 0.9, downbeatConfidence: 0.9, phraseConfidence: 0.9, sectionConfidence: 0.9, dropConfidence: 0.9, analysisIsMeasured: true
    )
    let flat = MusicStructure(
        bpm: 112, beatInterval: 60 / 112,
        sections: [MusicSection(kind: .chorus, start: 0, duration: 100, energy: 0.72, confidence: 0.4)],
        tempoConfidence: 0.6, downbeatConfidence: 0.2, phraseConfidence: 0.1, sectionConfidence: 0.2, dropConfidence: 0.1, analysisIsMeasured: false
    )
    let scorer = AutonomousMusicTrackScorer()
    #expect(scorer.score(track: track("editable", energy: 0.72), structure: editable, intent: intent)
        > scorer.score(track: track("flat", energy: 0.72), structure: flat, intent: intent) + 0.20)
}

@Test func autonomousGrammarUsesCleanCutsAndConfidenceSafety() {
    let (assets, analyses) = p3Fixture(energetic: true)
    let project = AutonomousProjectStyleEngine().infer(assets: assets, analyses: analyses, fallbackPreset: .highlight)
    let confident = AutonomousEditingGrammar(style: project.vector.adjusted(["transitionIntensity": 0.4]), project: project, confidence: 0.9)
    let uncertain = AutonomousEditingGrammar(style: project.vector.adjusted(["transitionIntensity": 0.4]), project: project, confidence: 0.18)

    #expect(confident.transitionDensity < 0.30)
    #expect(uncertain.transitionDensity < confident.transitionDensity)
    #expect(uncertain.speedRampDensity < confident.speedRampDensity)
    #expect(confident.effectDensity < confident.transitionDensity)
}

@Test func autonomousVariantIntentsProduceDifferentStyleGrammarAndStory() {
    let (assets, analyses) = p3Fixture(energetic: true)
    let base = AutonomousDirectorEngine().decide(prompt: "Лучший фильм", fallbackPreset: .adventure, requestedDuration: nil, assets: assets, analyses: analyses, personalProfile: PersonalTasteProfile())
    let action = base.variant(for: "telemetry-action")
    let cinematic = base.variant(for: "quiet-observational")

    #expect(action.finalStyle.distance(to: cinematic.finalStyle) > 0.16)
    #expect(action.grammar.meanShotDuration < cinematic.grammar.meanShotDuration)
    #expect(action.story.pattern == .rapidPeakReaction)
    #expect(cinematic.story.pattern == .atmosphericObservation)
    #expect(action.music.desiredBPM > cinematic.music.desiredBPM)
}

@Test func implicitSignalExtractorReadsRealTimelineBehavior() {
    let first = TimelineItem(kind: .video, sourceDuration: 6, timelineStart: 0, timelineDuration: 6)
    let second = TimelineItem(kind: .video, sourceDuration: 6, timelineStart: 6, timelineDuration: 6, transition: TransitionStyle.crossDissolve.rawValue)
    let before = Timeline(storyPlanID: UUID(), items: [first, second], music: MusicDirective(style: .energetic, bpm: 120))
    var shortened = first
    shortened.sourceDuration = 3
    shortened.timelineDuration = 3
    let after = Timeline(storyPlanID: before.storyPlanID, items: [shortened], music: nil)
    let signals = PreferenceSignalExtractor().signals(before: before, after: after, contextKey: "ACTION_TRAVEL")

    #expect(signals.contains { $0.source == .deletion && $0.feature == "visualDensity" && $0.value < 0 })
    #expect(signals.contains { $0.source == .trim && $0.feature == "shotDuration" && $0.value < 0 })
    #expect(signals.contains { $0.source == .transition && $0.feature == "transitionIntensity" && $0.value < 0 })
    #expect(signals.contains { $0.source == .music && $0.feature == "musicMatch" && $0.value < 0 })
}

@Test func paretoAnalyzerRejectsMultiObjectiveDominatedVariant() {
    let plan = StoryPlan(prompt: "", preset: .story, constraints: StoryConstraints(), chapters: [])
    let timeline = Timeline(storyPlanID: plan.id, items: [TimelineItem(kind: .video, sourceDuration: 3, timelineStart: 0, timelineDuration: 3)])
    let strong = MontageGlobalScore(
        total: 0.78, highlightQuality: 0.8, storyArc: 0.86, diversity: 0.7, durationFit: 0.8,
        musicalAlignment: 0.76, reviewQuality: 0.8, momentCompleteness: 0.84, continuity: 0.83,
        technicalQuality: 0.82, emotionalCurve: 0.80, pacingQuality: 0.82, projectStyleFit: 0.84, personalTasteFit: 0.78
    )
    let weak = MontageGlobalScore(
        total: 0.76, highlightQuality: 0.8, storyArc: 0.70, diversity: 0.7, durationFit: 0.8,
        musicalAlignment: 0.70, reviewQuality: 0.8, momentCompleteness: 0.70, continuity: 0.68,
        technicalQuality: 0.78, emotionalCurve: 0.66, pacingQuality: 0.69, projectStyleFit: 0.70, personalTasteFit: 0.66
    )
    let variants = [
        DirectedMontageVariant(story: StoryPlanVariant(plan: plan, strategy: "strong", seedScore: 1), timeline: timeline, score: strong),
        DirectedMontageVariant(story: StoryPlanVariant(plan: plan, strategy: "weak", seedScore: 1), timeline: timeline, score: weak)
    ]
    #expect(MontageParetoAnalyzer().front(variants).map { $0.story.strategy } == ["strong"])
}

@Test func productionPipelineRunsEndToEndAutonomouslyAndPersistsDiagnostics() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("veloedit")
    let tasteURL = FileManager.default.temporaryDirectory.appendingPathComponent("taste-\(UUID().uuidString).json")
    defer {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: tasteURL)
    }
    let store = try ProjectStore(createAt: root, name: "P3 autonomous production")
    let (assets, analyses) = p3Fixture()
    try await store.update { project in
        project.assets = assets
        project.analyses = analyses
    }
    let pipeline = VeloEditPipeline(store: store, personalTasteStore: LocalPersonalTasteStore(url: tasteURL))
    let timeline = try await pipeline.createFilm(
        prompt: "Без музыки. Сам определи лучший фильм из путешествия, действий, людей и реакций.",
        preset: .memories,
        targetDuration: 180
    )
    let run = try #require(timeline.directorRun)
    let autonomous = try #require(run.autonomousDecision)
    let diagnostics = try #require(run.variantDiagnostics)
    let snapshot = await pipeline.snapshot()

    #expect(autonomous.projectStyle.usableMomentCount >= 10)
    #expect(autonomous.duration.seconds < 120)
    #expect(timeline.duration <= autonomous.duration.safeRange.upperBound + 2)
    #expect(diagnostics.evaluatedVariantCount >= 2)
    #expect(diagnostics.variantEvaluations?.allSatisfy { $0.score.projectStyleFit > 0 && $0.score.pacingQuality > 0 } == true)
    #expect(run.paretoFrontStrategies?.isEmpty == false)
    #expect(run.decisionReasons.contains { $0.contains("ProjectStyle") })
    #expect(snapshot.storyPlans.last?.autonomousDecision != nil)
    #expect(snapshot.timelines.last?.directorRun?.autonomousDecision?.variantIntent == autonomous.variantIntent)

    var edited = timeline
    edited.items.removeLast()
    edited.items = TimelineTiming.retimed(edited.items)
    let learnedSignals = try await pipeline.recordPreferenceSignals(before: timeline, after: edited)
    let learnedSnapshot = await pipeline.snapshot()
    #expect(learnedSignals.contains { $0.source == .deletion })
    #expect(learnedSnapshot.personalTasteProfile?.totalSignalCount ?? 0 > 0)
    #expect(learnedSnapshot.preferenceSignals?.isEmpty == false)
}

@Test func autonomousDecisionsAreExplainableWithoutManualRatingUI() {
    let context = DirectorContext(
        assetCount: 8, videoCount: 8, photoCount: 0, analyzedCount: 8, candidateCount: 20,
        currentTimelineItemCount: 9, targetDuration: 58, preset: .story, currentOperation: "Готово",
        autonomousStyleLabel: "ACTION_TRAVEL", autonomousDurationConfidence: 0.82,
        autonomousDecisionReasons: ["Оптимальная длительность 58 с", "после неё оставались только повторяющиеся кадры"]
    )
    let reply = DirectorFallbackReply().make(userMessage: "Почему ролик такой длины?", context: context)
    #expect(reply.contains("58"))
    #expect(reply.contains("повторяющиеся"))
}
