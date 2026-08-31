import Foundation

public enum DirectorRequestMode: String, Sendable {
    case edit
    case advisory
}

/// Keeps questions and creative suggestions out of the edit queue. The
/// explicit non-destructive wording wins even if the same sentence mentions
/// music or titles, because those words are otherwise valid editing commands.
public struct DirectorRequestIntentInterpreter: Sendable {
    public init() {}

    public func mode(for prompt: String) -> DirectorRequestMode {
        let text = prompt.lowercased()
        let explicitlyReadOnly = [
            "не трогай", "не меняй", "не изменяй", "без изменений",
            "ничего не меняй", "не добавляй", "только предложи", "только посоветуй",
            "без монтажа", "без редактирования", "without changing", "advice only"
        ].contains(where: text.contains)
        if explicitlyReadOnly { return .advisory }

        let asksForSuggestion = [
            "посоветуй", "предложи", "что подойдет", "что подойдёт",
            "какая музыка", "какой трек", "какой саундтрек",
            "как назвать", "придумай название", "варианты названия",
            "что за шум", "какой это шум", "определи шум", "что слышно"
        ].contains(where: text.contains)
        return asksForSuggestion ? .advisory : .edit
    }
}

/// Compact, media-safe context sent to the language director. Original media,
/// frames and file paths never leave the editing pipeline.
public struct DirectorContext: Equatable, Sendable {
    public var assetCount: Int
    public var videoCount: Int
    public var photoCount: Int
    public var analyzedCount: Int
    public var candidateCount: Int
    public var currentTimelineItemCount: Int
    public var localMusicTrackCount: Int
    public var currentMusicTrackTitle: String?
    public var targetDuration: Double
    public var preset: FilmPreset
    public var currentOperation: String
    public var storyRoles: [String]
    public var selectedItemSummary: String?
    public var playheadTime: Double?
    public var neighboringItemSummaries: [String]
    public var lastDirectorReviewScore: Double?
    public var autonomousStyleLabel: String?
    public var autonomousDurationConfidence: Double?
    public var autonomousDecisionReasons: [String]
    public var contentHints: [String]
    public var audioHints: [String]

    public init(
        assetCount: Int,
        videoCount: Int,
        photoCount: Int,
        analyzedCount: Int,
        candidateCount: Int,
        currentTimelineItemCount: Int,
        localMusicTrackCount: Int = 0,
        currentMusicTrackTitle: String? = nil,
        targetDuration: Double,
        preset: FilmPreset,
        currentOperation: String,
        storyRoles: [String] = [],
        selectedItemSummary: String? = nil,
        playheadTime: Double? = nil,
        neighboringItemSummaries: [String] = [],
        lastDirectorReviewScore: Double? = nil,
        autonomousStyleLabel: String? = nil,
        autonomousDurationConfidence: Double? = nil,
        autonomousDecisionReasons: [String] = [],
        contentHints: [String] = [],
        audioHints: [String] = []
    ) {
        self.assetCount = assetCount
        self.videoCount = videoCount
        self.photoCount = photoCount
        self.analyzedCount = analyzedCount
        self.candidateCount = candidateCount
        self.currentTimelineItemCount = currentTimelineItemCount
        self.localMusicTrackCount = localMusicTrackCount
        self.currentMusicTrackTitle = currentMusicTrackTitle
        self.targetDuration = targetDuration
        self.preset = preset
        self.currentOperation = currentOperation
        self.storyRoles = storyRoles
        self.selectedItemSummary = selectedItemSummary
        self.playheadTime = playheadTime
        self.neighboringItemSummaries = neighboringItemSummaries
        self.lastDirectorReviewScore = lastDirectorReviewScore
        self.autonomousStyleLabel = autonomousStyleLabel
        self.autonomousDurationConfidence = autonomousDurationConfidence
        self.autonomousDecisionReasons = autonomousDecisionReasons
        self.contentHints = contentHints
        self.audioHints = audioHints
    }

