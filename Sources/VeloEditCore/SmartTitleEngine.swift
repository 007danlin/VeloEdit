import Foundation

/// Editorial intent is the only input allowed to influence template choice.
/// Layout, typography and motion remain owned by `TitleTemplateDefinition`.
public enum SmartTitlePurpose: String, Codable, CaseIterable, Sendable {
    case filmOpening = "film-opening"
    case chapter
    case location
    case dateChronicle = "date-chronicle"
    case activity
    case shortLabel = "short-label"
    case ending
}

public struct SmartTitleContext: Sendable {
    public var purpose: SmartTitlePurpose
    public var requestedText: String?
    public var tags: Set<String>
    public var summaries: [String]
    public var locationName: String?
    public var locationConfidence: Double
    public var captureDate: Date?
    public var dateAddsContext: Bool
    public var sequenceIndex: Int?
    public var sequenceCount: Int?
    public var usedTitles: [String]
    public var avoidRegions: [NormalizedRegion]
    public var preferredTemplateID: String?

    public init(
        purpose: SmartTitlePurpose,
        requestedText: String? = nil,
        tags: Set<String> = [],
        summaries: [String] = [],
        locationName: String? = nil,
        locationConfidence: Double = 0,
        captureDate: Date? = nil,
        dateAddsContext: Bool = false,
        sequenceIndex: Int? = nil,
        sequenceCount: Int? = nil,
        usedTitles: [String] = [],
        avoidRegions: [NormalizedRegion] = [],
        preferredTemplateID: String? = nil
    ) {
        self.purpose = purpose
        self.requestedText = requestedText
        self.tags = tags
        self.summaries = summaries
        self.locationName = locationName
        self.locationConfidence = min(max(0, locationConfidence), 1)
        self.captureDate = captureDate
        self.dateAddsContext = dateAddsContext
        self.sequenceIndex = sequenceIndex
        self.sequenceCount = sequenceCount
        self.usedTitles = usedTitles
        self.avoidRegions = avoidRegions
        self.preferredTemplateID = preferredTemplateID
    }
}

public struct SmartTitleDecision: Hashable, Sendable {
    public var primaryText: String
    public var secondaryText: String?
    public var templateID: String
    public var duration: Double
    public var confidence: Double
    public var explanation: [String]

    public init(primaryText: String, secondaryText: String? = nil, templateID: String, duration: Double, confidence: Double, explanation: [String]) {
        self.primaryText = primaryText
        self.secondaryText = secondaryText
        self.templateID = templateID
        self.duration = max(0.05, duration)
        self.confidence = min(max(0, confidence), 1)
        self.explanation = explanation
    }
}

/// Deterministic offline title director. It chooses content and one existing
/// visual template, but never synthesizes layout, fonts, sizes or animation.
public struct SmartTitleEngine: Sendable {
    public init() {}

