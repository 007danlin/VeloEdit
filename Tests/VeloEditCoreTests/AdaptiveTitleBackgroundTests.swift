import AVFoundation
import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import VeloEditCore

private let adaptiveCanvas = CGRect(x: 0, y: 0, width: 640, height: 360)
private let adaptiveContext = CIContext(options: [.cacheIntermediates: false])

private func adaptiveRegion(lines: Int = 1, luminance: Double = 1) -> TitleReadabilityRegion {
    TitleReadabilityRegion(elementID: "primary", lineRects: (0..<lines).map {
        CGRect(x: 150, y: 200 - $0 * 32, width: 340, height: 24)
    }, fontSize: 28, textLuminances: [luminance], textOpacity: 1, visibility: 1)
}

private func adaptiveTexture(dark: Bool = false) -> CIImage {
    CIFilter(name: "CICheckerboardGenerator", parameters: [
        "inputColor0": CIColor(red: dark ? 0.02 : 0.30, green: dark ? 0.10 : 0.46, blue: dark ? 0.03 : 0.18),
        "inputColor1": CIColor(red: dark ? 0.12 : 1, green: dark ? 0.24 : 1, blue: dark ? 0.08 : 0.85),
        "inputWidth": 5, "inputSharpness": 1
    ])!.outputImage!.cropped(to: adaptiveCanvas)
}