    public var modelPrompt: String {
        """
        В проекте: \(assetCount) материалов (видео: \(videoCount), фото: \(photoCount)).
        Проанализировано: \(analyzedCount) из \(assetCount), найдено кандидатов: \(candidateCount).
        Текущий монтаж: \(currentTimelineItemCount) фрагментов.
        Локальная музыкальная библиотека: \(localMusicTrackCount) треков. Текущий трек: \(currentMusicTrackTitle ?? "не выбран").
        Выбранный стиль: \(preset.localizedTitle). Целевая длительность: \(Self.durationText(targetDuration)).
        Story Plan: \(storyRoles.isEmpty ? "ещё не создан" : storyRoles.joined(separator: " → ")).
        Выбранный объект: \(selectedItemSummary ?? "нет"). Playhead: \(playheadTime.map { String(format: "%.2f с", $0) } ?? "не задан").
        Соседний контекст: \(neighboringItemSummaries.isEmpty ? "нет" : neighboringItemSummaries.joined(separator: " | ")).
        Оценка последнего self-review: \(lastDirectorReviewScore.map { String(format: "%.0f%%", $0 * 100) } ?? "нет").
        Autonomous ProjectStyle: \(autonomousStyleLabel ?? "ещё не определён"). Confidence длительности: \(autonomousDurationConfidence.map { String(format: "%.0f%%", $0 * 100) } ?? "нет").
        Объяснимые решения AI Director: \(autonomousDecisionReasons.isEmpty ? "нет" : autonomousDecisionReasons.joined(separator: " | ")).
        Смысловые подсказки из анализа: \(contentHints.isEmpty ? "нет" : contentHints.joined(separator: " | ")).
        Аудио из анализа: \(audioHints.isEmpty ? "нет" : audioHints.joined(separator: " | ")).
        Доступно типизированных editing tools: \(DirectorEditingTool.allCases.count).
        Текущая операция приложения: \(currentOperation).
        """
    }

    private static func durationText(_ seconds: Double) -> String {
        if seconds < 60 { return "\(Int(seconds.rounded())) секунд" }
        return String(format: "%.1f минуты", seconds / 60)
    }
}

/// A deterministic reply is intentionally always available. It is used when
/// none of the local language-model runtimes can answer.
public struct DirectorFallbackReply: Sendable {
    public init() {}

    public func make(userMessage: String, context: DirectorContext) -> String {
        let lower = userMessage.lowercased()
        if DirectorRequestIntentInterpreter().mode(for: userMessage) == .advisory {
            return advisoryReply(userMessage: lower, context: context)
        }
        if ["почему", "объясни", "поясни", "why", "explain"].contains(where: lower.contains),
           !context.autonomousDecisionReasons.isEmpty {
            return "AI Director принял решение по материалу: \(context.autonomousDecisionReasons.prefix(4).joined(separator: ". "))."
        }
        let constraints = PromptInterpreter().interpret(prompt: userMessage, preset: context.preset)
        let duration = constraints.targetDuration == PromptInterpreter.defaults(for: context.preset).targetDuration
            ? context.targetDuration
            : constraints.targetDuration
        var details: [String] = []
        if let count = constraints.targetClipCount { details.append("количество моментов: \(count)") }
        if lower.contains("динамич") || lower.contains("энергич") || lower.contains("быстрый темп") {
            details.append("динамичный темп")
        } else if lower.contains("спокой") || lower.contains("медлен") {
            details.append("спокойный темп")
        }
        if constraints.targetDuration != PromptInterpreter.defaults(for: context.preset).targetDuration {
            details.append("длительность около \(durationText(duration))")
        }
        if constraints.preferPhotos { details.append("больше фотографий") }
        if !constraints.allowSlowMotion { details.append("без slow motion") }
        if !constraints.excludeTags.isEmpty { details.append("исключу нежелательные сцены") }
        if OriginalAudioPromptInterpreter().volume(prompt: userMessage) == 0 {
            details.append("без звука исходников")
        }
        if let music = MusicPromptInterpreter().interpret(prompt: userMessage, preset: context.preset) {
            details.append("саундтрек: \(music.style.localizedTitle.lowercased())")
        }
        if details.isEmpty { details.append("связная история с понятным началом и финалом") }

        let understood = details.joined(separator: ", ")

        if context.assetCount == 0 {
            return "Понял задачу: \(understood). Пока в проекте нет исходников — добавьте фотографии или видео, а я сохраню это описание для монтажа."
        }
        if context.analyzedCount < context.assetCount {
            return "Понял: нужен новый монтаж — \(understood). Сейчас готово \(context.analyzedCount) из \(context.assetCount) анализов; после проверки оставшихся материалов соберу именно эту версию."
        }
        if context.currentTimelineItemCount > 0 {
            if let count = constraints.targetClipCount, count != context.currentTimelineItemCount {
                return "Понял буквально: новый фильм должен состоять из \(count) \(momentWord(count)), а не из текущих \(context.currentTimelineItemCount). Выберу самые сильные фрагменты и выстрою их как начало, развитие и финал; повторно анализировать исходники не понадобится."
            }
            return "Понял новый замысел: \(understood). Пересоберу текущие \(context.currentTimelineItemCount) фрагментов по этому описанию без повторного анализа исходников."
        }
        return "Понял: \(understood). Все \(context.assetCount) материалов проанализированы, найдено \(context.candidateCount) подходящих моментов. Можно запускать монтаж — сначала выстрою историю, затем сразу подготовлю просмотр."
    }

