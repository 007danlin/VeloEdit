import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import VeloEditCore

@Test func professionalTitleTemplateCatalogIsDataDrivenAndDistinct() {
    let templates = TitleTemplateRegistry.all
    #expect(templates.count >= 14)
    #expect(Set(templates.map(\.id)).count == templates.count)
    #expect(templates.allSatisfy { !$0.layout.elements.isEmpty })
    #expect(templates.allSatisfy { $0.renderer == "veloedit.core-graphics.title-template.v1" })

    let requiredNames = Set([
        "Minimal Clean", "Cinematic", "Modern", "Bold", "Elegant", "Dynamic",
        "Travel", "Chapter", "Location", "Lower Third", "Date", "End Card"
    ])
    #expect(requiredNames.isSubset(of: Set(templates.map(\.name))))

    let signatures = templates.map { template in
        template.layout.elements.map {
            "\($0.kind.rawValue):\($0.content.rawValue):\($0.frame.x):\($0.frame.y):\($0.frame.width):\($0.frame.height):\($0.fillColorHex)"
        }.joined(separator: "|")
    }
    #expect(Set(signatures).count == templates.count)
}

@Test func titleTimelineItemPersistsTemplateAndMigratesLegacyKind() throws {
    let template = try #require(TitleTemplateRegistry.template(id: "title.cinematic.v1"))
    let item = TitleTimelineItem(
        kind: template.kind,
        templateID: template.id,
        text: "ДОРОГА ДОМОЙ",
        startTime: 1,
        duration: 4,
        style: template.defaultStyle
    )
    let decoded = try JSONDecoder().decode(TitleTimelineItem.self, from: JSONEncoder().encode(item))
    #expect(decoded.templateID == template.id)
    #expect(decoded.effectiveTemplateID == template.id)

    let legacyJSON = """
    {
      "id":"\(UUID().uuidString)","kind":"location","text":"МОСКВА",
      "startTime":0,"duration":3,"track":0,
      "style":{"fontSize":58,"textColorHex":"#FFFFFF","backgroundColorHex":"#111111","alignment":"left"},
      "animation":{"entrance":"fade","exit":"fade","duration":0.35,"easing":"ease-in-out"},
      "words":[],"activeWordHighlighting":true,"enabled":true,"explanation":[]
    }
    """
    let legacy = try JSONDecoder().decode(TitleTimelineItem.self, from: Data(legacyJSON.utf8))
    #expect(legacy.templateID == nil)
    #expect(legacy.effectiveTemplateID == "title.location.v1")
}

@Test func oneRendererHandlesCyrillicLongTextAndEveryRequiredAspectRatio() throws {
    let template = try #require(TitleTemplateRegistry.template(id: "title.modern.v1"))
    var item = template.previewItem()
    item.text = "БОЛЬШОЕ ПУТЕШЕСТВИЕ ПО СЕВЕРНОМУ ПОБЕРЕЖЬЮ"
    item.additionalText = "МОСКВА · КАРЕЛИЯ · МУРМАНСК · 2026"
    let sizes = [
        CGSize(width: 1920, height: 1080),
        CGSize(width: 1080, height: 1920),
        CGSize(width: 1080, height: 1080),
        CGSize(width: 1440, height: 1080)
    ]
    for size in sizes {
        let image = try #require(TitleOverlayRenderer.image(item: item, timelineTime: 1.4, renderSize: size))
        #expect(image.extent == CGRect(origin: .zero, size: size))
        let frame = try #require(TitleOverlayRenderer.cgImage(item: item, timelineTime: 1.4, renderSize: size))
        let alpha = try #require(alphaBounds(of: frame))
        #expect(alpha.minX > 0)
        #expect(alpha.minY > 0)
        #expect(alpha.maxX < size.width)
        #expect(alpha.maxY < size.height)
    }
}

