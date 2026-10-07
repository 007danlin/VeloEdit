import Foundation

public enum TelemetrySourceFormat: String, Codable, CaseIterable, Identifiable, Sendable {
    case embeddedGPMF = "embedded-gpmf"
    case embeddedDJI = "embedded-dji"
    case embeddedInsta360 = "embedded-insta360"
    case embeddedCamera = "embedded-camera"
    case embeddedQuickTime = "embedded-quicktime"
    case gpx
    case fit
    case srt
    case csv
    case vbo

    public var id: String { rawValue }
    public var localizedTitle: String {
        switch self {
        case .embeddedGPMF: return "GoPro GPMF"
        case .embeddedDJI: return "DJI embedded"
        case .embeddedInsta360: return "Insta360 embedded"
        case .embeddedCamera: return "Телеметрия камеры"
        case .embeddedQuickTime: return "Метаданные смартфона"
        case .gpx: return "GPX"
        case .fit: return "FIT"
        case .srt: return "SRT"
        case .csv: return "CSV"
        case .vbo: return "VBO"
        }
    }
}

public enum TelemetrySynchronizationMethod: String, Codable, CaseIterable, Sendable {
    case embeddedTimecode = "embedded-timecode"
    case cameraTimestamp = "camera-timestamp"
    case telemetryTimestamp = "telemetry-timestamp"
    case gpsTimestamp = "gps-timestamp"
    case filenameTimestamp = "filename-timestamp"
    case manualOffset = "manual-offset"

    public var localizedTitle: String {
        switch self {
        case .embeddedTimecode: return "Таймкод камеры"
        case .cameraTimestamp: return "Дата камеры"
        case .telemetryTimestamp: return "Дата телеметрии"
        case .gpsTimestamp: return "GPS-время"
        case .filenameTimestamp: return "Дата в имени файла"
        case .manualOffset: return "Ручное смещение"
        }
    }
}

public enum TelemetryCSVField: String, Codable, CaseIterable, Identifiable, Sendable {
    case ignore
    case timestamp
    case latitude
    case longitude
    case speedMetersPerSecond = "speed-mps"
    case speedKilometersPerHour = "speed-kmh"
    case altitudeMeters = "altitude-m"
    case distanceMeters = "distance-m"
    case headingDegrees = "heading-deg"
    case gForce = "g-force"
    case heartRate = "heart-rate"
    case cadence
    case powerWatts = "power-watts"

    public var id: String { rawValue }
    public var localizedTitle: String {
        switch self {
        case .ignore: return "Не использовать"
        case .timestamp: return "Время / timestamp"
        case .latitude: return "Широта"
        case .longitude: return "Долгота"
        case .speedMetersPerSecond: return "Скорость, м/с"
        case .speedKilometersPerHour: return "Скорость, км/ч"
        case .altitudeMeters: return "Высота, м"
        case .distanceMeters: return "Дистанция, м"
        case .headingDegrees: return "Курс, °"
        case .gForce: return "Перегрузка, g"
        case .heartRate: return "Пульс, bpm"
        case .cadence: return "Каденс, rpm"
        case .powerWatts: return "Мощность, W"
        }
    }
}

public struct TelemetrySynchronization: Codable, Hashable, Sendable {
    /// Telemetry time sampled at video time zero. Negative values are valid
    /// when telemetry starts after the picture.
    public var offsetSeconds: Double
    public var method: TelemetrySynchronizationMethod
    public var confidence: Double
    public var frameRate: Double?

    public init(
        offsetSeconds: Double = 0,
        method: TelemetrySynchronizationMethod = .manualOffset,
        confidence: Double = 0,
        frameRate: Double? = nil
    ) {
        self.offsetSeconds = offsetSeconds.isFinite ? offsetSeconds : 0
        self.method = method
        self.confidence = min(max(0, confidence), 1)
        self.frameRate = frameRate?.isFinite == true ? frameRate : nil
    }
}

public struct TelemetrySource: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var originalURL: URL?
    public var bookmarkData: Data?
    public var displayName: String
    public var format: TelemetrySourceFormat
    public var linkedAssetID: UUID?
    public var importedAt: Date
    public var startDate: Date?
    public var summary: TelemetrySummary
    public var synchronization: TelemetrySynchronization

    public init(
        id: UUID = UUID(),
        originalURL: URL? = nil,
        bookmarkData: Data? = nil,
        displayName: String,
        format: TelemetrySourceFormat,
        linkedAssetID: UUID? = nil,
        importedAt: Date = Date(),
        startDate: Date? = nil,
        summary: TelemetrySummary,
        synchronization: TelemetrySynchronization = TelemetrySynchronization()
    ) {
        self.id = id
        self.originalURL = originalURL?.standardizedFileURL
        self.bookmarkData = bookmarkData
        self.displayName = displayName
        self.format = format
        self.linkedAssetID = linkedAssetID
        self.importedAt = importedAt
        self.startDate = startDate
        self.summary = summary
        self.synchronization = synchronization
    }

    public var duration: Double {
        guard let samples = summary.timedSamples, let first = samples.first, let last = samples.last else { return 0 }
        return max(0, last.timestamp - first.timestamp)
    }
}

