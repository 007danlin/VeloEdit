import Foundation
import CoreGraphics
import CoreImage
import CoreText

/// The single title renderer used by Library preview, Timeline playback and
/// video export. Template definitions contain composition and motion data;
/// this renderer has no template-ID-specific drawing branches.
public enum TitleOverlayRenderer {
    private static let previewCIContext = CIContext(options: [.cacheIntermediates: true])

    static func image(item: TitleTimelineItem, timelineTime: Double, renderSize: CGSize) -> CIImage? {
        guard let frame = renderedFrame(item: item, timelineTime: timelineTime, renderSize: renderSize) else { return nil }
        var result = CIImage(cgImage: frame.image)
        if frame.maximumBlur > 0.01 {
            result = result.clampedToExtent()
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: min(30, frame.maximumBlur)])
                .cropped(to: frame.bounds)
        }
        return result.cropped(to: frame.bounds)
    }

    static func cgImage(item: TitleTimelineItem, timelineTime: Double, renderSize: CGSize) -> CGImage? {
        guard let frame = renderedFrame(item: item, timelineTime: timelineTime, renderSize: renderSize) else { return nil }
        guard frame.maximumBlur > 0.01 else { return frame.image }
        let blurred = CIImage(cgImage: frame.image)
            .clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: min(30, frame.maximumBlur)])
            .cropped(to: frame.bounds)
        return previewCIContext.createCGImage(blurred, from: frame.bounds) ?? frame.image
    }

    public static func previewCGImage(template: TitleTemplateDefinition, time: Double, renderSize: CGSize) -> CGImage? {
        let item = template.previewItem()
        return cgImage(item: item, timelineTime: min(max(0, time), item.duration), renderSize: renderSize)
    }

    private struct RenderedFrame {
        var image: CGImage
        var bounds: CGRect
        var maximumBlur: CGFloat
    }

    private static func renderedFrame(
        item: TitleTimelineItem,
        timelineTime: Double,
        renderSize: CGSize
    ) -> RenderedFrame? {
        guard item.enabled,
              timelineTime >= item.startTime,
              timelineTime <= item.endTime,
              renderSize.width >= 1,
              renderSize.height >= 1,
              let template = TitleTemplateRegistry.template(for: item) else { return nil }

        let width = Int(renderSize.width.rounded())
        let height = Int(renderSize.height.rounded())
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        let bounds = CGRect(origin: .zero, size: renderSize)
        let safeRect = template.safeArea.rect(in: renderSize)
        let localTime = timelineTime - item.startTime
        let defaultStyle = template.defaultStyle
        let groupDX = safeRect.width * CGFloat(item.style.effectiveXPosition - defaultStyle.effectiveXPosition)
        let groupDY = -safeRect.height * CGFloat(item.style.effectiveYPosition - defaultStyle.effectiveYPosition)
        let groupScale = CGFloat(item.style.effectiveScale / max(0.01, defaultStyle.effectiveScale))
        let groupRotation = CGFloat(item.style.effectiveRotation * .pi / 180)
        var maximumBlur = CGFloat(item.style.blur ?? 0)

        context.clear(bounds)
        for element in template.layout.elements {
            guard let resolved = resolvedContent(for: element, item: item) else { continue }
            let container = element.followsSafeArea ? safeRect : bounds
            var rect = element.frame.rect(in: container).offsetBy(dx: groupDX, dy: groupDY)
            guard rect.width > 0.5, rect.height > 0.5 else { continue }
            let motion = motionState(
                animation: template.animation,
                elementIndex: element.staggerIndex,
                localTime: localTime,
                itemDuration: item.duration,
                renderSize: renderSize
            )
            maximumBlur = max(maximumBlur, motion.blur)
            rect = rect.offsetBy(dx: motion.offset.width, dy: motion.offset.height)

            context.saveGState()
            if element.reveal != .none {
                let progress = CGFloat(min(max(0, motion.reveal), 1))
                let revealRect: CGRect
                switch element.reveal {
                case .none:
                    revealRect = rect
                case .horizontal:
                    revealRect = CGRect(x: rect.minX, y: rect.minY, width: rect.width * progress, height: rect.height)
                case .vertical:
                    revealRect = CGRect(x: rect.minX, y: rect.maxY - rect.height * progress, width: rect.width, height: rect.height * progress)
                }
                context.clip(to: revealRect)
            }
            context.translateBy(x: rect.midX, y: rect.midY)
            context.rotate(by: groupRotation + motion.rotation)
            let scale = max(0.05, groupScale * motion.scale)
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: -rect.midX, y: -rect.midY)
            let elementOpacity = element.strokeColorHex != nil && element.opacity <= 0.001 ? 1 : element.opacity
            context.setAlpha(CGFloat(elementOpacity * motion.opacity))
            draw(
                element: element,
                resolvedContent: resolved,
                in: rect,
                item: item,
                template: template,
                timelineTime: timelineTime,
                context: context,
                renderSize: renderSize
            )
            context.restoreGState()
        }

        guard let cgImage = context.makeImage() else { return nil }
        return RenderedFrame(image: cgImage, bounds: bounds, maximumBlur: maximumBlur)
    }

    private enum ResolvedContent {
        case shape
        case text(String)
    }

    private static func resolvedContent(for element: TitleTemplateElement, item: TitleTimelineItem) -> ResolvedContent? {
        if element.kind != .text { return .shape }
        let value: String?
        switch element.content {
        case .none: value = element.fixedText
        case .primaryText, .activeCaption: value = item.text
        case .secondaryText: value = item.additionalText
        case .callToAction: value = item.callToAction
        }
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return .text(element.uppercase ? value.uppercased() : value)
    }

    private static func draw(
        element: TitleTemplateElement,
        resolvedContent: ResolvedContent,
        in rect: CGRect,
        item: TitleTimelineItem,
        template: TitleTemplateDefinition,
        timelineTime: Double,
        context: CGContext,
        renderSize: CGSize
    ) {
        switch resolvedContent {
        case .shape:
            drawShape(element, in: rect, context: context, renderSize: renderSize)
        case .text(let value):
            drawText(value, element: element, in: rect, item: item, template: template, timelineTime: timelineTime, context: context, renderSize: renderSize)
        }
    }

    private static func drawShape(_ element: TitleTemplateElement, in rect: CGRect, context: CGContext, renderSize: CGSize) {
        let scale = min(renderSize.width, renderSize.height) / 1080
        let fill = color(element.fillColorHex, alpha: 1)
        let stroke = element.strokeColorHex.map { color($0, alpha: 1) }
        let path: CGPath
        switch element.kind {
        case .line:
            context.setStrokeColor(fill)
            context.setLineWidth(max(0.5, CGFloat(element.lineWidth) * scale))
            context.setLineCap(.round)
            context.move(to: CGPoint(x: rect.minX, y: rect.midY))
            context.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            context.strokePath()
            return
        case .circle:
            path = CGPath(ellipseIn: rect, transform: nil)
        case .roundedRectangle:
            let radius = min(rect.width, rect.height) * min(0.5, CGFloat(element.cornerRadius) / 100)
            path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        case .rectangle:
            path = CGPath(rect: rect, transform: nil)
        case .text:
            return
        }
        if element.opacity > 0.001 && colorAlpha(fill) > 0.001 {
            context.addPath(path)
            context.setFillColor(fill)
            context.fillPath()
        }
        if let stroke, element.lineWidth > 0 {
            context.addPath(path)
            context.setStrokeColor(stroke)
            context.setLineWidth(max(0.5, CGFloat(element.lineWidth) * scale))
            context.strokePath()
        }
    }

    private static func drawText(
        _ value: String,
        element: TitleTemplateElement,
        in rect: CGRect,
        item: TitleTimelineItem,
        template: TitleTemplateDefinition,
        timelineTime: Double,
        context: CGContext,
        renderSize: CGSize
    ) {
        let isPrimary = element.content == .primaryText || element.content == .activeCaption
        let base = element.typography ?? template.typography
        let family = isPrimary ? item.style.effectiveFontFamily : base.fontFamily
        let weight = isPrimary ? item.style.effectiveFontWeight : base.fontWeight
        let referenceFontSize = isPrimary ? item.style.fontSize : base.fontSize
        let tracking = isPrimary ? (item.style.tracking ?? base.tracking) : base.tracking
        let lineSpacing = isPrimary ? (item.style.lineSpacing ?? base.lineSpacing) : base.lineSpacing
        let alignment = isPrimary ? item.style.alignment : base.alignment
        let textColor = isPrimary ? item.style.textColorHex : element.fillColorHex
        let shortSideScale = min(renderSize.width, renderSize.height) / 1080
        let lengthScale = value.count > template.textConstraints.maxCharacters
            ? sqrt(Double(template.textConstraints.maxCharacters) / Double(max(1, value.count)))
            : 1
        let desiredSize = CGFloat(referenceFontSize * lengthScale) * shortSideScale
        let minimumSize = max(9 * shortSideScale, desiredSize * CGFloat(template.textConstraints.minFontScale))
        let maximumSize = desiredSize * CGFloat(template.textConstraints.maxFontScale)
        let fitted = fittedText(
            value,
            family: family,
            weight: weight,
            color: color(textColor, alpha: isPrimary ? item.style.effectiveOpacity : 1),
            tracking: CGFloat(tracking) * shortSideScale,
            lineSpacing: lineSpacing,
            alignment: alignment,
            maximumSize: maximumSize,
            minimumSize: minimumSize,
            rect: rect,
            maxLines: template.textConstraints.maxLines,
            strokeWidth: isPrimary ? CGFloat(item.style.strokeWidth ?? 0) : 0,
            activeWord: element.content == .activeCaption && item.activeWordHighlighting ? item.activeWord(at: timelineTime)?.word : nil,
            activeWordColor: color(item.style.activeWordColorHex ?? "#34C759", alpha: item.style.effectiveOpacity)
        )
        guard let fitted else { return }
        if isPrimary, (item.style.shadow ?? 0) > 0.001 {
            context.setShadow(
                offset: CGSize(width: 0, height: -fitted.fontSize * 0.045),
                blur: fitted.fontSize * CGFloat(item.style.shadow ?? 0) * 0.18,
                color: CGColor(gray: 0, alpha: 0.72)
            )
        }
        let path = CGMutablePath()
        path.addRect(rect)
        let framesetter = CTFramesetterCreateWithAttributedString(fitted.text)
        CTFrameDraw(CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: fitted.text.length), path, nil), context)
    }

    private struct FittedText {
        var text: NSMutableAttributedString
        var fontSize: CGFloat
    }

    private static func fittedText(
        _ value: String,
        family: String,
        weight: Double,
        color textColor: CGColor,
        tracking: CGFloat,
        lineSpacing: Double,
        alignment: TitleAlignment,
        maximumSize: CGFloat,
        minimumSize: CGFloat,
        rect: CGRect,
        maxLines: Int,
        strokeWidth: CGFloat,
        activeWord: String?,
        activeWordColor: CGColor
    ) -> FittedText? {
        guard rect.width > 1, rect.height > 1 else { return nil }
        var size = max(minimumSize, maximumSize)
        var last: FittedText?
        while size >= minimumSize - 0.1 {
            let font = resolvedFont(family: family, size: size, weight: weight, text: value)
            let paragraph = paragraphStyle(alignment: alignment, lineSpacing: lineSpacing)
            let text = NSMutableAttributedString(string: value)
            let range = NSRange(location: 0, length: text.length)
            text.addAttributes([
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): textColor,
                NSAttributedString.Key(kCTParagraphStyleAttributeName as String): paragraph,
                NSAttributedString.Key(kCTKernAttributeName as String): tracking
            ], range: range)
            if strokeWidth > 0.001 {
                text.addAttributes([
                    NSAttributedString.Key(kCTStrokeWidthAttributeName as String): -strokeWidth,
                    NSAttributedString.Key(kCTStrokeColorAttributeName as String): CGColor(gray: 0, alpha: 0.88)
                ], range: range)
            }
            if let activeWord { highlight(activeWord, in: text, color: activeWordColor) }
            last = FittedText(text: text, fontSize: size)
            let framesetter = CTFramesetterCreateWithAttributedString(text)
            let suggested = CTFramesetterSuggestFrameSizeWithConstraints(
                framesetter,
                CFRange(location: 0, length: text.length),
                nil,
                CGSize(width: rect.width, height: .greatestFiniteMagnitude),
                nil
            )
            let lineCount = numberOfLines(text: text, width: rect.width)
            if suggested.width <= rect.width + 0.5, suggested.height <= rect.height + 0.5, lineCount <= maxLines {
                return last
            }
            size *= 0.91
        }
        return last
    }

    private static func numberOfLines(text: NSAttributedString, width: CGFloat) -> Int {
        let typesetter = CTTypesetterCreateWithAttributedString(text)
        var location = 0
        var lines = 0
        while location < text.length, lines < 100 {
            let count = CTTypesetterSuggestLineBreak(typesetter, location, Double(max(1, width)))
            guard count > 0 else { break }
            location += count
            lines += 1
        }
        return max(1, lines)
    }

    private static func resolvedFont(family: String, size: CGFloat, weight: Double, text: String) -> CTFont {
        let candidates = [family, "Avenir Next", "Helvetica Neue", "Arial"]
        for candidate in candidates {
            let base = CTFontCreateWithName(candidate as CFString, max(1, size), nil)
            let desired: CTFontSymbolicTraits = weight >= 0.72 ? .traitBold : []
            let font = CTFontCreateCopyWithSymbolicTraits(base, max(1, size), nil, desired, desired) ?? base
            if fontSupports(font, text: text) { return font }
        }
        return CTFontCreateWithName("Helvetica Neue" as CFString, max(1, size), nil)
    }

    private static func fontSupports(_ font: CTFont, text: String) -> Bool {
        var characters = Array(text.utf16)
        guard !characters.isEmpty else { return true }
        var glyphs = Array(repeating: CGGlyph(), count: characters.count)
        return CTFontGetGlyphsForCharacters(font, &characters, &glyphs, characters.count)
    }

    private static func paragraphStyle(alignment: TitleAlignment, lineSpacing: Double) -> CTParagraphStyle {
        var ctAlignment: CTTextAlignment = alignment == .left ? .left : alignment == .right ? .right : .center
        var multiple = CGFloat(min(max(0.5, lineSpacing), 3))
        return withUnsafePointer(to: &ctAlignment) { alignmentPointer in
            withUnsafePointer(to: &multiple) { multiplePointer in
                var settings = [
                    CTParagraphStyleSetting(spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size, value: alignmentPointer),
                    CTParagraphStyleSetting(spec: .lineHeightMultiple, valueSize: MemoryLayout<CGFloat>.size, value: multiplePointer)
                ]
                return CTParagraphStyleCreate(&settings, settings.count)
            }
        }
    }

    private struct MotionState {
        var opacity: Double
        var scale: CGFloat
        var rotation: CGFloat
        var offset: CGSize
        var blur: CGFloat
        var reveal: Double
    }

    private static func motionState(
        animation: TitleTemplateAnimation,
        elementIndex: Int,
        localTime: Double,
        itemDuration: Double,
        renderSize: CGSize
    ) -> MotionState {
        let entrance = animation.animationIn
        let exit = animation.animationOut
        let inDelay = Double(elementIndex) * entrance.stagger
        let outDelay = Double(elementIndex) * exit.stagger
        let inLinear = min(max(0, (localTime - inDelay) / max(0.001, entrance.duration)), 1)
        let remaining = max(0, itemDuration - localTime)
        let outLinear = remaining >= exit.duration + outDelay
            ? 1
            : min(max(0, (remaining - outDelay) / max(0.001, exit.duration)), 1)
        let inProgress = entrance.easing.transform(inLinear)
        let outProgress = exit.easing.transform(outLinear)

        var opacity = interpolate(entrance.opacityFrom, 1, inProgress) * interpolate(exit.opacityFrom, 1, outProgress)
        var scale = interpolate(entrance.scaleFrom, 1, inProgress) * interpolate(exit.scaleFrom, 1, outProgress)
        var rotation = interpolate(entrance.rotationFrom, 0, inProgress) + interpolate(exit.rotationFrom, 0, outProgress)
        var x = interpolate(entrance.translateX, 0, inProgress) + interpolate(exit.translateX, 0, outProgress)
        var y = interpolate(entrance.translateY, 0, inProgress) + interpolate(exit.translateY, 0, outProgress)
        let blur = max(interpolate(entrance.blurFrom, 0, inProgress), interpolate(exit.blurFrom, 0, outProgress))

        let hold = animation.animationHold
        if inLinear >= 1, outLinear >= 1, hold.cycles > 0 {
            let usable = max(0.001, itemDuration - entrance.duration - exit.duration)
            let holdProgress = min(max(0, (localTime - entrance.duration) / usable), 1)
            let wave = sin(holdProgress * .pi * 2 * hold.cycles)
            x += hold.translateX * wave
            y += hold.translateY * wave
            scale *= 1 + hold.scaleAmplitude * wave
            rotation += hold.rotationAmplitude * wave
        }
        opacity = min(max(0, opacity), 1)
        scale = min(max(0.05, scale), 4)
        return MotionState(
            opacity: opacity,
            scale: CGFloat(scale),
            rotation: CGFloat(rotation * .pi / 180),
            offset: CGSize(width: renderSize.width * CGFloat(x), height: -renderSize.height * CGFloat(y)),
            blur: CGFloat(min(max(0, blur), 30)),
            reveal: min(inProgress, outProgress)
        )
    }

    private static func interpolate(_ from: Double, _ to: Double, _ progress: Double) -> Double {
        from + (to - from) * min(max(0, progress), 1)
    }

    private static func highlight(_ word: String, in text: NSMutableAttributedString, color: CGColor) {
        let value = text.string as NSString
        let range = value.range(of: word, options: [.caseInsensitive])
        guard range.location != NSNotFound else { return }
        text.addAttribute(NSAttributedString.Key(kCTForegroundColorAttributeName as String), value: color, range: range)
    }

    private static func color(_ hex: String, alpha: Double) -> CGColor {
        let value = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard value.count == 6, let number = Int(value, radix: 16) else { return CGColor(gray: 1, alpha: alpha) }
        return CGColor(
            red: CGFloat((number >> 16) & 0xFF) / 255,
            green: CGFloat((number >> 8) & 0xFF) / 255,
            blue: CGFloat(number & 0xFF) / 255,
            alpha: CGFloat(min(max(0, alpha), 1))
        )
    }

    private static func colorAlpha(_ color: CGColor) -> CGFloat {
        color.alpha
    }
}
