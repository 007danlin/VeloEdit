import Foundation

// MARK: - Metadata-driven transition/effect catalogue

public struct RenderParameterDescriptor: Codable, Hashable, Identifiable, Sendable {
    public var key: String
    public var title: String
    public var range: ClosedRange<Double>
    public var defaultValue: Double
    public var unit: String?
    public var valueType: EffectParameterValueType
    public var enumOptions: [String]
    public var supportsKeyframes: Bool
    public var isAdvanced: Bool
    public var id: String { key }

    public init(
        key: String,
        title: String,
        range: ClosedRange<Double>,
        defaultValue: Double,
        unit: String? = nil,
        valueType: EffectParameterValueType = .float,
        enumOptions: [String] = [],
        supportsKeyframes: Bool? = nil,
        isAdvanced: Bool = false
    ) {
        self.key = key
        self.title = title
        self.range = range
        self.defaultValue = min(max(range.lowerBound, defaultValue), range.upperBound)
        self.unit = unit
        self.valueType = valueType
        self.enumOptions = enumOptions
        self.supportsKeyframes = supportsKeyframes ?? valueType.supportsKeyframes
        self.isAdvanced = isAdvanced
    }

    public func parameter(value: Double? = nil) -> EffectParameter {
        let scalar = min(max(range.lowerBound, value ?? defaultValue), range.upperBound)
        return EffectParameter(name: key, value: scalar, valueType: valueType)
    }
}

public enum TransitionPresetCategory: String, Codable, CaseIterable, Identifiable, Sendable {
    case basic, directional, motion, cinematic, creative, shapeMask = "shape-mask"
    public var id: String { rawValue }

    public var localizedTitle: String {
        switch self {
        case .basic: return "Базовые"
        case .directional: return "Направленные"
        case .motion: return "Движение"
        case .cinematic: return "Кинематографичные"
        case .creative: return "Креативные"
        case .shapeMask: return "Форма и маска"
        }
    }
}

public struct TransitionPreset: Codable, Hashable, Identifiable, Sendable {
    public var style: TransitionStyle
    public var category: TransitionPresetCategory
    public var subtitle: String
    public var semanticTags: Set<String>
    public var defaultDuration: Double
    public var durationRange: ClosedRange<Double>
    public var defaultIntensity: Double
    public var parameters: [RenderParameterDescriptor]
    public var isHeavy: Bool
    public var defaultDirection: TransitionDirection
    public var defaultEasing: KeyframeEasing
    public var version: Int
    public var id: String { style.rawValue }
    public var name: String { style.localizedTitle }

    public var defaultParameters: [EffectParameter] {
        parameters.map { $0.parameter() }
    }

    public func parameter(named key: String) -> RenderParameterDescriptor? {
        parameters.first { $0.key == key }
    }
}

public enum TransitionPresetRegistry {
    /// Existing raw values remain visible so older projects can be replaced in
    /// place, while new presets are discovered solely through metadata.
    public static let all: [TransitionPreset] = TransitionStyle.allCases.map(makePreset)

    public static func preset(for style: TransitionStyle) -> TransitionPreset {
        all.first(where: { $0.style == style }) ?? makePreset(style)
    }

    public static func presets(in category: TransitionPresetCategory) -> [TransitionPreset] {
        all.filter { $0.category == category }
    }