    public func decide(_ context: SmartTitleContext) -> SmartTitleDecision? {
        let evidence = normalizedEvidence(context)
        let activity = recognizedActivity(in: evidence)
        let requested = meaningfulRequestedText(context.requestedText)
        let location = reliableLocation(context.locationName, confidence: context.locationConfidence)
        let date = context.captureDate.map(Self.russianDate)
        var explanation: [String] = []

        let primary: String
        var secondary: String?
        var confidence: Double
        switch context.purpose {
        case .filmOpening:
            if let requested {
                primary = requested
                confidence = 0.92
                explanation.append("Название следует подтверждённой теме фильма")
            } else if evidence.contains(where: { $0.contains("лет") || $0.contains("summer") }) {
                primary = "Моё лето"
                confidence = 0.78
                explanation.append("Летняя тема подтверждена содержанием")
            } else if let activity {
                primary = activity.eventTitle
                confidence = activity.confidence
                explanation.append(activity.explanation)
            } else if let location {
                primary = "Поездка — \(location)"
                confidence = 0.68
                explanation.append("Использовано подтверждённое место")
            } else {
                return nil
            }
            secondary = supportingContext(location: location, date: date, includeDate: context.dateAddsContext, excluding: primary)

        case .chapter:
            let base = requested ?? activity?.eventTitle ?? location
            guard let base, !Self.isMeaningless(base) else { return nil }
            if let index = context.sequenceIndex, (context.sequenceCount ?? 0) > 1, let activity {
                primary = "День \(max(1, index)) — \(activity.shortTitle)"
                confidence = min(0.96, activity.confidence + 0.04)
                explanation.append("Глава связана с хронологией и распознанной активностью")
            } else if context.dateAddsContext, let date, base.count + date.count + 3 <= 48 {
                primary = "\(base) — \(date)"
                confidence = max(activity?.confidence ?? 0.68, 0.72)
                explanation.append("Дата различает события в хронологии")
            } else {
                primary = base
                confidence = activity?.confidence ?? (requested == nil ? 0.64 : 0.86)
                explanation.append(requested == nil ? "Название описывает содержимое сцены" : "Использовано конкретное название события")
            }
            secondary = supportingContext(location: location, date: date, includeDate: context.dateAddsContext, excluding: primary)

        case .location:
            guard let location else { return nil }
            primary = location
            secondary = context.dateAddsContext ? date : nil
            confidence = max(0.62, context.locationConfidence)
            explanation.append("Место подтверждено metadata или анализом сцены")

        case .dateChronicle:
            guard let date else { return nil }
            primary = date
            secondary = activity?.shortTitle ?? requested
            confidence = 0.88
            explanation.append("Дата используется как элемент хронологии")

        case .activity:
            if let activity {
                primary = activity.eventTitle
                confidence = activity.confidence
                explanation.append(activity.explanation)
            } else if let requested {
                primary = requested
                confidence = 0.76
                explanation.append("Название передано структурой монтажа")
            } else {
                return nil
            }
            secondary = supportingContext(location: location, date: date, includeDate: context.dateAddsContext, excluding: primary)

        case .shortLabel:
            if let activity {
                primary = activity.shortTitle
                confidence = activity.confidence
                explanation.append(activity.explanation)
            } else if let location {
                primary = location
                confidence = context.locationConfidence
                explanation.append("Короткая подпись использует подтверждённое место")
            } else if let requested {
                primary = requested
                confidence = 0.72
                explanation.append("Короткая подпись передана монтажным контекстом")
            } else {
                return nil
            }
            secondary = nil

        case .ending:
            if evidence.contains(where: { $0.contains("road") || $0.contains("дорог") || $0.contains("drive") || $0.contains("домой") }) {
                primary = "Дорога домой"
                confidence = 0.86
                explanation.append("Финал подтверждён дорожной сценой")
            } else if let requested {
                primary = requested
                confidence = 0.84
                explanation.append("Финальный текст следует структуре фильма")
            } else if let activity {
                primary = activity.eventTitle
                confidence = activity.confidence * 0.82
                explanation.append("Финал назван по последнему подтверждённому событию")
            } else {
                return nil
            }
            secondary = context.dateAddsContext ? date : nil
        }

        let deduplicated = disambiguated(primary, context: context, location: location, date: date)
        guard !Self.isMeaningless(deduplicated) else { return nil }
        let template = selectTemplate(primaryText: deduplicated, secondaryText: secondary, context: context, evidence: evidence)
        guard let template else { return nil }
        let fittedPrimary = Self.shortened(deduplicated, limit: template.textConstraints.maxCharacters)
        let fittedSecondary = secondary.map { Self.shortened($0, limit: max(18, template.textConstraints.maxCharacters)) }
        explanation.append("Выбран существующий шаблон \(template.name); его layout и animation не изменяются")
        if !context.avoidRegions.isEmpty { explanation.append("Композиция проверена относительно важных объектов кадра") }
        return SmartTitleDecision(
            primaryText: fittedPrimary,
            secondaryText: fittedSecondary,
            templateID: template.id,
            duration: template.duration,
            confidence: confidence,
            explanation: explanation
        )
    }

