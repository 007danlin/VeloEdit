import Foundation

// MARK: - Keyframes

public enum KeyframeEasing: String, Codable, CaseIterable, Identifiable, Sendable {
    case linear
    case easeIn = "ease-in"
    case easeOut = "ease-out"
    case easeInOut = "ease-in-out"
    case cubic
    case back
    case elastic
    case bounce

    public var id: String { rawValue }
    public var localizedTitle: String {
        switch self {
        case .linear: return "Линейно"
        case .easeIn: return "Плавный разгон"
        case .easeOut: return "Плавное завершение"
        case .easeInOut: return "Плавно с двух сторон"
        case .cubic: return "Кубическая"
        case .back: return "С возвратом"
        case .elastic: return "Упругая"
        case .bounce: return "Отскок"
        }
    }

    /// Converts linear segment progress to a stable, bounded easing curve.
    /// Cubic smoothstep is used for ease-in-out so preview, export and tests
    /// share one deterministic implementation.
    public func transform(_ progress: Double) -> Double {
        let value = min(max(0, progress), 1)
        if value <= 0 { return 0 }
        if value >= 1 { return 1 }
        switch self {
        case .linear: return value
        case .easeIn: return value * value * value
        case .easeOut:
            let inverse = 1 - value
            return 1 - inverse * inverse * inverse
        case .easeInOut: return value * value * (3 - 2 * value)
        case .cubic:
            return value < 0.5
                ? 4 * value * value * value
                : 1 - pow(-2 * value + 2, 3) / 2
        case .back:
            // Bounded "back" keeps pixels and numeric parameters safe while
            // preserving the characteristic anticipation of the curve.
            let c1 = 1.70158
            let c3 = c1 + 1
            return min(max(0, c3 * value * value * value - c1 * value * value), 1)
        case .elastic:
            guard value > 0, value < 1 else { return value }
            let oscillation = pow(2, -10 * value) * sin((value * 10 - 0.75) * (2 * .pi / 3)) + 1
            return min(max(0, oscillation), 1)
        case .bounce:
            let n1 = 7.5625
            let d1 = 2.75
            if value < 1 / d1 { return n1 * value * value }
            if value < 2 / d1 {
                let shifted = value - 1.5 / d1
                return n1 * shifted * shifted + 0.75
            }
            if value < 2.5 / d1 {
                let shifted = value - 2.25 / d1
                return n1 * shifted * shifted + 0.9375
            }
            let shifted = value - 2.625 / d1
            return n1 * shifted * shifted + 0.984375
        }
    }
}

// MARK: - Typed effect values

public enum EffectParameterValueType: String, Codable, CaseIterable, Identifiable, Sendable {
    case float, int, bool, angle, color, point, size, rect, enumeration
    public var id: String { rawValue }
    public var supportsKeyframes: Bool {
        switch self {
        case .float, .int, .angle, .color, .point, .size, .rect: return true
        case .bool, .enumeration: return false
        }
    }
}

public struct EffectColorValue: Codable, Hashable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double
    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red.clamped01; self.green = green.clamped01; self.blue = blue.clamped01; self.alpha = alpha.clamped01
    }
}

public struct EffectPointValue: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x.isFinite ? x : 0; self.y = y.isFinite ? y : 0 }
}

public struct EffectSizeValue: Codable, Hashable, Sendable {
    public var width: Double
    public var height: Double
    public init(width: Double, height: Double) { self.width = width.isFinite ? width : 0; self.height = height.isFinite ? height : 0 }
}

public struct EffectRectValue: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x.isFinite ? x : 0; self.y = y.isFinite ? y : 0
        self.width = width.isFinite ? width : 0; self.height = height.isFinite ? height : 0
    }
}

public enum EffectParameterValue: Codable, Hashable, Sendable {
    case float(Double)
    case int(Int)
    case bool(Bool)
    case angle(Double)
    case color(EffectColorValue)
    case point(EffectPointValue)
    case size(EffectSizeValue)
    case rect(EffectRectValue)
    case enumeration(String)

