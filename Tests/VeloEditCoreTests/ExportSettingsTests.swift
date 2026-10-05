import Foundation
import AVFoundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import Testing
@testable import VeloEditCore

@Suite(.serialized)
struct ExportSettingsTests {
    @Test func measuredCadenceRejectsMissingDuplicatedAndWrongRateFrames() {
        let times = (0..<15).map { Double($0) / 30 }
        #expect(ExportVideoVerifier.regularCadence(times: times, expectedRate: 30, duration: 0.5) == 30)
        #expect(ExportVideoVerifier.regularCadence(times: Array(times.reversed()), expectedRate: 30, duration: 0.5) == 30)
        #expect(ExportVideoVerifier.regularCadence(times: times, expectedRate: 25, duration: 0.5) == nil)
        var gap = times; gap.remove(at: 7)
        #expect(ExportVideoVerifier.regularCadence(times: gap, expectedRate: 30, duration: 0.5) == nil)
        var repeated = times; repeated[7] = repeated[6]
        #expect(ExportVideoVerifier.regularCadence(times: repeated, expectedRate: 30, duration: 0.5) == nil)
    }

    @Test func shortMP4WithFractionalTailUsesActualCadence() async throws {
        let fixture = try await Fixture.make(duration: 0.5)
        defer { fixture.remove() }
        let output = fixture.root.appendingPathComponent("cadence-original.mp4")
        _ = try await RenderEngine().render(timeline: fixture.timeline, assets: [fixture.asset], quality: .preview720p,
                                            frameRate: 30, destination: output)
        let trimmed = fixture.root.appendingPathComponent("cadence-trimmed.mp4")
        let session = try #require(AVAssetExportSession(asset: AVURLAsset(url: output), presetName: AVAssetExportPresetPassthrough))
        session.outputURL = trimmed; session.outputFileType = .mp4
        session.timeRange = CMTimeRange(start: .zero, duration: CMTime(value: 299, timescale: 600))
        try await EditorialAudioMastering.export(session, timeout: 60)
        var timeline = fixture.timeline; timeline.width = 1280; timeline.height = 720; timeline.frameRate = 30
        let info = try await ExportVideoVerifier.verify(url: trimmed,
            settings: ExportVideoSettings(timeline: timeline, quality: .preview720p), duration: 0.5)
        #expect(abs(info.frameRate - 30) < 0.005)
        let asset = AVURLAsset(url: trimmed)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        #expect(try await ExportVideoVerifier.measuredCadence(asset: asset, track: track, expectedRate: 30, duration: 0.5) != nil)
        #expect(try await ExportVideoVerifier.measuredCadence(asset: asset, track: track, expectedRate: 25, duration: 0.5) == nil)
    }

    @Test func maximumUsesOnlyEditedOriginalsAndPreservesTimelineFrameRate() {
        let used = MediaAsset(originalURL: URL(fileURLWithPath: "/original.mov"), kind: .video, byteSize: 1, contentHash: "used",
                              metadata: MediaMetadata(width: 5312, height: 2988, frameRate: 60_000.0 / 1001))
        let unused = MediaAsset(originalURL: URL(fileURLWithPath: "/unused.mov"), kind: .video, byteSize: 1, contentHash: "unused",
                                metadata: MediaMetadata(width: 7680, height: 4320, frameRate: 240))
        let timeline = Timeline(storyPlanID: UUID(), width: 1920, height: 1080, frameRate: 30,
                                items: [TimelineItem(assetID: used.id, kind: .video, sourceDuration: 1, timelineStart: 0, timelineDuration: 1)])
        let auto = ExportSettingsPolicy.timeline(timeline, assets: [used, unused], quality: .maximum)
        #expect(auto.width == 5312 && auto.height == 2988)
        #expect(auto.frameRate == timeline.frameRate)
        let manual = ExportSettingsPolicy.timeline(timeline, assets: [used, unused], quality: .maximum, frameRate: 25)
        #expect(manual.frameRate == 25)
        let fixed = ExportSettingsPolicy.timeline(timeline, assets: [used, unused], quality: .final1080p, frameRate: 30_000.0 / 1001)
        #expect(fixed.width == 1920 && fixed.height == 1080)
        #expect(VideoFrameTiming.duration(for: fixed.frameRate) == CMTime(value: 1001, timescale: 30_000))
    }

