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

@Test func titleTemplateCatalogCanBeRenderedForVisualQA() throws {
    let renderSize = CGSize(width: 480, height: 270)
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
    try writePNG(catalog, to: directory.appendingPathComponent("title-template-catalog.png"))
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
