import Foundation

/// A mention of speed or sensor data is not automatically permission to draw
/// over the movie. This policy requires an overlay/display intent and rejects
/// explicit opt-outs before TimelineComposer may create a telemetry layer.
enum TelemetryOverlayRequestPolicy {
    static func requestsOverlay(in prompt: String) -> Bool {
        let text = prompt.lowercased()
            .replacingOccurrences(of: "ё", with: "е")
            .replacingOccurrences(of: "–", with: "-")
        let forbidden = [
            "без телеметри", "не добавляй телеметри", "не показывай телеметри",
            "убери телеметри", "скрой телеметри", "no telemetry", "without telemetry"
        ]
        guard !forbidden.contains(where: text.contains) else { return false }
        // Negation may cover a coordinated list: “без фильтров и телеметрии”.
        // Do this before detecting “добавь” elsewhere in the same brief.
        let coordinatedNegation = #"(?:без|не\s+(?:добавляй|показывай)|убери|скрой|no|without)[^,;.!?\n]{0,48}(?:телеметри|telemetry)"#
        if text.range(of: coordinatedNegation, options: .regularExpression) != nil { return false }

        let directPhrases = [
            "с телеметри", "телеметрия:", "telemetry overlay", "telemetry hud",
            "наложение телеметри", "виджет телеметри", "индикатор телеметри"
        ]
        if directPhrases.contains(where: text.contains) { return true }

        let displayIntent = [
            "покажи", "показать", "добавь", "добавить", "выведи", "вывести",
            "отобрази", "отобразить", "наложи", "наложить", "на экране",
            "виджет", "индикатор", "спидометр", "show", "display", "overlay", "add"
        ].contains(where: text.contains)
        let telemetrySubject = [
            "телеметри", "gps", "маршрут", "скорост", "высот", "альтит",
            "g-force", "g force", "перегруз", "дистанц", "расстоян", "пульс",
            "каденс", "мощност", "telemetry", "speed", "route", "altitude",
            "distance", "heart rate", "cadence", "power"
        ].contains(where: text.contains)
        return displayIntent && telemetrySubject
    }
}

/// Editorial context for one video fragment. The engine can only select
/// existing OVRLEY widgets and layouts; it never invents a visualisation.
public struct SmartTelemetryContext: Sendable {
    public var telemetry: TelemetrySummary
    public var clip: TimelineItem
    public var tags: Set<String>
    public var role: StoryRole?
    public var avoidRegions: [NormalizedRegion]
    public var subjectMovementX: Double
    public var aspectRatio: Double
    public var sceneComplexity: Double
    public var explicitRequest: String?

    public init(
        telemetry: TelemetrySummary,
        clip: TimelineItem,
        tags: Set<String> = [],
        role: StoryRole? = nil,
        avoidRegions: [NormalizedRegion] = [],
        subjectMovementX: Double = 0,
        aspectRatio: Double = 16.0 / 9.0,
        sceneComplexity: Double = 0.5,
        explicitRequest: String? = nil
    ) {
        self.telemetry = telemetry
        self.clip = clip
        self.tags = tags
        self.role = role
        self.avoidRegions = avoidRegions
        self.subjectMovementX = min(max(-1, subjectMovementX), 1)
        self.aspectRatio = max(0.1, aspectRatio.isFinite ? aspectRatio : 16.0 / 9.0)
        self.sceneComplexity = min(max(0, sceneComplexity), 1)
        self.explicitRequest = explicitRequest
    }
}

public struct SmartTelemetryDecision: Hashable, Sendable {
    public var sourceMoment: Double
    public var timelineStart: Double
    public var duration: Double
    public var settings: TelemetryOverlaySettings
    public var confidence: Double
    public var explanation: [String]

    public init(
        sourceMoment: Double,
        timelineStart: Double,
        duration: Double,
        settings: TelemetryOverlaySettings,
        confidence: Double,
        explanation: [String]
    ) {
        self.sourceMoment = max(0, sourceMoment)
        self.timelineStart = max(0, timelineStart)
        self.duration = max(0.05, duration)
        self.settings = settings
        self.confidence = min(max(0, confidence), 1)
        self.explanation = explanation
    }
}

/// Selects a meaningful sensor moment, one real OVRLEY presentation and a
/// subject-aware frame position. Telemetry remains a short accent rather than
/// a permanent HUD.
public struct SmartTelemetryEngine: Sendable {
    public init() {}

