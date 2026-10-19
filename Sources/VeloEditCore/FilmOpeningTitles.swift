import CoreGraphics
import Foundation

public enum FilmOpeningPolicy: String, Codable, CaseIterable, Identifiable, Sendable {
    case automatic, selected, off
    public var id: String { rawValue }
    public var localizedTitle: String {
        switch self { case .automatic: return "Авто"; case .selected: return "Выбрать оформление"; case .off: return "Выключено" }
    }
}

public struct FilmOpeningSettings: Codable, Hashable, Sendable {
    public var policy: FilmOpeningPolicy
    public var title: String
    public var subtitle: String
    public var templateID: String?
    public init(policy: FilmOpeningPolicy = .automatic, title: String = "", subtitle: String = "", templateID: String? = nil) {
        self.policy = policy; self.title = title; self.subtitle = subtitle; self.templateID = templateID
    }
}

public struct FilmOpeningDecision: Codable, Hashable, Sendable {
    public var version = 1
    public var contextSignature: String
    public var titleSource: String
    public var reason: String
    public var warning: String?
    public var readingDuration: Double
    /// A combined opening fulfils this heading without deleting the film part.
    public var combinedChapter: TitleTimelineItem?
    public var movedChapter: TitleTimelineItem?
}

public struct FilmOpeningEvidence: Codable, Hashable, Sendable {
    public var spacious: Bool
    public var busy: Bool
    public var dynamics: Double
    public var protectedCenter: Bool
    public var protectedUpper: Bool
}

/// The single reconciliation point used by assembly, repairs and explicit UI
/// changes. It never changes media, audio, or the primary storyline's duration.
public enum FilmOpeningTitles {
    public static func restoringChapters(_ source: Timeline) -> Timeline {
        guard source.openingTitleDecision?.combinedChapter != nil || source.openingTitleDecision?.movedChapter != nil else { return source }
        var result = source
        var titles = source.effectiveTitleItems
        if let chapter = source.openingTitleDecision?.combinedChapter,
           !titles.contains(where: { $0.id == chapter.id }) { titles.append(chapter) }
        if let chapter = source.openingTitleDecision?.movedChapter,
           let index = titles.firstIndex(where: { $0.id == chapter.id && $0.userEdited != true }) { titles[index] = chapter }
        result.titleItems = titles
        return result
    }

