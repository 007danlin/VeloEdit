import Foundation
import Testing
import AVFoundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers
@testable import VeloEditCore

@Test func photoPresentationDefaultsAllowTimeToLookAndFinishTheFilm() throws {
    let assets = (0..<3).map { index in
        MediaAsset(originalURL: URL(fileURLWithPath: "/tmp/photo-\(index).jpg"), kind: .photo,
                   byteSize: 1, contentHash: "p\(index)", metadata: MediaMetadata(width: 320, height: 180))
    }
    let analyses = assets.map { asset in
        AnalysisResult(assetID: asset.id, analyzedContentHash: asset.contentHash, candidates: [
            Candidate(assetID: asset.id, sourceStart: 0, sourceDuration: 5,
                      scores: ClipScores(quality: 0.8, interest: 0.8, action: 0.1, stability: 1))
        ])
    }
    var plan = StoryPlan(prompt: "Спокойный фильм без музыки и титров", preset: .story,
                         constraints: StoryConstraints(targetDuration: 30),
                         chapters: [StoryChapter(title: "Фотографии", candidateIDs: analyses.flatMap(\.candidates).map(\.id))])
    let timeline = TimelineComposer().compose(plan: plan, assets: assets, analyses: analyses)
    let photos = timeline.items.filter { $0.kind == .photo }
    #expect(photos.count == 3)
    #expect(photos.allSatisfy { $0.timelineDuration == 6 && $0.effect == ClipEffect.zoomIn.rawValue })
    #expect(timeline.endingFadeDuration == 3)
    #expect(timeline.items.last?.effectiveAudioAdjustments.fadeOut == 3)
    var reviewedTimeline = timeline
    for index in reviewedTimeline.items.indices { reviewedTimeline.items[index].storyRole = .bRoll }
    let review = TimelineSelfReviewer().review(reviewedTimeline, plan: plan, analyses: analyses)
    #expect(!review.issues.contains { $0.kind == .overlongClip })
    let encoded = try JSONEncoder.veloEdit.encode(timeline)
    #expect(try JSONDecoder.veloEdit.decode(Timeline.self, from: encoded).endingFadeDuration == 3)
    var legacy = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    legacy.removeValue(forKey: "endingFadeDuration")
    #expect(try JSONDecoder.veloEdit.decode(Timeline.self, from: JSONSerialization.data(withJSONObject: legacy)).endingFadeDuration == nil)
    plan.prompt += " без затемнения"
    #expect(TimelineComposer().compose(plan: plan, assets: assets, analyses: analyses).endingFadeDuration == 0)
}

@Test(arguments: [2.0, 6.0]) func filmEndingFadeReachesBlackInPreviewAndExportWithoutExtendingTimeline(_ duration: Double) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("veloedit-finish-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let photo = root.appendingPathComponent("center.png")
    try presentationFixture(to: photo)
    let asset = MediaAsset(originalURL: photo, kind: .photo, byteSize: 1, contentHash: "center", metadata: MediaMetadata(width: 320, height: 180))
    let item = TimelineItem(assetID: asset.id, kind: .photo, sourceDuration: duration, timelineStart: 0, timelineDuration: duration)
    let title = TitleTimelineItem(kind: .cinematicTitle, text: "Финал", startTime: 0, duration: duration)
    let timeline = Timeline(storyPlanID: UUID(), width: 320, height: 180, frameRate: 30,
                            items: [item], titleItems: [title], endingFadeDuration: 3)
    let playback = try await PlaybackEngine().build(timeline: timeline, assets: [asset])
    let stable = try await PlaybackEngine().build(timeline: timeline, assets: [asset], preferStableRealtimePreview: true)
    #expect(stable.videoComposition?.customVideoCompositorClass != nil)
    #expect(playback.duration == duration)
    let output = root.appendingPathComponent("finished.mp4")
    _ = try await RenderEngine().render(timeline: timeline, assets: [asset], quality: .maximum, destination: output)
    let movie = AVURLAsset(url: output)
    #expect(abs(try await movie.load(.duration).seconds - duration) < 1 / 30.0)
    let preview = AVAssetImageGenerator(asset: playback.composition)
    preview.videoComposition = playback.videoComposition
    let exported = AVAssetImageGenerator(asset: movie)
    let realtime = AVAssetImageGenerator(asset: stable.composition)
    realtime.videoComposition = stable.videoComposition
    for generator in [preview, exported, realtime] {
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        var levels: [Double] = []
        let end = duration - 1 / 30.0
        let start = max(0, end - 3)
        for time in [start, start + (end - start) / 2, start + (end - start) * 0.85, end] {
            let image = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image
            levels.append(Double(FrameQualityInspector.assess(image: image).meanLuma))
        }
        #expect(levels[0] > 20)
        #expect(zip(levels, levels.dropFirst()).allSatisfy { $0 >= $1 })
        #expect(try #require(levels.last) < 2)
    }
}

@Test func photoDefaultZoomKeepsCenterStationary() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("veloedit-photo-center-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let photo = root.appendingPathComponent("center.png")
    try presentationFixture(to: photo)
    let output = root.appendingPathComponent("photo.mov")
    _ = try await StillImageVideoGenerator().generate(imageURL: photo, duration: 1, width: 320, height: 180, frameRate: 30, destination: output)
    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: output))
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = .zero
    var areas: [Int] = []
    for time in [0.0, 0.25, 0.5, 29 / 30.0] {
        let image = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image
        var pixels = [UInt8](repeating: 0, count: 320 * 180 * 4)
        try pixels.withUnsafeMutableBytes { bytes in
            let context = try #require(CGContext(data: bytes.baseAddress, width: 320, height: 180, bitsPerComponent: 8, bytesPerRow: 320 * 4,
                                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: 320, height: 180))
        }
        var xSum = 0, ySum = 0, count = 0
        for y in 0..<180 { for x in 0..<320 {
            let offset = (y * 320 + x) * 4
            if pixels[offset] > 235 && pixels[offset + 1] > 235 && pixels[offset + 2] > 235 {
                xSum += x; ySum += y; count += 1
            }
        } }
        try #require(count > 0)
        #expect(abs(Double(xSum) / Double(count) - 159.5) < 0.8)
        #expect(abs(Double(ySum) / Double(count) - 89.5) < 0.8)
        areas.append(count)
    }
    #expect(try #require(areas.last) > #require(areas.first))
}

private func presentationFixture(to url: URL) throws {
    let context = try #require(CGContext(data: nil, width: 320, height: 180, bitsPerComponent: 8, bytesPerRow: 0,
                                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: 0.12, green: 0.3, blue: 0.7, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 320, height: 180))
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(x: 130, y: 60, width: 60, height: 60))
    let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
    try #require(CGImageDestinationFinalize(destination))
}