private func adaptiveBytes(_ image: CIImage, rect: CGRect = adaptiveCanvas) -> [UInt8] {
    let width = Int(rect.width), height = Int(rect.height)
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    bytes.withUnsafeMutableBytes {
        adaptiveContext.render(image, toBitmap: $0.baseAddress!, rowBytes: width * 4,
                               bounds: rect, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
    }
    return bytes
}

@Test func adaptiveTitlePreservesReadableSceneryPixelForPixel() throws {
    let region = adaptiveRegion()
    let item = TitleTimelineItem(kind: .title, text: "ЛЕСНАЯ ДОРОГА", startTime: 0, duration: 4)
    for background in [CIImage(color: CIColor(red: 0.03, green: 0.10, blue: 0.14)).cropped(to: adaptiveCanvas), adaptiveTexture(dark: true)] {
        let metrics = try #require(TitleReadabilityAnalysis.measure(image: background, region: region, context: adaptiveContext, canvas: adaptiveCanvas))
        #expect(metrics.poorContrastFraction < 0.12)
        let output = AdaptiveTitleBackgroundRenderer().process(background: background, artwork: nil,
                                                              regions: [region], item: item, time: 1.5, bounds: adaptiveCanvas)
        #expect(output.treatments.isEmpty)
        #expect(adaptiveBytes(output.image) == adaptiveBytes(background))
        #expect(adaptiveBytes(output.backgroundOverlay).allSatisfy { $0 == 0 })
    }
}

@Test func adaptiveTitleUsesEdgesOnFlatSkyAndSupportsDarkText() throws {
    let item = TitleTimelineItem(kind: .title, text: "ОЗЕРО", startTime: 0, duration: 4)
    for (color, luminance) in [(CIColor.white, 1.0), (CIColor.black, 0.0)] {
        let background = CIImage(color: color).cropped(to: adaptiveCanvas)
        let output = AdaptiveTitleBackgroundRenderer().process(background: background, artwork: nil,
            regions: [adaptiveRegion(luminance: luminance)], item: item, time: 1, bounds: adaptiveCanvas)
        let treatment = try #require(output.treatments["primary"])
        #expect(treatment.level == .edge)
        #expect(treatment.lightSupport == (luminance == 0))
        #expect(treatment.blurRadius == 0)
        #expect(treatment.shadeOpacity == 0)
        #expect(adaptiveBytes(output.image) == adaptiveBytes(background))
    }
}

@Test func immediateTitleHasReadabilitySupportFromItsFirstFrame() throws {
    var title = try #require(TitleTemplateRegistry.template(id: "title.minimal-clean.v1")).previewItem()
    title.additionalText = nil
    title.animation = TitleAnimation(entrance: .none, exit: .none)
    title.style.shadow = 0
    let background = CIImage(color: .white).cropped(to: adaptiveCanvas)
    let renderer = AdaptiveTitleBackgroundRenderer()
    let first = TitleOverlayRenderer.composited(item: title, timelineTime: 0, renderSize: adaptiveCanvas.size,
                                               over: background, adaptation: renderer)
    let held = TitleOverlayRenderer.composited(item: title, timelineTime: 0.05, renderSize: adaptiveCanvas.size,
                                              over: background, adaptation: renderer)
    #expect(adaptiveBytes(first) == adaptiveBytes(held))
    #expect(adaptiveBytes(first) != adaptiveBytes(background))
}

@Test func adaptiveTitleEscalatesOnlyForUnreadableTextureAndProtectsAction() {
    let region = adaptiveRegion(lines: 2)
    let busy = TitleReadabilityMetrics(contrast: 1.2, poorContrastFraction: 0.92, detail: 0.98,
                                       meanLuminance: 0.6, samples: Array(repeating: [0.15, 0.95], count: 32).flatMap { $0 })
    let blurred = TitleReadabilityAnalysis.choose(metrics: busy, region: region, motion: 0,
                                                  protectedOverlap: 0, canProtectSubjects: true)
    #expect(blurred.level == .blur)
    #expect(blurred.blurRadius > 0 && blurred.blurRadius <= 8)
    for (motion, overlap, reliable) in [(0.30, 0.0, true), (0.0, 0.30, true), (0.0, 0.0, false)] {
        let protected = TitleReadabilityAnalysis.choose(metrics: busy, region: region, motion: motion,
                                                         protectedOverlap: overlap, canProtectSubjects: reliable)
        #expect(protected.blurRadius == 0)
        #expect(protected.edgeOpacity > 0)
        #expect(protected.shadeOpacity <= 0.44)
    }
    var readable = busy
    readable.poorContrastFraction = 0.02
    #expect(TitleReadabilityAnalysis.choose(metrics: readable, region: region, motion: 0,
                                           protectedOverlap: 0, canProtectSubjects: true).level == .none)
    var slight = busy
    slight.detail = 0.30
    slight.poorContrastFraction = 0.4
    let shade = TitleReadabilityAnalysis.choose(metrics: slight, region: region, motion: 0,
                                                protectedOverlap: 0, canProtectSubjects: true)
    #expect(shade.level == .shade && shade.blurRadius == 0)
}

@Test func adaptiveTitleMasksHaveSoftEdgesAndLeaveSubjectsAndDistantPixelsAlone() throws {
    let region = adaptiveRegion()
    let mask = AdaptiveTitleBackgroundRenderer.softMask(lines: region.lineRects, fontSize: 28, bounds: adaptiveCanvas)
    let subject = CGRect(x: 260, y: 195, width: 50, height: 50)
    let protected = AdaptiveTitleBackgroundRenderer.protect(mask: mask, subjects: [subject], padding: 14, bounds: adaptiveCanvas)
    #expect(adaptiveBytes(protected, rect: CGRect(x: 275, y: 210, width: 1, height: 1))[0] < 3)
    #expect(adaptiveBytes(protected, rect: CGRect(x: 180, y: 212, width: 1, height: 1))[0] > 200)
    let row = adaptiveBytes(mask, rect: CGRect(x: 100, y: 212, width: 90, height: 1))
    let values = stride(from: 0, to: row.count, by: 4).map { Int(row[$0]) }
    #expect(values.contains { $0 > 10 && $0 < 240 })
    #expect(zip(values, values.dropFirst()).allSatisfy { abs($0 - $1) < 24 })
    let background = adaptiveTexture()
    let item = TitleTimelineItem(kind: .title, text: "ТРОПА ЧЕРЕЗ ЛЕС", startTime: 0, duration: 4)
    let output = AdaptiveTitleBackgroundRenderer(subjectDetector: { _, _ in [] }).process(
        background: background, artwork: nil, regions: [region], item: item, time: 1, bounds: adaptiveCanvas)
    #expect(!output.treatments.isEmpty)
    #expect(adaptiveBytes(output.image, rect: CGRect(x: 0, y: 0, width: 80, height: 80)) ==
            adaptiveBytes(background, rect: CGRect(x: 0, y: 0, width: 80, height: 80)))
    // Native preview's transparent patch must reconstruct exactly the same frame.
    let patch = output.backgroundOverlay.composited(over: background)
    let delta = zip(adaptiveBytes(output.image), adaptiveBytes(patch)).map { abs(Int($0) - Int($1)) }.max() ?? 0
    #expect(delta <= 1)
}

