import Foundation
import Testing
@testable import VeloEditCore

@Test func timelineAICommentsMixedDeepAndTypedRequestKeepsBothPlanParts() {
    let clip = TimelineItem(
        kind: .video,
        sourceDuration: 8,
        timelineStart: 0,
        timelineDuration: 8
    )
    let story = StoryPlan(
        prompt: "Исходный фильм",
        preset: .story,
        constraints: StoryConstraints(targetDuration: 8),
        chapters: []
    )
    let timeline = Timeline(storyPlanID: story.id, items: [clip])
    let project = ProjectManifest(
        name: "Смешанная AI-правка",
        storyPlans: [story],
        timelines: [timeline]
    )
    let input = NaturalLanguageDirectorInput(
        userRequest: "Сделай монтаж кинематографичнее, а выбранный клип сделай чёрно-белым",
        currentProject: project,
        timeline: timeline,
        selectedItemID: clip.id
    )

    let director = NaturalLanguageDirector()
    let plan = director.plan(input: input)

    #expect(plan.executionTier == .deep)
    #expect(plan.requiresBackgroundRefinement)
    #expect(plan.intents.contains { $0.operation == .style })
    #expect(plan.intents.contains { $0.operation == .genericEdit })
    #expect(plan.commands.contains(.setFilter(.monochrome, .selected)))

    let result = director.execute(plan: plan, input: input)
    #expect(result.committed)
    #expect(result.plan.requiresBackgroundRefinement)
    #expect(result.timeline.items.first?.effectiveVideoAdjustments.filter == .monochrome)
}

@Test func timelineAICommentsStoryRebuildKeepsTypedMusicRemoval() {
    let clips = (0..<4).map { index in
        TimelineItem(
            kind: .video,
            sourceStart: Double(index * 3),
            sourceDuration: 3,
            timelineStart: Double(index * 3),
            timelineDuration: 3
        )
    }
    let story = StoryPlan(
        prompt: "Исходный фильм",
        preset: .story,
        constraints: StoryConstraints(targetDuration: 12),
        chapters: []
    )
    let timeline = Timeline(
        storyPlanID: story.id,
        items: clips,
        music: MusicDirective(style: .energetic, bpm: 124)
    )
    let project = ProjectManifest(
        name: "Смешанная пересборка истории",
        storyPlans: [story],
        timelines: [timeline]
    )
    let input = NaturalLanguageDirectorInput(
        userRequest: "Оставь 3 момента и убери музыку",
        currentProject: project,
        timeline: timeline
    )

    let plan = NaturalLanguageDirector().plan(input: input)

    #expect(plan.executionTier == .deep)
    #expect(plan.requiresBackgroundRefinement)
    #expect(plan.intents.contains { $0.operation == .autonomousEdit })
    #expect(plan.intents.contains { $0.operation == .music })
    #expect(plan.commands.contains(.setMusic(nil)))
}

@Test func timelineAICommentsDistinguishesFilmDurationFromClipDuration() {
    let clip = TimelineItem(
        kind: .video,
        sourceDuration: 8,
        timelineStart: 0,
        timelineDuration: 8
    )
    let story = StoryPlan(
        prompt: "Исходный фильм",
        preset: .story,
        constraints: StoryConstraints(targetDuration: 8),
        chapters: []
    )
    let timeline = Timeline(storyPlanID: story.id, items: [clip])
    let project = ProjectManifest(name: "Точная длительность", storyPlans: [story], timelines: [timeline])
    let director = NaturalLanguageDirector()

    let filmPlan = director.plan(input: NaturalLanguageDirectorInput(
        userRequest: "Сделай фильм длительностью 15 секунд",
        currentProject: project,
        timeline: timeline
    ))
    #expect(filmPlan.requiresBackgroundRefinement)
    #expect(!filmPlan.commands.contains { $0.semanticCategory == "duration" })

    let clipPlan = director.plan(input: NaturalLanguageDirectorInput(
        userRequest: "Сделай выбранный клип длительностью 3 секунды",
        currentProject: project,
        timeline: timeline,
        selectedItemID: clip.id
    ))
    #expect(!clipPlan.requiresBackgroundRefinement)
    #expect(clipPlan.commands.contains(.setDuration(3, .selected)))

    let mixedPlan = director.plan(input: NaturalLanguageDirectorInput(
        userRequest: "Сделай кинематографичнее, а выбранный клип длительностью 3 секунды",
        currentProject: project,
        timeline: timeline,
        selectedItemID: clip.id
    ))
    #expect(mixedPlan.requiresBackgroundRefinement)
    #expect(mixedPlan.commands.contains(.setDuration(3, .selected)))
}

