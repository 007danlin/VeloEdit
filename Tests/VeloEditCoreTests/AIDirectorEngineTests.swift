import Foundation
import Testing
@testable import VeloEditCore

private func directorFixture() -> ([MediaAsset], [AnalysisResult]) {
    let tags: [Set<String>] = [
        ["nature", "atmosphere"], ["people", "travel"], ["bike", "action"],
        ["water", "fishing", "atmosphere"], ["buggy", "action", "high-speed"],
        ["sunset", "nature", "atmosphere"]
    ]
    let assets = tags.indices.map { index in
        MediaAsset(
            originalURL: URL(fileURLWithPath: "/tmp/director-source-\(index).mov"),
            kind: .video,
            byteSize: 100,
            contentHash: "director-\(index)",
            metadata: MediaMetadata(
                duration: 120,
                width: 3840,
                height: 2160,
                frameRate: index == 4 ? 120 : 60,
                hasAudio: true,
                creationDate: Date(timeIntervalSince1970: 1_700_000_000 + Double(index * 60))
            )
        )
    }
    let analyses = assets.enumerated().map { assetIndex, asset in
        let candidates = (0..<4).map { part -> Candidate in
            let action = assetIndex == 4 ? 0.94 - Double(part) * 0.02 : min(0.88, 0.20 + Double(assetIndex) * 0.10 + Double(part) * 0.08)
            let interest = min(0.96, 0.52 + Double(assetIndex) * 0.055 + Double(part) * 0.035)
            // A selected high-action shot is deliberately shaky so the
            // autonomous technical pass has a real stabilization decision.
            let stability = part == 1 && assetIndex == 4 ? 0.38 : 0.76
            let roleScores: [StoryRole: Double] = [
                .intro: assetIndex == 0 ? 0.95 : 0.35,
                .setup: assetIndex == 1 ? 0.92 : 0.42,
                .buildup: assetIndex == 2 ? 0.90 : 0.45,
                .climax: assetIndex == 4 ? 0.98 : action,
                .outro: assetIndex == 5 ? 0.98 : 0.32
            ]
            let duration = [2.4, 4.2, 7.5, 11.0][part]
            return Candidate(
                assetID: asset.id,
                sourceStart: Double(part * 22),
                sourceDuration: duration,
                scores: ClipScores(quality: 0.78, interest: interest, action: action, stability: stability, uniqueness: 0.82),
                tags: tags[assetIndex],
                explanation: ["fixture \(assetIndex)-\(part)"],
                insights: CandidateInsights(
                    sceneSummary: tags[assetIndex].sorted().joined(separator: ", "),
                    dynamics: action,
                    visualAppeal: interest,
                    composition: 0.82,
                    sharpness: 0.78,
                    motionBlur: action > 0.85 ? 0.28 : 0.08,
                    noise: 0.12,
                    shake: 1 - stability,
                    exposureQuality: 0.76,
                    slowMotionSuitability: assetIndex == 4 ? 0.96 : action * 0.7,
                    speedRampSuitability: action,
                    originalAudioUsefulness: tags[assetIndex].contains("people") || tags[assetIndex].contains("action") ? 0.84 : 0.34,
                    storyValue: interest,
                    roleScores: roleScores
                )
            )
        }
        let telemetry: TelemetrySummary?
        if assetIndex == 4 {
            var samples: [TelemetrySample] = []
            let peaks: Set<Int> = [1, 24, 46, 69]
            for index in 0...80 {
                let isPeak = peaks.contains(index)
                let speed = isPeak ? 24.0 : 7.0 + Double(index % 8) * 0.25
                let force = isPeak ? 2.4 : 1.05
                samples.append(TelemetrySample(
                    timestamp: Double(index),
                    speedMetersPerSecond: speed,
                    gForce: force
                ))
            }
            telemetry = TelemetrySummary(
                hasGPMF: true,
                sampleCount: samples.count,
                maxSpeedMetersPerSecond: 24,
                maxGForce: 2.4,
                timedSamples: samples,
                streams: ["GPS5", "ACCL"]
            )
        } else {
            telemetry = nil
        }
        return AnalysisResult(assetID: asset.id, analyzedContentHash: asset.contentHash, sceneTags: tags[assetIndex], candidates: candidates, telemetry: telemetry)
    }
    return (assets, analyses)
}

