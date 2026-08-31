import Foundation
import CoreGraphics

// MARK: - Data-driven professional title templates

public enum TitleTemplateCategory: String, Codable, CaseIterable, Identifiable, Sendable {
    case mainTitles = "main-titles"
    case chapterTitles = "chapter-titles"
    case locationTitles = "location-titles"
    case dateTime = "date-time"
    case minimalTitles = "minimal-titles"
    case cinematicTitles = "cinematic-titles"
    case dynamicKinetic = "dynamic-kinetic"
    case lowerThirds = "lower-thirds"
    case captions
    case endCards = "end-cards"

    public var id: String { rawValue }

    public var localizedTitle: String {
        switch self {
        case .mainTitles: return "Главные титры"
        case .chapterTitles: return "Главы"
        case .locationTitles: return "Места"
        case .dateTime: return "Дата и время"
        case .minimalTitles: return "Минималистичные"
        case .cinematicTitles: return "Кинематографичные"
        case .dynamicKinetic: return "Динамические"
        case .lowerThirds: return "Нижние трети"
        case .captions: return "Субтитры"
        case .endCards: return "Финальные карточки"
        }
    }
}

public struct TitleTemplatePreview: Codable, Hashable, Sendable {
    public var primaryText: String
    public var secondaryText: String?
    public var callToAction: String?

    public init(primaryText: String, secondaryText: String? = nil, callToAction: String? = nil) {
        self.primaryText = primaryText
        self.secondaryText = secondaryText
        self.callToAction = callToAction
    }
}

public struct TitleSafeArea: Codable, Hashable, Sendable {
    public var horizontal: Double
    public var vertical: Double
    public var portraitHorizontal: Double
    public var portraitVertical: Double

    public init(horizontal: Double = 0.07, vertical: Double = 0.07, portraitHorizontal: Double = 0.09, portraitVertical: Double = 0.055) {
        self.horizontal = min(max(0, horizontal), 0.35)
        self.vertical = min(max(0, vertical), 0.35)
        self.portraitHorizontal = min(max(0, portraitHorizontal), 0.35)
        self.portraitVertical = min(max(0, portraitVertical), 0.35)
    }

    public func rect(in size: CGSize) -> CGRect {
        let portrait = size.height > size.width
        let x = size.width * CGFloat(portrait ? portraitHorizontal : horizontal)
        let y = size.height * CGFloat(portrait ? portraitVertical : vertical)
        return CGRect(x: x, y: y, width: max(1, size.width - x * 2), height: max(1, size.height - y * 2))
    }
}

public struct TitleTextConstraints: Codable, Hashable, Sendable {
    public var maxCharacters: Int
    public var maxLines: Int
    public var maxWidth: Double
    public var maxHeight: Double
    public var minFontScale: Double
    public var maxFontScale: Double

    public init(maxCharacters: Int = 80, maxLines: Int = 2, maxWidth: Double = 0.84, maxHeight: Double = 0.42, minFontScale: Double = 0.42, maxFontScale: Double = 1) {
        self.maxCharacters = max(1, maxCharacters)
        self.maxLines = max(1, maxLines)
        self.maxWidth = min(max(0.1, maxWidth), 1)
        self.maxHeight = min(max(0.05, maxHeight), 1)
        self.minFontScale = min(max(0.15, minFontScale), 1)
        self.maxFontScale = min(max(minFontScale, maxFontScale), 2)
    }
}

public struct TitleTemplateTypography: Codable, Hashable, Sendable {
    public var fontFamily: String
    public var fontSize: Double
    public var fontWeight: Double
    public var textColorHex: String
    public var tracking: Double
    public var lineSpacing: Double
    public var alignment: TitleAlignment

    public init(fontFamily: String = "Helvetica Neue", fontSize: Double = 72, fontWeight: Double = 0.7, textColorHex: String = "#FFFFFF", tracking: Double = 0, lineSpacing: Double = 1, alignment: TitleAlignment = .center) {
        self.fontFamily = fontFamily
        self.fontSize = min(max(12, fontSize), 260)
        self.fontWeight = min(max(0, fontWeight), 1)
        self.textColorHex = textColorHex
        self.tracking = min(max(-20, tracking), 80)
        self.lineSpacing = min(max(0.5, lineSpacing), 3)
        self.alignment = alignment
    }
}

public struct TitleNormalizedRect: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public func rect(in container: CGRect) -> CGRect {
        CGRect(
            x: container.minX + container.width * CGFloat(x),
            // Template coordinates use the conventional design-tool origin
            // at the top-left; Core Graphics uses a bottom-left origin.
            y: container.maxY - container.height * CGFloat(y + height),
            width: container.width * CGFloat(width),
            height: container.height * CGFloat(height)
        )
    }
}