@Test func timelineAICommentsNegativeDirectivesAreNotInverted() {
    let parser = EditorCommandParser()
    for request in [
        "Сделай динамичнее, но без slow motion",
        "Убери slow motion",
        "Не добавляй slow motion",
        "Никакого slow motion"
    ] {
        let commands = parser.parse(request, preset: .story)
        #expect(!commands.contains(.setSpeed(0.5, .all)))
        #expect(commands.contains(.removeSlowMotion(.all)))
    }

    let regularSlow = TimelineItem(
        kind: .video,
        sourceDuration: 2,
        timelineStart: 0,
        timelineDuration: 4,
        speed: 0.5
    )
    let accelerated = TimelineItem(
        kind: .video,
        sourceDuration: 4,
        timelineStart: 4,
        timelineDuration: 2,
        speed: 2
    )
    let mixedRamp = TimelineItem(
        kind: .video,
        sourceDuration: 4,
        timelineStart: 6,
        timelineDuration: SpeedRamp.action.outputDuration(sourceDuration: 4),
        speedRamp: .action
    )
    let freeze = TimelineItem(
        kind: .video,
        sourceStart: 5,
        sourceDuration: 1 / 30,
        timelineStart: 10,
        timelineDuration: 3,
        freezeFrame: true
    )
    let speedResult = EditorCommandExecutor().apply(
        [.removeSlowMotion(.all)],
        to: Timeline(storyPlanID: UUID(), items: [regularSlow, accelerated, mixedRamp, freeze])
    ).timeline
    #expect(speedResult.items[0].speed == 1)
    #expect(speedResult.items[1].speed == 2)
    #expect(speedResult.items[1].timelineDuration == accelerated.timelineDuration)
    #expect(speedResult.items[2].speedRamp?.normalizedPoints.allSatisfy { $0.rate >= 1 } == true)
    #expect(speedResult.items[2].speedRamp?.normalizedPoints.contains { $0.rate > 1 } == true)
    #expect(speedResult.items[3].timelineDuration == freeze.timelineDuration)

    let candidateID = UUID()
    let previousAnchor = TimelineItem(
        candidateID: candidateID,
        kind: .video,
        sourceDuration: 4,
        timelineStart: 0,
        timelineDuration: 4
    )
    var anchoredFreeze = freeze
    anchoredFreeze.timelineStart = 4
    let regeneratedAnchor = TimelineItem(
        candidateID: candidateID,
        kind: .video,
        sourceDuration: 4,
        timelineStart: 0,
        timelineDuration: 4
    )
    let carried = VeloEditPipeline.carryEditorAdjustments(
        from: Timeline(storyPlanID: UUID(), items: [previousAnchor, anchoredFreeze]),
        to: Timeline(storyPlanID: UUID(), items: [regeneratedAnchor])
    )
    #expect(carried.items.map(\.id) == [regeneratedAnchor.id, anchoredFreeze.id])
    #expect(carried.items[1].timelineStart == carried.items[0].timelineDuration)
    #expect(carried.items[1].timelineDuration == anchoredFreeze.timelineDuration)

    var base = StoryConstraints(targetDuration: 12, includeTags: ["action"])
    base.maximumTagShares["action"] = 0.80
    let lessAction = PromptInterpreter().interpret(
        prompt: "Сделай кинематографичнее и меньше экшена",
        preset: .story,
        base: base
    )
    #expect(!lessAction.includeTags.contains("action"))
    #expect((lessAction.maximumTagShares["action"] ?? 1) <= 0.25)

    let clipDurationFeedback = VeloEditPipeline.interpretedFeedbackConstraints(
        "Сделай динамичнее, а выбранный клип длительностью 3 секунды",
        preset: .story,
        base: base,
        ignoredConstraints: [.targetDuration]
    )
    #expect(clipDurationFeedback.targetDuration == base.targetDuration)
    #expect(clipDurationFeedback.pacing > base.pacing)

    var repeatedBase = base
    repeatedBase.allowSlowMotion = false
    repeatedBase.pacing = 1
    let repeatedText = "Ещё динамичнее и по-прежнему без slow motion"
    let repeated = PromptInterpreter().interpret(
        prompt: repeatedText,
        preset: .story,
        base: repeatedBase
    )
    let repeatedLocks = VeloEditPipeline.storyConstraintLocks(
        explicitIn: repeatedText,
        from: repeatedBase,
        to: repeated
    )
    #expect(repeatedLocks.contains(.pacing))
    #expect(repeatedLocks.contains(.allowSlowMotion))

    let selectedSpeed = VeloEditPipeline.interpretedFeedbackConstraints(
        "Сделай кинематографичнее, а выбранный клип медленнее",
        preset: .story,
        base: base,
        ignoredConstraints: [.pacing]
    )
    #expect(selectedSpeed.pacing == base.pacing)

    let negatedDynamic = PromptInterpreter().interpret(
        prompt: "Не делай монтаж динамичным",
        preset: .story,
        base: base
    )
    #expect(negatedDynamic.pacing < base.pacing)
}