    private static func makePreset(_ style: TransitionStyle) -> TransitionPreset {
        let category: TransitionPresetCategory
        let subtitle: String
        let tags: Set<String>
        let duration: Double
        let range: ClosedRange<Double>
        let intensity: Double
        var parameters: [RenderParameterDescriptor]
        let heavy: Bool
        let direction: TransitionDirection
        let easing: KeyframeEasing

        switch style {
        case .cut:
            category = .basic; subtitle = "Мгновенная профессиональная склейка"; tags = ["neutral", "fast", "dialogue"]
            duration = 0.08; range = 0.08...0.12; intensity = 0; parameters = []; heavy = false
        case .crossDissolve, .fade, .fadeThroughBlack, .fadeToWhite, .dipToColor:
            category = .basic; subtitle = "Спокойная смена сцены"; tags = ["calm", "memory", "time-change", "soft"]
            duration = style == .crossDissolve ? 0.55 : 0.45; range = 0.18...2.5; intensity = 0.65
            parameters = style == .dipToColor
                ? [RenderParameterDescriptor(key: "colorHue", title: "Оттенок", range: 0...1, defaultValue: 0.58)]
                : []; heavy = false
        case .push, .pushLeft, .pushRight, .pushUp, .pushDown, .slideLeft, .slideRight, .slideUp, .slideDown,
             .wipeLeft, .wipeRight, .wipeUp, .wipeDown:
            category = .directional; subtitle = "Продолжает направление движения"; tags = ["movement", "directional", "travel", "action"]
            duration = 0.38; range = 0.14...1.5; intensity = 0.78
            parameters = style.rawValue.hasPrefix("wipe")
                ? [RenderParameterDescriptor(key: "softness", title: "Мягкость края", range: 0...1, defaultValue: 0.08)] : []
            heavy = false
        case .zoom, .zoomIn, .zoomOut, .whipLeft, .whipRight, .whipUp, .whipDown, .spin, .cameraPush, .cameraPull:
            category = .motion; subtitle = "Мотивированный акцент движения"; tags = ["fast", "camera-motion", "action", "beat"]
            duration = style.rawValue.hasPrefix("whip") ? 0.24 : 0.42; range = 0.12...1.2; intensity = 0.72
            parameters = [
                RenderParameterDescriptor(key: "motionBlur", title: "Motion Blur", range: 0...1, defaultValue: 0.55),
                RenderParameterDescriptor(key: "scale", title: "Масштаб", range: 0...1, defaultValue: 0.5)
            ]; heavy = style.rawValue.hasPrefix("whip") || style == .spin
            if style.rawValue.hasPrefix("whip") { parameters.removeAll { $0.key == "scale" } }
        case .filmDissolve, .filmBurn, .lightLeak, .blurDissolve, .lensBlur, .exposureFlash, .lightFlash:
            category = .cinematic; subtitle = "Сдержанный киноакцент"; tags = ["cinematic", "emotion", "climax", "memory"]
            duration = 0.52; range = 0.18...1.8; intensity = style == .filmDissolve ? 0.42 : 0.58
            parameters = style == .blurDissolve || style == .lensBlur
                ? [RenderParameterDescriptor(key: "blur", title: "Размытие", range: 0...1, defaultValue: 0.72)] : []
            heavy = true
        case .glitch, .rgbSplit, .digitalDistortion, .pixelate, .shatter, .ripple, .wave:
            category = .creative; subtitle = "Редкий стилизованный акцент"; tags = ["digital", "stylized", "drop", "high-energy"]
            duration = 0.32; range = 0.10...1.0; intensity = 0.52
            parameters = [
                RenderParameterDescriptor(key: "amount", title: "Сила искажения", range: 0...1, defaultValue: 0.52),
                RenderParameterDescriptor(key: "frequency", title: "Частота", range: 1...32, defaultValue: 12)
            ]; heavy = true
            if [.rgbSplit, .pixelate, .shatter].contains(style) { parameters.removeAll { $0.key == "frequency" } }
        case .circle, .iris, .radial, .geometricWipe, .maskReveal:
            category = .shapeMask; subtitle = "Проявление через форму"; tags = ["graphic", "reveal", "chapter", "location"]
            duration = 0.48; range = 0.16...1.6; intensity = 0.75
            parameters = [
                RenderParameterDescriptor(key: "softness", title: "Растушёвка", range: 0...1, defaultValue: 0.12),
                RenderParameterDescriptor(key: "rotation", title: "Поворот", range: -180...180, defaultValue: 0, unit: "°")
            ]; heavy = true
            if style == .circle { parameters.removeAll { $0.key == "rotation" } }
        }
        switch style {
        case .pushRight, .slideRight, .wipeRight, .whipRight: direction = .right
        case .pushUp, .slideUp, .wipeUp, .whipUp: direction = .up
        case .pushDown, .slideDown, .wipeDown, .whipDown: direction = .down
        case .zoomOut, .cameraPull: direction = .outward
        case .zoom, .zoomIn, .cameraPush, .circle, .iris, .radial: direction = .inward
        case .push, .pushLeft, .slideLeft, .wipeLeft, .whipLeft: direction = .left
        default: direction = .automatic
        }
        switch style {
        case .cut: easing = .linear
        case .whipLeft, .whipRight, .whipUp, .whipDown, .glitch, .rgbSplit, .digitalDistortion: easing = .easeOut
        default: easing = .easeInOut
        }
        return TransitionPreset(
            style: style,
            category: category,
            subtitle: subtitle,
            semanticTags: tags,
            defaultDuration: duration,
            durationRange: range,
            defaultIntensity: intensity,
            parameters: parameters,
            isHeavy: heavy,
            defaultDirection: direction,
            defaultEasing: easing,
            version: 2
        )
    }
}

