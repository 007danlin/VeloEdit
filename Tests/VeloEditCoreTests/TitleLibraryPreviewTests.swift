import AVFoundation
import CoreImage
import Testing
@testable import VeloEditCore

struct TitleLibraryPreviewTests {
    @Test func thumbnailFrameRemovesProjectTitlesWithoutChangingPlayback() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("green.png")
        try BackgroundPresetRenderer.render(.green, width: 320, height: 180, to: url)
        let asset = MediaAsset(originalURL: url, kind: .photo, byteSize: 1, contentHash: "green",
            metadata: MediaMetadata(width: 320, height: 180))
        let clip = TimelineItem(assetID: asset.id, kind: .photo, sourceDuration: 2,
            timelineStart: 0, timelineDuration: 2)
        let title = TitleTimelineItem(kind: .title, text: "PROJECT TITLE", startTime: 0, duration: 2)
        let timeline = Timeline(storyPlanID: UUID(), width: 320, height: 180, items: [clip], titleItems: [title])
        let playback = try await PlaybackEngine().build(timeline: timeline, assets: [asset])
        let source = try #require(playback.videoComposition)
        let clean = try #require(TitleLibraryPreview.videoComposition(from: source))
        let sourceInstructions = try #require(source.instructions as? [VeloVideoInstruction])
        let cleanInstructions = try #require(clean.instructions as? [VeloVideoInstruction])
        #expect(sourceInstructions.contains { !$0.titles.isEmpty })
        #expect(cleanInstructions.allSatisfy { $0.titles.isEmpty })
        #expect(zip(sourceInstructions, cleanInstructions).allSatisfy { $0 !== $1 })
        let generator = AVAssetImageGenerator(asset: playback.composition)
        generator.videoComposition = clean
        let frame = try await generator.image(at: CMTime(seconds: 1, preferredTimescale: 600)).image
        let pixels = rgba(frame)
        // All pixels of the solid source remain uniform; no title glyphs or
        // decorative shapes from the project may leak into the template card.
        for channel in 0..<3 {
            let values = stride(from: channel, to: pixels.count, by: 4).map { pixels[$0] }
            #expect(Int(values.max()!) - Int(values.min()!) <= 2)
        }
        generator.videoComposition = source
        let titled = rgba(try await generator.image(at: CMTime(seconds: 1, preferredTimescale: 600)).image)
        #expect(titled != pixels)
        #expect(sourceInstructions.contains { !$0.titles.isEmpty })
    }

    @Test func cleanCopyKeepsTimingColorAndEffectsButExcludesBakedTitleLayers() throws {
        let range = CMTimeRange(start: .zero, duration: CMTime(seconds: 3, preferredTimescale: 600))
        let layer = VeloCompositorLayer(trackID: 1,
            item: TimelineItem(kind: .title, sourceDuration: 3, timelineStart: 0, timelineDuration: 3),
            start: .zero, duration: range.duration, naturalSize: CGSize(width: 320, height: 180), transform: .identity)
        let effect = EffectTimelineItem(effectType: .letterbox, startTime: 0, duration: 3)
        let instruction = VeloVideoInstruction(timeRange: range, layers: [layer], effects: [effect],
            titles: [TitleTimelineItem(kind: .title, text: "Existing", startTime: 0, duration: 3)],
            transition: nil, renderSize: CGSize(width: 320, height: 180), timelineTimeRange: range)
        let source = AVMutableVideoComposition()
        source.instructions = [instruction]
        let clean = try #require(TitleLibraryPreview.videoComposition(from: source)?.instructions.first as? VeloVideoInstruction)
        #expect(clean.layers.isEmpty && clean.titles.isEmpty)
        #expect(clean.effects == [effect])
        #expect(clean.timeRange == range && clean.timelineTimeRange == range)
        #expect(clean.renderSize == instruction.renderSize)
        #expect(instruction.layers.count == 1 && instruction.titles.count == 1)
    }

    private func rgba(_ image: CGImage) -> [UInt8] {
        let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Array(UnsafeBufferPointer(start: context.data!.assumingMemoryBound(to: UInt8.self), count: image.width * image.height * 4))
    }
}
