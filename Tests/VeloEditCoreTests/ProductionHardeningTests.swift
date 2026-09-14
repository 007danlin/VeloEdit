import Foundation
import AVFoundation
import CoreGraphics
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import VeloEditCore

private func productionTimeline(itemCount: Int = 4) -> Timeline {
    let items = (0..<itemCount).map { index in
        TimelineItem(
            assetID: UUID(),
            kind: .video,
            sourceStart: Double(index),
            sourceDuration: 3,
            timelineStart: Double(index * 3),
            timelineDuration: 3
        )
    }
    return Timeline(storyPlanID: UUID(), width: 3_840, height: 2_160, items: items)
}

@Test func optimisticTimelineMutationsAreSynchronousAndKeepMagneticTiming() {
    var timeline = productionTimeline(itemCount: 300)
    let movedID = timeline.items[240].id
    let started = ContinuousClock.now
    #expect(TimelineMutationEngine.movePrimaryItem(in: &timeline, id: movedID, toPrimaryIndex: 3))
    let elapsed = started.duration(to: .now).components
    let milliseconds = Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15

    #expect(timeline.items[3].id == movedID)
    #expect(zip(timeline.items, timeline.items.dropFirst()).allSatisfy {
        abs(($0.timelineStart + $0.timelineDuration) - $1.timelineStart) < 0.000_1
    })
    // This is a state-mutation budget, not a machine-independent benchmark;
    // the generous ceiling catches accidental disk/media work on this path.
    #expect(milliseconds < 50)
}

@Test func optimisticTimelineInsertionsAppearImmediatelyAndStayNormalized() {
    var timeline = productionTimeline(itemCount: 3)
    let inserted = TimelineItem(
        assetID: UUID(),
        kind: .video,
        sourceDuration: 2,
        timelineStart: 99,
        timelineDuration: 2
    )
    #expect(TimelineMutationEngine.insertPrimaryItem(in: &timeline, item: inserted, atPrimaryIndex: 1))
    #expect(timeline.items.filter { $0.overlay == nil }[1].id == inserted.id)
    #expect(zip(timeline.items.filter { $0.overlay == nil }, timeline.items.filter { $0.overlay == nil }.dropFirst()).allSatisfy {
        abs(($0.timelineStart + $0.timelineDuration) - $1.timelineStart) < 0.000_1
    })

    let connected = TimelineItem(
        assetID: UUID(),
        kind: .video,
        sourceDuration: 20,
        timelineStart: 0,
        timelineDuration: 20,
        overlay: OverlaySettings(style: .cutaway)
    )
    #expect(TimelineMutationEngine.insertConnectedItem(in: &timeline, item: connected, atTimelineStart: 1.1))
    let connectedResult = timeline.items.first { $0.id == connected.id }
    #expect(connectedResult?.overlay?.baseItemID != nil)
    #expect(abs((connectedResult?.timelineStart ?? -1) - 1.1) < 0.04)
    #expect((connectedResult?.timelineStart ?? 0) + (connectedResult?.timelineDuration ?? 0) <= timeline.duration + 0.000_1)

    let audio = TimelineAudioClip(
        trackID: UUID(),
        title: "Drop",
        role: .music,
        sourceDuration: 30,
        timelineStart: 2,
        timelineDuration: 30
    )
    #expect(TimelineMutationEngine.insertAudioClip(in: &timeline, clip: audio))
    #expect(timeline.effectiveAudioClips.contains {
        $0.id == audio.id && abs($0.timelineStart - 2) < 0.000_1 && $0.timelineEnd <= timeline.duration + 0.000_1
    })

    let telemetry = TimelineTelemetryItem(
        targetClipID: inserted.id,
        linkedAssetID: inserted.assetID,
        timelineStart: 0,
        timelineDuration: 30
    )
    #expect(TimelineMutationEngine.insertTelemetry(in: &timeline, item: telemetry))
    #expect(timeline.effectiveTelemetryItems.contains { $0.id == telemetry.id && $0.timelineEnd <= timeline.duration + 0.000_1 })

    let effect = EffectTimelineItem(effectType: .vignette, startTime: 1, duration: 2)
    let title = TitleTimelineItem(kind: .title, text: "Сразу", startTime: 1, duration: 2)
    #expect(TimelineMutationEngine.insertEffect(in: &timeline, effect: effect))
    #expect(TimelineMutationEngine.insertTitle(in: &timeline, title: title))
    #expect(timeline.effectiveEffects.contains { $0.id == effect.id })
    #expect(timeline.effectiveTitleItems.contains { $0.id == title.id })

    let primaries = timeline.items.filter { $0.overlay == nil }
    let transition = TimelineTransitionItem(
        style: .crossDissolve,
        outgoingClipID: primaries[0].id,
        incomingClipID: primaries[1].id,
        startTime: 0
    )
    #expect(TimelineMutationEngine.replaceTransition(
        in: &timeline,
        incomingClipID: primaries[1].id,
        with: transition
    ))
    #expect(timeline.effectiveTransitionItems.contains { $0.id == transition.id })
    #expect(timeline.items.first { $0.id == primaries[1].id }?.transition == TransitionStyle.crossDissolve.rawValue)
}