public enum TelemetryWidgetStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    // Original OVRLEY templates bundled in ThirdParty/OVRLEY/templates.
    case acidTitanium = "acid-titanium"
    case breezeBlue = "breeze-blue"
    case burntOrange = "burnt-orange"
    case champagneBasic = "champagne-basic"
    case champagneBorders = "champagne-borders"
    case champagneShadows = "champagne-shadows"
    case futuristicHUD = "futuristic-hud"
    case lavenderGradient = "lavender-gradient"
    case safaBrian = "safa-brian"
    case whiteVAM = "white-with-vam"
    case whiteOpacity = "white-opacity"
    case whiteShadows = "white-shadows"

    // Kept for projects made before the full OVRLEY catalogue was exposed.
    case minimal
    case cinematic
    case action
    case racing
    case goPro = "gopro-like"
    case cleanApple = "clean-apple"
    case digital
    case circular
    case horizontal
    case compact

    public var id: String { rawValue }
    public var localizedTitle: String {
        switch self {
        case .acidTitanium: return "Acid Titanium"
        case .breezeBlue: return "Breeze Blue"
        case .burntOrange: return "Burnt Orange"
        case .champagneBasic: return "Champagne Basic"
        case .champagneBorders: return "Champagne Borders"
        case .champagneShadows: return "Champagne Shadows"
        case .futuristicHUD: return "Futuristic HUD"
        case .lavenderGradient: return "Lavender Gradient"
        case .safaBrian: return "Safa Brian"
        case .whiteVAM: return "White + VAM"
        case .whiteOpacity: return "White Opacity"
        case .whiteShadows: return "White Shadows"
        case .minimal: return "Минималистичный"
        case .cinematic: return "Кинематографичный"
        case .action: return "Динамичный"
        case .racing: return "Гоночный"
        case .goPro: return "GoPro-like"
        case .cleanApple: return "Чистый Apple-style"
        case .digital: return "Цифровой"
        case .circular: return "Круговой"
        case .horizontal: return "Горизонтальный"
        case .compact: return "Компактный"
        }
    }

    public static let ovrleyTemplates: [TelemetryWidgetStyle] = [
        .acidTitanium, .breezeBlue, .burntOrange, .champagneBasic,
        .champagneBorders, .champagneShadows, .futuristicHUD,
        .lavenderGradient, .safaBrian, .whiteVAM, .whiteOpacity,
        .whiteShadows
    ]

    public var isOVRLEYTemplate: Bool { Self.ovrleyTemplates.contains(self) }
}

/// The actual display types exposed by OVRLEY. The segmented and reversed
/// entries are first-class presets of OVRLEY's configurable linear/arc gauge,
/// so users can see and drag them without rebuilding the gauge manually.
public enum TelemetryWidgetPresentation: String, Codable, CaseIterable, Identifiable, Sendable {
    case text
    case linear
    case linearSegmented = "linear-segmented"
    case arc
    case arcReverse = "arc-reverse"
    case arcSegmented = "arc-segmented"
    case arcSegmentedDense = "arc-segmented-dense"
    case corner
    case headingTape = "heading-tape"
    case gForce = "g-force"
    case leanAngle = "lean-angle"
    case lapCurrent = "lap-current"
    case lapBest = "lap-best"
    case lapDelta = "lap-delta"
    case lapLog = "lap-log"
    case routePlot = "route-plot"
    case elevationPlot = "elevation-plot"

    public var id: String { rawValue }
    public var localizedTitle: String {
        switch self {
        case .text: return "Число"
        case .linear: return "Линейная шкала"
        case .linearSegmented: return "Сегменты"
        case .arc: return "Дуга"
        case .arcReverse: return "Обратная дуга"
        case .arcSegmented: return "Сегментная дуга"
        case .arcSegmentedDense: return "Частая дуга"
        case .corner: return "Угловая шкала"
        case .headingTape: return "Лента курса"
        case .gForce: return "G-Force XY"
        case .leanAngle: return "Угол наклона"
        case .lapCurrent: return "Текущий круг"
        case .lapBest: return "Лучший круг"
        case .lapDelta: return "Дельта круга"
        case .lapLog: return "Журнал кругов"
        case .routePlot: return "Маршрут"
        case .elevationPlot: return "Профиль высоты"
        }
    }
}