public enum TitleTemplateElementKind: String, Codable, Hashable, Sendable {
    case text, rectangle, roundedRectangle = "rounded-rectangle", line, circle
}

public enum TitleTemplateContent: String, Codable, Hashable, Sendable {
    case none, primaryText = "primary-text", secondaryText = "secondary-text", callToAction = "call-to-action", activeCaption = "active-caption"
}

public enum TitleRevealAxis: String, Codable, Hashable, Sendable {
    case none, horizontal, vertical
}

public struct TitleTemplateElement: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var kind: TitleTemplateElementKind
    public var content: TitleTemplateContent
    public var fixedText: String?
    public var frame: TitleNormalizedRect
    public var followsSafeArea: Bool
    public var fillColorHex: String
    public var strokeColorHex: String?
    public var opacity: Double
    public var cornerRadius: Double
    public var lineWidth: Double
    public var typography: TitleTemplateTypography?
    public var uppercase: Bool
    public var staggerIndex: Int
    public var reveal: TitleRevealAxis

    public init(
        id: String,
        kind: TitleTemplateElementKind,
        content: TitleTemplateContent = .none,
        fixedText: String? = nil,
        frame: TitleNormalizedRect,
        followsSafeArea: Bool = true,
        fillColorHex: String = "#FFFFFF",
        strokeColorHex: String? = nil,
        opacity: Double = 1,
        cornerRadius: Double = 0,
        lineWidth: Double = 0,
        typography: TitleTemplateTypography? = nil,
        uppercase: Bool = false,
        staggerIndex: Int = 0,
        reveal: TitleRevealAxis = .none
    ) {
        self.id = id
        self.kind = kind
        self.content = content
        self.fixedText = fixedText
        self.frame = frame
        self.followsSafeArea = followsSafeArea
        self.fillColorHex = fillColorHex
        self.strokeColorHex = strokeColorHex
        self.opacity = min(max(0, opacity), 1)
        self.cornerRadius = max(0, cornerRadius)
        self.lineWidth = max(0, lineWidth)
        self.typography = typography
        self.uppercase = uppercase
        self.staggerIndex = max(0, staggerIndex)
        self.reveal = reveal
    }
}

public struct TitleTemplateLayout: Codable, Hashable, Sendable {
    public var elements: [TitleTemplateElement]

    public init(elements: [TitleTemplateElement]) {
        self.elements = elements
    }
}

public struct TitleMotionPhase: Codable, Hashable, Sendable {
    public var duration: Double
    public var opacityFrom: Double
    public var translateX: Double
    public var translateY: Double
    public var scaleFrom: Double
    public var rotationFrom: Double
    public var blurFrom: Double
    public var stagger: Double
    public var easing: KeyframeEasing

    public init(duration: Double = 0.45, opacityFrom: Double = 0, translateX: Double = 0, translateY: Double = 0, scaleFrom: Double = 1, rotationFrom: Double = 0, blurFrom: Double = 0, stagger: Double = 0, easing: KeyframeEasing = .easeOut) {
        self.duration = min(max(0, duration), 4)
        self.opacityFrom = min(max(0, opacityFrom), 1)
        self.translateX = min(max(-1, translateX), 1)
        self.translateY = min(max(-1, translateY), 1)
        self.scaleFrom = min(max(0.1, scaleFrom), 3)
        self.rotationFrom = min(max(-180, rotationFrom), 180)
        self.blurFrom = min(max(0, blurFrom), 100)
        self.stagger = min(max(0, stagger), 1)
        self.easing = easing
    }
}

public struct TitleHoldMotion: Codable, Hashable, Sendable {
    public var translateX: Double
    public var translateY: Double
    public var scaleAmplitude: Double
    public var rotationAmplitude: Double
    public var cycles: Double

    public init(translateX: Double = 0, translateY: Double = 0, scaleAmplitude: Double = 0, rotationAmplitude: Double = 0, cycles: Double = 1) {
        self.translateX = min(max(-0.15, translateX), 0.15)
        self.translateY = min(max(-0.15, translateY), 0.15)
        self.scaleAmplitude = min(max(0, scaleAmplitude), 0.2)
        self.rotationAmplitude = min(max(0, rotationAmplitude), 12)
        self.cycles = min(max(0, cycles), 8)
    }
}

public struct TitleTemplateAnimation: Codable, Hashable, Sendable {
    public var animationIn: TitleMotionPhase
    public var animationHold: TitleHoldMotion
    public var animationOut: TitleMotionPhase

    public init(animationIn: TitleMotionPhase, animationHold: TitleHoldMotion = TitleHoldMotion(), animationOut: TitleMotionPhase) {
        self.animationIn = animationIn
        self.animationHold = animationHold
        self.animationOut = animationOut
    }
}

