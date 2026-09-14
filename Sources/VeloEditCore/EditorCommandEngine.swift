import Foundation

public enum EditorCommandTarget: Hashable, Sendable {
    case all
    case selected
    case first
    case last
    /// One-based number as spoken by the user.
    case number(Int)
}

public enum TimelineInsertionPosition: Hashable, Sendable {
    case beginning
    case end
}

public enum EditorCommand: Hashable, Sendable {
    case setSpeed(Double, EditorCommandTarget)
    case removeSlowMotion(EditorCommandTarget)
    case setSpeedRamp(SpeedRamp?, EditorCommandTarget)
    case setDuration(Double, EditorCommandTarget)
    case setFilter(VideoFilter, EditorCommandTarget)
    case setCrop(CropStyle, EditorCommandTarget)
    case rotate(Int, EditorCommandTarget)
    case setBrightness(Double, EditorCommandTarget)
    case setContrast(Double, EditorCommandTarget)
    case setSaturation(Double, EditorCommandTarget)
    case setWarmth(Double, EditorCommandTarget)
    case setOpacity(Double, EditorCommandTarget)
    case setExposure(Double, EditorCommandTarget)
    case setHighlights(Double, EditorCommandTarget)
    case setShadows(Double, EditorCommandTarget)
    case setVignette(Double, EditorCommandTarget)
    case setGrain(Double, EditorCommandTarget)
    case setSharpening(Double, EditorCommandTarget)
    case setVideoDenoise(Double, EditorCommandTarget)
    case setBlur(Double, EditorCommandTarget)
    case setStabilization(Double, EditorCommandTarget)
    case setRollingShutterCorrection(Bool, EditorCommandTarget)
    case setSmoothSlowMotion(Bool, EditorCommandTarget)
    case autoEnhance(EditorCommandTarget)
    case setClipVolume(Double, EditorCommandTarget)
    case setClipMuted(Bool, EditorCommandTarget)
    case setClipFades(Double, Double, EditorCommandTarget)
    case setNoiseReduction(Double, EditorCommandTarget)
    case setEQ(AudioEQPreset, EditorCommandTarget)
    case detachAudio(EditorCommandTarget)
    case setAudioDucking(Bool)
    case setTransition(TransitionStyle?, EditorCommandTarget)
    case setTransitionPattern([TransitionStyle], EditorCommandTarget)
    case setEffect(ClipEffect?, EditorCommandTarget)
    case setEffectPattern([ClipEffect], EditorCommandTarget)
    case setOverlay(OverlayStyle?, EditorCommandTarget, EditorCommandTarget?)
    case setTelemetryOverlay(TelemetryOverlaySettings?, EditorCommandTarget)
    case insertFreezeFrame(Double, EditorCommandTarget)
    case insertInstantReplay(Double, EditorCommandTarget)
    case setReverse(Bool, EditorCommandTarget)
    case addTitle(String, TimelineInsertionPosition)
    case setTitleStyle(Double?, String?, String?, TitleAlignment?, EditorCommandTarget)
    case removeTitles
    case delete(EditorCommandTarget)
    case duplicate(EditorCommandTarget)
    case split(EditorCommandTarget)
    case move(EditorCommandTarget, TimelineInsertionPosition)
    case setOriginalAudioVolume(Double)
    case setMusic(MusicDirective?)
    case setMusicVolume(Double)

    /// Commands from the deterministic parser and the local language model
    /// are merged by operation, with the model's typed version winning. The
    /// key intentionally ignores values and targets so an inaccurately parsed
    /// destructive target cannot run before the structured command.
    public var semanticCategory: String {
        switch self {
        case .setSpeed, .removeSlowMotion: return "speed"
        case .setSpeedRamp: return "speed-ramp"
        case .setDuration: return "duration"
        case .setFilter: return "filter"
        case .setCrop: return "crop"
        case .rotate: return "rotate"
        case .setBrightness: return "brightness"
        case .setContrast: return "contrast"
        case .setSaturation: return "saturation"
        case .setWarmth: return "warmth"
        case .setOpacity: return "opacity"
        case .setExposure: return "exposure"
        case .setHighlights: return "highlights"
        case .setShadows: return "shadows"
        case .setVignette: return "vignette"
        case .setGrain: return "grain"
        case .setSharpening: return "sharpening"
        case .setVideoDenoise: return "video-denoise"
        case .setBlur: return "blur"
        case .setStabilization: return "stabilization"
        case .setRollingShutterCorrection: return "rolling-shutter"
        case .setSmoothSlowMotion: return "smooth-slow-motion"
        case .autoEnhance: return "auto-enhance"
        case .setClipVolume: return "clip-volume"
        case .setClipMuted: return "clip-muted"
        case .setClipFades: return "clip-fades"
        case .setNoiseReduction: return "noise-reduction"
        case .setEQ: return "eq"
        case .detachAudio: return "detach-audio"
        case .setAudioDucking: return "audio-ducking"
        case .setTransition, .setTransitionPattern: return "transition"
        case .setEffect, .setEffectPattern: return "effect"
        case .setOverlay: return "overlay"
        case .setTelemetryOverlay: return "telemetry"
        case .insertFreezeFrame: return "freeze-frame"
        case .insertInstantReplay: return "instant-replay"
        case .setReverse: return "reverse"
        case .addTitle: return "add-title"
        case .setTitleStyle: return "title-style"
        case .removeTitles: return "remove-titles"
        case .delete: return "delete"
        case .duplicate: return "duplicate"
        case .split: return "split"
        case .move: return "move"
        case .setOriginalAudioVolume: return "original-audio-volume"
        case .setMusic: return "music"
        case .setMusicVolume: return "music-volume"
        }
    }
}

public struct EditorCommandReport: Hashable, Sendable {
    public var recognizedCount: Int
    public var applied: [String]
    public var ignored: [String]
    public var affectedItemIDs: [UUID]

    public init(recognizedCount: Int, applied: [String] = [], ignored: [String] = [], affectedItemIDs: [UUID] = []) {
        self.recognizedCount = recognizedCount
        self.applied = applied
        self.ignored = ignored
        self.affectedItemIDs = affectedItemIDs
    }

    public var hasChanges: Bool { !applied.isEmpty }
    public var chatSummary: String {
        if applied.isEmpty {
            return recognizedCount == 0
                ? "Монтажных команд не найдено; применён режиссёрский подбор истории."
                : "Команды распознаны, но не изменили текущий монтаж. \(ignored.joined(separator: " "))"
        }
        var value = "Выполнено в монтаже: " + applied.joined(separator: "; ") + "."
        if !ignored.isEmpty { value += " Не выполнено: " + ignored.joined(separator: "; ") + "." }
        return value
    }
}

public struct EditorCommandParser: Sendable {
    public init() {}

    public func parse(_ prompt: String, preset: FilmPreset = .story) -> [EditorCommand] {
        let segments = commandSegments(prompt)
        var result: [EditorCommand]
        if segments.count <= 1 {
            result = parseSegment(prompt, preset: preset, targetOverride: nil)
        } else {
            var inheritedTarget: EditorCommandTarget?
            result = []
            for segment in segments {
                let explicit = explicitTarget(in: Self.normalized(segment))
                let target = explicit ?? inheritedTarget
                result.append(contentsOf: parseSegment(segment, preset: preset, targetOverride: target))
                if let explicit { inheritedTarget = explicit }
            }
        }
        // Questionnaire prompts split the question and its short answer into
        // separate clauses. Resolve source-audio intent once from the complete
        // exchange so «со звуком исходников?» is not mistaken for “restore”.
        if let sourceVolume = OriginalAudioPromptInterpreter().volume(prompt: prompt) {
            result.removeAll { command in
                if case .setOriginalAudioVolume = command { return true }
                return false
            }
            result.append(.setOriginalAudioVolume(sourceVolume))
        }
        return result
    }