public enum TelemetryWidgetCategory: String, CaseIterable, Identifiable, Sendable {
    case general, cycling, running, motorsports, camera, other

    public var id: String { rawValue }
    public var localizedTitle: String {
        switch self {
        case .general: return "Основные"
        case .cycling: return "Велоспорт"
        case .running: return "Бег"
        case .motorsports: return "Мотоспорт"
        case .camera: return "Камера"
        case .other: return "Другое"
        }
    }
}

/// More than forty reusable telemetry presentations. Several presentations
/// intentionally share one metric (for example speedometer and numeric speed)
/// while keeping independent design and layout behavior.
public enum TelemetryWidgetKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case speedometer
    case speedValue = "speed-value"
    case speedBar = "speed-bar"
    case routeMap = "route-map"
    case routeProgress = "route-progress"
    case altitude
    case elevationProfile = "elevation-profile"
    case gForce = "g-force"
    case gForceXY = "g-force-xy"
    case acceleration
    case heartRate = "heart-rate"
    case cadence
    case power
    case rpm
    case throttle
    case brake
    case leanAngle = "lean-angle"
    case lapTimer = "lap-timer"
    case lapCounter = "lap-counter"
    case heading
    case compass
    case distance
    case gradient
    case pace
    case verticalSpeed = "vertical-speed"
    case temperature
    case enginePower = "engine-power"
    case torque
    case gear
    case coordinates
    case calories
    case airPressure = "air-pressure"
    case leftRightBalance = "left-right-balance"
    case strideLength = "stride-length"
    case verticalOscillation = "vertical-oscillation"
    case groundContactTime = "ground-contact-time"
    case strokeRate = "stroke-rate"
    case cameraISO = "camera-iso"
    case cameraAperture = "camera-aperture"
    case cameraShutter = "camera-shutter"
    case cameraFocalLength = "camera-focal-length"
    case cameraEV = "camera-ev"
    case cameraColorTemperature = "camera-color-temperature"
    case elapsedTime = "elapsed-time"
    case satelliteStatus = "satellite-status"

    public var id: String { rawValue }

    public var metric: TelemetryMetric? {
        switch self {
        case .speedometer, .speedValue, .speedBar: return .speed
        case .routeMap, .routeProgress: return .route
        case .altitude, .elevationProfile: return .altitude
        case .gForce, .gForceXY: return .gForce
        case .acceleration: return .acceleration
        case .heartRate: return .heartRate
        case .cadence: return .cadence
        case .power, .enginePower: return .power
        case .rpm: return .rpm
        case .throttle: return .throttle
        case .brake: return .brake
        case .leanAngle: return .leanAngle
        case .lapTimer: return .lapTime
        case .lapCounter: return .lapNumber
        case .heading, .compass: return .heading
        case .distance: return .distance
        case .gradient: return .gradient
        case .pace: return .speed
        case .verticalSpeed: return .verticalSpeed
        case .temperature: return .temperature
        case .torque: return .torque
        case .gear: return .gear
        case .coordinates: return .route
        case .calories: return .calories
        case .airPressure: return .airPressure
        case .leftRightBalance: return .leftRightBalance
        case .strideLength: return .strideLength
        case .verticalOscillation: return .verticalOscillation
        case .groundContactTime: return .groundContactTime
        case .strokeRate: return .strokeRate
        case .cameraISO: return .cameraISO
        case .cameraAperture: return .cameraAperture
        case .cameraShutter: return .cameraShutter
        case .cameraFocalLength: return .cameraFocalLength
        case .cameraEV: return .cameraEV
        case .cameraColorTemperature: return .cameraColorTemperature
        case .elapsedTime, .satelliteStatus: return nil
        }
    }

    public var localizedTitle: String {
        switch self {
        case .speedometer: return "Спидометр"
        case .speedValue: return "Скорость — число"
        case .speedBar: return "Скорость — шкала"
        case .routeMap: return "GPS-маршрут"
        case .routeProgress: return "Прогресс маршрута"
        case .altitude: return "Высота"
        case .elevationProfile: return "Профиль высоты"
        case .gForce: return "Перегрузка"
        case .gForceXY: return "G-force по осям"
        case .acceleration: return "Ускорение"
        case .heartRate: return "Пульс"
        case .cadence: return "Каденс"
        case .power: return "Мощность"
        case .rpm: return "Обороты"
        case .throttle: return "Газ"
        case .brake: return "Тормоз"
        case .leanAngle: return "Угол наклона"
        case .lapTimer: return "Время круга"
        case .lapCounter: return "Номер круга"
        case .heading: return "Курс"
        case .compass: return "Компас"
        case .distance: return "Дистанция"
        case .gradient: return "Уклон"
        case .pace: return "Темп"
        case .verticalSpeed: return "Вертикальная скорость"
        case .temperature: return "Температура"
        case .enginePower: return "Мощность двигателя"
        case .torque: return "Крутящий момент"
        case .gear: return "Передача"
        case .coordinates: return "Координаты"
        case .calories: return "Калории"
        case .airPressure: return "Давление"
        case .leftRightBalance: return "Баланс лево/право"
        case .strideLength: return "Длина шага"
        case .verticalOscillation: return "Вертикальные колебания"
        case .groundContactTime: return "Контакт с землёй"
        case .strokeRate: return "Частота гребков"
        case .cameraISO: return "ISO камеры"
        case .cameraAperture: return "Диафрагма"
        case .cameraShutter: return "Выдержка"
        case .cameraFocalLength: return "Фокусное расстояние"
        case .cameraEV: return "Экспокоррекция"
        case .cameraColorTemperature: return "Баланс белого"
        case .elapsedTime: return "Время поездки"
        case .satelliteStatus: return "GPS-статус"
        }
    }

    public var category: TelemetryWidgetCategory {
        switch self {
        case .cadence, .power, .torque, .leftRightBalance:
            return .cycling
        case .pace, .strideLength, .verticalOscillation, .groundContactTime:
            return .running
        case .enginePower, .rpm, .throttle, .brake, .leanAngle, .lapTimer, .lapCounter, .gear:
            return .motorsports
        case .cameraISO, .cameraAperture, .cameraShutter, .cameraFocalLength, .cameraEV, .cameraColorTemperature:
            return .camera
        case .gForce, .gForceXY, .airPressure, .calories, .strokeRate, .satelliteStatus:
            return .other
        default:
            return .general
        }
    }

    public var defaultPresentation: TelemetryWidgetPresentation {
        switch self {
        case .speedometer: return .arc
        case .speedBar, .throttle, .brake: return .linear
        case .routeMap, .routeProgress: return .routePlot
        case .elevationProfile: return .elevationPlot
        case .gForceXY: return .gForce
        case .leanAngle: return .leanAngle
        case .lapTimer: return .lapCurrent
        case .compass: return .headingTape
        default: return .text
        }
    }

    public var supportedPresentations: [TelemetryWidgetPresentation] {
        switch self {
        case .routeMap, .routeProgress: return [.routePlot]
        case .elevationProfile: return [.elevationPlot]
        case .lapTimer: return [.lapCurrent, .lapBest, .lapDelta, .lapLog]
        case .heading, .compass: return [.text, .headingTape]
        case .gForce, .gForceXY: return [.text, .gForce]
        case .leanAngle: return [.text, .leanAngle]
        case .cameraISO, .cameraAperture, .cameraShutter, .cameraFocalLength,
             .cameraEV, .cameraColorTemperature, .coordinates, .leftRightBalance,
             .elapsedTime, .satelliteStatus, .gear, .lapCounter:
            return [.text]
        default:
            // Keep the browser identical to OVRLEY's shared
            // standard-metrics manifest. Segmented/reversed variants remain
            // decodable as legacy gauge configurations, not separate display
            // types in the catalogue.
            return [.text, .linear, .arc, .corner]
        }
    }

    /// Removes legacy aliases which represent the same OVRLEY metric. They
    /// remain decodable but the visual library shows one complete metric group.
    public static let catalogueKinds: [TelemetryWidgetKind] = allCases.filter {
        ![.speedometer, .speedBar, .routeProgress, .gForceXY, .compass].contains($0)
    }
}