public enum EffectRenderStage: Int, Codable, CaseIterable, Comparable, Sendable {
    case color = 100
    case blur = 200
    case stylization = 300
    case transform = 400
    public static func < (lhs: EffectRenderStage, rhs: EffectRenderStage) -> Bool { lhs.rawValue < rhs.rawValue }
}

public enum EffectFCPXMLCapability: String, Codable, Sendable {
    case native, metadataOnly = "metadata-only", renderedFallback = "rendered-fallback"
}

public struct EffectAIUsageMetadata: Codable, Hashable, Sendable {
    public var preferredContexts: Set<String>
    public var discouragedContexts: Set<String>
    public var maximumRecommendedIntensity: Double
    public var requiresExplicitCreativeRequest: Bool

    public init(
        preferredContexts: Set<String> = [],
        discouragedContexts: Set<String> = ["dialogue", "emotional-closeup"],
        maximumRecommendedIntensity: Double = 0.65,
        requiresExplicitCreativeRequest: Bool = false
    ) {
        self.preferredContexts = preferredContexts
        self.discouragedContexts = discouragedContexts
        self.maximumRecommendedIntensity = maximumRecommendedIntensity.clamped01
        self.requiresExplicitCreativeRequest = requiresExplicitCreativeRequest
    }
}

public struct EffectPreset: Codable, Hashable, Identifiable, Sendable {
    public var type: TimelineEffectType
    public var category: TimelineEffectCategory
    public var subtitle: String
    public var semanticTags: Set<String>
    public var parameters: [RenderParameterDescriptor]
    public var isHeavy: Bool
    public var renderStage: EffectRenderStage
    public var previewSupported: Bool
    public var renderSupported: Bool
    public var fcpxmlCapability: EffectFCPXMLCapability
    public var aiUsage: EffectAIUsageMetadata
    public var version: Int
    public var id: String { type.rawValue }
    public var name: String { type.localizedTitle }

    public func parameter(named key: String) -> RenderParameterDescriptor? {
        parameters.first { $0.key == key }
    }

    public var defaultParameters: [EffectParameter] {
        parameters.filter { $0.key != "intensity" }.map { $0.parameter() }
    }
}

public enum EffectPresetRegistry {
    public static let all: [EffectPreset] = TimelineEffectType.allCases.map(makePreset)

    public static func preset(for type: TimelineEffectType) -> EffectPreset {
        all.first(where: { $0.type == type }) ?? makePreset(type)
    }

    public static func presets(in category: TimelineEffectCategory) -> [EffectPreset] {
        all.filter { $0.category == category }
    }