    public func decide(_ context: SmartTelemetryContext) -> SmartTelemetryDecision? {
        var context = context
        guard context.telemetry.hasTelemetry, context.clip.kind == .video else { return nil }
        let sourceRange = context.clip.sourceStart...(context.clip.sourceStart + context.clip.sourceDuration)
        let samplesInRange = (context.telemetry.timedSamples ?? []).filter { sourceRange.contains($0.timestamp) }
        // A summary maximum is not enough to place an editorial accent: its
        // exact time must come from a real decoded sample inside this clip.
        guard !samplesInRange.isEmpty else { return nil }
        context.telemetry = AutomaticTelemetryPolicy.scoped(context.telemetry, samples: samplesInRange)
        let moments = TelemetryHighlightDetector().moments(
            from: context.telemetry,
            duration: context.telemetry.timedSamples?.last?.timestamp
        ).filter { sourceRange.contains($0.timestamp) }
        let requested = context.explicitRequest?.lowercased() ?? ""
        let bestMoment = moments.max(by: { eventScore($0, request: requested) < eventScore($1, request: requested) })
        let explicit = !requested.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let score = bestMoment.map { eventScore($0, request: requested) } ?? 0
        guard explicit || score >= 0.65 else { return nil }

        let kind = chooseKind(context: context, moment: bestMoment, request: requested)
        guard let kind,
              context.telemetry.supports(kind, presentation: kind.defaultPresentation) else { return nil }
        if kind == .gForce {
            let peak = samplesInRange.compactMap { sample -> Double? in
                if let value = sample.gForce { return abs(value) }
                if let x = sample.gForceX, let y = sample.gForceY { return hypot(x, y) }
                return nil
            }.max() ?? 0
            guard explicit || peak > 0.15 else { return nil }
        }
        let presentation = presentation(for: kind, context: context)
        guard context.telemetry.supports(kind, presentation: presentation) else { return nil }

        let proposedMoment = bestMoment?.timestamp ?? fallbackMoment(context)
        let covered = AutomaticTelemetryPolicy.ranges(in: samplesInRange, kind: kind)
        guard let interval = covered.filter({ $0.upperBound - $0.lowerBound >= 1 }).min(by: {
            abs(($0.lowerBound + $0.upperBound) / 2 - proposedMoment) < abs(($1.lowerBound + $1.upperBound) / 2 - proposedMoment)
        }) else { return nil }
        let sourceMoment = min(interval.upperBound, max(interval.lowerBound, proposedMoment))
        let timelineMoment = timelineTime(forSourceTime: sourceMoment, clip: context.clip)
        let coverageStart = timelineTime(forSourceTime: interval.lowerBound, clip: context.clip)
        let coverageEnd = timelineTime(forSourceTime: interval.upperBound, clip: context.clip)
        let duration = min(context.clip.timelineDuration, preferredDuration(for: kind, score: score), coverageEnd - coverageStart)
        let start = min(
            coverageEnd - duration,
            max(coverageStart, timelineMoment - min(0.55, duration * 0.22))
        )
        let style = style(for: kind, context: context)
        let layout = placement(
            kind: kind,
            presentation: presentation,
            context: context
        )
        let settings = TelemetryOverlaySettings(
            metrics: kind.metric.map { [$0] } ?? [],
            corner: corner(for: layout),
            scale: layout.width,
            style: style,
            widgets: [layout]
        )
        let eventExplanation = bestMoment?.explanation ?? explicitReason(requested, kind: kind)
        return SmartTelemetryDecision(
            sourceMoment: sourceMoment,
            timelineStart: start,
            duration: duration,
            settings: settings,
            confidence: explicit ? max(0.58, score) : score,
            explanation: [
                "OVRLEY: \(kind.localizedTitle) · \(presentation.localizedTitle) · \(style.localizedTitle)",
                "Акцент привязан к моменту \(clock(sourceMoment)): \(eventExplanation)",
                placementExplanation(layout: layout, context: context)
            ]
        )
    }