@Test func automaticDirectorKeepsOriginalColorsAndDoesNotInsertCutaways() {
    let (assets, original) = directorFixture()
    var analyses = original
    for index in analyses.indices {
        for candidateIndex in analyses[index].candidates.indices {
            analyses[index].candidates[candidateIndex].insights?.exposureQuality = 0.4
        }
    }
    let plan = StoryEngine().createPlan(prompt: "Киношный фильм с названиями каждой части", preset: .adventure,
        constraints: StoryConstraints(targetDuration: 45), assets: assets, analyses: analyses)
    let source = TimelineComposer().compose(plan: plan, assets: assets, analyses: analyses)
    let result = AIDirectorEngine(maximumReviewIterations: 0).direct(plan: plan, initialTimeline: source, assets: assets, analyses: analyses)
    #expect(!result.items.contains { $0.overlay != nil })
    #expect(result.items.allSatisfy {
        let video = $0.effectiveVideoAdjustments
        return (video.exposure ?? 0) == 0 && video.contrast == 1 && video.saturation == 1 && video.filter == .none
    })
    #expect(result.effectiveEffects.isEmpty)
}

@Test func directorDoesNotLowerMusicWhenUserAskedToLowerCameraAudio() {
    let (assets, analyses) = directorFixture()
    let plan = StoryEngine().createPlan(prompt: "Киношный фильм. Приглушить звук исходников.", preset: .adventure,
        constraints: StoryConstraints(targetDuration: 45), assets: assets, analyses: analyses)
    let source = TimelineComposer().compose(plan: plan, assets: assets, analyses: analyses)
    let result = AIDirectorEngine(maximumReviewIterations: 0).direct(plan: plan, initialTimeline: source, assets: assets, analyses: analyses)
    #expect(result.effectiveOriginalAudioVolume == 0.20)
    #expect(!SourceAudioMixPolicy.musicDucking(in: result).enabled)
}

@Test func autonomousDirectorRequiresEvidenceForClimaxAndAutomaticDecoration() {
    let (assets, analyses) = directorFixture()
    var constraints = PromptInterpreter().interpret(
        prompt: "Сделай динамичный фильм, поездка на багги — кульминация, покажи скорость на экране",
        preset: .adventure
    )
    constraints.targetDuration = 55
    constraints.targetClipCount = 12
    let plan = StoryEngine().createPlan(
        prompt: "Сделай динамичный фильм, поездка на багги — кульминация, покажи скорость на экране",
        preset: .adventure,
        constraints: constraints,
        assets: assets,
        analyses: analyses
    )
    var initial = TimelineComposer().compose(plan: plan, assets: assets, analyses: analyses)
    initial.music = MusicDirective(style: .energetic, bpm: 132)
    let directed = AIDirectorEngine().direct(plan: plan, initialTimeline: initial, assets: assets, analyses: analyses)
    let primaries = directed.items.filter { $0.overlay == nil && $0.kind != .title }

    #expect(primaries.first?.storyRole == .intro)
    #expect(primaries.last?.storyRole == .outro)
    #expect(!primaries.contains { $0.storyRole == .climax })
    #expect(plan.narrativeBeatPlan?.beats.allSatisfy(\.fulfilled) == true)
    #expect(Set(primaries.map { Int(($0.sourceDuration * 10).rounded()) }).count > 2)
    #expect(!directed.effectiveEffects.contains { $0.enabled && $0.effectType.category == .stylized })
    #expect(directed.effectiveTelemetryItems.contains { item in
        primaries.contains(where: { $0.id == item.targetClipID }) && item.timelineDuration < directed.duration
    })
    #expect(SourceAudioMixPolicy.musicDucking(in: directed).enabled)
    #expect(directed.directorRun?.reviewIterations ?? -1 <= 2)
    #expect((directed.directorRun?.finalReview.score ?? 0) >= (directed.directorRun?.initialReview.score ?? 0))
    #expect(directed.editorialBeatPlan != nil)
}

