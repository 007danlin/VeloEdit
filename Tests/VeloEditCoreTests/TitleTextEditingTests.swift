import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import VeloEditCore

@Suite(.serialized) struct TitleTextEditingTests {
    @Test(arguments: TitleTemplateRegistry.all.map(\.id))
    func fontSizeChangesActualGlyphsInEveryTemplate(_ id: String) throws {
        let template = try #require(TitleTemplateRegistry.template(id: id))
        for size in [CGSize(width: 960, height: 540), CGSize(width: 540, height: 960)] {
            var title = template.previewItem()
            title.text = "ЛЕТО"
            title.animation = TitleAnimation(entrance: .none, exit: .none)
            var previous: TitleReadabilityRegion?
            for fontSize in [24.0, 36, 48, 60] {
                title.style.fontSize = fontSize
                let region = try #require(TitleOverlayRenderer.textLayout(item: title, timelineTime: 1, renderSize: size)
                    .first { $0.elementID == "primary" })
                let sizing = try #require(TitleOverlayRenderer.textSizing(item: title, renderSize: size))
                #expect(sizing.lineCount == region.lineRects.count)
                #expect(!sizing.isTruncated)
                if let previous {
                    #expect(region.fontSize > previous.fontSize + 1, "\(id): changing the inspector must enlarge rendered text")
                    #expect(region.bounds.height > previous.bounds.height, "\(id): actual glyphs must grow")
                }
                previous = region
            }
        }
    }

    @Test(arguments: TitleTemplateRegistry.all.map(\.id))
    func increasingSizeNeverShrinksLongText(_ id: String) throws {
        var title = try #require(TitleTemplateRegistry.template(id: id)).previewItem()
        title.text = "Обычный день от лукавого"
        for size in [CGSize(width: 960, height: 540), CGSize(width: 540, height: 960)] {
            var previous = 0.0
            for requested in stride(from: 48.0, through: 160, by: 4) {
                title.style.fontSize = requested
                let sizing = try #require(TitleOverlayRenderer.textSizing(item: title, renderSize: size))
                #expect(sizing.fontSize >= previous - 0.02, "\(id): increasing size to \(requested) must not shrink the text")
                previous = sizing.fontSize
            }
        }
    }

    @Test(arguments: TitleTemplateRegistry.all.map(\.id))
    func manualLineBreaksSurviveEveryTemplateAndPersistence(_ id: String) throws {
        let template = try #require(TitleTemplateRegistry.template(id: id))
        var title = template.previewItem()
        title.text = "ЛЕТО\nМОРЕ"
        title.style.fontSize = 48
        title.animation = TitleAnimation(entrance: .none, exit: .none)
        title = try JSONDecoder.veloEdit.decode(TitleTimelineItem.self, from: JSONEncoder.veloEdit.encode(title))
        for size in [CGSize(width: 960, height: 540), CGSize(width: 540, height: 960)] {
            let region = try #require(TitleOverlayRenderer.textLayout(item: title, timelineTime: 1, renderSize: size)
                .first { $0.elementID == "primary" })
            #expect(region.renderedText == "ЛЕТО\nМОРЕ")
            #expect(region.lineRects.count == 2)
        }
    }

    @Test func longBoldHeadingUsesBannerSpace() throws {
        var title = try #require(TitleTemplateRegistry.template(id: "title.bold.v1")).previewItem()
        title.text = "Обычный день от лукавого"
        title.additionalText = "LUKA STUDIO"
        title.style.fontSize = 128
        title.animation = TitleAnimation(entrance: .none, exit: .none)
        let size = CGSize(width: 1920, height: 1080)
        let regions = TitleOverlayRenderer.textLayout(item: title, timelineTime: 1, renderSize: size)
        let primary = try #require(regions.first { $0.elementID == "primary" })
        let secondary = try #require(regions.first { $0.elementID == "secondary" })
        #expect(secondary.renderedText == "LUKA STUDIO")
        #expect(CGRect(origin: .zero, size: size).contains(secondary.bounds))
        print("Bold long title: font=\(primary.fontSize), lines=\(primary.lineRects.count), text=\(primary.renderedText)")
        #expect(primary.lineRects.count == 2)
        // The original one-line renderer reduced this exact title to 60.
        #expect(primary.fontSize >= 90)
        #expect(!primary.renderedText.contains("…"))
        for other in regions where other.elementID != primary.elementID {
            #expect(!primary.bounds.intersects(other.bounds))
        }
        let image = try #require(TitleOverlayRenderer.cgImage(item: title, timelineTime: 1, renderSize: size))
        let pixels = [UInt8](try #require(image.dataProvider?.data) as Data)
        let subtitlePixels = stride(from: 0, to: pixels.count, by: 4).filter {
            pixels[$0] > 180 && pixels[$0 + 1] > 180 && pixels[$0 + 2] > 180 && pixels[$0 + 3] > 180
        }.count
        #expect(subtitlePixels > 50, "The white subtitle must remain visible after drawing a multiline heading")
        if let path = ProcessInfo.processInfo.environment["VELOEDIT_TITLE_TEXT_QA"] {
            let url = URL(fileURLWithPath: path).appendingPathComponent("bold-long-title.png")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let writer = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(writer, image, nil)
            #expect(CGImageDestinationFinalize(writer))
        }
    }

    @Test func narrowHeadingsKeepWholeWordsOnEachLine() throws {
        for (id, text) in [("title.dynamic.v1", "ПУТЕШЕСТВИЕ НАЧИНАЕТСЯ"),
                           ("title.location.v1", "ПЕТРОПАВЛОВСК-КАМЧАТСКИЙ")] {
            var title = try #require(TitleTemplateRegistry.template(id: id)).previewItem()
            title.text = text
            title.animation = TitleAnimation(entrance: .none, exit: .none)
            let region = try #require(TitleOverlayRenderer.textLayout(item: title, timelineTime: 1,
                renderSize: CGSize(width: 360, height: 640)).first { $0.elementID == "primary" })
            #expect(region.lineRects.count == 2, "A final letter must not occupy its own third line")
            #expect(!region.renderedText.contains("…"))
        }
    }
}