public struct TelemetryWidgetPreset: Identifiable, Hashable, Sendable {
    public var kind: TelemetryWidgetKind
    public var presentation: TelemetryWidgetPresentation

    public init(kind: TelemetryWidgetKind, presentation: TelemetryWidgetPresentation) {
        self.kind = kind
        self.presentation = presentation
    }

    public var id: String { "\(kind.rawValue):\(presentation.rawValue)" }
    public var category: TelemetryWidgetCategory { kind.category }
    public static let all: [TelemetryWidgetPreset] = TelemetryWidgetKind.catalogueKinds.flatMap { kind in
        kind.supportedPresentations.map { TelemetryWidgetPreset(kind: kind, presentation: $0) }
    }
}

public struct TelemetryWidgetLayout: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var kind: TelemetryWidgetKind
    /// Optional for backwards compatibility with projects created before the
    /// OVRLEY display catalogue was exposed.
    public var presentation: TelemetryWidgetPresentation?
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public var opacity: Double
    public var foregroundHex: String
    public var backgroundHex: String
    public var accentHex: String
    public var borderWidth: Double
    public var shadowRadius: Double
    public var fontName: String
    public var showsLabel: Bool

    public init(
        id: UUID = UUID(),
        kind: TelemetryWidgetKind,
        presentation: TelemetryWidgetPresentation? = nil,
        x: Double = 0.05,
        y: Double = 0.72,
        width: Double = 0.26,
        height: Double = 0.20,
        opacity: Double = 1,
        foregroundHex: String = "#FFFFFF",
        backgroundHex: String = "#0B1018CC",
        accentHex: String = "#42D9FF",
        borderWidth: Double = 1,
        shadowRadius: Double = 8,
        fontName: String = "Helvetica Neue",
        showsLabel: Bool = true
    ) {
        self.id = id
        self.kind = kind
        self.presentation = presentation
        self.x = min(max(0, x), 1)
        self.y = min(max(0, y), 1)
        self.width = min(max(0.08, width), 1)
        self.height = min(max(0.06, height), 1)
        self.opacity = min(max(0, opacity), 1)
        self.foregroundHex = foregroundHex
        self.backgroundHex = backgroundHex
        self.accentHex = accentHex
        self.borderWidth = min(max(0, borderWidth), 12)
        self.shadowRadius = min(max(0, shadowRadius), 50)
        self.fontName = fontName
        self.showsLabel = showsLabel
    }

    public static func defaultLayout(for kind: TelemetryWidgetKind, index: Int = 0) -> TelemetryWidgetLayout {
        let column = index % 2
        let row = index / 2
        let specialized = kind == .routeMap || kind == .routeProgress || kind == .elevationProfile
        return TelemetryWidgetLayout(
            kind: kind,
            presentation: kind.defaultPresentation,
            x: 0.04 + Double(column) * 0.27,
            y: max(0.04, 0.76 - Double(row) * 0.21),
            width: specialized ? 0.31 : 0.24,
            height: specialized ? 0.24 : 0.17
        )
    }

    public var effectivePresentation: TelemetryWidgetPresentation { presentation ?? kind.defaultPresentation }

    public static func presetLayout(
        kind: TelemetryWidgetKind,
        presentation: TelemetryWidgetPresentation,
        x: Double = 0.06,
        y: Double = 0.69
    ) -> TelemetryWidgetLayout {
        let plot = presentation == .routePlot || presentation == .elevationPlot || presentation == .headingTape
        let lapLog = presentation == .lapLog
        return TelemetryWidgetLayout(
            kind: kind,
            presentation: presentation,
            x: x,
            y: y,
            width: plot ? 0.38 : (lapLog ? 0.30 : 0.22),
            height: plot ? 0.24 : (lapLog ? 0.26 : 0.22),
            backgroundHex: "#00000000",
            borderWidth: 0,
            shadowRadius: 0
        )
    }
}

