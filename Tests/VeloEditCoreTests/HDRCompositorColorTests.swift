import AVFoundation
import CoreImage
import Foundation
import ImageIO
import Testing
@testable import VeloEditCore

@Suite(.serialized) struct HDRCompositorColorTests {
    @Test func editorPreviewUsesDeliveryColorsInAMixedProject() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("veloedit-preview-color-\(UUID())")
        let store = try ProjectStore(createAt: root, name: "Preview color regression")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("colors.mov")
        try await makeSource(at: source)
        // A mixed project used to switch the entire editor (including SDR
        // shots and titles) to HLG, while delivery remained Rec.709.
        let assets = [DynamicRange.hdr, .sdr].map { range in
            MediaAsset(originalURL: source, kind: .video, byteSize: 1, contentHash: UUID().uuidString,
                metadata: MediaMetadata(duration: 1, width: 96, height: 64, frameRate: 30,
                    dynamicRange: range, hasAudio: false))
        }
        let clips = assets.enumerated().map { index, asset in
            TimelineItem(assetID: asset.id, kind: .video, sourceDuration: 1,
                timelineStart: Double(index), timelineDuration: 1)
        }
        let timeline = Timeline(storyPlanID: UUID(), width: 96, height: 64, frameRate: 30,
            items: clips, effects: [.init(effectType: .pushIn, startTime: 0, duration: 2, intensity: 0)])
        var snapshot = await store.manifest
        snapshot.assets = assets
        snapshot.timelines = [timeline]
        let preview = try await VeloEditPipeline(store: store).makePlayback(projectSnapshot: snapshot)
        let composition = try #require(preview.videoComposition)
        #expect(composition.colorPrimaries == AVVideoColorPrimaries_ITU_R_709_2)
        #expect(composition.colorTransferFunction == AVVideoTransferFunction_ITU_R_709_2)
        let delivery = try await PlaybackEngine().build(timeline: timeline, assets: assets, outputColorProfile: .rec709)
        for time in [0.5, 1.5] {
            let error = try difference(frame(preview, at: time), frame(delivery, at: time))
            #expect(error < 0.01, "Preview changed delivery colors by \(error)")
        }
    }

    @Test(arguments: [VideoTransferFunction.hlg, .pq])
    func enablingEffectsPreservesNativeHDRColors(transfer: VideoTransferFunction) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("veloedit-hdr-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("colors.mov")
        try await makeSource(at: source)
        let asset = MediaAsset(originalURL: source, kind: .video, byteSize: 1, contentHash: UUID().uuidString,
            metadata: MediaMetadata(duration: 1, width: 96, height: 64, frameRate: 30, dynamicRange: .sdr, hasAudio: false))
        let clip = TimelineItem(assetID: asset.id, kind: .video, sourceDuration: 1, timelineStart: 0, timelineDuration: 1)
        var timeline = Timeline(storyPlanID: UUID(), width: 96, height: 64, frameRate: 30, items: [clip])
        let profile = VideoColorProfile(dynamicRange: .hdr, transferFunction: transfer, bitDepth: 10)
        let native = try await PlaybackEngine().build(timeline: timeline, assets: [asset],
            outputColorProfile: profile, forceVideoComposition: true)
        timeline.effects = [.init(effectType: .pushIn, startTime: 0, duration: 1, intensity: 0)]
        let custom = try await PlaybackEngine().build(timeline: timeline, assets: [asset], outputColorProfile: profile)
        #expect(native.videoComposition?.customVideoCompositorClass == nil)
        #expect(custom.videoComposition?.customVideoCompositorClass != nil)
        let error = try difference(frame(custom, at: 0.5), frame(native, at: 0.5))
        #expect(error < 0.025, "\(transfer): merely enabling the custom compositor changed colors by \(error)")
    }

    /// Reads originals without loading/migrating or saving the project package.
    @Test func realMixedProjectPreviewMatchesNativeRenderer() async throws {
        guard let path = ProcessInfo.processInfo.environment["VELOEDIT_HDR_QA_PROJECT"] else { return }
        let data = try Data(contentsOf: URL(fileURLWithPath: path).appendingPathComponent("project.json"))
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let project = try decoder.decode(ProjectManifest.self, from: data)
        let original = try #require(project.timelines.first)
        let hdrAsset = try #require(project.assets.first { $0.metadata.dynamicRange == .hdr })
        let sdrAsset = try #require(project.assets.first { $0.metadata.dynamicRange == .sdr })
        let assets = [hdrAsset, sdrAsset]
        let clips = assets.enumerated().map { index, asset in
            TimelineItem(assetID: asset.id, kind: .video, sourceStart: 5, sourceDuration: 1,
                         timelineStart: Double(index), timelineDuration: 1)
        }
        let timeline = Timeline(storyPlanID: original.storyPlanID, width: 320, height: 180, frameRate: 30,
            items: clips, effects: [EffectTimelineItem(effectType: .pushIn, startTime: 0, duration: 2, intensity: 0)])
        let playback = try await PlaybackEngine().build(timeline: timeline, assets: assets)
        let profile = VideoColorPipeline.profile(timeline: timeline, assets: assets)
        for index in assets.indices {
            let reference = try await PlaybackEngine().build(timeline: Timeline(storyPlanID: original.storyPlanID,
                width: 320, height: 180, frameRate: 30, items: [clips[index]]), assets: [assets[index]],
                outputColorProfile: profile, forceVideoComposition: true)
            let actual = try frame(playback, at: Double(index) + 0.5)
            let expected = try frame(reference, at: 0.5)
            let error = try difference(actual, expected)
            #expect(error < 0.035, "\(assets[index].metadata.dynamicRange): custom preview differs from native by \(error)")
            if let folder = ProcessInfo.processInfo.environment["VELOEDIT_HDR_QA_OUTPUT"] {
                try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
                for (name, image) in [("preview", actual), ("reference", expected)] {
                    let url = URL(fileURLWithPath: folder).appendingPathComponent("\(index)-\(name).png")
                    let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
                    CGImageDestinationAddImage(destination, image, nil)
                    #expect(CGImageDestinationFinalize(destination))
                }
            }
        }
    }

    private func frame(_ playback: TimelinePlayback, at time: Double) throws -> CGImage {
        let generator = AVAssetImageGenerator(asset: playback.composition)
        generator.videoComposition = playback.videoComposition
        return try generator.copyCGImage(at: CMTime(seconds: time, preferredTimescale: 600), actualTime: nil)
    }

    private func difference(_ actual: CGImage, _ expected: CGImage) throws -> Double {
        #expect(actual.width == expected.width && actual.height == expected.height)
        let context = CIContext()
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        func pixels(_ image: CGImage) -> [UInt8] {
            var result = [UInt8](repeating: 0, count: image.width * image.height * 4)
            context.render(CIImage(cgImage: image), toBitmap: &result, rowBytes: image.width * 4,
                bounds: CGRect(x: 0, y: 0, width: image.width, height: image.height), format: .RGBA8, colorSpace: colorSpace)
            return result
        }
        let a = pixels(actual), b = pixels(expected)
        return zip(a, b).reduce(0.0) { $0 + abs(Double($1.0) - Double($1.1)) } / Double(a.count) / 255
    }

    private func makeSource(at url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 96, AVVideoHeightKey: 64,
            AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2]
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 96, kCVPixelBufferHeightKey as String: 64,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ])
        writer.add(input)
        try #require(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        var buffer: CVPixelBuffer?
        try #require(CVPixelBufferPoolCreatePixelBuffer(nil, try #require(adaptor.pixelBufferPool), &buffer) == kCVReturnSuccess)
        let pixelBuffer = try #require(buffer)
        let bounds = CGRect(x: 0, y: 0, width: 96, height: 64)
        var image = CIImage(color: .black).cropped(to: bounds)
        for (index, color) in [CIColor(red: 0.18, green: 0.18, blue: 0.18),
            CIColor(red: 0.5, green: 0.5, blue: 0.5), CIColor(red: 0.85, green: 0.85, blue: 0.85),
            CIColor(red: 0.7, green: 0.35, blue: 0.2)].enumerated() {
            image = CIImage(color: color).cropped(to: CGRect(x: index * 24, y: 0, width: 24, height: 64)).composited(over: image)
        }
        CIContext().render(image, to: pixelBuffer, bounds: bounds, colorSpace: VideoColorPipeline.cgColorSpace(for: .rec709))
        for index in 0..<30 {
            while !input.isReadyForMoreMediaData {
                try #require(writer.status == .writing)
                try await Task.sleep(for: .milliseconds(5))
            }
            try #require(adaptor.append(pixelBuffer, withPresentationTime: CMTime(value: Int64(index), timescale: 30)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        try #require(writer.status == .completed)
    }
}