@Test func previewInvalidationDistinguishesOverlayOnlyAndStructuralEdits() {
    let original = productionTimeline()
    var titleOnly = original
    titleOnly.titleItems = [TitleTimelineItem(kind: .title, text: "Новый титр", startTime: 1, duration: 2)]
    let overlayPlan = TimelineInvalidationPlanner.plan(from: original, to: titleOnly)
    #expect(overlayPlan.layers == [.titles])
    #expect(!overlayPlan.requiresCompositionRebuild)
    #expect(overlayPlan.canReuseDecodedVideo)

    var trimmed = original
    let id = trimmed.items[0].id
    _ = TimelineMutationEngine.updateItem(in: &trimmed, id: id) {
        $0.timelineDuration = 2
        $0.sourceDuration = 2
    }
    let structuralPlan = TimelineInvalidationPlanner.plan(from: original, to: trimmed)
    #expect(structuralPlan.layers.contains(.sourceVideo))
    #expect(structuralPlan.requiresCompositionRebuild)
    #expect(!structuralPlan.canReuseDecodedVideo)
}

@Test func projectStoreRejectsStaleBackgroundCommit() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString).appendingPathExtension("veloedit")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try ProjectStore(createAt: root, name: "Revision")
    let snapshot = await store.snapshot()
    try await store.update { $0.name = "Новая ручная правка" }

    do {
        try await store.update(ifRevision: snapshot.revision) { $0.name = "Устаревший AI" }
        Issue.record("Устаревшая транзакция не должна быть зафиксирована")
    } catch let error as ProjectStoreError {
        guard case .staleRevision = error else {
            Issue.record("Ожидалась staleRevision, получено \(error)")
            return
        }
    }
    #expect(await store.manifest.name == "Новая ручная правка")
}

@Test func workspaceAutosaveDoesNotInvalidateBackgroundCommit() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString).appendingPathExtension("veloedit")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try ProjectStore(createAt: root, name: "Background build")
    let workspaceState = ProjectWorkspaceState(
        prompt: "Собери динамичный фильм",
        preset: .adventure,
        targetMinutes: 2
    )

    try await store.updateWorkspaceState(workspaceState)
    let snapshot = await store.snapshot()
    var auxiliary = workspaceState
    auxiliary.directorDraft = "Черновик"
    try await store.updateWorkspaceState(auxiliary)
    try await store.update(ifRevision: snapshot.revision) { project in
        project.name = "Готовый фоновый результат"
    }

    let manifest = await store.manifest
    #expect(manifest.name == "Готовый фоновый результат")
    #expect(manifest.workspaceState == auxiliary)
}

@Test func pipelineDiscardsOutOfOrderOptimisticCommits() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString).appendingPathExtension("veloedit")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try ProjectStore(createAt: root, name: "Ordering")
    let original = productionTimeline()
    try await store.update { $0.timelines = [original] }
    let pipeline = VeloEditPipeline(store: store)

    var newest = original
    newest.versionName = "revision-8"
    var stale = original
    stale.versionName = "revision-7"
    #expect(try await pipeline.commitLatestTimeline(newest, clientRevision: 8))
    #expect(try await pipeline.commitLatestTimeline(stale, clientRevision: 7) == false)
    #expect(await store.manifest.timelines.last?.versionName == "revision-8")
}

@Test func productionCachesHaveHardMemoryBounds() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let frameCache = FrameCache(rootURL: root.appendingPathComponent("frames"), maximumMemoryEntries: 3)
    for index in 0..<12 {
        let sample = VisualFrameSample(
            timestamp: Double(index), motion: 0.4, exposure: 0.7, detail: 0.8,
            labels: ["frame"], labelConfidence: 0.9, faceCount: 0,
            jpegBase64: "", histogram: [0.2, 0.8], luminanceFingerprint: [20, 80]
        )
        try await frameCache.store(sample, for: FrameCacheKey(
            sourceFile: "source.mov", timestamp: Double(index), resolution: 320, processingPurpose: .vision
        ))
    }
    #expect(await frameCache.memoryEntryCount() == 3)

    let deepCache = DeepAnalysisCache(rootURL: root.appendingPathComponent("deep"), maximumMemoryEntries: 2)
    for index in 0..<8 {
        try await deepCache.store(DeepMediaCacheRecord(contentHash: "asset-\(index)"))
    }
    #expect(await deepCache.memoryEntryCount() == 2)
}