    public static func isMeaningless(_ value: String) -> Bool {
        let normalized = normalizePhrase(value)
        let forbidden: Set<String> = [
            "ключевой момент", "важный момент", "яркий момент", "незабываемый момент",
            "захватывающая сцена", "приключение", "эмоциональный момент", "главный момент",
            "следующий этап путешествия", "событие", "сцена", "съёмка", "материал"
        ]
        return normalized.isEmpty || forbidden.contains(normalized)
    }

    /// Structural beat names are useful inside the edit graph, but are not
    /// audience-facing facts and therefore must never become automatic titles.
    public static func isStructuralPlaceholder(_ value: String) -> Bool {
        let structural: Set<String> = [
            "начало", "подготовка", "действие", "кульминация", "реакция", "завершение",
            "вступление", "завязка", "развитие", "финал", "b roll", "cold open", "intro", "outro",
            "знакомство с местом", "в движении", "пик маршрута", "развитие действия", "дорога домой"
        ]
        return structural.contains(normalizePhrase(value))
    }

    /// Produces a label from analyzed content only. In particular, a proposed
    /// scene title is deliberately not passed as evidence, so callers can use
    /// this as a provenance check before exposing text to the viewer.
    public func contentConfirmedActivityTitle(
        tags: Set<String>,
        summaries: [String] = [],
        proposedTitle: String? = nil,
        provenanceConfidence: Double = 0
    ) -> SmartTitleDecision? {
        let evidence = (Array(tags) + summaries).map(Self.normalizePhrase)
        let proposed = proposedTitle.map(Self.normalizePhrase)
        func has(_ values: [String]) -> Bool {
            evidence.contains { item in values.contains(where: item.contains) }
        }
        // A SourceActivityGroup-labelled buggy block can still carry one stray
        // `bicycle` classifier. Trust that provenance only when several
        // independent visual families corroborate it; the title alone is not
        // enough to manufacture an activity.
        let buggyProvenance = proposed == "багги" || proposed == "поездка на багги"
        let motorVehicle = has(["car", "automobile", "vehicle", "machine", "motor", "utv"])
        let offRoad = has(["dirt road", "dirt_road", "off road", "off-road", "грунт", "бездорож"])
        let mechanics = has(["wheel", "tire", "tyre", "колес", "шина"])
        let safetyGear = has(["helmet", "headgear", "шлем"])
        if buggyProvenance,
           provenanceConfidence >= 0.55,
           motorVehicle,
           offRoad,
           mechanics || safetyGear {
            return decide(SmartTitleContext(
                purpose: .shortLabel,
                tags: tags.union(["buggy"]),
                summaries: summaries
            ))
        }
        return decide(SmartTitleContext(purpose: .shortLabel, tags: tags, summaries: summaries))
    }

    private struct Activity {
        var eventTitle: String
        var shortTitle: String
        var confidence: Double
        var explanation: String
    }

