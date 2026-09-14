import CoreGraphics
import CoreImage
import Foundation
import Vision

/// Coordinates are the final, display-oriented canvas coordinates, including
/// fitting, wrapping, placement, scale, rotation and the template's animation.
struct TitleReadabilityRegion {
    var elementID: String
    var lineRects: [CGRect]
    var fontSize: Double
    var textLuminances: [Double]
    var textOpacity: Double
    var visibility: Double

    var bounds: CGRect { lineRects.reduce(CGRect.null) { $0.union($1) } }
}

enum TitleBackgroundLevel: String {
    case none, edge, shade, plate, blur
}

struct TitleBackgroundTreatment {
    var level: TitleBackgroundLevel = .none
    var edgeOpacity: Double = 0
    var strokeWidth: Double = 0
    var shadeOpacity: Double = 0
    /// Radius at a 1080-pixel short side, independent of preview resolution.
    var blurRadius: Double = 0
    var lightSupport: Bool = false

    static let none = TitleBackgroundTreatment()

    func interpolated(toward target: Self, fraction: Double) -> Self {
        func mix(_ a: Double, _ b: Double) -> Double { a + (b - a) * fraction }
        return Self(level: target.level,
                    edgeOpacity: mix(edgeOpacity, target.edgeOpacity),
                    strokeWidth: mix(strokeWidth, target.strokeWidth),
                    shadeOpacity: mix(shadeOpacity, target.shadeOpacity),
                    blurRadius: mix(blurRadius, target.blurRadius),
                    lightSupport: target.lightSupport)
    }
}

struct TitleReadabilityMetrics {
    var contrast: Double
    var poorContrastFraction: Double
    var detail: Double
    var meanLuminance: Double
    var samples: [Double]
}

/// A conservative local perceptual model, not a claim of semantic understanding
/// from luminance alone. Vision supplies face/saliency protection separately.
enum TitleReadabilityAnalysis {
    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
    private static let linearValues = (0...255).map { linear(Double($0) / 255) }

    static func linear(_ value: Double) -> Double {
        value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }

    static func luminance(_ color: CGColor) -> Double {
        guard let c = color.converted(to: sRGB, intent: .relativeColorimetric, options: nil)?.components,
              c.count >= 3 else { return 1 }
        return 0.2126 * linear(Double(c[0])) + 0.7152 * linear(Double(c[1])) + 0.0722 * linear(Double(c[2]))
    }

