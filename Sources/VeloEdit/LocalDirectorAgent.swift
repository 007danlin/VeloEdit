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
    let replacesSelectedFootage: Bool
    let judgment: DirectorJudgment?
    let isFallback: Bool
    let planningFailed: Bool

    init(text: String, runtimeLabel: String, normalizedBrief: String?, commands: [EditorCommand] = [], replacesSelectedFootage: Bool = false, judgment: DirectorJudgment? = nil, isFallback: Bool = false, planningFailed: Bool = false) {
        self.judgment = judgment
        self.isFallback = isFallback
        self.planningFailed = planningFailed
        self.text = text
        self.runtimeLabel = runtimeLabel
        self.normalizedBrief = normalizedBrief
        self.commands = commands
        self.replacesSelectedFootage = replacesSelectedFootage
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
    var numPredict = 1200

    enum CodingKeys: String, CodingKey {
        case temperature
        case numPredict = "num_predict"
    }
}

private struct OllamaChatRequest: Encodable {
    let model: String
    let messages: [OllamaMessage]
    let stream = true
    let think = false
    let format = OllamaDirectorSchema()
    let keepAlive = "15m"
    var options = OllamaOptions()

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
        normalizedBrief = try container.decodeIfPresent(String.self, forKey: .normalizedBrief)
        commands = try container.decode([OllamaDirectorCommand].self, forKey: .commands)
    }
}

private struct OllamaDirectorCommand: Decodable {
    let action: String
    let target: String
    let value: String
    let secondaryTarget: String

    static let supportedActions = [
        "replace_footage", "set_speed", "remove_slow_motion", "set_speed_ramp", "set_duration", "set_filter", "set_crop", "rotate",
        "set_brightness", "set_contrast", "set_saturation", "set_warmth", "set_opacity",
        "set_exposure", "set_highlights", "set_shadows", "set_vignette", "set_grain",
        "set_sharpening", "set_video_denoise", "set_blur", "set_stabilization",
        "set_rolling_shutter", "set_smooth_slow_motion", "auto_enhance",
        "set_clip_volume", "set_clip_muted", "set_clip_fades", "set_noise_reduction", "set_eq",
        "detach_audio", "set_audio_ducking",
        "set_transition", "set_transition_pattern", "set_effect", "set_effect_pattern", "set_overlay",
        "set_telemetry", "insert_freeze_frame", "insert_instant_replay", "set_reverse", "add_title",
        "set_title_text", "set_title_style", "remove_titles", "delete", "duplicate", "split", "move", "set_original_audio_volume",
        "set_music", "set_music_volume", "insert_background", "insert_source", "add_library_effect", "apply_title_template"
    ]
}

private struct OllamaTagsResponse: Decodable {
    struct Model: Decodable { let name: String }
    let models: [Model]
}

@MainActor
final class LocalDirectorAgent {
    typealias ResponseProvider = @MainActor (String, DirectorContext, DirectorRequestMode, Bool) async throws -> DirectorAIReply
    private let responseProvider: ResponseProvider?

    init(responseProvider: ResponseProvider? = nil) {
        self.responseProvider = responseProvider
    }
    nonisolated static let ollamaModel = "qwen3:4b-instruct"
    private static let ollamaRuntimeLabel = "Qwen3 4B Instruct · локальная нейросеть"
    private static let ollamaBaseURL = URL(string: "http://127.0.0.1:11434")!
    private var ollamaHistory: [OllamaMessage] = []
    private var modelRequestActive = false
    private var conversationGeneration: UInt64 = 0

    static func currentRuntimeLabel() -> String {
        "Проверяю локальную нейросеть…"
    }