public struct TimelineTelemetryItem: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    /// The edited video fragment that owns this overlay. Older projects may
    /// omit it; renderers retain the legacy source/timeline fallback.
    public var targetClipID: UUID?
    public var sourceID: UUID?
    public var linkedAssetID: UUID?
    public var sourceStart: Double
    public var timelineStart: Double
    public var timelineDuration: Double
    public var syncOffset: Double
    public var settings: TelemetryOverlaySettings
    public var locked: Bool
    public var explanation: [String]

    public init(
        id: UUID = UUID(),
        targetClipID: UUID? = nil,
        sourceID: UUID? = nil,
        linkedAssetID: UUID? = nil,
        sourceStart: Double = 0,
        timelineStart: Double,
        timelineDuration: Double,
        syncOffset: Double = 0,
        settings: TelemetryOverlaySettings = TelemetryOverlaySettings(),
        locked: Bool = false,
        explanation: [String] = []
    ) {
        self.id = id
        self.targetClipID = targetClipID
        self.sourceID = sourceID
        self.linkedAssetID = linkedAssetID
        self.sourceStart = max(0, sourceStart.isFinite ? sourceStart : 0)
        self.timelineStart = max(0, timelineStart.isFinite ? timelineStart : 0)
        self.timelineDuration = max(0.05, timelineDuration.isFinite ? timelineDuration : 0.05)
        self.syncOffset = syncOffset.isFinite ? syncOffset : 0
        self.settings = settings
        self.locked = locked
        self.explanation = explanation
    }

    public var timelineEnd: Double { timelineStart + timelineDuration }
}