    public static func reconcile(_ source: Timeline, plan: StoryPlan, projectName: String? = nil, analyses: [AnalysisResult] = [],
                                 applying settings: FilmOpeningSettings? = nil) -> Timeline {
        guard let settings = settings ?? source.openingTitles ?? plan.directorBrief?.openingTitles
                ?? (EditorialIntentEnforcer.requestsAdditionalTitles(plan.prompt) ? FilmOpeningSettings() : nil) else { return source }
        var result = source
        result.openingTitles = settings
        let firstIDs = Set(source.items.filter { $0.overlay == nil && $0.timelineStart < 7 }.compactMap(\.candidateID))
        let observed = analyses.flatMap(\.candidates).filter { firstIDs.contains($0.id) }
        if !observed.isEmpty {
            let tags = Set(observed.flatMap(\.tags).map { $0.lowercased() })
            let tracks = observed.compactMap { $0.insights?.subjectTracking?.mainSubject }.filter { $0.kind != .unknown }
            let regions = tracks.flatMap(\.observations)
            result.openingTitleEvidence = FilmOpeningEvidence(
                spacious: !tags.isDisjoint(with: ["landscape", "nature", "scenery", "travel", "пейзаж", "природа", "путешествие"]),
                busy: observed.contains { ($0.insights?.shake ?? 0) > 0.45 || ($0.insights?.motionBlur ?? 0) > 0.4 },
                dynamics: observed.map { $0.insights?.dynamics ?? $0.scores.action }.max() ?? 0,
                protectedCenter: regions.contains { $0.confidence >= 0.6 && $0.region.x < 0.8 && $0.region.x + $0.region.width > 0.2 && $0.region.y < 0.65 && $0.region.y + $0.region.height > 0.35 },
                protectedUpper: regions.contains { $0.confidence >= 0.6 && $0.region.y < 0.35 })
        }
        if ExplicitDeliveryRequirements(plan: plan).forbidsTitles || plan.directorBrief?.titlePolicy == DirectorTitlePolicy.none {
            result.titleItems = source.effectiveTitleItems.filter { $0.kind.category == .captions && plan.directorBrief?.subtitlesEnabled(preset: plan.preset) == true }
            result.openingTitleDecision = nil
            return result
        }
        var titles = source.effectiveTitleItems
        let existing = titles.first { $0.semanticRole == .filmOpening }
        // Undo our own previous chapter scheduling before re-evaluating. Never
        // overwrite a subsequent inspector edit to that chapter.
        if let chapter = source.openingTitleDecision?.combinedChapter,
           !titles.contains(where: { $0.id == chapter.id }) { titles.append(chapter) }
        if let chapter = source.openingTitleDecision?.movedChapter,
           let index = titles.firstIndex(where: { $0.id == chapter.id && $0.userEdited != true }) { titles[index] = chapter }
        titles.removeAll { $0.semanticRole == .filmOpening }
        if settings.policy == .off {
            result.titleItems = titles; result.openingTitleDecision = nil
            return result
        }
        let preserved = settings == source.openingTitles && existing?.userEdited == true ? existing : nil
        let context = plan.chapters.map { $0.chapterCardTitle ?? $0.title }
            .filter { !SmartTitleEngine.isPlaceholderTitle($0) }
        let signature = ProductionCacheIdentity.hash(context.sorted())
        let authored = settings.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let project = meaningfulName(projectName)
        let evidence = meaningfulName(plan.eventStory?.projectTitle)
        let retainedText = source.openingTitleDecision?.contextSignature == signature ? existing?.text : nil
        let unique = context.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        let joined = unique.joined(separator: " и ")
        let common = !joined.isEmpty && joined.split(whereSeparator: \.isWhitespace).count <= 6 && joined.count <= 60 ? joined : nil
        let text = !authored.isEmpty ? settings.title : project ?? retainedText ?? evidence ?? common ?? "Мой фильм"
        let provenance = !authored.isEmpty ? "user" : project != nil ? "project" : retainedText != nil
            ? (source.openingTitleDecision?.titleSource ?? "whole-film") : evidence != nil || common != nil ? "whole-film" : "neutral"
        let mood = DirectorVisualStyle(plan: plan).mood
        let words = text.split(whereSeparator: \.isWhitespace).count
        let hasSpeech = titles.contains { $0.kind.category == .captions && $0.startTime < 7 && $0.enabled }
        let observation = result.openingTitleEvidence
        let crowded = hasSpeech || source.effectiveTelemetryItems.contains { $0.timelineStart < 7 }
            || observation?.busy == true || observation?.protectedCenter == true
        var chosen = "title.minimal-clean.v1"
        if !crowded && text.count < 44 && source.width >= source.height {
            if mood == .dynamic && words <= 3 && (observation?.dynamics ?? 0) >= 0.6 { chosen = "title.dynamic.v1" }
            else if observation?.spacious == true { chosen = "title.cinematic-clean.v1" }
        }
        if settings.policy == .selected, let id = settings.templateID,
           TitleTemplateRegistry.template(id: id)?.supportsFilmOpening == true { chosen = id }
        let template = TitleTemplateRegistry.template(id: chosen)!
        let short = source.duration <= 15
        let veryShort = source.duration < 6
        let start = veryShort ? 0.0 : short ? 0.6 : 0.8
        let subtitle = short || settings.subtitle.isEmpty ? nil : settings.subtitle
        let requiredReading = max(veryShort ? 1.5 : short ? 1.8 : 2.5,
                                  Double(text.count + (subtitle?.count ?? 0)) / 14)
        let requestedDuration = veryShort ? source.duration : short ? max(2.5, min(3.5, requiredReading + 1.5)) : max(4.6, requiredReading + 1.5)
        var title = preserved ?? TitleTimelineItem(id: existing?.id ?? EditorialIdentity.uuid("film-opening-v1|\(source.storyPlanID)"),
            kind: template.kind, templateID: template.id, text: text, additionalText: subtitle,
            startTime: start, duration: min(requestedDuration, max(0.05, source.duration - start)),
            style: template.defaultStyle, explanation: ["Автоматическое название всего фильма: \(provenance)"])
        title.semanticRole = .filmOpening
        title.targetClipID = nil; title.anchorClipID = nil
        title.duration = min(title.duration, max(0.05, source.duration - title.startTime))
        if veryShort && preserved == nil { title.animation = .init(entrance: .none, exit: .none, duration: 0) }
        let motion = template.animationFitted(to: title.duration)
        let stagger = Double(template.layout.elements.map(\.staggerIndex).max() ?? 0)
        let reading = veryShort ? title.duration : title.duration - motion.animationIn.duration - motion.animationOut.duration
            - stagger * (motion.animationIn.stagger + motion.animationOut.stagger)
        var decision = FilmOpeningDecision(contextSignature: signature, titleSource: provenance,
            reason: settings.policy == .selected ? "Выбор пользователя" : crowded ? "Простой титр рядом с речью или телеметрией" : "Настроение, длина названия и формат кадра",
            readingDuration: reading)
        if observation?.protectedCenter == true && observation?.protectedUpper == false && settings.policy != .selected && preserved == nil {
            title.style.placement = .upper
        } else if observation?.protectedCenter == true {
            if preserved == nil { title.enabled = false }
            decision.warning = "Название перекрывает важный объект в начальных кадрах. Выберите время или положение титра в инспекторе."
        }
        if reading + 0.05 < requiredReading { decision.warning = "Начальный фрагмент слишком короткий для полного чтения названия." }
        if let sizing = TitleOverlayRenderer.textSizing(item: title, renderSize: CGSize(width: source.width, height: source.height)),
           sizing.isTruncated || sizing.fontSize < 28 {
            decision.warning = "Название не помещается целиком с читаемым размером. Измените текст или оформление."
            if preserved == nil { title.enabled = false }
        }
        // Scheduling is transactional: an opener rejected by any conflict
        // must leave every existing heading at its original time.
        let unscheduledTitles = titles
        // A chapter may follow the opener only while its own material remains.
        for index in titles.indices where title.enabled && titles[index].enabled && titles[index].kind.category != .captions
            && titles[index].duration >= 1.25 && !titles[index].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && titles[index].startTime >= 0 && titles[index].endTime <= source.duration
            && titles[index].startTime < title.endTime + 0.15 && titles[index].endTime > title.startTime {
            let chapter = titles[index]
            let blocks = EditorialPresentationPolicy.chapterBlocks(in: source, plan: plan)
            let blockEnd = blocks.first { chapter.startTime >= $0.start && chapter.startTime < $0.end }?.end ?? source.duration
            let newStart = title.endTime + 0.15
            if chapter.kind == .chapter && chapter.userEdited != true && newStart + chapter.duration <= blockEnd {
                decision.movedChapter = chapter
                titles[index].startTime = newStart
                titles[index].anchorClipID = nil
            } else if chapter.kind == .chapter && chapter.userEdited != true && title.endTime <= blockEnd
                        && (chapter.text == title.text || (subtitle == nil && !short && preserved == nil)) {
                if chapter.text != title.text { title.additionalText = chapter.text }
                title.fulfilledChapterID = chapter.id
                title.filmPartID = chapter.filmPartID
                decision.combinedChapter = chapter
                titles[index].enabled = false
            } else {
                decision.warning = "Вступление пересекается с обязательным или ручным титром. Сохранён титр части; выберите время вступления."
                if preserved == nil { title.enabled = false }
            }
        }
        if decision.combinedChapter != nil {
            titles.removeAll { $0.id == decision.combinedChapter?.id }
            let combinedReading = Double(title.text.count + (title.additionalText?.count ?? 0)) / 14
            if combinedReading > reading || TitleOverlayRenderer.textSizing(item: title, renderSize: CGSize(width: source.width, height: source.height), elementID: "secondary")?.isTruncated == true {
                titles.append(decision.combinedChapter!)
                decision.combinedChapter = nil; title.fulfilledChapterID = nil; title.filmPartID = nil
                title.additionalText = preserved?.additionalText ?? subtitle; if preserved == nil { title.enabled = false }
                decision.warning = "Название фильма и первой части не помещаются вместе. Сохранён титр части."
            }
        }
        if source.duration < 0.25 { title.enabled = false; decision.warning = "Материал слишком короткий для вступления." }
        if !title.enabled {
            titles = unscheduledTitles
            decision.combinedChapter = nil; decision.movedChapter = nil
            title.fulfilledChapterID = nil; title.filmPartID = nil
            title.additionalText = preserved?.additionalText ?? subtitle
        }
        titles.append(title)
        result.titleItems = titles.sorted { $0.startTime == $1.startTime ? $0.id.uuidString < $1.id.uuidString : $0.startTime < $1.startTime }
        result.openingTitleDecision = decision
        return result
    }

    public static func meaningfulName(_ value: String?) -> String? {
        guard let text = value?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
              !SmartTitleEngine.isMeaningless(text),
              text.range(of: #"(?i)^(untitled|без названия|новый проект|veloedit|project|проект|GX\d|GH\d|IMG[_-]|DSC[_-]|\d{4}[-_.])|\.(mp4|mov|jpg|png|veloedit)$"#, options: .regularExpression) == nil else { return nil }
        return text
    }

    public static func rememberDeletion(in timeline: inout Timeline, titleID: UUID) {
        guard timeline.effectiveTitleItems.contains(where: { $0.id == titleID && $0.semanticRole == .filmOpening }) else { return }
        var settings = timeline.openingTitles ?? FilmOpeningSettings()
        settings.policy = .off
        timeline.openingTitles = settings
        timeline = restoringChapters(timeline)
        timeline.openingTitleDecision = nil
    }
}