    private func recognizedActivity(in evidence: [String]) -> Activity? {
        let sharedEvidence = ActivityCompatibilityContract.evidence(in: Set(evidence))
        if let family = sharedEvidence.family {
            let confidence = min(0.96, 0.76 + sharedEvidence.confidence * 0.20)
            let markers = sharedEvidence.matchedMarkers
            switch family {
            case .cycling:
                return .init(eventTitle: "Велопрогулка", shortTitle: "Велопрогулка", confidence: confidence, explanation: "Общий activity vocabulary распознал велосипедную прогулку")
            case .motorized:
                if !markers.isDisjoint(with: ["buggy", "багги", "utv", "atv", "quadbike", "quad bike", "side by side", "квадроцикл"]) {
                    return .init(eventTitle: "Поездка на багги", shortTitle: "Багги", confidence: confidence, explanation: "Общий activity vocabulary распознал поездку на багги")
                }
                if !markers.isDisjoint(with: ["motocross", "motorcycle", "motorbike", "мотоцикл"]) {
                    return .init(eventTitle: "Мотопоездка", shortTitle: "Мотопоездка", confidence: confidence, explanation: "Общий activity vocabulary распознал мотопоездку")
                }
                return .init(eventTitle: "В дороге", shortTitle: "В дороге", confidence: confidence, explanation: "Общий activity vocabulary распознал поездку")
            case .paddling:
                return .init(eventTitle: "Сплав", shortTitle: "Сплав", confidence: confidence, explanation: "Общий activity vocabulary распознал греблю или сплав")
            case .fishing:
                return .init(eventTitle: "Рыбалка", shortTitle: "Рыбалка", confidence: confidence, explanation: "Общий activity vocabulary распознал рыбалку")
            case .hiking:
                return .init(eventTitle: "Поход", shortTitle: "Поход", confidence: confidence, explanation: "Общий activity vocabulary распознал поход")
            case .running:
                return .init(eventTitle: "Пробежка", shortTitle: "Пробежка", confidence: confidence, explanation: "Общий activity vocabulary распознал пробежку")
            case .swimming:
                return .init(eventTitle: "Плавание", shortTitle: "Плавание", confidence: confidence, explanation: "Общий activity vocabulary распознал плавание")
            case .winterSports:
                return .init(eventTitle: "На склоне", shortTitle: "На склоне", confidence: confidence, explanation: "Общий activity vocabulary распознал зимний спорт")
            case .surfing:
                return .init(eventTitle: "Сёрфинг", shortTitle: "Сёрфинг", confidence: confidence, explanation: "Общий activity vocabulary распознал сёрфинг")
            case .climbing:
                return .init(eventTitle: "Скалолазание", shortTitle: "Скалолазание", confidence: confidence, explanation: "Общий activity vocabulary распознал скалолазание")
            case .equestrian:
                return .init(eventTitle: "Конная прогулка", shortTitle: "Конная прогулка", confidence: confidence, explanation: "Общий activity vocabulary распознал конную прогулку")
            }
        }
        let text = evidence.joined(separator: " ")
        func has(_ values: [String]) -> Bool { values.contains(where: text.contains) }
        if has(["buggy", "багги", "side by side", "utv"]) { return .init(eventTitle: "Поездка на багги", shortTitle: "Багги", confidence: 0.96, explanation: "Распознана поездка на багги") }
        if has(["cycling", "cyclist", "bicycle", "bike ride", "велосип", "велопрогул"]) { return .init(eventTitle: "Велопрогулка", shortTitle: "Велопрогулка", confidence: 0.94, explanation: "Распознана велосипедная прогулка") }
        if has(["rafting", "kayak", "каяк", "сплав", "порог"]) { return .init(eventTitle: "Сплав", shortTitle: "Сплав", confidence: 0.94, explanation: "Распознана водная активность") }
        if has(["fishing", "angler", "рыбал"]) { return .init(eventTitle: "Рыбалка", shortTitle: "Рыбалка", confidence: 0.94, explanation: "Распознана рыбалка") }
        if has(["sunset", "закат"]) { return .init(eventTitle: "Закат", shortTitle: "Закат", confidence: 0.92, explanation: "Распознан закат") }
        if has(["morning", "утро"]) && has(["lake", "озер"]) { return .init(eventTitle: "Утро у озера", shortTitle: "Утро у озера", confidence: 0.91, explanation: "Распознаны время суток и место") }
        if has(["hiking", "trekking", "trail", "поход"]) { return .init(eventTitle: "Поход", shortTitle: "Поход", confidence: 0.88, explanation: "Распознан пеший маршрут") }
        if has(["mountain", "горы", "горн"]) { return .init(eventTitle: "Поездка в горы", shortTitle: "В горах", confidence: 0.84, explanation: "Распознан горный маршрут") }
        if has(["campfire", "bonfire", "костер", "костёр"]) { return .init(eventTitle: "Вечер у костра", shortTitle: "У костра", confidence: 0.90, explanation: "Распознан вечер у костра") }
        if has(["beach", "sea", "море", "пляж"]) { return .init(eventTitle: "День у моря", shortTitle: "У моря", confidence: 0.84, explanation: "Распознана съёмка у моря") }
        if has(["lake", "озер"]) { return .init(eventTitle: "У озера", shortTitle: "У озера", confidence: 0.80, explanation: "Распознано озеро") }
        if has(["river", "река"]) { return .init(eventTitle: "На реке", shortTitle: "На реке", confidence: 0.78, explanation: "Распознана река") }
        if has(["cottage", "country house", "дача"]) { return .init(eventTitle: "Поездка на дачу", shortTitle: "На даче", confidence: 0.88, explanation: "Распознана поездка на дачу") }
        if has(["birthday", "день рождения"]) { return .init(eventTitle: "День рождения", shortTitle: "День рождения", confidence: 0.90, explanation: "Распознан день рождения") }
        if has(["wedding", "свадьб"]) { return .init(eventTitle: "Свадьба", shortTitle: "Свадьба", confidence: 0.92, explanation: "Распознана свадьба") }
        if has(["walk", "walking", "прогул"]) && has(["embankment", "waterfront", "набереж"]) { return .init(eventTitle: "Прогулка по набережной", shortTitle: "На набережной", confidence: 0.88, explanation: "Распознана прогулка по набережной") }
        if has(["road", "drive", "driving", "дорог"]) { return .init(eventTitle: "В дороге", shortTitle: "В дороге", confidence: 0.70, explanation: "Распознана дорожная сцена") }
        if has(["family", "семья"]) { return .init(eventTitle: "Семейный день", shortTitle: "Семья", confidence: 0.72, explanation: "Распознана семейная съёмка") }
        return nil
    }