    private static func makePreset(_ type: TimelineEffectType) -> EffectPreset {
        var parameters = [RenderParameterDescriptor(
            key: "intensity", title: "Интенсивность", range: 0...1,
            defaultValue: type.defaultIntensity, valueType: .float
        )]
        switch type {
        case .glitch:
            parameters.append(RenderParameterDescriptor(key: "frequency", title: "Частота сбоев", range: 1...30, defaultValue: 12))
        case .directionalBlur, .motionBlur, .cinematicMotionBlur:
            parameters.append(RenderParameterDescriptor(
                key: "angle", title: "Угол", range: -.pi...(.pi), defaultValue: 0,
                unit: "rad", valueType: .angle
            ))
        case .shake, .handheld:
            parameters.append(contentsOf: [
                RenderParameterDescriptor(key: "amplitude", title: "Амплитуда", range: 0...1, defaultValue: type == .handheld ? 0.18 : 0.42),
                RenderParameterDescriptor(key: "frequency", title: "Частота", range: 1...30, defaultValue: type == .handheld ? 6 : 13),
                RenderParameterDescriptor(key: "rotation", title: "Поворот", range: -12...12, defaultValue: 0, unit: "°", valueType: .angle)
            ])
        case .pan, .cameraDrift, .parallaxMotion:
            parameters.append(RenderParameterDescriptor(
                key: "direction", title: "Направление", range: -1...1, defaultValue: 1,
                valueType: .enumeration, enumOptions: ["Влево", "Вправо"], supportsKeyframes: false
            ))
        case .lensDistortion, .fisheye, .barrelDistortion:
            parameters.append(RenderParameterDescriptor(key: "radius", title: "Радиус", range: 0.1...1, defaultValue: 0.62))
        case .scanlines, .halftone:
            parameters.append(RenderParameterDescriptor(key: "scale", title: "Размер", range: 1...40, defaultValue: 8))
        case .posterize:
            parameters.append(RenderParameterDescriptor(key: "levels", title: "Уровни", range: 2...30, defaultValue: 8, valueType: .int))
        case .letterbox:
            parameters.append(contentsOf: [
                RenderParameterDescriptor(key: "barSize", title: "Размер полос", range: 0.04...0.24, defaultValue: 0.12),
                RenderParameterDescriptor(key: "barColor", title: "Цвет полос", range: 0...1, defaultValue: 0, valueType: .color, supportsKeyframes: false)
            ])
        case .zoomBlur, .radialBlur:
            parameters.append(RenderParameterDescriptor(key: "radius", title: "Радиус", range: 0...80, defaultValue: 24))
        case .tint:
            parameters.append(RenderParameterDescriptor(key: "color", title: "Цвет", range: 0...1, defaultValue: 0.58, valueType: .color))
        case .colorGrade:
            parameters.append(RenderParameterDescriptor(
                key: "look", title: "Профиль", range: 0...3, defaultValue: 0,
                valueType: .enumeration, enumOptions: ["Natural", "Cinematic", "Warm", "Cool"], supportsKeyframes: false
            ))
        default:
            break
        }

        if type.category == .motion {
            parameters.append(contentsOf: transformParameters)
        }
        let heavy = [
            TimelineEffectType.lensBlur, .zoomBlur, .radialBlur, .chromaticAberration,
            .lensDistortion, .fisheye, .barrelDistortion, .glitch, .rgbSplit,
            .filmBurn, .fogHaze, .vhsDistortion
        ].contains(type)
        let stage: EffectRenderStage
        switch type.category {
        case .basic, .color: stage = .color
        case .blur: stage = .blur
        case .motion: stage = .transform
        case .cinematic, .stylized: stage = .stylization
        }
        let guarded = [.glitch, .rgbSplit, .posterize, .halftone, .vhsDistortion].contains(type)
        return EffectPreset(
            type: type,
            category: type.category,
            subtitle: subtitle(for: type),
            semanticTags: tags(for: type),
            parameters: parameters,
            isHeavy: heavy,
            renderStage: stage,
            previewSupported: true,
            renderSupported: true,
            fcpxmlCapability: .renderedFallback,
            aiUsage: EffectAIUsageMetadata(
                preferredContexts: tags(for: type),
                maximumRecommendedIntensity: guarded ? 0.52 : (heavy ? 0.58 : 0.72),
                requiresExplicitCreativeRequest: guarded
            ),
            version: 2
        )
    }