@Test func titleRendererScalesDeterministicallyTo4KAndPreviewUsesIt() throws {
    let template = try #require(TitleTemplateRegistry.template(id: "title.cinematic.v1"))
    let item = template.previewItem()
    let size = CGSize(width: 3840, height: 2160)
    let exportFrame = try #require(TitleOverlayRenderer.image(item: item, timelineTime: 1.2, renderSize: size))
    #expect(exportFrame.extent == CGRect(origin: .zero, size: size))
    #expect(TitleOverlayRenderer.previewCGImage(template: template, time: 1.2, renderSize: CGSize(width: 480, height: 270)) != nil)
}

@Test func adaptiveTitleLayoutCoversRequiredFormatsSafeAreasAndUndistortedCircles() throws {
    let requiredSizes = [
        CGSize(width: 1920, height: 1080),
        CGSize(width: 3840, height: 2160),
        CGSize(width: 1080, height: 1920),
        CGSize(width: 2160, height: 2160),
        CGSize(width: 1080, height: 1350),
        CGSize(width: 1440, height: 1080)
    ]
    for template in TitleTemplateRegistry.all {
        for size in requiredSizes {
            let bounds = CGRect(origin: .zero, size: size)
            let layout = AdaptiveTitleLayout.resolve(template: template, renderSize: size)
            #expect(layout.geometry.aspectRatio == Double(size.width / size.height))
            #expect(bounds.contains(layout.safeRect))
            for (source, resolved) in zip(template.layout.elements, layout.elements) {
                let allowed = source.followsSafeArea ? layout.safeRect : bounds
                #expect(allowed.insetBy(dx: -0.5, dy: -0.5).contains(resolved.frame))
                if source.kind == .circle {
                    #expect(abs(resolved.frame.width - resolved.frame.height) < 0.01)
                }
            }
        }
    }

    let portrait = AdaptiveTitleLayout.resolve(
        template: try #require(TitleTemplateRegistry.template(id: "title.location.v1")),
        renderSize: CGSize(width: 1080, height: 1920)
    )
    let landscape = AdaptiveTitleLayout.resolve(
        template: try #require(TitleTemplateRegistry.template(id: "title.location.v1")),
        renderSize: CGSize(width: 1920, height: 1080)
    )
    #expect(portrait.element(id: "primary")?.maximumLines == 3)
    #expect((portrait.element(id: "primary")?.frame.width ?? 0) / 1080 > (landscape.element(id: "primary")?.frame.width ?? 0) / 1920)
}

@Test func timelineCanvasAutomaticallyUsesRealPrimaryVideoDimensions() {
    let portrait = MediaAsset(
        originalURL: URL(fileURLWithPath: "/tmp/camera-clip.mov"),
        kind: .video,
        byteSize: 1,
        contentHash: "portrait-source",
        metadata: MediaMetadata(width: 1080, height: 1920)
    )
    let item = TimelineItem(
        assetID: portrait.id,
        kind: .video,
        sourceDuration: 2,
        timelineStart: 0,
        timelineDuration: 2
    )
    let canvas = TimelineComposer.automaticCanvasSize(items: [item], assetsByID: [portrait.id: portrait])
    #expect(canvas.width == 1080)
    #expect(canvas.height == 1920)
    #expect(VideoFrameGeometry(width: canvas.width, height: canvas.height).orientation == .portrait)
}

@Test func templateAnimationOwnsMotionInsteadOfLegacyFallback() throws {
    let template = try #require(TitleTemplateRegistry.template(id: "title.dynamic.v1"))
    var first = template.previewItem()
    first.animation = TitleAnimation(entrance: .fade, exit: .fade, duration: 3.5)
    var second = first
    second.animation = TitleAnimation(entrance: .slide, exit: .scale, duration: 0.05)
    let size = CGSize(width: 640, height: 360)
    let firstImage = try #require(TitleOverlayRenderer.image(item: first, timelineTime: 0.22, renderSize: size))
    let secondImage = try #require(TitleOverlayRenderer.image(item: second, timelineTime: 0.22, renderSize: size))
    #expect(pixelChecksum(firstImage, size: size) == pixelChecksum(secondImage, size: size))
}