    private func selectTemplate(primaryText: String, secondaryText: String?, context: SmartTitleContext, evidence: [String]) -> TitleTemplateDefinition? {
        let categories: Set<TitleTemplateCategory>
        switch context.purpose {
        case .filmOpening: categories = [.mainTitles, .cinematicTitles, .minimalTitles]
        case .chapter: categories = [.chapterTitles, .mainTitles, .minimalTitles]
        case .location: categories = [.locationTitles, .lowerThirds, .minimalTitles]
        case .dateChronicle: categories = [.dateTime, .minimalTitles]
        case .activity: categories = [.mainTitles, .lowerThirds, .dynamicKinetic, .minimalTitles]
        case .shortLabel: categories = [.lowerThirds, .locationTitles, .minimalTitles]
        case .ending: categories = [.endCards]
        }
        let dynamic = evidence.contains { ["action", "sport", "speed", "high speed", "экшен", "динами"].contains(where: $0.contains) }
        let calm = evidence.contains { ["sunset", "закат", "calm", "тихо", "lake", "озер"].contains(where: $0.contains) }
        let candidates = TitleTemplateRegistry.all.filter { categories.contains($0.category) }
        return candidates.max { lhs, rhs in
            score(lhs, primaryText: primaryText, secondaryText: secondaryText, context: context, dynamic: dynamic, calm: calm)
                < score(rhs, primaryText: primaryText, secondaryText: secondaryText, context: context, dynamic: dynamic, calm: calm)
        }
    }

    private func score(_ template: TitleTemplateDefinition, primaryText: String, secondaryText: String?, context: SmartTitleContext, dynamic: Bool, calm: Bool) -> Double {
        var value = 0.0
        if template.id == context.preferredTemplateID { value += 2.2 }
        switch context.purpose {
        case .filmOpening:
            if [.mainTitles, .cinematicTitles].contains(template.category) { value += 0.9 }
        case .chapter:
            if template.category == .chapterTitles { value += 1.35 }
        case .location:
            if template.category == .locationTitles { value += 1.35 }
        case .dateChronicle:
            if template.category == .dateTime { value += 1.35 }
        case .activity:
            if template.category == .mainTitles { value += 0.65 }
        case .shortLabel:
            if template.category == .lowerThirds { value += 1.1 }
        case .ending:
            if template.category == .endCards { value += 1.4 }
        }
        if primaryText.count <= template.textConstraints.maxCharacters { value += 0.8 }
        else { value -= Double(primaryText.count - template.textConstraints.maxCharacters) * 0.04 }
        let supportsSecondary = template.layout.elements.contains { $0.content == .secondaryText }
        if secondaryText != nil { value += supportsSecondary ? 0.42 : -0.35 }
        if dynamic, template.category == .dynamicKinetic { value += 0.75 }
        if calm, [.cinematicTitles, .minimalTitles].contains(template.category) { value += 0.55 }
        value -= overlapPenalty(template: template, avoidRegions: context.avoidRegions) * 2.4
        // Stable tie-breaker without random template selection.
        value -= Double(TitleTemplateRegistry.all.firstIndex(where: { $0.id == template.id }) ?? 0) * 0.0001
        return value
    }

