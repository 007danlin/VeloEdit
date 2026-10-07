import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import Testing
@testable import VeloEditCore

struct VideoCameraEffectTests {
    private let context = CIContext(options: [.cacheIntermediates: false])

    private func source(_ bounds: CGRect) -> CIImage {
        CIImage(color: CIColor(red: 0.8, green: 0.35, blue: 0.12)).cropped(to: bounds)
    }

    private func pixels(_ image: CIImage, bounds: CGRect? = nil) -> [UInt8] {
        let bounds = bounds ?? image.extent
        var bytes = [UInt8](repeating: 0, count: Int(bounds.width * bounds.height) * 4)
        context.render(image, toBitmap: &bytes, rowBytes: Int(bounds.width) * 4, bounds: bounds,
            format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        return bytes
    }

    @Test func monochromeFieldsAndViewfinderWorkInLandscapePortraitAndOffsetFrames() {
        for bounds in [CGRect(x: 0, y: 0, width: 640, height: 360), CGRect(x: 13, y: -27, width: 360, height: 640)] {
            let effect = EffectTimelineItem(effectType: .videoCamera, startTime: 12, duration: 3)
            let image = TransitionEffectRenderer.applyEffects([effect], to: source(bounds), timelineTime: 12.2)
            #expect(image.extent == bounds)
            let center = pixels(image, bounds: CGRect(x: bounds.midX, y: bounds.midY, width: 1, height: 1))
            #expect(abs(Int(center[0]) - Int(center[1])) <= 1 && abs(Int(center[1]) - Int(center[2])) <= 1)
            #expect(center[0] > 30 && center[0] < 230)
            for y in [bounds.minY + 2, bounds.maxY - 3] {
                #expect(pixels(image, bounds: CGRect(x: bounds.midX, y: y, width: 1, height: 1)) == [0, 0, 0, 255])
            }
            let frame = pixels(image)
            #expect(stride(from: 3, to: frame.count, by: 4).allSatisfy { frame[$0] == 255 })
            let unit = min(bounds.width, bounds.height)
            let recArea = CGRect(x: bounds.minX + (unit * 0.07).rounded(),
                y: bounds.maxY - (bounds.height * 0.08 + unit * 0.13).rounded(),
                width: (unit * 0.14).rounded(), height: (unit * 0.08).rounded())
            let rec = pixels(image, bounds: recArea)
            #expect(stride(from: 0, to: rec.count, by: 4).contains { rec[$0] > 230 && rec[$0 + 1] > 230 && rec[$0 + 2] > 230 },
                "The REC label must be drawn in the upper-left viewfinder area")
            #expect(stride(from: 0, to: rec.count, by: 4).contains { rec[$0] > 200 && rec[$0 + 1] < 120 && rec[$0 + 2] < 120 },
                "The recording light must be red over the monochrome frame")
            let draft = TransitionEffectRenderer.applyEffects([effect], to: source(bounds), timelineTime: 12.2, quality: .draft)
            #expect(pixels(draft) == frame)
        }
    }

    @Test func blinkFollowsEffectLocalTimeAndControlsChangeTheActualFrame() {
        let bounds = CGRect(x: 0, y: 0, width: 320, height: 180)
        var effect = EffectTimelineItem(effectType: .videoCamera, startTime: 12.25, duration: 3)
        func render(_ time: Double) -> [UInt8] {
            pixels(TransitionEffectRenderer.applyEffects([effect], to: source(bounds), timelineTime: time))
        }
        let on = render(12.45), off = render(13.05)
        #expect(on != off)
        #expect(on == render(13.45))
        #expect(off == render(14.05))
        let offIsMonochrome = stride(from: 0, to: off.count, by: 4).allSatisfy { index in
            let red = Int(off[index]), green = Int(off[index + 1]), blue = Int(off[index + 2])
            return abs(red - green) <= 1 && abs(green - blue) <= 1
        }
        #expect(offIsMonochrome)
        effect.parameters = [.init(name: "blinkREC", value: 0)]
        #expect(render(13.05) == on)
        effect.parameters.append(.init(name: "barSize", value: 0))
        let noFields = render(13.05)
        #expect(noFields != on)
        #expect(noFields[0] > 30)
        effect.enabled = false
        #expect(render(13.05) == pixels(source(bounds)))
        effect.enabled = true
        effect.intensity = 0
        #expect(render(13.05) == pixels(source(bounds)))
    }

    @Test func savedCameraEffectKeepsSettingsAndCanProduceReviewArtwork() throws {
        let effect = EffectTimelineItem(effectType: .videoCamera, startTime: 2, duration: 5,
            parameters: [.init(name: "barSize", value: 0.12), .init(name: "blinkREC", value: 0)])
        let reopened = try JSONDecoder.veloEdit.decode(EffectTimelineItem.self, from: JSONEncoder.veloEdit.encode(effect))
        #expect(reopened == effect)
        #expect(EffectPresetRegistry.presets(in: .stylized).contains { $0.type == reopened.effectType })

        guard let path = ProcessInfo.processInfo.environment["VELOEDIT_CAMERA_QA_OUTPUT"] else { return }
        let directory = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let photo = try #require(CIImage(contentsOf: root.appendingPathComponent("Resources/TransitionPreviews/effect-field.jpg")))
        for size in [CGSize(width: 960, height: 540), CGSize(width: 540, height: 960)] {
            let bounds = CGRect(origin: .zero, size: size)
            let scale = max(size.width / photo.extent.width, size.height / photo.extent.height)
            let scaled = photo.transformed(by: .init(scaleX: scale, y: scale))
            let input = scaled.transformed(by: .init(translationX: bounds.midX - scaled.extent.midX,
                y: bounds.midY - scaled.extent.midY)).cropped(to: bounds)
            let image = TransitionEffectRenderer.applyEffects([.init(effectType: .videoCamera, startTime: 0, duration: 3)],
                to: input, timelineTime: 0.2)
            let output = directory.appendingPathComponent("camera-\(Int(size.width))x\(Int(size.height)).png")
            let writer = try #require(CGImageDestinationCreateWithURL(output as CFURL, "public.png" as CFString, 1, nil))
            CGImageDestinationAddImage(writer, try #require(context.createCGImage(image, from: bounds)), nil)
            #expect(CGImageDestinationFinalize(writer))
        }
    }
}