    public var valueType: EffectParameterValueType {
        switch self {
        case .float: return .float
        case .int: return .int
        case .bool: return .bool
        case .angle: return .angle
        case .color: return .color
        case .point: return .point
        case .size: return .size
        case .rect: return .rect
        case .enumeration: return .enumeration
        }
    }

    /// Numeric projection used by the native compositor. Compound values keep
    /// their complete typed payload and expose their first component only to
    /// legacy scalar render code.
    public var numericValue: Double {
        switch self {
        case .float(let value), .angle(let value): return value
        case .int(let value): return Double(value)
        case .bool(let value): return value ? 1 : 0
        case .color(let value): return value.red
        case .point(let value): return value.x
        case .size(let value): return value.width
        case .rect(let value): return value.x
        case .enumeration(let value): return Double(value) ?? 0
        }
    }

    public static func scalar(_ value: Double, as type: EffectParameterValueType) -> EffectParameterValue {
        switch type {
        case .float: return .float(value)
        case .int: return .int(Int(value.rounded()))
        case .bool: return .bool(value >= 0.5)
        case .angle: return .angle(value)
        case .color: return .color(EffectColorValue(red: value, green: value, blue: value))
        case .point: return .point(EffectPointValue(x: value, y: value))
        case .size: return .size(EffectSizeValue(width: value, height: value))
        case .rect: return .rect(EffectRectValue(x: value, y: value, width: 1, height: 1))
        case .enumeration: return .enumeration(String(value))
        }
    }
}

public struct EffectKeyframe: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var parameter: String
    /// Seconds relative to the beginning of the effect.
    public var time: Double
    public var value: Double
    /// Optional typed payload. Missing in legacy projects; `value` remains the
    /// scalar compatibility representation used by older manifests.
    public var typedValue: EffectParameterValue?
    public var easing: KeyframeEasing

    public init(
        id: UUID = UUID(),
        parameter: String,
        time: Double,
        value: Double,
        easing: KeyframeEasing = .linear,
        typedValue: EffectParameterValue? = nil
    ) {
        self.id = id
        self.parameter = parameter
        self.time = max(0, time)
        self.value = value.isFinite ? value : 0
        self.typedValue = typedValue
        self.easing = easing
    }

    public var effectiveNumericValue: Double { typedValue?.numericValue ?? value }
}

public struct EffectParameter: Codable, Identifiable, Hashable, Sendable {
    public var name: String
    public var value: Double
    public var valueType: EffectParameterValueType?
    public var typedValue: EffectParameterValue?
    public var id: String { name }

    public init(
        name: String,
        value: Double,
        valueType: EffectParameterValueType? = nil,
        typedValue: EffectParameterValue? = nil
    ) {
        self.name = name
        self.value = value.isFinite ? value : 0
        self.valueType = valueType ?? typedValue?.valueType
        self.typedValue = typedValue ?? valueType.map { EffectParameterValue.scalar(self.value, as: $0) }
    }


    public init(name: String, typedValue: EffectParameterValue) {
        self.init(name: name, value: typedValue.numericValue, valueType: typedValue.valueType, typedValue: typedValue)
    }

    public var effectiveNumericValue: Double { typedValue?.numericValue ?? value }
}

// MARK: - Standalone effects

public enum TimelineEffectCategory: String, Codable, CaseIterable, Identifiable, Sendable {
    case basic, cinematic, color, blur, motion, stylized
    public var id: String { rawValue }

    public var localizedTitle: String {
        switch self {
        case .basic: return "Основные"
        case .cinematic: return "Кино"
        case .color: return "Цвет"
        case .blur: return "Размытие"
        case .motion: return "Движение"
        case .stylized: return "Стилизация"
        }
    }
}

