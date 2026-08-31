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