public struct TitleTemplateDefinition: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var category: TitleTemplateCategory
    public var kind: TitleTimelineKind
    public var preview: TitleTemplatePreview
    public var duration: Double
    public var typography: TitleTemplateTypography
    public var layout: TitleTemplateLayout
    public var animation: TitleTemplateAnimation
    public var safeArea: TitleSafeArea
    public var textConstraints: TitleTextConstraints
    public var renderer: String

    public init(
        id: String,
        name: String,
        category: TitleTemplateCategory,
        kind: TitleTimelineKind,
        preview: TitleTemplatePreview,
        duration: Double = 3.2,
        typography: TitleTemplateTypography,
        layout: TitleTemplateLayout,
        animation: TitleTemplateAnimation,
        safeArea: TitleSafeArea = TitleSafeArea(),
        textConstraints: TitleTextConstraints = TitleTextConstraints(),
        renderer: String = "veloedit.core-graphics.title-template.v1"
    ) {
        self.id = id
        self.name = name
        self.category = category
        self.kind = kind
        self.preview = preview
        self.duration = min(max(0.25, duration), 30)
        self.typography = typography
        self.layout = layout
        self.animation = animation
        self.safeArea = safeArea
        self.textConstraints = textConstraints
        self.renderer = renderer
    }

    public var defaultStyle: TitleStyle {
        let primary = layout.elements.first { $0.content == .primaryText }
        let primaryFrame = primary?.frame ?? TitleNormalizedRect(x: 0.08, y: 0.32, width: 0.84, height: 0.36)
        return TitleStyle(
            fontSize: typography.fontSize,
            textColorHex: typography.textColorHex,
            backgroundColorHex: "#111111",
            alignment: typography.alignment,
            fontFamily: typography.fontFamily,
            fontWeight: typography.fontWeight,
            xPosition: primaryFrame.x + primaryFrame.width / 2,
            yPosition: primaryFrame.y + primaryFrame.height / 2,
            shadow: 0.25,
            backgroundOpacity: 0,
            tracking: typography.tracking,
            lineSpacing: typography.lineSpacing
        )
    }

    public func previewItem(startTime: Double = 0) -> TitleTimelineItem {
        TitleTimelineItem(
            kind: kind,
            templateID: id,
            text: preview.primaryText,
            additionalText: preview.secondaryText,
            callToAction: preview.callToAction,
            startTime: startTime,
            duration: duration,
            style: defaultStyle,
            activeWordHighlighting: kind == .wordLevelCaptions
        )
    }
}

public enum TitleTemplateRegistry {
    public static let all: [TitleTemplateDefinition] = makeTemplates()
    private static let byID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

    public static func template(id: String?) -> TitleTemplateDefinition? {
        id.flatMap { byID[$0] }
    }

    public static func template(for item: TitleTimelineItem) -> TitleTemplateDefinition? {
        template(id: item.templateID) ?? defaultTemplate(for: item.kind)
    }

    public static func defaultTemplate(for kind: TitleTimelineKind) -> TitleTemplateDefinition? {
        let id: String
        switch kind {
        case .title: id = "title.minimal-clean.v1"
        case .subtitle, .automaticSubtitles: id = "caption.clean.v1"
        case .lowerThird: id = "title.lower-third.v1"
        case .cinematicTitle: id = "title.cinematic.v1"
        case .location: id = "title.location.v1"
        case .date: id = "title.date.v1"
        case .chapter: id = "title.chapter.v1"
        case .animatedTitle: id = "title.modern.v1"
        case .keywordOverlay: id = "title.bold.v1"
        case .kineticText: id = "title.dynamic.v1"
        case .wordLevelCaptions: id = "caption.word-focus.v1"
        case .titleCard: id = "title.travel.v1"
        case .endCard: id = "title.end-card.v1"
        }
        return byID[id]
    }

