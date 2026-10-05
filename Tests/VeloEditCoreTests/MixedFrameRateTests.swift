import Foundation
import AVFoundation
import Testing
@testable import VeloEditCore

@Suite(.serialized)
struct MixedFrameRateTests {
    private func asset(_ fps: Double) -> MediaAsset {
        MediaAsset(originalURL: URL(fileURLWithPath: "/fps-\(fps).mov"), kind: .video,
                   byteSize: 1, contentHash: "\(fps)", metadata: MediaMetadata(duration: 120, frameRate: fps))
    }

    private func clip(_ asset: MediaAsset, duration: Double = 10, speed: Double = 1) -> TimelineItem {
        TimelineItem(assetID: asset.id, kind: .video, sourceDuration: duration * speed,
                     timelineStart: 0, timelineDuration: duration, speed: speed)
    }

    @Test func selectsUsefulHighRateWithoutDependingOnFileCountOrUnusedAssets() {
        let low = asset(30), high = asset(60), unused = asset(240)
        let items = [clip(low, duration: 80), clip(high, duration: 20)]
        #expect(TimelineFrameRatePolicy.automaticFrameRate(items: items, assets: [low, high, unused]) == 60)
        let splitLow = (0..<80).map { _ in clip(low, duration: 1) }
        #expect(TimelineFrameRatePolicy.automaticFrameRate(items: splitLow + [items[1]], assets: [high, low]) == 60)
        #expect(TimelineFrameRatePolicy.automaticFrameRate(items: [clip(low, duration: 99), clip(high, duration: 1)], assets: [low, high]) == 30)
        #expect(TimelineFrameRatePolicy.automaticFrameRate(items: [clip(unused)], assets: [unused]) == 60)
        var frozen = clip(unused); frozen.freezeFrame = true
        #expect(TimelineFrameRatePolicy.automaticFrameRate(items: [clip(low), frozen], assets: [low, unused]) == 30)
    }

    @Test func fractionalFamiliesAndSlowMotionPreserveTheirNaturalCadence() {
        let low = asset(30_000.0 / 1001), high = asset(60_000.0 / 1001), faster = asset(120)
        #expect(TimelineFrameRatePolicy.automaticFrameRate(items: [clip(low), clip(high)], assets: [low, high]) == 60_000.0 / 1001)
        #expect(TimelineFrameRatePolicy.automaticFrameRate(items: [clip(high, speed: 0.5)], assets: [high]) == 30_000.0 / 1001)
        #expect(TimelineFrameRatePolicy.automaticFrameRate(items: [clip(faster, speed: 0.25)], assets: [faster]) == 30)
        #expect(TimelineFrameRatePolicy.automaticFrameRate(items: [clip(faster, speed: 0.5)], assets: [faster]) == 60)
        let pal = asset(25), palHigh = asset(50), cinema = asset(24_000.0 / 1001)
        #expect(TimelineFrameRatePolicy.automaticFrameRate(items: [clip(pal), clip(palHigh)], assets: [pal, palHigh]) == 50)
        #expect(TimelineFrameRatePolicy.automaticFrameRate(items: [clip(cinema)], assets: [cinema]) == 24_000.0 / 1001)
        // The real HFR motion decides the fractional/integer clock when the
        // cameras use different variants of the same nominal rate family.
        let integer = asset(60)
        #expect(TimelineFrameRatePolicy.automaticFrameRate(items: [clip(low), clip(integer)], assets: [low, integer]) == 60)
        let integerLow = asset(30)
        #expect(TimelineFrameRatePolicy.automaticFrameRate(items: [clip(integerLow), clip(high)], assets: [integerLow, high]) == 60_000.0 / 1001)
        var ramp = clip(faster, speed: 0.25)
        ramp.speedRamp = SpeedRamp(points: [.init(position: 0, rate: 0.25), .init(position: 1, rate: 0.25)])
        #expect(TimelineFrameRatePolicy.automaticFrameRate(items: [ramp], assets: [faster]) == 30)
    }

    @Test func qualityDoesNotChangeClockAndExplicitExportRateWins() {
        let camera = asset(120)
        let timeline = Timeline(storyPlanID: UUID(), frameRate: 60_000.0 / 1001, items: [clip(camera)])
        for quality in [RenderQuality.preview720p, .preview1080p, .final1080p, .final4K, .maximum] {
            let resolved = ExportSettingsPolicy.timeline(timeline, assets: [camera], quality: quality)
            #expect(resolved.frameRate == timeline.frameRate)
            #expect(resolved.items == timeline.items)
            #expect(ExportSettingsPolicy.timeline(timeline, assets: [camera], quality: quality, frameRate: 30).frameRate == 30)
        }
    }

