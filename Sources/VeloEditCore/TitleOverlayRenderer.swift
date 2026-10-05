import Foundation
import CoreGraphics
import CoreImage
import CoreText

/// The single title renderer used by Library preview, Timeline playback and
/// video export. Template definitions contain composition and motion data;
/// this renderer has no template-ID-specific drawing branches.
public enum TitleOverlayRenderer {
    private static let previewCIContext = CIContext(options: [.cacheIntermediates: true])

    /// Video-aware path shared by playback and export. Library thumbnails have
    /// no source frame and continue to render the unmodified template artwork.
    static func composited(
        item: TitleTimelineItem, timelineTime: Double, renderSize: CGSize,
        over background: CIImage, adaptation: AdaptiveTitleBackgroundRenderer,
        overlayOnly: Bool = false
    ) -> CIImage {
        guard let frame = renderedFrame(item: item, timelineTime: timelineTime,
                                        renderSize: renderSize, collectReadability: true) else {
            return overlayOnly ? CIImage.empty() : background
        }
        let analysis = adaptation.process(
            background: background, artwork: frame.artwork.map { CIImage(cgImage: $0) },
            regions: frame.regions, item: item, time: timelineTime, bounds: frame.bounds
        )
        let protectedFrame = analysis.treatments.isEmpty ? frame :
            (renderedFrame(item: item, timelineTime: timelineTime, renderSize: renderSize,
                           treatments: analysis.treatments) ?? frame)
        var overlay = CIImage(cgImage: protectedFrame.image)
        if protectedFrame.maximumBlur > 0.01 {
            overlay = overlay.clampedToExtent()
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: min(30, protectedFrame.maximumBlur)])
                .cropped(to: frame.bounds)
        }
        return overlay.composited(over: overlayOnly ? analysis.backgroundOverlay : analysis.image).cropped(to: frame.bounds)
    }

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

    public static func cgImage(item: TitleTimelineItem, timelineTime: Double, renderSize: CGSize) -> CGImage? {
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

    /// Uses the very same Core Text fitting and transformed glyph bounds as
    /// playback/export, allowing visual QA to detect lost text and collisions.
    static func textLayout(item: TitleTimelineItem, timelineTime: Double, renderSize: CGSize) -> [TitleReadabilityRegion] {
        renderedFrame(item: item, timelineTime: timelineTime, renderSize: renderSize, collectReadability: true)?.regions ?? []
    }

    public struct TextSizing: Sendable {
        /// Font size in the same reference units as the inspector.
        public let fontSize: Double
        public let lineCount: Int
        public let isReduced: Bool
        public let isTruncated: Bool
    }

    /// Measure with the same fitter as playback, without rendering a bitmap
    /// on each inspector update. Fitting limits must be visible to the editor.
    public static func textSizing(item: TitleTimelineItem, renderSize: CGSize) -> TextSizing? {
        guard let template = TitleTemplateRegistry.template(for: item),
              let element = template.layout.elements.first(where: { $0.content == .primaryText || $0.content == .activeCaption }),
              case .text(let value) = resolvedContent(for: element, item: item) else { return nil }
        let layout = AdaptiveTitleLayout.resolve(template: template, renderSize: renderSize, item: item)
        guard let geometry = layout.element(id: element.id),
              let fitted = fittedText(value, element: element, rect: geometry.frame, item: item,
                                      template: template, timelineTime: item.startTime,
                                      typographyScale: layout.typographyScale,
                                      portraitInfluence: layout.geometry.portraitInfluence,
                                      maximumLines: geometry.maximumLines) else { return nil }
        let ratio = fitted.fontSize / max(0.001, fitted.requestedFontSize)
        return TextSizing(fontSize: item.style.fontSize * Double(ratio),
                          lineCount: numberOfLines(text: fitted.text, width: geometry.frame.width),
                          isReduced: ratio < 0.99,
                          isTruncated: fitted.text.string.contains("…") && !value.contains("…"))
    }

    private struct RenderedFrame {
        var image: CGImage
        var bounds: CGRect
        var maximumBlur: CGFloat
        var artwork: CGImage?
        var regions: [TitleReadabilityRegion]
    }

    private static func renderedFrame(
        item: TitleTimelineItem,
        timelineTime: Double,
        renderSize: CGSize,
        collectReadability: Bool = false,
        treatments: [String: TitleBackgroundTreatment] = [:]
    ) -> RenderedFrame? {
        guard item.enabled,
              timelineTime >= item.startTime,
              timelineTime < item.endTime,
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
        let adaptiveLayout = AdaptiveTitleLayout.resolve(template: template, renderSize: renderSize, item: item)
        let safeRect = adaptiveLayout.safeRect
        let localTime = timelineTime - item.startTime
        let templateMotion = template.animationFitted(to: item.duration)
        let defaultStyle = template.defaultStyle
        let groupDX = safeRect.width * CGFloat(item.style.effectiveXPosition - defaultStyle.effectiveXPosition)
        let groupDY = -safeRect.height * CGFloat(item.style.effectiveYPosition - defaultStyle.effectiveYPosition)
        let groupScale = CGFloat(item.style.effectiveScale / max(0.01, defaultStyle.effectiveScale))
        let groupRotation = CGFloat(item.style.effectiveRotation * .pi / 180)
        var maximumBlur = CGFloat(item.style.blur ?? 0)
        var regions: [TitleReadabilityRegion] = []
        let artworkContext = collectReadability ? CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) : nil

        context.clear(bounds)
        // Opacity belongs to the complete title, including secondary text,
        // artwork and readability outlines. A transparency group avoids
        // multiplying alpha where those elements overlap.
        context.setAlpha(CGFloat(item.style.effectiveOpacity))
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        artworkContext?.setAlpha(CGFloat(item.style.effectiveOpacity))
        artworkContext?.beginTransparencyLayer(auxiliaryInfo: nil)
        for element in template.layout.elements {
            guard let resolved = resolvedContent(for: element, item: item) else { continue }
            guard let layoutElement = adaptiveLayout.element(id: element.id) else { continue }
            var rect = layoutElement.frame.offsetBy(dx: groupDX, dy: groupDY)
            guard rect.width > 0.5, rect.height > 0.5 else { continue }
            let motion = motionState(
                animation: templateMotion,
                elementIndex: element.staggerIndex,
                localTime: localTime,
                itemDuration: item.duration,
                renderSize: renderSize,
                immediateEntrance: item.animation.entrance == .none,
                immediateExit: item.animation.exit == .none
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
            // Mirror only template artwork, so a designed panel is included in
            // the contrast analysis but the letters cannot mask their own background.
            if element.kind != .text, let artworkContext {
                artworkContext.saveGState()
                artworkContext.concatenate(context.ctm)
                artworkContext.setAlpha(CGFloat(elementOpacity * motion.opacity))
                if element.reveal != .none {
                    // The active context already contains the animated reveal clip.
                    artworkContext.clip(to: context.boundingBoxOfClipPath)
                }
                drawShape(element, in: rect, context: artworkContext, renderSize: renderSize)
                artworkContext.restoreGState()
            }
            if let region = draw(
                element: element,
                resolvedContent: resolved,
                in: rect,
                item: item,
                template: template,
                timelineTime: timelineTime,
                context: context,
                renderSize: renderSize,
                typographyScale: adaptiveLayout.typographyScale,
                portraitInfluence: adaptiveLayout.geometry.portraitInfluence,
                maximumLines: layoutElement.maximumLines,
                collectReadability: collectReadability,
                treatment: treatments[element.id]
            ) {
                var visibleRegion = region
                visibleRegion.visibility = motion.opacity * elementOpacity * item.style.effectiveOpacity
                regions.append(visibleRegion)
            }
            context.restoreGState()
        }
        context.endTransparencyLayer()
        artworkContext?.endTransparencyLayer()

        guard let cgImage = context.makeImage() else { return nil }
        return RenderedFrame(image: cgImage, bounds: bounds, maximumBlur: maximumBlur,
                             artwork: artworkContext?.makeImage(), regions: regions)
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
        case .chapterNumber: value = item.formattedChapterNumber
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
        renderSize: CGSize,
        typographyScale: CGFloat,
        portraitInfluence: Double,
        maximumLines: Int,
        collectReadability: Bool,
        treatment: TitleBackgroundTreatment?
    ) -> TitleReadabilityRegion? {
        switch resolvedContent {
        case .shape:
            drawShape(element, in: rect, context: context, renderSize: renderSize)
            return nil
        case .text(let value):
            return drawText(
                value,
                element: element,
                in: rect,
                item: item,
                template: template,
                timelineTime: timelineTime,
                context: context,
                typographyScale: typographyScale,
                portraitInfluence: portraitInfluence,
                maximumLines: maximumLines,
                collectReadability: collectReadability,
                treatment: treatment
            )
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
        typographyScale: CGFloat,
        portraitInfluence: Double,
        maximumLines: Int,
        collectReadability: Bool,
        treatment: TitleBackgroundTreatment?
    ) -> TitleReadabilityRegion? {
        let isPrimary = element.content == .primaryText || element.content == .activeCaption
        guard let fitted = fittedText(value, element: element, rect: rect, item: item,
                                      template: template, timelineTime: timelineTime,
                                      typographyScale: typographyScale, portraitInfluence: portraitInfluence,
                                      maximumLines: maximumLines) else { return nil }
        if isPrimary, (item.style.shadow ?? 0) > 0.001 {
            context.setShadow(
                offset: CGSize(width: 0, height: -fitted.fontSize * 0.045),
                blur: fitted.fontSize * CGFloat(item.style.shadow ?? 0) * 0.18,
                color: CGColor(gray: 0, alpha: 0.72)
            )
        }
        var edgeText: NSMutableAttributedString?
        if let treatment, treatment.edgeOpacity > 0.001 {
            let supportStrokeWidth = max(8, treatment.strokeWidth)
            let edgeColor = CGColor(gray: treatment.lightSupport ? 1 : 0, alpha: treatment.edgeOpacity)
            context.setShadow(offset: CGSize(width: 0, height: -fitted.fontSize * 0.025),
                              blur: fitted.fontSize * 0.035, color: edgeColor)
            // Core Text specifies stroke as a percentage of the actual font size.
            // Preserve a deliberately stronger user stroke.
            if !isPrimary || (item.style.strokeWidth ?? 0) < supportStrokeWidth {
                let outlined = NSMutableAttributedString(attributedString: fitted.text)
                outlined.addAttributes([
                    // A monochrome support silhouette gives the shadow a solid
                    // source. It contains no duplicate of the text's own fill.
                    NSAttributedString.Key(kCTForegroundColorAttributeName as String): edgeColor,
                    // Core Text strokes straddle the glyph edge; the final
                    // fill covers their inner half. Keep the surviving edge
                    // visible at phone size, including white text on white sky.
                    NSAttributedString.Key(kCTStrokeWidthAttributeName as String): -supportStrokeWidth,
                    NSAttributedString.Key(kCTStrokeColorAttributeName as String): edgeColor
                ], range: NSRange(location: 0, length: fitted.text.length))
                edgeText = outlined
            }
        }
        let path = CGMutablePath()
        path.addRect(textFlowRect(rect, glyphFitting: isPrimary))
        let framesetter = CTFramesetterCreateWithAttributedString(fitted.text)
        let textFrame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: fitted.text.length), path, nil)
        let lines = CTFrameGetLines(textFrame) as! [CTLine]
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(textFrame, CFRange(location: 0, length: 0), &origins)
        let glyphRects = zip(lines, origins).map { line, origin in
            CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds])
                .offsetBy(dx: path.boundingBox.minX + origin.x, dy: path.boundingBox.minY + origin.y)
        }
        // Center headings in their reserved text area in every format, so a
        // short line does not sit against the top of an otherwise empty panel.
        let glyphBounds = glyphRects.reduce(CGRect.null) { $0.union($1) }
        if !glyphBounds.isNull {
            context.translateBy(x: 0, y: (rect.midY - glyphBounds.midY) * (isPrimary ? 1 : CGFloat(portraitInfluence)))
        }
        if let edgeText {
            context.saveGState()
            let edgeSetter = CTFramesetterCreateWithAttributedString(edgeText)
            CTFrameDraw(CTFramesetterCreateFrame(edgeSetter, CFRange(location: 0, length: edgeText.length), path, nil), context)
            context.restoreGState()
            context.setShadow(offset: .zero, blur: 0, color: nil)
        }
        // Restore the original fill over the inner half of the outline. This is
        // especially important for thin serif strokes at preview resolution.
        context.setTextDrawingMode(.fill)
        CTFrameDraw(textFrame, context)
        guard collectReadability else { return nil }
        let lineRects = glyphRects.map {
            $0.applying(context.ctm).standardized
        }.filter { $0.width > 0 && $0.height > 0 }
        let transformScale = hypot(context.ctm.a, context.ctm.b)
        var luminances: [Double] = []
        fitted.text.enumerateAttribute(NSAttributedString.Key(kCTForegroundColorAttributeName as String),
                                       in: NSRange(location: 0, length: fitted.text.length)) { value, _, _ in
            if let value { luminances.append(TitleReadabilityAnalysis.luminance(value as! CGColor)) }
        }
        return TitleReadabilityRegion(elementID: element.id, lineRects: lineRects,
                                      fontSize: Double(fitted.fontSize * transformScale),
                                      textLuminances: Array(Set(luminances)),
                                      textOpacity: 1,
                                      visibility: 1, requestedText: value, renderedText: fitted.text.string)
    }

    private struct FittedText {
        var text: NSAttributedString
        var fontSize: CGFloat
        var requestedFontSize: CGFloat
    }

    private struct FitParameters: Hashable {
        let text: String
        let element: TitleTemplateElement
        let style: TitleStyle
        let template: TitleTemplateDefinition
        let geometry: [Double]
        let maximumLines: Int
        let activeWord: NSRange?
    }

    private final class FitKey: NSObject {
        let parameters: FitParameters
        init(_ parameters: FitParameters) { self.parameters = parameters }
        override var hash: Int { parameters.hashValue }
        override func isEqual(_ object: Any?) -> Bool {
            (object as? FitKey)?.parameters == parameters
        }
    }

    private final class CachedFit {
        let result: FittedText?
        init(_ result: FittedText?) { self.result = result }
    }

    // Layout is independent of animation time except for the active caption
    // word. NSCache is bounded and thread-safe for preview and export workers.
    private static let fittedTextCache: NSCache<FitKey, CachedFit> = {
        let cache = NSCache<FitKey, CachedFit>()
        cache.countLimit = 256
        cache.totalCostLimit = 8 * 1_024 * 1_024
        return cache
    }()

    private static func fittedText(
        _ value: String, element: TitleTemplateElement, rect: CGRect,
        item: TitleTimelineItem, template: TitleTemplateDefinition, timelineTime: Double,
        typographyScale: CGFloat, portraitInfluence: Double, maximumLines: Int
    ) -> FittedText? {
        let isPrimary = element.content == .primaryText || element.content == .activeCaption
        let base = element.typography ?? template.typography
        let baseSize = isPrimary ? item.style.fontSize : base.fontSize
        let portraitSize = element.portraitFontSize ?? base.fontSize
        let referenceSize = baseSize * (1 + (portraitSize / max(1, base.fontSize) - 1) * portraitInfluence)
        let desiredSize = CGFloat(referenceSize) * typographyScale
        let activeWord = element.content == .activeCaption && item.activeWordHighlighting ? item.activeWordRange(at: timelineTime) : nil
        let key = FitKey(FitParameters(text: value, element: element, style: item.style, template: template,
            geometry: [Double(rect.origin.x), Double(rect.origin.y), Double(rect.width), Double(rect.height), Double(typographyScale), portraitInfluence],
            maximumLines: maximumLines, activeWord: activeWord))
        if let cached = fittedTextCache.object(forKey: key) { return cached.result }
        let result = fittedText(value,
            family: isPrimary ? item.style.effectiveFontFamily : base.fontFamily,
            weight: isPrimary ? item.style.effectiveFontWeight : base.fontWeight,
            color: color(isPrimary ? item.style.textColorHex : element.fillColorHex, alpha: 1),
            tracking: CGFloat(isPrimary ? (item.style.tracking ?? base.tracking) : base.tracking) * typographyScale,
            lineSpacing: isPrimary ? (item.style.lineSpacing ?? base.lineSpacing) : base.lineSpacing,
            alignment: isPrimary ? item.style.alignment : base.alignment,
            maximumSize: desiredSize * CGFloat(template.textConstraints.maxFontScale),
            minimumSize: max(9 * typographyScale, desiredSize * CGFloat(template.textConstraints.minFontScale)),
            rect: rect, maxLines: maximumLines, glyphFitting: isPrimary,
            strokeWidth: isPrimary ? CGFloat(item.style.strokeWidth ?? 0) : 0,
            activeWord: activeWord,
            activeWordColor: color(item.style.activeWordColorHex ?? "#34C759", alpha: 1))
        fittedTextCache.setObject(CachedFit(result), forKey: key, cost: max(1, value.utf8.count) * 16 + 1_024)
        return result
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
        glyphFitting: Bool,
        strokeWidth: CGFloat,
        activeWord: NSRange?,
        activeWordColor: CGColor
    ) -> FittedText? {
        guard rect.width > 1, rect.height > 1 else { return nil }
        // Never split a single title word at an arbitrary glyph boundary.
        // Phrases can reflow between words; a long place/name is fitted as one
        // readable line before the bounded truncation fallback is considered.
        let hasBreak = value.rangeOfCharacter(from: .whitespacesAndNewlines) != nil || value.contains("-") || value.contains("–")
        let manualLines = value.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n").count
        let effectiveMaxLines = hasBreak ? max(maxLines, manualLines) : 1
        let candidates = lineBreakCandidates(value, maximumLines: effectiveMaxLines)
        func fit(at size: CGFloat) -> FittedText? {
            for candidate in candidates {
                let text = attributedText(
                    candidate,
                    family: family,
                    size: size,
                    weight: weight,
                    color: textColor,
                    tracking: tracking,
                    lineSpacing: lineSpacing,
                    alignment: alignment,
                    strokeWidth: strokeWidth,
                    activeWord: activeWord,
                    activeWordColor: activeWordColor
                )
                if textFits(text, rect: rect, maxLines: effectiveMaxLines, glyphFitting: glyphFitting) {
                    return FittedText(text: text, fontSize: size, requestedFontSize: maximumSize)
                }
            }
            return nil
        }
        if let exact = fit(at: maximumSize) { return exact }
        if var best = fit(at: minimumSize) {
            // Coarse 9% decrements could make an increased inspector value
            // render *smaller*. Find the largest fitting size continuously.
            var lower = minimumSize
            var upper = maximumSize
            for _ in 0..<14 {
                let middle = (lower + upper) / 2
                if let candidate = fit(at: middle) { best = candidate; lower = middle }
                else { upper = middle }
            }
            return best
        }

        // Extremely long manually entered text is shortened only after all
        // legal reflow and font-size options have been exhausted. This keeps
        // the visible result inside its frame instead of silently clipping it.
        let characters = Array(value.trimmingCharacters(in: .whitespacesAndNewlines))
        func truncatedFit(length: Int) -> FittedText? {
            let shortened = String(characters.prefix(length)).trimmingCharacters(in: .whitespacesAndNewlines)
            for candidate in lineBreakCandidates(shortened + "…", maximumLines: effectiveMaxLines) {
                let text = attributedText(
                    candidate,
                    family: family,
                    size: minimumSize,
                    weight: weight,
                    color: textColor,
                    tracking: tracking,
                    lineSpacing: lineSpacing,
                    alignment: alignment,
                    strokeWidth: strokeWidth,
                    activeWord: activeWord,
                    activeWordColor: activeWordColor
                )
                if textFits(text, rect: rect, maxLines: effectiveMaxLines, glyphFitting: glyphFitting) {
                    return FittedText(text: text, fontSize: minimumSize, requestedFontSize: maximumSize)
                }
            }
            return nil
        }
        // Binary search bounds expensive Core Text measurements for pasted
        // words. Prefer complete words; only shorten a word when none fits.
        func longestFit(_ lengths: [Int]) -> FittedText? {
            var lower = 0, upper = lengths.count - 1
            var best: FittedText?
            while lower <= upper {
                let middle = (lower + upper) / 2
                if let fit = truncatedFit(length: lengths[middle]) {
                    best = fit
                    lower = middle + 1
                } else { upper = middle - 1 }
            }
            return best
        }
        guard characters.count > 1 else { return nil }
        let boundaries = (1..<characters.count).filter { characters[$0].isWhitespace }
        return longestFit(boundaries) ?? longestFit(Array(1..<characters.count))
    }

    private static func attributedText(
        _ value: String,
        family: String,
        size: CGFloat,
        weight: Double,
        color textColor: CGColor,
        tracking: CGFloat,
        lineSpacing: Double,
        alignment: TitleAlignment,
        strokeWidth: CGFloat,
        activeWord: NSRange?,
        activeWordColor: CGColor
    ) -> NSMutableAttributedString {
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
            return text
    }

    private static func textFlowRect(_ rect: CGRect, glyphFitting: Bool) -> CGRect {
        // Headings are centered by their visible glyphs. Leave room for the
        // font's invisible ascender/descender padding while laying out lines;
        // otherwise those metrics shrink letters that would actually fit.
        guard glyphFitting else { return rect }
        let height = rect.height * 4
        return CGRect(x: rect.minX, y: rect.maxY - height, width: rect.width, height: height)
    }

    private static func textFits(_ text: NSAttributedString, rect: CGRect, maxLines: Int, glyphFitting: Bool) -> Bool {
        // Core Text can otherwise split an overwide surname into a separate
        // last letter even when the overall suggested frame size "fits".
        let wordRanges = (try? NSRegularExpression(pattern: #"[^\s\-–]+[\-–]?"#))?
            .matches(in: text.string, range: NSRange(location: 0, length: text.length)).map(\.range) ?? []
        for range in wordRanges {
            let word = text.attributedSubstring(from: range)
            if CTLineGetTypographicBounds(CTLineCreateWithAttributedString(word), nil, nil, nil) > rect.width + 0.5 { return false }
        }
        let framesetter = CTFramesetterCreateWithAttributedString(text)
        let flowRect = textFlowRect(rect, glyphFitting: glyphFitting)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: text.length), CGPath(rect: flowRect, transform: nil), nil)
        let visible = CTFrameGetVisibleStringRange(frame)
        let lines = CTFrameGetLines(frame) as! [CTLine]
        guard visible.length == text.length, lines.count <= maxLines else { return false }
        // At a fractional-width boundary, especially with negative tracking,
        // Core Text may still wrap the last letter despite the width check.
        // Validate the actual breaks, including the hyphen attached to a word.
        for line in lines.dropLast() {
            let range = CTLineGetStringRange(line)
            let end = range.location + range.length
            if wordRanges.contains(where: { end > $0.location && end < NSMaxRange($0) }) { return false }
        }
        if glyphFitting {
            var origins = [CGPoint](repeating: .zero, count: lines.count)
            CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)
            let glyphs = zip(lines, origins).map { line, origin in
                CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds]).offsetBy(dx: origin.x, dy: origin.y)
            }
            let bounds = glyphs.reduce(CGRect.null) { $0.union($1) }
            return !bounds.isNull && bounds.height <= rect.height && bounds.width <= rect.width + 0.5
        }
        let suggested = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter,
            CFRange(location: 0, length: text.length),
            nil,
            CGSize(width: rect.width, height: .greatestFiniteMagnitude),
            nil
        )
        return suggested.width <= rect.width + 0.5
            && suggested.height <= rect.height + 0.5
    }

    private static func lineBreakCandidates(_ value: String, maximumLines: Int) -> [String] {
        let normalized = value.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
            .map { $0.split(whereSeparator: \Character.isWhitespace).map(String.init).joined(separator: " ") }
            .joined(separator: "\n")
        // Explicit paragraphs are authoritative, even in a one-line template.
        // Core Text may still wrap within each paragraph to fit its width.
        if normalized.contains("\n") { return [normalized] }
        guard maximumLines > 1 else { return [normalized] }
        let words = normalized.split(separator: " ").map(String.init)
        guard words.count > 1 else { return [normalized] }
        var result = [normalized]
        for lineCount in 2...min(maximumLines, words.count) {
            var lines: [String] = []
            var cursor = 0
            for line in 0..<lineCount {
                let remainingLines = lineCount - line
                let remainingWords = words.count - cursor
                let take: Int
                if remainingLines == 1 {
                    take = remainingWords
                } else {
                    let remainingCharacters = words[cursor...].reduce(0) { $0 + $1.count + 1 }
                    let target = max(1, remainingCharacters / remainingLines)
                    var count = 1
                    var length = words[cursor].count
                    while count < remainingWords - (remainingLines - 1) {
                        let nextLength = length + 1 + words[cursor + count].count
                        if nextLength > target, count > 0 { break }
                        count += 1
                        length = nextLength
                    }
                    take = count
                }
                lines.append(words[cursor..<(cursor + take)].joined(separator: " "))
                cursor += take
            }
            let candidate = lines.joined(separator: "\n")
            if !result.contains(candidate) { result.append(candidate) }
        }
        return result
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
        // Line separators have no printable glyph and must not trigger a
        // fallback font when the user inserts a newline.
        var characters = Array(text.filter { !$0.isNewline && $0 != "\t" }.utf16)
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
        renderSize: CGSize,
        immediateEntrance: Bool = false,
        immediateExit: Bool = false
    ) -> MotionState {
        let entrance = animation.animationIn
        let exit = animation.animationOut
        let inDelay = Double(elementIndex) * entrance.stagger
        let outDelay = Double(elementIndex) * exit.stagger
        let inLinear = immediateEntrance ? 1 : min(max(0, (localTime - inDelay) / max(0.001, entrance.duration)), 1)
        let remaining = max(0, itemDuration - localTime)
        let outLinear = immediateExit || remaining >= exit.duration + outDelay
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

    private static func highlight(_ range: NSRange, in text: NSMutableAttributedString, color: CGColor) {
        guard range.location != NSNotFound, NSMaxRange(range) <= text.length else { return }
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