@Test func directorEditingToolsValidateAndExecuteStructuralTimelineChanges() throws {
    let (assets, analyses) = directorFixture()
    let candidates = analyses.flatMap(\.candidates)
    let first = candidates[0]
    let second = candidates[4]
    let third = candidates[8]
    let firstItem = TimelineItem(candidateID: first.id, assetID: first.assetID, kind: .video, sourceStart: first.sourceStart, sourceDuration: first.sourceDuration, timelineStart: 0, timelineDuration: first.sourceDuration, storyRole: .intro)
    let secondItem = TimelineItem(candidateID: second.id, assetID: second.assetID, kind: .video, sourceStart: second.sourceStart, sourceDuration: second.sourceDuration, timelineStart: first.sourceDuration, timelineDuration: second.sourceDuration, storyRole: .setup)
    let source = Timeline(storyPlanID: UUID(), items: [firstItem, secondItem])
    let calls: [DirectorToolCall] = [
        .insert(candidateID: third.id, sourceStart: third.sourceStart, sourceDuration: third.sourceDuration, afterItemID: firstItem.id, role: .action, reason: "вернуть сильный исходник"),
        .replace(itemID: secondItem.id, candidateID: candidates[12].id, sourceStart: candidates[12].sourceStart, sourceDuration: candidates[12].sourceDuration, role: .buildup, reason: "заменить слабую сцену"),
        .reorder(itemID: secondItem.id, beforeItemID: firstItem.id, reason: "изменить порядок"),
        .duplicate(itemID: firstItem.id, afterItemID: nil, reason: "повторно использовать оправданный фрагмент"),
        .trim(itemID: firstItem.id, sourceStart: 500, sourceDuration: 4, reason: "недопустимый диапазон")
    ]
    let result = DirectorEditingTools().apply(calls, to: source, assets: assets, analyses: analyses)

    #expect(result.report.applied.count == 4)
    #expect(result.report.rejected.count == 1)
    #expect(result.timeline.items.count == 4)
    #expect(result.timeline.items.first?.id == secondItem.id)
    #expect(result.timeline.items.contains { $0.candidateID == third.id })
    #expect(result.timeline.items.filter { $0.assetID == first.assetID }.count == 2)
    #expect(result.timeline.items.map(\.timelineStart) == TimelineTiming.retimed(result.timeline.items).map(\.timelineStart))
    #expect(assets[0].originalURL.path == "/tmp/director-source-0.mov")

    let xml = try FCPXMLExporter().xml(timeline: result.timeline, assets: assets)
    #expect(xml.contains("fcpxml"))
    #expect(xml.contains("director-source"))
}

@Test func semanticToolCatalogCoversTheDirectorSpecification() {
    let tools = Set(DirectorEditingTool.allCases)
    #expect(tools.isSuperset(of: [
        .cut, .split, .trim, .rippleDelete, .reorder, .insert, .replace, .duplicate,
        .crop, .zoom, .pan, .kenBurns, .speedChange, .slowMotion, .speedRamp,
        .freezeFrame, .stabilization, .exposure, .color, .contrast, .saturation,
        .sharpening, .videoDenoise, .blur, .transitions, .dissolve, .fade,
        .dipToBlack, .wipe, .lightTransition, .music, .trimMusic, .audioFade,
        .volume, .ducking, .noiseReduction, .eq, .detachAudio, .bRoll, .overlay,
        .pictureInPicture, .splitScreen, .titles, .telemetry, .beatSynchronization
    ]))
}

@Test func directorAddTitleUsesTheSharedTemplateTimelineObject() {
    let video = TimelineItem(kind: .video, sourceDuration: 10, timelineStart: 0, timelineDuration: 10)
    let source = Timeline(storyPlanID: UUID(), items: [video])
    let result = DirectorEditingTools().apply(
        [
            .addTitle(text: "В путь", atEnd: false, reason: "начальный титр"),
            .addTitle(text: "Конец", atEnd: true, reason: "финальный титр")
        ],
        to: source,
        assets: [],
        analyses: []
    )

    #expect(result.timeline.items == [video])
    #expect(result.timeline.effectiveTitleItems.map(\.templateID) == ["title.minimal-clean.v1", "title.end-card.v1"])
    #expect(result.timeline.effectiveTitleItems[0].startTime == 0)
    #expect(result.timeline.effectiveTitleItems[1].endTime == source.duration)
    #expect(result.report.rejected.isEmpty)
}