@Test func timelineAICommentsMagicBrushAllTargetDoesNotEscapeRange() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("veloedit")
    defer { try? FileManager.default.removeItem(at: root) }

    let store = try ProjectStore(createAt: root, name: "Локальная команда all")
    let source = TimelineItem(
        kind: .video,
        sourceDuration: 10,
        timelineStart: 0,
        timelineDuration: 10
    )
    let timeline = Timeline(storyPlanID: UUID(), items: [source])
    try await store.update { $0.timelines = [timeline] }
    let pipeline = VeloEditPipeline(store: store)

    let report = try await pipeline.applyEditorCommands(
        [.setFilter(.monochrome, .all)],
        timelineRange: 2...4
    )
    let edited = try #require((await store.manifest).timelines.last)

    #expect(report.hasChanges)
    #expect(edited.items.count == 3)
    #expect(edited.items.map(\.sourceStart) == [0, 2, 4])
    #expect(edited.items.map(\.sourceDuration) == [2, 2, 6])
    #expect(edited.items.map { $0.effectiveVideoAdjustments.filter } == [.none, .monochrome, .none])
}

@Test func timelineAICommentsMagicBrushSlicingKeepsAttachmentsAndOutsideSegmentsStable() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("veloedit")
    defer { try? FileManager.default.removeItem(at: root) }

    let store = try ProjectStore(createAt: root, name: "Связи после локальной нарезки")
    let baseAssetID = UUID()
    let overlayAssetID = UUID()
    let nextAssetID = UUID()
    let base = TimelineItem(
        assetID: baseAssetID,
        kind: .video,
        sourceDuration: 10,
        timelineStart: 0,
        timelineDuration: 10
    )
    let overlay = TimelineItem(
        assetID: overlayAssetID,
        kind: .video,
        sourceStart: 1,
        sourceDuration: 2,
        timelineStart: 6,
        timelineDuration: 2,
        videoAdjustments: VideoAdjustments(filter: .warm),
        overlay: OverlaySettings(
            style: .pictureInPicture,
            baseItemID: base.id,
            corner: .bottomRight,
            scale: 0.31,
            startOffset: 6
        )
    )
    let next = TimelineItem(
        assetID: nextAssetID,
        kind: .video,
        sourceDuration: 2,
        timelineStart: 10,
        timelineDuration: 2
    )
    let attachedAudio = TimelineAudioClip(
        title: "Синхронный звук",
        role: .naturalSound,
        sourceDuration: 10,
        timelineStart: 0,
        timelineDuration: 10,
        attachedToItemID: base.id,
        attachmentOffset: 0,
        adjustments: AudioAdjustments(volume: 0.73, fadeIn: 0.2, fadeOut: 0.3)
    )
    let attachedTelemetry = TimelineTelemetryItem(
        targetClipID: base.id,
        sourceStart: 0,
        timelineStart: 0,
        timelineDuration: 10,
        settings: TelemetryOverlaySettings(opacity: 0.61)
    )
    let attachedEffect = EffectTimelineItem(
        effectType: .glow,
        startTime: 0,
        duration: 10,
        intensity: 0.37,
        targetClipID: base.id
    )
    let attachedTitle = TitleTimelineItem(
        kind: .title,
        text: "Связанный титр",
        startTime: 0,
        duration: 10,
        style: TitleStyle(fontSize: 48, opacity: 0.82),
        targetClipID: base.id
    )
    let transition = TimelineTransitionItem(
        style: .push,
        outgoingClipID: base.id,
        incomingClipID: next.id,
        startTime: 10,
        duration: 0.6
    )
    let timeline = Timeline(
        storyPlanID: UUID(),
        items: [base, overlay, next],
        audioClips: [attachedAudio],
        telemetryItems: [attachedTelemetry],
        effects: [attachedEffect],
        titleItems: [attachedTitle],
        transitionItems: [transition]
    )
    try await store.update { $0.timelines = [timeline] }
    let pipeline = VeloEditPipeline(store: store)

    let report = try await pipeline.applyEditorCommands(
        [.setFilter(.monochrome, .all)],
        timelineRange: 2...4
    )
    let edited = try #require((await store.manifest).timelines.last)

    #expect(report.hasChanges)
    let baseSegments = edited.items
        .filter { $0.assetID == baseAssetID && $0.overlay == nil }
        .sorted { $0.timelineStart < $1.timelineStart }
    #expect(baseSegments.count == 3)
    #expect(baseSegments.map(\.sourceStart) == [0, 2, 4])
    #expect(baseSegments.map(\.sourceDuration) == [2, 2, 6])
    #expect(baseSegments.map { $0.effectiveVideoAdjustments.filter } == [.none, .monochrome, .none])
    #expect(baseSegments.first?.id == base.id)
    #expect(edited.items.first(where: { $0.id == next.id }) == next)

    let validItemIDs = Set(edited.items.map(\.id))
    let editedOverlay = try #require(edited.items.first(where: { $0.id == overlay.id }))
    let trailingSegment = try #require(baseSegments.last)
    #expect(editedOverlay.timelineStart == overlay.timelineStart)
    #expect(editedOverlay.timelineDuration == overlay.timelineDuration)
    #expect(editedOverlay.sourceStart == overlay.sourceStart)
    #expect(editedOverlay.sourceDuration == overlay.sourceDuration)
    #expect(editedOverlay.effectiveVideoAdjustments == overlay.effectiveVideoAdjustments)
    #expect(editedOverlay.overlay?.baseItemID == trailingSegment.id)
    #expect(editedOverlay.overlay?.effectiveStartOffset == 2)
    #expect(editedOverlay.overlay?.baseItemID.map { validItemIDs.contains($0) } == true)

    #expect(edited.effectiveAudioClips.count == 3)
    #expect(edited.effectiveTelemetryItems.count == 3)
    #expect(edited.effectiveEffects.count == 3)
    #expect(edited.effectiveTitleItems.count == 3)
    #expect(edited.effectiveAudioClips.map(\.timelineStart) == [0, 2, 4])
    #expect(edited.effectiveTelemetryItems.map(\.timelineStart) == [0, 2, 4])
    #expect(edited.effectiveEffects.map(\.startTime) == [0, 2, 4])
    #expect(edited.effectiveTitleItems.map(\.startTime) == [0, 2, 4])

    func owningBaseSegment(at time: Double) -> TimelineItem? {
        baseSegments.first {
            time >= $0.timelineStart && time < $0.timelineStart + $0.timelineDuration
        }
    }
    for item in edited.effectiveAudioClips {
        let owner = owningBaseSegment(at: item.timelineStart + item.timelineDuration / 2)
        #expect(item.attachedToItemID == owner?.id)
        #expect(item.attachedToItemID.map { validItemIDs.contains($0) } == true)
        #expect(item.adjustments == attachedAudio.adjustments)
    }
    for item in edited.effectiveTelemetryItems {
        let owner = owningBaseSegment(at: item.timelineStart + item.timelineDuration / 2)
        #expect(item.targetClipID == owner?.id)
        #expect(item.targetClipID.map { validItemIDs.contains($0) } == true)
        #expect(item.settings == attachedTelemetry.settings)
    }
    for item in edited.effectiveEffects {
        let owner = owningBaseSegment(at: item.startTime + item.duration / 2)
        #expect(item.targetClipID == owner?.id)
        #expect(item.targetClipID.map { validItemIDs.contains($0) } == true)
        #expect(item.effectType == attachedEffect.effectType)
        #expect(item.intensity == attachedEffect.intensity)
    }
    for item in edited.effectiveTitleItems {
        let owner = owningBaseSegment(at: item.startTime + item.duration / 2)
        #expect(item.targetClipID == owner?.id)
        #expect(item.targetClipID.map { validItemIDs.contains($0) } == true)
        #expect(item.text == attachedTitle.text)
        #expect(item.style == attachedTitle.style)
    }

    let editedTransition = try #require(edited.effectiveTransitionItems.first(where: { $0.id == transition.id }))
    #expect(editedTransition.style == transition.style)
    #expect(editedTransition.duration == transition.duration)
    #expect(editedTransition.startTime == transition.startTime)
    #expect(editedTransition.outgoingClipID == trailingSegment.id)
    #expect(editedTransition.incomingClipID == next.id)
    #expect(validItemIDs.contains(editedTransition.outgoingClipID))
    #expect(validItemIDs.contains(editedTransition.incomingClipID))
}