public extension TelemetryOverlaySettings {
    var resolvedWidgets: [TelemetryWidgetLayout] {
        if let widgets, !widgets.isEmpty { return widgets }
        let kinds: [TelemetryWidgetKind] = metrics.sorted { $0.rawValue < $1.rawValue }.compactMap { metric in
            switch metric {
            case .speed: return .speedometer
            case .route: return .routeMap
            case .altitude: return .altitude
            case .gForce: return .gForce
            case .distance: return .distance
            case .acceleration: return .acceleration
            case .heading: return .compass
            case .heartRate: return .heartRate
            case .cadence: return .cadence
            case .power: return .power
            case .leanAngle: return .leanAngle
            case .rpm: return .rpm
            case .throttle: return .throttle
            case .brake: return .brake
            case .lapTime: return .lapTimer
            case .lapNumber: return .lapCounter
            case .temperature: return .temperature
            case .gradient: return .gradient
            case .verticalSpeed: return .verticalSpeed
            case .torque: return .torque
            case .gear: return .gear
            case .calories: return .calories
            case .airPressure: return .airPressure
            case .strideLength: return .strideLength
            case .verticalOscillation: return .verticalOscillation
            case .groundContactTime: return .groundContactTime
            case .leftRightBalance: return .leftRightBalance
            case .strokeRate: return .strokeRate
            case .cameraISO: return .cameraISO
            case .cameraAperture: return .cameraAperture
            case .cameraShutter: return .cameraShutter
            case .cameraFocalLength: return .cameraFocalLength
            case .cameraEV: return .cameraEV
            case .cameraColorTemperature: return .cameraColorTemperature
            }
        }
        return Array(kinds.prefix(4).enumerated()).map { TelemetryWidgetLayout.defaultLayout(for: $0.element, index: $0.offset) }
    }
}