public enum TimelineEffectType: String, Codable, CaseIterable, Identifiable, Sendable {
    case zoom, pushIn = "push-in", pullOut = "pull-out", pan, shake, motionBlur = "motion-blur"
    case blur, directionalBlur = "directional-blur", backgroundBlur = "background-blur"
    case exposure, contrast, saturation, temperature, vignette, grain
    case fade, light, flash, glow
    case brightness, vibrance, tint, highlights, shadows, sharpness, opacity
    case filmGrain = "film-grain", cinematicVignette = "cinematic-vignette", cinematicMotionBlur = "cinematic-motion-blur"
    case bloom, lensBlur = "lens-blur", softFocus = "soft-focus", letterbox, colorGrade = "color-grade"
    case cinematicContrast = "cinematic-contrast", tealOrangeGrade = "teal-orange-grade", vintage, filmLook = "film-look"
    case cameraDrift = "camera-drift", handheld, spin, kenBurns = "ken-burns", parallaxMotion = "parallax-motion"
    case zoomBlur = "zoom-blur", radialBlur = "radial-blur"
    case chromaticAberration = "chromatic-aberration", lensDistortion = "lens-distortion", fisheye, barrelDistortion = "barrel-distortion"
    case glitch, rgbSplit = "rgb-split", scanlines, pixelate, posterize, halftone, vhsDistortion = "vhs-distortion"
    case lightLeak = "light-leak", filmBurn = "film-burn", dust, noise, fogHaze = "fog-haze"

    public var id: String { rawValue }
    public var category: TimelineEffectCategory {
        switch self {
        case .brightness, .contrast, .exposure, .saturation, .vibrance, .temperature, .tint,
             .highlights, .shadows, .sharpness, .fade, .opacity: return .basic
        case .filmGrain, .vignette, .cinematicVignette, .bloom, .glow, .softFocus,
             .letterbox, .cinematicContrast, .vintage, .filmLook: return .cinematic
        case .colorGrade, .tealOrangeGrade: return .color
        case .blur, .backgroundBlur, .lensBlur, .directionalBlur, .motionBlur,
             .cinematicMotionBlur, .zoomBlur, .radialBlur: return .blur
        case .zoom, .pushIn, .pullOut, .pan, .shake, .cameraDrift, .handheld,
             .spin, .kenBurns, .parallaxMotion: return .motion
        case .chromaticAberration, .lensDistortion, .fisheye, .barrelDistortion,
             .glitch, .rgbSplit, .scanlines, .pixelate, .posterize, .halftone, .vhsDistortion,
             .lightLeak, .filmBurn, .dust, .noise, .fogHaze, .grain, .light, .flash: return .stylized
        }
    }

    public var localizedTitle: String {
        switch self {
        case .zoom: return "Масштабирование"
        case .pushIn: return "Наезд"
        case .pullOut: return "Отъезд"
        case .pan: return "Панорама"
        case .shake: return "Дрожание"
        case .motionBlur: return "Размытие в движении"
        case .blur: return "Размытие"
        case .directionalBlur: return "Направленное размытие"
        case .backgroundBlur: return "Размытие фона"
        case .exposure: return "Экспозиция"
        case .contrast: return "Контраст"
        case .saturation: return "Насыщенность"
        case .temperature: return "Температура"
        case .vignette: return "Виньетка"
        case .grain: return "Зерно"
        case .fade: return "Затемнение"
        case .light: return "Свет"
        case .flash: return "Вспышка"
        case .glow: return "Свечение"
        case .brightness: return "Яркость"
        case .vibrance: return "Живость цвета"
        case .tint: return "Оттенок"
        case .highlights: return "Света"
        case .shadows: return "Тени"
        case .sharpness: return "Резкость"
        case .opacity: return "Прозрачность"
        case .filmGrain: return "Плёночное зерно"
        case .cinematicVignette: return "Мягкая виньетка"
        case .cinematicMotionBlur: return "Мягкое размытие движения"
        case .bloom: return "Bloom"
        case .lensBlur: return "Lens Blur"
        case .softFocus: return "Мягкий фокус"
        case .letterbox: return "Киношные полосы"
        case .colorGrade: return "Color Grade"
        case .cinematicContrast: return "Киноконтраст"
        case .tealOrangeGrade: return "Teal & Orange"
        case .vintage: return "Vintage"
        case .filmLook: return "Film Look"
        case .cameraDrift: return "Дрейф камеры"
        case .handheld: return "Ручная камера"
        case .spin: return "Вращение"
        case .kenBurns: return "Ken Burns"
        case .parallaxMotion: return "Параллакс"
        case .zoomBlur: return "Zoom Blur"
        case .radialBlur: return "Радиальное размытие"
        case .chromaticAberration: return "Хроматическая аберрация"
        case .lensDistortion: return "Искажение объектива"
        case .fisheye: return "Рыбий глаз"
        case .barrelDistortion: return "Бочкообразное искажение"
        case .glitch: return "Glitch"
        case .rgbSplit: return "RGB Split"
        case .scanlines: return "Строки сканирования"
        case .pixelate: return "Пикселизация"
        case .posterize: return "Постеризация"
        case .halftone: return "Полутон"
        case .vhsDistortion: return "VHS"
        case .lightLeak: return "Light Leak"
        case .filmBurn: return "Film Burn"
        case .dust: return "Пыль"
        case .noise: return "Шум"
        case .fogHaze: return "Туман / дымка"
        }
    }