    static func contrast(_ a: Double, _ b: Double) -> Double {
        (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    static func measure(image: CIImage, region: TitleReadabilityRegion,
                        context: CIContext, canvas: CGRect) -> TitleReadabilityMetrics? {
        var samples: [Double] = []
        var edgeTotal = 0.0
        var edgeCount = 0
        // Sample each actual line separately. A wide layout box or empty space
        // between lines must not make a busy background look deceptively clean.
        for line in region.lineRects {
            let rect = line.intersection(canvas)
            guard !rect.isNull, rect.width >= 1, rect.height >= 1 else { continue }
            let width = min(192, max(16, Int(rect.width / max(1, region.fontSize) * 18)))
            let height = min(48, max(8, Int(Double(width) * rect.height / rect.width)))
            let scaled = image.cropped(to: rect)
                .transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
                .transformed(by: CGAffineTransform(scaleX: CGFloat(width) / rect.width, y: CGFloat(height) / rect.height))
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            bytes.withUnsafeMutableBytes { buffer in
                context.render(scaled, toBitmap: buffer.baseAddress!, rowBytes: width * 4,
                               bounds: CGRect(x: 0, y: 0, width: width, height: height),
                               format: .RGBA8, colorSpace: sRGB)
            }
            let values: [Double] = (0..<(width * height)).map { i in
                let red = linearValues[Int(bytes[i * 4])]
                let green = linearValues[Int(bytes[i * 4 + 1])]
                let blue = linearValues[Int(bytes[i * 4 + 2])]
                return 0.2126 * red + 0.7152 * green + 0.0722 * blue
            }
            for i in values.indices {
                if i % width > 0 { edgeTotal += abs(values[i] - values[i - 1]); edgeCount += 1 }
                if i >= width { edgeTotal += abs(values[i] - values[i - width]); edgeCount += 1 }
            }
            samples.append(contentsOf: values)
        }
        guard !samples.isEmpty else { return nil }
        let contrasts = samples.map { background in
            (region.textLuminances.isEmpty ? [1] : region.textLuminances).map {
                contrast($0 * region.textOpacity + background * (1 - region.textOpacity), background)
            }.min() ?? 1
        }.sorted()
        let target = region.lineRects.count > 1 || region.fontSize / max(1, min(canvas.width, canvas.height)) < 0.042 ? 4.2 : 3.2
        return TitleReadabilityMetrics(
            contrast: contrasts[min(contrasts.count - 1, contrasts.count / 8)],
            poorContrastFraction: Double(contrasts.filter { $0 < target }.count) / Double(contrasts.count),
            detail: min(1, edgeTotal / Double(max(1, edgeCount)) / 0.20),
            meanLuminance: samples.reduce(0, +) / Double(samples.count), samples: samples
        )
    }

    static func choose(metrics: TitleReadabilityMetrics, region: TitleReadabilityRegion,
                       motion: Double, protectedOverlap: Double, canProtectSubjects: Bool) -> TitleBackgroundTreatment {
        let lightSupport = (region.textLuminances.max() ?? 1) < 0.36
        // Even detailed scenery stays original when the letters already separate.
        guard metrics.poorContrastFraction > 0.12 else { return .none }
        let difficulty = min(1, metrics.poorContrastFraction * 0.75 + metrics.detail * 0.25)
        var result = TitleBackgroundTreatment(level: .edge, edgeOpacity: 0.72 + difficulty * 0.26,
                                               strokeWidth: 1.8 + difficulty * 2.2, lightSupport: lightSupport)
        // Uniform sky/water needs an edge, not a blurred patch. A restrained
        // contour remains effective even when the fill matches a flat background.
        guard metrics.detail > 0.18, metrics.poorContrastFraction > 0.28 else { return result }
        result.level = .shade
        result.shadeOpacity = min(0.24, 0.08 + difficulty * 0.16)
        if metrics.detail > 0.40, metrics.poorContrastFraction > 0.48 {
            result.level = .plate
            result.shadeOpacity = min(0.44, 0.24 + difficulty * 0.20)
        }
        // Blur must earn its place after edge + shade/plate, and is suppressed
        // over subjects and during fast action. Long/multiline text is less
        // tolerant of a texture competing with the rhythm of the letter strokes.
        let longText = region.lineRects.count > 1 || region.bounds.width / max(1, region.fontSize) > 15
        let unresolved = residualPoorFraction(metrics: metrics, region: region, shade: result.shadeOpacity,
                                               lightSupport: lightSupport)
        if canProtectSubjects, protectedOverlap < 0.12, motion < 0.22,
           metrics.detail > (longText ? 0.58 : 0.76), unresolved > 0.40 {
            result.level = .blur
            let severity = max(0, (metrics.detail - 0.55) / 0.45)
            result.blurRadius = 1.5 + severity * (longText ? 4.5 : 2.5)
            if longText, metrics.detail > 0.94, metrics.poorContrastFraction > 0.90, motion < 0.06 {
                result.blurRadius = 8
            }
        }
        return result
    }

    static func residualPoorFraction(metrics: TitleReadabilityMetrics, region: TitleReadabilityRegion,
                                     shade: Double, lightSupport: Bool) -> Double {
        guard !metrics.samples.isEmpty else { return 1 }
        let poor = metrics.samples.filter { value in
            let background = value * (1 - shade) + (lightSupport ? shade : 0)
            return (region.textLuminances.isEmpty ? [1] : region.textLuminances).contains {
                contrast($0 * region.textOpacity + background * (1 - region.textOpacity), background) < 3.2
            }
        }.count
        return Double(poor) / Double(metrics.samples.count)
    }
}

/// One instance per video compositor. State is bounded and isolated from other
/// projects. The same timestamp is idempotent; a seek resets temporal history.
final class AdaptiveTitleBackgroundRenderer: @unchecked Sendable {
    struct Output {
        var image: CIImage
        var treatments: [String: TitleBackgroundTreatment]
        var backgroundOverlay: CIImage
    }
    private struct History {
        var time: Double
        var metrics: TitleReadabilityMetrics
        var treatment: TitleBackgroundTreatment
    }
    private struct SubjectSnapshot {
        var time: Double
        var bounds: CGRect
        var regions: [CGRect]
        var reliable: Bool
    }
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let lock = NSLock()
    private var history: [String: History] = [:]
    private var subjectSnapshot: SubjectSnapshot?
    private let subjectDetector: ((CIImage, CGRect) -> [CGRect]?)?

    init(subjectDetector: ((CIImage, CGRect) -> [CGRect]?)? = nil) {
        self.subjectDetector = subjectDetector
    }

    func process(background: CIImage, artwork: CIImage?, regions: [TitleReadabilityRegion],
                 item: TitleTimelineItem, time: Double, bounds: CGRect) -> Output {
        lock.lock()
        defer { lock.unlock() }
        guard item.enabled, item.style.effectiveOpacity > 0,
              time >= item.startTime, time < item.endTime else {
            return Output(image: background, treatments: [:], backgroundOverlay: CIImage.empty())
        }
        if history.count > 96 { history = history.filter { abs(time - $0.value.time) < 2 } }
        var result = background
        var backgroundOverlay = CIImage.empty()
        var treatments: [String: TitleBackgroundTreatment] = [:]
        let shortSideScale = Double(min(bounds.width, bounds.height)) / 1080
        let keyPrefix = "\(item.hashValue):\(bounds.width)x\(bounds.height)"
        for region in regions where region.visibility > 0.001 && region.textOpacity > 0.01 {
            let assessmentImage = artwork?.composited(over: background) ?? background
            guard let metrics = TitleReadabilityAnalysis.measure(image: assessmentImage, region: region,
                                                                  context: context, canvas: bounds) else { continue }
            let key = "\(keyPrefix):\(region.elementID)"
            let previous = history[key]
            let delta = previous.map { time - $0.time } ?? 0
            let continuous = previous != nil && delta >= 0 && delta <= 0.25
            let motion: Double
            if continuous, delta > 0, let previous, previous.metrics.samples.count == metrics.samples.count {
                motion = zip(previous.metrics.samples, metrics.samples).reduce(0) { $0 + abs($1.0 - $1.1) }
                    / Double(max(1, metrics.samples.count))
            } else { motion = 0 }
            let cut = continuous && motion > 0.40
            // Vision is only needed for a genuine candidate for texture reduction.
            let subjects: SubjectSnapshot
            if (metrics.detail > 0.50 && metrics.poorContrastFraction > 0.35) || (previous?.treatment.blurRadius ?? 0) > 0.01 {
                subjects = detectSubjects(image: background, bounds: bounds, time: time, force: cut || !continuous)
            } else {
                subjects = SubjectSnapshot(time: time, bounds: bounds, regions: [], reliable: false)
            }
            let area = max(1, region.bounds.width * region.bounds.height)
            let overlap = subjects.regions.reduce(0.0) { total, subject in
                let intersection = region.bounds.intersection(subject)
                return total + (intersection.isNull ? 0 : Double(intersection.width * intersection.height / area))
            }
            let desired = TitleReadabilityAnalysis.choose(metrics: metrics, region: region, motion: motion,
                                                         protectedOverlap: min(1, overlap), canProtectSubjects: subjects.reliable)
            let treatment: TitleBackgroundTreatment
            if continuous, !cut, let previous {
                // Quick, smooth attack; slower release avoids pumping in foliage.
                // Seek/out-of-order requests never inherit another frame's strength.
                let attack = desired.shadeOpacity > previous.treatment.shadeOpacity || desired.edgeOpacity > previous.treatment.edgeOpacity
                let fraction = delta == 0 ? 0 : 1 - exp(-delta / (attack ? 0.16 : 0.42))
                treatment = previous.treatment.interpolated(toward: desired, fraction: fraction)
            } else { treatment = desired }
            history[key] = History(time: time, metrics: metrics, treatment: treatment)
            var visible = treatment
            // Text motion owns the envelope; no extra effect is scheduled outside
            // the title interval. Feathering also fades smoothly with its letters.
            let envelope = min(1, max(0, region.visibility))
            visible.shadeOpacity *= envelope
            // Protection is immediate, even while blur strength is easing down.
            if !subjects.reliable || motion >= 0.22 || overlap >= 0.12 { visible.blurRadius = 0 }
            visible.blurRadius *= envelope
            if visible.edgeOpacity > 0.01 { treatments[region.elementID] = visible }
            guard visible.shadeOpacity > 0.001 || visible.blurRadius > 0.01 else { continue }
            let mask = Self.softMask(lines: region.lineRects, fontSize: region.fontSize, bounds: bounds)
            if visible.blurRadius > 0.01 {
                let protectedMask = Self.protect(mask: mask, subjects: subjects.regions,
                                                 padding: CGFloat(region.fontSize * 0.4), bounds: bounds)
                let radius = visible.blurRadius * shortSideScale
                let roi = region.bounds.insetBy(dx: -region.fontSize * 1.5 - radius * 3,
                                                dy: -region.fontSize * 1.5 - radius * 3).intersection(bounds)
                let blurred = result.cropped(to: roi).clampedToExtent()
                    .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius]).cropped(to: bounds)
                result = blurred.applyingFilter("CIBlendWithMask", parameters: [
                    kCIInputBackgroundImageKey: result, kCIInputMaskImageKey: protectedMask
                ]).cropped(to: bounds)
                let patch = blurred.applyingFilter("CIBlendWithMask", parameters: [
                    kCIInputBackgroundImageKey: CIImage(color: .clear).cropped(to: bounds),
                    kCIInputMaskImageKey: protectedMask
                ]).cropped(to: bounds)
                backgroundOverlay = patch.composited(over: backgroundOverlay)
            }
            if visible.shadeOpacity > 0.001 {
                result = Self.shade(result, mask: mask, opacity: visible.shadeOpacity,
                                    light: visible.lightSupport, bounds: bounds)
                backgroundOverlay = Self.shade(backgroundOverlay.cropped(to: bounds), mask: mask,
                                               opacity: visible.shadeOpacity, light: visible.lightSupport, bounds: bounds)
            }
            // Recheck the actual processed frame, including designed panels.
            // If a difficult texture still defeats the fill, strengthen only the
            // letter edge; never respond by escalating to a full-frame blur.
            if let reviewed = TitleReadabilityAnalysis.measure(
                image: artwork?.composited(over: result) ?? result, region: region, context: context, canvas: bounds
            ), reviewed.poorContrastFraction > 0.35 {
                visible.edgeOpacity = max(visible.edgeOpacity, 0.88)
                visible.strokeWidth = max(visible.strokeWidth, 1.8)
                treatments[region.elementID] = visible
            }
        }
        return Output(image: result, treatments: treatments, backgroundOverlay: backgroundOverlay)
    }