    private static let transformParameters: [RenderParameterDescriptor] = [
        RenderParameterDescriptor(key: "positionX", title: "Позиция X", range: -1...1, defaultValue: 0, valueType: .float, isAdvanced: true),
        RenderParameterDescriptor(key: "positionY", title: "Позиция Y", range: -1...1, defaultValue: 0, valueType: .float, isAdvanced: true),
        RenderParameterDescriptor(key: "scaleX", title: "Масштаб X", range: 0.1...4, defaultValue: 1, valueType: .float, isAdvanced: true),
        RenderParameterDescriptor(key: "scaleY", title: "Масштаб Y", range: 0.1...4, defaultValue: 1, valueType: .float, isAdvanced: true),
        RenderParameterDescriptor(key: "rotation", title: "Поворот", range: -360...360, defaultValue: 0, unit: "°", valueType: .angle, isAdvanced: true),
        RenderParameterDescriptor(key: "anchorX", title: "Anchor X", range: 0...1, defaultValue: 0.5, valueType: .point, isAdvanced: true),
        RenderParameterDescriptor(key: "anchorY", title: "Anchor Y", range: 0...1, defaultValue: 0.5, valueType: .point, isAdvanced: true),
        RenderParameterDescriptor(key: "cropX", title: "Crop X", range: 0...0.95, defaultValue: 0, valueType: .rect, isAdvanced: true),
        RenderParameterDescriptor(key: "cropY", title: "Crop Y", range: 0...0.95, defaultValue: 0, valueType: .rect, isAdvanced: true),
        RenderParameterDescriptor(key: "cropWidth", title: "Crop Width", range: 0.05...1, defaultValue: 1, valueType: .rect, isAdvanced: true),
        RenderParameterDescriptor(key: "cropHeight", title: "Crop Height", range: 0.05...1, defaultValue: 1, valueType: .rect, isAdvanced: true),
        RenderParameterDescriptor(key: "opacity", title: "Прозрачность", range: 0...1, defaultValue: 1, valueType: .float, isAdvanced: true)
    ]

    private static func subtitle(for type: TimelineEffectType) -> String {
        switch type.category {
        case .basic: return "Базовая коррекция изображения"
        case .cinematic: return "Тонкая обработка киноизображения"
        case .color: return "Профессиональная цветовая стилизация"
        case .blur: return "Оптическое и направленное размытие"
        case .motion: return "Движение и динамика кадра"
        case .stylized: return "Графическая стилизация"
        }
    }

    private static func tags(for type: TimelineEffectType) -> Set<String> {
        var result: Set<String> = [type.category.rawValue]
        switch type {
        case .filmGrain, .vignette, .cinematicVignette, .filmBurn: result.formUnion(["film", "memory", "cinematic"])
        case .motionBlur, .directionalBlur, .shake, .cameraDrift, .handheld, .spin, .kenBurns, .parallaxMotion: result.formUnion(["action", "movement"])
        case .glitch, .rgbSplit, .scanlines, .pixelate, .posterize, .vhsDistortion: result.formUnion(["digital", "drop", "high-energy"])
        case .lightLeak, .bloom, .glow, .fogHaze: result.formUnion(["soft", "emotion", "atmosphere"])
        case .colorGrade, .cinematicContrast, .tealOrangeGrade, .filmLook: result.formUnion(["grade", "cinematic", "travel"])
        default: break
        }
        return result
    }
}

// MARK: - Explainable semantic AI selection

public struct TransitionSemanticContext: Hashable, Sendable {
    public var sceneChanged: Bool
    public var eventOrTimeChanged: Bool
    public var energy: Double
    public var previousMovementX: Double
    public var incomingMovementX: Double
    public var previousMovementY: Double
    public var incomingMovementY: Double
    public var emotion: String?
    public var tags: Set<String>
    public var beatAccent: Bool
    public var musicDrop: Bool
    public var explicitCreativeRequest: Bool
    public var shotScaleChanged: Bool
    public var locationChanged: Bool
    public var recentStyles: [TransitionStyle]