@Test func timelineAICommentsNoOpDoesNotCreateCheckpointOrRevision() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("veloedit")
    defer { try? FileManager.default.removeItem(at: root) }

    let store = try ProjectStore(createAt: root, name: "AI no-op")
    let clip = TimelineItem(
        kind: .video,
        sourceDuration: 5,
        timelineStart: 0,
        timelineDuration: 5,
        videoAdjustments: VideoAdjustments(filter: .monochrome)
    )
    let timeline = Timeline(storyPlanID: UUID(), items: [clip])
    try await store.update { $0.timelines = [timeline] }
    let pipeline = VeloEditPipeline(store: store)
    let before = await store.snapshot()

    let report = try await pipeline.applyEditorCommands(
        [.setFilter(.monochrome, .all)],
        createCheckpoint: true
    )
    let after = await store.snapshot()

    #expect(!report.hasChanges)
    #expect(after.manifest.timelines == before.manifest.timelines)
    #expect(after.manifest.timelineCheckpoints == before.manifest.timelineCheckpoints)
    #expect(after.revision == before.revision)

    let localizedReport = try await pipeline.applyEditorCommands(
        [.setFilter(.monochrome, .all)],
        timelineRange: 2...4
    )
    let afterLocalizedNoOp = await store.snapshot()

    #expect(!localizedReport.hasChanges)
    #expect(afterLocalizedNoOp.manifest.timelines == before.manifest.timelines)
    #expect(afterLocalizedNoOp.manifest.timelineCheckpoints == before.manifest.timelineCheckpoints)
    #expect(afterLocalizedNoOp.revision == before.revision)
}