@Test func frameQualityRejectsTrueBlackButKeepsDarkTexture() {
    let black = FrameQualityInspector.assess(luma: Array(repeating: 0, count: 256))
    let darkTexture = FrameQualityInspector.assess(luma: (0..<256).map { UInt8($0 % 22) })
    let normal = FrameQualityInspector.assess(luma: (0..<256).map { UInt8(60 + $0 % 80) })
    #expect(black.isBlack)
    #expect(!darkTexture.isBlack)
    #expect(!normal.isBlack)
    #expect(darkTexture.lumaDeviation > black.lumaDeviation)
}

@Test func interactionLatencySummaryUsesP95BudgetsAndBoundedHistory() async {
    let recorder = InteractionLatencyRecorder(maximumSamples: 5)
    for index in 0..<8 {
        await recorder.record(InteractionLatencySample(
            name: "drag", stateUpdateMilliseconds: Double(index + 1), visualFeedbackMilliseconds: Double(index + 10)
        ))
    }
    let summary = await recorder.summary()
    #expect(summary.sampleCount == 5)
    #expect(summary.p95StateUpdateMilliseconds == 8)
    #expect(summary.p95VisualFeedbackMilliseconds == 17)
    #expect(summary.stateUpdateBudgetPass)
    #expect(summary.visualFeedbackBudgetPass)
}

@Test func productionCacheIdentityIsStableAndInputSensitive() {
    let first = ProductionCacheIdentity.hash(["photo", "hash", "1920x1080", "4000"])
    #expect(first == ProductionCacheIdentity.hash(["photo", "hash", "1920x1080", "4000"]))
    #expect(first != ProductionCacheIdentity.hash(["photo", "hash", "1280x720", "4000"]))
}

@Test func productionPlaybackActuallyReusesDerivedPhotoMedia() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let imageURL = root.appendingPathComponent("fixture.png")
    let context = try #require(CGContext(
        data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 256,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.setFillColor(CGColor(red: 0.15, green: 0.55, blue: 0.9, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
    let image = try #require(context.makeImage())
    let destination = try #require(CGImageDestinationCreateWithURL(
        imageURL as CFURL, UTType.png.identifier as CFString, 1, nil
    ))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))

    let asset = MediaAsset(
        originalURL: imageURL, kind: .photo, byteSize: 1, contentHash: "persistent-photo",
        metadata: MediaMetadata(width: 64, height: 48, hasAudio: false)
    )
    let item = TimelineItem(
        assetID: asset.id, kind: .photo, sourceDuration: 0.3,
        timelineStart: 0, timelineDuration: 0.3
    )
    let timeline = Timeline(storyPlanID: UUID(), width: 320, height: 180, frameRate: 10, items: [item])
    let cacheURL = root.appendingPathComponent("preview-cache")
    do {
        let first = try await PlaybackEngine().build(
            timeline: timeline, assets: [asset], derivedMediaCacheURL: cacheURL
        )
        #expect(first.derivedMediaCacheMisses == 1)
        #expect(first.derivedMediaCacheHits == 0)
        let second = try await PlaybackEngine().build(
            timeline: timeline, assets: [asset], derivedMediaCacheURL: cacheURL
        )
        #expect(second.derivedMediaCacheHits == 1)
        #expect(second.derivedMediaCacheMisses == 0)
        #expect(second.renderedItemCount == 1)
        #expect((try await second.composition.load(.duration)).seconds > 0.2)
    } catch DerivedMediaError.exportFailed(let reason) where reason.contains("-11834") || reason.contains("-12903") {
        // A headless host can lack VideoToolbox. Signed-app verification covers
        // this codec-dependent branch on a normal macOS runtime.
        return
    }
}

