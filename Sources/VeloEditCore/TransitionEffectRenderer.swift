import Foundation
import CoreGraphics
import CoreImage

public enum TransitionEffectRenderQuality: String, Sendable {
    case draft
    case full
}

/// One native Core Image renderer shared by library cards, Timeline playback
/// and export. The catalogue only describes presets; this type owns their
/// actual pixels so previews cannot drift away from the final movie.
public enum TransitionEffectRenderer {
    private static let previewContext = CIContext(options: [.cacheIntermediates: true])
    private static let previewCache = TransitionEffectPreviewCache()
    private static let transitionPreviewPhotos: (CIImage, CIImage)? = {
        guard let resources = Bundle.main.resourceURL?.appendingPathComponent("TransitionPreviews", isDirectory: true),
              let outgoing = CIImage(
                contentsOf: resources.appendingPathComponent("wheat-field.webp"),
                options: [.applyOrientationProperty: true]
              ),
              let incoming = CIImage(
                contentsOf: resources.appendingPathComponent("moraine-lake.jpg"),
                options: [.applyOrientationProperty: true]
              ) else {
            return nil
        }
        return (outgoing, incoming)
    }()

    public static func applyEffects(
        _ effects: [EffectTimelineItem],
        to source: CIImage,
        timelineTime: Double,
        quality: TransitionEffectRenderQuality = .full
    ) -> CIImage {
        var image = source
        for effect in EffectStackEngine.orderedForRendering(effects) where effect.enabled {
            let preset = EffectPresetRegistry.preset(for: effect.effectType)
            let requested = min(max(0, effect.parameterValue("intensity", at: timelineTime)), 1)
            let amount = quality == .draft && preset.isHeavy ? min(0.58, requested) : requested
            guard amount > 0.0001 else { continue }
            let extent = source.extent
            switch effect.effectType {
            case .blur, .backgroundBlur, .lensBlur:
                let radius = effect.effectType == .lensBlur ? 48.0 : 34.0
                image = gaussianBlur(image, radius: radius * amount, extent: extent)
            case .softFocus:
                let softened = gaussianBlur(image, radius: 18 * amount, extent: extent)
                image = withOpacity(softened, amount * 0.58).composited(over: image).cropped(to: extent)
            case .zoomBlur, .radialBlur:
                let radius = max(1, effect.parameterValue("radius", at: timelineTime)) * amount
                image = image.clampedToExtent().applyingFilter("CIZoomBlur", parameters: [
                    kCIInputCenterKey: CIVector(x: extent.midX, y: extent.midY),
                    kCIInputAmountKey: effect.effectType == .radialBlur ? radius * 0.62 : radius
                ]).cropped(to: extent)
            case .directionalBlur, .motionBlur, .cinematicMotionBlur:
                let maximum = effect.effectType == .cinematicMotionBlur ? 7.0 : 28.0
                let angle = effect.parameterValue("angle", at: timelineTime)
                image = image.clampedToExtent()
                    .applyingFilter("CIMotionBlur", parameters: [kCIInputRadiusKey: maximum * amount, kCIInputAngleKey: angle])
                    .cropped(to: extent)
            case .exposure:
                image = image.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: (amount - 0.5) * 3.2])
            case .brightness:
                image = image.applyingFilter("CIColorControls", parameters: [kCIInputBrightnessKey: (amount - 0.5) * 0.8])
            case .contrast:
                image = image.applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 0.5 + amount])
            case .saturation:
                image = image.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0.35 + amount * 1.3])
            case .vibrance:
                image = image.applyingFilter("CIVibrance", parameters: ["inputAmount": (amount - 0.5) * 2])
            case .temperature:
                let target = 6_500 + (amount - 0.5) * 4_000
                image = image.applyingFilter("CITemperatureAndTint", parameters: [
                    "inputNeutral": CIVector(x: 6_500, y: 0),
                    "inputTargetNeutral": CIVector(x: target, y: 0)
                ])
            case .tint:
                image = image.applyingFilter("CITemperatureAndTint", parameters: [
                    "inputNeutral": CIVector(x: 6_500, y: 0),
                    "inputTargetNeutral": CIVector(x: 6_500, y: (amount - 0.5) * 240)
                ])
            case .highlights:
                image = image.applyingFilter("CIHighlightShadowAdjust", parameters: ["inputHighlightAmount": 0.35 + amount * 1.3])
            case .shadows:
                image = image.applyingFilter("CIHighlightShadowAdjust", parameters: ["inputShadowAmount": amount * 1.25])
            case .sharpness:
                image = image.applyingFilter("CISharpenLuminance", parameters: [kCIInputSharpnessKey: amount * 1.4])
            case .colorGrade:
                image = cinematicGrade(image, contrast: 1 + amount * 0.22, saturation: 1 + amount * 0.10, warmth: amount * 0.08)
            case .cinematicContrast:
                image = cinematicGrade(image, contrast: 1 + amount * 0.42, saturation: 1 - amount * 0.07, warmth: amount * 0.03)
            case .tealOrangeGrade:
                image = tealOrangeGrade(image, amount: amount, extent: extent)
            case .vintage:
                image = cinematicGrade(image, contrast: 1 - amount * 0.18, saturation: 1 - amount * 0.34, warmth: amount * 0.26)
                image = grain(over: image, amount: amount * 0.08, dust: false, extent: extent)
            case .filmLook:
                image = cinematicGrade(image, contrast: 1 + amount * 0.28, saturation: 1 - amount * 0.12, warmth: amount * 0.12)
                image = grain(over: image, amount: amount * 0.10, dust: false, extent: extent)
            case .vignette, .cinematicVignette:
                let strength = effect.effectType == .cinematicVignette ? amount * 0.42 : amount
                image = image.applyingFilter("CIVignette", parameters: [
                    kCIInputIntensityKey: strength * 2.1,
                    kCIInputRadiusKey: max(extent.width, extent.height) * 0.55
                ])
            case .grain, .filmGrain, .noise, .dust:
                let baseStrength: Double
                switch effect.effectType {
                case .filmGrain: baseStrength = 0.28
                case .dust: baseStrength = 0.20
                case .noise: baseStrength = 0.48
                default: baseStrength = 0.45
                }
                image = grain(over: image, amount: amount * baseStrength, dust: effect.effectType == .dust, extent: extent)
            case .light:
                image = image.applyingFilter("CIHighlightShadowAdjust", parameters: ["inputHighlightAmount": 1 + amount * 0.65, "inputShadowAmount": amount * 0.2])
            case .flash:
                let progress = localProgress(effect, timelineTime: timelineTime)
                let peak = max(0, 1 - abs(progress * 2 - 1)) * amount
                image = image.applyingFilter("CIColorControls", parameters: [kCIInputBrightnessKey: peak * 0.75])
            case .glow, .bloom:
                let maximum = effect.effectType == .bloom ? 42.0 : 28.0
                image = image.clampedToExtent()
                    .applyingFilter("CIBloom", parameters: [kCIInputRadiusKey: maximum * amount, kCIInputIntensityKey: 0.25 + amount])
                    .cropped(to: extent)
            case .chromaticAberration, .rgbSplit:
                image = rgbSplit(image, amount: amount, extent: extent)
            case .lensDistortion, .barrelDistortion, .fisheye:
                let radius = min(extent.width, extent.height) * max(0.1, effect.parameterValue("radius", at: timelineTime))
                let scale: Double
                switch effect.effectType {
                case .fisheye: scale = 0.82 * amount
                case .barrelDistortion: scale = -0.52 * amount
                default: scale = 0.42 * amount
                }
                image = image.clampedToExtent().applyingFilter("CIBumpDistortion", parameters: [
                    kCIInputCenterKey: CIVector(x: extent.midX, y: extent.midY),
                    kCIInputRadiusKey: radius,
                    kCIInputScaleKey: scale
                ]).cropped(to: extent)
            case .glitch:
                let progress = localProgress(effect, timelineTime: timelineTime)
                let jitter = sin(progress * .pi * 18) * amount
                image = rgbSplit(image, amount: amount * 0.8, extent: extent)
                    .transformed(by: CGAffineTransform(translationX: jitter * extent.width * 0.025, y: 0))
                    .cropped(to: extent)
            case .scanlines:
                image = scanlines(over: image, amount: amount, scale: max(2, effect.parameterValue("scale", at: timelineTime)), extent: extent)
            case .pixelate:
                image = image.applyingFilter("CIPixellate", parameters: [
                    kCIInputCenterKey: CIVector(x: extent.midX, y: extent.midY),
                    kCIInputScaleKey: 2 + amount * 38
                ]).cropped(to: extent)
            case .halftone:
                image = image.applyingFilter("CIDotScreen", parameters: [
                    kCIInputCenterKey: CIVector(x: extent.midX, y: extent.midY),
                    kCIInputWidthKey: max(2, effect.parameterValue("scale", at: timelineTime)),
                    kCIInputSharpnessKey: 0.55 + amount * 0.4
                ]).cropped(to: extent)
            case .posterize:
                let levels = max(2, effect.parameterValue("levels", at: timelineTime))
                image = image.applyingFilter("CIColorPosterize", parameters: ["inputLevels": levels]).cropped(to: extent)
            case .vhsDistortion:
                let progress = localProgress(effect, timelineTime: timelineTime)
                let jitter = sin(progress * .pi * 22) * amount * extent.width * 0.012
                image = rgbSplit(image, amount: amount * 0.46, extent: extent)
                    .transformed(by: CGAffineTransform(translationX: jitter, y: 0)).cropped(to: extent)
                image = scanlines(over: image, amount: amount * 0.72, scale: 6, extent: extent)
            case .lightLeak, .filmBurn:
                let progress = localProgress(effect, timelineTime: timelineTime)
                let overlay = warmLightOverlay(extent: extent, progress: progress, amount: amount, burn: effect.effectType == .filmBurn)
                image = overlay.applyingFilter("CIScreenBlendMode", parameters: [kCIInputBackgroundImageKey: image]).cropped(to: extent)
            case .fogHaze:
                let haze = CIImage(color: CIColor(red: 0.78, green: 0.83, blue: 0.86, alpha: amount * 0.28)).cropped(to: extent)
                image = haze.applyingFilter("CIScreenBlendMode", parameters: [kCIInputBackgroundImageKey: image]).cropped(to: extent)
            case .letterbox:
                image = letterboxed(image, amount: effect.parameterValue("barSize", at: timelineTime) * amount, extent: extent)
            case .zoom, .pushIn, .pullOut, .pan, .shake, .cameraDrift, .handheld,
                 .spin, .kenBurns, .parallaxMotion, .fade, .opacity:
                break
            }
            if preset.renderStage == .transform {
                image = animatedCrop(effect, image: image, timelineTime: timelineTime, extent: extent)
            }
        }
        return image
    }

    public static func effectTransform(
        _ effects: [EffectTimelineItem],
        base: CGAffineTransform,
        timelineTime: Double,
        renderSize: CGSize
    ) -> CGAffineTransform {
        var transform = base
        for effect in EffectStackEngine.orderedForRendering(effects) where effect.enabled {
            let amount = min(max(0, effect.parameterValue("intensity", at: timelineTime)), 1)
            let progress = localProgress(effect, timelineTime: timelineTime)
            switch effect.effectType {
            case .zoom:
                transform = zoomed(transform, scale: 1 + CGFloat(amount * progress * 0.28), renderSize: renderSize)
            case .pushIn:
                transform = zoomed(transform, scale: 1 + CGFloat(amount * progress * 0.42), renderSize: renderSize)
            case .pullOut:
                transform = zoomed(transform, scale: 1 + CGFloat(amount * (1 - progress) * 0.42), renderSize: renderSize)
            case .pan:
                let direction = effect.parameterValue("direction", at: timelineTime) >= 0 ? 1.0 : -1.0
                transform = transform.concatenating(CGAffineTransform(translationX: renderSize.width * CGFloat(direction * amount * (progress - 0.5) * 0.18), y: 0))
            case .cameraDrift:
                let direction = effect.parameterValue("direction", at: timelineTime) >= 0 ? 1.0 : -1.0
                let x = sin(progress * .pi) * direction * amount * Double(renderSize.width) * 0.025
                let y = cos(progress * .pi * 0.7) * amount * Double(renderSize.height) * 0.012
                transform = zoomed(transform, scale: 1 + CGFloat(amount * 0.025), renderSize: renderSize)
                    .concatenating(CGAffineTransform(translationX: x, y: y))
            case .shake:
                let cycles = effect.parameterValue("frequency", at: timelineTime) == 0 ? 13 : effect.parameterValue("frequency", at: timelineTime)
                let amplitude = max(0.05, effect.parameterValue("amplitude", at: timelineTime))
                let x = sin(progress * .pi * 2 * cycles) * amount * amplitude * Double(renderSize.width) * 0.028
                let y = cos(progress * .pi * 2 * cycles * 1.37) * amount * amplitude * Double(renderSize.height) * 0.028
                transform = transform.concatenating(CGAffineTransform(translationX: x, y: y))
            case .handheld:
                let cycles = max(2, effect.parameterValue("frequency", at: timelineTime))
                let amplitude = max(0.04, effect.parameterValue("amplitude", at: timelineTime))
                let x = sin(progress * .pi * 2 * cycles) * amount * amplitude * Double(renderSize.width) * 0.018
                let y = cos(progress * .pi * 2 * cycles * 0.83) * amount * amplitude * Double(renderSize.height) * 0.015
                transform = transform.concatenating(CGAffineTransform(translationX: x, y: y))
            case .spin:
                let angle = CGFloat(effect.parameterValue("rotation", at: timelineTime) * .pi / 180)
                    + CGFloat(progress * amount * .pi * 0.35)
                transform = centeredTransform(transform, anchorX: 0.5, anchorY: 0.5, scaleX: 1, scaleY: 1, rotation: angle, x: 0, y: 0, renderSize: renderSize)
            case .kenBurns:
                transform = zoomed(transform, scale: 1 + CGFloat(amount * progress * 0.16), renderSize: renderSize)
                    .concatenating(CGAffineTransform(translationX: CGFloat(progress - 0.5) * renderSize.width * 0.04 * CGFloat(amount), y: 0))
            case .parallaxMotion:
                let direction = effect.parameterValue("direction", at: timelineTime) >= 0 ? 1.0 : -1.0
                transform = zoomed(transform, scale: 1 + CGFloat(amount * 0.035), renderSize: renderSize)
                    .concatenating(CGAffineTransform(translationX: CGFloat(direction * (progress - 0.5) * amount) * renderSize.width * 0.12, y: CGFloat(sin(progress * .pi) * amount) * renderSize.height * 0.02))
            default:
                break
            }
            let positionX = effect.parameterValue("positionX", at: timelineTime)
            let positionY = effect.parameterValue("positionY", at: timelineTime)
            let scaleX = effect.parameterValue("scaleX", at: timelineTime)
            let scaleY = effect.parameterValue("scaleY", at: timelineTime)
            let rotation = effect.parameterValue("rotation", at: timelineTime) * .pi / 180
            let anchorX = effect.parameterValue("anchorX", at: timelineTime)
            let anchorY = effect.parameterValue("anchorY", at: timelineTime)
            if positionX != 0 || positionY != 0 || abs(scaleX - 1) > 0.000_001 || abs(scaleY - 1) > 0.000_001 || rotation != 0 {
                transform = centeredTransform(
                    transform,
                    anchorX: anchorX,
                    anchorY: anchorY,
                    scaleX: CGFloat(scaleX),
                    scaleY: CGFloat(scaleY),
                    rotation: CGFloat(rotation),
                    x: CGFloat(positionX) * renderSize.width * 0.5,
                    y: CGFloat(positionY) * renderSize.height * 0.5,
                    renderSize: renderSize
                )
            }
        }
        return transform
    }

    public static func effectOpacity(_ effects: [EffectTimelineItem], timelineTime: Double) -> Double {
        EffectStackEngine.orderedForRendering(effects).reduce(1) { value, effect in
            guard effect.enabled else { return value }
            if effect.effectType == .opacity {
                return value * effect.parameterValue("intensity", at: timelineTime)
            }
            if effect.effectType == .fade {
                let progress = localProgress(effect, timelineTime: timelineTime)
                let peak = 1 - abs(progress * 2 - 1)
                return value * max(0, 1 - effect.parameterValue("intensity", at: timelineTime) * peak)
            }
            if EffectPresetRegistry.preset(for: effect.effectType).parameter(named: "opacity") != nil {
                return value * min(max(0, effect.parameterValue("opacity", at: timelineTime)), 1)
            }
            return value
        }
    }

    public static func renderTransition(
        outgoing: CIImage,
        incoming: CIImage,
        item: TimelineTransitionItem,
        progress requestedProgress: Double,
        bounds: CGRect,
        quality: TransitionEffectRenderQuality = .full
    ) -> CIImage {
        let progress = min(max(0, requestedProgress), 1)
        guard item.enabled else { return progress < 0.5 ? outgoing.cropped(to: bounds) : incoming.cropped(to: bounds) }
        if progress <= 0.000_001 { return outgoing.cropped(to: bounds) }
        if progress >= 0.999_999 { return incoming.cropped(to: bounds) }
        let style = item.style
        if style == .cut { return progress < 0.5 ? outgoing.cropped(to: bounds) : incoming.cropped(to: bounds) }
        let preset = TransitionPresetRegistry.preset(for: style)
        let intensity = quality == .draft && preset.isHeavy ? min(0.58, item.effectiveIntensity) : item.effectiveIntensity
        let eased = item.effectiveEasing.transform(progress)
        let peak = 1 - abs(progress * 2 - 1)
        var outgoingImage = outgoing.cropped(to: bounds)
        var incomingImage = incoming.cropped(to: bounds)

        switch style {
        case .blurDissolve, .lensBlur:
            let radius = (style == .lensBlur ? 48.0 : 32.0) * peak * max(0.2, item.parameterValue("blur")) * intensity
            outgoingImage = gaussianBlur(outgoingImage, radius: radius, extent: bounds)
            incomingImage = gaussianBlur(incomingImage, radius: radius, extent: bounds)
        case .filmDissolve:
            outgoingImage = grain(over: outgoingImage, amount: 0.12 * peak * intensity, dust: false, extent: bounds)
            incomingImage = grain(over: incomingImage, amount: 0.12 * peak * intensity, dust: false, extent: bounds)
        case .glitch, .rgbSplit, .digitalDistortion:
            let amount = peak * intensity * max(0.2, item.parameterValue("amount"))
            outgoingImage = rgbSplit(outgoingImage, amount: amount, extent: bounds)
            incomingImage = rgbSplit(incomingImage, amount: amount, extent: bounds)
            if style != .rgbSplit {
                let offset = sin(progress * .pi * max(4, item.parameterValue("frequency"))) * amount * bounds.width * 0.035
                incomingImage = incomingImage.transformed(by: CGAffineTransform(translationX: offset, y: 0)).cropped(to: bounds)
            }
        case .pixelate:
            let scale = 2 + peak * intensity * 72
            outgoingImage = outgoingImage.applyingFilter("CIPixellate", parameters: [kCIInputScaleKey: scale]).cropped(to: bounds)
            incomingImage = incomingImage.applyingFilter("CIPixellate", parameters: [kCIInputScaleKey: scale]).cropped(to: bounds)
        case .ripple, .wave:
            let radius = min(bounds.width, bounds.height) * (0.18 + progress * 0.74)
            let scale = sin(progress * .pi) * intensity * (style == .wave ? 0.35 : 0.62)
            incomingImage = incomingImage.clampedToExtent().applyingFilter("CIBumpDistortion", parameters: [
                kCIInputCenterKey: CIVector(x: bounds.midX, y: bounds.midY),
                kCIInputRadiusKey: radius,
                kCIInputScaleKey: scale
            ]).cropped(to: bounds)
        default:
            break
        }

        if let mask = revealMask(style: style, progress: eased, item: item, bounds: bounds) {
            return incomingImage.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: outgoingImage,
                kCIInputMaskImageKey: mask
            ]).cropped(to: bounds)
        }

        if isDirectional(style) || isMotion(style) {
            let outgoingTransform = transitionTransform(style: style, direction: item.effectiveDirection, incoming: false, progress: eased, intensity: intensity, bounds: bounds)
            let incomingTransform = transitionTransform(style: style, direction: item.effectiveDirection, incoming: true, progress: eased, intensity: intensity, bounds: bounds)
            outgoingImage = outgoingImage.transformed(by: outgoingTransform).cropped(to: bounds)
            incomingImage = incomingImage.transformed(by: incomingTransform).cropped(to: bounds)
        }

        let opacity: Double
        switch style {
        case .fadeThroughBlack, .fade:
            let outgoingOpacity = max(0, 1 - progress * 2)
            let incomingOpacity = max(0, progress * 2 - 1)
            let base = CIImage(color: .black).cropped(to: bounds)
            return withOpacity(incomingImage, incomingOpacity).composited(over: withOpacity(outgoingImage, outgoingOpacity).composited(over: base))
        case .fadeToWhite:
            let outgoingOpacity = max(0, 1 - progress * 2)
            let incomingOpacity = max(0, progress * 2 - 1)
            let base = CIImage(color: .white).cropped(to: bounds)
            return withOpacity(incomingImage, incomingOpacity).composited(over: withOpacity(outgoingImage, outgoingOpacity).composited(over: base))
        case .dipToColor:
            let hue = item.parameterValue("colorHue")
            let color = colorForHue(hue)
            let base = CIImage(color: color).cropped(to: bounds)
            let outgoingOpacity = max(0, 1 - progress * 2)
            let incomingOpacity = max(0, progress * 2 - 1)
            return withOpacity(incomingImage, incomingOpacity).composited(over: withOpacity(outgoingImage, outgoingOpacity).composited(over: base))
        default:
            opacity = eased
        }

        var result = withOpacity(incomingImage, opacity).composited(over: outgoingImage)
        switch style {
        case .lightFlash, .exposureFlash:
            let flashAmount = peak * intensity * (style == .exposureFlash ? 0.92 : 0.72)
            let overlay = CIImage(color: CIColor(red: 1, green: 0.97, blue: 0.88, alpha: flashAmount)).cropped(to: bounds)
            result = overlay.applyingFilter("CIScreenBlendMode", parameters: [kCIInputBackgroundImageKey: result]).cropped(to: bounds)
        case .lightLeak, .filmBurn:
            let overlay = warmLightOverlay(extent: bounds, progress: progress, amount: peak * intensity, burn: style == .filmBurn)
            result = overlay.applyingFilter("CIScreenBlendMode", parameters: [kCIInputBackgroundImageKey: result]).cropped(to: bounds)
        case .shatter:
            let cells = incomingImage.applyingFilter("CICrystallize", parameters: [kCIInputRadiusKey: max(2, (1 - peak) * 24 + 3)]).cropped(to: bounds)
            result = withOpacity(cells, eased).composited(over: outgoingImage)
        default:
            break
        }
        return result.cropped(to: bounds)
    }

    public static func previewTransitionCGImage(
        style: TransitionStyle,
        progress: Double,
        size: CGSize = CGSize(width: 480, height: 270),
        quality: TransitionEffectRenderQuality = .draft
    ) -> CGImage? {
        let bucket = Int(min(max(0, progress), 1) * 30)
        let key = "transition:\(style.rawValue):\(Int(size.width))x\(Int(size.height)):\(bucket):\(quality.rawValue)"
        if let cached = previewCache.image(for: key) { return cached }
        let bounds = CGRect(origin: .zero, size: size)
        let images = previewTransitionSources(bounds: bounds)
        let preset = TransitionPresetRegistry.preset(for: style)
        let item = TimelineTransitionItem(
            style: style,
            outgoingClipID: Self.previewOutgoingID,
            incomingClipID: Self.previewIncomingID,
            startTime: 0,
            duration: preset.defaultDuration,
            intensity: preset.defaultIntensity,
            parameters: preset.defaultParameters
        )
        let rendered = renderTransition(outgoing: images.0, incoming: images.1, item: item, progress: progress, bounds: bounds, quality: quality)
        return cachedCGImage(rendered, bounds: bounds, key: key)
    }

    public static func previewEffectCGImage(
        type: TimelineEffectType,
        progress: Double,
        size: CGSize = CGSize(width: 480, height: 270),
        quality: TransitionEffectRenderQuality = .draft
    ) -> CGImage? {
        let bucket = Int(min(max(0, progress), 1) * 30)
        let key = "effect:\(type.rawValue):\(Int(size.width))x\(Int(size.height)):\(bucket):\(quality.rawValue)"
        if let cached = previewCache.image(for: key) { return cached }
        let bounds = CGRect(origin: .zero, size: size)
        var source = previewSources(bounds: bounds).0
        let preset = EffectPresetRegistry.preset(for: type)
        let parameters = preset.parameters.filter { $0.key != "intensity" }.map { EffectParameter(name: $0.key, value: $0.defaultValue) }
        let effect = EffectTimelineItem(
            effectType: type,
            startTime: 0,
            duration: 1,
            parameters: parameters,
            intensity: type.defaultIntensity,
            explanation: ["Живая карточка использует renderer Timeline/Export"]
        )
        source = applyEffects([effect], to: source, timelineTime: progress, quality: quality)
        let transform = effectTransform([effect], base: .identity, timelineTime: progress, renderSize: size)
        source = source.transformed(by: transform).cropped(to: bounds)
        source = withOpacity(source, effectOpacity([effect], timelineTime: progress))
        return cachedCGImage(source, bounds: bounds, key: key)
    }

    private static let previewOutgoingID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private static let previewIncomingID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

    private static func cachedCGImage(_ image: CIImage, bounds: CGRect, key: String) -> CGImage? {
        guard let cgImage = previewContext.createCGImage(image, from: bounds) else { return nil }
        previewCache.store(cgImage, for: key)
        return cgImage
    }

    private static func previewSources(bounds: CGRect) -> (CIImage, CIImage) {
        let outgoing = linearGradient(
            start: CIColor(red: 0.03, green: 0.16, blue: 0.30),
            end: CIColor(red: 0.12, green: 0.72, blue: 0.88),
            bounds: bounds
        )
        let incoming = linearGradient(
            start: CIColor(red: 0.95, green: 0.30, blue: 0.12),
            end: CIColor(red: 0.48, green: 0.08, blue: 0.46),
            bounds: bounds
        )
        let outgoingAccent = CIImage(color: CIColor(red: 1, green: 0.92, blue: 0.42, alpha: 0.88))
            .cropped(to: CGRect(x: bounds.width * 0.12, y: bounds.height * 0.18, width: bounds.width * 0.28, height: bounds.height * 0.60))
        let incomingAccent = CIImage(color: CIColor(red: 0.38, green: 1, blue: 0.72, alpha: 0.82))
            .cropped(to: CGRect(x: bounds.width * 0.58, y: bounds.height * 0.16, width: bounds.width * 0.27, height: bounds.height * 0.64))
        return (outgoingAccent.composited(over: outgoing).cropped(to: bounds), incomingAccent.composited(over: incoming).cropped(to: bounds))
    }

    private static func previewTransitionSources(bounds: CGRect) -> (CIImage, CIImage) {
        guard let (outgoing, incoming) = transitionPreviewPhotos else {
            return previewSources(bounds: bounds)
        }
        return (
            aspectFilled(outgoing, into: bounds),
            aspectFilled(incoming, into: bounds)
        )
    }

    private static func aspectFilled(_ image: CIImage, into bounds: CGRect) -> CIImage {
        guard !image.extent.isEmpty, image.extent.width > 0, image.extent.height > 0 else {
            return image.cropped(to: bounds)
        }
        let scale = max(bounds.width / image.extent.width, bounds.height / image.extent.height)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let centered = scaled.transformed(by: CGAffineTransform(
            translationX: bounds.midX - scaled.extent.midX,
            y: bounds.midY - scaled.extent.midY
        ))
        return centered.cropped(to: bounds)
    }

    private static func linearGradient(start: CIColor, end: CIColor, bounds: CGRect) -> CIImage {
        guard let filter = CIFilter(name: "CILinearGradient") else { return CIImage(color: start).cropped(to: bounds) }
        filter.setValue(CIVector(x: bounds.minX, y: bounds.minY), forKey: "inputPoint0")
        filter.setValue(CIVector(x: bounds.maxX, y: bounds.maxY), forKey: "inputPoint1")
        filter.setValue(start, forKey: "inputColor0")
        filter.setValue(end, forKey: "inputColor1")
        return (filter.outputImage ?? CIImage(color: start)).cropped(to: bounds)
    }

    private static func revealMask(style: TransitionStyle, progress: Double, item: TimelineTransitionItem, bounds: CGRect) -> CIImage? {
        let softness = max(0.5, item.parameterValue("softness") * min(bounds.width, bounds.height) * 0.12)
        switch style {
        case .wipeLeft, .wipeRight, .wipeUp, .wipeDown:
            let rect: CGRect
            switch style {
            case .wipeLeft: rect = CGRect(x: bounds.maxX - bounds.width * progress, y: bounds.minY, width: bounds.width * progress, height: bounds.height)
            case .wipeRight: rect = CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width * progress, height: bounds.height)
            case .wipeUp: rect = CGRect(x: bounds.minX, y: bounds.maxY - bounds.height * progress, width: bounds.width, height: bounds.height * progress)
            default: rect = CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: bounds.height * progress)
            }
            return CIImage(color: .white).cropped(to: rect).composited(over: CIImage(color: .black).cropped(to: bounds)).cropped(to: bounds)
        case .circle, .iris, .radial, .maskReveal:
            let diagonal = hypot(bounds.width, bounds.height)
            let radius = diagonal * progress * (style == .iris ? 0.72 : 0.62)
            guard let filter = CIFilter(name: "CIRadialGradient") else { return nil }
            filter.setValue(CIVector(x: bounds.midX, y: bounds.midY), forKey: "inputCenter")
            filter.setValue(max(0, radius - softness), forKey: "inputRadius0")
            filter.setValue(radius + softness, forKey: "inputRadius1")
            filter.setValue(CIColor.white, forKey: "inputColor0")
            filter.setValue(CIColor.black, forKey: "inputColor1")
            return filter.outputImage?.cropped(to: bounds)
        case .geometricWipe, .shatter:
            let width = bounds.width * progress
            let offset = bounds.height * 0.32
            let rect = CGRect(x: bounds.minX - offset + width, y: bounds.minY, width: width + offset, height: bounds.height)
            return CIImage(color: .white).cropped(to: rect).composited(over: CIImage(color: .black).cropped(to: bounds)).cropped(to: bounds)
        default:
            return nil
        }
    }

    private static func transitionTransform(style: TransitionStyle, direction: TransitionDirection, incoming: Bool, progress: Double, intensity: Double, bounds: CGRect) -> CGAffineTransform {
        let width = bounds.width
        let height = bounds.height
        switch style {
        case .push:
            switch direction {
            case .right: return CGAffineTransform(translationX: incoming ? -width * (1 - progress) : width * progress, y: 0)
            case .up: return CGAffineTransform(translationX: 0, y: incoming ? -height * (1 - progress) : height * progress)
            case .down: return CGAffineTransform(translationX: 0, y: incoming ? height * (1 - progress) : -height * progress)
            default: return CGAffineTransform(translationX: incoming ? width * (1 - progress) : -width * progress, y: 0)
            }
        case .pushLeft, .whipLeft:
            return CGAffineTransform(translationX: incoming ? width * (1 - progress) : -width * progress, y: 0)
        case .pushRight, .whipRight:
            return CGAffineTransform(translationX: incoming ? -width * (1 - progress) : width * progress, y: 0)
        case .pushUp, .whipUp:
            return CGAffineTransform(translationX: 0, y: incoming ? -height * (1 - progress) : height * progress)
        case .pushDown, .whipDown:
            return CGAffineTransform(translationX: 0, y: incoming ? height * (1 - progress) : -height * progress)
        case .slideLeft:
            return CGAffineTransform(translationX: incoming ? width * (1 - progress) : 0, y: 0)
        case .slideRight:
            return CGAffineTransform(translationX: incoming ? -width * (1 - progress) : 0, y: 0)
        case .slideUp:
            return CGAffineTransform(translationX: 0, y: incoming ? -height * (1 - progress) : 0)
        case .slideDown:
            return CGAffineTransform(translationX: 0, y: incoming ? height * (1 - progress) : 0)
        case .zoom, .zoomIn, .cameraPush:
            let scale = incoming ? 1.20 - progress * 0.20 : 1 - progress * 0.08 * intensity
            return centeredScale(scale, bounds: bounds)
        case .zoomOut, .cameraPull:
            let scale = incoming ? 0.78 + progress * 0.22 : 1 + progress * 0.12 * intensity
            return centeredScale(scale, bounds: bounds)
        case .spin:
            let angle = CGFloat((incoming ? 1 - progress : -progress) * .pi * intensity)
            let scale = incoming ? 0.72 + progress * 0.28 : 1 - progress * 0.12
            return CGAffineTransform(translationX: bounds.midX, y: bounds.midY)
                .rotated(by: angle)
                .scaledBy(x: scale, y: scale)
                .translatedBy(x: -bounds.midX, y: -bounds.midY)
        default:
            return .identity
        }
    }

    private static func isDirectional(_ style: TransitionStyle) -> Bool {
        [.push, .pushLeft, .pushRight, .pushUp, .pushDown, .slideLeft, .slideRight, .slideUp, .slideDown].contains(style)
    }

    private static func isMotion(_ style: TransitionStyle) -> Bool {
        [.zoom, .zoomIn, .zoomOut, .whipLeft, .whipRight, .whipUp, .whipDown, .spin, .cameraPush, .cameraPull].contains(style)
    }

    private static func gaussianBlur(_ image: CIImage, radius: Double, extent: CGRect) -> CIImage {
        guard radius > 0.001 else { return image.cropped(to: extent) }
        return image.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius]).cropped(to: extent)
    }

    private static func cinematicGrade(_ image: CIImage, contrast: Double, saturation: Double, warmth: Double) -> CIImage {
        image.applyingFilter("CIColorControls", parameters: [
            kCIInputContrastKey: contrast,
            kCIInputSaturationKey: saturation,
            kCIInputBrightnessKey: warmth * 0.04
        ]).applyingFilter("CITemperatureAndTint", parameters: [
            "inputNeutral": CIVector(x: 6_500, y: 0),
            "inputTargetNeutral": CIVector(x: 6_500 + warmth * 1_800, y: 0)
        ])
    }

    private static func tealOrangeGrade(_ image: CIImage, amount: Double, extent: CGRect) -> CIImage {
        let value = min(max(0, amount), 1)
        return image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 1 + value * 0.10, y: value * 0.03, z: -value * 0.04, w: 0),
            "inputGVector": CIVector(x: value * 0.01, y: 1, z: value * 0.04, w: 0),
            "inputBVector": CIVector(x: -value * 0.05, y: value * 0.07, z: 1 + value * 0.10, w: 0),
            "inputBiasVector": CIVector(x: value * 0.018, y: 0, z: value * 0.012, w: 0)
        ]).cropped(to: extent)
    }

    private static func letterboxed(_ image: CIImage, amount: Double, extent: CGRect) -> CIImage {
        let height = min(extent.height * 0.24, max(0, extent.height * amount))
        guard height > 0.5 else { return image.cropped(to: extent) }
        let black = CIImage(color: .black)
        let lower = black.cropped(to: CGRect(x: extent.minX, y: extent.minY, width: extent.width, height: height))
        let upper = black.cropped(to: CGRect(x: extent.minX, y: extent.maxY - height, width: extent.width, height: height))
        return upper.composited(over: lower.composited(over: image)).cropped(to: extent)
    }

    private static func animatedCrop(_ effect: EffectTimelineItem, image: CIImage, timelineTime: Double, extent: CGRect) -> CIImage {
        let x = min(max(0, effect.parameterValue("cropX", at: timelineTime)), 0.95)
        let y = min(max(0, effect.parameterValue("cropY", at: timelineTime)), 0.95)
        let width = min(max(0.05, effect.parameterValue("cropWidth", at: timelineTime)), 1 - x)
        let height = min(max(0.05, effect.parameterValue("cropHeight", at: timelineTime)), 1 - y)
        guard x > 0.000_001 || y > 0.000_001 || width < 0.999_999 || height < 0.999_999 else {
            return image.cropped(to: extent)
        }
        let crop = CGRect(
            x: extent.minX + extent.width * x,
            y: extent.minY + extent.height * y,
            width: extent.width * width,
            height: extent.height * height
        )
        return image.cropped(to: crop)
            .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
            .transformed(by: CGAffineTransform(scaleX: extent.width / crop.width, y: extent.height / crop.height))
            .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
            .cropped(to: extent)
    }

    private static func rgbSplit(_ image: CIImage, amount: Double, extent: CGRect) -> CIImage {
        let offset = max(0.5, amount * extent.width * 0.018)
        let red = image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 1, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0)
        ]).transformed(by: CGAffineTransform(translationX: offset, y: 0))
        let cyan = image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 1, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 1, w: 0)
        ]).transformed(by: CGAffineTransform(translationX: -offset, y: 0))
        return red.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: cyan]).cropped(to: extent)
    }

    private static func grain(over image: CIImage, amount: Double, dust: Bool, extent: CGRect) -> CIImage {
        guard let noise = CIFilter(name: "CIRandomGenerator")?.outputImage?.cropped(to: extent) else { return image }
        var texture = noise.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0, kCIInputContrastKey: dust ? 4.2 : 1.35])
        if dust {
            texture = texture.applyingFilter("CIPixellate", parameters: [kCIInputScaleKey: 1.8 + amount * 4])
        }
        texture = texture.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: amount)])
        return texture.applyingFilter("CISoftLightBlendMode", parameters: [kCIInputBackgroundImageKey: image]).cropped(to: extent)
    }

    private static func scanlines(over image: CIImage, amount: Double, scale: Double, extent: CGRect) -> CIImage {
        guard let filter = CIFilter(name: "CIStripesGenerator") else { return image }
        filter.setValue(CIVector(x: 0, y: 0), forKey: kCIInputCenterKey)
        filter.setValue(CIColor(red: 0, green: 0, blue: 0, alpha: amount * 0.38), forKey: "inputColor0")
        filter.setValue(CIColor.clear, forKey: "inputColor1")
        filter.setValue(max(1, scale * 0.35), forKey: "inputWidth")
        filter.setValue(0.45, forKey: "inputSharpness")
        let stripes = (filter.outputImage ?? CIImage.empty()).transformed(by: CGAffineTransform(rotationAngle: .pi / 2)).cropped(to: extent)
        return stripes.composited(over: image).cropped(to: extent)
    }

    private static func warmLightOverlay(extent: CGRect, progress: Double, amount: Double, burn: Bool) -> CIImage {
        guard let filter = CIFilter(name: "CIRadialGradient") else { return CIImage.empty() }
        let centerX = extent.minX + extent.width * (0.12 + progress * 0.76)
        filter.setValue(CIVector(x: centerX, y: extent.midY), forKey: "inputCenter")
        filter.setValue(0, forKey: "inputRadius0")
        filter.setValue(max(extent.width, extent.height) * 0.78, forKey: "inputRadius1")
        filter.setValue(CIColor(red: 1, green: burn ? 0.18 : 0.48, blue: burn ? 0.02 : 0.12, alpha: amount * (burn ? 0.88 : 0.66)), forKey: "inputColor0")
        filter.setValue(CIColor(red: 0.38, green: 0.03, blue: 0, alpha: 0), forKey: "inputColor1")
        return (filter.outputImage ?? CIImage.empty()).cropped(to: extent)
    }

    private static func colorForHue(_ value: Double) -> CIColor {
        let h = min(max(0, value), 1) * 6
        let x = 1 - abs(h.truncatingRemainder(dividingBy: 2) - 1)
        let rgb: (Double, Double, Double)
        switch h {
        case 0..<1: rgb = (1, x, 0)
        case 1..<2: rgb = (x, 1, 0)
        case 2..<3: rgb = (0, 1, x)
        case 3..<4: rgb = (0, x, 1)
        case 4..<5: rgb = (x, 0, 1)
        default: rgb = (1, 0, x)
        }
        return CIColor(red: rgb.0 * 0.32, green: rgb.1 * 0.32, blue: rgb.2 * 0.32, alpha: 1)
    }

    private static func withOpacity(_ image: CIImage, _ opacity: Double) -> CIImage {
        guard opacity < 0.999 else { return image }
        return image.applyingFilter("CIColorMatrix", parameters: [
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: min(max(0, opacity), 1))
        ])
    }

    private static func localProgress(_ effect: EffectTimelineItem, timelineTime: Double) -> Double {
        min(max(0, (timelineTime - effect.startTime) / max(0.000_001, effect.duration)), 1)
    }

    private static func smooth(_ value: Double) -> Double {
        value * value * (3 - 2 * value)
    }

    private static func centeredScale(_ scale: Double, bounds: CGRect) -> CGAffineTransform {
        CGAffineTransform(translationX: bounds.midX, y: bounds.midY)
            .scaledBy(x: scale, y: scale)
            .translatedBy(x: -bounds.midX, y: -bounds.midY)
    }

    private static func centeredTransform(
        _ base: CGAffineTransform,
        anchorX: Double,
        anchorY: Double,
        scaleX: CGFloat,
        scaleY: CGFloat,
        rotation: CGFloat,
        x: CGFloat,
        y: CGFloat,
        renderSize: CGSize
    ) -> CGAffineTransform {
        let anchor = CGPoint(
            x: renderSize.width * CGFloat(min(max(0, anchorX), 1)),
            y: renderSize.height * CGFloat(min(max(0, anchorY), 1))
        )
        return base.concatenating(
            CGAffineTransform(translationX: anchor.x + x, y: anchor.y + y)
                .rotated(by: rotation)
                .scaledBy(x: max(0.01, scaleX), y: max(0.01, scaleY))
                .translatedBy(x: -anchor.x, y: -anchor.y)
        )
    }

    private static func zoomed(_ base: CGAffineTransform, scale: CGFloat, renderSize: CGSize) -> CGAffineTransform {
        base.concatenating(
            CGAffineTransform(translationX: renderSize.width / 2, y: renderSize.height / 2)
                .scaledBy(x: scale, y: scale)
                .translatedBy(x: -renderSize.width / 2, y: -renderSize.height / 2)
        )
    }
}

private final class TransitionEffectPreviewCache: @unchecked Sendable {
    private let cache = NSCache<NSString, CGImageBox>()

    func image(for key: String) -> CGImage? {
        cache.object(forKey: key as NSString)?.image
    }

    func store(_ image: CGImage, for key: String) {
        cache.setObject(CGImageBox(image), forKey: key as NSString)
    }
}

private final class CGImageBox {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
}