@Test func timelineAICommentsLocalRemoveTitlesPreservesModernTitlesOutsideRange() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("veloedit")
    defer { try? FileManager.default.removeItem(at: root) }

    let store = try ProjectStore(createAt: root, name: "Локальное удаление титров")
    let clip = TimelineItem(
        kind: .video,
        sourceDuration: 10,
        timelineStart: 0,
        timelineDuration: 10
    )
    let inside = TitleTimelineItem(
        kind: .title,
        text: "Удалить внутри кисти",
        startTime: 2,
        duration: 1
    )
    let outside = TitleTimelineItem(
        kind: .title,
        text: "Сохранить снаружи",
        startTime: 7,
        duration: 1
    )
    let timeline = Timeline(
        storyPlanID: UUID(),
        items: [clip],
        titleItems: [inside, outside]
    )
    try await store.update { $0.timelines = [timeline] }
    let pipeline = VeloEditPipeline(store: store)

    let report = try await pipeline.applyEditorCommands(
        [.removeTitles],
        timelineRange: 2...3
    )
    let edited = try #require((await store.manifest).timelines.last)

    #expect(report.hasChanges)
    #expect(!edited.effectiveTitleItems.contains { $0.id == inside.id })
    #expect(edited.effectiveTitleItems.contains(outside))
    #expect(edited.effectiveTitleItems.count == 1)
}