    @Test func actualMP4MatchesEveryResolutionAndFractionalFrameRate() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.remove() }
        let cases: [(RenderQuality, Int, Int, Double)] = [
            (.preview720p, 1280, 720, 25),
            (.preview1080p, 1920, 1080, 30_000.0 / 1001),
            (.final1080p, 1920, 1080, 60_000.0 / 1001),
            (.final4K, 3840, 2160, 24),
            (.maximum, 1920, 1080, 24_000.0 / 1001)
        ]
        var rows = ["mode,width,height,fps,codec,actual_bps,frames"]
        for (quality, width, height, fps) in cases {
            let url = fixture.root.appendingPathComponent("\(quality.rawValue).mp4")
            try Data("previous export".utf8).write(to: url)
            let report = try await RenderEngine().render(timeline: fixture.timeline, assets: [fixture.asset], quality: quality,
                                                         frameRate: fps, destination: url)
            let info = try #require(report.videoInfo)
            #expect(info.width == width && info.height == height)
            #expect(abs(info.frameRate - fps) < 0.005)
            #expect(info.codec == (quality == .maximum || quality == .final4K ? "HEVC" : "H.264"))
            #expect(info.videoBitRate > 0)
            let count = try await Self.checkTimestamps(url, fps: fps, duration: fixture.timeline.duration)
            rows.append("\(quality.rawValue),\(info.width),\(info.height),\(info.frameRate),\(info.codec),\(info.videoBitRate),\(count)")
        }
        for fps in [50.0, 120.0, 240.0] {
            var timeline = fixture.timeline
            timeline.width = 320; timeline.height = 180
            let url = fixture.root.appendingPathComponent("fps-\(Int(fps)).mp4")
            // No source size in this fixture variant: retain its small canvas.
            var asset = fixture.asset
            asset.metadata.width = 320; asset.metadata.height = 180
            let report = try await RenderEngine().render(timeline: timeline, assets: [asset], quality: .maximum, frameRate: fps, destination: url)
            let info = try #require(report.videoInfo)
            let count = try await Self.checkTimestamps(url, fps: fps, duration: timeline.duration)
            rows.append("fps,\(info.width),\(info.height),\(info.frameRate),\(info.codec),\(info.videoBitRate),\(count)")
        }
        for (width, height) in [(1080, 1920), (2560, 1080)] {
            var timeline = fixture.timeline
            timeline.width = width; timeline.height = height
            let url = fixture.root.appendingPathComponent("aspect-\(width).mp4")
            let report = try await RenderEngine().render(timeline: timeline, assets: [fixture.asset], quality: .final1080p,
                                                         frameRate: 30, destination: url)
            let info = try #require(report.videoInfo)
            #expect(info.width == (width == 1080 ? 1080 : 1920))
            #expect(info.height == (width == 1080 ? 1920 : 810))
            _ = try await Self.checkTimestamps(url, fps: 30, duration: timeline.duration)
        }
        try rows.joined(separator: "\n").write(to: fixture.root.appendingPathComponent("settings.csv"), atomically: true, encoding: .utf8)
    }

    @Test func originalsWinOverPreviewCopiesAndHighQualityPreservesFineDetail() async throws {
        let fixture = try await Fixture.make(duration: 1)
        defer { fixture.remove() }
        let proxyImage = fixture.root.appendingPathComponent("proxy.png")
        let blank = CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: 320, height: 180))
        try Self.save(blank, to: proxyImage)
        let proxy = fixture.root.appendingPathComponent("preview.mp4")
        _ = try await StillImageVideoGenerator().generate(imageURL: proxyImage, duration: 1, width: 320, height: 180,
                                                          frameRate: 60, destination: proxy, codec: .jpeg, motion: nil)
        let playback = try await PlaybackEngine().build(timeline: fixture.timeline, assets: [fixture.asset], forceVideoComposition: true)
        let referenceGenerator = AVAssetImageGenerator(asset: playback.composition)
        referenceGenerator.videoComposition = playback.videoComposition
        referenceGenerator.requestedTimeToleranceBefore = .zero
        referenceGenerator.requestedTimeToleranceAfter = .zero
        let reference = try referenceGenerator.copyCGImage(at: CMTime(seconds: 0.2, preferredTimescale: 600), actualTime: nil)
        var errors: [RenderQuality: Double] = [:]
        for quality in [RenderQuality.preview1080p, .final1080p, .maximum] {
            let output = fixture.root.appendingPathComponent("detail-\(quality.rawValue).mp4")
            _ = try await RenderEngine().render(timeline: fixture.timeline, assets: [fixture.asset],
                                                preferredVideoSources: [fixture.asset.id: proxy], quality: quality, frameRate: 60, destination: output)
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: output))
            generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
            let result = try generator.copyCGImage(at: CMTime(seconds: 0.2, preferredTimescale: 600), actualTime: nil)
            errors[quality] = Self.meanSquaredError(reference, result, allowedMeanShift: quality == .maximum ? 0.005 : 0.01)
            if ProcessInfo.processInfo.environment["VELOEDIT_EXPORT_QA_ROOT"] != nil {
                try Self.save(CIImage(cgImage: result), to: fixture.root.appendingPathComponent("frame-\(quality.rawValue).png"))
                try Self.save(CIImage(cgImage: reference), to: fixture.root.appendingPathComponent("reference.png"))
            }
        }
        let compact = try #require(errors[.preview1080p]), final = try #require(errors[.final1080p]), maximum = try #require(errors[.maximum])
        // A substituted black 320p proxy, JPEG generation loss or an ignored
        // bitrate setting must fail on this moving fine-detail chart.
        // This chart fills every pixel with moving high-frequency noise:
        // require >26 dB PSNR and an improvement over the compact encoder.
        // It is intentionally harder to compress than normal camera footage.
        #expect(maximum < 0.0025)
        #expect(final < compact * 0.9)
        #expect(maximum < compact * 0.9)
        try "preview_mse=\(compact)\nfinal_mse=\(final)\nmaximum_mse=\(maximum)\n".write(to: fixture.root.appendingPathComponent("detail.txt"), atomically: true, encoding: .utf8)
    }

    @Test func mismatchedFileIsRejectedAndTitleCardsKeepFullResolution() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.remove() }
        var wrong = fixture.timeline; wrong.frameRate = 25
        do {
            _ = try await ExportVideoVerifier.verify(url: fixture.asset.originalURL,
                                                     settings: ExportVideoSettings(timeline: wrong, quality: .final1080p), duration: 0.3)
            Issue.record("An incorrectly encoded file must not be reported as a successful export")
        } catch DerivedMediaError.exportFailed { }
        let title = fixture.root.appendingPathComponent("title.mov")
        _ = try await TitleCardVideoGenerator().generate(text: "Чёткие титры", style: TitleStyle(fontSize: 72), duration: 0.1,
                                                         width: 1920, height: 1080, frameRate: 30, destination: title, codec: .proRes4444)
        let track = try #require(try await AVURLAsset(url: title).loadTracks(withMediaType: .video).first)
        #expect(try await track.load(.naturalSize) == CGSize(width: 1920, height: 1080))
        for fps in [Double.nan, Double.infinity, 0, 241] {
            var invalid = fixture.timeline; invalid.frameRate = fps
            let report = await ExportPreflight().inspect(timeline: invalid, assets: [fixture.asset], destination: fixture.root.appendingPathComponent("invalid.mp4"), quality: .maximum)
            #expect(!report.canExport)
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["VELOEDIT_EXPORT_REAL_SOURCE"] != nil))
    func realGoProExportsAtOriginal5KAndFractionalFPS() async throws {
        let source = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["VELOEDIT_EXPORT_REAL_SOURCE"]))
        let results = await MediaImporter().importAssets(from: [source])
        let asset = try #require(results.first).get()
        let root = Self.root()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try ProjectStore(createAt: root.appendingPathComponent("gopro.veloedit"), name: "Export QA")
        let item = TimelineItem(assetID: asset.id, kind: .video, sourceStart: 10, sourceDuration: 0.5, timelineStart: 0, timelineDuration: 0.5)
        var timeline = Timeline(storyPlanID: UUID(), width: 1920, height: 1080, items: [item], originalAudioVolume: 0)
        timeline.automaticallySelectFrameRate = true
        timeline = TimelineFrameRatePolicy.applying(to: timeline, assets: [asset])
        try await store.update { project in project.assets = [asset]; project.timelines = [timeline] }
        let proxyImage = root.appendingPathComponent("black-proxy.png")
        try Self.save(CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: 320, height: 180)), to: proxyImage)
        let paths = CachePaths(root: await store.cacheURL)
        _ = try await StillImageVideoGenerator().generate(imageURL: proxyImage, duration: 11, width: 320, height: 180,
                                                          frameRate: 10, destination: paths.previewProxy(for: asset), codec: .jpeg, motion: nil)
        let output = root.appendingPathComponent("gopro-maximum.mp4")
        let report = try await VeloEditPipeline(store: store).render(to: output, quality: .maximum)
        let info = try #require(report.videoInfo)
        #expect(info.width == asset.displayDimensions?.width && info.height == asset.displayDimensions?.height)
        #expect(abs(info.frameRate - (asset.metadata.frameRate ?? 0)) < 0.005)
        #expect(info.codec == "HEVC")
        let decoded = AVAssetImageGenerator(asset: AVURLAsset(url: output))
        let actualFrame = try decoded.copyCGImage(at: CMTime(seconds: 0.2, preferredTimescale: 600), actualTime: nil)
        #expect(!FrameQualityInspector.assess(image: actualFrame).isBlack, "A cached preview must never replace the original GoPro")
        _ = try await Self.checkTimestamps(output, fps: info.frameRate, duration: 0.5)
        try info.summary.write(to: root.appendingPathComponent("gopro.txt"), atomically: true, encoding: .utf8)
    }

    private static func checkTimestamps(_ url: URL, fps: Double, duration: Double) async throws -> Int {
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output)
        try #require(reader.startReading())
        var previous: Double?, count = 0
        while let sample = output.copyNextSampleBuffer() {
            let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            if let previous { #expect(abs(pts - previous - 1 / fps) < 0.00001) }
            else { #expect(abs(pts) < 0.00001) }
            #expect(CMSampleBufferGetImageBuffer(sample) != nil)
            previous = pts; count += 1
        }
        #expect(reader.status == .completed)
        #expect(abs(Double(count) - ceil(duration * fps)) <= 1)
        return count
    }

    private static func root() -> URL {
        ProcessInfo.processInfo.environment["VELOEDIT_EXPORT_QA_ROOT"].map { URL(fileURLWithPath: $0).appendingPathComponent(UUID().uuidString) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("veloedit-export-settings-\(UUID())")
    }
    private struct Fixture {
        var root: URL; var asset: MediaAsset; var timeline: Timeline
        func remove() { if ProcessInfo.processInfo.environment["VELOEDIT_EXPORT_QA_ROOT"] == nil { try? FileManager.default.removeItem(at: root) } }
        static func make(duration: Double = 0.3) async throws -> Fixture {
            let root = ExportSettingsTests.root()
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let width = 1920, height = 1080
            var pixels = [UInt8](repeating: 255, count: width * height * 4)
            for y in 0..<height {
                for x in 0..<width {
                    let n = (x &* 73 &+ y &* 151) ^ ((x / 3) &* (y / 3))
                    let value = UInt8(40 + abs(n) % 176)
                    let offset = (y * width + x) * 4
                    pixels[offset] = value; pixels[offset + 1] = value; pixels[offset + 2] = value
                }
            }
            let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
            let bitmap = try #require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                              space: CGColorSpace(name: CGColorSpace.itur_709)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                              provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
            let imageURL = root.appendingPathComponent("detail.png")
            try ExportSettingsTests.save(CIImage(cgImage: bitmap), to: imageURL)
            let video = root.appendingPathComponent("original.mov")
            _ = try await StillImageVideoGenerator().generate(imageURL: imageURL, duration: duration + 0.1, width: width, height: height,
                                                              frameRate: 60, destination: video, codec: .proRes4444, motion: .panLeft)
            let asset = MediaAsset(originalURL: video, kind: .video, byteSize: 1, contentHash: "fine-detail",
                                   metadata: MediaMetadata(duration: duration + 0.1, width: width, height: height, frameRate: 60, hasAudio: false))
            let item = TimelineItem(assetID: asset.id, kind: .video, sourceDuration: duration, timelineStart: 0, timelineDuration: duration,
                                    videoAdjustments: VideoAdjustments(crop: .fit))
            let timeline = Timeline(storyPlanID: UUID(), width: width, height: height, frameRate: 60, items: [item],
                                    effects: [EffectTimelineItem(effectType: .brightness, startTime: 0, duration: duration, intensity: 0.02)], originalAudioVolume: 0)
            return Fixture(root: root, asset: asset, timeline: timeline)
        }
    }
    private static func save(_ image: CIImage, to url: URL) throws {
        let bitmap = try #require(CIContext().createCGImage(image, from: image.extent))
        let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, bitmap, nil)
        try #require(CGImageDestinationFinalize(dest))
    }
    private static func meanSquaredError(_ lhs: CGImage, _ rhs: CGImage, allowedMeanShift: Double) -> Double {
        func pixels(_ image: CGImage) -> [UInt8] {
            var data = [UInt8](repeating: 0, count: 1920 * 1080 * 4)
            data.withUnsafeMutableBytes { bytes in
                let context = CGContext(data: bytes.baseAddress, width: 1920, height: 1080, bitsPerComponent: 8, bytesPerRow: 1920 * 4,
                                        space: CGColorSpace(name: CGColorSpace.itur_709)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                context.draw(image, in: CGRect(x: 0, y: 0, width: 1920, height: 1080))
            }
            return data
        }
        let a = pixels(lhs), b = pixels(rhs)
        var sum = 0.0, bias = 0.0
        for index in stride(from: 0, to: a.count, by: 4) {
            let delta = Double(a[index]) - Double(b[index]); sum += delta * delta; bias += delta
        }
        #expect(abs(bias / Double(1920 * 1080) / 255) < allowedMeanShift, "Export must not shift the transfer curve / midtone brightness")
        return sum / Double(1920 * 1080) / (255 * 255)
    }
}