    private func chooseKind(context: SmartTelemetryContext, moment: TelemetryMoment?, request: String) -> TelemetryWidgetKind? {
        let requestedOrder: [(TelemetryWidgetKind, [String])] = [
            (.routeMap, ["gps", "маршрут", "route", "map"]),
            (.elevationProfile, ["высот", "подъём", "спуск", "altitude", "elevation"]),
            (.gForce, ["g-force", "g force", "перегруз", "поворот", "тормож"]),
            (.heartRate, ["пульс", "heart rate"]),
            (.cadence, ["каденс", "cadence"]),
            (.power, ["мощност", "power"]),
            (.distance, ["дистанц", "расстояни", "distance"]),
            (.speedValue, ["скорост", "speed", "разгон"])
        ]
        for (kind, words) in requestedOrder where words.contains(where: request.contains) {
            return context.telemetry.supports(kind, presentation: kind.defaultPresentation) ? kind : nil
        }
        if !request.isEmpty, AutomaticTelemetryPolicy.usefulKinds(in: context.telemetry).isEmpty { return nil }
        if let moment {
            if request.isEmpty, (moment.tags.contains("turn") || moment.tags.contains("g-force")), context.telemetry.supports(.gForce, presentation: .gForce) { return .gForce }
            if moment.tags.contains("elevation-change"), context.telemetry.supports(.elevationProfile, presentation: .elevationPlot) { return .elevationProfile }
            if (moment.tags.contains("high-speed") || moment.tags.contains("acceleration")), context.telemetry.supports(.speedValue, presentation: .arc) { return .speedValue }
        }
        let semantic = context.tags.map { $0.lowercased() }
        if semantic.contains(where: { $0.contains("cycling") || $0.contains("велосип") }) {
            for kind in [TelemetryWidgetKind.power, .cadence, .speedValue, .distance] where context.telemetry.supports(kind, presentation: kind.defaultPresentation) { return kind }
        }
        return [.speedValue, .elevationProfile, .routeMap, .heartRate, .cadence, .power, .distance]
            .first { context.telemetry.supports($0, presentation: $0.defaultPresentation) }
    }

    private func presentation(for kind: TelemetryWidgetKind, context: SmartTelemetryContext) -> TelemetryWidgetPresentation {
        switch kind {
        case .gForce: return .gForce
        case .heading: return .headingTape
        case .leanAngle: return .leanAngle
        default: break
        }
        if context.sceneComplexity >= 0.68 {
            if kind.supportedPresentations.contains(.text) { return .text }
        }
        switch kind {
        case .speedValue: return .arc
        default: return kind.defaultPresentation
        }
    }

    private func style(for kind: TelemetryWidgetKind, context: SmartTelemetryContext) -> TelemetryWidgetStyle {
        switch kind {
        case .routeMap, .distance: return .breezeBlue
        case .elevationProfile, .altitude, .verticalSpeed: return .whiteVAM
        case .gForce, .acceleration, .leanAngle: return .futuristicHUD
        case .speedValue, .speedometer, .speedBar: return context.role == .climax ? .acidTitanium : .burntOrange
        case .heartRate, .cadence, .power: return .champagneBorders
        default: return .champagneBasic
        }
    }

    private func placement(
        kind: TelemetryWidgetKind,
        presentation: TelemetryWidgetPresentation,
        context: SmartTelemetryContext
    ) -> TelemetryWidgetLayout {
        var base = TelemetryWidgetLayout.presetLayout(kind: kind, presentation: presentation)
        let vertical = context.aspectRatio < 0.82
        let plot = presentation == .routePlot || presentation == .elevationPlot || presentation == .headingTape
        let compact = context.sceneComplexity >= 0.64 || vertical
        base.width = plot ? (compact ? 0.34 : 0.40) : (compact ? 0.18 : 0.24)
        base.height = plot ? (compact ? 0.18 : 0.24) : (compact ? 0.15 : 0.22)

        let marginX = vertical ? 0.07 : 0.045
        let marginY = vertical ? 0.055 : 0.045
        let candidates = [
            CGPoint(x: marginX, y: marginY),
            CGPoint(x: 1 - marginX - base.width, y: marginY),
            CGPoint(x: marginX, y: 1 - marginY - base.height),
            CGPoint(x: 1 - marginX - base.width, y: 1 - marginY - base.height)
        ]
        let selected = candidates.min { lhs, rhs in
            placementPenalty(origin: lhs, size: base, context: context) < placementPenalty(origin: rhs, size: base, context: context)
        } ?? candidates[0]
        base.x = selected.x
        base.y = selected.y
        return base
    }