@Test func previewGeometryContractKeepsTheWholeCameraFrame() {
    let fitted = PreviewGeometryContract.assess(
        sourceWidth: 5_312,
        sourceHeight: 2_988,
        viewportWidth: 640,
        viewportHeight: 640,
        contentMode: .aspectFit
    )
    let filled = PreviewGeometryContract.assess(
        sourceWidth: 5_312,
        sourceHeight: 2_988,
        viewportWidth: 640,
        viewportHeight: 640,
        contentMode: .aspectFill
    )

    #expect(fitted.preservesCompleteSource)
    #expect(fitted.cropFraction < 0.000_1)
    #expect(!filled.preservesCompleteSource)
    #expect(filled.cropFraction > 0.43)
    #expect(PreviewDeliveryProfile.production.sourcePreviewContentMode == .aspectFit)
    #expect(PreviewDeliveryProfile.production.timelinePreviewContentMode == .aspectFit)
}

@Test func deliveryContractRepairsExplicitMusicTitleAndSourceAudioRequirements() {
    let assetID = UUID()
    let items = (0..<2).map { index in
        TimelineItem(
            assetID: assetID,
            kind: .video,
            sourceStart: Double(index * 5),
            sourceDuration: 5,
            timelineStart: Double(index * 5),
            timelineDuration: 5
        )
    }
    let sourceAudio = TimelineAudioClip(
        assetID: assetID,
        title: "J/L-cut · диалог",
        role: .dialogue,
        sourceDuration: 5,
        timelineStart: 0,
        timelineDuration: 5
    )
    let musicAudio = TimelineAudioClip(
        trackID: UUID(),
        title: "Музыка",
        role: .music,
        sourceDuration: 10,
        timelineStart: 0,
        timelineDuration: 10
    )
    let plan = StoryPlan(
        prompt: "Ровно 10 секунд, без музыки, без титров, звук исходников приглушить",
        preset: .cinematic,
        constraints: StoryConstraints(targetDuration: 10),
        chapters: []
    )
    let timeline = Timeline(
        storyPlanID: plan.id,
        items: items,
        audioClips: [sourceAudio, musicAudio],
        titleItems: [TitleTimelineItem(
            kind: .chapter,
            text: "Ключевой момент",
            startTime: 0,
            duration: 3,
            explanation: ["Автоматический режиссёрский титр"]
        )],
        music: MusicDirective(style: .cinematic, bpm: 82),
        originalAudioVolume: 1
    )

    let result = TimelineDeliveryContract().validateAndRepair(
        timeline: timeline,
        plan: plan,
        assets: []
    )

    #expect(result.canPersist)
    #expect(result.timeline.music == nil)
    #expect(result.timeline.effectiveAudioClips.count == 1)
    #expect(result.timeline.effectiveAudioClips.first?.role == .dialogue)
    #expect(abs((result.timeline.effectiveAudioClips.first?.adjustments.effectiveVolume ?? 1) - DirectorSourceAudioPolicy.duck.volume) < 0.000_1)
    #expect(abs(result.timeline.effectiveOriginalAudioVolume - DirectorSourceAudioPolicy.duck.volume) < 0.000_1)
    #expect(result.timeline.effectiveTitleItems.isEmpty)
    #expect(result.issues.contains { $0.kind == .forbiddenMusic && $0.resolution == .repaired })
    #expect(result.issues.contains { $0.kind == .forbiddenTitles && $0.resolution == .repaired })
    #expect(result.issues.contains { $0.kind == .originalAudioVolume && $0.resolution == .repaired })
}

@Test func deliveryContractBlocksMismatchedExactDurationAndMomentCount() {
    let plan = StoryPlan(
        prompt: "Сделай фильм ровно 10 секунд, используй 3 момента",
        preset: .story,
        constraints: StoryConstraints(targetDuration: 10, targetClipCount: 3),
        chapters: []
    )
    let timeline = Timeline(
        storyPlanID: plan.id,
        items: (0..<2).map { index in
            TimelineItem(
                assetID: UUID(),
                kind: .video,
                sourceDuration: 4,
                timelineStart: Double(index * 4),
                timelineDuration: 4
            )
        }
    )

    let result = TimelineDeliveryContract().validateAndRepair(
        timeline: timeline,
        plan: plan,
        assets: []
    )

    #expect(!result.canPersist)
    #expect(result.blockingIssues.contains { $0.kind == .exactDuration })
    #expect(result.blockingIssues.contains { $0.kind == .exactClipCount })
}

