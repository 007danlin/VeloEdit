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