    @Test func automaticClockIsPersistedForManualEditsAndFixedProjectsStayFixed() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mixed-clock-\(UUID()).veloedit")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ProjectStore(createAt: root, name: "Mixed rates")
        let low = asset(30), high = asset(60)
        var automatic = Timeline(storyPlanID: UUID(), items: [clip(low)])
        automatic.automaticallySelectFrameRate = true
        let fixed = Timeline(storyPlanID: UUID(), frameRate: 30, items: [clip(high)])
        try await store.update { $0.assets = [low, high]; $0.timelines = [fixed, automatic] }
        try await store.update { $0.timelines[1].items.append(clip(high)) }
        let saved = await store.manifest
        #expect(saved.timelines.map(\.frameRate) == [30, 60])
        let reopened = try ProjectStore(open: root)
        #expect(await reopened.manifest.timelines.map(\.frameRate) == [30, 60])
        try await store.update {
            $0.timelines[1].items[1].sourceDuration = 5
            $0.timelines[1].items[1].speed = 0.5
        }
        #expect(await store.manifest.timelines[1].frameRate == 30)
    }

    @Test func fractionalEditClockDoesNotAccumulateRoundingAcrossCuts() {
        for fps in [24_000.0 / 1001, 30_000.0 / 1001, 48_000.0 / 1001, 60_000.0 / 1001] {
            let duration = 7 / fps
            let items = (0..<1_000).map { index in
                TimelineItem(kind: .video, sourceDuration: duration, timelineStart: Double(index) * duration, timelineDuration: duration)
            }
            let timeline = Timeline(storyPlanID: UUID(), frameRate: fps, items: items)
            #expect(abs(AutomaticFilmDurationPolicy.renderedDuration(of: timeline) - 7_000 / fps) < 0.000_01)
        }
    }

    @Test func fcpxmlPreservesBothSourceClocksAndFractionalSequence() throws {
        let low = asset(30_000.0 / 1001), high = asset(60_000.0 / 1001)
        var first = clip(high); first.sourceStart = 1001.0 / 60_000
        let timeline = Timeline(storyPlanID: UUID(), frameRate: 30_000.0 / 1001, items: [first, clip(low)])
        let xml = try FCPXMLExporter().xml(timeline: timeline, assets: [low, high])
        let document = try XMLDocument(xmlString: xml)
        let format = try #require(try document.nodes(forXPath: "/fcpxml/resources/format[@id='r_format']").first as? XMLElement)
        #expect(format.attribute(forName: "frameDuration")?.stringValue == "1001/30000s")
        let source = try #require(try document.nodes(forXPath: "/fcpxml/resources/asset")
            .compactMap { $0 as? XMLElement }.first { $0.attribute(forName: "name")?.stringValue == high.displayName })
        let formatID = try #require(source.attribute(forName: "format")?.stringValue)
        let sourceFormat = try #require(try document.nodes(forXPath: "/fcpxml/resources/format[@id='\(formatID)']").first as? XMLElement)
        #expect(sourceFormat.attribute(forName: "frameDuration")?.stringValue == "1001/60000s")
        let firstClip = try #require(try document.nodes(forXPath: "//spine/asset-clip").first as? XMLElement)
        #expect(firstClip.attribute(forName: "start")?.stringValue == "1001/60000s")
    }

    @Test func generatedTitlesKeepExactFractionalFrameTimes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("fractional-title-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for fps in [30_000.0 / 1001, 60_000.0 / 1001] {
            let url = root.appendingPathComponent("title-\(fps).mov")
            _ = try await TitleCardVideoGenerator().generate(text: "FPS", style: TitleStyle(), duration: 10 / fps,
                                                            width: 320, height: 180, frameRate: fps,
                                                            destination: url, codec: .proRes4444)
            let frames = try await Self.readNumbers(url, fps: fps)
            #expect(frames.count == 10)
            #expect(abs(try await AVURLAsset(url: url).load(.duration).seconds - 10 / fps) < 0.000_01)
        }
    }

    /// Each source frame contains a binary frame number. Checking decoded
    /// pixels detects missing motion even when the container reports 60 fps.
    @Test(arguments: [false, true], [false, true])
    func actualMixedExportPreservesMotionAtBothDeliveryRates(fractional: Bool, customCompositor: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mixed-fps-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let low = fractional ? 30_000.0 / 1001 : 30
        let high = low * 2
        let urls = [root.appendingPathComponent("30.mov"), root.appendingPathComponent("60.mov")]
        try await Self.writeNumberedVideo(urls[0], fps: low, tag: 1)
        try await Self.writeNumberedVideo(urls[1], fps: high, tag: 2)
        for (index, rate) in [low, high].enumerated() {
            let sourceFrames = try await Self.readNumbers(urls[index], fps: rate)
            #expect(sourceFrames == (0..<120).map { (index + 1) * 256 + $0 })
        }
        let imported = await MediaImporter().importAssets(from: urls)
        let assets = try imported.map { try $0.get() }.sorted { $0.originalURL.lastPathComponent < $1.originalURL.lastPathComponent }
        let duration = 30 / low
        let items = [
            TimelineItem(assetID: assets[0].id, kind: .video, sourceStart: 10 / low, sourceDuration: duration, timelineStart: 0, timelineDuration: duration),
            TimelineItem(assetID: assets[1].id, kind: .video, sourceStart: 10 / high, sourceDuration: duration, timelineStart: duration, timelineDuration: duration),
            TimelineItem(assetID: assets[1].id, kind: .video, sourceStart: 10 / high, sourceDuration: duration / 2, timelineStart: duration * 2, timelineDuration: duration, speed: 0.5)
        ]
        var timeline = Timeline(storyPlanID: UUID(), width: 320, height: 180, items: items, originalAudioVolume: 0)
        timeline.automaticallySelectFrameRate = true
        timeline = TimelineFrameRatePolicy.applying(to: timeline, assets: assets)
        if customCompositor {
            timeline.effects = [.init(effectType: .brightness, startTime: 0, duration: timeline.duration, intensity: 0.02)]
        }
        #expect(abs(timeline.frameRate - high) < 0.000_001)
        let preview = try await PlaybackEngine().build(timeline: timeline, assets: assets)
        #expect(preview.videoComposition?.frameDuration == VideoFrameTiming.duration(for: high))

        for fps in [high, low] {
            let url = root.appendingPathComponent("output-\(fps).mp4")
            _ = try await RenderEngine().render(timeline: timeline, assets: assets, quality: .maximum,
                                                frameRate: fps == high ? nil : fps, destination: url)
            let frames = try await Self.readNumbers(url, fps: fps)
            let perClip = fps == high ? 60 : 30
            #expect(frames.count == perClip * 3)
            for (position, value) in frames.enumerated() {
                let section = position / perClip, index = position % perClip
                let sourceIndex = section == 1 ? (fps == high ? index : index * 2) : (fps == high ? index / 2 : index)
                let expected = (section == 0 ? 1 : 2) * 256 + 10 + sourceIndex
                #expect(value == expected, "fps=\(fps), frame=\(position): decoded=\(value), expected=\(expected)")
            }
        }
    }

    private static func writeNumberedVideo(_ url: URL, fps: Double, tag: Int) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.proRes422, AVVideoWidthKey: 320, AVVideoHeightKey: 180
        ])
        input.mediaTimeScale = VideoFrameTiming.duration(for: fps).timescale
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 180,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ])
        writer.add(input)
        try #require(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        let step = VideoFrameTiming.duration(for: fps)
        for frame in 0..<120 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            let pool = try #require(adaptor.pixelBufferPool)
            var optional: CVPixelBuffer?
            try #require(CVPixelBufferPoolCreatePixelBuffer(nil, pool, &optional) == kCVReturnSuccess)
            let buffer = try #require(optional)
            CVPixelBufferLockBaseAddress(buffer, [])
            let bytes = try #require(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(buffer)
            let number = tag * 256 + frame
            for y in 0..<180 {
                for x in 0..<320 {
                    let value: UInt8 = number & (1 << (x / 32)) == 0 ? 16 : 235
                    let offset = y * stride + x * 4
                    bytes[offset] = value; bytes[offset + 1] = value; bytes[offset + 2] = value; bytes[offset + 3] = 255
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            try #require(adaptor.append(buffer, withPresentationTime: CMTimeMultiply(step, multiplier: Int32(frame))))
        }
        writer.endSession(atSourceTime: CMTimeMultiply(step, multiplier: 120))
        input.markAsFinished()
        await writer.finishWriting()
        #expect(writer.status == .completed)
    }

    private static func readNumbers(_ url: URL, fps: Double) async throws -> [Int] {
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output)
        try #require(reader.startReading())
        var result: [Int] = []
        while let sample = output.copyNextSampleBuffer() {
            #expect(abs(CMSampleBufferGetPresentationTimeStamp(sample).seconds - Double(result.count) / fps) < 0.000_01)
            let buffer = try #require(CMSampleBufferGetImageBuffer(sample))
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            let bytes = try #require(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
            let row = 90 * CVPixelBufferGetBytesPerRow(buffer)
            let value = (0..<10).reduce(0) { value, bit in
                value | (bytes[row + (bit * 32 + 16) * 4] > 128 ? 1 << bit : 0)
            }
            CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
            result.append(value)
        }
        #expect(reader.status == .completed)
        return result
    }
}
