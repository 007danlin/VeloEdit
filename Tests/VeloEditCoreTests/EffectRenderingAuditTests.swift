import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import Testing
@testable import VeloEditCore

@Suite(.serialized) struct EffectRenderingAuditTests {
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let bounds = CGRect(x: 0, y: 0, width: 160, height: 96)

    private func source(_ incoming: Bool = false) -> CIImage {
        let gradient = CIFilter(name: "CILinearGradient", parameters: [
            "inputPoint0": CIVector(x: 0, y: 0), "inputPoint1": CIVector(x: 160, y: 0),
            "inputColor0": incoming ? CIColor(red: 0.1, green: 0.4, blue: 0.8) : CIColor(red: 0.1, green: 0.1, blue: 0.1),
            "inputColor1": incoming ? CIColor(red: 0.8, green: 0.2, blue: 0.1) : CIColor(red: 0.9, green: 0.9, blue: 0.9)
        ])!.outputImage!.cropped(to: bounds)
        return gradient
    }

    private func pixels(_ image: CIImage, in rect: CGRect? = nil) -> [UInt8] {
        let rect = rect ?? bounds
        var bytes = [UInt8](repeating: 0, count: Int(rect.width * rect.height) * 4)
        context.render(image, toBitmap: &bytes, rowBytes: Int(rect.width) * 4, bounds: rect,
            format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        return bytes
    }

    private func transition(_ style: TransitionStyle, _ progress: Double, parameters: [EffectParameter]? = nil) -> CIImage {
        TransitionEffectRenderer.renderTransition(outgoing: source(), incoming: source(true),
            item: .init(style: style, outgoingClipID: UUID(), incomingClipID: UUID(), startTime: 0,
                parameters: parameters), progress: progress, bounds: bounds)
    }

    @Test func allTransitionFramesStayOpaqueInLandscapePortraitAndOffsetBounds() {
        for rect in [bounds, CGRect(x: 13, y: 27, width: 90, height: 160)] {
            let a = source().clampedToExtent().cropped(to: rect)
            let b = source(true).clampedToExtent().cropped(to: rect)
            for style in TransitionStyle.allCases {
                for progress in [0.08, 0.37, 0.5, 0.72, 0.97] {
                    let rendered = TransitionEffectRenderer.renderTransition(outgoing: a, incoming: b,
                        item: .init(style: style, outgoingClipID: UUID(), incomingClipID: UUID(), startTime: 0),
                        progress: progress, bounds: rect)
                    #expect(rendered.extent == rect)
                    let rgba = pixels(rendered, in: rect)
                    let lowestAlpha = stride(from: 3, to: rgba.count, by: 4).map { rgba[$0] }.min()!
                    #expect(lowestAlpha >= 250, "\(style) at \(progress) leaves a transparent edge: \(lowestAlpha)")
                }
            }
        }
    }

    @Test func glitchHasHorizontalTearsAndDiscreteRepeatableBursts() {
        let effect = EffectTimelineItem(effectType: .glitch, startTime: 0, duration: 2, intensity: 0.8)
        func render(_ time: Double) -> [UInt8] {
            pixels(TransitionEffectRenderer.applyEffects([effect], to: source(), timelineTime: time))
        }
        let first = render(0.34)
        #expect(first == render(0.35), "A glitch burst holds until the next digital tick")
        #expect(first != render(0.51), "Glitch must evolve over time")
        let rows = Set((0..<96).map { Data(first[($0 * 640)..<(($0 + 1) * 640)]) })
        #expect(rows.count > 5, "Glitch must tear separate bands instead of shifting the entire frame")
        #expect(pixels(transition(.glitch, 0.43)) != pixels(transition(.rgbSplit, 0.43)))
        #expect(pixels(transition(.glitch, 0.43)) != pixels(transition(.digitalDistortion, 0.43)))
    }

    @Test func correctedFamiliesHaveDistinctGeometry() {
        for pair: (TransitionStyle, TransitionStyle) in [(.whipLeft, .pushLeft), (.shatter, .geometricWipe),
                (.wave, .ripple), (.radial, .circle), (.iris, .circle), (.maskReveal, .circle), (.cameraPush, .zoomIn)] {
            #expect(pixels(transition(pair.0, 0.37)) != pixels(transition(pair.1, 0.37)), "\(pair.0) duplicates \(pair.1)")
        }
        let a = EffectTimelineItem(effectType: .radialBlur, startTime: 0, duration: 1)
        var b = a; b.effectType = .zoomBlur
        #expect(pixels(TransitionEffectRenderer.applyEffects([a], to: source(), timelineTime: 0.5)) !=
            pixels(TransitionEffectRenderer.applyEffects([b], to: source(), timelineTime: 0.5)))
    }

    @Test func wipesTravelInTheirNamedDirectionAndGeometricRevealFinishesBeforeEndpoint() {
        let black = CIImage(color: .black).cropped(to: bounds)
        let white = CIImage(color: .white).cropped(to: bounds)
        func mask(_ style: TransitionStyle, _ progress: Double) -> [UInt8] {
            pixels(TransitionEffectRenderer.renderTransition(outgoing: black, incoming: white,
                item: .init(style: style, outgoingClipID: UUID(), incomingClipID: UUID(), startTime: 0),
                progress: progress, bounds: bounds))
        }
        // CIContext's bitmap is top-down, while Core Image coordinates are y-up.
        let up = mask(.wipeUp, 0.5), down = mask(.wipeDown, 0.5)
        #expect(up[(10 * 160 + 80) * 4] < 10 && up[(85 * 160 + 80) * 4] > 240)
        #expect(down[(10 * 160 + 80) * 4] > 240 && down[(85 * 160 + 80) * 4] < 10)
        let nearEnd = mask(.geometricWipe, 0.999)
        #expect(stride(from: 0, to: nearEnd.count, by: 4).allSatisfy { nearEnd[$0] > 240 })
    }

