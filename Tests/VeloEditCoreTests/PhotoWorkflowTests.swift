import Foundation
import Testing
import AVFoundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import VeloEditCore

@Suite(.serialized) struct PhotoWorkflowTests {
    @Test func sourceCacheSurvivesDurationChangesButNotSourceReplacement() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("still.png")
        try AutonomousOperationTests.photo(at: file)
        let asset = try await MediaImporter().makeAsset(url: file)
        let first = try await PhotoSourceAnalysis.inspect(asset)
        #expect(first.visionCalls == 1)
        let second = try await PhotoSourceAnalysis.inspect(asset)
        #expect(second.visionCalls == 0)
        let candidate = Candidate(assetID: asset.id, sourceStart: 0, sourceDuration: 19, scores: .init(quality: 0.6, interest: 0.5, action: 0, stability: 1), tags: ["photo"])
        let evidence = try await LocalEditorialEvidenceAnalyzer(cacheURL: root).analyze(candidate: candidate, asset: asset)
        #expect(evidence.usableRange.end == 19)
        #expect(try await PhotoSourceAnalysis.inspect(asset).visionCalls == 0)
        try Data("unreadable changed source".utf8).write(to: file)
        await #expect(throws: (any Error).self) { try await PhotoSourceAnalysis.inspect(asset) }
        try AutonomousOperationTests.photo(at: file)
        #expect(try await PhotoSourceAnalysis.inspect(asset).visionCalls == 1)
    }

    @Test func encodedPhotoNeverEntersVideoReviewer() async throws {
        let asset = MediaAsset(originalURL: URL(fileURLWithPath: "/missing-still.png"), kind: .photo, byteSize: 1, contentHash: "still", metadata: .init())
        let item = TimelineItem(assetID: asset.id, kind: .video, sourceDuration: 6, timelineStart: 0, timelineDuration: 6)
        let timeline = Timeline(storyPlanID: UUID(), items: [item])
        let result = try await SelectedContentReviewer(cacheURL: FileManager.default.temporaryDirectory, model: "unavailable").review(timeline: timeline, assets: [asset])
        #expect(result.isEmpty)
        #expect(!OriginalMediaType.isVideo(item, assets: [asset]))
    }

    @Test func repairsStopWithoutImprovementAndPersistBest() throws {
        let plan = StoryPlan(prompt: "Фильм", preset: .memories, constraints: .init(targetDuration: 12), chapters: [])
        let first = Timeline(storyPlanID: plan.id, items: [.init(kind: .photo, sourceDuration: 12, timelineStart: 0, timelineDuration: 12)])
        var state = FilmContentRepairState()
        let retained = state.retain(timeline: first, plan: plan, defects: 2)
        #expect(retained)
        let permitted = state.permit(signature: "alternative", improved: true, defects: 2)
        #expect(permitted)
        var worse = first; worse.items[0].timelineDuration = 6
        let retainedWorse = state.retain(timeline: worse, plan: plan, defects: 3)
        #expect(!retainedWorse)
        let permittedWorse = state.permit(signature: "next", improved: false, defects: 3)
        #expect(!permittedWorse)
        let restored = try JSONDecoder.veloEdit.decode(FilmContentRepairState.self, from: JSONEncoder.veloEdit.encode(state))
        #expect(restored.best.map { EditorialRenderSignature.signature($0.timeline) } == EditorialRenderSignature.signature(first))
        #expect(restored.attempts == 1)
        #expect(restored.reason?.contains("не показала улучшения") == true)
        #expect(!AutomaticFilmDelivery.technicalFailures(timeline: first).isEmpty)
    }

    @Test func subjectiveContentNeverRequestsRepair() {
        var assessment = ShotContentAssessment(itemID: UUID(), assetID: UUID(), sourceContentHash: "s", sourceStart: 0,
            sourceDuration: 6, sampleTimes: [0,1,2,3,4], phase: "source", model: "test", cacheKey: "test",
            status: .unmotivated, confidence: 0.99, obstructedSamples: [], observation: "Not interesting", activity: "unknown",
            editorialPurpose: "none", irrelevantSamples: [0,1,2,3,4])
        #expect(assessment.rejectsRange)
        #expect(!assessment.requiresConcreteRepair)
        assessment.status = .uncertain
        #expect(!assessment.requiresConcreteRepair)
        assessment.status = .obstructed; assessment.obstructedSamples = [0,1,2]
        #expect(assessment.requiresConcreteRepair)
    }

    @Test func photoFramingChecksIntermediateKeyframesAndResolution() {
        let sample = VisualFrameSample(timestamp: 0, motion: 0, exposure: 0.1, detail: 0.1,
            labels: [], labelConfidence: 1, faceCount: 1, jpegBase64: "", histogram: [], luminanceFingerprint: [],
            subjects: [.init(kind: .face, label: "face", region: .init(x: 0.1, y: 0.4, width: 0.1, height: 0.2), confidence: 1)])
        let photo = PhotoSourceAnalysis(sample: sample, width: 640, height: 360, orientation: 1, visionCalls: 0)
        var plan = SubjectReframePlan(startCenterX: 0.5, startCenterY: 0.5, endCenterX: 0.5, endCenterY: 0.5,
            startScale: 1, endScale: 1, targetAspectRatio: 16.0 / 9, confidence: 1)
        plan.keyframes = [.init(sourceTime: 0, centerX: 0.5, centerY: 0.5),
            .init(sourceTime: 3, centerX: 0.8, centerY: 0.5, scale: 2),
            .init(sourceTime: 6, centerX: 0.5, centerY: 0.5)]
        var item = TimelineItem(kind: .photo, sourceDuration: 6, timelineStart: 0, timelineDuration: 6,
            videoAdjustments: .init(crop: .fill, subjectReframe: plan))
        let moving = PhotoTimelineReview.inspect(item: item, photo: photo, canvas: .init(width: 1920, height: 1080))
        #expect(moving.cropsSubject && moving.upscales)
        item.videoAdjustments = .init(crop: .fit)
        #expect(!PhotoTimelineReview.inspect(item: item, photo: photo, canvas: .init(width: 1920, height: 1080)).cropsSubject)
    }

    @Test func darkStillDoesNotAcquireActionTailOrPaddingLimit() {
        let candidate = Candidate(assetID: UUID(), sourceStart: 0, sourceDuration: 12,
            scores: .init(quality: 0.2, interest: 0.6, action: 0, stability: 1), tags: ["photo"])
        #expect(EditorialUnit(candidate: candidate).usableDuration == 12)
        #expect(EditorialUnit(candidate: candidate).preferredDuration(pacing: 1) == 6)
    }

    @Test func titleTextUpdatesTheExistingPlaybackWithoutRebuildingSources() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("still.png")
        try AutonomousOperationTests.photo(at: file)
        let asset = try await MediaImporter().makeAsset(url: file)
        var timeline = Timeline(storyPlanID: UUID(), width: 320, height: 180,
            items: [.init(assetID: asset.id, kind: .photo, sourceDuration: 1, timelineStart: 0, timelineDuration: 1)])
        let title = TitleTimelineItem(kind: .title, text: "Было", startTime: 0, duration: 1)
        timeline.titleItems = [title]
        let playback = try await PlaybackEngine().build(timeline: timeline, assets: [asset], forceVideoComposition: true)
        let instructions = try #require(playback.videoComposition?.instructions as? [VeloVideoInstruction])
        func renderedPixels() async throws -> Data {
            let generator = AVAssetImageGenerator(asset: playback.composition)
            generator.videoComposition = playback.videoComposition
            generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
            let image = try await generator.image(at: CMTime(seconds: 0.5, preferredTimescale: 600)).image
            return try #require(image.dataProvider?.data) as Data
        }
        let beforePixels = try await renderedPixels()
        var revised = timeline; revised.titleItems?[0].text = "Новое 🌳"
        #expect(playback.updateTitleContents(from: timeline, to: revised))
        #expect(instructions.flatMap(\.titles).contains { $0.text == "Новое 🌳" })
        #expect(!instructions.flatMap(\.titles).contains { $0.text == "Было" })
        let afterPixels = try await renderedPixels()
        #expect(afterPixels != beforePixels)
        var moved = revised; moved.titleItems?[0].startTime = 0.5
        #expect(!playback.updateTitleContents(from: revised, to: moved))
    }

    @Test func reorderedPhotosReuseRenderedCacheAndFadeOnlyAtNewMovieEnd() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("still.png")
        try AutonomousOperationTests.photo(at: file)
        let asset = try await MediaImporter().makeAsset(url: file)
        let framing = SubjectReframePlan(startCenterX: 0.5, startCenterY: 0.5, endCenterX: 0.5, endCenterY: 0.5,
            startScale: 1, endScale: 1.1, targetAspectRatio: 16.0 / 9, confidence: 1)
        let items = (0..<3).map { TimelineItem(assetID: asset.id, kind: .photo, sourceDuration: 3,
            timelineStart: Double($0) * 3, timelineDuration: 3, videoAdjustments: .init(subjectReframe: framing)) }
        let timeline = Timeline(storyPlanID: UUID(), width: 320, height: 180, items: items, endingFadeDuration: 3)
        let cache = root.appendingPathComponent("Derived")
        let first = try await PlaybackEngine().build(timeline: timeline, assets: [asset], derivedMediaCacheURL: cache)
        #expect(first.derivedMediaCacheMisses == 1)
        var reordered = try JSONDecoder.veloEdit.decode(Timeline.self, from: JSONEncoder.veloEdit.encode(timeline))
        #expect(TimelineMutationEngine.movePrimaryItem(in: &reordered, id: items[2].id, toPrimaryIndex: 1))
        let next = try await PlaybackEngine().build(timeline: reordered, assets: [asset], derivedMediaCacheURL: cache)
        #expect(next.derivedMediaCacheMisses == 0)
        #expect(next.derivedMediaCacheHits == 3)
        let generator = AVAssetImageGenerator(asset: next.composition)
        generator.videoComposition = next.videoComposition
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        let middle = try await generator.image(at: CMTime(seconds: 5.5, preferredTimescale: 600)).image
        let end = try await generator.image(at: CMTime(seconds: 8.966667, preferredTimescale: 600)).image
        let middleLuma = PerceptualRenderInspector.lumaFingerprint(middle).reduce(0, +)
        let endLuma = PerceptualRenderInspector.lumaFingerprint(end).reduce(0, +)
        #expect(middleLuma > 1)
        #expect(endLuma < middleLuma * 0.01)
    }

    @Test func fitPhotoHasStablePixelsAcrossTheOpening() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("still.png")
        let context = try #require(CGContext(data: nil, width: 180, height: 320, bitsPerComponent: 8, bytesPerRow: 720,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        for y in stride(from: 0, to: 320, by: 16) {
            context.setFillColor(CGColor(red: Double(y) / 320, green: 0.7, blue: 0.2, alpha: 1))
            context.fill(CGRect(x: 0, y: y, width: 180, height: 16))
        }
        let image = try #require(context.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        try #require(CGImageDestinationFinalize(destination))
        let movie = try await StillImageVideoGenerator().generate(imageURL: file, duration: 1, width: 320, height: 180,
            frameRate: 24, destination: root.appendingPathComponent("fit.mov"), codec: .proRes4444, motion: .zoomIn, cropStyle: .fit)
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: movie))
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        var previous: Data?
        for time in [0.0, 0.2, 0.5, 0.8] {
            let image = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image
            let data = try #require(image.dataProvider?.data) as Data
            if let previous { #expect(data == previous) }
            previous = data
        }
    }
}
