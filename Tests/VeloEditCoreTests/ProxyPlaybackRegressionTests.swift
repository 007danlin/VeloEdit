import Foundation
import Testing
import AVFoundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers
@testable import VeloEditCore

@Suite(.serialized)
struct ProxyPlaybackRegressionTests {
    @Test func optimisticPreviewDoesNotWaitForTheProjectStore() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.remove() }
        let snapshot = await fixture.store.manifest
        let pipeline = VeloEditPipeline(store: fixture.store)
        // Preload the local music catalog to measure the store dependency.
        _ = try await pipeline.musicTracks()
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let blocked = Task.detached {
            try await fixture.store.update { _ in
                entered.signal()
                _ = release.wait(timeout: .now() + 10)
            }
        }
        await Task.detached { entered.wait() }.value
        defer { release.signal() }
        let started = Date()
        let playback = try await pipeline.makePlayback(projectSnapshot: snapshot)
        let elapsed = Date().timeIntervalSince(started)
        #expect(elapsed < 2)
        #expect(playback.renderedItemCount == 1)
        release.signal()
        try await blocked.value
        print("PERF preview-during-store-write ms=\(elapsed * 1000)")
    }

    @Test func hundredCutsReuseCameraMetadataAndDecodeTheEditedFrame() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.remove() }
        let items = (0..<100).map { index in
            TimelineItem(assetID: fixture.asset.id, kind: .video, sourceStart: Double(index % 3),
                         sourceDuration: 0.4, timelineStart: Double(index) * 0.4, timelineDuration: 0.4)
        }
        let timeline = Timeline(storyPlanID: UUID(), width: 320, height: 180, frameRate: 15,
                                items: items, originalAudioVolume: 0)
        let started = Date()
        let playback = try await PlaybackEngine().build(timeline: timeline, assets: [fixture.asset])
        let elapsed = Date().timeIntervalSince(started)
        #expect(playback.renderedItemCount == 100)
        #expect(playback.skippedItemIDs.isEmpty)
        #expect(abs(playback.duration - 40) < 0.01)
        #expect(elapsed < 5)
        let generator = AVAssetImageGenerator(asset: playback.composition)
        generator.videoComposition = playback.videoComposition
        let frame = try await generator.image(at: CMTime(seconds: 20.2, preferredTimescale: 600)).image
        #expect(!FrameQualityInspector.assess(image: frame).isBlack)
        print("PERF hundred-cuts-build ms=\(elapsed * 1000)")
    }

    @Test func chapterTitleRemainsInCompositionAfterItsFirstShotEnds() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.remove() }
        let ids = [UUID(), UUID()], eventID = UUID()
        let plan = StoryPlan(prompt: "Титры в начале каждой части", preset: .story,
            constraints: StoryConstraints(targetDuration: 4),
            chapters: ids.map { StoryChapter(title: "На озере", candidateIDs: [$0], eventID: eventID) },
            directorBrief: DirectorBrief(musicPolicy: .none, titlePolicy: .keyOnly))
        let items = ids.enumerated().map { index, id in
            TimelineItem(candidateID: id, assetID: fixture.asset.id, kind: .video,
                sourceStart: Double(index * 2), sourceDuration: 2, timelineStart: Double(index * 2), timelineDuration: 2, eventID: eventID)
        }
        let timeline = EditorialIntentEnforcer.enforce(Timeline(storyPlanID: plan.id, width: 320, height: 180, frameRate: 15, items: items, originalAudioVolume: 0), plan: plan)
        let playback = try await PlaybackEngine().build(timeline: timeline, assets: [fixture.asset])
        let instructions = try #require(playback.videoComposition?.instructions as? [VeloVideoInstruction])
        let secondShot = try #require(instructions.first { $0.timeRange.containsTime(CMTime(seconds: 3, preferredTimescale: 600)) })
        #expect(secondShot.titles.map(\.text) == ["На озере"])
    }

    @Test func playbackReusesAnalysisAndManualCachesWithoutWarning() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.remove() }
        let paths = CachePaths(root: await fixture.store.cacheURL)
        let generator = ProxyGenerator()
        let analysis = paths.analysisProxy(for: fixture.asset, longEdge: 960)
        try FileManager.default.copyItem(at: fixture.asset.originalURL, to: analysis)
        #expect(try await generator.cachedProxy(for: fixture.asset, paths: paths)?.lastPathComponent == analysis.lastPathComponent)
        let playback = try await VeloEditPipeline(store: fixture.store).makePlayback()
        #expect(playback.warnings.isEmpty)
        #expect(playback.skippedItemIDs.isEmpty)
        #expect(playback.composition.tracks.flatMap { $0.segments.compactMap(\.sourceURL) }.contains { $0.lastPathComponent == analysis.lastPathComponent })

        let manual = paths.proxy(for: fixture.asset)
        try FileManager.default.moveItem(at: analysis, to: manual)
        #expect(try await generator.cachedProxy(for: fixture.asset, paths: paths) == manual)
        let preview = paths.previewProxy(for: fixture.asset)
        try FileManager.default.copyItem(at: manual, to: preview)
        #expect(try await generator.cachedProxy(for: fixture.asset, paths: paths) == preview)
    }

    @Test func missingAndInvalidCachesUseOriginalWithoutTranscodingOrFalseWarning() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.remove() }
        let pipeline = VeloEditPipeline(store: fixture.store)
        let paths = CachePaths(root: await fixture.store.cacheURL)
        for invalid in [false, true] {
            let corrupt = Data(repeating: 0xFF, count: 4_096)
            if invalid { try corrupt.write(to: paths.previewProxy(for: fixture.asset)) }
            let playback = try await pipeline.makePlayback()
            #expect(playback.warnings.isEmpty)
            #expect(playback.renderedItemCount == 1)
            #expect(playback.composition.tracks.flatMap { $0.segments.compactMap(\.sourceURL) }.contains(fixture.asset.originalURL))
            if invalid {
                // Read-only selection must not delete or try to regenerate an
                // invalid cache inside the application process.
                #expect(try Data(contentsOf: paths.previewProxy(for: fixture.asset)) == corrupt)
            } else {
                #expect(!FileManager.default.fileExists(atPath: paths.previewProxy(for: fixture.asset).path))
            }
        }
    }

    @Test func corruptOrTruncatedPreferredCopyCannotHideAValidLowerPriorityCache() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.remove() }
        let paths = CachePaths(root: await fixture.store.cacheURL)
        let valid = paths.proxy(for: fixture.asset)
        try FileManager.default.copyItem(at: fixture.asset.originalURL, to: valid)
        try Data(repeating: 0xFF, count: 4_096).write(to: paths.previewProxy(for: fixture.asset))
        let short = paths.analysisProxy(for: fixture.asset, longEdge: 1080)
        _ = try await StillImageVideoGenerator().generate(imageURL: fixture.imageURL, duration: 0.5, width: 320, height: 180, frameRate: 15, destination: short, codec: .jpeg, motion: nil)
        #expect(try await ProxyGenerator().cachedProxy(for: fixture.asset, paths: paths) == valid)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["VELOEDIT_PROXY_QA_PROJECT"] != nil))
    func realProjectReusesExistingCameraCopiesAndDecodesPlayback() async throws {
        let source = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["VELOEDIT_PROXY_QA_PROJECT"]))
        let manifest = try JSONDecoder.veloEdit.decode(ProjectManifest.self, from: Data(contentsOf: source.appendingPathComponent("project.json")))
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("veloedit-real-proxy-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ProjectStore(createAt: root, name: "Proxy playback regression")
        try await store.update { project in
            project.assets = manifest.assets
            project.analyses = manifest.analyses
        }
        let originalPaths = CachePaths(root: source.appendingPathComponent("Cache"))
        let paths = CachePaths(root: await store.cacheURL)
        let generator = ProxyGenerator()
        let cameras = manifest.assets.filter { CachePaths.requiresStableRenderProxy($0) }
        #expect(!cameras.isEmpty)
        for asset in cameras {
            let cached = try #require(try await generator.cachedProxy(for: asset, paths: originalPaths))
            let link = paths.analysisProxy(for: asset, longEdge: 960)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: cached)
            let item = TimelineItem(assetID: asset.id, kind: .video, sourceStart: 1, sourceDuration: 1, timelineStart: 0, timelineDuration: 1)
            let timeline = Timeline(storyPlanID: UUID(), width: 640, height: 360, frameRate: 30, items: [item], originalAudioVolume: 0)
            let playback = try await VeloEditPipeline(store: store).makePlayback(timeline: timeline)
            #expect(playback.warnings.isEmpty)
            #expect(playback.skippedItemIDs.isEmpty)
            #expect(playback.composition.tracks.flatMap { $0.segments.compactMap(\.sourceURL) }.contains { $0.lastPathComponent == link.lastPathComponent })
            let imageGenerator = AVAssetImageGenerator(asset: playback.composition)
            imageGenerator.videoComposition = playback.videoComposition
            imageGenerator.maximumSize = CGSize(width: 320, height: 180)
            let frame = try await imageGenerator.image(at: CMTime(seconds: 0.5, preferredTimescale: 600)).image
            #expect(!FrameQualityInspector.assess(image: frame).isBlack)
        }
    }

    private struct Fixture {
        let root: URL
        let store: ProjectStore
        let asset: MediaAsset
        let imageURL: URL
        func remove() { try? FileManager.default.removeItem(at: root) }
        static func make() async throws -> Fixture {
            let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("veloedit-proxy-regression-\(UUID().uuidString)")
            let store = try ProjectStore(createAt: root, name: "Proxy regression")
            let imageURL = root.appendingPathComponent("pattern.png")
            let image = CIImage(color: CIColor(red: 0.2, green: 0.65, blue: 0.3)).cropped(to: CGRect(x: 0, y: 0, width: 320, height: 180))
            let bitmap = try #require(CIContext().createCGImage(image, from: image.extent))
            let destination = try #require(CGImageDestinationCreateWithURL(imageURL as CFURL, UTType.png.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(destination, bitmap, nil)
            try #require(CGImageDestinationFinalize(destination))
            let video = root.appendingPathComponent("original.mov")
            _ = try await StillImageVideoGenerator().generate(imageURL: imageURL, duration: 4, width: 320, height: 180, frameRate: 15, destination: video, codec: .jpeg, motion: nil)
            let asset = MediaAsset(originalURL: video, kind: .video, byteSize: 1, contentHash: "proxy-regression", metadata: MediaMetadata(duration: 4, width: 5312, height: 2988, frameRate: 15, codec: "hvc1", hasAudio: false))
            let item = TimelineItem(assetID: asset.id, kind: .video, sourceDuration: 1, timelineStart: 0, timelineDuration: 1)
            try await store.update { project in
                project.assets = [asset]
                project.timelines = [Timeline(storyPlanID: UUID(), width: 320, height: 180, frameRate: 15, items: [item], originalAudioVolume: 0)]
            }
            return Fixture(root: root, store: store, asset: asset, imageURL: imageURL)
        }
    }
}