@Test func editorCommandsExposeStabilizationCleanupAndDetachedAudio() {
    let item = TimelineItem(assetID: UUID(), kind: .video, sourceDuration: 6, timelineStart: 0, timelineDuration: 6)
    let timeline = Timeline(storyPlanID: UUID(), items: [item], music: MusicDirective(style: .cinematic, bpm: 82))
    let commands = EditorCommandParser().parse("Первый клип: стабилизируй, добавь резкость 40%, убери шум на видео, отдели звук, включи ducking")
    let result = EditorCommandExecutor().apply(commands, to: timeline)

    #expect(result.timeline.items[0].effectiveVideoAdjustments.stabilization == 0.58)
    #expect(result.timeline.items[0].effectiveVideoAdjustments.sharpening == 0.4)
    #expect(result.timeline.items[0].effectiveVideoAdjustments.denoise == 0.55)
    #expect(result.timeline.items[0].effectiveAudioAdjustments.muted)
    #expect(result.timeline.effectiveAudioClips.count == 1)
    #expect(result.timeline.audioDucking?.enabled == true)
    #expect(AdjustedClipGenerator.needsRender(result.timeline.items[0].effectiveVideoAdjustments))
}

@Test func persistentAICheckpointCanRestoreThePreviousTimeline() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("veloedit")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try ProjectStore(createAt: root, name: "AI checkpoints")
    let asset = MediaAsset(originalURL: URL(fileURLWithPath: "/tmp/checkpoint.mov"), kind: .video, byteSize: 1, contentHash: "checkpoint", metadata: MediaMetadata(duration: 20))
    let item = TimelineItem(assetID: asset.id, kind: .video, sourceDuration: 8, timelineStart: 0, timelineDuration: 8)
    let plan = StoryPlan(prompt: "Фильм", preset: .story, constraints: StoryConstraints(), chapters: [])
    try await store.update { project in
        project.assets = [asset]
        project.storyPlans = [plan]
        project.timelines = [Timeline(storyPlanID: plan.id, items: [item], versionName: "AI Edit 01")]
    }
    let pipeline = VeloEditPipeline(store: store)
    _ = try await pipeline.applyEditorCommands([.setSpeed(2, .first)], createCheckpoint: true)
    let edited = await pipeline.snapshot()
    let checkpoint = try #require(edited.timelineCheckpoints?.last)
    #expect(edited.timelines.last?.items.first?.speed == 2)
    #expect(checkpoint.timeline.items.first?.speed == 1)

    _ = try await pipeline.restoreTimelineCheckpoint(id: checkpoint.id)
    let restored = await pipeline.snapshot()
    #expect(restored.timelines.last?.items.first?.speed == 1)
    #expect(restored.timelines.last?.versionName?.contains("Восстановлено") == true)
}

@Test func musicStructureMapsStoryEnergyAndBeatDensity() {
    let items: [TimelineItem] = [
        TimelineItem(kind: .video, sourceDuration: 8, timelineStart: 0, timelineDuration: 8, storyRole: .intro),
        TimelineItem(kind: .video, sourceDuration: 8, timelineStart: 8, timelineDuration: 8, storyRole: .buildup),
        TimelineItem(kind: .video, sourceDuration: 8, timelineStart: 16, timelineDuration: 8, storyRole: .climax),
        TimelineItem(kind: .video, sourceDuration: 8, timelineStart: 24, timelineDuration: 8, storyRole: .outro)
    ]
    let directive = MusicDirective(style: .energetic, bpm: 120)
    let timeline = Timeline(storyPlanID: UUID(), items: items, music: directive)
    let track = LocalMusicTrack(
        title: "Fixture", author: "Fixture", bpm: 120, genres: ["action"], moods: ["energetic"], energy: 0.9, duration: 60,
        license: .userFile(), sourceProvider: .user, sourcePageURL: URL(string: "about:blank")!, localFileURL: URL(fileURLWithPath: "/tmp/music.mp3"), originalFileName: "music.mp3"
    )
    let synchronized = MusicBeatSynchronizer().synchronize(timeline, to: track)
    #expect(synchronized.music?.structure?.sections.map(\.kind) == [.intro, .buildup, .drop, .chorus, .climax, .outro])
    #expect(synchronized.music?.structure?.beatInterval == 0.5)
    // A supplied BPM describes a grid, not measured beat confidence. Building
    // the structure must not claim synchronization or trim uninspected footage.
    #expect(synchronized.items == timeline.items)
    #expect(synchronized.music?.structure?.analysisIsMeasured == false)
}

