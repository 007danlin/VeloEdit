import Foundation
import Testing
import AVFoundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Darwin
@testable import VeloEditCore

@Suite(.serialized)
struct TemporaryMediaTests {
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func longPhotoTimelineUsesOneTinyClockAndCleansItWhenReleased() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let photo = root.appendingPathComponent("original.png")
        try AutonomousOperationTests.photo(at: photo)
        let originalBytes = try Data(contentsOf: photo)
        let asset = try await MediaImporter().makeAsset(url: photo)
        let scratch = root.appendingPathComponent("scratch")
        let engine = PlaybackEngine(temporaryRoot: scratch)
        let items = (0..<100).map { TimelineItem(assetID: asset.id, kind: .photo, sourceDuration: 60,
            timelineStart: Double($0) * 60, timelineDuration: 60) }
        let timeline = Timeline(storyPlanID: UUID(), width: 3840, height: 2160, frameRate: 30, items: items)
        let started = Date()
        var playback: TimelinePlayback? = try await engine.build(timeline: timeline, assets: [asset], forceVideoComposition: true)
        print("Still timeline: 100 clips, 100 minutes, 4K; build \(Date().timeIntervalSince(started)) s; scratch \(TemporaryMediaMaintenance.bytes(in: scratch)) bytes")
        #expect(playback?.renderedItemCount == 100)
        #expect(abs((playback?.duration ?? 0) - 6000) < 0.001)
        let sources = Set(playback!.composition.tracks.flatMap { $0.segments.compactMap(\.sourceURL) })
        #expect(sources.count == 1)
        #expect(TemporaryMediaMaintenance.bytes(in: scratch) < 64 * 1_024)
        // A seek near the end must render source pixels, not the tiny clock.
        do {
            let generator = AVAssetImageGenerator(asset: playback!.composition)
            generator.videoComposition = playback!.videoComposition
            generator.maximumSize = CGSize(width: 320, height: 180)
            let frame = try await generator.image(at: CMTime(seconds: 5_999, preferredTimescale: 600)).image
            #expect(PerceptualRenderInspector.lumaFingerprint(frame).reduce(0, +) > 1)
        }
        playback = nil
        #expect(sources.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        #expect(try Data(contentsOf: photo) == originalBytes)
    }

    @Test func failedAndCancelledBuildsRemoveAlreadyCreatedMedia() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let scratch = root.appendingPathComponent("scratch")
        let engine = PlaybackEngine(temporaryRoot: scratch)
        let missing = MediaAsset(originalURL: root.appendingPathComponent("missing.mov"), kind: .video,
            byteSize: 100, contentHash: "missing", metadata: MediaMetadata(width: 320, height: 180, hasAudio: false))
        let title = TimelineItem(kind: .title, sourceDuration: 1, timelineStart: 0, timelineDuration: 1, title: "Титр")
        let video = TimelineItem(assetID: missing.id, kind: .video, sourceDuration: 1, timelineStart: 1, timelineDuration: 1)
        do {
            _ = try await engine.build(timeline: Timeline(storyPlanID: UUID(), width: 320, height: 180, items: [title, video]), assets: [missing])
            Issue.record("A missing video must fail after the clock was created")
        } catch {}
        #expect(TemporaryMediaMaintenance.bytes(in: scratch) == 0)
        var secondTitle = title
        secondTitle.id = UUID()
        secondTitle.timelineStart = 1
        let task = Task {
            try await engine.build(timeline: Timeline(storyPlanID: UUID(), width: 320, height: 180, items: [title, secondTitle]), assets: []) { progress in
                if progress.completed == 1 { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        do { _ = try await task.value; Issue.record("Cancelled build completed") } catch {}
        #expect(TemporaryMediaMaintenance.bytes(in: scratch) == 0)
    }

    @Test func manyVideoCutsReferenceOriginalWithoutScratchCopies() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("original.mov")
        _ = try await TitleCardVideoGenerator().generate(text: "Оригинал", style: TitleStyle(), duration: 0.5,
            width: 320, height: 180, frameRate: 30, destination: original)
        let sourceBytes = try Data(contentsOf: original)
        let asset = try await MediaImporter().makeAsset(url: original)
        let scratch = root.appendingPathComponent("scratch")
        let items = (0..<100).map { TimelineItem(assetID: asset.id, kind: .video, sourceDuration: 0.5,
            timelineStart: Double($0) * 0.5, timelineDuration: 0.5) }
        let playback = try await PlaybackEngine(temporaryRoot: scratch).build(
            timeline: Timeline(storyPlanID: UUID(), width: 320, height: 180, items: items), assets: [asset])
        #expect(playback.renderedItemCount == 100)
        let sources = Set(playback.composition.tracks.flatMap { $0.segments.compactMap(\.sourceURL) }.map { $0.resolvingSymlinksInPath() })
        #expect(sources == [original.resolvingSymlinksInPath()])
        #expect(!FileManager.default.fileExists(atPath: scratch.path))
        #expect(try Data(contentsOf: original) == sourceBytes)
    }

    @Test(arguments: [CropStyle.fill, .fit])
    func directPhotoMatchesCompositedIntermediate(_ crop: CropStyle) async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let photo = root.appendingPathComponent("original.png")
        let canvas = try #require(CGContext(data: nil, width: 1200, height: 800, bitsPerComponent: 8,
            bytesPerRow: 4800, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        for y in stride(from: 0, to: 800, by: 20) {
            for x in stride(from: 0, to: 1200, by: 20) {
                canvas.setFillColor(CGColor(red: Double(x) / 1200, green: Double(y) / 800,
                    blue: (x / 20 + y / 20).isMultiple(of: 2) ? 0.15 : 0.85, alpha: 1))
                canvas.fill(CGRect(x: x, y: y, width: 20, height: 20))
            }
        }
        let png = try #require(CGImageDestinationCreateWithURL(photo as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(png, try #require(canvas.makeImage()), nil)
        #expect(CGImageDestinationFinalize(png))
        let asset = try await MediaImporter().makeAsset(url: photo)
        let reference = root.appendingPathComponent("legacy.mov")
        let oldStart = Date()
        _ = try await StillImageVideoGenerator().generate(imageURL: photo, duration: 3,
            width: 1920, height: 1080, frameRate: 30, destination: reference, codec: .proRes4444, cropStyle: crop)
        let oldSeconds = Date().timeIntervalSince(oldStart)
        let scratch = root.appendingPathComponent("scratch")
        let newStart = Date()
        let item = TimelineItem(assetID: asset.id, kind: .photo, sourceDuration: 3, timelineStart: 0,
            timelineDuration: 3, videoAdjustments: .init(crop: crop))
        // Force the reference through the color compositor too. Comparing a
        // raw ProRes frame with a finished composition misses transfer-curve
        // regressions. Sample before the final fade so framing stays visible.
        let directTimeline = Timeline(storyPlanID: UUID(), width: 1920, height: 1080,
            frameRate: 30, items: [item], endingFadeDuration: 0.001)
        let playback = try await PlaybackEngine(temporaryRoot: scratch).build(
            timeline: directTimeline,
            assets: [asset], forceVideoComposition: true)
        let newSeconds = Date().timeIntervalSince(newStart)
        let live = AVAssetImageGenerator(asset: playback.composition)
        live.videoComposition = playback.videoComposition
        let oldAsset = try await MediaImporter().makeAsset(url: reference)
        let oldItem = TimelineItem(assetID: oldAsset.id, kind: .video, sourceDuration: 3,
            timelineStart: 0, timelineDuration: 3, videoAdjustments: .init(crop: .fill))
        let oldTimeline = Timeline(storyPlanID: UUID(), width: 1920, height: 1080,
            frameRate: 30, items: [oldItem], endingFadeDuration: 0.001)
        let oldPlayback = try await PlaybackEngine().build(timeline: oldTimeline,
            assets: [oldAsset], forceVideoComposition: true)
        let old = AVAssetImageGenerator(asset: oldPlayback.composition)
        old.videoComposition = oldPlayback.videoComposition
        for generator in [live, old] {
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
        }
        var maximumDifference = 0.0
        for frame in [0, 30, 88] {
            let time = CMTime(value: Int64(frame), timescale: 30)
            let a = try rgbPixels(try await live.image(at: time).image)
            let b = try rgbPixels(try await old.image(at: time).image)
            maximumDifference = max(maximumDifference, rgbDifference(a, b))
        }
        #expect(maximumDifference < 0.01)
        print("Photo \(crop) preparation: intermediate \(oldSeconds) s; direct \(newSeconds) s / \(TemporaryMediaMaintenance.bytes(in: scratch)) bytes; mean RGB delta \(maximumDifference)")

        let oldOutput = root.appendingPathComponent("old-export.mp4")
        let directOutput = root.appendingPathComponent("direct-export.mp4")
        let exportStart = Date()
        _ = try await RenderEngine().render(timeline: oldTimeline,
            assets: [oldAsset], quality: .final1080p, destination: oldOutput)
        let oldExportSeconds = Date().timeIntervalSince(exportStart)
        let directExportStart = Date()
        _ = try await RenderEngine().render(timeline: directTimeline,
            assets: [asset], quality: .final1080p, destination: directOutput)
        let directExportSeconds = Date().timeIntervalSince(directExportStart)
        let exports = [oldOutput, directOutput].map { AVAssetImageGenerator(asset: AVURLAsset(url: $0)) }
        for generator in exports {
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
        }
        for frame in [0, 30, 88] {
            let time = CMTime(value: Int64(frame), timescale: 30)
            let a = try rgbPixels(try await exports[0].image(at: time).image)
            let b = try rgbPixels(try await exports[1].image(at: time).image)
            #expect(rgbDifference(a, b) < 0.015)
        }
        let exported = AVURLAsset(url: directOutput)
        #expect(abs(try await exported.load(.duration).seconds - 3) < 0.001)
        let track = try #require(try await exported.loadTracks(withMediaType: .video).first)
        #expect(try await track.load(.naturalSize) == CGSize(width: 1920, height: 1080))
        print("Photo Full HD end-to-end: legacy preparation + export \(oldSeconds + oldExportSeconds) s; direct export \(directExportSeconds) s")
    }

    @Test func darkTitleMatchesCompositedIntermediate() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let reference = root.appendingPathComponent("title.mov")
        _ = try await TitleCardVideoGenerator().generate(text: "ЛЕТО — ПРОВЕРКА", style: TitleStyle(),
            duration: 1, width: 1280, height: 720, frameRate: 30, destination: reference, codec: .proRes4444)
        let asset = try await MediaImporter().makeAsset(url: reference)
        let title = TimelineItem(kind: .title, sourceDuration: 1, timelineStart: 0,
            timelineDuration: 1, title: "ЛЕТО — ПРОВЕРКА")
        let video = TimelineItem(assetID: asset.id, kind: .video, sourceDuration: 1,
            timelineStart: 0, timelineDuration: 1)
        var frames: [[UInt8]] = []
        for item in [title, video] {
            let timeline = Timeline(storyPlanID: UUID(), width: 1280, height: 720, frameRate: 30,
                items: [item], endingFadeDuration: 0.001)
            let playback = try await PlaybackEngine().build(timeline: timeline, assets: [asset], forceVideoComposition: true)
            let generator = AVAssetImageGenerator(asset: playback.composition)
            generator.videoComposition = playback.videoComposition
            frames.append(try rgbPixels(try await generator.image(at: CMTime(value: 15, timescale: 30)).image))
        }
        #expect(rgbDifference(frames[0], frames[1]) < 0.01)
    }

    private func rgbPixels(_ image: CGImage) throws -> [UInt8] {
        let context = try #require(CGContext(data: nil, width: 160, height: 90, bitsPerComponent: 8,
            bytesPerRow: 640, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: 160, height: 90))
        return Array(UnsafeBufferPointer(start: try #require(context.data).assumingMemoryBound(to: UInt8.self), count: 160 * 90 * 4))
    }

    private func rgbDifference(_ lhs: [UInt8], _ rhs: [UInt8]) -> Double {
        let total = lhs.indices.filter { $0 % 4 != 3 }.reduce(0) { $0 + abs(Int(lhs[$1]) - Int(rhs[$1])) }
        return Double(total) / Double(lhs.count / 4 * 3 * 255)
    }

    @Test func cleanupPreservesActiveWorkAndRemovesAbandonedWork() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let active = TemporaryMediaWorkspace(root: root)
        let activeFile = try active.file("movie.mov")
        try Data(repeating: 1, count: 512).write(to: activeFile)
        let abandoned = root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: abandoned, withIntermediateDirectories: false)
        try Data().write(to: abandoned.appendingPathComponent(".owner"))
        try Data(repeating: 1, count: 512).write(to: abandoned.appendingPathComponent("partial.mov"))
        let unknown = root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: unknown, withIntermediateDirectories: false)
        TemporaryMediaMaintenance.removeAbandonedWork(in: root, now: Date().addingTimeInterval(120))
        #expect(FileManager.default.fileExists(atPath: activeFile.path))
        #expect(!FileManager.default.fileExists(atPath: abandoned.path))
        #expect(FileManager.default.fileExists(atPath: unknown.path))
        withExtendedLifetime(active) {}
    }

    @Test func boundedFrameCacheEvictsWithoutLosingComputedResultsOrOriginals() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("original.png")
        try Data([1, 2, 3]).write(to: original)
        let cache = FrameCache(rootURL: root, maximumDiskBytes: 1_024)
        let sample = VisualFrameSample(timestamp: 1, motion: 0, exposure: 0.8, detail: 0.7,
            labels: [], labelConfidence: 0.9, faceCount: 0, jpegBase64: "frame",
            histogram: [0.25, 0.75], luminanceFingerprint: [10, 20])
        for index in 0..<20 {
            let key = FrameCacheKey(sourceFile: "source", timestamp: Double(index), resolution: 960, processingPurpose: .vision)
            let result = try await cache.resolve(key) { sample }
            #expect(result.sample == sample)
        }
        let records = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasSuffix(".frame-v2.bin") }
        let bytes = try records.reduce(0) { try $0 + Data(contentsOf: $1).count }
        #expect(bytes <= 1_024)
        #expect(try Data(contentsOf: original) == Data([1, 2, 3]))
    }

    @Test func legacyCleanupRequiresExactNamesAgeAndRegularFiles() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let old = root.appendingPathComponent("veloedit-playback-\(UUID()).mov")
        let recent = root.appendingPathComponent("veloedit-playback-\(UUID()).mov")
        let unrelated = root.appendingPathComponent("veloedit-playback-family.mov")
        let original = root.appendingPathComponent("original.mov")
        for url in [old, recent, unrelated, original] { try Data([1, 2, 3]).write(to: url) }
        for url in [old, unrelated, original] {
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-172_800)], ofItemAtPath: url.path)
        }
        let link = root.appendingPathComponent("veloedit-playback-\(UUID()).mov")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: original)
        TemporaryMediaMaintenance.removeLegacyFiles(in: root)
        #expect(!FileManager.default.fileExists(atPath: old.path))
        for url in [recent, unrelated, original, link] { #expect(FileManager.default.fileExists(atPath: url.path)) }
    }
}