    public var defaultIntensity: Double {
        switch self {
        case .flash: return 0.55
        case .cinematicVignette, .cinematicMotionBlur, .filmGrain, .dust, .fogHaze: return 0.24
        default: return 0.5
        }
    }
}

public struct EffectTimelineItem: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var effectType: TimelineEffectType
    public var startTime: Double
    public var duration: Double
    public var track: Int
    public var parameters: [EffectParameter]
    public var intensity: Double
    public var keyframes: [EffectKeyframe]
    public var enabled: Bool
    public var targetClipID: UUID?
    public var targetTrack: Int?
    /// Explicit per-clip stack order. Optional so legacy projects keep their
    /// serialized array order until the user or preset first reorders them.
    public var stackOrder: Int?
    /// Preset metadata keeps the renderer's editable component effects
    /// independent while allowing the editor to present one preset instance
    /// as a single Timeline block.
    public var effectStackPresetID: String?
    public var effectStackPresetInstanceID: UUID?
    public var explanation: [String]

    public init(
        id: UUID = UUID(),
        effectType: TimelineEffectType,
        startTime: Double,
        duration: Double,
        track: Int = 0,
        parameters: [EffectParameter] = [],
        intensity: Double? = nil,
        keyframes: [EffectKeyframe] = [],
        enabled: Bool = true,
        targetClipID: UUID? = nil,
        targetTrack: Int? = nil,
        stackOrder: Int? = nil,
        effectStackPresetID: String? = nil,
        effectStackPresetInstanceID: UUID? = nil,
        explanation: [String] = []
    ) {
        self.id = id
        self.effectType = effectType
        self.startTime = max(0, startTime)
        self.duration = max(0.05, duration)
        self.track = max(0, track)
        self.parameters = parameters
        self.intensity = min(max(0, intensity ?? effectType.defaultIntensity), 1)
        self.keyframes = keyframes.sorted { $0.time < $1.time }
        self.enabled = enabled
        self.targetClipID = targetClipID
        self.targetTrack = targetTrack
        self.stackOrder = stackOrder.map { max(0, $0) }
        self.effectStackPresetID = effectStackPresetID
        self.effectStackPresetInstanceID = effectStackPresetInstanceID
        self.explanation = explanation
    }

    public var endTime: Double { startTime + duration }

    public func affects(clipID: UUID, clipTrack: Int = 0, timelineTime: Double) -> Bool {
        enabled && timelineTime >= startTime && timelineTime <= endTime &&
            (targetClipID == nil || targetClipID == clipID) &&
            (targetTrack == nil || targetTrack == clipTrack)
    }

    public func parameterValue(_ name: String, at timelineTime: Double) -> Double {
        let base = parameters.first(where: { $0.name == name })?.effectiveNumericValue
            ?? (name == "intensity" ? intensity : EffectPresetRegistry.preset(for: effectType).parameter(named: name)?.defaultValue ?? 0)
        let localTime = min(max(0, timelineTime - startTime), duration)
        let values = keyframes.filter { $0.parameter == name }.sorted { $0.time < $1.time }
        guard let first = values.first else { return base }
        if localTime <= first.time { return first.effectiveNumericValue }
        guard let last = values.last, localTime < last.time else { return values.last?.effectiveNumericValue ?? base }
        guard let rightIndex = values.firstIndex(where: { $0.time >= localTime }), rightIndex > 0 else { return base }
        let left = values[rightIndex - 1]
        let right = values[rightIndex]
        let span = max(0.000_001, right.time - left.time)
        let progress = left.easing.transform((localTime - left.time) / span)
        return left.effectiveNumericValue + (right.effectiveNumericValue - left.effectiveNumericValue) * progress
    }
}