    private func placementPenalty(origin: CGPoint, size: TelemetryWidgetLayout, context: SmartTelemetryContext) -> Double {
        let region = NormalizedRegion(x: origin.x, y: origin.y, width: size.width, height: size.height)
        var penalty = context.avoidRegions.reduce(0) { $0 + overlap(region, $1) * 8 }
        // Preserve lead room in front of a moving subject.
        if context.subjectMovementX > 0.08 { penalty += region.centerX * abs(context.subjectMovementX) * 1.6 }
        if context.subjectMovementX < -0.08 { penalty += (1 - region.centerX) * abs(context.subjectMovementX) * 1.6 }
        // Bottom corners are usually quieter, but never at the cost of covering a subject.
        if region.centerY < 0.5 { penalty -= 0.12 }
        return penalty
    }

    private func eventScore(_ moment: TelemetryMoment, request: String) -> Double {
        var value = moment.score
        if request.contains("скорост") && moment.tags.contains("high-speed") { value += 0.25 }
        if (request.contains("поворот") || request.contains("g-force") || request.contains("перегруз")) && (moment.tags.contains("turn") || moment.tags.contains("g-force")) { value += 0.25 }
        if (request.contains("высот") || request.contains("подъём")) && moment.tags.contains("elevation-change") { value += 0.25 }
        return min(1, value)
    }

    private func fallbackMoment(_ context: SmartTelemetryContext) -> Double {
        let samples = context.telemetry.timedSamples ?? []
        let range = context.clip.sourceStart...(context.clip.sourceStart + context.clip.sourceDuration)
        return samples.filter { range.contains($0.timestamp) }.max(by: {
            ($0.speedMetersPerSecond ?? 0) < ($1.speedMetersPerSecond ?? 0)
        })?.timestamp ?? context.clip.sourceStart
    }

    private func preferredDuration(for kind: TelemetryWidgetKind, score: Double) -> Double {
        switch kind {
        case .routeMap, .elevationProfile: return 4.2
        default: return score >= 0.72 ? 3.0 : 2.4
        }
    }

    private func timelineTime(forSourceTime sourceTime: Double, clip: TimelineItem) -> Double {
        var low = clip.timelineStart
        var high = clip.timelineStart + clip.timelineDuration
        let descending = clip.sourceTime(atTimelineTime: low) > clip.sourceTime(atTimelineTime: high)
        for _ in 0..<28 {
            let middle = (low + high) / 2
            let value = clip.sourceTime(atTimelineTime: middle)
            if (value < sourceTime) != descending { low = middle } else { high = middle }
        }
        return min(max(clip.timelineStart, (low + high) / 2), clip.timelineStart + clip.timelineDuration)
    }

    private func corner(for layout: TelemetryWidgetLayout) -> OverlayCorner {
        switch (layout.x + layout.width / 2 >= 0.5, layout.y + layout.height / 2 >= 0.5) {
        case (false, false): return .bottomLeft
        case (true, false): return .bottomRight
        case (false, true): return .topLeft
        case (true, true): return .topRight
        }
    }

    private func overlap(_ lhs: NormalizedRegion, _ rhs: NormalizedRegion) -> Double {
        let width = max(0, min(lhs.x + lhs.width, rhs.x + rhs.width) - max(lhs.x, rhs.x))
        let height = max(0, min(lhs.y + lhs.height, rhs.y + rhs.height) - max(lhs.y, rhs.y))
        return width * height / max(0.0001, min(lhs.area, rhs.area))
    }

    private func placementExplanation(layout: TelemetryWidgetLayout, context: SmartTelemetryContext) -> String {
        let horizontal = layout.x + layout.width / 2 < 0.5 ? "слева" : "справа"
        let vertical = layout.y + layout.height / 2 < 0.5 ? "снизу" : "сверху"
        let size = context.sceneComplexity >= 0.64 || context.aspectRatio < 0.82 ? "компактный размер" : "расширенный размер"
        return "Позиция \(vertical) \(horizontal), \(size): минимальное пересечение с главным объектом и направлением движения"
    }

    private func explicitReason(_ request: String, kind: TelemetryWidgetKind) -> String {
        request.isEmpty ? "доступная метрика \(kind.localizedTitle)" : "явный запрос пользователя на \(kind.localizedTitle)"
    }

    private func clock(_ seconds: Double) -> String {
        String(format: "%02d:%05.2f", Int(seconds) / 60, seconds.truncatingRemainder(dividingBy: 60))
    }
}