    func runtimeStatus() async -> String {
        // Status polling does not start Ollama. First-launch model preparation
        // and actual AI requests own service startup.
        if await hasOllamaModel(startService: false) { return Self.ollamaRuntimeLabel }
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), SystemLanguageModel.default.isAvailable {
            return "Apple Intelligence · локальная нейросеть"
        }
        #endif
        return "Базовый алгоритм · это не нейросеть"
    }

    func reset() {
        conversationGeneration &+= 1
        ollamaHistory = []
    }

    var recentConversationContext: String {
        ollamaHistory.suffix(8).map {
            "\($0.role == "user" ? "Пользователь" : "Режиссёр"): \($0.content)"
        }.joined(separator: "\n\n")
    }

    func recordExchange(user: String, reply: String) {
        ollamaHistory.append(OllamaMessage(role: "user", content: user))
        ollamaHistory.append(OllamaMessage(role: "assistant", content: reply))
        if ollamaHistory.count > 10 { ollamaHistory.removeFirst(ollamaHistory.count - 10) }
    }

    func restoreConversation(_ messages: [DirectorMessage]) {
        ollamaHistory = []
        guard let firstUser = messages.firstIndex(where: { $0.role == .user }) else { return }
        ollamaHistory = messages[firstUser...]
            .filter { !$0.text.isEmpty }
            .map { message in
                OllamaMessage(role: message.role == .user ? "user" : "assistant", content: message.text + (message.response.map { record in
                    " [status=\(record.state.rawValue); saved=\(record.saved); objects=\(record.itemIDs.map(\.uuidString).joined(separator: ","))]"
                } ?? ""))
            }
        if ollamaHistory.count > 10 {
            ollamaHistory.removeFirst(ollamaHistory.count - 10)
        }
    }

    func respond(
        to userMessage: String,
        context: DirectorContext,
        mode: DirectorRequestMode = .edit,
        recordInHistory: Bool = true,
        allowsFootageReplacement: Bool = false,
        onPartialReply: (@MainActor @Sendable (String) -> Void)? = nil,
        submittedAt: Double = ProcessInfo.processInfo.systemUptime
    ) async -> DirectorAIReply {
        if mode == .advisory {
            return await respondToAdvice(userMessage, context: context, recordInHistory: recordInHistory, submittedAt: submittedAt)
        }
        if let commands = EditorCommandParser().parseComplete(userMessage, hasSelection: context.selectedItemSummary != nil) {
            return DirectorAIReply(text: "Применяю правку.", runtimeLabel: "Точная монтажная команда", normalizedBrief: nil, commands: commands)
        }
        do { try await acquireModelSlot() } catch { return DirectorAIReply(text: "", runtimeLabel: "Отменено", normalizedBrief: nil, planningFailed: true) }
        defer { modelRequestActive = false }
        for attempt in 0..<2 {
            do {
                try Task.checkCancellation()
                if let responseProvider {
                    return try await responseProvider(userMessage, context, mode, allowsFootageReplacement)
                }
                return try await respondWithOllama(
                    to: userMessage,
                    context: context,
                    mode: mode,
                    recordInHistory: recordInHistory,
                    allowsFootageReplacement: allowsFootageReplacement,
                    onPartialReply: onPartialReply,
                    repairingPlan: attempt > 0
                )
            } catch {
                guard !Task.isCancelled, !(error is CancellationError) else { return DirectorAIReply(text: "", runtimeLabel: "Отменено", normalizedBrief: nil, planningFailed: true) }
                let invalidPlan = error is DecodingError || (error as? URLError)?.code == .cannotParseResponse
                if attempt == 0, invalidPlan {
                    PerformanceTrace.current?.event("director.plan-retry")
                    onPartialReply?("Уточняю команды правки")
                    continue
                }
                return Self.planningFailure(error)
            }
        }
        return Self.planningFailure(URLError(.cannotParseResponse))
    }

    private static func planningFailure(_ error: Error) -> DirectorAIReply {
        let reason: String
        switch (error as? URLError)?.code {
        case .timedOut: reason = "Локальная модель не успела подготовить правку. Повторите запрос."
        case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .notConnectedToInternet:
            reason = "Прервалась связь с локальной моделью. Повторите запрос после её запуска."
        case .badServerResponse: reason = "Локальная модель вернула ошибку. Проверьте её состояние в настройках ИИ и повторите запрос."
        default: reason = "Не удалось разобрать все действия в запросе даже после повторной попытки. Попробуйте указать правки отдельными предложениями и назвать нужные клипы."
        }
        return DirectorAIReply(text: reason + " Изменения не применены.", runtimeLabel: "Правка не подготовлена",
            normalizedBrief: nil, isFallback: true, planningFailed: true)
    }

    private func acquireModelSlot() async throws {
        PerformanceTrace.current?.event("director.queue.enter")
        while modelRequestActive { try await Task.sleep(for: .milliseconds(20)) }
        try Task.checkCancellation()
        modelRequestActive = true
        PerformanceTrace.current?.event("director.queue.leave")
    }

    private func respondToAdvice(_ prompt: String, context: DirectorContext, recordInHistory: Bool, submittedAt: Double) async -> DirectorAIReply {
        let detailed = ["подробнее", "подробный", "подробно", "продолжи ожидание", "подожди"].contains(where: prompt.lowercased().contains)
        let generation = conversationGeneration
        let asksPastReason = DirectorResponseComposer.asksForPastEditReason(prompt)
        if responseProvider == nil, asksPastReason, !(context.moment?.facts.contains(where: { $0.kind == .decision }) ?? false) {
            let text = "В журнале нет отдельного обоснования этой правки. Можно заново оценить текущий монтаж по доступным фактам."
            if recordInHistory { recordExchange(user: prompt, reply: text) }
            return DirectorAIReply(text: text, runtimeLabel: "Готовые данные · без модели", normalizedBrief: nil, isFallback: true)
        }
        let evidenceGap = context.moment?.adviceEvidenceGap(for: prompt)
        if responseProvider == nil, (context.moment?.objects.flatMap(\.facts).isEmpty ?? true) || evidenceGap != nil {
            let text = evidenceGap ?? DirectorResponseComposer.limitedAdvice(prompt: prompt, moment: context.moment)
            if recordInHistory { recordExchange(user: prompt, reply: text) }
            return DirectorAIReply(text: text, runtimeLabel: "Готовые данные · без модели", normalizedBrief: nil, isFallback: true)
        }
        let fallback = DirectorAIReply(text: DirectorResponseComposer.limitedAdvice(prompt: prompt, moment: context.moment, delayed: true),
            runtimeLabel: "Ограниченный ответ · модель не ответила", normalizedBrief: nil, isFallback: true)
        let reply = await DirectorReplyDeadline.run(seconds: max(0, (detailed ? 30 : 6) - (ProcessInfo.processInfo.systemUptime - submittedAt)), fallback: fallback) {
            do {
                try await self.acquireModelSlot()
                defer { self.modelRequestActive = false }
                try Task.checkCancellation()
                if let provider = self.responseProvider {
                    let answer = try await provider(prompt, context, .advisory, false)
                    return DirectorAIReply(text: answer.text, runtimeLabel: answer.runtimeLabel, normalizedBrief: nil,
                        judgment: answer.judgment, isFallback: answer.isFallback)
                }
                return try await self.generateAdvice(prompt, context: context, detailed: detailed)
            } catch {
                return DirectorAIReply(text: DirectorResponseComposer.limitedAdvice(prompt: prompt, moment: context.moment),
                    runtimeLabel: "Ограниченный ответ · готовые данные", normalizedBrief: nil, isFallback: true)
            }
        }
        guard !Task.isCancelled, generation == conversationGeneration else { return DirectorAIReply(text: "", runtimeLabel: "Отменено", normalizedBrief: nil) }
        if recordInHistory { recordExchange(user: prompt, reply: reply.text) }
        return reply
    }

    private func generateAdvice(_ prompt: String, context: DirectorContext, detailed: Bool) async throws -> DirectorAIReply {
        let requestData = DirectorAdviceRequest(prompt: prompt, context: context, history: compactAdviceHistory, detailed: detailed)
        PerformanceTrace.current?.event("director.loading")
        let available = await hasOllamaModel(startService: true)
        try Task.checkCancellation()
        if available {
            var request = URLRequest(url: Self.ollamaBaseURL.appendingPathComponent("api/chat"))
            request.httpMethod = "POST"
            request.timeoutInterval = detailed ? 30 : 6
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(requestData)
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw URLError(.badServerResponse) }
            var stream = DirectorReplyStream()
            for try await line in bytes.lines where !line.isEmpty {
                try Task.checkCancellation()
                _ = try stream.append(line) // Metadata must be validated before any text is shown.
            }
            try Task.checkCancellation()
            return try validatedAdvice(try stream.completedContent(), context: context, detailed: detailed, runtime: Self.ollamaRuntimeLabel, allowsProposedTitle: DirectorAdviceRequest.requestsTitle(prompt))
        }
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), SystemLanguageModel.default.isAvailable {
            let session = LanguageModelSession(instructions: DirectorAdviceRequest.instructions)
            let response = try await session.respond(to: requestData.messages.last!.content + "\nJSON: {\"stance\":\"keep|trim|compare|reorder|clarify|insufficientEvidence\",\"targetID\":\"\",\"evidenceIDs\":[],\"reply\":\"\"}")
            try Task.checkCancellation()
            return try validatedAdvice(response.content, context: context, detailed: detailed, runtime: "Apple Intelligence · локальная нейросеть", allowsProposedTitle: DirectorAdviceRequest.requestsTitle(prompt))
        }
        #endif
        throw URLError(.cannotConnectToHost)
    }

    private var compactAdviceHistory: String {
        // Whole exchanges only; never truncate negations or user constraints.
        var selected: [OllamaMessage] = []
        var size = 0
        for message in ollamaHistory.reversed() {
            let cost = message.content.utf8.count
            guard size + cost <= 2_400 else { break }
            selected.insert(message, at: 0); size += cost
            if selected.count >= 4 { break }
        }
        return selected.map { "\($0.role): \($0.content)" }.joined(separator: "\n")
    }

    private func validatedAdvice(_ content: String, context: DirectorContext, detailed: Bool, runtime: String, allowsProposedTitle: Bool = false) throws -> DirectorAIReply {
        var judgment = try JSONDecoder().decode(DirectorJudgment.self, from: Data(Self.cleanedJSON(content).utf8))
        guard judgment.targetID == (context.moment?.adviceTarget ?? "") else { throw URLError(.cannotParseResponse) }
        let evidence = context.moment?.adviceEvidence ?? [:]
        judgment.evidenceIDs = try judgment.evidenceIDs.map { alias in
            guard let fact = evidence[alias] else { throw URLError(.cannotParseResponse) }
            return fact.id
        }
        judgment.targetID = context.moment?.targetID ?? ""
        guard judgment.validated(in: context.moment, detailed: detailed, allowsProposedTitle: allowsProposedTitle) else { throw URLError(.cannotParseResponse) }
        return DirectorAIReply(text: judgment.reply, runtimeLabel: runtime, normalizedBrief: nil, judgment: judgment)
    }

    private func respondWithOllama(
        to userMessage: String,
        context: DirectorContext,
        mode: DirectorRequestMode,
        recordInHistory: Bool,
        allowsFootageReplacement: Bool,
        onPartialReply: (@MainActor @Sendable (String) -> Void)?,
        repairingPlan: Bool = false
    ) async throws -> DirectorAIReply {
        let ollamaAvailable = await hasOllamaModel(startService: true)
        try Task.checkCancellation()
        let requestModeInstruction = mode == .advisory
            ? "РЕЖИМ СОВЕТА: предложи музыку, название или объясни звук по данным анализа. Ничего не применяй, пиши в настоящем времени, верни commands: [] и пустой normalizedBrief. Обязательно скажи, что исходник и Timeline не изменены."
            : "РЕЖИМ МОНТАЖА: подготовь исполняемый план только для явно запрошенных изменений."
        let editingSystem = OllamaMessage(role: "system", content: """
            Ты монтажный режиссёр внутри VeloEdit. Отвечай естественно по-русски, ровно 1–2 короткими предложениями. Реагируй только на пожелание пользователя: не пересказывай служебную сводку, не делай арифметических расчётов и не выдумывай стиль или длительность. Точные числа повторяй буквально и считай жёсткими ограничениями. Сейчас ты только принимаешь задачу: пиши в будущем времени и не утверждай, что фильм, звук или музыка уже изменены. Например, говори «отключу звук исходников после применения правок», а не «звук убран». Не притворяйся, что просмотрел кадры, если анализ не завершён.

            \(requestModeInstruction)

            \(allowsFootageReplacement && mode == .edit ? "Пользователь работает Волшебной кистью с выделенным диапазоном. Понимай смысл произвольной формулировки: просьба взять другой материал, неудачный дубль, заменить этот кусок, показать здесь что-то другое означает replace_footage, target selected, пустые value и secondaryTarget. Это реальная замена исходного видео другим моментом той же сцены. Смена музыки, цвета, титра, перестановка и удаление без замены не означают replace_footage. Не подменяй замену настройками звука или эффектами." : "Операция replace_footage недоступна вне Волшебной кисти.")

            Верни только JSON по выданной схеме: reply — ответ пользователю; normalizedBrief — краткий русский бриф для подбора истории; commands — полный исполняемый план. На каждое действие создавай отдельный элемент commands. target всегда один из: all, selected, first, last или number:N. Для неиспользуемых value и secondaryTarget передавай пустую строку. secondaryTarget нужен только наложению и использует тот же формат цели.
            Для переименования существующего титра используй set_title_text: новый текст в value, выбранный титр — target selected. Сохраняй регистр и пунктуацию текста. Не заменяй переименование добавлением нового титра.
            add_library_effect: value — код эффекта из полного каталога: \(TimelineEffectType.allCases.map { "\($0.rawValue)=\($0.localizedTitle)" }.joined(separator: "; ")). Добавляет редактируемый эффект на указанные клипы. Не дублируй то же действие через set_effect.
            «Ещё хочу эффект камеры в первом видео» означает {"action":"add_library_effect","target":"first","value":"video-camera","secondaryTarget":""}. «Эффект камеры», «видеокамера», REC, видоискатель — video-camera; «ручная камера» — handheld; «дрейф камеры» — camera-drift. Это разные эффекты. Для эффекта из библиотеки всегда используй add_library_effect, а не set_effect. Вводные слова «ещё хочу», «можешь», «пожалуйста» не меняют действие. «В первом видео» указывает первый клип монтажа, «во втором» — number:2; не заменяй явный номер выбранным клипом.
            apply_title_template: value — ID шаблона, target указывает титр. Каталог: \(TitleTemplateRegistry.all.map { "\($0.id)=\($0.name)" }.joined(separator: "; ")). Для нового титра сначала add_title, затем apply_title_template; текст сохраняется.
            Полный каталог set_transition: \(TransitionStyle.allCases.map { "\($0.rawValue)=\($0.localizedTitle)" }.joined(separator: "; ")).
            insert_background: target beginning/end; value — JSON строкой {"background":"clouds","title":"Путешествие","duration":4}; title можно опустить. Это отдельный клип из библиотеки и привязанный титр, а не set_overlay. Для неба используй clouds, для звёздного неба stars. Каталог фонов: \(BackgroundPreset.catalogPresets.map { "\($0.rawValue)=\($0.localizedTitle)" }.joined(separator: "; ")).
            insert_source: target beginning/end; value — краткое описание искомой сцены из запроса (например «собака»). Ищет неиспользованный момент во всех проанализированных исходниках. Не заменяй это duplicate, move или пересборкой фильма. Не утверждай, что момент найден, до выполнения поиска.
            set_title_style: value — JSON-объект, закодированный строкой, с нужными полями fontSize (18...220), textColorHex, backgroundColorHex (#RRGGBB) и alignment (left, center, right); отсутствующие поля не меняются. remove_slow_motion убирает только замедление, сохраняя ускоренные участки; value пустой.

            Значения пиши только кодами движка. set_transition: cross-dissolve, fade, fade-through-black, blur-dissolve, light-flash, slide-left, slide-right, push, zoom, wipe-left, wipe-right или none. set_transition_pattern: список этих кодов через запятую. Переход хранится на входящем клипе: «после первого клипа» означает target number:2, «между вторым и третьим» — number:3. set_effect: ken-burns, zoom-in, zoom-out, push-in, pull-out, pan-left, pan-right, mirror или none. set_effect_pattern: список кодов через запятую. set_filter: none, monochrome, noir, sepia, vivid, warm, cool, dramatic. set_crop: fit или fill. set_eq: flat, voice, music, bass-reduction, presence. set_overlay: cutaway, picture-in-picture, split-screen, green-screen или none. set_telemetry: speed, route, altitude, distance, g-force через запятую или none. Числовые value передавай десятичным числом без единиц; true/false — буквально. set_clip_fades: два числа fade-in,fade-out. add_title: текст в value и beginning/end в target. move: beginning/end в value. set_music: energetic, cinematic, calm, joyful, electronic, acoustic, different или none.

            Для set_sharpening, set_video_denoise, set_blur и set_stabilization value — 0...1. set_rolling_shutter, set_smooth_slow_motion и set_audio_ducking принимают true/false. detach_audio не использует value. «Приглуши музыку» означает set_music_volume, а «музыку тише под речь» — set_audio_ducking. «Приглуши звук исходников» означает set_original_audio_volume со значением \(DirectorSourceAudioPolicy.duck.volume): оставить 20% исходной громкости. Не приглушай при этом музыку под камеру. «Убери шум» означает set_noise_reduction; отличай аудиошум от video denoise. «Сделай голос/речь тише» может уменьшить громкость исходной дорожки через set_clip_volume, но не обещай изоляцию голоса из уже смешанной фонограммы. Фразы «только ключевые титры», «минимум титров» и ответы на вопрос о количестве титров задают частоту, а не текст: никогда не превращай слова «ключевой момент» или «важный момент» в add_title. add_title допустим только когда пользователь явно просит добавить надпись; текст должен быть дан пользователем или подтверждаться анализом содержания. Сохраняй все действия, точные числа и цели пользователя. Количество моментов, темп истории, предпочтения по содержанию и общую длительность сохраняй в normalizedBrief, но не выдумывай для них command, если такого action нет. При просьбе «сделай динамичнее» выбирай локальные монтажные решения по контексту: убрать слабое, укоротить затянутое, усилить action и кульминацию; не ускоряй автоматически все клипы. Полная пересборка разрешает Story Engine вернуть ранее неиспользованные фрагменты и изменить структуру, но commands должны содержать только доступные typed actions. VeloEdit сам ищет и скачивает разрешённые non-premium треки через официальный Free To Use API, даже если локальная библиотека сейчас пуста. Никогда не отвечай, что пользователь должен вручную добавить музыку или что локальный трек не найден: для монтажного музыкального запроса подтверди подбор, а приложение сообщит фактический результат загрузки. Музыку нельзя генерировать. Не добавляй действий, которых пользователь не просил, и не называй в reply эффекты, которых нет в commands.
            """)
        let system = mode == .advisory ? OllamaMessage(role: "system", content: """
            Ты монтажный режиссёр внутри VeloEdit. Пользователь просит только совет, никаких изменений проекта.
            Ответь непосредственно на вопрос по-русски, конкретно и кратко. Сначала дай запрошенный результат: если нужно название, предложи готовое название в кавычках «»; если варианты музыки — назови подходящие варианты и объясни выбор. Учитывай описание пользователя и доступный анализ, не выдумывай просмотренные кадры. Не заменяй ответ подтверждением получения задачи или фразой об отсутствии изменений. После содержательного ответа можно кратко подтвердить, что проект не изменён.
            Верни только JSON по выданной схеме: reply — содержательный совет, normalizedBrief — пустая строка, commands — пустой массив. Не обещай выполнить или применить совет.
            """) : editingSystem
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
        let history = Array(ollamaHistory.suffix(8))
        var messages = [system] + history + [contextualUser]
        if repairingPlan {
            messages.append(OllamaMessage(role: "user", content: "Предыдущая попытка не дала корректного полного плана; ничего не применено. Составь план заново для всего исходного запроса. Используй только перечисленные action, коды и цели, включи все поля команды. reply сократи до одной фразы, не повторяй каталог. Не теряй ни одну запрошенную правку."))
        }
        if !ollamaAvailable {
            #if canImport(FoundationModels)
            if #available(macOS 26.0, *), SystemLanguageModel.default.isAvailable {
                let session = LanguageModelSession(instructions: editingSystem.content)
                let response = try await session.respond(to: messages.dropFirst().map(\.content).joined(separator: "\n") + "\nВерни полный JSON: {\"reply\":\"\",\"normalizedBrief\":\"\",\"commands\":[{\"action\":\"код\",\"target\":\"selected\",\"value\":\"\",\"secondaryTarget\":\"\"}]}")
                try Task.checkCancellation()
                return try Self.decodeReply(response.content, userMessage: userMessage, runtimeLabel: "Apple Intelligence · локальная нейросеть", allowsFootageReplacement: allowsFootageReplacement, mode: mode)
            }
            #endif
            // No generation was attempted. The existing deterministic planner
            // can still resolve supported commands and reports omissions.
            return DirectorAIReply(text: "Проверяю доступные монтажные команды.", runtimeLabel: "Базовый алгоритм · это не нейросеть", normalizedBrief: nil, isFallback: true)
        }
        var payload = OllamaChatRequest(model: Self.ollamaModel, messages: messages)
        if repairingPlan { payload.options.numPredict = 2400 }
        var request = URLRequest(url: Self.ollamaBaseURL.appendingPathComponent("api/chat"))
        request.httpMethod = "POST"
        request.timeoutInterval = allowsFootageReplacement ? 20 : 180
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(payload)

        let started = ProcessInfo.processInfo.systemUptime
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        var stream = DirectorReplyStream()
        for try await line in bytes.lines where !line.isEmpty {
            try Task.checkCancellation()
            if try stream.append(line) != nil {
                PerformanceTrace.current?.event("director.reply-field-ready", values: ["seconds": ProcessInfo.processInfo.systemUptime - started])
                // An unvalidated phrase may contain an invented observation or
                // claim completion. Keep it off screen until there is a receipt.
                onPartialReply?("Проверяю полный план правки")
            }
        }
        let content = Self.cleanedJSON(try stream.completedContent())
        PerformanceTrace.current?.event("director.plan-complete", values: ["seconds": ProcessInfo.processInfo.systemUptime - started])
        let decoded = try JSONDecoder().decode(OllamaDirectorPayload.self, from: Data(content.utf8))
        let reply = decoded.reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reply.isEmpty else { throw URLError(.cannotParseResponse) }

        return try Self.decodeReply(content, userMessage: userMessage, runtimeLabel: Self.ollamaRuntimeLabel,
                                    allowsFootageReplacement: allowsFootageReplacement && mode == .edit, mode: mode)
    }

    /// A structured action, never words in the assistant's prose, authorizes
    /// source replacement. The brush supplies the only supported target scope.
    static func decodeReply(_ content: String, userMessage: String, runtimeLabel: String, allowsFootageReplacement: Bool, mode: DirectorRequestMode = .edit) throws -> DirectorAIReply {
        let decoded = try JSONDecoder().decode(OllamaDirectorPayload.self, from: Data(cleanedJSON(content).utf8))
        let reply = decoded.reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reply.isEmpty else { throw URLError(.cannotParseResponse) }
        // Advisory mode cannot carry executable edits, even when the model
        // ignores its empty-plan instruction or echoes actions from history.
        if mode == .advisory {
            return DirectorAIReply(text: reply, runtimeLabel: runtimeLabel, normalizedBrief: nil)
        }
        // Validate every action before returning any executable plan. Dropping a
        // malformed item would silently turn a compound request into a partial edit.
        let commands = try decoded.commands.compactMap { command -> EditorCommand? in
            if command.action.trimmingCharacters(in: .whitespacesAndNewlines) == "replace_footage" { return nil }
            guard let result = Self.editorCommand(command) else { throw URLError(.cannotParseResponse) }
            return result
        }
        return DirectorAIReply(
            text: reply,
            runtimeLabel: runtimeLabel,
            normalizedBrief: decoded.normalizedBrief?.trimmingCharacters(in: .whitespacesAndNewlines),
            commands: Self.sanitizedCommands(commands, for: userMessage),
            replacesSelectedFootage: allowsFootageReplacement && decoded.commands.contains {
                $0.action.trimmingCharacters(in: .whitespacesAndNewlines) == "replace_footage"
                    && $0.target.trimmingCharacters(in: .whitespacesAndNewlines) == "selected"
            }
        )
    }

    private static func sanitizedCommands(_ commands: [EditorCommand], for userMessage: String) -> [EditorCommand] {
        let request = userMessage.lowercased().replacingOccurrences(of: "ё", with: "е")
        let explicitlyRequestsTitle = [
            "добавь титр", "добавить титр", "добавь надпись", "напиши на экране",
            "сделай титр", "покажи текст", "title card", "вставь титр", "вставь надпись",
            "создай титр", "наложи текст", "наложи надпись", "хочу надпись", "нужен титр", "с титром", "с надписью"
        ].contains(where: request.contains)
        var seen = Set<EditorCommand>()
        return commands.compactMap { command in
            if case .addTitle(let text, _) = command {
                guard explicitlyRequestsTitle, !SmartTitleEngine.isMeaningless(text) else { return nil }
            }
            guard seen.insert(command).inserted else { return nil }
            return command
        }
    }

    private static func editorCommand(_ command: OllamaDirectorCommand) -> EditorCommand? {
        let action = command.action.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let value = command.value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let target = editorTarget(command.target)
        let number = numericValue(value)

        switch action {
        case "add_library_effect":
            return target.flatMap { target in TimelineEffectType(rawValue: value).map { .addLibraryEffect($0, target) } }
        case "apply_title_template":
            guard let target, TitleTemplateRegistry.template(id: value) != nil else { return nil }
            return .applyTitleTemplate(value, target)
        case "insert_background":
            struct Background: Decodable { var background: String; var title: String?; var duration: Double? }
            guard let details = try? JSONDecoder().decode(Background.self, from: Data(command.value.utf8)),
                  details.duration.map({ $0.isFinite && (0.25...120).contains($0) }) ?? true else { return nil }
            return .insertBackground(.init(background: details.background, title: details.title,
                duration: details.duration ?? 4, position: command.target == "end" || command.target == "last" ? .end : .beginning))
        case "insert_source":
            guard !value.isEmpty else { return nil }
            return .insertSource(command.value.trimmingCharacters(in: .whitespacesAndNewlines),
                command.target == "beginning" || command.target == "first" ? .beginning : .end)
        case "set_speed": return target.flatMap { target in number.map { .setSpeed($0, target) } }
        case "remove_slow_motion": return target.map(EditorCommand.removeSlowMotion)
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
            let position: TimelineInsertionPosition = ["end", "last"].contains(command.target.lowercased()) ? .end : .beginning
            return .addTitle(title, position)
        case "set_title_text":
            let text = command.value.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : target.map { .setTitleText(text, $0) }
        case "set_title_style":
            struct Style: Decodable {
                var fontSize: Double?
                var textColorHex: String?
                var backgroundColorHex: String?
                var alignment: TitleAlignment?
            }
            guard let target,
                  let style = try? JSONDecoder().decode(Style.self, from: Data(command.value.utf8)),
                  style.fontSize != nil || style.textColorHex != nil || style.backgroundColorHex != nil || style.alignment != nil,
                  style.fontSize.map({ $0.isFinite && (18...220).contains($0) }) ?? true,
                  [style.textColorHex, style.backgroundColorHex].compactMap({ $0 }).allSatisfy({
                      $0.range(of: #"^#?[0-9a-fA-F]{6}$"#, options: .regularExpression) != nil
                  }) else { return nil }
            return .setTitleStyle(style.fontSize, style.textColorHex, style.backgroundColorHex, style.alignment, target)
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

    private func hasOllamaModel(startService: Bool) async -> Bool {
        await LocalAIModelManager.shared.availability(model: Self.ollamaModel, startService: startService).installed
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