public extension TelemetrySummary {
    /// Returns only widgets which can produce a visible value from this
    /// source. A stream name alone is not enough: some camera containers
    /// advertise GPS or lap channels while every decoded value is absent (or
    /// is only a sentinel such as lap -1).
    func supports(_ kind: TelemetryWidgetKind, presentation: TelemetryWidgetPresentation? = nil) -> Bool {
        // Older saved projects may contain zero-valued motion derived from a
        // single QuickTime location. It is a capture location, not a GPS track.
        if sourceFormat == TelemetrySourceFormat.embeddedQuickTime.rawValue {
            guard [.coordinates, .altitude, .satelliteStatus, .elapsedTime].contains(kind),
                  presentation != .elevationPlot, presentation != .routePlot else { return false }
        }
        let values = timedSamples ?? []
        func has(_ keyPath: KeyPath<TelemetrySample, Double?>, where predicate: (Double) -> Bool = { _ in true }) -> Bool {
            values.contains { sample in sample[keyPath: keyPath].map(predicate) == true }
        }
        func hasCoordinate() -> Bool {
            route?.isEmpty == false || values.contains { $0.coordinate != nil }
        }
        func hasRoute() -> Bool {
            let coordinates = route ?? values.compactMap(\.coordinate)
            guard let first = coordinates.first else { return false }
            return coordinates.dropFirst().contains { coordinate in
                abs(coordinate.latitude - first.latitude) > 0.0000001 ||
                    abs(coordinate.longitude - first.longitude) > 0.0000001
            }
        }

        let metricAvailable: Bool
        switch kind {
        case .speedometer, .speedValue, .speedBar, .pace:
            metricAvailable = has(\.speedMetersPerSecond) { $0 > 0 } || (maxSpeedMetersPerSecond ?? 0) > 0
        case .routeMap, .routeProgress:
            metricAvailable = hasRoute()
        case .coordinates, .satelliteStatus:
            metricAvailable = hasCoordinate()
        case .altitude, .elevationProfile:
            metricAvailable = has(\.altitudeMeters) || altitudeSamplesMeters?.isEmpty == false || minAltitudeMeters != nil || maxAltitudeMeters != nil
        case .gForce:
            metricAvailable = has(\.gForce) || has(\.gForceX) || has(\.gForceY)
        case .gForceXY:
            metricAvailable = has(\.gForceX) || has(\.gForceY)
        case .distance:
            metricAvailable = has(\.distanceMeters) { $0 > 0 } || (distanceMeters ?? 0) > 0
        case .acceleration: metricAvailable = has(\.accelerationMetersPerSecondSquared)
        case .heading, .compass: metricAvailable = has(\.headingDegrees)
        case .heartRate: metricAvailable = has(\.heartRateBPM) { $0 > 0 }
        case .cadence: metricAvailable = has(\.cadenceRPM) { $0 > 0 }
        case .power, .enginePower: metricAvailable = has(\.powerWatts)
        case .leanAngle: metricAvailable = has(\.leanAngleDegrees)
        case .rpm: metricAvailable = has(\.rpm) { $0 >= 0 }
        case .throttle: metricAvailable = has(\.throttlePercent)
        case .brake: metricAvailable = has(\.brakePercent)
        case .lapTimer: metricAvailable = has(\.lapTimeSeconds) { $0 >= 0 }
        case .lapCounter: metricAvailable = has(\.lapNumber) { $0 > 0 }
        case .temperature: metricAvailable = has(\.temperatureCelsius)
        case .gradient: metricAvailable = has(\.gradientPercent)
        case .verticalSpeed: metricAvailable = has(\.verticalSpeedMetersPerSecond)
        case .torque: metricAvailable = has(\.torqueNewtonMeters)
        case .gear: metricAvailable = has(\.gear) { $0 >= 0 }
        case .calories: metricAvailable = has(\.calories) { $0 >= 0 }
        case .airPressure: metricAvailable = has(\.airPressureHPA) { $0 > 0 }
        case .leftRightBalance: metricAvailable = has(\.leftRightBalancePercent)
        case .strideLength: metricAvailable = has(\.strideLengthMeters) { $0 >= 0 }
        case .verticalOscillation: metricAvailable = has(\.verticalOscillationCentimeters) { $0 >= 0 }
        case .groundContactTime: metricAvailable = has(\.groundContactTimeMilliseconds) { $0 >= 0 }
        case .strokeRate: metricAvailable = has(\.strokeRate) { $0 >= 0 }
        case .cameraISO: metricAvailable = has(\.cameraISO) { $0 > 0 }
        case .cameraAperture: metricAvailable = has(\.cameraAperture) { $0 > 0 }
        case .cameraShutter: metricAvailable = has(\.cameraShutterSeconds) { $0 > 0 }
        case .cameraFocalLength: metricAvailable = has(\.cameraFocalLengthMM) { $0 > 0 }
        case .cameraEV: metricAvailable = has(\.cameraEV)
        case .cameraColorTemperature: metricAvailable = has(\.cameraColorTemperatureKelvin) { $0 > 0 }
        case .elapsedTime: metricAvailable = values.isEmpty == false
        }
        guard metricAvailable else { return false }

        switch presentation {
        case .routePlot: return hasRoute()
        case .elevationPlot:
            return (altitudeSamplesMeters?.count ?? 0) > 1 || values.lazy.compactMap(\.altitudeMeters).prefix(2).count > 1
        case .gForce:
            return has(\.gForceX) || has(\.gForceY) || has(\.gForce)
        case .headingTape: return has(\.headingDegrees)
        case .leanAngle: return has(\.leanAngleDegrees)
        default: return true
        }
    }

    var availableWidgetKinds: [TelemetryWidgetKind] {
        TelemetryWidgetKind.catalogueKinds.filter { supports($0) }
    }

    func sample(at timestamp: Double) -> TelemetrySample? {
        guard let values = timedSamples, !values.isEmpty else { return nil }
        if values.count == 1 { return values[0] }
        let target = timestamp.isFinite ? timestamp : 0
        if target <= values[0].timestamp { return values[0] }
        if target >= values[values.count - 1].timestamp { return values[values.count - 1] }
        var low = 0
        var high = values.count - 1
        while high - low > 1 {
            let mid = (low + high) / 2
            if values[mid].timestamp <= target { low = mid } else { high = mid }
        }
        let lhs = values[low]
        let rhs = values[high]
        let span = max(0.000_001, rhs.timestamp - lhs.timestamp)
        let fraction = min(max(0, (target - lhs.timestamp) / span), 1)
        return TelemetrySample.interpolate(lhs, rhs, fraction: fraction, timestamp: target)
    }
}