    private func overlapPenalty(template: TitleTemplateDefinition, avoidRegions: [NormalizedRegion]) -> Double {
        guard !avoidRegions.isEmpty else { return 0 }
        let safe = template.safeArea
        let contentFrames = template.layout.elements.filter { $0.kind == .text }.map { element -> CGRect in
            let xBase = element.followsSafeArea ? safe.horizontal : 0
            let yBase = element.followsSafeArea ? safe.vertical : 0
            let widthBase = element.followsSafeArea ? 1 - safe.horizontal * 2 : 1
            let heightBase = element.followsSafeArea ? 1 - safe.vertical * 2 : 1
            return CGRect(
                x: xBase + element.frame.x * widthBase,
                y: yBase + element.frame.y * heightBase,
                width: element.frame.width * widthBase,
                height: element.frame.height * heightBase
            )
        }
        return avoidRegions.reduce(0) { total, region in
            let topLeftRegion = CGRect(x: region.x, y: 1 - region.y - region.height, width: region.width, height: region.height)
            return total + contentFrames.reduce(0) { subtotal, frame in
                let intersection = frame.intersection(topLeftRegion)
                guard !intersection.isNull else { return subtotal }
                return subtotal + Double(intersection.width * intersection.height / max(0.0001, min(frame.width * frame.height, topLeftRegion.width * topLeftRegion.height)))
            }
        }
    }

    private func disambiguated(_ primary: String, context: SmartTitleContext, location: String?, date: String?) -> String {
        let used = Set(context.usedTitles.map(Self.normalizePhrase))
        guard used.contains(Self.normalizePhrase(primary)) else { return primary }
        if let location, !Self.normalizePhrase(primary).contains(Self.normalizePhrase(location)) {
            return "\(primary) — \(location)"
        }
        if let date, !Self.normalizePhrase(primary).contains(Self.normalizePhrase(date)) {
            return "\(primary) — \(date)"
        }
        if let index = context.sequenceIndex { return "\(primary) · \(max(1, index))" }
        return primary
    }

    private func meaningfulRequestedText(_ value: String?) -> String? {
        guard let clean = value?.trimmingCharacters(in: .whitespacesAndNewlines), !Self.isMeaningless(clean) else { return nil }
        return Self.isStructuralPlaceholder(clean) ? nil : clean
    }

    private func reliableLocation(_ value: String?, confidence: Double) -> String? {
        guard confidence >= 0.55,
              let clean = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              clean.count >= 2,
              !clean.lowercased().contains("gps"),
              clean.rangeOfCharacter(from: .letters) != nil else { return nil }
        return clean
    }

    private func normalizedEvidence(_ context: SmartTitleContext) -> [String] {
        (Array(context.tags) + context.summaries + [context.requestedText ?? "", context.locationName ?? ""])
            .map(Self.normalizePhrase)
            .filter { !$0.isEmpty }
    }

    private func supportingContext(location: String?, date: String?, includeDate: Bool, excluding primary: String) -> String? {
        let values = [location, includeDate ? date : nil].compactMap { $0 }.filter { !Self.normalizePhrase(primary).contains(Self.normalizePhrase($0)) }
        return values.isEmpty ? nil : values.joined(separator: " · ")
    }