@Test func directorBriefContractRepairsFormatSpecificMusicAudioAndTitlesButBlocksOriginalRequestedDuration() {
    let requestedTrackID = UUID()
    let brief = DirectorBrief(
        canvasFormat: .portrait9x16,
        requestedDuration: 10,
        mood: .cinematic,
        musicPolicy: .specificTrack,
        musicTrackID: requestedTrackID,
        sourceAudioPolicy: .mute,
        titlePolicy: .none
    )
    // Simulates an optimizer that shortened the plan. The original brief must
    // remain the delivery target and therefore cannot silently pass at 8 s.
    let plan = StoryPlan(
        prompt: "Фильм",
        preset: .story,
        constraints: StoryConstraints(targetDuration: 8),
        chapters: [],
        directorBrief: brief
    )
    let assetID = UUID()
    let wrongTrackID = UUID()
    let timeline = Timeline(
        storyPlanID: plan.id,
        width: 1920,
        height: 1080,
        items: [TimelineItem(
            assetID: assetID,
            kind: .video,
            sourceDuration: 8,
            timelineStart: 0,
            timelineDuration: 8,
            audioAdjustments: AudioAdjustments(volume: 0.4)
        )],
        audioClips: [TimelineAudioClip(
            assetID: assetID,
            title: "Исходный звук",
            role: .naturalSound,
            sourceDuration: 8,
            timelineStart: 0,
            timelineDuration: 8
        )],
        titleItems: [TitleTimelineItem(
            kind: .chapter,
            text: "Поездка",
            startTime: 0,
            duration: 2,
            explanation: ["Автоматический режиссёрский титр"]
        )],
        music: MusicDirective(style: .energetic, bpm: 120, trackID: wrongTrackID),
        originalAudioVolume: 1
    )

    let result = TimelineDeliveryContract().validateAndRepair(
        timeline: timeline,
        plan: plan,
        assets: []
    )

    #expect(result.timeline.width == 1080)
    #expect(result.timeline.height == 1920)
    #expect(result.timeline.music?.trackID == requestedTrackID)
    #expect(result.timeline.effectiveOriginalAudioVolume == 0)
    #expect(result.timeline.items.first?.effectiveAudioAdjustments.muted == true)
    #expect(result.timeline.effectiveAudioClips.isEmpty)
    #expect(result.timeline.effectiveTitleItems.isEmpty)
    #expect(!result.canPersist)
    #expect(result.blockingIssues.contains { $0.kind == .exactDuration })
    #expect(result.issues.contains { $0.kind == .canvasFormat && $0.resolution == .repaired })
    #expect(result.issues.contains { $0.kind == .musicPolicy && $0.resolution == .repaired })
}

@Test func directorBriefContractEnforcesSoftMusicDuckAndPreservesEveryKeyTitle() {
    let brief = DirectorBrief(
        requestedDuration: 120,
        musicPolicy: .soft,
        sourceAudioPolicy: .duck,
        titlePolicy: .keyOnly
    )
    let plan = StoryPlan(
        prompt: "Фильм",
        preset: .story,
        constraints: StoryConstraints(targetDuration: 120),
        chapters: [],
        directorBrief: brief
    )
    let assetID = UUID()
    let titles = zip([0.0, 10, 45, 80], ["Старт маршрута", "Первый подъём", "Главный спуск", "Финиш"]).map { start, text in
        TitleTimelineItem(
            kind: .chapter,
            text: text,
            startTime: start,
            duration: 2,
            explanation: ["Автоматический режиссёрский титр"]
        )
    }
    let timeline = Timeline(
        storyPlanID: plan.id,
        items: [TimelineItem(
            assetID: assetID,
            kind: .video,
            sourceDuration: 120,
            timelineStart: 0,
            timelineDuration: 120
        )],
        audioClips: [TimelineAudioClip(
            assetID: assetID,
            title: "Диалог",
            role: .dialogue,
            sourceDuration: 120,
            timelineStart: 0,
            timelineDuration: 120
        )],
        titleItems: titles,
        music: MusicDirective(style: .energetic, bpm: 126, volume: 0.4),
        originalAudioVolume: 1
    )

    let result = TimelineDeliveryContract().validateAndRepair(
        timeline: timeline,
        plan: plan,
        assets: []
    )

    #expect(result.canPersist)
    #expect(result.timeline.music?.style == .calm)
    #expect((result.timeline.music?.volume ?? 1) <= 0.14)
    #expect(abs(result.timeline.effectiveOriginalAudioVolume - DirectorSourceAudioPolicy.duck.volume) < 0.000_1)
    #expect(abs((result.timeline.effectiveAudioClips.first?.adjustments.effectiveVolume ?? 1) - DirectorSourceAudioPolicy.duck.volume) < 0.000_1)
    #expect(result.timeline.audioDucking?.enabled == false)
    #expect(result.timeline.effectiveTitleItems.map(\.id) == titles.map(\.id))
    #expect(result.timeline.effectiveTitleItems.allSatisfy {
        !SmartTitleEngine.isMeaningless($0.text) && !SmartTitleEngine.isStructuralPlaceholder($0.text)
    })
}

