import Foundation
import VeloEditCore

#if canImport(FoundationModels)
import FoundationModels
#endif

struct DirectorAIReply: Sendable {
    let text: String
    let runtimeLabel: String
    let normalizedBrief: String?
    let commands: [EditorCommand]

    init(text: String, runtimeLabel: String, normalizedBrief: String?, commands: [EditorCommand] = []) {
        self.text = text
        self.runtimeLabel = runtimeLabel
        self.normalizedBrief = normalizedBrief
        self.commands = commands
    }
}

private struct OllamaMessage: Codable, Sendable {
    let role: String
    let content: String
}

private struct OllamaOptions: Encodable {
    let temperature = 0.2
    // A typed multi-action plan is larger than the old two-string response.
    // Keep enough room so a request with several edits is not truncated into
    // invalid JSON and silently downgraded to the deterministic fallback.
    let numPredict = 480

    enum CodingKeys: String, CodingKey {
        case temperature
        case numPredict = "num_predict"
    }
}

private struct OllamaChatRequest: Encodable {
    let model: String
    let messages: [OllamaMessage]
    let stream = false
    let think = false
    let format = OllamaDirectorSchema()
    let keepAlive = "15m"
    let options = OllamaOptions()

    enum CodingKeys: String, CodingKey {
        case model, messages, stream, think, format, options
        case keepAlive = "keep_alive"
    }
}

private struct OllamaDirectorSchema: Encodable {
    struct StringProperty: Encodable { let type = "string" }
    struct EnumStringProperty: Encodable {
        let type = "string"
        let values: [String]
        enum CodingKeys: String, CodingKey { case type; case values = "enum" }
    }
    struct CommandProperties: Encodable {
        let action = EnumStringProperty(values: OllamaDirectorCommand.supportedActions)
        let target = StringProperty()
        let value = StringProperty()
        let secondaryTarget = StringProperty()
    }
    struct CommandItem: Encodable {
        let type = "object"
        let properties = CommandProperties()
        let required = ["action", "target", "value", "secondaryTarget"]
        let additionalProperties = false
        enum CodingKeys: String, CodingKey {
            case type, properties, required
            case additionalProperties = "additionalProperties"
        }
    }
    struct CommandArray: Encodable {
        let type = "array"
        let items = CommandItem()
    }
    struct RootProperties: Encodable {
        let reply = StringProperty()
        let normalizedBrief = StringProperty()
        let commands = CommandArray()
    }
    let type = "object"
    let properties = RootProperties()
    let required = ["reply", "normalizedBrief", "commands"]
    let additionalProperties = false

    enum CodingKeys: String, CodingKey {
        case type, properties, required
        case additionalProperties = "additionalProperties"
    }
}

private struct OllamaChatResponse: Decodable {
    let message: OllamaMessage
}

private struct OllamaDirectorPayload: Decodable {
    let reply: String
    let normalizedBrief: String?
    let commands: [OllamaDirectorCommand]

    enum CodingKeys: String, CodingKey { case reply, normalizedBrief, commands }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        reply = try container.decode(String.self, forKey: .reply)
        normalizedBrief = try? container.decodeIfPresent(String.self, forKey: .normalizedBrief)
        commands = (try? container.decodeIfPresent([OllamaDirectorCommand].self, forKey: .commands)) ?? []
    }
}

private struct OllamaDirectorCommand: Decodable {
    let action: String
    let target: String
    let value: String
    let secondaryTarget: String

    static let supportedActions = [
        "set_speed", "set_speed_ramp", "set_duration", "set_filter", "set_crop", "rotate",
        "set_brightness", "set_contrast", "set_saturation", "set_warmth", "set_opacity",
        "set_exposure", "set_highlights", "set_shadows", "set_vignette", "set_grain",
        "set_sharpening", "set_video_denoise", "set_blur", "set_stabilization",
        "set_rolling_shutter", "set_smooth_slow_motion", "auto_enhance",
        "set_clip_volume", "set_clip_muted", "set_clip_fades", "set_noise_reduction", "set_eq",
        "detach_audio", "set_audio_ducking",
        "set_transition", "set_transition_pattern", "set_effect", "set_effect_pattern", "set_overlay",
        "set_telemetry", "insert_freeze_frame", "insert_instant_replay", "set_reverse", "add_title",
        "remove_titles", "delete", "duplicate", "split", "move", "set_original_audio_volume",
        "set_music", "set_music_volume"
    ]
}