@Test func selfReviewRemovesAnUnjustifiedTechnicallyWeakShot() {
    let asset = MediaAsset(
        originalURL: URL(fileURLWithPath: "/tmp/self-review.mov"),
        kind: .video,
        byteSize: 1,
        contentHash: "self-review",
        metadata: MediaMetadata(duration: 90, frameRate: 60, hasAudio: true)
    )
    var candidates: [Candidate] = []
    for index in 0..<7 {
        let scores = ClipScores(
            quality: index == 3 ? 0.18 : 0.82,
            interest: index == 3 ? 0.20 : 0.76,
            action: index.isMultiple(of: 2) ? 0.82 : 0.58,
            stability: 0.78,
            uniqueness: 0.8
        )
        candidates.append(Candidate(
            assetID: asset.id,
            sourceStart: Double(index * 10),
            sourceDuration: 5,
            scores: scores,
            tags: index.isMultiple(of: 2) ? ["action"] : ["nature"]
        ))
    }
    let roles: [StoryRole] = [.intro, .setup, .buildup, .action, .action, .climax, .outro]
    let items = zip(candidates, roles).enumerated().map { index, pair in
        TimelineItem(
            candidateID: pair.0.id,
            assetID: asset.id,
            kind: .video,
            sourceStart: pair.0.sourceStart,
            sourceDuration: 5,
            timelineStart: Double(index * 5),
            timelineDuration: 5,
            storyRole: pair.1
        )
    }
    let weakItemID = items[3].id
    let analysis = AnalysisResult(assetID: asset.id, analyzedContentHash: asset.contentHash, candidates: candidates)
    let plan = StoryPlan(
        prompt: "Собери энергичный фильм",
        preset: .adventure,
        constraints: StoryConstraints(targetDuration: 35, pacing: 0.72),
        chapters: []
    )
    let directed = AIDirectorEngine().direct(
        plan: plan,
        initialTimeline: Timeline(storyPlanID: plan.id, items: items),
        assets: [asset],
        analyses: [analysis]
    )

    #expect(!directed.items.contains { $0.id == weakItemID })
    #expect(directed.directorRun?.appliedToolNames.contains(DirectorEditingTool.rippleDelete.rawValue) == true)
    #expect((directed.directorRun?.finalReview.score ?? 0) > (directed.directorRun?.initialReview.score ?? 0))
}

@Test func selfReviewTransactionRejectsAWorseSpeculativeTimeline() {
    let (assets, analyses) = directorFixture()
    var constraints = StoryConstraints(targetDuration: 30, targetClipCount: 6, pacing: 0.7)
    constraints.preferredClimaxTags = ["buggy"]
    let plan = StoryEngine().createPlan(prompt: "Приключение", preset: .adventure, constraints: constraints, assets: assets, analyses: analyses)
    let original = TimelineComposer().compose(plan: plan, assets: assets, analyses: analyses)
    let review = TimelineSelfReviewer().review(original, plan: plan, analyses: analyses)
    var speculative = original
    speculative.items = []
    let result = TimelineReviewTransaction().commitIfImproved(
        original: original,
        candidate: speculative,
        currentReview: review,
        plan: plan,
        analyses: analyses
    )
    #expect(!result.committed)
    #expect(result.timeline == original)
    #expect(result.review == review)
}

@Test func directorRuntimeQualityGateRepairsGeneratedTitlesBeforeReturningTimeline() {
    let (assets, analyses) = directorFixture()
    let plan = StoryEngine().createPlan(
        prompt: "Короткий фильм без выдуманных титров",
        preset: .story,
        constraints: StoryConstraints(targetDuration: 12, targetClipCount: 2),
        assets: assets,
        analyses: analyses
    )
    var initial = TimelineComposer().compose(plan: plan, assets: assets, analyses: analyses)
    let placeholderTitle = TitleTimelineItem(
        kind: .title,
        text: "Кульминация",
        startTime: 0,
        duration: 3,
        explanation: ["Автоматический титр режиссёра"]
    )
    initial.titleItems = initial.effectiveTitleItems + [placeholderTitle]

    let directed = AIDirectorEngine(maximumReviewIterations: 0).direct(
        plan: plan,
        initialTimeline: initial,
        assets: assets,
        analyses: analyses
    )

    #expect(!directed.effectiveTitleItems.contains { SmartTitleEngine.isMeaningless($0.text) })
    #expect(!directed.effectiveTitleItems.contains { $0.id == placeholderTitle.id })
}