@Test func deliveryContractRemovesPlaceholderAndCollidingAutomaticTitles() {
    let plan = StoryPlan(
        prompt: "Добавь только ключевые титры",
        preset: .cinematic,
        constraints: StoryConstraints(targetDuration: 10),
        chapters: []
    )
    let timeline = Timeline(
        storyPlanID: plan.id,
        items: [TimelineItem(assetID: UUID(), kind: .video, sourceDuration: 10, timelineStart: 0, timelineDuration: 10)],
        titleItems: [
            TitleTimelineItem(
                kind: .chapter,
                text: "Ключевой момент",
                startTime: 0,
                duration: 3,
                explanation: ["Автоматический режиссёрский титр"]
            ),
            TitleTimelineItem(
                kind: .chapter,
                text: "Поездка на багги",
                startTime: 1,
                duration: 4,
                explanation: ["Автоматический режиссёрский титр"]
            ),
            TitleTimelineItem(
                kind: .chapter,
                text: "Велопрогулка",
                startTime: 2,
                duration: 4,
                explanation: ["Автоматический режиссёрский титр"]
            )
        ]
    )

    let result = TimelineDeliveryContract().validateAndRepair(
        timeline: timeline,
        plan: plan,
        assets: []
    )

    #expect(result.canPersist)
    #expect(result.timeline.effectiveTitleItems.map(\.text) == ["Поездка на багги"])
    #expect(result.issues.contains { $0.kind == .generatedTitleQuality && $0.resolution == .repaired })
}

@Test func deliveryContractRequiresStableRealtimePathForDecorated5KCameraMedia() {
    let asset = MediaAsset(
        originalURL: URL(fileURLWithPath: "/tmp/camera.mov"),
        kind: .video,
        byteSize: 1,
        contentHash: "camera-5k",
        metadata: MediaMetadata(width: 5_312, height: 2_988, codec: "hevc", hasAudio: true)
    )
    let plan = StoryPlan(
        prompt: "Кинематографичный фильм",
        preset: .cinematic,
        constraints: StoryConstraints(targetDuration: 10),
        chapters: []
    )
    let timeline = Timeline(
        storyPlanID: plan.id,
        width: 1_920,
        height: 1_080,
        items: [TimelineItem(assetID: asset.id, kind: .video, sourceDuration: 10, timelineStart: 0, timelineDuration: 10)],
        titleItems: [TitleTimelineItem(
            kind: .chapter,
            text: "Поездка на багги",
            startTime: 0,
            duration: 2,
            explanation: ["Автоматический режиссёрский титр"]
        )]
    )
    let unsafe = PreviewDeliveryProfile(
        sourcePreviewContentMode: .aspectFit,
        timelinePreviewContentMode: .aspectFit,
        usesStableRealtimePlayback: false
    )

    let blocked = TimelineDeliveryContract().validateAndRepair(
        timeline: timeline,
        plan: plan,
        assets: [asset],
        previewProfile: unsafe
    )
    let stable = TimelineDeliveryContract().validateAndRepair(
        timeline: timeline,
        plan: plan,
        assets: [asset]
    )

    #expect(!blocked.canPersist)
    #expect(blocked.blockingIssues.contains { $0.kind == .unstableHighResolutionPreview })
    #expect(stable.canPersist)
    #expect(stable.issues.contains {
        $0.kind == .unstableHighResolutionPreview && $0.resolution == .repaired
    })
}