@Test(arguments: TitleTemplateRegistry.all.map(\.id))
func titleInspectorSizeColorAndOpacityChangeEveryTemplate(_ id: String) throws {
    let template = try #require(TitleTemplateRegistry.template(id: id))
    var item = template.previewItem()
    item.text = "ЛЕТО"
    item.animation = TitleAnimation(entrance: .none, exit: .none)
    let size = CGSize(width: 640, height: 360)
    func render(_ value: TitleTimelineItem) throws -> CGImage {
        try #require(TitleOverlayRenderer.cgImage(item: value, timelineTime: 1, renderSize: size))
    }
    let original = try render(item)
    var edited = item
    edited.style.fontSize *= 0.65
    #expect(try render(edited).dataProvider?.data as Data? != original.dataProvider?.data as Data?)
    edited = item
    edited.style.textColorHex = "#FF00CC"
    #expect(try render(edited).dataProvider?.data as Data? != original.dataProvider?.data as Data?)
    edited = item
    edited.style.opacity = 0
    #expect(try alphaBounds(of: render(edited)) == nil, "\(id): transparency must hide text AND artwork")
    #expect(TitleOverlayRenderer.cgImage(item: item, timelineTime: item.endTime, renderSize: size) == nil)
}

@Test func transparentTitleLeavesNoAdaptiveOutlineOrBackground() throws {
    let size = CGSize(width: 640, height: 360)
    let bounds = CGRect(origin: .zero, size: size)
    let background = CIImage(color: .white).cropped(to: bounds)
    var item = try #require(TitleTemplateRegistry.template(id: "title.modern.v1")).previewItem()
    item.animation = TitleAnimation(entrance: .none, exit: .none)
    let renderer = AdaptiveTitleBackgroundRenderer()
    _ = TitleOverlayRenderer.composited(item: item, timelineTime: 1, renderSize: size, over: background, adaptation: renderer)
    item.style.opacity = 0
    let hidden = TitleOverlayRenderer.composited(item: item, timelineTime: 1.05, renderSize: size, over: background, adaptation: renderer)
    #expect(pixelChecksum(hidden, size: size) == pixelChecksum(background, size: size))
    let overlay = try #require(AdaptiveTitlePreviewRenderer().image(items: [item], timelineTime: 1, renderSize: size, background: background))
    #expect(alphaBounds(of: overlay) == nil)
}

@Test func chapterTitleWithImmediateEntranceIsVisibleInTheFirstRenderedFrame() throws {
    let size = CGSize(width: 640, height: 360)
    let title = TitleTimelineItem(kind: .chapter, templateID: "title.minimal-clean.v1", text: "Рыбалка",
        startTime: 0, duration: 3, animation: TitleAnimation(entrance: .none))
    let first = try #require(TitleOverlayRenderer.cgImage(item: title, timelineTime: 0, renderSize: size))
    #expect(alphaBounds(of: first) != nil)
    let hold = try #require(TitleOverlayRenderer.image(item: title, timelineTime: 0.5, renderSize: size))
    #expect(pixelChecksum(CIImage(cgImage: first), size: size) == pixelChecksum(hold, size: size))
}

@Test func everyBuiltInTitleIsPixelStableDuringItsHoldPhase() throws {
    let renderSize = CGSize(width: 640, height: 360)
    for template in TitleTemplateRegistry.all {
        let item = template.previewItem()
        let lastStaggerIndex = Double(template.layout.elements.map(\.staggerIndex).max() ?? 0)
        let settledAt = template.animation.animationIn.duration
            + lastStaggerIndex * template.animation.animationIn.stagger
        let exitStartsAt = item.duration
            - template.animation.animationOut.duration
            - lastStaggerIndex * template.animation.animationOut.stagger
        let holdDuration = exitStartsAt - settledAt
        #expect(holdDuration > 0.1, "\(template.name) needs a settled hold interval")

        let firstTime = settledAt + holdDuration * 0.35
        let secondTime = settledAt + holdDuration * 0.65
        let first = try #require(TitleOverlayRenderer.cgImage(
            item: item,
            timelineTime: firstTime,
            renderSize: renderSize
        ))
        let second = try #require(TitleOverlayRenderer.cgImage(
            item: item,
            timelineTime: secondTime,
            renderSize: renderSize
        ))
        #expect(
            first.dataProvider?.data as Data? == second.dataProvider?.data as Data?,
            "\(template.name) must not drift, pulse or rotate after its entrance animation"
        )
    }
}