private extension TelemetrySample {
    static func interpolate(_ lhs: TelemetrySample, _ rhs: TelemetrySample, fraction: Double, timestamp: Double) -> TelemetrySample {
        func value(_ a: Double?, _ b: Double?) -> Double? {
            switch (a, b) {
            case let (a?, b?): return a + (b - a) * fraction
            case let (a?, nil): return a
            case let (nil, b?): return b
            default: return nil
            }
        }
        let coordinate: TelemetryCoordinate?
        if let a = lhs.coordinate, let b = rhs.coordinate {
            coordinate = TelemetryCoordinate(
                latitude: a.latitude + (b.latitude - a.latitude) * fraction,
                longitude: a.longitude + (b.longitude - a.longitude) * fraction
            )
        } else { coordinate = lhs.coordinate ?? rhs.coordinate }
        let customKeys = Set(lhs.customFields?.keys.map { $0 } ?? [])
            .union(rhs.customFields?.keys.map { $0 } ?? [])
        let customFields = Dictionary(uniqueKeysWithValues: customKeys.compactMap { key -> (String, Double)? in
            guard let interpolated = value(lhs.customFields?[key], rhs.customFields?[key]) else { return nil }
            return (key, interpolated)
        })
        return TelemetrySample(
            timestamp: timestamp,
            speedMetersPerSecond: value(lhs.speedMetersPerSecond, rhs.speedMetersPerSecond),
            altitudeMeters: value(lhs.altitudeMeters, rhs.altitudeMeters),
            gForce: value(lhs.gForce, rhs.gForce),
            coordinate: coordinate,
            distanceMeters: value(lhs.distanceMeters, rhs.distanceMeters),
            accelerationMetersPerSecondSquared: value(lhs.accelerationMetersPerSecondSquared, rhs.accelerationMetersPerSecondSquared),
            gForceX: value(lhs.gForceX, rhs.gForceX),
            gForceY: value(lhs.gForceY, rhs.gForceY),
            gForceZ: value(lhs.gForceZ, rhs.gForceZ),
            gyroX: value(lhs.gyroX, rhs.gyroX),
            gyroY: value(lhs.gyroY, rhs.gyroY),
            gyroZ: value(lhs.gyroZ, rhs.gyroZ),
            headingDegrees: value(lhs.headingDegrees, rhs.headingDegrees),
            heartRateBPM: value(lhs.heartRateBPM, rhs.heartRateBPM),
            cadenceRPM: value(lhs.cadenceRPM, rhs.cadenceRPM),
            powerWatts: value(lhs.powerWatts, rhs.powerWatts),
            leanAngleDegrees: value(lhs.leanAngleDegrees, rhs.leanAngleDegrees),
            rpm: value(lhs.rpm, rhs.rpm),
            throttlePercent: value(lhs.throttlePercent, rhs.throttlePercent),
            brakePercent: value(lhs.brakePercent, rhs.brakePercent),
            lapNumber: lhs.lapNumber ?? rhs.lapNumber,
            lapTimeSeconds: value(lhs.lapTimeSeconds, rhs.lapTimeSeconds),
            temperatureCelsius: value(lhs.temperatureCelsius, rhs.temperatureCelsius),
            gradientPercent: value(lhs.gradientPercent, rhs.gradientPercent),
            verticalSpeedMetersPerSecond: value(lhs.verticalSpeedMetersPerSecond, rhs.verticalSpeedMetersPerSecond),
            torqueNewtonMeters: value(lhs.torqueNewtonMeters, rhs.torqueNewtonMeters),
            gear: lhs.gear ?? rhs.gear,
            calories: value(lhs.calories, rhs.calories),
            airPressureHPA: value(lhs.airPressureHPA, rhs.airPressureHPA),
            strideLengthMeters: value(lhs.strideLengthMeters, rhs.strideLengthMeters),
            verticalOscillationCentimeters: value(lhs.verticalOscillationCentimeters, rhs.verticalOscillationCentimeters),
            groundContactTimeMilliseconds: value(lhs.groundContactTimeMilliseconds, rhs.groundContactTimeMilliseconds),
            leftRightBalancePercent: value(lhs.leftRightBalancePercent, rhs.leftRightBalancePercent),
            strokeRate: value(lhs.strokeRate, rhs.strokeRate),
            cameraISO: lhs.cameraISO ?? rhs.cameraISO,
            cameraAperture: value(lhs.cameraAperture, rhs.cameraAperture),
            cameraShutterSeconds: value(lhs.cameraShutterSeconds, rhs.cameraShutterSeconds),
            cameraFocalLengthMM: value(lhs.cameraFocalLengthMM, rhs.cameraFocalLengthMM),
            cameraEV: value(lhs.cameraEV, rhs.cameraEV),
            cameraColorTemperatureKelvin: value(lhs.cameraColorTemperatureKelvin, rhs.cameraColorTemperatureKelvin),
            customFields: customFields
        )
    }
}