@Test func deliveryContractBlocksConfirmedRenderedBlackFramesButNotMissingSamples() {
    let plan = StoryPlan(
        prompt: "Короткий фильм",
        preset: .story,
        constraints: StoryConstraints(targetDuration: 10),
        chapters: []
    )
    var timeline = Timeline(
        storyPlanID: plan.id,
        items: [TimelineItem(assetID: UUID(), kind: .video, sourceDuration: 10, timelineStart: 0, timelineDuration: 10)]
    )
    let score = PerceptualScore(
        continuity: 1,
        composition: 1,
        momentCompleteness: 1,
        pacing: 1,
        musicAlignment: 1,
        audioContinuity: 1,
        visualVariety: 1,
        storyCoherence: 1,
        effectQuality: 1,
        titleQuality: 1,
        technicalIntegrity: 0
    )
    let finding = PerceptualFinding(
        severity: .critical,
        scope: .film,
        timelineRange: PerceptualTimeRange(start: 0, end: 5),
        type: .blackFrame,
        confidence: 1,
        explanation: "Decoded frame is black"
    )
    func run(sampleCount: Int) -> DirectorRunSummary {
        let summary = PerceptualReviewSummary(
            perceptualReviewIterations: 1,
            findings: [finding],
            repairsAttempted: 0,
            repairsAccepted: 0,
            repairsRejected: 0,
            rollbackCount: 0,
            initialScore: score,
            finalScore: score,
            cutScores: [],
            repairAttempts: [],
            renderedFrameSampleCount: sampleCount,
            renderReviewStatus: sampleCount == 0 ? "render-built-no-decodable-samples" : "selective-render-reviewed"
        )
        return DirectorRunSummary(
            reviewIterations: 1,
            appliedToolNames: [],
            decisionReasons: [],
            rejectedOperations: [],
            initialReview: DirectorReview(score: 1, issues: []),
            finalReview: DirectorReview(score: 1, issues: []),
            perceptualReview: summary
        )
    }

    timeline.directorRun = run(sampleCount: 1)
    let confirmed = TimelineDeliveryContract().validateAndRepair(timeline: timeline, plan: plan, assets: [])
    timeline.directorRun = run(sampleCount: 0)
    let noSamples = TimelineDeliveryContract().validateAndRepair(timeline: timeline, plan: plan, assets: [])

    #expect(!confirmed.canPersist)
    #expect(confirmed.blockingIssues.contains { $0.kind == .renderedBlackFrame })
    #expect(noSamples.canPersist)
    #expect(!noSamples.issues.contains { $0.kind == .renderedBlackFrame })
}

@Test func deliveryContractRejectsCroppingPreviewConfiguration() {
    let plan = StoryPlan(
        prompt: "Фильм",
        preset: .story,
        constraints: StoryConstraints(targetDuration: 10),
        chapters: []
    )
    let timeline = Timeline(
        storyPlanID: plan.id,
        items: [TimelineItem(assetID: UUID(), kind: .video, sourceDuration: 10, timelineStart: 0, timelineDuration: 10)]
    )
    let profile = PreviewDeliveryProfile(
        sourcePreviewContentMode: .aspectFill,
        timelinePreviewContentMode: .aspectFill,
        usesStableRealtimePlayback: true
    )

    let result = TimelineDeliveryContract().validateAndRepair(
        timeline: timeline,
        plan: plan,
        assets: [],
        previewProfile: profile
    )

    #expect(!result.canPersist)
    #expect(result.blockingIssues.contains { $0.kind == .sourcePreviewCrop })
    #expect(result.blockingIssues.contains { $0.kind == .timelinePreviewCrop })
}