    static func softMask(lines: [CGRect], fontSize: Double, bounds: CGRect) -> CIImage {
        let black = CIImage(color: .black).cropped(to: bounds)
        var mask = black
        let padding = max(2, fontSize * 0.32)
        let feather = max(2, fontSize * 0.30)
        for line in lines where !line.isNull && !line.isEmpty {
            let rect = line.insetBy(dx: -padding, dy: -padding)
            let solid = CIImage(color: .white).cropped(to: rect).composited(over: black)
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: feather]).cropped(to: bounds)
            mask = solid.applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: mask])
        }
        return mask.cropped(to: bounds)
    }

    static func protect(mask: CIImage, subjects: [CGRect], padding: CGFloat, bounds: CGRect) -> CIImage {
        guard !subjects.isEmpty else { return mask }
        var protected = CIImage(color: .black).cropped(to: bounds)
        for subject in subjects {
            let solid = CIImage(color: .white).cropped(to: subject.insetBy(dx: -padding, dy: -padding))
                .composited(over: CIImage(color: .black).cropped(to: bounds))
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: max(1, padding * 0.28)])
            protected = solid.applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: protected])
        }
        return CIImage(color: .black).cropped(to: bounds).applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: mask, kCIInputMaskImageKey: protected
        ]).cropped(to: bounds)
    }

    private static func shade(_ image: CIImage, mask: CIImage, opacity: Double, light: Bool, bounds: CGRect) -> CIImage {
        let scaledMask = mask.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: opacity, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: opacity, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: opacity, w: 0)
        ])
        return CIImage(color: light ? .white : .black).cropped(to: bounds)
            .applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: image, kCIInputMaskImageKey: scaledMask
            ]).cropped(to: bounds)
    }

    private func detectSubjects(image: CIImage, bounds: CGRect, time: Double, force: Bool) -> SubjectSnapshot {
        if let cached = subjectSnapshot, cached.bounds == bounds,
           time == cached.time || (!force && time >= cached.time && time - cached.time < 0.45) { return cached }
        let regions: [CGRect]?
        if let subjectDetector { regions = subjectDetector(image, bounds) }
        else {
            let scale = min(1, 384 / max(bounds.width, bounds.height))
            let small = image.cropped(to: bounds).transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            if let cgImage = context.createCGImage(small, from: small.extent) {
                let faces = VNDetectFaceRectanglesRequest()
                let saliency = VNGenerateAttentionBasedSaliencyImageRequest()
                do {
                    try VNImageRequestHandler(cgImage: cgImage).perform([faces, saliency])
                    let boxes = (faces.results ?? []).map(\.boundingBox) +
                        (saliency.results?.first?.salientObjects ?? []).filter { $0.confidence >= 0.15 }.map(\.boundingBox)
                    regions = boxes.map { box in
                        CGRect(x: bounds.minX + box.minX * bounds.width, y: bounds.minY + box.minY * bounds.height,
                               width: box.width * bounds.width, height: box.height * bounds.height)
                    }
                } catch { regions = nil }
            } else { regions = nil }
        }
        let snapshot = SubjectSnapshot(time: time, bounds: bounds, regions: regions ?? [], reliable: regions != nil)
        subjectSnapshot = snapshot
        return snapshot
    }
}
