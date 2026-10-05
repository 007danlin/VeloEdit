import AVFoundation
import CoreImage
import Foundation
import Testing
@testable import VeloEditCore

@Suite(.serialized) struct AnamorphicPlaybackTests {
    @Test(arguments: [false, true])
    func nonSquarePixelsStayCenteredInPreviewAndExport(rotated: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("veloedit-anamorphic-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.mov")
        try await makeSource(at: source)
        let track = try #require(try await AVURLAsset(url: source).loadTracks(withMediaType: .video).first)
        let naturalSize = try await track.load(.naturalSize)
        #expect(abs(naturalSize.width / naturalSize.height - 16.0 / 9) < 0.001)
        let asset = MediaAsset(originalURL: source, kind: .video, byteSize: 1, contentHash: UUID().uuidString,
                               metadata: MediaMetadata(duration: 1, width: 512, height: 288, frameRate: 25, hasAudio: false))
        var clip = TimelineItem(assetID: asset.id, kind: .video, sourceDuration: 1, timelineStart: 0, timelineDuration: 1)
        if rotated {
            var adjustments = clip.effectiveVideoAdjustments
            adjustments.rotationQuarterTurns = 1
            clip.videoAdjustments = adjustments
        }
        var timeline = Timeline(storyPlanID: UUID(), width: rotated ? 180 : 320, height: rotated ? 320 : 180,
                                frameRate: 25, items: [clip])
        // A neutral effect takes the same custom-compositor path as titles in
        // project 1231, without obscuring the geometric reference pattern.
        timeline.effects = [EffectTimelineItem(effectType: .brightness, startTime: 0, duration: 1, intensity: 0)]
        let playback = try await PlaybackEngine().build(timeline: timeline, assets: [asset])
        #expect(playback.videoComposition?.customVideoCompositorClass != nil)
        let preview = AVAssetImageGenerator(asset: playback.composition)
        preview.videoComposition = playback.videoComposition
        try checkFrame(preview, width: timeline.width, height: timeline.height)

        let destination = root.appendingPathComponent("export.mp4")
        _ = try await RenderEngine().render(timeline: timeline, assets: [asset], quality: .maximum, destination: destination)
        try checkFrame(AVAssetImageGenerator(asset: AVURLAsset(url: destination)), width: timeline.width, height: timeline.height)
    }

    private func checkFrame(_ generator: AVAssetImageGenerator, width: Int, height: Int) throws {
        generator.appliesPreferredTrackTransform = true
        let frame = try generator.copyCGImage(at: CMTime(seconds: 0.5, preferredTimescale: 600), actualTime: nil)
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(frame, in: CGRect(x: 0, y: 0, width: width, height: height))
        let pixels = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        let center = (height / 2 * width + width / 2) * 4
        #expect(pixels[center] > 180 && pixels[center + 1] < 80, "The red source marker must remain centered")
        for (x, y) in [(8, 8), (width - 9, 8), (8, height - 9), (width - 9, height - 9)] {
            let index = (y * width + x) * 4
            #expect(pixels[index + 1] > 150 && pixels[index + 2] > 150,
                    "All corners must contain the cyan source, without an uncovered black edge")
        }
    }

    private func makeSource(at url: URL) async throws {
        let width = 360, height = 288
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoPixelAspectRatioKey: [AVVideoPixelAspectRatioHorizontalSpacingKey: 64,
                                        AVVideoPixelAspectRatioVerticalSpacingKey: 45]
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ])
        writer.add(input)
        try #require(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        let pool = try #require(adaptor.pixelBufferPool)
        var buffer: CVPixelBuffer?
        try #require(CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess)
        let pixels = try #require(buffer)
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        let background = CIImage(color: CIColor(red: 0, green: 1, blue: 1)).cropped(to: bounds)
        let marker = CIImage(color: CIColor(red: 1, green: 0, blue: 0))
            .cropped(to: CGRect(x: 144, y: 115, width: 72, height: 58))
        CIContext().render(marker.composited(over: background), to: pixels)
        for index in 0..<25 {
            while !input.isReadyForMoreMediaData {
                try #require(writer.status == .writing)
                try await Task.sleep(for: .milliseconds(5))
            }
            try #require(adaptor.append(pixels, withPresentationTime: CMTime(value: Int64(index), timescale: 25)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        try #require(writer.status == .completed)
    }
}
