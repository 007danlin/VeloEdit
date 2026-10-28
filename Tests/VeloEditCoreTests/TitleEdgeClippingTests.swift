import CoreGraphics
import Foundation
import Testing
@testable import VeloEditCore

@Suite(.serialized)
struct TitleEdgeClippingTests {
    @Test func settledRevealPreservesTheFirstGlyphAndItsOutline() throws {
        let template = try #require(TitleTemplateRegistry.template(id: "title.chapter-compact.v1"))
        var title = template.previewItem()
        title.text = "ДВОЕ ЛЮДЕЙ С ПЛАНШЕТАМИ"
        title.style.strokeWidth = 12
        title.style.shadow = 0
        title.animation = .init(entrance: .none, exit: .none, duration: 0)
        for size in [CGSize(width: 1920, height: 1080), CGSize(width: 1280, height: 720)] {
            let layout = AdaptiveTitleLayout.resolve(template: template, renderSize: size, item: title)
            let primary = try #require(layout.element(id: "primary"))
            let origin = template.layoutOrigin ?? template.defaultStyle
            let flowLeft = primary.frame.minX + layout.safeRect.width
                * CGFloat(title.style.effectiveXPosition - origin.effectiveXPosition)
            let overlay = try #require(TitleOverlayRenderer.cgImage(item: title, timelineTime: 1, renderSize: size))
            // The Д overhang and outline belong to the visible glyph, even
            // to the left of its typographic box. The former full reveal
            // mask erased every pixel in this strip after the title appeared.
            let strip = CGRect(x: floor(flowLeft) - 8, y: 0, width: 8, height: size.height)
            let pixels = try #require(overlay.cropping(to: strip))
            let context = try #require(CGContext(data: nil, width: pixels.width, height: pixels.height,
                bitsPerComponent: 8, bytesPerRow: pixels.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.draw(pixels, in: CGRect(x: 0, y: 0, width: pixels.width, height: pixels.height))
            let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
            #expect((0..<(pixels.width * pixels.height)).contains { bytes[$0 * 4 + 3] > 16 })
        }
    }

    @Test func automaticChapterTitlesKeepSafeMarginsAcrossFormats() throws {
        let template = try #require(TitleTemplateRegistry.template(id: "title.chapter-compact.v1"))
        for text in ["Дорога домой", "ДВОЕ ЛЮДЕЙ С ПЛАНШЕТАМИ", "ПОСЛЕДОВАТЕЛЬНОСТЬ ОТДЫХА НА ПРИРОДЕ"] {
            for size in [CGSize(width: 1920, height: 1080), CGSize(width: 1280, height: 720),
                         CGSize(width: 1080, height: 1080), CGSize(width: 1080, height: 1920)] {
                var title = template.previewItem()
                title.text = text
                let regions = TitleOverlayRenderer.textLayout(item: title, timelineTime: 1, renderSize: size)
                let primary = try #require(regions.first { $0.elementID == "primary" })
                let safe = template.safeArea.rect(in: size)
                #expect(safe.contains(primary.bounds), "\(text): glyphs leave safe area at \(size)")
                #expect(!primary.renderedText.contains("…"))
                #expect(primary.renderedText.replacingOccurrences(of: "\n", with: " ") == text.uppercased())
            }
        }
    }
}