@Test func adaptiveTitleRespectsExistingPanelAndActualTextContrast() throws {
    let background = adaptiveTexture()
    let artwork = CIImage(color: .black).cropped(to: CGRect(x: 100, y: 100, width: 440, height: 180))
    let item = TitleTimelineItem(kind: .title, text: "МАРШРУТ", startTime: 0, duration: 4)
    let output = AdaptiveTitleBackgroundRenderer().process(background: background, artwork: artwork,
        regions: [adaptiveRegion()], item: item, time: 1, bounds: adaptiveCanvas)
    #expect(output.treatments.isEmpty)
    #expect(adaptiveBytes(output.image) == adaptiveBytes(background))
    var region = adaptiveRegion()
    region.textLuminances = [1, 0.04] // A dark highlighted word on a dark frame still needs help.
    let metrics = try #require(TitleReadabilityAnalysis.measure(image: CIImage(color: .black), region: region,
                                                                context: adaptiveContext, canvas: adaptiveCanvas))
    #expect(metrics.poorContrastFraction > 0.9)
}

@Test func adaptiveTitleSmoothsStrengthAndResetsOnSeekAndAtBoundaries() throws {
    let item = TitleTimelineItem(kind: .title, text: "ДОРОГА", startTime: 0, duration: 4)
    let region = adaptiveRegion()
    let renderer = AdaptiveTitleBackgroundRenderer(subjectDetector: { _, _ in [] })
    let busy = adaptiveTexture()
    func process(_ time: Double, _ background: CIImage, _ visibility: Double = 1) -> AdaptiveTitleBackgroundRenderer.Output {
        var visible = region
        visible.visibility = visibility
        return renderer.process(background: background, artwork: nil, regions: [visible], item: item, time: time, bounds: adaptiveCanvas)
    }
    let first = process(1, busy)
    let repeated = process(1, busy)
    #expect(adaptiveBytes(first.image) == adaptiveBytes(repeated.image))
    let clean = CIImage(color: CIColor(red: 0.25, green: 0.25, blue: 0.25)).cropped(to: adaptiveCanvas)
    let released = process(1.033, clean)
    let oldShade = try #require(first.treatments["primary"]?.shadeOpacity)
    #expect((released.treatments["primary"]?.shadeOpacity ?? 0) <= oldShade)
    let seek = process(0.5, clean)
    #expect(seek.treatments.isEmpty)
    let faint = process(2, busy, 0.05)
    #expect((faint.treatments["primary"]?.shadeOpacity ?? 0) < oldShade * 0.1)
    // At startTime a static title is visible. Outside the interval, or
    // during a fully transparent animation frame, no support is needed.
    for time in [-0.001, 4.0, 4.1] {
        let absent = process(time, busy)
        #expect(absent.treatments.isEmpty)
        #expect(adaptiveBytes(absent.image).elementsEqual(adaptiveBytes(busy)))
    }
    let transparent = process(0, busy, 0)
    #expect(transparent.treatments.isEmpty)
    #expect(adaptiveBytes(transparent.image).elementsEqual(adaptiveBytes(busy)))
}