@Test func globalVariantSelectorChoosesTheStrongerCompleteMontage() throws {
    let (assets, analyses) = directorFixture()
    let constraints = StoryConstraints(targetDuration: 30, targetClipCount: 6, pacing: 0.7)
    let plan = StoryEngine().createPlan(prompt: "Приключение", preset: .adventure, constraints: constraints, assets: assets, analyses: analyses)
    let good = TimelineComposer().compose(plan: plan, assets: assets, analyses: analyses)
    let first = try #require(good.items.first(where: { $0.kind != .title }))
    let repeated = (0..<6).map { index in
        TimelineItem(candidateID: first.candidateID, assetID: first.assetID, kind: .video, sourceStart: first.sourceStart, sourceDuration: 4, timelineStart: Double(index * 4), timelineDuration: 4, storyRole: index == 5 ? .climax : .action)
    }
    let poor = Timeline(storyPlanID: plan.id, items: repeated)
    let stories = [
        StoryPlanVariant(plan: plan, strategy: "complete", seedScore: 1),
        StoryPlanVariant(plan: plan, strategy: "repeated", seedScore: 0)
    ]
    let winner = try #require(MontageVariantSelector().select(stories: stories, timelines: [good, poor], assets: assets, analyses: analyses))
    let poorScore = DefaultMontageGlobalScorer().score(plan: plan, timeline: poor, assets: assets, analyses: analyses)
    #expect(winner.story.strategy == "complete")
    #expect(winner.score.total > poorScore.total)
}

@Test func productionCreateFilmBuildsAndReportsDistinctDirectedVariants() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("veloedit")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try ProjectStore(createAt: root, name: "P1 production variants")
    let (fixtureAssets, analyses) = directorFixture()
    let assets = try await materializeEditorialFixtureMedia(fixtureAssets, at: root)
    try await store.update { project in
        project.assets = assets
        project.analyses = analyses
    }
    try await store.update { $0.editorialDevelopmentEnabled = true }
    let pipeline = VeloEditPipeline(store: store, renderedProber: FixtureEditorialProber(), analyzer: FixtureEditorialAnalyzer(analyses: analyses))
    let timeline = try await pipeline.createFilm(
        prompt: "Без музыки. Собери разные решения: природа, люди, движение, поездка на багги и реакция",
        preset: .adventure
    )
    let diagnostics = try #require(timeline.directorRun?.variantDiagnostics)
    let snapshot = await pipeline.snapshot()

    #expect(diagnostics.attemptedStrategyCount >= diagnostics.acceptedVariantCount)
    #expect(diagnostics.acceptedVariantCount >= 2)
    #expect(diagnostics.acceptedVariantCount <= 10)
    #expect(diagnostics.evaluatedVariantCount == diagnostics.variantEvaluations?.count)
    #expect(diagnostics.variantEvaluations?.count == diagnostics.acceptedVariantCount)
    #expect(diagnostics.pairDistances.count >= 1)
    #expect(diagnostics.pairDistances.allSatisfy { $0.metrics.total + 0.000_001 >= diagnostics.minimumRequiredDistance })
    #expect(diagnostics.winningStrategy != nil)
    let eligible = diagnostics.variantEvaluations?.filter { $0.disposition == .selected || $0.disposition == .evaluated }.count ?? 0
    #expect(diagnostics.pairwiseResults?.count == eligible * max(0, eligible - 1) / 2)
    #expect(diagnostics.pairwiseResults?.allSatisfy { !$0.reasons.isEmpty } == true)
    #expect(diagnostics.variantEvaluations?.filter { $0.disposition == .selected }.count == 1)
    #expect(diagnostics.variantEvaluations?.first(where: { $0.disposition == .selected })?.strategy == diagnostics.winningStrategy)
    #expect(diagnostics.variantEvaluations?.allSatisfy { $0.score.technicalQuality > 0 && $0.score.rhythmQuality > 0 && $0.score.continuity > 0 } == true)
    #expect(diagnostics.rejectedVariants?.allSatisfy { !$0.reason.isEmpty } == true)
    #expect(timeline.directorRun?.globalScore != nil)
    #expect(snapshot.storyPlans.last?.id == timeline.storyPlanID)
    #expect(snapshot.timelines.last?.id == timeline.id)

    let reopenedStore = try ProjectStore(open: root)
    let reopened = await reopenedStore.manifest
    #expect(reopened.timelines.last?.directorRun?.variantDiagnostics?.variantEvaluations?.count == diagnostics.acceptedVariantCount)
    #expect(reopened.timelines.last?.directorRun?.variantDiagnostics?.pairwiseResults?.count == diagnostics.pairwiseResults?.count)
}