    private func advisoryReply(userMessage: String, context: DirectorContext) -> String {
        guard context.assetCount > 0 else {
            return "Добавьте ролик, и я проанализирую его для совета; исходный файл и Timeline останутся без изменений."
        }
        guard context.analyzedCount > 0 else {
            return "Сначала нужен анализ ролика; после него предложу вариант, не меняя исходник и Timeline."
        }

        var suggestions: [String] = []
        if ["назван", "как назвать"].contains(where: userMessage.contains) {
            let title = SmartTitleEngine().decide(SmartTitleContext(
                purpose: .filmOpening,
                tags: Set(context.contentHints),
                summaries: context.contentHints
            ))
            if let title {
                suggestions.append("название: «\(title.primaryText)»; шаблон: \(TitleTemplateRegistry.template(id: title.templateID)?.name ?? title.templateID)")
            } else {
                suggestions.append("для конкретного названия пока недостаточно подтверждённых деталей; выдумывать тему или место не буду")
            }
        }
        if ["музык", "трек", "саундтр", "мелоди"].contains(where: userMessage.contains) {
            let style = MusicPromptInterpreter().interpret(
                prompt: userMessage.replacingOccurrences(of: "посоветуй", with: "подбери"),
                preset: context.preset,
                automaticDefault: true
            )?.style ?? .cinematic
            suggestions.append("музыка: \(style.localizedTitle.lowercased()), инструментальная, около \(Int(Self.defaultBPM(for: style))) BPM")
        }
        if ["шум", "что слышно", "звук"].contains(where: userMessage.contains) {
            suggestions.append("аудио: \(context.audioHints.isEmpty ? "явных уверенных событий пока не найдено" : context.audioHints.joined(separator: ", "))")
        }
        if suggestions.isEmpty {
            suggestions.append("по материалу лучше всего опираться на \(context.contentHints.prefix(3).joined(separator: ", "))")
        }
        return "Мой совет — \(suggestions.joined(separator: "; ")). Это только рекомендация: исходник и Timeline не изменены."
    }

    private static func titleCase(_ value: String) -> String {
        guard let first = value.first else { return value }
        return String(first).uppercased() + String(value.dropFirst())
    }

    private static func defaultBPM(for style: MusicStyle) -> Double {
        switch style {
        case .energetic: return 118
        case .cinematic: return 82
        case .calm: return 68
        case .joyful: return 112
        case .electronic: return 116
        case .acoustic: return 94
        }
    }

    private func durationText(_ seconds: Double) -> String {
        if seconds < 60 { return "\(Int(seconds.rounded())) секунд" }
        return String(format: "%.1f минуты", seconds / 60)
    }

    private func momentWord(_ count: Int) -> String {
        let mod100 = count % 100
        let mod10 = count % 10
        if mod100 >= 11 && mod100 <= 14 { return "моментов" }
        if mod10 == 1 { return "момента" }
        if (2...4).contains(mod10) { return "моментов" }
        return "моментов"
    }
}