@Test func adaptiveTitleFullRendererAndNativePreviewAgreeAcrossFormats() throws {
    let template = try #require(TitleTemplateRegistry.template(id: "title.minimal-clean.v1"))
    var item = template.previewItem()
    item.text = "ДОРОГА К ОЗЕРУ"
    item.additionalText = nil
    item.style.rotation = 9
    item.style.xPosition = 0.55
    for size in [CGSize(width: 640, height: 360), CGSize(width: 360, height: 640), CGSize(width: 480, height: 480)] {
        let bounds = CGRect(origin: .zero, size: size)
        let background = CIImage(color: .white).cropped(to: bounds)
        let full = TitleOverlayRenderer.composited(item: item, timelineTime: 1.5, renderSize: size,
            over: background, adaptation: AdaptiveTitleBackgroundRenderer())
        let preview = try #require(AdaptiveTitlePreviewRenderer().image(items: [item], timelineTime: 1.5,
            renderSize: size, background: background))
        let reconstructed = CIImage(cgImage: preview).composited(over: background)
        let difference = zip(adaptiveBytes(full, rect: bounds), adaptiveBytes(reconstructed, rect: bounds))
            .map { abs(Int($0) - Int($1)) }.max() ?? 0
        #expect(difference <= 2)
        #expect(adaptiveBytes(full, rect: bounds) != adaptiveBytes(background, rect: bounds))
    }
}

@Test func adaptiveTitleSceneExamplesCanBeRenderedForVisualQA() throws {
    guard let path = ProcessInfo.processInfo.environment["VELOEDIT_ADAPTIVE_TITLE_QA_DIR"] else { return }
    let directory = URL(fileURLWithPath: path, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let lakeURL = root.appendingPathComponent("Resources/TransitionPreviews/moraine-lake.jpg")
    let lake = try #require(CIImage(contentsOf: lakeURL))
    let lakeScale = max(640 / lake.extent.width, 360 / lake.extent.height)
    let scenery = lake.transformed(by: CGAffineTransform(scaleX: lakeScale, y: lakeScale)).cropped(to: adaptiveCanvas)
    let scenes = [scenery, CIImage(color: CIColor(red: 0.78, green: 0.88, blue: 0.96)).cropped(to: adaptiveCanvas), adaptiveTexture(), adaptiveTexture(dark: true)]
    let template = try #require(TitleTemplateRegistry.template(id: "title.minimal-clean.v1"))
    var item = template.previewItem()
    item.text = "ДОРОГА К ОЗЕРУ"
    item.additionalText = "ПУТЕШЕСТВИЕ ПРОДОЛЖАЕТСЯ"
    let sheet = try #require(CGContext(data: nil, width: 1920, height: 1440, bitsPerComponent: 8, bytesPerRow: 0,
                                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    for (row, background) in scenes.enumerated() {
        let plain = try #require(TitleOverlayRenderer.image(item: item, timelineTime: 1.5, renderSize: adaptiveCanvas.size)).composited(over: background)
        let adapted = TitleOverlayRenderer.composited(item: item, timelineTime: 1.5, renderSize: adaptiveCanvas.size,
            over: background, adaptation: AdaptiveTitleBackgroundRenderer())
        for (column, image) in [background, plain, adapted].enumerated() {
            let cgImage = try #require(adaptiveContext.createCGImage(image, from: adaptiveCanvas))
            sheet.draw(cgImage, in: CGRect(x: column * 640, y: (3 - row) * 360, width: 640, height: 360))
        }
    }
    let output = directory.appendingPathComponent("adaptive-title-comparison.png")
    let destination = try #require(CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, try #require(sheet.makeImage()), nil)
    #expect(CGImageDestinationFinalize(destination))
}

@Test func adaptiveTitleExportCompositionActuallyProcessesItsSourceFrame() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("adaptive-title-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let imageURL = root.appendingPathComponent("sky.png")
    let background = CIImage(color: .white).cropped(to: adaptiveCanvas)
    let image = try #require(adaptiveContext.createCGImage(background, from: adaptiveCanvas))
    let destination = try #require(CGImageDestinationCreateWithURL(imageURL as CFURL, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    let asset = MediaAsset(originalURL: imageURL, kind: .photo, byteSize: 1, contentHash: UUID().uuidString,
                           metadata: MediaMetadata(width: 640, height: 360, hasAudio: false))
    let clip = TimelineItem(assetID: asset.id, kind: .photo, sourceDuration: 3,
                            timelineStart: 0, timelineDuration: 3)
    var title = try #require(TitleTemplateRegistry.template(id: "title.minimal-clean.v1")).previewItem()
    title.text = "ДОРОГА"
    title.additionalText = nil
    title.duration = 3
    title.style.shadow = 0
    let timeline = Timeline(storyPlanID: UUID(), width: 640, height: 360, frameRate: 10,
                            items: [clip], titleItems: [title])
    let playback = try await PlaybackEngine().build(timeline: timeline, assets: [asset])
    #expect(playback.videoComposition?.customVideoCompositorClass != nil)
    #expect(playback.videoComposition?.animationTool == nil)
    let generator = AVAssetImageGenerator(asset: playback.composition)
    generator.videoComposition = playback.videoComposition
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = .zero
    let frame = try generator.copyCGImage(at: CMTime(seconds: 1.5, preferredTimescale: 600), actualTime: nil)
    let pixels = adaptiveBytes(CIImage(cgImage: frame))
    if let path = ProcessInfo.processInfo.environment["VELOEDIT_ADAPTIVE_TITLE_QA_DIR"] {
        let url = URL(fileURLWithPath: path).appendingPathComponent("export-white-sky.png")
        let png = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(png, frame, nil)
        #expect(CGImageDestinationFinalize(png))
    }
    let darkPixels = stride(from: 0, to: pixels.count, by: 4).filter { pixels[$0] < 150 }.count
    // White letters without the adaptive edge would disappear on this source.
    #expect(darkPixels > 100)
    #expect(darkPixels < 640 * 360 / 12)
}