// MARK: - Editable transitions

public enum TransitionDirection: String, Codable, CaseIterable, Identifiable, Sendable {
    case automatic, left, right, up, down, inward, outward
    public var id: String { rawValue }
    public var localizedTitle: String {
        switch self {
        case .automatic: return "Авто"
        case .left: return "Влево"
        case .right: return "Вправо"
        case .up: return "Вверх"
        case .down: return "Вниз"
        case .inward: return "Внутрь"
        case .outward: return "Наружу"
        }
    }
}

public struct TimelineTransitionItem: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var style: TransitionStyle
    public var outgoingClipID: UUID
    public var incomingClipID: UUID
    public var startTime: Double
    public var duration: Double
    public var enabled: Bool
    /// Optional fields preserve compatibility with projects saved before the
    /// professional transition Inspector was introduced.
    public var intensity: Double?
    public var parameters: [EffectParameter]?
    public var direction: TransitionDirection?
    public var easing: KeyframeEasing?
    public var explanation: [String]

    public init(
        id: UUID = UUID(),
        style: TransitionStyle,
        outgoingClipID: UUID,
        incomingClipID: UUID,
        startTime: Double,
        duration: Double = 0.45,
        enabled: Bool = true,
        intensity: Double? = nil,
        parameters: [EffectParameter]? = nil,
        direction: TransitionDirection? = nil,
        easing: KeyframeEasing? = nil,
        explanation: [String] = []
    ) {
        self.id = id
        self.style = style
        self.outgoingClipID = outgoingClipID
        self.incomingClipID = incomingClipID
        self.startTime = max(0, startTime)
        self.duration = min(max(0.08, duration), 4)
        self.enabled = enabled
        self.intensity = min(max(0, intensity ?? TransitionPresetRegistry.preset(for: style).defaultIntensity), 1)
        self.parameters = parameters ?? TransitionPresetRegistry.preset(for: style).defaultParameters
        self.direction = direction
        self.easing = easing
        self.explanation = explanation
    }

    public var effectiveIntensity: Double {
        min(max(0, intensity ?? TransitionPresetRegistry.preset(for: style).defaultIntensity), 1)
    }

    public var effectiveParameters: [EffectParameter] {
        parameters ?? TransitionPresetRegistry.preset(for: style).defaultParameters
    }

    public var effectiveDirection: TransitionDirection {
        direction ?? TransitionPresetRegistry.preset(for: style).defaultDirection
    }

    public var effectiveEasing: KeyframeEasing {
        easing ?? TransitionPresetRegistry.preset(for: style).defaultEasing
    }

    public func parameterValue(_ name: String) -> Double {
        if name == "intensity" { return effectiveIntensity }
        return effectiveParameters.first(where: { $0.name == name })?.effectiveNumericValue
            ?? TransitionPresetRegistry.preset(for: style).parameter(named: name)?.defaultValue
            ?? 0
    }
}

// MARK: - Titles, cards and word-level captions

public enum TitleCategory: String, Codable, CaseIterable, Identifiable, Sendable {
    case basic, cinematic, dynamic, captions, cards
    public var id: String { rawValue }