    private func parseSegment(
        _ prompt: String,
        preset: FilmPreset,
        targetOverride: EditorCommandTarget?
    ) -> [EditorCommand] {
        let text = Self.normalized(prompt)
        guard !text.isEmpty else { return [] }
        let target = targetOverride ?? parseTarget(text)
        var result: [EditorCommand] = []
        let asksInstantReplay = containsAny(text, ["мгновенный повтор", "инстант реплей", "instant replay", "повтори этот момент замедленно"])
        let asksSpeedRamp = containsAny(text, ["speed ramp", "спид рамп", "рамп скорости", "плавно замедли и ускорь", "динамическая скорость"])
        let forbidsSlowMotion = containsAny(text, [
            "без slow motion", "не используй slow motion", "убери slow motion", "отключи slow motion",
            "не добавляй slow motion", "никакого slow motion", "не нужен slow motion",
            "без слоумо", "без слоу-мо", "без слоу мо", "без замедления", "не замедляй"
        ])

        if containsAny(text, ["убери все титры", "удали все титры", "без титров"]) {
            result.append(.removeTitles)
        } else if containsAny(text, ["добавь титр", "добавить титр", "добавь надпись", "напиши на экране", "title card"]) {
            let title = quotedText(in: prompt) ?? titleTail(in: prompt) ?? "Мой фильм"
            let position: TimelineInsertionPosition = containsAny(text, ["в конце", "на финале", "финальный титр"]) ? .end : .beginning
            result.append(.addTitle(title, position))
        }
        let asksTitleStyle = containsAny(text, ["титр", "надпись", "title", "текст", "фон", "подложк", "выровняй"])
            && containsAny(text, ["крупн", "больш", "мелк", "маленьк", "размер", "кегль", "бел", "черн", "красн", "оранж", "желт", "зелен", "син", "голуб", "бирюз", "фиолет", "слева", "справа", "по центру"])
        if asksTitleStyle {
            let explicitSize = firstNumber(in: text, patterns: [#"(?:размер|кегль)\w*\s*(\d+(?:[\.,]\d+)?)"#])
            let fontSize = explicitSize
                ?? (containsAny(text, ["крупн", "больш"]) ? 108 : nil)
                ?? (containsAny(text, ["мелк", "маленьк", "небольш"]) ? 48 : nil)
            let textColor = colorHex(in: text, before: ["текст", "титр", "надпись"])
            let backgroundColor = colorHex(in: text, before: ["фон", "подложк"])
            let alignment: TitleAlignment? = containsAny(text, ["титр слева", "надпись слева", "выровняй слева"])
                ? .left
                : containsAny(text, ["титр справа", "надпись справа", "выровняй справа"])
                    ? .right
                    : containsAny(text, ["титр по центру", "надпись по центру", "выровняй по центру"])
                        ? .center
                        : nil
            if fontSize != nil || textColor != nil || backgroundColor != nil || alignment != nil {
                result.append(.setTitleStyle(fontSize, textColor, backgroundColor, alignment, target))
            }
        }

        if containsAny(text, ["убери speed ramp", "убери спид рамп", "без рампа скорости"]) {
            result.append(.setSpeedRamp(nil, target))
        } else if asksSpeedRamp {
            result.append(.setSpeedRamp(.action, target))
        } else if !asksInstantReplay && containsAny(text, ["обычная скорость", "нормальная скорость", "верни скорость", "скорость 1x", "скорость 1 x"]) {
            result.append(.setSpeed(1, target))
        } else if !asksInstantReplay && containsAny(text, ["ускор", "быстрее", "скорость "]) {
            let factor = speedFactor(in: text) ?? 2
            result.append(.setSpeed(min(max(0.1, factor), 8), target))
        } else if !asksInstantReplay && forbidsSlowMotion {
            result.append(.removeSlowMotion(target))
        } else if !asksInstantReplay && containsAny(text, ["замедл", "медленнее", "слоумо", "slow motion"]) {
            let spoken = speedFactor(in: text)
            let factor = spoken.map { $0 > 1 ? 1 / $0 : $0 } ?? 0.5
            result.append(.setSpeed(min(max(0.1, factor), 8), target))
        }
        if containsAny(text, ["добавь стоп-кадр", "сделай стоп-кадр", "вставь стоп-кадр", "freeze frame"]) {
            let duration = firstNumber(in: text, patterns: [#"(\d+(?:[\.,]\d+)?)\s*(?:сек|с\b)"#]) ?? 2
            result.append(.insertFreezeFrame(min(max(0.25, duration), 30), target == .all ? .last : target))
        }
        if asksInstantReplay {
            let spoken = speedFactor(in: text)
            let replaySpeed = spoken.map { $0 > 1 ? 1 / $0 : $0 } ?? 0.5
            result.append(.insertInstantReplay(min(max(0.1, replaySpeed), 1), target == .all ? .last : target))
        }
        if containsAny(text, ["убери реверс", "выключи реверс", "без реверса", "обычное воспроизведение", "воспроизводи вперед", "воспроизводи вперёд"]) {
            result.append(.setReverse(false, target))
        } else if containsAny(text, ["задом наперед", "задом наперёд", "обратное воспроизведение", "в обратную сторону", "наоборот", "сделай реверс", "включи реверс", " реверс", "reverse"]) {
            result.append(.setReverse(true, target))
        }

        if let durationTarget = targetOverride ?? explicitTarget(in: text),
           containsAny(text, ["клип", "фрагмент", "момент"]),
           let duration = firstNumber(in: text, patterns: [#"(?:длительност\w*|по|до)\s*(\d+(?:[\.,]\d+)?)\s*(?:сек|с\b)"#]) {
            result.append(.setDuration(min(max(0.25, duration), 600), durationTarget))
        }

        if containsAny(text, ["без фильтр", "убери фильтр", "сбрось цвет", "верни цвет"]) {
            result.append(.setFilter(.none, target))
        } else if containsAny(text, ["черно-бел", "чёрно-бел", "монохром"]) {
            result.append(.setFilter(.monochrome, target))
        } else if text.contains("нуар") {
            result.append(.setFilter(.noir, target))
        } else if text.contains("сепи") {
            result.append(.setFilter(.sepia, target))
        } else if containsAny(text, ["яркий фильтр", "сделай цвета ярче", "насыщенный фильтр"]) {
            result.append(.setFilter(.vivid, target))
        } else if containsAny(text, ["теплый фильтр", "тёплый фильтр"]) {
            result.append(.setFilter(.warm, target))
        } else if text.contains("холодный фильтр") {
            result.append(.setFilter(.cool, target))
        } else if text.contains("драматичный фильтр") {
            result.append(.setFilter(.dramatic, target))
        }
        if (text.contains("улучш") && text.contains("автоматич")) || containsAny(text, [
            "автоулучш", "автоматически улучши", "улучши автоматически",
            "исправь цвет автоматически", "автокоррекция", "auto enhance"
        ]) {
            result.append(.autoEnhance(target))
        }

        if containsAny(text, ["покажи целиком", "вместить в кадр", "без обрезк", "режим fit"]) {
            result.append(.setCrop(.fit, target))
        } else if containsAny(text, ["заполни кадр", "обрежь по краям", "режим fill"]) {
            result.append(.setCrop(.fill, target))
        }
        if containsAny(text, ["поверни вправо", "повернуть вправо", "по часовой"]) {
            result.append(.rotate(1, target))
        } else if containsAny(text, ["поверни влево", "повернуть влево", "против часовой"]) {
            result.append(.rotate(-1, target))
        }

        if let value = percentValue(after: "яркост", in: text) {
            result.append(.setBrightness(min(max(-1, value / 100), 1), target))
        }
        if let value = percentValue(after: "контраст", in: text) {
            result.append(.setContrast(min(max(0.25, value / 100), 4), target))
        }
        if let value = percentValue(after: "насыщен", in: text) {
            result.append(.setSaturation(min(max(0, value / 100), 2), target))
        }
        if let value = percentValue(after: "температур", in: text) {
            result.append(.setWarmth(min(max(-1, value / 100), 1), target))
        }
        if let value = percentValue(after: "прозрачност", in: text) ?? percentValue(after: "непрозрачност", in: text) {
            result.append(.setOpacity(min(max(0, value / 100), 1), target))
        }
        if let value = firstNumber(in: text, patterns: [#"экспозиц\w*\s*([+-]?\d+(?:[\.,]\d+)?)"#]) {
            result.append(.setExposure(min(max(-4, value), 4), target))
        }
        if let value = percentValue(after: "свет", in: text) ?? percentValue(after: "highlights", in: text) {
            result.append(.setHighlights(min(max(-1, value / 100), 1), target))
        }
        if let value = percentValue(after: "тен", in: text) ?? percentValue(after: "shadows", in: text) {
            result.append(.setShadows(min(max(-1, value / 100), 1), target))
        }
        if containsAny(text, ["убери виньет", "без виньет"]) {
            result.append(.setVignette(0, target))
        } else if containsAny(text, ["виньет", "затемни края"]) {
            let value = percentValue(after: "виньет", in: text).map { $0 / 100 } ?? 0.45
            result.append(.setVignette(min(max(0, value), 1), target))
        }
        if containsAny(text, ["убери зерно", "без зерна", "убери grain"]) {
            result.append(.setGrain(0, target))
        } else if containsAny(text, ["добавь зерно", "пленочное зерно", "плёночное зерно", "film grain"]) {
            let value = percentValue(after: "зерн", in: text).map { $0 / 100 } ?? 0.3
            result.append(.setGrain(min(max(0, value), 1), target))
        }
        if containsAny(text, ["убери резкость", "без повышения резкости", "сбрось sharpening"]) {
            result.append(.setSharpening(0, target))
        } else if containsAny(text, ["добавь резкость", "повысь резкость", "усиль резкость", "sharpen"]) {
            let value = percentValue(after: "резкост", in: text).map { $0 / 100 } ?? 0.45
            result.append(.setSharpening(min(max(0, value), 1), target))
        }
        if containsAny(text, ["убери шум на видео", "шумоподавление видео", "video denoise", "очисти изображение от шума"]) {
            let value = percentValue(after: "шумоподав", in: text).map { $0 / 100 } ?? 0.55
            result.append(.setVideoDenoise(min(max(0, value), 1), target))
        }
        if containsAny(text, ["убери размытие", "сбрось размытие", "без blur"]) {
            result.append(.setBlur(0, target))
        } else if containsAny(text, ["размой кадр", "добавь размытие", "blur video", "размытый фон"]) {
            let value = percentValue(after: "размыт", in: text).map { $0 / 100 } ?? 0.42
            result.append(.setBlur(min(max(0, value), 1), target))
        }
        if containsAny(text, ["убери стабилизац", "без стабилизации", "отключи стабилизацию"]) {
            result.append(.setStabilization(0, target))
        } else if containsAny(text, ["стабилиз", "убери тряску", "сгладь тряску"]) {
            let value = percentValue(after: "стабилизац", in: text).map { $0 / 100 } ?? 0.58
            result.append(.setStabilization(min(max(0, value), 1), target))
        }
        if containsAny(text, ["исправь rolling shutter", "исправь роллинг шаттер", "убери желе", "коррекция rolling shutter"]) {
            result.append(.setRollingShutterCorrection(true, target))
        }
        if containsAny(text, ["сгладь slow motion", "плавный slow motion", "сгладь замедление", "smooth slow motion"]) {
            result.append(.setSmoothSlowMotion(true, target))
        }

        let selectedAudioTarget = target != .all
        let explicitlyMusicAudio = containsAny(text, [
            "звук музы", "громкость музы", "заглуши музыку", "приглуши музыку",
            "сделай музыку тише", "музыку потише", "убавь музыку"
        ])
        let quieterSourceAudio = containsAny(text, [
            "приглуши звук исход", "приглушить звук исход", "звук исходников приглуш", "звук исходников? приглуш",
            "звуком исходников приглуш", "звуком исходников? приглуш",
            "сделай звук исходников тише", "исходный звук тише", "оригинальный звук тише",
            "убавь звук исходников", "lower original audio", "original audio quieter"
        ])
        if quieterSourceAudio && !explicitlyMusicAudio {
            result.append(selectedAudioTarget ? .setClipVolume(0.30, target) : .setOriginalAudioVolume(DirectorSourceAudioPolicy.duck.volume))
        } else if containsAny(text, ["убери звук", "убери у него звук", "выключи звук", "выключи у него звук", "без звука", "заглуши"]) && !explicitlyMusicAudio {
            result.append(selectedAudioTarget ? .setClipMuted(true, target) : .setOriginalAudioVolume(0))
        } else if containsAny(text, ["верни звук", "включи звук", "со звуком"]) && !explicitlyMusicAudio {
            result.append(selectedAudioTarget ? .setClipMuted(false, target) : .setOriginalAudioVolume(1))
        }
        if let value = firstNumber(in: text, patterns: [#"громкост\w*\s*(\d+(?:[\.,]\d+)?)\s*%"#]), !text.contains("музык") {
            result.append(.setClipVolume(min(max(0, value / 100), 2), target))
        }
        if containsAny(text, [
            "приглуши голос в исходнике", "сделай голос тише", "сделай речь тише",
            "убавь голос", "убавь речь", "lower source voice"
        ]) {
            let amount = firstNumber(in: text, patterns: [#"(?:голос|реч\w*)\D{0,20}(\d+(?:[\.,]\d+)?)\s*%"#]).map { $0 / 100 } ?? 0.35
            result.append(.setClipVolume(min(max(0, amount), 2), target))
        }
        if containsAny(text, ["плавное появление звука", "нарастание звука", "fade in звука", "плавный вход звука"]) {
            let seconds = firstNumber(in: text, patterns: [#"(\d+(?:[\.,]\d+)?)\s*(?:сек|с\b)"#]) ?? 1
            result.append(.setClipFades(seconds, 0, target))
        }
        if containsAny(text, ["плавное затухание звука", "fade out звука", "плавный выход звука"]) {
            let seconds = firstNumber(in: text, patterns: [#"(\d+(?:[\.,]\d+)?)\s*(?:сек|с\b)"#]) ?? 1
            result.append(.setClipFades(0, seconds, target))
        }
        if containsAny(text, ["убери шум", "шумоподав", "noise reduction", "очисти звук"]) {
            let amount = percentValue(after: "шумоподав", in: text).map { $0 / 100 } ?? 0.65
            result.append(.setNoiseReduction(min(max(0, amount), 1), target))
        }
        if containsAny(text, ["eq для голоса", "эквалайзер для голоса", "подчеркни голос", "voice eq"]) {
            result.append(.setEQ(.voice, target))
        } else if containsAny(text, ["eq для музыки", "музыкальный eq"]) {
            result.append(.setEQ(.music, target))
        } else if containsAny(text, ["убери бас", "срежь низкие", "bass reduction"]) {
            result.append(.setEQ(.bassReduction, target))
        } else if containsAny(text, ["сбрось eq", "убери эквалайзер", "плоский eq"]) {
            result.append(.setEQ(.flat, target))
        }
        if containsAny(text, ["отдели звук", "отсоедини звук", "detach audio", "вынеси звук отдельно"]) {
            result.append(.detachAudio(target == .all ? .selected : target))
        }
        if containsAny(text, ["включи ducking", "приглушай музыку под звук", "приглуши музыку под речь", "музыку тише под речь", "автоматический ducking"]) {
            result.append(.setAudioDucking(true))
        } else if containsAny(text, ["выключи ducking", "без ducking", "не приглушай музыку"]) {
            result.append(.setAudioDucking(false))
        }

        let transitionTarget = incomingTransitionTarget(in: text) ?? target
        let asksForTransitions = containsAny(text, ["переход", "transition", "crossfade", "кроссфейд"])
        if containsAny(text, ["без переход", "убери переход", "удали переход", "отключи переход"]) {
            result.append(.setTransition(nil, transitionTarget))
        } else if containsAny(text, ["через черный", "через чёрный", "провал в черн", "fade through black", "dip to black", "dip black"]) {
            result.append(.setTransition(.fadeThroughBlack, transitionTarget))
        } else if containsAny(text, ["растворение", "раствори", "кроссфейд", "cross dissolve", "crossfade"]) {
            result.append(.setTransition(.crossDissolve, transitionTarget))
        } else if containsAny(text, ["мягкое затухание", "обычный fade", "fade transition", "переход фейд"]) {
            result.append(.setTransition(.fade, transitionTarget))
        } else if asksForTransitions && containsAny(text, ["размыт", "blur"]) {
            result.append(.setTransition(.blurDissolve, transitionTarget))
        } else if asksForTransitions && containsAny(text, ["светов", "вспыш", "flash"]) {
            result.append(.setTransition(.lightFlash, transitionTarget))
        } else if containsAny(text, ["сдвиг влево", "slide left"]) {
            result.append(.setTransition(.slideLeft, transitionTarget))
        } else if containsAny(text, ["сдвиг вправо", "slide right"]) {
            result.append(.setTransition(.slideRight, transitionTarget))
        } else if containsAny(text, ["шторка влево", "wipe left"]) {
            result.append(.setTransition(.wipeLeft, transitionTarget))
        } else if containsAny(text, ["шторка вправо", "wipe right"]) {
            result.append(.setTransition(.wipeRight, transitionTarget))
        } else if asksForTransitions && asksToApplyCreativeChange(text) && !containsAny(text, ["меньше переход", "реже переход"]) {
            if containsAny(text, ["разн", "черед", "разнообраз", "каждый переход другой"]) {
                let styles: [TransitionStyle] = containsAny(text, ["динамич", "энергич", "эффектн", "крут", "вау"])
                    ? [.lightFlash, .slideLeft, .wipeRight, .blurDissolve]
                    : [.crossDissolve, .fadeThroughBlack, .blurDissolve, .slideRight]
                result.append(.setTransitionPattern(styles, transitionTarget))
            } else if containsAny(text, ["динамич", "энергич", "эффектн", "крут", "вау", "резк"]) {
                result.append(.setTransition(.lightFlash, transitionTarget))
            } else if containsAny(text, ["кинематограф", "драматич", "эпич"]) {
                result.append(.setTransition(.fadeThroughBlack, transitionTarget))
            } else {
                result.append(.setTransition(.crossDissolve, transitionTarget))
            }
        }

        if containsAny(text, ["убери эффект", "без эффекта"]) {
            result.append(.setEffect(nil, target))
        } else if containsAny(text, ["ken burns", "кен бернс"]) {
            result.append(.setEffect(.kenBurns, target))
        } else if containsAny(text, ["плавный наезд", "наезд камеры", "push in", "push-in"]) {
            result.append(.setEffect(.pushIn, target))
        } else if containsAny(text, ["плавный отъезд", "отъезд камеры", "pull out", "pull-out"]) {
            result.append(.setEffect(.pullOut, target))
        } else if containsAny(text, ["приближение", "приближай", "zoom in", "zoom-in", "зум внутрь"]) {
            result.append(.setEffect(.zoomIn, target))
        } else if containsAny(text, ["отдаление", "отдаляй", "zoom out", "zoom-out", "зум наружу"]) {
            result.append(.setEffect(.zoomOut, target))
        } else if containsAny(text, ["панорама влево", "pan left"]) {
            result.append(.setEffect(.panLeft, target))
        } else if containsAny(text, ["панорама вправо", "pan right"]) {
            result.append(.setEffect(.panRight, target))
        } else if containsAny(text, ["отрази", "зеркально", "mirror"]) {
            result.append(.setEffect(.mirror, target))
        } else if containsAny(text, ["разные эффект", "разнообразные эффект", "чередуй эффект", "чередование эффект", "разное движение", "чередуй движение"]) {
            result.append(.setEffectPattern([.pushIn, .panLeft, .pullOut, .panRight], target))
        } else if containsAny(text, ["эффект", "движение кадр", "движение камер", "оживи кадр", "оживи видео", "оживи клип"]),
                  asksToApplyCreativeChange(text) {
            let effect: ClipEffect = containsAny(text, ["динамич", "энергич", "эффектн", "крут", "вау", "эпич"])
                ? .pushIn
                : .kenBurns
            result.append(.setEffect(effect, target))
        }

        let overlayTarget: EditorCommandTarget = target == .all ? .last : target
        if containsAny(text, ["убери наложение", "без наложения", "убери картинку в картинке", "обычный экран"]) {
            result.append(.setOverlay(nil, overlayTarget, nil))
        } else if containsAny(text, ["картинка в картинке", "картинкой в картинке", "picture in picture", "pip", "маленьким поверх", "маленькое поверх", "маленький поверх", "в углу поверх"]) {
            result.append(.setOverlay(.pictureInPicture, overlayTarget, .first))
        } else if containsAny(text, ["разделенный экран", "разделённый экран", "split screen", "два видео рядом"]) {
            result.append(.setOverlay(.splitScreen, overlayTarget, .first))
        } else if containsAny(text, ["зеленый фон", "зелёный фон", "хромакей", "green screen"]) {
            result.append(.setOverlay(.greenScreen, overlayTarget, .first))
        } else if containsAny(text, ["сделай перебивку", "как перебивку", "cutaway"]) {
            result.append(.setOverlay(.cutaway, overlayTarget, .first))
        }
        if containsAny(text, ["убери телеметри", "без телеметрии", "скрой gps", "скрой маршрут"]) {
            result.append(.setTelemetryOverlay(nil, target))
        } else if containsAny(text, ["покажи телеметри", "добавь телеметри", "покажи скорость", "покажи gps", "покажи маршрут", "g-force", "перегрузк"]) {
            var metrics = Set<TelemetryMetric>()
            if containsAny(text, ["скорост", "телеметри"]) { metrics.insert(.speed) }
            if containsAny(text, ["gps", "маршрут", "трек", "телеметри"]) { metrics.insert(.route) }
            if containsAny(text, ["высот", "альтит", "телеметри"]) { metrics.insert(.altitude) }
            if containsAny(text, ["дистанц", "расстоян", "телеметри"]) { metrics.insert(.distance) }
            if containsAny(text, ["g-force", "перегрузк", "телеметри"]) { metrics.insert(.gForce) }
            result.append(.setTelemetryOverlay(TelemetryOverlaySettings(metrics: metrics), target))
        }

        if containsAny(text, ["удали клип", "удали фрагмент", "убери клип", "убери фрагмент"]) {
            result.append(.delete(target))
        } else if containsAny(text, ["дублируй клип", "дублируй фрагмент", "сделай копию клипа", "повтори клип"]) {
            result.append(.duplicate(target))
        } else if containsAny(text, ["разрежь клип", "раздели клип", "разрежь фрагмент", "раздели фрагмент"]) {
            result.append(.split(target))
        }
        if containsAny(text, ["перемести", "поставь"]), containsAny(text, ["в начало", "первым"]) {
            result.append(.move(target, .beginning))
        } else if containsAny(text, ["перемести", "поставь"]), containsAny(text, ["в конец", "последним"]) {
            result.append(.move(target, .end))
        }

        if containsAny(text, ["без музы", "убери музыку", "удали музыку"]) {
            result.append(.setMusic(nil))
        } else if let music = MusicPromptInterpreter().interpret(prompt: prompt, preset: preset) {
            result.append(.setMusic(music))
        }
        if text.contains("музык") {
            if let value = firstNumber(in: text, patterns: [#"громкост\w*\s*(?:музык\w*\s*)?(\d+(?:[\.,]\d+)?)\s*%"#, #"музык\w*\s*(?:на\s*)?(\d+(?:[\.,]\d+)?)\s*%"#]) {
                result.append(.setMusicVolume(min(max(0, value / 100), 1)))
            } else if containsAny(text, ["приглуши музыку", "сделай музыку тише", "музыку потише", "убавь музыку"]) &&
                        !containsAny(text, ["под речь", "под голос", "когда говорят"]) {
                result.append(.setMusicVolume(0.25))
            }
        }
        return result
    }

    private func commandSegments(_ prompt: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"[,;]\s+|\n+"#) else { return [prompt] }
        let range = NSRange(prompt.startIndex..<prompt.endIndex, in: prompt)
        var cursor = prompt.startIndex
        var result: [String] = []
        for match in regex.matches(in: prompt, range: range) {
            guard let separator = Range(match.range, in: prompt) else { continue }
            let value = prompt[cursor..<separator.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { result.append(value) }
            cursor = separator.upperBound
        }
        let tail = prompt[cursor...].trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { result.append(tail) }
        return result.isEmpty ? [prompt] : result
    }

    private func explicitTarget(in text: String) -> EditorCommandTarget? {
        if containsAny(text, ["все клип", "все фрагмент", "ко всем клип", "на весь фильм", "для всего фильма"]) { return .all }
        let target = parseTarget(text)
        if target == .selected,
           !containsAny(text, ["выбранн", "этот клип", "этот фрагмент"]) {
            return nil
        }
        return target == .all ? nil : target
    }

    private func parseTarget(_ text: String) -> EditorCommandTarget {
        if containsAny(text, ["первый клип", "первого клипа", "первом клипе", "первый фрагмент", "первого фрагмента", "первом фрагменте", "первый план", "первого плана", "первом плане", "первый титр", "первого титра", "первом титре", "первое видео", "первом видео", "в начале фильма"]) { return .first }
        if containsAny(text, ["последний клип", "последнего клипа", "последнем клипе", "последний фрагмент", "последнего фрагмента", "последнем фрагменте", "последний план", "последнего плана", "последнем плане", "последний титр", "последнего титра", "последнем титре", "последнее видео", "последнем видео", "в конце фильма", "концовк", "финальный момент"]) { return .last }
        let ordinalWords: [(Int, [String])] = [
            (2, ["второй клип", "второго клипа", "втором клипе", "второй фрагмент", "втором фрагменте", "второй план", "второго плана", "втором плане", "второе видео", "втором видео"]),
            (3, ["третий клип", "третьего клипа", "третьем клипе", "третий фрагмент", "третьем фрагменте", "третий план", "третьего плана", "третьем плане", "третье видео", "третьем видео"]),
            (4, ["четвертый клип", "четвертого клипа", "четвертом клипе", "четвертый фрагмент", "четвертом фрагменте", "четвертый план", "четвертом плане", "четвертое видео", "четвертом видео"]),
            (5, ["пятый клип", "пятого клипа", "пятом клипе", "пятый фрагмент", "пятом фрагменте", "пятый план", "пятом плане", "пятое видео", "пятом видео"]),
            (6, ["шестой клип", "шестого клипа", "шестом клипе", "шестой фрагмент", "шестом фрагменте", "шестое видео", "шестом видео"]),
            (7, ["седьмой клип", "седьмого клипа", "седьмом клипе", "седьмой фрагмент", "седьмом фрагменте", "седьмое видео", "седьмом видео"]),
            (8, ["восьмой клип", "восьмого клипа", "восьмом клипе", "восьмой фрагмент", "восьмом фрагменте", "восьмое видео", "восьмом видео"]),
            (9, ["девятый клип", "девятого клипа", "девятом клипе", "девятый фрагмент", "девятом фрагменте", "девятое видео", "девятом видео"]),
            (10, ["десятый клип", "десятого клипа", "десятом клипе", "десятый фрагмент", "десятом фрагменте", "десятое видео", "десятом видео"])
        ]
        if let match = ordinalWords.first(where: { containsAny(text, $0.1) }) { return .number(match.0) }
        if let value = firstNumber(in: text, patterns: [#"(?:клип|фрагмент|момент|план|титр|видео)\w*\s*(?:№\s*)?(\d+)"#, #"(\d+)\s*[- ]?(?:й|ый|ой)\s+(?:клип|фрагмент|момент|план|титр|видео)"#]) {
            return .number(max(1, Int(value)))
        }
        if containsAny(text, ["выбранн", "этот клип", "этот фрагмент", "у него", "на нем", "на нём", "сделай его", "для него"]) { return .selected }
        return .all
    }

    /// A transition belongs to the incoming clip. Natural speech often names
    /// the cut instead ("after the first clip"), so translate that boundary to
    /// the clip that actually stores and renders the transition.
    private func incomingTransitionTarget(in text: String) -> EditorCommandTarget? {
        let afterOrdinals: [(Int, [String])] = [
            (2, ["после первого клипа", "после первого фрагмента", "между первым и вторым"]),
            (3, ["после второго клипа", "после второго фрагмента", "между вторым и третьим"]),
            (4, ["после третьего клипа", "после третьего фрагмента", "между третьим и четвертым"]),
            (5, ["после четвертого клипа", "после четвертого фрагмента", "между четвертым и пятым"])
        ]
        if let match = afterOrdinals.first(where: { containsAny(text, $0.1) }) { return .number(match.0) }
        if let value = firstNumber(in: text, patterns: [#"после\s+(?:клип|фрагмент|момент|план|видео)\w*\s*(\d+)"#]) {
            return .number(max(1, Int(value) + 1))
        }
        return nil
    }

    private func asksToApplyCreativeChange(_ text: String) -> Bool {
        containsAny(text, [
            "добав", "сделай", "использ", "постав", "примен", "включ", "хочу", "нужн", "пусть",
            "больше переход", "красив", "плавн", "динамич", "энергич", "эффектн", "кинематограф",
            "эпич", "крут", "вау", "разн", "черед", "разнообраз", "оживи"
        ])
    }

    private func speedFactor(in text: String) -> Double? {
        firstNumber(in: text, patterns: [#"(\d+(?:[\.,]\d+)?)\s*[xх]"#, #"в\s*(\d+(?:[\.,]\d+)?)\s*раз"#, #"скорост\w*\s*(\d+(?:[\.,]\d+)?)"#])
    }

    private func percentValue(after stem: String, in text: String) -> Double? {
        firstNumber(in: text, patterns: ["\(stem)\\w*\\s*(-?\\d+(?:[\\.,]\\d+)?)\\s*%"])
    }

    private func colorHex(in text: String, before nouns: [String]) -> String? {
        let colors: [(String, String)] = [
            ("бел", "#FFFFFF"), ("черн", "#111111"), ("красн", "#FF3B30"),
            ("оранж", "#FF9500"), ("желт", "#FFCC00"), ("зелен", "#34C759"),
            ("син", "#007AFF"), ("голуб", "#5AC8FA"), ("бирюз", "#40E0D0"),
            ("фиолет", "#AF52DE")
        ]
        for noun in nouns {
            for (stem, hex) in colors where text.range(of: "\(stem)\\w*\\s+\(noun)", options: .regularExpression) != nil {
                return hex
            }
        }
        return nil
    }

    private func firstNumber(in text: String, patterns: [String]) -> Double? {
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges > 1,
                  let valueRange = Range(match.range(at: 1), in: text) else { continue }
            return Double(text[valueRange].replacingOccurrences(of: ",", with: "."))
        }
        return nil
    }

    private func quotedText(in text: String) -> String? {
        let pairs: [(Character, Character)] = [("«", "»"), ("\"", "\"")]
        for (opening, closing) in pairs {
            guard let start = text.firstIndex(of: opening),
                  let end = text[text.index(after: start)...].firstIndex(of: closing), start < end else { continue }
            let value = text[text.index(after: start)..<end].trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { return value }
        }
        return nil
    }

    private func titleTail(in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"(?:титр|надпись)\w*\s*[:—-]\s*(.+)$"#, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges > 1,
              let valueRange = Range(match.range(at: 1), in: text) else { return nil }
        let value = text[valueRange].trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private func containsAny(_ text: String, _ values: [String]) -> Bool {
        values.contains(where: text.contains)
    }

    private static func normalized(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: "ё", with: "е")
            .replacingOccurrences(of: "–", with: "-")
    }
}

public struct EditorCommandExecutor: Sendable {
    public init() {}

    public func apply(
        _ commands: [EditorCommand],
        to source: Timeline,
        selectedItemID: UUID? = nil,
        selectedCandidateID: UUID? = nil
    ) -> (timeline: Timeline, report: EditorCommandReport) {
        var timeline = source
        var applied: [String] = []
        var ignored: [String] = []
        var affected = Set<UUID>()

        func indexes(for target: EditorCommandTarget) -> [Int] {
            let editable = timeline.items.indices.filter { timeline.items[$0].kind != .title }
            switch target {
            case .all: return editable
            case .first: return editable.first.map { [$0] } ?? []
            case .last: return editable.last.map { [$0] } ?? []
            case .number(let number):
                return editable.indices.contains(number - 1) ? [editable[number - 1]] : []
            case .selected:
                if let selectedItemID, let index = timeline.items.firstIndex(where: { $0.id == selectedItemID }) { return [index] }
                if let selectedCandidateID, let index = timeline.items.firstIndex(where: { $0.candidateID == selectedCandidateID }) { return [index] }
                return []
            }
        }

        func titleIndexes(for target: EditorCommandTarget) -> [Int] {
            let titles = timeline.items.indices.filter { timeline.items[$0].kind == .title }
            switch target {
            case .all: return titles
            case .first: return titles.first.map { [$0] } ?? []
            case .last: return titles.last.map { [$0] } ?? []
            case .number(let number): return titles.indices.contains(number - 1) ? [titles[number - 1]] : []
            case .selected:
                guard let selectedItemID,
                      let index = timeline.items.firstIndex(where: { $0.id == selectedItemID && $0.kind == .title }) else { return [] }
                return [index]
            }
        }

        func titleObjectIndexes(for target: EditorCommandTarget) -> [Int] {
            let titles = timeline.effectiveTitleItems
            switch target {
            case .all: return Array(titles.indices)
            case .first: return titles.indices.first.map { [$0] } ?? []
            case .last: return titles.indices.last.map { [$0] } ?? []
            case .number(let number): return titles.indices.contains(number - 1) ? [number - 1] : []
            case .selected:
                guard let selectedItemID,
                      let index = titles.firstIndex(where: { $0.id == selectedItemID }) else { return [] }
                return [index]
            }
        }

        func mutate(_ target: EditorCommandTarget, description: (Int) -> String, operation: (inout TimelineItem) -> Void) {
            let positions = indexes(for: target)
            guard !positions.isEmpty else {
                ignored.append("цель команды не найдена")
                return
            }
            var changed = 0
            for index in positions {
                let before = timeline.items[index]
                operation(&timeline.items[index])
                if timeline.items[index] != before {
                    affected.insert(timeline.items[index].id)
                    changed += 1
                }
            }
            if changed > 0 {
                applied.append(description(changed))
            } else {
                ignored.append("(description(positions.count)) — уже было установлено")
            }
        }

        for command in commands {
            switch command {
            case .setSpeed(let speed, let target):
                mutate(target, description: { "скорость \(Self.number(speed))× для \($0) фрагм." }) { item in
                    guard !item.isFreezeFrame else { return }
                    item.speed = min(max(0.1, speed), 20)
                    item.speedRamp = nil
                    item.timelineDuration = max(0.05, item.sourceDuration / item.speed)
                }
            case .removeSlowMotion(let target):
                mutate(target, description: { "slow motion убран у \($0) фрагм." }) { item in
                    guard !item.isFreezeFrame else { return }
                    if let ramp = item.speedRamp,
                       ramp.normalizedPoints.contains(where: { $0.rate < 1 }) {
                        let normalized = SpeedRamp(points: ramp.points.map {
                            SpeedRampPoint(position: $0.position, rate: max(1, $0.rate))
                        })
                        if normalized.normalizedPoints.allSatisfy({ abs($0.rate - 1) < 0.000_1 }) {
                            item.speedRamp = nil
                            item.speed = 1
                            item.timelineDuration = max(0.05, item.sourceDuration)
                        } else {
                            item.speed = 1
                            item.speedRamp = normalized
                            item.timelineDuration = max(0.05, normalized.outputDuration(sourceDuration: item.sourceDuration))
                        }
                    } else if item.speed < 1 {
                        item.speed = 1
                        item.timelineDuration = max(0.05, item.sourceDuration)
                    }
                }
            case .setSpeedRamp(let ramp, let target):
                mutate(target, description: { ramp == nil ? "рамп скорости убран у \($0) фрагм." : "рамп скорости применён к \($0) фрагм." }) { item in
                    guard !item.isFreezeFrame else { return }
                    item.speed = 1
                    item.speedRamp = ramp
                    item.timelineDuration = max(0.25, ramp?.outputDuration(sourceDuration: item.sourceDuration) ?? item.sourceDuration)
                }
            case .setDuration(let duration, let target):
                mutate(target, description: { "длительность \(Self.number(duration)) с для \($0) фрагм." }) { item in
                    item.timelineDuration = max(0.25, duration)
                    guard !item.isFreezeFrame else { return }
                    let rampFactor = item.speedRamp?.outputDuration(sourceDuration: 1) ?? (1 / item.speed)
                    item.sourceDuration = item.timelineDuration / max(0.01, rampFactor)
                }
            case .setFilter(let filter, let target):
                mutate(target, description: { "фильтр «\(filter.localizedTitle)» для \($0) фрагм." }) { item in
                    var value = item.effectiveVideoAdjustments
                    value.filter = filter
                    item.videoAdjustments = value.isNeutral ? nil : value
                }
            case .setCrop(let crop, let target):
                mutate(target, description: { "кадрирование «\(crop.localizedTitle)» для \($0) фрагм." }) { item in
                    var value = item.effectiveVideoAdjustments
                    value.crop = crop
                    item.videoAdjustments = value.isNeutral ? nil : value
                }
            case .rotate(let amount, let target):
                mutate(target, description: { "поворот на \(amount > 0 ? "90° вправо" : "90° влево") для \($0) фрагм." }) { item in
                    var value = item.effectiveVideoAdjustments
                    value.rotationQuarterTurns = ((value.rotationQuarterTurns + amount) % 4 + 4) % 4
                    item.videoAdjustments = value.isNeutral ? nil : value
                }
            case .setBrightness(let brightness, let target):
                mutate(target, description: { "яркость \(Int((brightness * 100).rounded()))% для \($0) фрагм." }) { item in
                    var value = item.effectiveVideoAdjustments; value.brightness = brightness; item.videoAdjustments = value.isNeutral ? nil : value
                }
            case .setContrast(let contrast, let target):
                mutate(target, description: { "контраст \(Int((contrast * 100).rounded()))% для \($0) фрагм." }) { item in
                    var value = item.effectiveVideoAdjustments; value.contrast = contrast; item.videoAdjustments = value.isNeutral ? nil : value
                }
            case .setSaturation(let saturation, let target):
                mutate(target, description: { "насыщенность \(Int((saturation * 100).rounded()))% для \($0) фрагм." }) { item in
                    var value = item.effectiveVideoAdjustments; value.saturation = saturation; item.videoAdjustments = value.isNeutral ? nil : value
                }
            case .setWarmth(let warmth, let target):
                mutate(target, description: { "температура \(Int((warmth * 100).rounded()))% для \($0) фрагм." }) { item in
                    var value = item.effectiveVideoAdjustments; value.warmth = warmth; item.videoAdjustments = value.isNeutral ? nil : value
                }
            case .setOpacity(let opacity, let target):
                mutate(target, description: { "непрозрачность \(Int((opacity * 100).rounded()))% для \($0) фрагм." }) { item in
                    var value = item.effectiveVideoAdjustments; value.opacity = opacity; item.videoAdjustments = value.isNeutral ? nil : value
                }
            case .setExposure(let exposure, let target):
                mutate(target, description: { "экспозиция \(Self.number(exposure)) EV для \($0) фрагм." }) { item in
                    var value = item.effectiveVideoAdjustments; value.exposure = exposure; item.videoAdjustments = value.isNeutral ? nil : value
                }
            case .setHighlights(let amount, let target):
                mutate(target, description: { "света \(Int((amount * 100).rounded()))% для \($0) фрагм." }) { item in
                    var value = item.effectiveVideoAdjustments; value.highlights = amount; item.videoAdjustments = value.isNeutral ? nil : value
                }
            case .setShadows(let amount, let target):
                mutate(target, description: { "тени \(Int((amount * 100).rounded()))% для \($0) фрагм." }) { item in
                    var value = item.effectiveVideoAdjustments; value.shadows = amount; item.videoAdjustments = value.isNeutral ? nil : value
                }
            case .setVignette(let amount, let target):
                mutate(target, description: { "виньетка \(Int((amount * 100).rounded()))% для \($0) фрагм." }) { item in
                    var value = item.effectiveVideoAdjustments; value.vignette = amount; item.videoAdjustments = value.isNeutral ? nil : value
                }
            case .setGrain(let amount, let target):
                mutate(target, description: { "зерно \(Int((amount * 100).rounded()))% для \($0) фрагм." }) { item in
                    var value = item.effectiveVideoAdjustments; value.grain = amount; item.videoAdjustments = value.isNeutral ? nil : value
                }
            case .setSharpening(let amount, let target):
                mutate(target, description: { "резкость \(Int((amount * 100).rounded()))% для \($0) фрагм." }) { item in
                    var value = item.effectiveVideoAdjustments; value.sharpening = amount; item.videoAdjustments = value.isNeutral ? nil : value
                }
            case .setVideoDenoise(let amount, let target):
                mutate(target, description: { "шумоподавление видео \(Int((amount * 100).rounded()))% для \($0) фрагм." }) { item in
                    var value = item.effectiveVideoAdjustments; value.denoise = amount; item.videoAdjustments = value.isNeutral ? nil : value
                }
            case .setBlur(let amount, let target):
                mutate(target, description: { "размытие \(Int((amount * 100).rounded()))% для \($0) фрагм." }) { item in
                    var value = item.effectiveVideoAdjustments; value.blur = amount; item.videoAdjustments = value.isNeutral ? nil : value
                }
            case .setStabilization(let amount, let target):
                mutate(target, description: { "стабилизация \(Int((amount * 100).rounded()))% для \($0) фрагм." }) { item in
                    var value = item.effectiveVideoAdjustments; value.stabilization = amount; item.videoAdjustments = value.isNeutral ? nil : value
                }
            case .setRollingShutterCorrection(let enabled, let target):
                mutate(target, description: { enabled ? "rolling shutter исправлен у \($0) фрагм." : "коррекция rolling shutter отключена у \($0) фрагм." }) { item in
                    var value = item.effectiveVideoAdjustments; value.rollingShutterCorrection = enabled; item.videoAdjustments = value.isNeutral ? nil : value
                }
            case .setSmoothSlowMotion(let enabled, let target):
                mutate(target, description: { enabled ? "slow motion сглажен у \($0) фрагм." : "сглаживание slow motion отключено у \($0) фрагм." }) { item in
                    var value = item.effectiveVideoAdjustments; value.smoothSlowMotion = enabled; item.videoAdjustments = value.isNeutral ? nil : value
                }
            case .autoEnhance(let target):
                mutate(target, description: { "автоматическое улучшение цвета для \($0) фрагм." }) { item in
                    var value = item.effectiveVideoAdjustments
                    value.brightness = min(1, value.brightness + 0.04)
                    value.contrast = min(4, max(value.contrast, 1.08))
                    value.saturation = min(2, max(value.saturation, 1.08))
                    item.videoAdjustments = value
                }
            case .setClipVolume(let volume, let target):
                mutate(target, description: { "громкость \(Int((volume * 100).rounded()))% для \($0) фрагм." }) { item in
                    var value = item.effectiveAudioAdjustments; value.volume = volume; item.audioAdjustments = value.isNeutral ? nil : value
                }
            case .setClipMuted(let muted, let target):
                mutate(target, description: { muted ? "звук отключён у \($0) фрагм." : "звук включён у \($0) фрагм." }) { item in
                    var value = item.effectiveAudioAdjustments; value.muted = muted; item.audioAdjustments = value.isNeutral ? nil : value
                }
            case .setClipFades(let fadeIn, let fadeOut, let target):
                mutate(target, description: { "плавный звук настроен у \($0) фрагм." }) { item in
                    var value = item.effectiveAudioAdjustments
                    if fadeIn > 0 { value.fadeIn = fadeIn }
                    if fadeOut > 0 { value.fadeOut = fadeOut }
                    item.audioAdjustments = value.isNeutral ? nil : value
                }
            case .setNoiseReduction(let amount, let target):
                mutate(target, description: { "шумоподавление \(Int((amount * 100).rounded()))% для \($0) фрагм." }) { item in
                    var value = item.effectiveAudioAdjustments; value.noiseReduction = amount; item.audioAdjustments = value.isNeutral ? nil : value
                }
            case .setEQ(let preset, let target):
                mutate(target, description: { "EQ «\(preset.rawValue)» для \($0) фрагм." }) { item in
                    var value = item.effectiveAudioAdjustments; value.eqPreset = preset; item.audioAdjustments = value.isNeutral ? nil : value
                }
            case .detachAudio(let target):
                let positions = indexes(for: target)
                guard !positions.isEmpty else { ignored.append("клип для отделения звука не найден"); continue }
                var detached = timeline.effectiveAudioClips
                for index in positions {
                    let item = timeline.items[index]
                    guard let assetID = item.assetID, item.kind == .video else { continue }
                    detached.append(TimelineAudioClip(
                        assetID: assetID,
                        title: "Отделённый звук",
                        role: .detached,
                        sourceStart: item.sourceStart,
                        sourceDuration: item.sourceDuration,
                        timelineStart: item.timelineStart,
                        timelineDuration: item.timelineDuration,
                        attachedToItemID: item.id
                    ))
                    var audio = timeline.items[index].effectiveAudioAdjustments
                    audio.muted = true
                    timeline.items[index].audioAdjustments = audio
                    affected.insert(item.id)
                }
                timeline.audioClips = detached
                applied.append("звук отделён у \(positions.count) фрагм.")
            case .setAudioDucking(let enabled):
                timeline.audioDucking = enabled ? AudioDuckingSettings() : nil
                applied.append(enabled ? "автоматический ducking включён" : "автоматический ducking выключен")
            case .setTransition(let transition, let target):
                let targetIDs = Set(indexes(for: target).map { timeline.items[$0].id })
                let previousObjects = timeline.effectiveTransitionItems
                if let transition {
                    timeline.transitionItems = previousObjects.map { item in
                        guard targetIDs.contains(item.incomingClipID) else { return item }
                        var copy = item
                        copy.style = transition
                        copy.intensity = TransitionPresetRegistry.preset(for: transition).defaultIntensity
                        copy.parameters = TransitionPresetRegistry.preset(for: transition).defaultParameters
                        return copy
                    }
                } else {
                    timeline.transitionItems = previousObjects.filter { !targetIDs.contains($0.incomingClipID) }
                }
                let currentObjects = timeline.effectiveTransitionItems
                var changedTransitionObjects = Set<UUID>()
                for previous in previousObjects {
                    if let current = currentObjects.first(where: { $0.id == previous.id }) {
                        if current != previous { changedTransitionObjects.insert(current.id) }
                    } else {
                        changedTransitionObjects.insert(previous.id)
                    }
                }
                for current in currentObjects where !previousObjects.contains(where: { $0.id == current.id }) {
                    changedTransitionObjects.insert(current.id)
                }
                affected.formUnion(changedTransitionObjects)
                if !changedTransitionObjects.isEmpty {
                    applied.append("объекты переходов обновлены: \(changedTransitionObjects.count)")
                }
                mutate(target, description: { "переход «\(transition?.localizedTitle ?? "без перехода")» для \($0) фрагм." }) { $0.transition = transition?.rawValue }
            case .setTransitionPattern(let styles, let target):
                let positions = indexes(for: target)
                guard !positions.isEmpty, !styles.isEmpty else {
                    ignored.append("фрагменты для чередования переходов не найдены")
                    continue
                }
                let applicable = positions.filter { index in
                    timeline.items.indices.contains(where: { previous in
                        previous < index && timeline.items[previous].kind != .title && timeline.items[previous].overlay == nil
                    })
                }
                let styleByIncomingID = Dictionary(uniqueKeysWithValues: applicable.enumerated().map { offset, index in
                    (timeline.items[index].id, styles[offset % styles.count])
                })
                let previousTransitions = timeline.effectiveTransitionItems
                timeline.transitionItems = previousTransitions.map { transition in
                    guard let style = styleByIncomingID[transition.incomingClipID] else { return transition }
                    var copy = transition
                    copy.style = style
                    copy.intensity = TransitionPresetRegistry.preset(for: style).defaultIntensity
                    copy.parameters = TransitionPresetRegistry.preset(for: style).defaultParameters
                    return copy
                }
                var changedTransitionIDs = Set<UUID>()
                for current in timeline.effectiveTransitionItems {
                    if previousTransitions.first(where: { $0.id == current.id }) != current {
                        changedTransitionIDs.insert(current.id)
                    }
                }
                affected.formUnion(changedTransitionIDs)
                var changed = 0
                for (offset, index) in applicable.enumerated() {
                    let style = styles[offset % styles.count]
                    if timeline.items[index].transition != style.rawValue {
                        timeline.items[index].transition = style.rawValue
                        affected.insert(timeline.items[index].id)
                        changed += 1
                    }
                }
                if changed > 0 || !changedTransitionIDs.isEmpty {
                    applied.append("чередование \(styles.count) переходов для \(max(changed, changedTransitionIDs.count)) фрагм.")
                } else {
                    ignored.append(applicable.isEmpty ? "для перехода нужен предыдущий фрагмент" : "чередование переходов уже установлено")
                }
            case .setEffect(let effect, let target):
                if effect == nil {
                    let targetIDs = Set(indexes(for: target).map { timeline.items[$0].id })
                    let removed = timeline.effectiveEffects.filter { item in
                        item.targetClipID.map(targetIDs.contains) ?? false
                    }
                    if !removed.isEmpty {
                        let removedIDs = Set(removed.map(\.id))
                        timeline.effects = timeline.effectiveEffects.filter { !removedIDs.contains($0.id) }
                        affected.formUnion(removedIDs)
                        applied.append("объекты эффектов удалены: \(removed.count)")
                    }
                }
                mutate(target, description: { "эффект «\(effect?.localizedTitle ?? "без эффекта")» для \($0) фрагм." }) { $0.effect = effect?.rawValue }
            case .setEffectPattern(let effects, let target):
                let positions = indexes(for: target)
                guard !positions.isEmpty, !effects.isEmpty else {
                    ignored.append("фрагменты для чередования эффектов не найдены")
                    continue
                }
                var changed = 0
                for (offset, index) in positions.enumerated() {
                    let effect = effects[offset % effects.count]
                    if timeline.items[index].effect != effect.rawValue {
                        timeline.items[index].effect = effect.rawValue
                        affected.insert(timeline.items[index].id)
                        changed += 1
                    }
                }
                if changed > 0 {
                    applied.append("чередование \(effects.count) эффектов для \(changed) фрагм.")
                } else {
                    ignored.append("чередование эффектов уже установлено")
                }
            case .setOverlay(let style, let foregroundTarget, let backgroundTarget):
                let foregrounds = indexes(for: foregroundTarget)
                guard let foregroundIndex = foregrounds.last else {
                    ignored.append("клип для наложения не найден")
                    continue
                }
                if let style {
                    let backgroundCandidates = indexes(for: backgroundTarget ?? .first)
                        .filter { $0 != foregroundIndex && timeline.items[$0].overlay == nil }
                    let preceding = timeline.items.indices
                        .filter { $0 < foregroundIndex && timeline.items[$0].overlay == nil }
                        .last
                    guard let backgroundIndex = backgroundCandidates.first ?? preceding else {
                        ignored.append("основной клип для наложения не найден")
                        continue
                    }
                    timeline.items[foregroundIndex].overlay = OverlaySettings(
                        style: style,
                        baseItemID: timeline.items[backgroundIndex].id
                    )
                    affected.formUnion([timeline.items[foregroundIndex].id, timeline.items[backgroundIndex].id])
                    applied.append("«\(style.localizedTitle)»: клип \(foregroundIndex + 1) наложен на клип \(backgroundIndex + 1)")
                } else {
                    timeline.items[foregroundIndex].overlay = nil
                    affected.insert(timeline.items[foregroundIndex].id)
                    applied.append("наложение убрано")
                }
            case .setTelemetryOverlay(let settings, let target):
                let targetIndexes = indexes(for: target)
                mutate(target, description: { settings == nil ? "телеметрия скрыта у \($0) фрагм." : "телеметрия добавлена к \($0) фрагм." }) { item in
                    if var settings, let existing = item.telemetryOverlay {
                        settings.metrics.formUnion(existing.metrics)
                        item.telemetryOverlay = settings
                    } else {
                        item.telemetryOverlay = settings
                    }
                }
                var telemetryItems = timeline.effectiveTelemetryItems
                for index in targetIndexes where timeline.items.indices.contains(index) {
                    let item = timeline.items[index]
                    telemetryItems.removeAll { $0.linkedAssetID == item.assetID && abs($0.timelineStart - item.timelineStart) < 0.001 }
                    if let settings, let assetID = item.assetID {
                        telemetryItems.append(TimelineTelemetryItem(
                            targetClipID: item.id,
                            linkedAssetID: assetID,
                            sourceStart: item.sourceStart,
                            timelineStart: item.timelineStart,
                            timelineDuration: item.timelineDuration,
                            settings: settings,
                            explanation: ["Команда AI Editor: telemetry"]
                        ))
                    }
                }
                timeline.telemetryItems = telemetryItems
            case .insertFreezeFrame(let duration, let target):
                let positions = indexes(for: target).sorted(by: >)
                guard !positions.isEmpty else {
                    ignored.append("клип для стоп-кадра не найден")
                    continue
                }
                for index in positions {
                    let original = timeline.items[index]
                    var freeze = original
                    freeze.id = UUID()
                    freeze.candidateID = nil
                    freeze.sourceStart = original.sourceStart + max(0, original.sourceDuration * 0.5)
                    freeze.sourceDuration = original.kind == .video ? 1 / 30 : duration
                    freeze.timelineDuration = duration
                    freeze.speed = 1
                    freeze.speedRamp = nil
                    freeze.freezeFrame = true
                    freeze.reversePlayback = false
                    freeze.overlay = nil
                    freeze.transition = nil
                    freeze.audioAdjustments = AudioAdjustments(muted: true)
                    freeze.explanation.append("Стоп-кадр добавлен по запросу режиссёру")
                    timeline.items.insert(freeze, at: index + 1)
                    affected.insert(freeze.id)
                }
                applied.append("добавлен стоп-кадр \(Self.number(duration)) с")
            case .insertInstantReplay(let speed, let target):
                let positions = indexes(for: target).sorted(by: >)
                guard !positions.isEmpty else {
                    ignored.append("клип для мгновенного повтора не найден")
                    continue
                }
                for index in positions {
                    var replay = timeline.items[index]
                    replay.id = UUID()
                    replay.candidateID = nil
                    replay.speed = min(max(0.1, speed), 1)
                    replay.speedRamp = nil
                    replay.timelineDuration = max(0.25, replay.sourceDuration / replay.speed)
                    replay.overlay = nil
                    replay.transition = nil
                    replay.locked = false
                    replay.explanation.append("Мгновенный повтор добавлен по запросу режиссёру")
                    timeline.items.insert(replay, at: index + 1)
                    affected.insert(replay.id)
                }
                applied.append("добавлен мгновенный повтор со скоростью \(Self.number(speed))×")
            case .setReverse(let reversed, let target):
                mutate(target, description: { reversed ? "обратное воспроизведение для \($0) фрагм." : "обычное воспроизведение для \($0) фрагм." }) { item in
                    item.reversePlayback = reversed ? true : nil
                    if reversed {
                        item.speedRamp = nil
                        item.timelineDuration = max(0.05, item.sourceDuration / item.speed)
                        var audio = item.effectiveAudioAdjustments
                        audio.muted = true
                        item.audioAdjustments = audio
                    }
                }
            case .addTitle(let text, let position):
                let cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !SmartTitleEngine.isMeaningless(cleanText) else {
                    ignored.append("служебная формулировка «\(cleanText)» не является текстом титра")
                    continue
                }
                let normalizedText = cleanText.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                guard !timeline.effectiveTitleItems.contains(where: {
                    $0.text.trimmingCharacters(in: .whitespacesAndNewlines)
                        .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) == normalizedText
                }) else {
                    ignored.append("титр «\(cleanText)» уже есть в фильме")
                    continue
                }
                let decision = SmartTitleEngine().decide(SmartTitleContext(
                    purpose: position == .beginning ? .filmOpening : .ending,
                    requestedText: cleanText,
                    usedTitles: timeline.effectiveTitleItems.map(\.text),
                    preferredTemplateID: position == .beginning ? "title.minimal-clean.v1" : "title.end-card.v1"
                ))
                guard let decision else {
                    ignored.append("для титра «\(cleanText)» нет подтверждённого текста или подходящего шаблона")
                    continue
                }
                let template = TitleTemplateRegistry.template(id: decision.templateID)
                    ?? TitleTemplateRegistry.defaultTemplate(for: position == .beginning ? .title : .endCard)
                let duration = min(decision.duration, max(0.05, timeline.duration))
                let occupied = timeline.effectiveTitleItems.filter {
                    $0.enabled && $0.track == 0 && ![.automaticSubtitles, .wordLevelCaptions, .subtitle].contains($0.kind)
                }
                var start = position == .beginning ? 0 : max(0, timeline.duration - duration)
                if position == .beginning {
                    while let collision = occupied
                        .filter({ $0.startTime < start + duration && $0.endTime > start })
                        .max(by: { $0.endTime < $1.endTime }) {
                        start = collision.endTime + 0.12
                    }
                } else {
                    while let collision = occupied
                        .filter({ $0.startTime < start + duration && $0.endTime > start })
                        .min(by: { $0.startTime < $1.startTime }) {
                        start = collision.startTime - duration - 0.12
                    }
                }
                guard start >= 0, start + duration <= timeline.duration + 0.001 else {
                    ignored.append("для титра «\(cleanText)» нет свободного места без наложения")
                    continue
                }
                let title = TitleTimelineItem(
                    kind: template?.kind ?? .title,
                    templateID: template?.id,
                    text: decision.primaryText,
                    additionalText: decision.secondaryText,
                    startTime: start,
                    duration: duration,
                    style: template?.defaultStyle ?? TitleStyle(),
                    explanation: ["Титр добавлен по запросу режиссёру"] + decision.explanation
                )
                timeline.titleItems = timeline.effectiveTitleItems + [title]
                affected.insert(title.id)
                applied.append("титр «\(cleanText)» добавлен без наложения")
            case .setTitleStyle(let fontSize, let textColor, let backgroundColor, let alignment, let target):
                let legacyPositions = titleIndexes(for: target)
                let objectPositions = titleObjectIndexes(for: target)
                guard !legacyPositions.isEmpty || !objectPositions.isEmpty else {
                    ignored.append("титр для оформления не найден")
                    continue
                }
                for index in legacyPositions {
                    var style = timeline.items[index].effectiveTitleStyle
                    if let fontSize { style.fontSize = min(max(18, fontSize), 220) }
                    if let textColor { style.textColorHex = textColor }
                    if let backgroundColor { style.backgroundColorHex = backgroundColor }
                    if let alignment { style.alignment = alignment }
                    timeline.items[index].titleStyle = style
                    affected.insert(timeline.items[index].id)
                }
                var titleObjects = timeline.effectiveTitleItems
                for index in objectPositions {
                    if let fontSize { titleObjects[index].style.fontSize = min(max(18, fontSize), 220) }
                    if let textColor { titleObjects[index].style.textColorHex = textColor }
                    if let backgroundColor { titleObjects[index].style.backgroundColorHex = backgroundColor }
                    if let alignment { titleObjects[index].style.alignment = alignment }
                    titleObjects[index].userEdited = true
                    affected.insert(titleObjects[index].id)
                }
                timeline.titleItems = titleObjects
                applied.append("оформление изменено у титров: \(legacyPositions.count + objectPositions.count)")
            case .removeTitles:
                let ids = timeline.items.filter { $0.kind == .title }.map(\.id) + timeline.effectiveTitleItems.map(\.id)
                timeline.items.removeAll { $0.kind == .title }
                timeline.titleItems = []
                affected.formUnion(ids)
                ids.isEmpty ? ignored.append("в фильме нет титров") : applied.append("удалено титров: \(ids.count)")
            case .delete(let target):
                let positions = indexes(for: target).sorted(by: >)
                guard !positions.isEmpty else { ignored.append("фрагмент для удаления не найден"); continue }
                for index in positions { affected.insert(timeline.items.remove(at: index).id) }
                applied.append("удалено фрагментов: \(positions.count)")
            case .duplicate(let target):
                let positions = indexes(for: target).sorted(by: >)
                guard !positions.isEmpty else { ignored.append("фрагмент для копирования не найден"); continue }
                for index in positions {
                    var copy = timeline.items[index]
                    copy.id = UUID()
                    copy.locked = false
                    timeline.items.insert(copy, at: index + 1)
                    affected.insert(copy.id)
                }
                applied.append("создано копий: \(positions.count)")
            case .split(let target):
                let positions = indexes(for: target).sorted(by: >)
                guard !positions.isEmpty else { ignored.append("фрагмент для разделения не найден"); continue }
                for index in positions {
                    var first = timeline.items[index]
                    var second = first
                    let firstTimelineDuration = max(0.125, first.timelineDuration / 2)
                    let firstSourceDuration = first.sourceDuration / 2
                    first.timelineDuration = firstTimelineDuration
                    first.sourceDuration = firstSourceDuration
                    second.id = UUID()
                    second.sourceStart += firstSourceDuration
                    second.sourceDuration -= firstSourceDuration
                    second.timelineDuration -= firstTimelineDuration
                    timeline.items[index] = first
                    timeline.items.insert(second, at: index + 1)
                    affected.formUnion([first.id, second.id])
                }
                applied.append("разделено фрагментов: \(positions.count)")
            case .move(let target, let position):
                let positions = indexes(for: target)
                guard positions.count == 1, let index = positions.first else { ignored.append("для перемещения нужен один фрагмент"); continue }
                let item = timeline.items.remove(at: index)
                if position == .beginning { timeline.items.insert(item, at: 0) } else { timeline.items.append(item) }
                affected.insert(item.id)
                applied.append("фрагмент перемещён \(position == .beginning ? "в начало" : "в конец")")
            case .setOriginalAudioVolume(let volume):
                timeline = SourceAudioMixPolicy.applyingRequestedVolume(volume, to: timeline)
                applied.append(volume < 0.001
                    ? "звук исходников отключён"
                    : "громкость звука исходников \(Int((min(max(0, volume), 1) * 100).rounded()))%")
            case .setMusic(let directive):
                timeline.music = directive
                timeline.adaptiveSoundtrack = nil
                applied.append(directive.map { "музыка «\($0.style.localizedTitle)» добавлена" } ?? "музыка удалена")
            case .setMusicVolume(let volume):
                guard var music = timeline.music else { ignored.append("сначала нужно добавить музыку"); continue }
                music.volume = min(max(0, volume), 1)
                timeline.music = music
                applied.append("громкость музыки \(Int((volume * 100).rounded()))%")
            }
        }

        timeline.items = TimelineTiming.retimed(timeline.items)
        return (timeline, EditorCommandReport(
            recognizedCount: commands.count,
            applied: applied,
            ignored: ignored,
            affectedItemIDs: Array(affected)
        ))
    }

    private static func number(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...2)))
    }
}