@Test func timelineAICommentsExecutorRemovesOnlyTargetedModernTransitionAndEffectObjects() {
    let first = TimelineItem(
        kind: .video,
        sourceDuration: 4,
        timelineStart: 0,
        timelineDuration: 4
    )
    let second = TimelineItem(
        kind: .video,
        sourceDuration: 4,
        timelineStart: 4,
        timelineDuration: 4
    )
    let third = TimelineItem(
        kind: .video,
        sourceDuration: 4,
        timelineStart: 8,
        timelineDuration: 4
    )
    let targetedEffect = EffectTimelineItem(
        effectType: .filmGrain,
        startTime: 0,
        duration: 4,
        targetClipID: first.id
    )
    let untouchedEffect = EffectTimelineItem(
        effectType: .glow,
        startTime: 4,
        duration: 4,
        targetClipID: second.id
    )
    let targetedTransition = TimelineTransitionItem(
        style: .crossDissolve,
        outgoingClipID: first.id,
        incomingClipID: second.id,
        startTime: 4
    )
    let untouchedTransition = TimelineTransitionItem(
        style: .blurDissolve,
        outgoingClipID: second.id,
        incomingClipID: third.id,
        startTime: 8
    )
    let timeline = Timeline(
        storyPlanID: UUID(),
        items: [first, second, third],
        effects: [targetedEffect, untouchedEffect],
        transitionItems: [targetedTransition, untouchedTransition]
    )

    let result = EditorCommandExecutor().apply(
        [.setEffect(nil, .first), .setTransition(nil, .number(2))],
        to: timeline
    )

    #expect(result.report.hasChanges)
    #expect(!result.timeline.effectiveEffects.contains { $0.id == targetedEffect.id })
    #expect(result.timeline.effectiveEffects.contains(untouchedEffect))
    #expect(!result.timeline.effectiveTransitionItems.contains { $0.id == targetedTransition.id })
    #expect(result.timeline.effectiveTransitionItems.contains(untouchedTransition))
    #expect(Set(result.report.affectedItemIDs).isSuperset(of: [targetedEffect.id, targetedTransition.id]))
}

@Test func timelineAICommentsMagicBrushPatternsAlternateInsideRange() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("veloedit")
    defer { try? FileManager.default.removeItem(at: root) }

    let store = try ProjectStore(createAt: root, name: "Чередование внутри кисти")
    let clips = (0..<5).map { index in
        TimelineItem(
            kind: .video,
            sourceStart: Double(index),
            sourceDuration: 1,
            timelineStart: Double(index),
            timelineDuration: 1
        )
    }
    let transitions = (1..<clips.count).map { index in
        TimelineTransitionItem(
            style: .fade,
            outgoingClipID: clips[index - 1].id,
            incomingClipID: clips[index].id,
            startTime: Double(index)
        )
    }
    let timeline = Timeline(
        storyPlanID: UUID(),
        items: clips,
        transitionItems: transitions
    )
    try await store.update { $0.timelines = [timeline] }
    let pipeline = VeloEditPipeline(store: store)
    let transitionPattern: [TransitionStyle] = [.crossDissolve, .blurDissolve]
    let effectPattern: [ClipEffect] = [.zoomIn, .mirror]

    let report = try await pipeline.applyEditorCommands(
        [
            .setTransitionPattern(transitionPattern, .all),
            .setEffectPattern(effectPattern, .all)
        ],
        timelineRange: 1...5
    )
    let edited = try #require((await store.manifest).timelines.last)
    let outside = try #require(edited.items.first(where: { $0.id == clips[0].id }))
    let inside = clips.dropFirst().compactMap { clip in
        edited.items.first(where: { $0.id == clip.id })
    }

    #expect(report.hasChanges)
    #expect(outside.transition == nil)
    #expect(outside.effect == nil)
    #expect(inside.count == 4)
    #expect(inside.compactMap(\.transition) == [
        TransitionStyle.crossDissolve.rawValue,
        TransitionStyle.blurDissolve.rawValue,
        TransitionStyle.crossDissolve.rawValue,
        TransitionStyle.blurDissolve.rawValue
    ])
    #expect(inside.compactMap(\.effect) == [
        ClipEffect.zoomIn.rawValue,
        ClipEffect.mirror.rawValue,
        ClipEffect.zoomIn.rawValue,
        ClipEffect.mirror.rawValue
    ])

    let transitionStylesByIncomingID = Dictionary(uniqueKeysWithValues: edited.effectiveTransitionItems.map {
        ($0.incomingClipID, $0.style)
    })
    #expect(clips.dropFirst().compactMap { transitionStylesByIncomingID[$0.id] } == [
        .crossDissolve,
        .blurDissolve,
        .crossDissolve,
        .blurDissolve
    ])
}