@Test func adaptiveTitleContourDoesNotDoubleTheFillDuringFade() throws {
    var item = try #require(TitleTemplateRegistry.template(id: "title.minimal-clean.v1")).previewItem()
    item.text = "ТИХИЙ ВЕЧЕР"
    item.additionalText = nil
    item.style.shadow = 0
    item.style.opacity = 0.55
    let background = CIImage(color: .white).cropped(to: adaptiveCanvas)
    for time in [0.35, 0.6, 1.5] {
        let plain = try #require(TitleOverlayRenderer.image(item: item, timelineTime: time, renderSize: adaptiveCanvas.size))
        let adapted = try #require(AdaptiveTitlePreviewRenderer().image(items: [item], timelineTime: time,
            renderSize: adaptiveCanvas.size, background: background))
        func fillEnergy(_ image: CIImage) -> Double {
            // Compare linear premultiplied light. Gamma-encoded RGB byte sums
            // change with alpha even when a black shadow adds no emitted light.
            var pixels = [Float](repeating: 0, count: 640 * 360 * 4)
            pixels.withUnsafeMutableBytes {
                adaptiveContext.render(image, toBitmap: $0.baseAddress!, rowBytes: 640 * 4 * MemoryLayout<Float>.size,
                    bounds: adaptiveCanvas, format: .RGBAf,
                    colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!)
            }
            return stride(from: 0, to: pixels.count, by: 4).reduce(0) { $0 + Double(pixels[$1]) }
        }
        // A black outline adds alpha but cannot add white fill. Drawing the
        // translucent fill twice would make the entrance noticeably brighter.
        #expect(fillEnergy(CIImage(cgImage: adapted)) <= fillEnergy(plain) * 1.04)
    }
}