    private static func makeTemplates() -> [TitleTemplateDefinition] {
        let fadeBlur = TitleTemplateAnimation(
            animationIn: TitleMotionPhase(duration: 0.65, opacityFrom: 0, translateY: -0.035, scaleFrom: 0.98, blurFrom: 14, stagger: 0.08, easing: .easeOut),
            animationOut: TitleMotionPhase(duration: 0.5, opacityFrom: 0, translateY: 0.025, scaleFrom: 1.01, blurFrom: 8, stagger: 0.04, easing: .easeIn)
        )
        let maskReveal = TitleTemplateAnimation(
            animationIn: TitleMotionPhase(duration: 0.55, opacityFrom: 0, translateX: -0.06, scaleFrom: 0.96, stagger: 0.09, easing: .easeOut),
            animationHold: TitleHoldMotion(translateY: 0.003, scaleAmplitude: 0.006, cycles: 1.4),
            animationOut: TitleMotionPhase(duration: 0.42, opacityFrom: 0, translateX: 0.045, scaleFrom: 0.97, stagger: 0.05, easing: .easeIn)
        )
        let kinetic = TitleTemplateAnimation(
            animationIn: TitleMotionPhase(duration: 0.34, opacityFrom: 0, translateY: -0.10, scaleFrom: 0.72, rotationFrom: -8, blurFrom: 6, stagger: 0.055, easing: .easeOut),
            animationHold: TitleHoldMotion(translateX: 0.004, translateY: 0.006, scaleAmplitude: 0.012, rotationAmplitude: 0.5, cycles: 2.2),
            animationOut: TitleMotionPhase(duration: 0.28, opacityFrom: 0, translateY: 0.08, scaleFrom: 0.78, rotationFrom: 6, stagger: 0.035, easing: .easeIn)
        )
        let cleanCaption = TitleTemplateAnimation(
            animationIn: TitleMotionPhase(duration: 0.18, opacityFrom: 0, translateY: -0.025, scaleFrom: 0.98, easing: .easeOut),
            animationOut: TitleMotionPhase(duration: 0.16, opacityFrom: 0, translateY: 0.02, scaleFrom: 0.99, easing: .easeIn)
        )

        func type(_ family: String, _ size: Double, _ weight: Double, _ color: String, _ tracking: Double = 0, _ alignment: TitleAlignment = .center, _ lineSpacing: Double = 1) -> TitleTemplateTypography {
            TitleTemplateTypography(fontFamily: family, fontSize: size, fontWeight: weight, textColorHex: color, tracking: tracking, lineSpacing: lineSpacing, alignment: alignment)
        }
        func text(_ id: String, _ content: TitleTemplateContent, _ frame: TitleNormalizedRect, _ typography: TitleTemplateTypography, uppercase: Bool = false, stagger: Int = 0, reveal: TitleRevealAxis = .none, color: String? = nil) -> TitleTemplateElement {
            TitleTemplateElement(id: id, kind: .text, content: content, frame: frame, fillColorHex: color ?? typography.textColorHex, typography: typography, uppercase: uppercase, staggerIndex: stagger, reveal: reveal)
        }
        func shape(_ id: String, _ kind: TitleTemplateElementKind, _ frame: TitleNormalizedRect, _ color: String, opacity: Double = 1, radius: Double = 0, stroke: String? = nil, lineWidth: Double = 0, safe: Bool = true, stagger: Int = 0, reveal: TitleRevealAxis = .none) -> TitleTemplateElement {
            TitleTemplateElement(id: id, kind: kind, frame: frame, followsSafeArea: safe, fillColorHex: color, strokeColorHex: stroke, opacity: opacity, cornerRadius: radius, lineWidth: lineWidth, staggerIndex: stagger, reveal: reveal)
        }

        let sans = "Avenir Next"
        let serif = "Georgia"
        let mono = "Menlo"

        return [
            TitleTemplateDefinition(
                id: "title.minimal-clean.v1", name: "Minimal Clean", category: .minimalTitles, kind: .title,
                preview: TitleTemplatePreview(primaryText: "МОЁ ЛЕТО", secondaryText: "маленькая история"),
                typography: type(sans, 78, 0.62, "#FFFFFF", 5),
                layout: TitleTemplateLayout(elements: [
                    shape("hairline", .line, .init(x: 0.28, y: 0.63, width: 0.44, height: 0.004), "#FFFFFF", opacity: 0.78, lineWidth: 2, stagger: 0, reveal: .horizontal),
                    text("primary", .primaryText, .init(x: 0.12, y: 0.36, width: 0.76, height: 0.22), type(sans, 78, 0.62, "#FFFFFF", 5), uppercase: true, stagger: 1, reveal: .vertical),
                    text("secondary", .secondaryText, .init(x: 0.22, y: 0.59, width: 0.56, height: 0.10), type(sans, 28, 0.38, "#D8D8DE", 2), stagger: 2)
                ]), animation: fadeBlur,
                textConstraints: TitleTextConstraints(maxCharacters: 52, maxLines: 2, maxWidth: 0.76, maxHeight: 0.24, minFontScale: 0.48)
            ),
            TitleTemplateDefinition(
                id: "title.cinematic.v1", name: "Cinematic", category: .cinematicTitles, kind: .cinematicTitle,
                preview: TitleTemplatePreview(primaryText: "ДОРОГА ДОМОЙ", secondaryText: "A VELOEDIT FILM"), duration: 4,
                typography: type(serif, 88, 0.58, "#F6F0E6", 9),
                layout: TitleTemplateLayout(elements: [
                    shape("top-rule", .line, .init(x: 0.23, y: 0.30, width: 0.54, height: 0.003), "#D8B26E", opacity: 0.85, lineWidth: 2, stagger: 0, reveal: .horizontal),
                    text("primary", .primaryText, .init(x: 0.10, y: 0.34, width: 0.80, height: 0.25), type(serif, 88, 0.58, "#F6F0E6", 9), uppercase: true, stagger: 1, reveal: .horizontal),
                    text("secondary", .secondaryText, .init(x: 0.24, y: 0.61, width: 0.52, height: 0.08), type(sans, 23, 0.48, "#D8B26E", 6), uppercase: true, stagger: 2),
                    shape("bottom-rule", .line, .init(x: 0.36, y: 0.72, width: 0.28, height: 0.003), "#F6F0E6", opacity: 0.56, lineWidth: 1, stagger: 3, reveal: .horizontal)
                ]), animation: fadeBlur, safeArea: TitleSafeArea(horizontal: 0.055, vertical: 0.08, portraitHorizontal: 0.08, portraitVertical: 0.07),
                textConstraints: TitleTextConstraints(maxCharacters: 46, maxLines: 2, maxWidth: 0.8, maxHeight: 0.28, minFontScale: 0.43)
            ),
            TitleTemplateDefinition(
                id: "title.modern.v1", name: "Modern", category: .mainTitles, kind: .animatedTitle,
                preview: TitleTemplatePreview(primaryText: "НОВЫЙ МАРШРУТ", secondaryText: "MOVE FORWARD"),
                typography: type(sans, 94, 0.88, "#FFFFFF", -1, .left),
                layout: TitleTemplateLayout(elements: [
                    shape("panel", .roundedRectangle, .init(x: 0.08, y: 0.28, width: 0.72, height: 0.39), "#111218", opacity: 0.86, radius: 28, stagger: 0, reveal: .horizontal),
                    shape("accent", .rectangle, .init(x: 0.08, y: 0.28, width: 0.018, height: 0.39), "#5AC8FA", stagger: 1, reveal: .vertical),
                    text("primary", .primaryText, .init(x: 0.14, y: 0.34, width: 0.60, height: 0.22), type(sans, 94, 0.88, "#FFFFFF", -1, .left), uppercase: true, stagger: 2, reveal: .horizontal),
                    text("secondary", .secondaryText, .init(x: 0.145, y: 0.57, width: 0.52, height: 0.07), type(sans, 24, 0.56, "#5AC8FA", 4, .left), uppercase: true, stagger: 3)
                ]), animation: maskReveal,
                textConstraints: TitleTextConstraints(maxCharacters: 42, maxLines: 2, maxWidth: 0.60, maxHeight: 0.23, minFontScale: 0.44)
            ),
            TitleTemplateDefinition(
                id: "title.bold.v1", name: "Bold", category: .dynamicKinetic, kind: .keywordOverlay,
                preview: TitleTemplatePreview(primaryText: "90 КМ/Ч", secondaryText: "ПОЛНЫЙ ГАЗ"),
                typography: type(sans, 126, 1, "#0B0B0D", -4, .left),
                layout: TitleTemplateLayout(elements: [
                    shape("shadow", .rectangle, .init(x: 0.155, y: 0.365, width: 0.69, height: 0.27), "#111111", opacity: 0.88, stagger: 0, reveal: .horizontal),
                    shape("banner", .rectangle, .init(x: 0.13, y: 0.33, width: 0.69, height: 0.27), "#FFD60A", stagger: 1, reveal: .horizontal),
                    text("primary", .primaryText, .init(x: 0.17, y: 0.355, width: 0.59, height: 0.20), type(sans, 126, 1, "#0B0B0D", -4, .left), uppercase: true, stagger: 2, reveal: .vertical),
                    text("secondary", .secondaryText, .init(x: 0.55, y: 0.62, width: 0.27, height: 0.07), type(mono, 22, 0.76, "#FFFFFF", 2, .right), uppercase: true, stagger: 3)
                ]), animation: kinetic,
                textConstraints: TitleTextConstraints(maxCharacters: 24, maxLines: 1, maxWidth: 0.59, maxHeight: 0.20, minFontScale: 0.45)
            ),
            TitleTemplateDefinition(
                id: "title.elegant.v1", name: "Elegant", category: .mainTitles, kind: .title,
                preview: TitleTemplatePreview(primaryText: "Тихий вечер", secondaryText: "КАРЕЛИЯ · 2026"), duration: 4,
                typography: type(serif, 82, 0.42, "#FFF9F0", 2),
                layout: TitleTemplateLayout(elements: [
                    shape("frame", .rectangle, .init(x: 0.19, y: 0.23, width: 0.62, height: 0.54), "#000000", opacity: 0, stroke: "#E9D9BF", lineWidth: 2, stagger: 0, reveal: .horizontal),
                    text("primary", .primaryText, .init(x: 0.25, y: 0.37, width: 0.50, height: 0.20), type(serif, 82, 0.42, "#FFF9F0", 2), stagger: 1, reveal: .vertical),
                    shape("ornament", .circle, .init(x: 0.493, y: 0.61, width: 0.014, height: 0.025), "#E9D9BF", stagger: 2),
                    text("secondary", .secondaryText, .init(x: 0.28, y: 0.65, width: 0.44, height: 0.07), type(sans, 20, 0.44, "#E9D9BF", 5), uppercase: true, stagger: 3)
                ]), animation: fadeBlur,
                textConstraints: TitleTextConstraints(maxCharacters: 54, maxLines: 2, maxWidth: 0.50, maxHeight: 0.22, minFontScale: 0.46)
            ),
            TitleTemplateDefinition(
                id: "title.dynamic.v1", name: "Dynamic", category: .dynamicKinetic, kind: .kineticText,
                preview: TitleTemplatePreview(primaryText: "ВПЕРЁД!", secondaryText: "RIDE · EXPLORE · REPEAT"),
                typography: type(sans, 132, 1, "#FFFFFF", -5),
                layout: TitleTemplateLayout(elements: [
                    shape("ring", .circle, .init(x: 0.12, y: 0.19, width: 0.27, height: 0.48), "#000000", opacity: 0, stroke: "#34C759", lineWidth: 18, stagger: 0, reveal: .vertical),
                    shape("slash", .rectangle, .init(x: 0.31, y: 0.22, width: 0.035, height: 0.57), "#34C759", opacity: 0.9, stagger: 1, reveal: .vertical),
                    text("primary", .primaryText, .init(x: 0.23, y: 0.36, width: 0.66, height: 0.23), type(sans, 132, 1, "#FFFFFF", -5), uppercase: true, stagger: 2, reveal: .horizontal),
                    text("secondary", .secondaryText, .init(x: 0.47, y: 0.62, width: 0.40, height: 0.07), type(mono, 20, 0.64, "#34C759", 2, .right), uppercase: true, stagger: 3)
                ]), animation: kinetic,
                textConstraints: TitleTextConstraints(maxCharacters: 28, maxLines: 1, maxWidth: 0.66, maxHeight: 0.23, minFontScale: 0.44)
            ),
            TitleTemplateDefinition(
                id: "title.travel.v1", name: "Travel", category: .mainTitles, kind: .titleCard,
                preview: TitleTemplatePreview(primaryText: "TRAVEL 2026", secondaryText: "МОСКВА → СОЧИ"), duration: 4,
                typography: type(sans, 96, 0.82, "#FFFFFF", 3, .left),
                layout: TitleTemplateLayout(elements: [
                    shape("sun", .circle, .init(x: 0.67, y: 0.16, width: 0.22, height: 0.39), "#FF9F0A", opacity: 0.82, stagger: 0),
                    shape("route", .line, .init(x: 0.08, y: 0.75, width: 0.72, height: 0.005), "#FFFFFF", opacity: 0.88, lineWidth: 4, stagger: 1, reveal: .horizontal),
                    shape("marker", .circle, .init(x: 0.775, y: 0.731, width: 0.025, height: 0.045), "#FFFFFF", stagger: 2),
                    text("primary", .primaryText, .init(x: 0.09, y: 0.35, width: 0.66, height: 0.24), type(sans, 96, 0.82, "#FFFFFF", 3, .left), uppercase: true, stagger: 2, reveal: .horizontal),
                    text("secondary", .secondaryText, .init(x: 0.10, y: 0.62, width: 0.52, height: 0.08), type(mono, 22, 0.52, "#FFD8A8", 2, .left), uppercase: true, stagger: 3)
                ]), animation: maskReveal,
                textConstraints: TitleTextConstraints(maxCharacters: 38, maxLines: 2, maxWidth: 0.66, maxHeight: 0.25, minFontScale: 0.44)
            ),
            TitleTemplateDefinition(
                id: "title.chapter.v1", name: "Chapter", category: .chapterTitles, kind: .chapter,
                preview: TitleTemplatePreview(primaryText: "ВЕЛОПРОГУЛКА", secondaryText: "ГЛАВА 03"),
                typography: type(sans, 84, 0.78, "#FFFFFF", 1, .left),
                layout: TitleTemplateLayout(elements: [
                    text("number", .none, .init(x: 0.04, y: 0.17, width: 0.34, height: 0.53), type(sans, 210, 1, "#8B5CF6", -8, .left), uppercase: true, stagger: 0, reveal: .vertical),
                    shape("rule", .line, .init(x: 0.35, y: 0.31, width: 0.43, height: 0.004), "#8B5CF6", lineWidth: 5, stagger: 1, reveal: .horizontal),
                    text("primary", .primaryText, .init(x: 0.35, y: 0.36, width: 0.54, height: 0.22), type(sans, 84, 0.78, "#FFFFFF", 1, .left), uppercase: true, stagger: 2, reveal: .horizontal),
                    text("secondary", .secondaryText, .init(x: 0.36, y: 0.60, width: 0.34, height: 0.07), type(mono, 22, 0.62, "#C8AFFF", 3, .left), uppercase: true, stagger: 3)
                ].enumerated().map { index, element in
                    if element.id != "number" { return element }
                    var copy = element; copy.fixedText = "03"; return copy
                }), animation: maskReveal,
                textConstraints: TitleTextConstraints(maxCharacters: 40, maxLines: 2, maxWidth: 0.54, maxHeight: 0.23, minFontScale: 0.45)
            ),
            TitleTemplateDefinition(
                id: "title.location.v1", name: "Location", category: .locationTitles, kind: .location,
                preview: TitleTemplatePreview(primaryText: "СОЧИ", secondaryText: "43.5855° N · 39.7231° E"),
                typography: type(sans, 86, 0.86, "#FFFFFF", 2, .left),
                layout: TitleTemplateLayout(elements: [
                    shape("pin-outer", .circle, .init(x: 0.075, y: 0.69, width: 0.045, height: 0.08), "#FF453A", stagger: 0),
                    shape("pin-inner", .circle, .init(x: 0.087, y: 0.711, width: 0.021, height: 0.038), "#FFFFFF", stagger: 1),
                    text("primary", .primaryText, .init(x: 0.14, y: 0.62, width: 0.50, height: 0.16), type(sans, 86, 0.86, "#FFFFFF", 2, .left), uppercase: true, stagger: 2, reveal: .horizontal),
                    text("secondary", .secondaryText, .init(x: 0.145, y: 0.79, width: 0.48, height: 0.06), type(mono, 18, 0.48, "#D1D1D6", 1, .left), uppercase: true, stagger: 3)
                ]), animation: maskReveal,
                textConstraints: TitleTextConstraints(maxCharacters: 34, maxLines: 1, maxWidth: 0.50, maxHeight: 0.16, minFontScale: 0.48)
            ),
            TitleTemplateDefinition(
                id: "title.lower-third.v1", name: "Lower Third", category: .lowerThirds, kind: .lowerThird,
                preview: TitleTemplatePreview(primaryText: "АННА ПЕТРОВА", secondaryText: "ПУТЕШЕСТВЕННИК"),
                typography: type(sans, 56, 0.82, "#FFFFFF", 1, .left),
                layout: TitleTemplateLayout(elements: [
                    shape("panel", .roundedRectangle, .init(x: 0.05, y: 0.68, width: 0.49, height: 0.22), "#111218", opacity: 0.90, radius: 18, stagger: 0, reveal: .horizontal),
                    shape("accent", .rectangle, .init(x: 0.05, y: 0.68, width: 0.016, height: 0.22), "#BF5AF2", stagger: 1, reveal: .vertical),
                    text("primary", .primaryText, .init(x: 0.095, y: 0.705, width: 0.40, height: 0.09), type(sans, 56, 0.82, "#FFFFFF", 1, .left), uppercase: true, stagger: 2, reveal: .horizontal),
                    text("secondary", .secondaryText, .init(x: 0.098, y: 0.80, width: 0.36, height: 0.055), type(sans, 20, 0.50, "#D9B4EA", 2, .left), uppercase: true, stagger: 3)
                ]), animation: maskReveal,
                textConstraints: TitleTextConstraints(maxCharacters: 48, maxLines: 1, maxWidth: 0.40, maxHeight: 0.10, minFontScale: 0.50)
            ),
            TitleTemplateDefinition(
                id: "title.date.v1", name: "Date", category: .dateTime, kind: .date,
                preview: TitleTemplatePreview(primaryText: "16 АПРЕЛЯ", secondaryText: "2026 · 07:40"),
                typography: type(mono, 48, 0.60, "#FFFFFF", 2, .right),
                layout: TitleTemplateLayout(elements: [
                    shape("bracket-top", .line, .init(x: 0.67, y: 0.075, width: 0.25, height: 0.003), "#5AC8FA", lineWidth: 3, stagger: 0, reveal: .horizontal),
                    text("primary", .primaryText, .init(x: 0.55, y: 0.10, width: 0.37, height: 0.10), type(mono, 48, 0.60, "#FFFFFF", 2, .right), uppercase: true, stagger: 1, reveal: .horizontal),
                    text("secondary", .secondaryText, .init(x: 0.64, y: 0.205, width: 0.28, height: 0.055), type(mono, 19, 0.45, "#9EDBFF", 1, .right), uppercase: true, stagger: 2)
                ]), animation: fadeBlur,
                textConstraints: TitleTextConstraints(maxCharacters: 34, maxLines: 1, maxWidth: 0.37, maxHeight: 0.11, minFontScale: 0.55)
            ),
            TitleTemplateDefinition(
                id: "title.end-card.v1", name: "End Card", category: .endCards, kind: .endCard,
                preview: TitleTemplatePreview(primaryText: "КОНЕЦ", secondaryText: "СПАСИБО ЗА ПРОСМОТР", callToAction: "ПОДПИСАТЬСЯ"), duration: 4.5,
                typography: type(serif, 92, 0.50, "#FFF8EE", 7),
                layout: TitleTemplateLayout(elements: [
                    shape("background", .rectangle, .init(x: 0, y: 0, width: 1, height: 1), "#09090C", safe: false),
                    shape("halo", .circle, .init(x: 0.35, y: 0.18, width: 0.30, height: 0.54), "#8B5CF6", opacity: 0.22, safe: false, stagger: 0),
                    shape("frame", .rectangle, .init(x: 0.18, y: 0.20, width: 0.64, height: 0.60), "#000000", opacity: 0, stroke: "#6C5A8D", lineWidth: 2, stagger: 1, reveal: .horizontal),
                    text("primary", .primaryText, .init(x: 0.20, y: 0.34, width: 0.60, height: 0.19), type(serif, 92, 0.50, "#FFF8EE", 7), uppercase: true, stagger: 2, reveal: .vertical),
                    text("secondary", .secondaryText, .init(x: 0.26, y: 0.56, width: 0.48, height: 0.07), type(sans, 20, 0.48, "#C9BCD9", 3), uppercase: true, stagger: 3),
                    text("cta", .callToAction, .init(x: 0.36, y: 0.68, width: 0.28, height: 0.08), type(sans, 18, 0.72, "#FFFFFF", 2), uppercase: true, stagger: 4)
                ]), animation: fadeBlur, safeArea: TitleSafeArea(horizontal: 0.04, vertical: 0.04, portraitHorizontal: 0.055, portraitVertical: 0.04),
                textConstraints: TitleTextConstraints(maxCharacters: 36, maxLines: 2, maxWidth: 0.60, maxHeight: 0.20, minFontScale: 0.46)
            ),
            TitleTemplateDefinition(
                id: "caption.clean.v1", name: "Subtitles Clean", category: .captions, kind: .automaticSubtitles,
                preview: TitleTemplatePreview(primaryText: "Дорога начинается здесь"), duration: 2.6,
                typography: type(sans, 50, 0.66, "#FFFFFF"),
                layout: TitleTemplateLayout(elements: [
                    shape("caption-bg", .roundedRectangle, .init(x: 0.12, y: 0.77, width: 0.76, height: 0.15), "#0B0B0D", opacity: 0.82, radius: 20, stagger: 0, reveal: .horizontal),
                    text("primary", .primaryText, .init(x: 0.15, y: 0.79, width: 0.70, height: 0.11), type(sans, 50, 0.66, "#FFFFFF"), stagger: 1, reveal: .vertical)
                ]), animation: cleanCaption,
                textConstraints: TitleTextConstraints(maxCharacters: 92, maxLines: 2, maxWidth: 0.70, maxHeight: 0.12, minFontScale: 0.50)
            ),
            TitleTemplateDefinition(
                id: "caption.word-focus.v1", name: "Word Focus", category: .captions, kind: .wordLevelCaptions,
                preview: TitleTemplatePreview(primaryText: "Каждый момент имеет значение"), duration: 2.8,
                typography: type(sans, 58, 0.82, "#FFFFFF", -1),
                layout: TitleTemplateLayout(elements: [
                    shape("caption-bg", .roundedRectangle, .init(x: 0.09, y: 0.74, width: 0.82, height: 0.18), "#111218", opacity: 0.72, radius: 22, stagger: 0, reveal: .horizontal),
                    shape("accent", .rectangle, .init(x: 0.09, y: 0.74, width: 0.012, height: 0.18), "#34C759", stagger: 1, reveal: .vertical),
                    text("primary", .activeCaption, .init(x: 0.13, y: 0.765, width: 0.74, height: 0.13), type(sans, 58, 0.82, "#FFFFFF", -1), stagger: 2, reveal: .vertical)
                ]), animation: cleanCaption,
                textConstraints: TitleTextConstraints(maxCharacters: 88, maxLines: 2, maxWidth: 0.74, maxHeight: 0.14, minFontScale: 0.48)
            )
        ]
    }
}
