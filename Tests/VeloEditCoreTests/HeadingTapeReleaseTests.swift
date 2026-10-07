import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Testing
@testable import VeloEditCore

@Test func headingTapeUsesOVRLEYWithinWidgetBounds() throws {
    var layout = TelemetryWidgetLayout.presetLayout(kind: .heading, presentation: .headingTape)
    layout.x = 0.1; layout.y = 0.1; layout.width = 0.8; layout.height = 0.8
    let settings = TelemetryOverlaySettings(metrics: [.heading], style: .champagneBasic, widgets: [layout])
    let size = CGSize(width: 480, height: 152)
    let config = try #require(OVRLEYFrameRenderer.renderTemplate(settings: settings, telemetry: TelemetryOverlayRenderer.catalogueTelemetry, renderSize: size), "Heading template must exist")
    let payload = try #require(OVRLEYFrameRenderer.activityPayload(TelemetryOverlayRenderer.catalogueTelemetry))
    let png = try OVRLEYBridge().renderFrame(payload: payload, config: config, second: 2.5)
    let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
    let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))

    var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
    pixels.withUnsafeMutableBytes { bytes in
        let context = CGContext(data: bytes.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(origin: .zero, size: size))
    }
    var visible = 0, outside = 0
    for y in 0..<image.height {
        for x in 0..<image.width where pixels[(y * image.width + x) * 4 + 3] > 16 {
            visible += 1
            if x < 46 || x > 434 || y < 13 || y > 139 { outside += 1 }
        }
    }
    #expect(visible > 100)
    #expect(outside == 0)
    if let path = ProcessInfo.processInfo.environment["VELOEDIT_TELEMETRY_QA_DIR"] {
        let file = URL(fileURLWithPath: path).appendingPathComponent("heading-ovrley-verified.png")
        let output = try #require(CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(output, image, nil)
        #expect(CGImageDestinationFinalize(output))
    }
}