    public init(
        sceneChanged: Bool = false,
        eventOrTimeChanged: Bool = false,
        energy: Double = 0.5,
        previousMovementX: Double = 0,
        incomingMovementX: Double = 0,
        previousMovementY: Double = 0,
        incomingMovementY: Double = 0,
        emotion: String? = nil,
        tags: Set<String> = [],
        beatAccent: Bool = false,
        musicDrop: Bool = false,
        explicitCreativeRequest: Bool = false,
        shotScaleChanged: Bool = false,
        locationChanged: Bool = false,
        recentStyles: [TransitionStyle] = []
    ) {
        self.sceneChanged = sceneChanged
        self.eventOrTimeChanged = eventOrTimeChanged
        self.energy = min(max(0, energy), 1)
        self.previousMovementX = min(max(-1, previousMovementX), 1)
        self.incomingMovementX = min(max(-1, incomingMovementX), 1)
        self.previousMovementY = min(max(-1, previousMovementY), 1)
        self.incomingMovementY = min(max(-1, incomingMovementY), 1)
        self.emotion = emotion
        self.tags = tags
        self.beatAccent = beatAccent
        self.musicDrop = musicDrop
        self.explicitCreativeRequest = explicitCreativeRequest
        self.shotScaleChanged = shotScaleChanged
        self.locationChanged = locationChanged
        self.recentStyles = Array(recentStyles.suffix(4))
    }
}

public struct TransitionSemanticDecision: Hashable, Sendable {
    public var style: TransitionStyle
    public var confidence: Double
    public var explanation: String
}

public struct TransitionSemanticSelector: Sendable {
    public init() {}

    /// Returns nil when a direct cut is more motivated. Creative/glitch
    /// families are guarded behind a high-confidence musical or explicit cue.
    public func select(for context: TransitionSemanticContext) -> TransitionSemanticDecision? {
        let x = (context.previousMovementX + context.incomingMovementX) * 0.5
        let y = (context.previousMovementY + context.incomingMovementY) * 0.5
        let coherentX = abs(x) >= 0.055 && context.previousMovementX.sign == context.incomingMovementX.sign
        let coherentY = abs(y) >= 0.055 && context.previousMovementY.sign == context.incomingMovementY.sign

        if context.explicitCreativeRequest && context.musicDrop && context.energy >= 0.78 {
            return TransitionSemanticDecision(style: .glitch, confidence: 0.82, explanation: "Glitch выбран по явному запросу на креативный акцент и музыкальному drop")
        }
        if context.musicDrop && context.energy >= 0.78 {
            return TransitionSemanticDecision(style: .exposureFlash, confidence: 0.80, explanation: "Exposure Flash подчёркивает подтверждённый музыкальный drop")
        }
        if coherentX && context.energy >= 0.64 {
            let style: TransitionStyle = x > 0 ? .whipLeft : .whipRight
            return TransitionSemanticDecision(style: style, confidence: 0.78, explanation: "Whip продолжает совпадающее горизонтальное движение соседних сцен")
        }
        if coherentY && context.energy >= 0.64 {
            let style: TransitionStyle = y > 0 ? .whipUp : .whipDown
            return TransitionSemanticDecision(style: style, confidence: 0.76, explanation: "Whip продолжает совпадающее вертикальное движение соседних сцен")
        }
        if context.eventOrTimeChanged && context.energy < 0.72 {
            return TransitionSemanticDecision(style: .fadeThroughBlack, confidence: 0.84, explanation: "Переход через чёрный обозначает смену события, места или времени")
        }
        if context.locationChanged && context.energy < 0.70 {
            let style: TransitionStyle = context.recentStyles.last == .filmDissolve ? .fadeThroughBlack : .filmDissolve
            return TransitionSemanticDecision(style: style, confidence: 0.78, explanation: "Кинорастворение отделяет новую локацию, не повторяя недавний переход")
        }
        if context.shotScaleChanged && context.energy >= 0.52 && context.energy < 0.74 {
            let style: TransitionStyle = context.recentStyles.last == .cameraPush ? .cameraPull : .cameraPush
            return TransitionSemanticDecision(style: style, confidence: 0.70, explanation: "Camera transition поддерживает мотивированную смену крупности планов")
        }
        if context.sceneChanged && context.energy <= 0.58 {
            return TransitionSemanticDecision(style: .filmDissolve, confidence: 0.73, explanation: "Плёночное растворение мягко связывает спокойную смену сцены")
        }
        if context.beatAccent && context.energy >= 0.70 {
            return TransitionSemanticDecision(style: .cameraPush, confidence: 0.72, explanation: "Camera Push поддерживает сильный музыкальный акцент и динамику кадра")
        }
        let calmEmotion = ["calm", "quiet", "nostalgic", "peaceful", "неж", "спокой", "носталь"].contains { token in
            context.emotion?.lowercased().contains(token) == true || context.tags.contains(where: { $0.lowercased().contains(token) })
        }
        if calmEmotion || context.energy < 0.42 {
            return TransitionSemanticDecision(style: .crossDissolve, confidence: 0.70, explanation: "Растворение соответствует спокойному содержанию и темпу")
        }
        return nil
    }
}