private struct OllamaTagsResponse: Decodable {
    struct Model: Decodable { let name: String }
    let models: [Model]
}

@MainActor
final class LocalDirectorAgent {
    private static let ollamaModel = "qwen3:4b-instruct"
    private static let ollamaRuntimeLabel = "Qwen3 4B Instruct · локальная нейросеть"
    private static let ollamaBaseURL = URL(string: "http://127.0.0.1:11434")!
    private let fallback = DirectorFallbackReply()
    private var ollamaHistory: [OllamaMessage] = []

    #if canImport(FoundationModels)
    // The stored type remains deployment-target neutral and is cast only
    // inside a macOS 26 availability gate.
    private var appleSession: Any?
    #endif

    static func currentRuntimeLabel() -> String {
        "Проверяю локальную нейросеть…"
    }

    func runtimeStatus() async -> String {
        if await hasOllamaModel() { return Self.ollamaRuntimeLabel }
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), SystemLanguageModel.default.isAvailable {
            return "Apple Intelligence · локальная нейросеть"
        }
        #endif
        return "Базовый алгоритм · это не нейросеть"
    }

    func reset() {
        ollamaHistory = []
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) { appleSession = nil }
        #endif
    }

    func restoreConversation(_ messages: [DirectorMessage]) {
        reset()
        guard let firstUser = messages.firstIndex(where: { $0.role == .user }) else { return }
        ollamaHistory = messages[firstUser...]
            .filter { !$0.text.isEmpty }
            .map { message in
                OllamaMessage(role: message.role == .user ? "user" : "assistant", content: message.text)
            }
        if ollamaHistory.count > 10 {
            ollamaHistory.removeFirst(ollamaHistory.count - 10)
        }
    }

    func respond(
        to userMessage: String,
        context: DirectorContext,
        mode: DirectorRequestMode = .edit
    ) async -> DirectorAIReply {
        if let reply = try? await respondWithOllama(to: userMessage, context: context, mode: mode) {
            return reply
        }

        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), SystemLanguageModel.default.isAvailable {
            do {
                let session = (appleSession as? LanguageModelSession) ?? makeAppleSession()
                appleSession = session
                let response = try await session.respond(to: """
                    \(context.modelPrompt)

                    Последнее сообщение пользователя:
                    \(userMessage)

                    Режим запроса: \(mode == .advisory ? "только совет; ничего не менять" : "подготовка монтажной правки").
                    Ответь как режиссёр: конкретно перескажи замысел и назови следующий шаг. Обязательно учитывай точные числа из запроса. Не утверждай, что видел содержание кадров, если анализ не завершён. В режиме совета дай конкретные варианты по данным анализа и явно скажи, что исходник и Timeline не изменены.
                    """)
                let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    return DirectorAIReply(text: text, runtimeLabel: "Apple Intelligence · локальная нейросеть", normalizedBrief: nil)
                }
            } catch { /* Explicit fallback below. */ }
        }
        #endif

        return DirectorAIReply(
            text: fallback.make(userMessage: userMessage, context: context),
            runtimeLabel: "Базовый алгоритм · это не нейросеть",
            normalizedBrief: nil
        )
    }

    private func respondWithOllama(
        to userMessage: String,
        context: DirectorContext,
        mode: DirectorRequestMode
    ) async throws -> DirectorAIReply {
        guard await hasOllamaModel() else { throw URLError(.cannotConnectToHost) }
        let requestModeInstruction = mode == .advisory
            ? "РЕЖИМ СОВЕТА: предложи музыку, название или объясни звук по данным анализа. Ничего не применяй, пиши в настоящем времени, верни commands: [] и пустой normalizedBrief. Обязательно скажи, что исходник и Timeline не изменены."
            : "РЕЖИМ МОНТАЖА: подготовь исполняемый план только для явно запрошенных изменений."
        let system = OllamaMessage(role: "system", content: """
            Ты монтажный режиссёр внутри VeloEdit. Отвечай естественно по-русски, ровно 1–2 короткими предложениями. Реагируй только на пожелание пользователя: не пересказывай служебную сводку, не делай арифметических расчётов и не выдумывай стиль или длительность. Точные числа повторяй буквально и считай жёсткими ограничениями. Сейчас ты только принимаешь задачу: пиши в будущем времени и не утверждай, что фильм, звук или музыка уже изменены. Например, говори «отключу звук исходников после применения правок», а не «звук убран». Не притворяйся, что просмотрел кадры, если анализ не завершён.

            \(requestModeInstruction)

            Верни только JSON по выданной схеме: reply — ответ пользователю; normalizedBrief — краткий русский бриф для подбора истории; commands — полный исполняемый план. На каждое действие создавай отдельный элемент commands. target всегда один из: all, selected, first, last или number:N. Для неиспользуемых value и secondaryTarget передавай пустую строку. secondaryTarget нужен только наложению и использует тот же формат цели.

            Значения пиши только кодами движка. set_transition: cross-dissolve, fade, fade-through-black, blur-dissolve, light-flash, slide-left, slide-right, push, zoom, wipe-left, wipe-right или none. set_transition_pattern: список этих кодов через запятую. Переход хранится на входящем клипе: «после первого клипа» означает target number:2, «между вторым и третьим» — number:3. set_effect: ken-burns, zoom-in, zoom-out, push-in, pull-out, pan-left, pan-right, mirror или none. set_effect_pattern: список кодов через запятую. set_filter: none, monochrome, noir, sepia, vivid, warm, cool, dramatic. set_crop: fit или fill. set_eq: flat, voice, music, bass-reduction, presence. set_overlay: cutaway, picture-in-picture, split-screen, green-screen или none. set_telemetry: speed, route, altitude, distance, g-force через запятую или none. Числовые value передавай десятичным числом без единиц; true/false — буквально. set_clip_fades: два числа fade-in,fade-out. add_title: текст в value и beginning/end в target. move: beginning/end в value. set_music: energetic, cinematic, calm, joyful, electronic, acoustic, different или none.

            Для set_sharpening, set_video_denoise, set_blur и set_stabilization value — 0...1. set_rolling_shutter, set_smooth_slow_motion и set_audio_ducking принимают true/false. detach_audio не использует value. «Приглуши музыку» означает set_music_volume, а «музыку тише под речь» — set_audio_ducking. «Убери шум» означает set_noise_reduction; отличай аудиошум от video denoise. «Сделай голос/речь тише» может уменьшить громкость исходной дорожки через set_clip_volume, но не обещай изоляцию голоса из уже смешанной фонограммы. Сохраняй все действия, точные числа и цели пользователя. Количество моментов, темп истории, предпочтения по содержанию и общую длительность сохраняй в normalizedBrief, но не выдумывай для них command, если такого action нет. При просьбе «сделай динамичнее» выбирай локальные монтажные решения по контексту: убрать слабое, укоротить затянутое, усилить action и кульминацию; не ускоряй автоматически все клипы. Полная пересборка разрешает Story Engine вернуть ранее неиспользованные фрагменты и изменить структуру, но commands должны содержать только доступные typed actions. VeloEdit сам ищет и скачивает разрешённые non-premium треки через официальный Free To Use API, даже если локальная библиотека сейчас пуста. Никогда не отвечай, что пользователь должен вручную добавить музыку или что локальный трек не найден: для монтажного музыкального запроса подтверди подбор, а приложение сообщит фактический результат загрузки. Музыку нельзя генерировать. Не добавляй действий, которых пользователь не просил, и не называй в reply эффекты, которых нет в commands.
            """)
        let hardConstraint: String
        if let count = PromptInterpreter.requestedClipCount(from: userMessage.lowercased()) {
            hardConstraint = "Жёсткое ограничение из сообщения: количество моментов равно \(count). Это обязательное точное число."
        } else {
            hardConstraint = "Явного ограничения на количество моментов нет."
        }
        let contextualUser = OllamaMessage(role: "user", content: """
            \(context.modelPrompt)

            \(hardConstraint)
            Сообщение пользователя:
            \(userMessage)
            """)
        let messages = [system] + Array(ollamaHistory.suffix(8)) + [contextualUser]
        let payload = OllamaChatRequest(model: Self.ollamaModel, messages: messages)
        var request = URLRequest(url: Self.ollamaBaseURL.appendingPathComponent("api/chat"))
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        let envelope = try JSONDecoder().decode(OllamaChatResponse.self, from: data)
        let content = Self.cleanedJSON(envelope.message.content)
        let decoded = try JSONDecoder().decode(OllamaDirectorPayload.self, from: Data(content.utf8))
        let reply = decoded.reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reply.isEmpty else { throw URLError(.cannotParseResponse) }

        ollamaHistory.append(OllamaMessage(role: "user", content: userMessage))
        ollamaHistory.append(OllamaMessage(role: "assistant", content: reply))
        if ollamaHistory.count > 10 { ollamaHistory.removeFirst(ollamaHistory.count - 10) }
        return DirectorAIReply(
            text: reply,
            runtimeLabel: Self.ollamaRuntimeLabel,
            normalizedBrief: decoded.normalizedBrief?.trimmingCharacters(in: .whitespacesAndNewlines),
            commands: decoded.commands.compactMap(Self.editorCommand)
        )
    }

    private static func editorCommand(_ command: OllamaDirectorCommand) -> EditorCommand? {
        let action = command.action.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let value = command.value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let target = editorTarget(command.target)
        let number = numericValue(value)

        switch action {
        case "set_speed": return target.flatMap { target in number.map { .setSpeed($0, target) } }
        case "set_speed_ramp":
            guard let target else { return nil }
            let ramp: SpeedRamp? = value == "none" || value == "off" ? nil
                : value == "ease-in" ? .easeIn
                : value == "ease-out" ? .easeOut
                : .action
            return .setSpeedRamp(ramp, target)
        case "set_duration": return target.flatMap { target in number.map { .setDuration($0, target) } }
        case "set_filter": return target.flatMap { target in VideoFilter(rawValue: value).map { .setFilter($0, target) } }
        case "set_crop": return target.flatMap { target in CropStyle(rawValue: value).map { .setCrop($0, target) } }
        case "rotate":
            guard let target else { return nil }
            let turns = value.contains("left") ? -1 : value.contains("right") ? 1 : Int(number ?? 0)
            return turns == 0 ? nil : .rotate(turns, target)
        case "set_brightness": return normalized(number, maximum: 1).flatMap { amount in target.map { .setBrightness(amount, $0) } }
        case "set_contrast": return normalized(number, maximum: 4).flatMap { amount in target.map { .setContrast(amount, $0) } }
        case "set_saturation": return normalized(number, maximum: 2).flatMap { amount in target.map { .setSaturation(amount, $0) } }
        case "set_warmth": return normalized(number, maximum: 1).flatMap { amount in target.map { .setWarmth(amount, $0) } }
        case "set_opacity": return normalized(number, maximum: 1).flatMap { amount in target.map { .setOpacity(amount, $0) } }
        case "set_exposure": return target.flatMap { target in number.map { .setExposure($0, target) } }
        case "set_highlights": return normalized(number, maximum: 1).flatMap { amount in target.map { .setHighlights(amount, $0) } }
        case "set_shadows": return normalized(number, maximum: 1).flatMap { amount in target.map { .setShadows(amount, $0) } }
        case "set_vignette": return normalized(number, maximum: 1).flatMap { amount in target.map { .setVignette(amount, $0) } }
        case "set_grain": return normalized(number, maximum: 1).flatMap { amount in target.map { .setGrain(amount, $0) } }
        case "set_sharpening": return normalized(number, maximum: 1).flatMap { amount in target.map { .setSharpening(amount, $0) } }
        case "set_video_denoise": return normalized(number, maximum: 1).flatMap { amount in target.map { .setVideoDenoise(amount, $0) } }
        case "set_blur": return normalized(number, maximum: 1).flatMap { amount in target.map { .setBlur(amount, $0) } }
        case "set_stabilization": return normalized(number, maximum: 1).flatMap { amount in target.map { .setStabilization(amount, $0) } }
        case "set_rolling_shutter": return target.map { .setRollingShutterCorrection(booleanValue(value, default: true), $0) }
        case "set_smooth_slow_motion": return target.map { .setSmoothSlowMotion(booleanValue(value, default: true), $0) }
        case "auto_enhance": return target.map(EditorCommand.autoEnhance)
        case "set_clip_volume": return normalized(number, maximum: 2).flatMap { amount in target.map { .setClipVolume(amount, $0) } }
        case "set_clip_muted": return target.map { .setClipMuted(booleanValue(value, default: true), $0) }
        case "set_clip_fades":
            guard let target else { return nil }
            let values = numericList(value)
            guard !values.isEmpty else { return nil }
            return .setClipFades(values[0], values.count > 1 ? values[1] : values[0], target)
        case "set_noise_reduction": return normalized(number, maximum: 1).flatMap { amount in target.map { .setNoiseReduction(amount, $0) } }
        case "set_eq": return target.flatMap { target in AudioEQPreset(rawValue: value).map { .setEQ($0, target) } }
        case "detach_audio": return target.map(EditorCommand.detachAudio)
        case "set_audio_ducking": return .setAudioDucking(booleanValue(value, default: true))
        case "set_transition":
            guard let target else { return nil }
            if value == "none" || value == "off" { return .setTransition(nil, target) }
            if value == "different" || value == "varied" {
                return .setTransitionPattern([.crossDissolve, .lightFlash, .blurDissolve, .slideRight], target)
            }
            return TransitionStyle(rawValue: value).map { .setTransition($0, target) }
        case "set_transition_pattern":
            guard let target else { return nil }
            let styles = stringList(value).compactMap(TransitionStyle.init(rawValue:))
            return styles.isEmpty ? nil : .setTransitionPattern(styles, target)
        case "set_effect":
            guard let target else { return nil }
            if value == "none" || value == "off" { return .setEffect(nil, target) }
            if value == "different" || value == "varied" {
                return .setEffectPattern([.pushIn, .panLeft, .pullOut, .panRight], target)
            }
            return ClipEffect(rawValue: value).map { .setEffect($0, target) }
        case "set_effect_pattern":
            guard let target else { return nil }
            let effects = stringList(value).compactMap(ClipEffect.init(rawValue:))
            return effects.isEmpty ? nil : .setEffectPattern(effects, target)
        case "set_overlay":
            guard let target else { return nil }
            if value == "none" || value == "off" { return .setOverlay(nil, target, nil) }
            return OverlayStyle(rawValue: value).map { .setOverlay($0, target, editorTarget(command.secondaryTarget)) }
        case "set_telemetry":
            guard let target else { return nil }
            if value == "none" || value == "off" { return .setTelemetryOverlay(nil, target) }
            let metrics = Set(stringList(value).compactMap(TelemetryMetric.init(rawValue:)))
            return metrics.isEmpty ? nil : .setTelemetryOverlay(TelemetryOverlaySettings(metrics: metrics), target)
        case "insert_freeze_frame": return target.map { .insertFreezeFrame(number ?? 2, $0) }
        case "insert_instant_replay": return target.map { .insertInstantReplay(number ?? 0.5, $0) }
        case "set_reverse": return target.map { .setReverse(booleanValue(value, default: true), $0) }
        case "add_title":
            let title = command.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return nil }
            let position: TimelineInsertionPosition = command.target.lowercased().contains("end") ? .end : .beginning
            return .addTitle(title, position)
        case "remove_titles": return .removeTitles
        case "delete": return target.map(EditorCommand.delete)
        case "duplicate": return target.map(EditorCommand.duplicate)
        case "split": return target.map(EditorCommand.split)
        case "move":
            guard let target else { return nil }
            return .move(target, value.contains("begin") || value.contains("start") ? .beginning : .end)
        case "set_original_audio_volume": return normalized(number, maximum: 1).map(EditorCommand.setOriginalAudioVolume)
        case "set_music":
            if value == "none" || value == "off" { return .setMusic(nil) }
            if value == "different" {
                return .setMusic(MusicDirective(style: .cinematic, bpm: 82, preferDifferentTrack: true))
            }
            guard let style = MusicStyle(rawValue: value) else { return nil }
            return .setMusic(MusicDirective(style: style, bpm: defaultBPM(for: style)))
        case "set_music_volume": return normalized(number, maximum: 1).map(EditorCommand.setMusicVolume)
        default: return nil
        }
    }

    private static func editorTarget(_ raw: String) -> EditorCommandTarget? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value == "all" || value == "all clips" || value == "все клипы" { return .all }
        if value == "selected" || value == "selected clip" || value == "выбранный клип" { return .selected }
        if value == "first" || value == "first clip" || value == "первый клип" { return .first }
        if value == "last" || value == "last clip" || value == "последний клип" { return .last }
        let suffix = value.split(separator: ":").last.map(String.init) ?? value
        if let number = Int(suffix), number > 0 { return .number(number) }
        return nil
    }

    private static func numericValue(_ value: String) -> Double? {
        Double(value.replacingOccurrences(of: ",", with: ".").replacingOccurrences(of: "%", with: ""))
    }

    private static func numericList(_ value: String) -> [Double] {
        value.split(separator: ",").compactMap { numericValue(String($0).trimmingCharacters(in: .whitespaces)) }
    }

    private static func stringList(_ value: String) -> [String] {
        value.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
    }

    private static func normalized(_ value: Double?, maximum: Double) -> Double? {
        guard var value, value.isFinite else { return nil }
        if abs(value) > maximum { value /= 100 }
        return value
    }

    private static func booleanValue(_ value: String, default fallback: Bool) -> Bool {
        if ["false", "no", "off", "0", "нет"].contains(value) { return false }
        if ["true", "yes", "on", "1", "да"].contains(value) { return true }
        return fallback
    }

    private static func defaultBPM(for style: MusicStyle) -> Double {
        switch style {
        case .energetic: return 132
        case .cinematic: return 82
        case .calm: return 68
        case .joyful: return 112
        case .electronic: return 124
        case .acoustic: return 94
        }
    }

    private static func cleanedJSON(_ content: String) -> String {
        var cleaned = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("```json") { cleaned.removeFirst(7) }
        else if cleaned.hasPrefix("```") { cleaned.removeFirst(3) }
        if cleaned.hasSuffix("```") { cleaned.removeLast(3) }
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func hasOllamaModel() async -> Bool {
        _ = try? await LocalAIModelManager.shared.ensureService()
        var request = URLRequest(url: Self.ollamaBaseURL.appendingPathComponent("api/tags"))
        request.timeoutInterval = 1.5
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let tags = try? JSONDecoder().decode(OllamaTagsResponse.self, from: data) else { return false }
            return tags.models.contains { $0.name == Self.ollamaModel }
        } catch {
            return false
        }
    }

    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    private func makeAppleSession() -> LanguageModelSession {
        LanguageModelSession(instructions: """
            Ты режиссёр с искусственным интеллектом в локальном приложении VeloEdit. Отвечай по-русски, естественно, конкретно и дружелюбно. Обязательно учитывай точные числа и не выдавай стандартные параметры за пожелания пользователя.
            """)
    }
    #endif
}