@Test func titleTemplateCatalogCanBeRenderedForVisualQA() throws {
    let portraitQA = ProcessInfo.processInfo.environment["VELOEDIT_TITLE_QA_PORTRAIT"] == "1"
    let renderSize = portraitQA ? CGSize(width: 270, height: 480) : CGSize(width: 480, height: 270)
    let templates = TitleTemplateRegistry.all
    let images = try templates.map { template in
        try #require(TitleOverlayRenderer.previewCGImage(template: template, time: 1.35, renderSize: renderSize))
    }
    #expect(images.count == templates.count)

    guard let outputDirectory = ProcessInfo.processInfo.environment["VELOEDIT_TITLE_QA_DIR"] else { return }
    let directory = URL(fileURLWithPath: outputDirectory, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let columns = 4
    let rows = Int(ceil(Double(images.count) / Double(columns)))
    let width = Int(renderSize.width) * columns
    let height = Int(renderSize.height) * rows
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    let context = try #require(CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.setFillColor(CGColor(red: 0.055, green: 0.06, blue: 0.075, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    for (index, image) in images.enumerated() {
        let column = index % columns
        let row = index / columns
        let target = CGRect(
            x: column * Int(renderSize.width),
            y: height - ((row + 1) * Int(renderSize.height)),
            width: Int(renderSize.width),
            height: Int(renderSize.height)
        )
        context.draw(image, in: target)
    }
    let catalog = try #require(context.makeImage())
    let name = portraitQA ? "title-template-catalog-portrait.png" : "title-template-catalog-landscape.png"
    try writePNG(catalog, to: directory.appendingPathComponent(name))
}

private func alphaBounds(of cgImage: CGImage) -> CGRect? {
    let width = cgImage.width
    let height = cgImage.height
    guard let data = cgImage.dataProvider?.data,
          let bytes = CFDataGetBytePtr(data) else { return nil }
    let bytesPerRow = cgImage.bytesPerRow
    let bytesPerPixel = max(1, cgImage.bitsPerPixel / 8)
    var minX = width, minY = height, maxX = -1, maxY = -1
    for y in 0..<height {
        for x in 0..<width {
            let offset = y * bytesPerRow + x * bytesPerPixel
            var visible = false
            for channel in 0..<bytesPerPixel where bytes[offset + channel] > 2 { visible = true; break }
            guard visible else { continue }
            minX = min(minX, x); minY = min(minY, y); maxX = max(maxX, x); maxY = max(maxY, y)
        }
    }
    guard maxX >= minX, maxY >= minY else { return nil }
    return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
}

private func writePNG(_ image: CGImage, to url: URL) throws {
    let destination = try #require(CGImageDestinationCreateWithURL(
        url as CFURL,
        UTType.png.identifier as CFString,
        1,
        nil
    ))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
}

private func pixelChecksum(_ image: CIImage, size: CGSize) -> UInt64 {
    guard let cgImage = CIContext().createCGImage(image, from: CGRect(origin: .zero, size: size)),
          let data = cgImage.dataProvider?.data,
          let bytes = CFDataGetBytePtr(data) else { return 0 }
    let count = CFDataGetLength(data)
    var checksum: UInt64 = 1_469_598_103_934_665_603
    for index in stride(from: 0, to: count, by: max(1, count / 8192)) {
        checksum = (checksum ^ UInt64(bytes[index])) &* 1_099_511_628_211
    }
    return checksum
}