@Test func timelineAICommentsVariantSearchPreservesExplicitGrammarConstraints() throws {
    let asset = MediaAsset(
        originalURL: URL(fileURLWithPath: "/tmp/timeline-ai-constraints.mov"),
        kind: .video,
        byteSize: 1,
        contentHash: "timeline-ai-constraints",
        metadata: MediaMetadata(duration: 30, frameRate: 30, hasAudio: true)
    )
    let candidates = (0..<5).map { index in
        Candidate(
            assetID: asset.id,
            sourceStart: Double(index * 5),
            sourceDuration: 4,
            scores: ClipScores(
                quality: 0.82,
                interest: 0.70 + Double(index) * 0.04,
                action: 0.35 + Double(index) * 0.10,
                stability: 0.88,
                uniqueness: 0.84
            ),
            tags: [index.isMultiple(of: 2) ? "scenic" : "action"]
        )
    }
    let analyses = [AnalysisResult(
        assetID: asset.id,
        analyzedContentHash: asset.contentHash,
        candidates: candidates
    )]
    let autonomous = AutonomousDirectorEngine().decide(
        prompt: "Сделай лучший фильм",
        fallbackPreset: .story,
        requestedDuration: 16,
        assets: [asset],
        analyses: analyses,
        personalProfile: PersonalTasteProfile()
    )
    let exact = StoryConstraints(
        targetDuration: 16,
        targetClipCount: 4,
        allowSlowMotion: false,
        transitionFrequency: 0.01,
        pacing: 0.77
    )
    let search = StoryEngine().createPlanVariantSearch(
        prompt: "Сделай динамичнее, меньше переходов и без slow motion",
        preset: .story,
        constraints: exact,
        assets: [asset],
        analyses: analyses,
        minimumDistance: 0,
        autonomousDecision: autonomous,
        directorBrief: DirectorBrief(requestedDuration: 16, mood: .calm),
        lockedConstraints: [.pacing, .transitionFrequency, .allowSlowMotion]
    )

    #expect(!search.variants.isEmpty)
    #expect(search.variants.allSatisfy { abs($0.plan.constraints.pacing - 0.77) < 0.000_1 })
    #expect(search.variants.allSatisfy { abs($0.plan.constraints.transitionFrequency - 0.01) < 0.000_1 })
    #expect(search.variants.allSatisfy { !$0.plan.constraints.allowSlowMotion })
}