    private static func russianDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "d MMMM yyyy"
        return formatter.string(from: date)
    }

    private static func normalizePhrase(_ value: String) -> String {
        value.lowercased()
            .replacingOccurrences(of: "ё", with: "е")
            .split { !$0.isLetter && !$0.isNumber }
            .joined(separator: " ")
    }

    private static func shortened(_ value: String, limit: Int) -> String {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count > limit else { return clean }
        let replacements = [
            "Поездка с друзьями в ": "",
            " на майские праздники": "",
            " года": "",
            "Первый день в ": ""
        ]
        var compact = clean
        for (source, replacement) in replacements { compact = compact.replacingOccurrences(of: source, with: replacement, options: [.caseInsensitive]) }
        guard compact.count > limit else { return compact }
        let prefix = compact.prefix(limit - 1)
        let boundary = prefix.lastIndex(of: " ") ?? prefix.endIndex
        let shortened = prefix[..<boundary].trimmingCharacters(in: .whitespacesAndNewlines)
        return shortened.isEmpty ? String(prefix) : "\(shortened)…"
    }
}

/// Repairs only titles known to have been generated by the director. Manual
/// title layering stays untouched, while placeholder prose, exact duplicate
/// commands and accidental same-track collisions are removed from old films.
public struct AutomatedTitleQualityDiagnostic: Hashable, Sendable {
    public var code: String
    public var titleID: UUID
    public var message: String

    public init(code: String, titleID: UUID, message: String) {
        self.code = code
        self.titleID = titleID
        self.message = message
    }
}

public struct AutomatedTitleQualityResult: Sendable {
    public var titles: [TitleTimelineItem]
    public var diagnostics: [AutomatedTitleQualityDiagnostic]

    public init(titles: [TitleTimelineItem], diagnostics: [AutomatedTitleQualityDiagnostic]) {
        self.titles = titles
        self.diagnostics = diagnostics
    }
}

public enum AutomatedTitlePolicy {
    /// Runs immediately before a generated timeline is returned or an older
    /// timeline is migrated. Manual title layering and captions remain intact.
    public static func reviewed(
        _ source: [TitleTimelineItem],
        timelineDuration: Double,
        containmentByTitleID: [UUID: ClosedRange<Double>] = [:]
    ) -> AutomatedTitleQualityResult {
        let timelineEnd = max(0, timelineDuration)
        let minimumReadableDuration = 1.25
        let titleGap = 0.08
        var seenGenerated = Set<String>()
        var lastGeneratedTextByTrack: [Int: String] = [:]
        var result: [TitleTimelineItem] = []
        var diagnostics: [AutomatedTitleQualityDiagnostic] = []

        func reject(_ item: TitleTimelineItem, code: String, message: String) {
            diagnostics.append(.init(code: code, titleID: item.id, message: message))
        }

        for original in source.sorted(by: titleOrder) {
            var item = original
            let generated = isGenerated(item)
            guard generated, !isCaption(item.kind) else {
                result.append(item)
                continue
            }
            let normalized = normalizedTitle(item.text)
            if SmartTitleEngine.isMeaningless(item.text) || SmartTitleEngine.isStructuralPlaceholder(item.text) {
                reject(item, code: "unconfirmed-text", message: "Автотитр «\(item.text)» удалён: это placeholder или структурное имя beat-а")
                continue
            }
            let identity = "\(item.track)|\(normalized)|\(Int((item.startTime * 10).rounded()))"
            if !seenGenerated.insert(identity).inserted {
                reject(item, code: "exact-duplicate", message: "Повторная команда автотитра «\(item.text)» удалена")
                continue
            }
            if lastGeneratedTextByTrack[item.track] == normalized {
                reject(item, code: "adjacent-duplicate", message: "Соседний повтор автотитра «\(item.text)» удалён")
                continue
            }

            let requestedScope = containmentByTitleID[item.id]
            let lowerBound = max(0, requestedScope?.lowerBound ?? 0)
            let upperBound = min(timelineEnd, requestedScope?.upperBound ?? timelineEnd)
            guard lowerBound.isFinite, upperBound.isFinite, upperBound > lowerBound else {
                reject(item, code: "empty-containment", message: "Автотитр «\(item.text)» удалён: его story block пуст")
                continue
            }

            let originalStart = item.startTime
            let originalEnd = item.endTime
            item.startTime = min(max(item.startTime, lowerBound), upperBound)
            var end = min(originalEnd, upperBound)

            if let collision = result.last(where: {
                $0.enabled && $0.track == item.track && isGenerated($0) && !isCaption($0.kind)
                    && $0.startTime < end && $0.endTime > item.startTime
            }) {
                item.startTime = max(item.startTime, collision.endTime + titleGap)
            }
            end = min(end, upperBound)
            let available = end - item.startTime
            guard available + 0.000_001 >= minimumReadableDuration else {
                reject(item, code: "unreadable-placement", message: "Автотитр «\(item.text)» удалён: в его story block нет 1,25 секунды без наложения")
                continue
            }
            item.duration = available
            if abs(item.startTime - originalStart) > 0.000_001 || abs(item.endTime - originalEnd) > 0.000_001 {
                let message = "Quality gate ограничил автотитр границами story block и свободным участком дорожки"
                item.explanation.append(message)
                diagnostics.append(.init(code: "repaired-placement", titleID: item.id, message: message))
            }
            result.append(item)
            lastGeneratedTextByTrack[item.track] = normalized
        }
        return AutomatedTitleQualityResult(titles: result.sorted(by: titleOrder), diagnostics: diagnostics)
    }