    public var localizedTitle: String {
        switch self {
        case .basic: return "Основные"
        case .cinematic: return "Кинематографичные"
        case .dynamic: return "Динамические"
        case .captions: return "Субтитры"
        case .cards: return "Карточки"
        }
    }
}

public enum TitleTimelineKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case title, subtitle, lowerThird = "lower-third"
    case cinematicTitle = "cinematic-title", location, date, chapter
    case animatedTitle = "animated-title", keywordOverlay = "keyword-overlay", kineticText = "kinetic-text"
    case automaticSubtitles = "automatic-subtitles", wordLevelCaptions = "word-level-captions"
    case titleCard = "title-card", endCard = "end-card"

    public var id: String { rawValue }
    public var category: TitleCategory {
        switch self {
        case .title, .subtitle, .lowerThird: return .basic
        case .cinematicTitle, .location, .date, .chapter: return .cinematic
        case .animatedTitle, .keywordOverlay, .kineticText: return .dynamic
        case .automaticSubtitles, .wordLevelCaptions: return .captions
        case .titleCard, .endCard: return .cards
        }
    }

    public var localizedTitle: String {
        switch self {
        case .title: return "Заголовок"
        case .subtitle: return "Подзаголовок"
        case .lowerThird: return "Нижняя треть"
        case .cinematicTitle: return "Кинематографичный титр"
        case .location: return "Место"
        case .date: return "Дата"
        case .chapter: return "Глава"
        case .animatedTitle: return "Анимированный титр"
        case .keywordOverlay: return "Ключевое слово"
        case .kineticText: return "Кинетический текст"
        case .automaticSubtitles: return "Автоматические субтитры"
        case .wordLevelCaptions: return "Подсветка по словам"
        case .titleCard: return "Титульная карточка"
        case .endCard: return "Финальная карточка"
        }
    }
}

public struct CaptionWord: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var word: String
    /// Seconds relative to the title/caption item.
    public var start: Double
    public var end: Double

    public init(id: UUID = UUID(), word: String, start: Double, end: Double) {
        self.id = id
        self.word = word
        self.start = max(0, start)
        self.end = max(self.start, end)
    }
}

public enum TitleAnimationKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case none, fade, slide, scale, kinetic
    public var id: String { rawValue }
}

public struct TitleAnimation: Codable, Hashable, Sendable {
    public var entrance: TitleAnimationKind
    public var exit: TitleAnimationKind
    public var duration: Double
    public var easing: KeyframeEasing

    public init(entrance: TitleAnimationKind = .fade, exit: TitleAnimationKind = .fade, duration: Double = 0.35, easing: KeyframeEasing = .easeInOut) {
        self.entrance = entrance
        self.exit = exit
        self.duration = min(max(0, duration), 4)
        self.easing = easing
    }
}

public struct TitleTimelineItem: Codable, Identifiable, Hashable, Sendable {
    public var speechAnchor: SpeechCaptionAnchor?
    public var filmPartID: UUID?
    public var id: UUID
    public var kind: TitleTimelineKind
    /// Stable identifier of the complete visual composition. A nil value is
    /// preserved for projects created before Title Templates and resolves via
    /// the deterministic kind-to-template migration in TitleTemplateRegistry.
    public var templateID: String?
    public var text: String
    public var additionalText: String?
    public var callToAction: String?
    public var chapterNumber: Int?
    public var startTime: Double
    public var duration: Double
    public var track: Int
    public var style: TitleStyle
    public var animation: TitleAnimation
    public var words: [CaptionWord]
    public var activeWordHighlighting: Bool
    public var enabled: Bool
    public var targetClipID: UUID?
    /// A generated heading may span cuts within its confirmed scene. Keep its
    /// attachment separate from the compositor's single-clip visibility mask.
    public var anchorClipID: UUID?
    public var effectiveAnchorClipID: UUID? { anchorClipID ?? targetClipID }
    public var explanation: [String]
    /// An edited automatic title is now authoritative user content. Optional
    /// so existing project files continue to decode without migration.
    public var userEdited: Bool?