@Test func deliveryContractValidatesCanonicalTagCoverageSharesAndRoleAnchors() {
    let cyclingAssetID = UUID()
    let buggyAssetID = UUID()
    let cyclingCandidate = Candidate(
        assetID: cyclingAssetID,
        sourceStart: 0,
        sourceDuration: 8,
        scores: ClipScores(quality: 0.8, interest: 0.8, action: 0.7, stability: 0.8),
        tags: ["bicycle"]
    )
    // The low-level classifier did not name this activity. SourceMap and the
    // confirmed chapter provide the canonical buggy provenance instead.
    let buggyCandidate = Candidate(
        assetID: buggyAssetID,
        sourceStart: 0,
        sourceDuration: 4,
        scores: ClipScores(quality: 0.8, interest: 0.9, action: 0.9, stability: 0.7),
        tags: ["vehicle"]
    )
    let analyses = [
        AnalysisResult(assetID: cyclingAssetID, analyzedContentHash: "cycling", candidates: [cyclingCandidate]),
        AnalysisResult(assetID: buggyAssetID, analyzedContentHash: "buggy", candidates: [buggyCandidate])
    ]
    let sourceMap = SourceMap(entries: [], activityGroups: [
        SourceActivityGroup(
            id: UUID(),
            order: 0,
            title: "Велопрогулка",
            assetIDs: [cyclingAssetID],
            confidence: 0.9,
            evidence: []
        ),
        SourceActivityGroup(
            id: UUID(),
            order: 1,
            title: "Багги",
            assetIDs: [buggyAssetID],
            confidence: 0.9,
            evidence: []
        )
    ])
    let diagnostics = EventRunDiagnostics(
        eventsDetected: 2,
        eventConfidence: [:],
        eventTitles: [],
        eventDateRanges: [],
        eventOrder: [],
        sceneCount: 2,
        crossDeviceMatches: 0,
        sourceMap: sourceMap
    )
    var constraints = StoryConstraints(
        targetDuration: 12,
        includeTags: ["bike", "buggy"],
        excludeTags: ["fishing"],
        maximumTagShares: ["bike": 0.70],
        preferredIntroTags: ["bike"],
        preferredClimaxTags: ["buggy"]
    )
    let plan = StoryPlan(
        prompt: "Велосипед в начале, багги — кульминация, без рыбалки, велосипеда максимум 70%",
        preset: .adventure,
        constraints: constraints,
        chapters: [
            StoryChapter(title: "Велопрогулка", candidateIDs: [cyclingCandidate.id], role: .intro),
            StoryChapter(title: "Багги", candidateIDs: [buggyCandidate.id], role: .climax)
        ],
        eventStory: EventStoryPlan(entries: [], diagnostics: diagnostics)
    )
    let timeline = Timeline(storyPlanID: plan.id, items: [
        TimelineItem(
            candidateID: cyclingCandidate.id,
            assetID: cyclingAssetID,
            kind: .video,
            sourceDuration: 4,
            timelineStart: 0,
            timelineDuration: 4,
            storyRole: .intro
        ),
        TimelineItem(
            candidateID: buggyCandidate.id,
            assetID: buggyAssetID,
            kind: .video,
            sourceDuration: 4,
            timelineStart: 4,
            timelineDuration: 4,
            storyRole: .climax
        ),
        TimelineItem(
            candidateID: cyclingCandidate.id,
            assetID: cyclingAssetID,
            kind: .video,
            sourceStart: 4,
            sourceDuration: 4,
            timelineStart: 8,
            timelineDuration: 4,
            storyRole: .outro
        )
    ])

    let valid = TimelineDeliveryContract().validateAndRepair(
        timeline: timeline,
        plan: plan,
        assets: [],
        analyses: analyses
    )
    #expect(valid.canPersist)

    constraints.includeTags.insert("sunset")
    constraints.excludeTags.insert("bike")
    constraints.maximumTagShares["bike"] = 0.50
    constraints.preferredClimaxTags = ["bike"]
    let invalidPlan = StoryPlan(
        prompt: plan.prompt,
        preset: plan.preset,
        constraints: constraints,
        chapters: plan.chapters,
        eventStory: plan.eventStory
    )
    let invalid = TimelineDeliveryContract().validateAndRepair(
        timeline: timeline,
        plan: invalidPlan,
        assets: [],
        analyses: analyses
    )

    #expect(!invalid.canPersist)
    #expect(invalid.blockingIssues.contains { $0.kind == .missingRequiredTag })
    #expect(invalid.blockingIssues.contains { $0.kind == .excludedTagPresent })
    #expect(invalid.blockingIssues.contains { $0.kind == .maximumTagShare })
    #expect(invalid.blockingIssues.contains { $0.kind == .preferredRoleTag })
}

@Test func deliveryContractReappliesEventSceneTitleContainmentAfterMusicSync() {
    let firstSceneID = UUID()
    let secondSceneID = UUID()
    let first = TimelineItem(
        assetID: UUID(),
        kind: .video,
        sourceDuration: 5,
        timelineStart: 0,
        timelineDuration: 5,
        eventSceneID: firstSceneID
    )
    let second = TimelineItem(
        assetID: UUID(),
        kind: .video,
        sourceDuration: 5,
        timelineStart: 5,
        timelineDuration: 5,
        eventSceneID: secondSceneID
    )
    let plan = StoryPlan(
        prompt: "Только ключевые титры",
        preset: .cinematic,
        constraints: StoryConstraints(targetDuration: 10),
        chapters: []
    )
    let title = TitleTimelineItem(
        kind: .chapter,
        text: "Велопрогулка",
        startTime: 3,
        duration: 4,
        targetClipID: first.id,
        explanation: ["Автоматический режиссёрский титр"]
    )
    let timeline = Timeline(
        storyPlanID: plan.id,
        items: [first, second],
        titleItems: [title]
    )

    let result = TimelineDeliveryContract().validateAndRepair(
        timeline: timeline,
        plan: plan,
        assets: []
    )

    let repaired = result.timeline.effectiveTitleItems.first
    #expect(result.canPersist)
    #expect(repaired?.startTime == 3)
    #expect(repaired?.endTime == 5)
    #expect(result.issues.contains { $0.kind == .generatedTitleQuality && $0.resolution == .repaired })
}