    public static func sanitized(_ source: [TitleTimelineItem], timelineDuration: Double) -> [TitleTimelineItem] {
        reviewed(source, timelineDuration: timelineDuration).titles
    }

    /// Reconstructs a title's activity scope after Director tools have retimed
    /// the timeline. Composer links generated chapter titles to their anchor
    /// clip; legacy titles fall back to the block visible at their start time.
    public static func inferredContainmentByTitleID(
        _ source: [TitleTimelineItem],
        timeline: Timeline
    ) -> [UUID: ClosedRange<Double>] {
        let primaries = timeline.items
            .filter { $0.overlay == nil && $0.kind != .title }
            .sorted { $0.timelineStart < $1.timelineStart }
        guard !primaries.isEmpty else { return [:] }
        var scopes: [UUID: ClosedRange<Double>] = [:]

        for title in source where isGenerated(title) && !isCaption(title.kind) {
            let anchorIndex = title.targetClipID.flatMap { targetID in
                primaries.firstIndex { $0.id == targetID }
            } ?? primaries.firstIndex {
                title.startTime + 0.000_001 >= $0.timelineStart
                    && title.startTime < $0.timelineStart + $0.timelineDuration
            } ?? primaries.firstIndex { $0.timelineStart >= title.startTime }
                ?? primaries.index(before: primaries.endIndex)
            let anchor = primaries[anchorIndex]
            let sameBlock: (TimelineItem) -> Bool = { item in
                if let sceneID = anchor.eventSceneID { return item.eventSceneID == sceneID }
                if let eventID = anchor.eventID { return item.eventID == eventID }
                return item.id == anchor.id
            }
            var lower = anchorIndex
            while lower > primaries.startIndex, sameBlock(primaries[primaries.index(before: lower)]) {
                lower = primaries.index(before: lower)
            }
            var upper = anchorIndex
            while primaries.index(after: upper) < primaries.endIndex,
                  sameBlock(primaries[primaries.index(after: upper)]) {
                upper = primaries.index(after: upper)
            }
            let start = primaries[lower].timelineStart
            let end = primaries[upper].timelineStart + primaries[upper].timelineDuration
            if end > start { scopes[title.id] = start...end }
        }
        return scopes
    }

    private static func normalizedTitle(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .replacingOccurrences(of: "ё", with: "е")
    }

    private static func isGenerated(_ item: TitleTimelineItem) -> Bool {
        item.explanation.contains { reason in
            let value = reason.lowercased()
            return value.contains("режисс") || value.contains("автомат") || value.contains("event hierarchy")
        }
    }

    private static func isCaption(_ kind: TitleTimelineKind) -> Bool {
        [.subtitle, .automaticSubtitles, .wordLevelCaptions].contains(kind)
    }

    private static func titleOrder(_ lhs: TitleTimelineItem, _ rhs: TitleTimelineItem) -> Bool {
        if lhs.startTime != rhs.startTime { return lhs.startTime < rhs.startTime }
        if lhs.track != rhs.track { return lhs.track < rhs.track }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}