public struct EffectSemanticContext: Hashable, Sendable {
    public var isPhoto: Bool
    public var energy: Double
    public var stability: Double
    public var emotion: String?
    public var tags: Set<String>
    public var cinematicIntent: Bool
    public var explicitCreativeRequest: Bool

    public init(
        isPhoto: Bool,
        energy: Double,
        stability: Double,
        emotion: String? = nil,
        tags: Set<String> = [],
        cinematicIntent: Bool = false,
        explicitCreativeRequest: Bool = false
    ) {
        self.isPhoto = isPhoto
        self.energy = min(max(0, energy), 1)
        self.stability = min(max(0, stability), 1)
        self.emotion = emotion
        self.tags = tags
        self.cinematicIntent = cinematicIntent
        self.explicitCreativeRequest = explicitCreativeRequest
    }
}

public struct EffectSemanticDecision: Hashable, Sendable {
    public var type: TimelineEffectType
    public var confidence: Double
    public var explanation: String
}

public struct EffectSemanticSelector: Sendable {
    public init() {}

    /// Conservative by design: nil means the scene is stronger without an
    /// effect. Stylized effects require an explicit creative/digital cue.
    public func select(for context: EffectSemanticContext) -> EffectSemanticDecision? {
        let normalizedTags = Set(context.tags.map { $0.lowercased() })
        let emotion = context.emotion?.lowercased() ?? ""
        let memory = normalizedTags.contains(where: { $0.contains("memory") || $0.contains("archive") || $0.contains("носталь") }) || emotion.contains("носталь")
        let digital = normalizedTags.contains(where: { $0.contains("digital") || $0.contains("tech") || $0.contains("game") })
        if context.explicitCreativeRequest && digital && context.energy >= 0.72 {
            return EffectSemanticDecision(type: .rgbSplit, confidence: 0.80, explanation: "RGB Split разрешён явным digital-запросом и высокой энергией сцены")
        }
        if memory && context.cinematicIntent {
            return EffectSemanticDecision(type: .filmGrain, confidence: 0.76, explanation: "Лёгкое плёночное зерно поддерживает память/архивный характер сцены")
        }
        if context.isPhoto && context.energy < 0.58 {
            return EffectSemanticDecision(type: .cameraDrift, confidence: 0.70, explanation: "Мягкий Camera Drift оживляет неподвижный кадр без декоративной перегрузки")
        }
        if !context.isPhoto && context.energy >= 0.78 && context.stability >= 0.62 {
            return EffectSemanticDecision(type: .motionBlur, confidence: 0.68, explanation: "Умеренный Motion Blur поддерживает измеренное быстрое движение стабильного кадра")
        }
        return nil
    }
}