@Test func timelineAICommentsPreserveAssetBackedFreezeFrameDuration() async throws {
    let asset = MediaAsset(
        originalURL: URL(fileURLWithPath: "/tmp/timeline-ai-freeze.mov"),
        kind: .video,
        byteSize: 1,
        contentHash: "timeline-ai-freeze",
        metadata: MediaMetadata(duration: 12, frameRate: 30, hasAudio: true)
    )
    let first = TimelineItem(
        assetID: asset.id,
        kind: .video,
        sourceDuration: 2,
        timelineStart: 0,
        timelineDuration: 2
    )
    let freeze = TimelineItem(
        assetID: asset.id,
        kind: .video,
        sourceStart: 3,
        sourceDuration: 1 / 30,
        timelineStart: 2,
        timelineDuration: 3,
        freezeFrame: true
    )
    let tail = TimelineItem(
        assetID: asset.id,
        kind: .video,
        sourceStart: 4,
        sourceDuration: 2,
        timelineStart: 5,
        timelineDuration: 2
    )
    let story = StoryPlan(
        prompt: "Исходный фильм",
        preset: .story,
        constraints: StoryConstraints(targetDuration: 7),
        chapters: []
    )
    let timeline = Timeline(storyPlanID: story.id, items: [first, freeze, tail])
    let project = ProjectManifest(
        name: "Стоп-кадр",
        assets: [asset],
        storyPlans: [story],
        timelines: [timeline]
    )
    let input = NaturalLanguageDirectorInput(
        userRequest: "Сделай все клипы чёрно-белыми",
        currentProject: project,
        timeline: timeline
    )
    let director = NaturalLanguageDirector()
    let globalResult = director.execute(plan: director.plan(input: input), input: input)
    let globalFreeze = try #require(globalResult.timeline.items.first { $0.id == freeze.id })
    #expect(abs(globalFreeze.timelineDuration - 3) < 0.000_1)

    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("veloedit")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try ProjectStore(createAt: root, name: "Локальный стоп-кадр")
    try await store.update { manifest in
        manifest.assets = [asset]
        manifest.storyPlans = [story]
        manifest.timelines = [timeline]
    }
    let pipeline = VeloEditPipeline(store: store)
    _ = try await pipeline.applyEditorCommands(
        [.setFilter(.monochrome, .all)],
        timelineRange: 0...1
    )
    let localTimeline = try #require((await store.manifest).timelines.last)
    let localFreeze = try #require(localTimeline.items.first { $0.id == freeze.id })
    #expect(abs(localFreeze.timelineDuration - 3) < 0.000_1)
    #expect(abs(localFreeze.timelineStart - 2) < 0.000_1)
}

@Test func timelineAICommentsSplitLocalRangeWithoutDamagingAttachments() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("veloedit")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try ProjectStore(createAt: root, name: "Безопасный split")
    let clip = TimelineItem(
        kind: .video,
        sourceDuration: 8,
        timelineStart: 0,
        timelineDuration: 8
    )
    let audio = TimelineAudioClip(
        title: "Привязанный звук",
        role: .naturalSound,
        sourceDuration: 8,
        timelineStart: 0,
        timelineDuration: 8,
        attachedToItemID: clip.id,
        attachmentOffset: 0
    )
    let title = TitleTimelineItem(
        kind: .title,
        text: "Привязанный титр",
        startTime: 0,
        duration: 8,
        targetClipID: clip.id
    )
    let timeline = Timeline(
        storyPlanID: UUID(),
        items: [clip],
        audioClips: [audio],
        titleItems: [title]
    )
    try await store.update { $0.timelines = [timeline] }
    let pipeline = VeloEditPipeline(store: store)
    let before = await store.snapshot()

    let report = try await pipeline.applyEditorCommands(
        [.split(.all)],
        timelineRange: 2...6
    )
    let after = await store.snapshot()

    #expect(report.hasChanges)
    #expect(report.ignored.isEmpty)
    let result = try #require(after.manifest.timelines.last)
    #expect(result.items.map(\.timelineDuration) == [2, 2, 2, 2])
    #expect(result.effectiveAudioClips.map(\.timelineDuration) == [2, 2, 2, 2])
    #expect(result.effectiveAudioClips.map(\.sourceStart) == [0, 2, 4, 6])
    #expect(result.effectiveTitleItems.map(\.duration) == [2, 2, 2, 2])
    for (clip, title) in zip(result.items, result.effectiveTitleItems) {
        #expect(title.targetClipID == clip.id)
        #expect(title.startTime == clip.timelineStart)
    }
    #expect((after.manifest.timelineCheckpoints?.count ?? 0) == (before.manifest.timelineCheckpoints?.count ?? 0) + 1)
    #expect(after.revision > before.revision)
}