    @Test func everyExposedTransitionParameterChangesRenderedPixels() {
        for preset in TransitionPresetRegistry.all {
            for parameter in preset.parameters {
                // Hue wraps at 0/1, and rotation wraps at -180/180.
                let upper = parameter.key == "colorHue" ? 0.5 : parameter.key == "rotation" ? 35 : parameter.range.upperBound
                let low = pixels(transition(preset.style, 0.37, parameters: [.init(name: parameter.key, value: parameter.range.lowerBound)]))
                let high = pixels(transition(preset.style, 0.37, parameters: [.init(name: parameter.key, value: upper)]))
                #expect(low != high, "\(preset.style).\(parameter.key) is an inert control")
            }
        }
    }

    @Test func allNonTransformEffectsKeepOpaqueEdgesAndCanBeDisabled() {
        let original = pixels(source())
        for type in TimelineEffectType.allCases where type.category != .motion {
            var effect = EffectTimelineItem(effectType: type, startTime: 0, duration: 1)
            for time in [0.2, 0.51, 0.83] {
                let rendered = pixels(TransitionEffectRenderer.applyEffects([effect], to: source(), timelineTime: time))
                #expect(stride(from: 3, to: rendered.count, by: 4).allSatisfy { rendered[$0] >= 250 }, "\(type) loses edge coverage")
            }
            effect.enabled = false
            #expect(pixels(TransitionEffectRenderer.applyEffects([effect], to: source(), timelineTime: 0.4)) == original)
            effect.enabled = true; effect.intensity = 0
            #expect(pixels(TransitionEffectRenderer.applyEffects([effect], to: source(), timelineTime: 0.4)) == original)
        }
    }

    @Test func automaticCameraMotionCoversFrameAndInspectorRotationIsAppliedOnce() {
        for size in [bounds.size, CGSize(width: 90, height: 160)] {
            let rect = CGRect(origin: .zero, size: size)
            let corners = [CGPoint(x: 0, y: 0), CGPoint(x: rect.maxX, y: 0),
                CGPoint(x: 0, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY)]
            for type: TimelineEffectType in [.pan, .cameraDrift, .shake, .handheld, .spin, .kenBurns, .parallaxMotion] {
                let effect = EffectTimelineItem(effectType: type, startTime: 0, duration: 1)
                for time in [0.0, 0.2, 0.51, 0.8, 1] {
                    let transform = TransitionEffectRenderer.effectTransform([effect], base: .identity, timelineTime: time, renderSize: size)
                    #expect(corners.allSatisfy { rect.insetBy(dx: -0.01, dy: -0.01).contains($0.applying(transform.inverted())) },
                        "\(type) at \(time) exposes the canvas behind the frame")
                }
            }
        }
        let effect = EffectTimelineItem(effectType: .spin, startTime: 0, duration: 1,
            parameters: [.init(name: "rotation", value: 30)], intensity: 0)
        let transform = TransitionEffectRenderer.effectTransform([effect], base: .identity, timelineTime: 0, renderSize: bounds.size)
        #expect(abs(atan2(transform.b, transform.a) - .pi / 6) < 0.001)
    }

    @Test func auditContactSheets() throws {
        guard let directory = ProcessInfo.processInfo.environment["VELOEDIT_EFFECT_AUDIT_OUTPUT"] else { return }
        let output = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/TransitionPreviews")
        let a = try #require(CIImage(contentsOf: resources.appendingPathComponent("wheat-field.webp")))
        let b = try #require(CIImage(contentsOf: resources.appendingPathComponent("moraine-lake.jpg")))
        let cell = CGRect(x: 0, y: 0, width: 240, height: 135)
        func fit(_ image: CIImage) -> CIImage {
            let scale = max(cell.width / image.extent.width, cell.height / image.extent.height)
            let scaled = image.transformed(by: .init(scaleX: scale, y: scale))
            return scaled.transformed(by: .init(translationX: cell.midX - scaled.extent.midX, y: cell.midY - scaled.extent.midY)).cropped(to: cell)
        }
        let styles: [TransitionStyle] = [.glitch, .rgbSplit, .digitalDistortion, .whipLeft, .shatter, .wave, .ripple, .radial, .geometricWipe]
        let sheet = CGContext(data: nil, width: 240 * 5, height: 135 * styles.count, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for (row, style) in styles.enumerated() {
            for (column, progress) in [0.1, 0.3, 0.5, 0.7, 0.9].enumerated() {
                let frame = TransitionEffectRenderer.renderTransition(outgoing: fit(a), incoming: fit(b),
                    item: .init(style: style, outgoingClipID: UUID(), incomingClipID: UUID(), startTime: 0),
                    progress: progress, bounds: cell)
                sheet.draw(try #require(context.createCGImage(frame, from: cell)), in:
                    CGRect(x: column * 240, y: (styles.count - row - 1) * 135, width: 240, height: 135))
            }
        }
        let image = try #require(sheet.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(output.appendingPathComponent("transitions.png") as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        try styles.map(\.rawValue).joined(separator: "\n").write(to: output.appendingPathComponent("rows.txt"), atomically: true, encoding: .utf8)
    }
}
