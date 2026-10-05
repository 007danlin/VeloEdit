import Foundation
import CoreGraphics
import Testing
@testable import VeloEditCore

@Suite(.serialized)
struct FilmSpeedAndTitlesTests {
    func fixture() -> (Timeline, TitleTimelineItem) {
        var title = TitleTemplateRegistry.template(id: "title.minimal-clean.v1")!.previewItem()
        title.text = "В дороге"
        title.startTime = 0
        title.duration = 3.5
        title.animation = .init(entrance: .none, exit: .none, duration: 0)
        title.style = EditorialPresentationPolicy.compactChapterStyle
        let timeline = Timeline(storyPlanID: UUID(), items: [.init(kind: .video, sourceDuration: 5, timelineStart: 0, timelineDuration: 5)], titleItems: [title])
        return (timeline, title)
    }

    func image(title: TitleTimelineItem, size: CGSize, background: CGFloat = 0.1, blank: Bool = false) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: background, alpha: 1)); context.fill(CGRect(origin: .zero, size: size))
        if !blank {
            let overlay = try #require(TitleOverlayRenderer.cgImage(item: title, timelineTime: 1.75, renderSize: size))
            context.draw(overlay, in: CGRect(origin: .zero, size: size))
        }
        return try #require(context.makeImage())
    }

    @Test func titleOCRUsesRealPixelsAndRejectsNegativeExamples() throws {
        let (timeline, title) = fixture()
        for size in [CGSize(width: 1920, height: 1080), CGSize(width: 1080, height: 1920)] {
            let pixels = try image(title: title, size: size)
            let read = TitleReadabilityInspector.inspect(image: pixels, title: title, timeline: timeline, time: 1.75, actualPTS: 1.75, source: "preview")
            #expect(read.passed, "\(read)")
            #expect(read.recognizedText.lowercased().contains("дороге"))
            let blank = try image(title: title, size: size, blank: true)
            #expect(!TitleReadabilityInspector.inspect(image: blank, title: title, timeline: timeline, time: 1.75, actualPTS: 1.75, source: "preview").passed)
            var lowContrast = title
            lowContrast.style.textColorHex = "#FFFFFF"
            lowContrast.style.shadow = 0
            lowContrast.style.strokeWidth = 0
            lowContrast.style.backgroundOpacity = 0
            let white = try image(title: lowContrast, size: size, background: 1)
            #expect(!TitleReadabilityInspector.inspect(image: white, title: lowContrast, timeline: timeline, time: 1.75, actualPTS: 1.75, source: "preview").passed)
            var outside = title; outside.style.xPosition = 3
            #expect(!TitleReadabilityInspector.inspect(image: pixels, title: outside, timeline: timeline, time: 1.75, actualPTS: 1.75, source: "preview").passed)
            var tiny = title; tiny.style.opacity = 0.05
            let invisible = try image(title: tiny, size: size)
            #expect(!TitleReadabilityInspector.inspect(image: invisible, title: tiny, timeline: timeline, time: 1.75, actualPTS: 1.75, source: "preview").passed)
            let clipped = try #require(pixels.cropping(to: CGRect(x: 0, y: 0, width: size.width / 10, height: size.height)))
            #expect(!TitleReadabilityInspector.inspect(image: clipped, title: title, timeline: timeline, time: 1.75, actualPTS: 1.75, source: "preview").passed)
        }
        #expect(!TitleReadabilityInspector.inspect(image: nil, title: title, timeline: timeline, time: 1.75, actualPTS: nil, source: "mp4").passed)
    }

    @Test func tokenNormalizationDoesNotAcceptSubstringsOrInventRepeatedWords() {
        #expect(TitleReadabilityInspector.score(expected: "В дороге", recognized: "В ДОРОГЕ") == 1)
        #expect(TitleReadabilityInspector.score(expected: "дома", recognized: "домашний") == 0)
        #expect(TitleReadabilityInspector.score(expected: "да да да", recognized: "да") == 1.0 / 3)
        #expect(TitleReadabilityInspector.score(expected: "на\nприроде", recognized: "На природе!") == 1)
        #expect(TitleReadabilityInspector.score(expected: "Багги", recognized: "") == 0)
    }

    @Test func everyTitleNeedsAllPointsAndIndependentCurrentMP4Evidence() {
        let (timeline, title) = fixture()
        let times = TitleReadabilityInspector.times(title, frameRate: 30)
        #expect(times.count == 3)
        #expect(times.first! < 0.04 && times.last! > 3.46)
        let evidence = times.map { time in
            TitleReadabilityEvidence(titleID: title.id, renderSignature: EditorialRenderSignature.signature(timeline), algorithmVersion: TitleReadabilityInspector.version,
                timelineTime: time, actualPTS: time, source: "preview", expectedText: title.text, recognizedText: title.text, confidences: [1], pixelWidth: 1920, pixelHeight: 1080, score: 1)
        }
        #expect(TitleReadabilityInspector.coverage(timeline: timeline, evidence: evidence, source: "preview").passed)
        #expect(!TitleReadabilityInspector.coverage(timeline: timeline, evidence: Array(evidence.prefix(1)), source: "preview").complete)
        #expect(!TitleReadabilityInspector.coverage(timeline: timeline, evidence: evidence, source: "mp4").passed)
        var edited = timeline; edited.titleItems?[0].style.fontSize = 99
        #expect(!evidence[0].isCurrent(for: edited))
        #expect(!TitleReadabilityInspector.coverage(timeline: edited, evidence: evidence, source: "preview").complete)
    }

    @Test func previewCacheReusesAudioIndependentPixelsButInvalidatesTitlesAndCorruption() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (timeline, _) = fixture()
        let cache = RenderedProbeCache(directory: root, visualOnly: true)
        var frame = PerceptualRenderedFrameEvidence(timelineTime: 1.75, meanLuma: 80, lumaDeviation: 10, isBlack: false)
        frame.decodeFailed = false
        try await cache.store([frame], timeline: timeline, assets: [])
        var audio = timeline; audio.originalAudioVolume = 0.2
        #expect(await cache.load(timeline: audio, assets: []) != nil)
        var title = timeline; title.titleItems?[0].text = "Утро"
        #expect(await cache.load(timeline: title, assets: []) == nil)
        let file = try #require(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first)
        var data = try Data(contentsOf: file); data[data.count / 2] ^= 1; try data.write(to: file)
        #expect(await cache.load(timeline: timeline, assets: []) == nil)
    }

    @Test func renderDependenciesIncludeCurrentSourceAndProxyBytes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.mov"), proxy = root.appendingPathComponent("proxy.mov")
        try Data([1,2,3]).write(to: source); try Data([1,2,3]).write(to: proxy)
        let asset = MediaAsset(originalURL: source, kind: .video, byteSize: 3, contentHash: "imported", metadata: .init(duration: 5))
        var (timeline, _) = fixture(); timeline.items[0].assetID = asset.id
        func key() -> String { EditorialRenderDependencies.signature(timeline: timeline, assets: [asset], tracks: [], preferredVideoSources: [asset.id: proxy]) }
        let first = key(); #expect(first == key())
        try Data([3,2,1]).write(to: source, options: .atomic); let second = key(); #expect(first != second)
        try Data([3,2,1]).write(to: proxy, options: .atomic); #expect(second != key())
    }

    @Test func receiptRejectsSameSizeReplacementWithRestoredModificationDate() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data([1,2,3]).write(to: file)
        let info = try FileManager.default.attributesOfItem(atPath: file.path)
        var receipt = EditorialExportVerification(renderSignature: "fixture", probes: [], durationDifference: 0,
            aspectRatioMatches: true, provenance: "explicit receipt fixture")
        receipt.outputURL = file
        receipt.fileSize = 3
        receipt.fileModified = info[.modificationDate] as? Date
        receipt.fileModifiedTime = receipt.fileModified?.timeIntervalSince1970
        receipt.artifactFileIdentity = FrameCacheKey.sourceIdentity(url: file, contentHash: "export")
        #expect(receipt.artifactIsCurrent)
        try Data([3,2,1]).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.modificationDate: receipt.fileModified!], ofItemAtPath: file.path)
        #expect(!receipt.artifactIsCurrent)
    }

    @Test func telemetrySetInsertionOrderCannotChangeRenderSignature() {
        let (timeline, _) = fixture()
        let id = UUID()
        let names = ["GPS5", "ACCL", "GYRO", "TEMP", "SCAL", "GPSU", "UNIT", "ORIN"]
        let first = TelemetrySummary(streams: Set(names))
        let expected = EditorialRenderDependencies.signature(timeline: timeline, assets: [], tracks: [], telemetry: [id: first])
        for _ in 0..<50 {
            let reordered = TelemetrySummary(streams: Set(names.shuffled()))
            #expect(EditorialRenderDependencies.signature(timeline: timeline, assets: [], tracks: [], telemetry: [id: reordered]) == expected)
        }
        var changed = first; changed.maxSpeedMetersPerSecond = 10
        #expect(EditorialRenderDependencies.signature(timeline: timeline, assets: [], tracks: [], telemetry: [id: changed]) != expected)
    }

    @Test func progressRelayKeepsStageChangesAndCompletion() async {
        let observer = ProgressCapture()
        let relay = FilmBuildProgressRelay(trace: nil, observer: { await observer.add($0) })
        for i in 0...100 { await relay.report(.init(.previewFrames, completed: i, total: 100)) }
        await relay.report(.init(.controlExport))
        await relay.finish(status: "cancelled")
        let updates = await observer.updates
        #expect(updates.count < 10)
        #expect(updates.contains { $0.completed == 100 })
        #expect(updates.last?.stage == .controlExport)
    }
}

private actor ProgressCapture {
    var updates: [FilmBuildProgress] = []
    func add(_ update: FilmBuildProgress) { updates.append(update) }
}