    public init(
        id: UUID = UUID(),
        kind: TitleTimelineKind,
        templateID: String? = nil,
        text: String,
        additionalText: String? = nil,
        callToAction: String? = nil,
        chapterNumber: Int? = nil,
        startTime: Double,
        duration: Double,
        track: Int = 0,
        style: TitleStyle = TitleStyle(),
        animation: TitleAnimation = TitleAnimation(),
        words: [CaptionWord] = [],
        activeWordHighlighting: Bool = true,
        enabled: Bool = true,
        targetClipID: UUID? = nil,
        explanation: [String] = []
    ) {
        self.id = id
        self.kind = kind
        self.templateID = templateID
        self.text = text
        self.additionalText = additionalText
        self.callToAction = callToAction
        self.chapterNumber = chapterNumber.map { min(999, max(1, $0)) }
        self.startTime = max(0, startTime)
        self.duration = max(0.05, duration)
        self.track = max(0, track)
        self.style = style
        self.animation = animation
        self.words = words.sorted { $0.start < $1.start }
        self.activeWordHighlighting = activeWordHighlighting
        self.enabled = enabled
        self.targetClipID = targetClipID
        self.explanation = explanation
        self.userEdited = nil
    }

    public var endTime: Double { startTime + duration }
    public var effectiveTemplateID: String? {
        templateID ?? TitleTemplateRegistry.defaultTemplate(for: kind)?.id
    }
    public var primaryText: String {
        get { text }
        set { text = newValue }
    }
    public var effectiveChapterNumber: Int {
        if let chapterNumber { return min(999, max(1, chapterNumber)) }
        // Older Chapter items kept their only editable number in the subtitle.
        if let additionalText,
           additionalText.range(of: #"(?i)^\s*(глава|chapter)\s+\d{1,3}\s*$"#, options: .regularExpression) != nil,
           let number = additionalText.split(whereSeparator: { !$0.isNumber }).last.flatMap({ Int($0) }) {
            return min(999, max(1, number))
        }
        return 1
    }

    public var formattedChapterNumber: String { String(format: "%02d", effectiveChapterNumber) }

    public mutating func setChapterNumber(_ number: Int) {
        chapterNumber = min(999, max(1, number))
        if let additionalText,
           additionalText.range(of: #"(?i)^\s*(глава|chapter)\s+\d{1,3}\s*$"#, options: .regularExpression) != nil {
            self.additionalText = additionalText.replacingOccurrences(of: #"\d{1,3}"#, with: formattedChapterNumber, options: .regularExpression)
        }
    }
    public var secondaryText: String? {
        get { additionalText }
        set { additionalText = newValue }
    }
    public func activeWord(at timelineTime: Double) -> CaptionWord? {
        let local = timelineTime - startTime
        return words.first { local >= $0.start && local < $0.end }
    }

    /// Locate words in sequence so repeated words highlight their own glyphs.
    /// If an edited caption no longer matches the measured words, omit the
    /// highlight instead of assigning timing to unrelated text.
    public func activeWordRange(at timelineTime: Double) -> NSRange? {
        guard let active = activeWord(at: timelineTime) else { return nil }
        let string = text as NSString
        var cursor = 0
        for word in words {
            let range = string.range(of: word.word, options: .caseInsensitive,
                                     range: NSRange(location: cursor, length: string.length - cursor))
            guard range.location != NSNotFound else { return nil }
            if word.id == active.id { return range }
            cursor = NSMaxRange(range)
        }
        return nil
    }
}

public extension Array where Element == EffectTimelineItem {
    func active(at timelineTime: Double, for clipID: UUID, clipTrack: Int = 0) -> [EffectTimelineItem] {
        filter { $0.affects(clipID: clipID, clipTrack: clipTrack, timelineTime: timelineTime) }
            .sorted { $0.track == $1.track ? $0.startTime < $1.startTime : $0.track < $1.track }
    }
}
