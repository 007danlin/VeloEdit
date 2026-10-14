import Foundation

public struct CinematicPlanStep: Codable, Hashable, Sendable {
    public var techniqueID: String
    public var commandID: String
    public var itemID: UUID
    public var relatedItemID: UUID?
    public var styleID: String?
    public var parameters: [String: Double]

    public init(techniqueID: String, commandID: String, itemID: UUID, relatedItemID: UUID? = nil,
                styleID: String? = nil, parameters: [String: Double] = [:]) {
        self.techniqueID = techniqueID; self.commandID = commandID; self.itemID = itemID
        self.relatedItemID = relatedItemID; self.styleID = styleID; self.parameters = parameters
    }
}

public struct CinematicEditingPlan: Codable, Hashable, Sendable {
    public var projectID: UUID
    public var timelineID: UUID
    public var request: String
    public var scopeItemIDs: Set<UUID>
    public var steps: [CinematicPlanStep]
    public var skippedReasons: [String]

    public init(projectID: UUID, timelineID: UUID, request: String, scopeItemIDs: Set<UUID>,
                steps: [CinematicPlanStep] = [], skippedReasons: [String] = []) {
        self.projectID = projectID; self.timelineID = timelineID; self.request = request
        self.scopeItemIDs = scopeItemIDs; self.steps = steps; self.skippedReasons = skippedReasons
    }
}

public enum CinematicDirector {
    public static func authorizedScope(input: NaturalLanguageDirectorInput) -> Set<UUID> {
        let text = CinematicKnowledgeBase.normalized(input.userRequest)
        if ["между клипами", "между всеми", "во всем фильме", "на всех", "all clips"].contains(where: text.contains) {
            return Set(input.timeline.items.filter { $0.overlay == nil && $0.kind == .video }.map(\.id))
        }
        let resolved = DirectorTargetResolver(input: input).resolve(query: input.userRequest).itemIDs
        if !resolved.isEmpty { return Set(resolved) }
        if let id = input.selectedItemID { return [id] }
        return []
    }
    /// Explicit named requests enter this route before the generic command
    /// parser. Deferred/analysis-only techniques cannot fall through to a lookalike.
    public static func plan(request: String, targetIDs: [UUID], project: ProjectManifest,
                            timeline: Timeline) -> CinematicEditingPlan? {
        guard let base = CinematicKnowledgeBase.bundled else { return nil }
        let matching = base.matching(request)
        let audited = CinematicKnowledgeBase.auditedMatches(request)
        let names = matching.flatMap(\.aliases) + audited.map(\.name)
        let requestText = CinematicKnowledgeBase.normalized(request)
        let isNamedRequest = names.contains { name in
            let phrase = NSRegularExpression.escapedPattern(for: CinematicKnowledgeBase.normalized(name))
            let pattern = "(?:^| )(?:добавь|сделай|примени|используй|создай|хочу|нужен|нужна|apply|add|use|make) (?:эффект |прием |переход |технику )?" + phrase + "(?: |$)"
            return requestText.range(of: pattern, options: .regularExpression) != nil
        }
        guard isNamedRequest else { return nil }
        if matching.isEmpty, let unavailable = audited.first {
            return CinematicEditingPlan(projectID: project.id, timelineID: timeline.id, request: request,
                                        scopeItemIDs: Set(targetIDs), skippedReasons: ["\(unavailable.name): \(unavailable.reason)"])
        }
        guard !matching.isEmpty else { return nil }
        let normalized = CinematicKnowledgeBase.normalized(request)
        if ["убери", "удали", "отключи", "remove", "не применяй"].contains(where: normalized.contains) {
            // Removal remains an existing editor operation, never addition.
            return nil
        }
        var plan = CinematicEditingPlan(projectID: project.id, timelineID: timeline.id,
                                        request: request, scopeItemIDs: Set(targetIDs))
        if normalized.range(of: " и (?:добавь|сделай|примени|убери|измени|музык|звук|титр|цвет|субтитр)", options: .regularExpression) != nil {
            plan.skippedReasons = ["Составной запрос требует полного структурированного плана; отдельный киноприём не заменяет остальные действия."]
            return plan
        }
        guard matching.count == 1, let card = matching.first else {
            plan.skippedReasons = ["Несколько киноприёмов в одном запросе: нужен отдельный точный план, автоматическая подмена запрещена."]
            return plan
        }
        guard card.status == .applicable else {
            plan.skippedReasons = ["\(card.name): \(card.reason) \(card.negativeExample)"]
            return plan
        }
        let primaries = timeline.items.filter { $0.overlay == nil && $0.kind == .video }.sorted { $0.timelineStart < $1.timelineStart }
        let targets = primaries.filter { targetIDs.contains($0.id) }
        guard !targets.isEmpty else { plan.skippedReasons = ["Целевые видео не определены."]; return plan }
        // Exact numeric requests continue through the typed plan, never a
        // guessed default. Reject unsupported numbers instead of ignoring them.
        let numbers = request.replacingOccurrences(of: ",", with: ".").components(separatedBy: CharacterSet(charactersIn: "0123456789.").inverted)
            .compactMap(Double.init)
        if !numbers.isEmpty {
            plan.skippedReasons = ["Для именованного киноприёма нужен план с явными параметрами; числовые ограничения нельзя заменять значением по умолчанию."]
            return plan
        }
        for item in targets {
            var requestedStyle = card.transitionIDs.first
            if card.id == "editing/wipe" {
                if normalized.contains("вправо") { requestedStyle = "wipe-right" }
                if normalized.contains("вверх") { requestedStyle = "wipe-up" }
                if normalized.contains("вниз") { requestedStyle = "wipe-down" }
            }
            if let styleID = requestedStyle, let style = TransitionStyle(rawValue: styleID) {
                guard let index = primaries.firstIndex(where: { $0.id == item.id }), index > 0 else {
                    // A request across a sequence naturally starts at its
                    // second clip; there is no incoming boundary on the first.
                    if targets.count == 1 { plan.skippedReasons.append("Перед клипом нет основного видеоклипа.") }
                    continue
                }
                let previous = primaries[index - 1]
                plan.steps.append(.init(techniqueID: card.id, commandID: "addTransition", itemID: item.id,
                                        relatedItemID: previous.id, styleID: styleID,
                                        parameters: ["duration": TransitionPresetRegistry.preset(for: style).defaultDuration]))
            } else if let effect = card.effectIDs.first {
                plan.steps.append(.init(techniqueID: card.id, commandID: "addEffect", itemID: item.id,
                                        styleID: effect, parameters: ["startTime": item.timelineStart, "duration": item.timelineDuration]))
            } else if card.allowedCommands.contains("setSpeed") {
                plan.steps.append(.init(techniqueID: card.id, commandID: "setSpeed", itemID: item.id,
                                        parameters: ["rate": card.id.hasSuffix("/slow-motion") ? 0.5 : 2]))
            } else if card.allowedCommands.contains("freezeFrame") {
                plan.steps.append(.init(techniqueID: card.id, commandID: "freezeFrame", itemID: item.id, parameters: ["duration": 2]))
            }
        }
        return plan
    }

    /// Validate the entire structured plan against current facts, then execute
    /// on a value copy. Any failure discards every mutation and every receipt.
    public static func execute(_ plan: CinematicEditingPlan, project: ProjectManifest,
                               timeline: Timeline, authorizedScope: Set<UUID>) -> (timeline: Timeline, report: DirectorToolExecutionReport) {
        func failure(_ reasons: [String]) -> (Timeline, DirectorToolExecutionReport) {
            (timeline, DirectorToolExecutionReport(rejected: reasons))
        }
        guard let base = CinematicKnowledgeBase.bundled else { return failure(["Локальная база недоступна."]) }
        guard plan.projectID == project.id, plan.timelineID == timeline.id,
              plan.scopeItemIDs.isSubset(of: authorizedScope), plan.steps.count <= 32 else {
            return failure(["План устарел, относится к другому проекту или выходит за область правки."])
        }
        guard plan.skippedReasons.isEmpty else { return failure(plan.skippedReasons) }
        let primaries = timeline.items.filter { $0.overlay == nil && $0.kind != .title }.sorted { $0.timelineStart < $1.timelineStart }
        let assets = Dictionary(project.assets.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let requestedTechniques = Set(base.matching(plan.request).map(\.id))
        var calls: [DirectorToolCall] = []
        var touched = Set<String>()
        let noEffects = project.storyPlans.last.map { DirectorEffectsPolicyEngine.policy(for: $0) == DirectorEffectsPolicy.none } == true
            || CinematicKnowledgeBase.normalized(plan.request).contains("без эффект")
            || project.workspaceState?.directorBrief?.effectsPolicy == DirectorEffectsPolicy.none
        let fixedDuration = project.storyPlans.last?.directorBrief?.explicitRequestedDuration != nil
            || project.workspaceState?.directorBrief?.explicitRequestedDuration != nil
        for step in plan.steps {
            guard let card = base.technique(id: step.techniqueID), card.status == .applicable,
                  requestedTechniques.contains(card.id),
                  card.allowedCommands.contains(step.commandID), CinematicCapabilityCatalog.commandIDs.contains(step.commandID),
                  plan.scopeItemIDs.contains(step.itemID), authorizedScope.contains(step.itemID),
                  let item = primaries.first(where: { $0.id == step.itemID }), item.kind == .video, !item.locked,
                  let assetID = item.assetID, let asset = assets[assetID],
                  item.sourceStart.isFinite, item.sourceDuration.isFinite, item.sourceStart >= 0, item.sourceDuration > 0,
                  item.timelineStart.isFinite, item.timelineDuration.isFinite, item.timelineDuration > 0,
                  let assetDuration = asset.metadata.duration, assetDuration.isFinite,
                  timeline.frameRate.isFinite, timeline.frameRate > 0,
                  item.sourceStart + item.sourceDuration <= assetDuration + 0.001,
                  step.parameters.values.allSatisfy(\.isFinite),
                  step.commandID == "addTransition" || step.relatedItemID == nil,
                  touched.insert("\(step.itemID):\(step.commandID)").inserted else {
                return failure(["Неизвестный или недоступный ID, неверная цель/диапазон, блокировка либо повтор команды."])
            }
            let reason = "\(card.name): явный запрос; \(asset.displayName), исходник \(item.sourceStart)…\(item.sourceStart + item.sourceDuration); база \(base.edition)"
            let analysis = project.analyses.first { $0.assetID == assetID && $0.analyzedContentHash == asset.contentHash
                && $0.schemaVersion == project.analysisSchemaVersion && $0.deepMediaVersion == DeepAnalysisCache.version }
            let candidates = analysis?.directorCandidates.filter {
                $0.sourceStart < item.sourceStart + item.sourceDuration && $0.sourceStart + $0.sourceDuration > item.sourceStart
            } ?? []
            let speech = candidates.compactMap { $0.insights?.speech }.filter { $0.confidence >= card.minimumConfidence }
            func validParameters(_ names: Set<String>) -> Bool { Set(step.parameters.keys) == names }
            func timingSafe() -> Bool {
                // Unknown sound is not silence. A muted clip needs no speech
                // time manipulation in the film; source media remains intact.
                !asset.metadata.hasAudio || item.effectiveAudioAdjustments.muted
            }
            if ["trim", "setSpeed", "freezeFrame"].contains(step.commandID) {
                guard timingSafe(), speech.isEmpty, item.speedRamp == nil, !item.isReversed, !item.isFreezeFrame,
                      !fixedDuration else {
                    return failure(["Изменение времени не подтверждено: звук/речь, сложная шкала времени или фиксированная длительность."])
                }
            }
            if noEffects && ["addEffect", "addTransition", "freezeFrame"].contains(step.commandID) {
                return failure(["Выбрано «Без эффектов»."])
            }
            switch step.commandID {
            case "setSpeed":
                guard validParameters(["rate"]), step.styleID == nil, let rate = step.parameters["rate"], (0.1...8).contains(rate),
                      (card.id == "time-and-motion/slow-motion" && rate < 1) || (card.id == "time-and-motion/fast-motion" && rate > 1),
                      rate >= 1 || (asset.metadata.frameRate ?? 0) * rate + 0.001 >= timeline.frameRate else {
                    return failure(["Недопустимая скорость или недостаточная исходная частота кадров для плавного замедления."])
                }
                calls.append(.setSpeed(itemID: item.id, rate: rate, reason: reason))
            case "freezeFrame":
                guard validParameters(["duration"]), step.styleID == nil, let duration = step.parameters["duration"], (0.25...30).contains(duration) else {
                    return failure(["Недопустимая длительность стоп-кадра."])
                }
                calls.append(.freezeFrame(itemID: item.id, duration: duration, reason: reason))
            case "trim":
                guard validParameters(["sourceStart", "sourceDuration"]), let start = step.parameters["sourceStart"],
                      let duration = step.parameters["sourceDuration"], start >= item.sourceStart, duration >= 0.05,
                      start + duration <= item.sourceStart + item.sourceDuration else { return failure(["Обрезка выходит за подтверждённый диапазон."]) }
                // No current applicable card authorizes trim without its own
                // temporal evidence predicate. Keep this dormant contract closed.
                return failure(["Для обрезки нет подтверждённых фаз действия и границ речи."])
            case "setTransition":
                guard step.styleID == "cut", validParameters([]) else { return failure(["Разрешена только прямая склейка."]) }
                calls.append(.setTransition(itemID: item.id, transition: nil, reason: reason))
            case "addTransition":
                guard !fixedDuration else { return failure(["Переход изменил бы фиксированную длительность фильма."]) }
                guard validParameters(["duration"]), let styleID = step.styleID, card.transitionIDs.contains(styleID),
                      let style = TransitionStyle(rawValue: styleID), let duration = step.parameters["duration"],
                      TransitionPresetRegistry.preset(for: style).durationRange.contains(duration),
                      let index = primaries.firstIndex(where: { $0.id == item.id }), index > 0,
                      primaries[index - 1].id == step.relatedItemID, !primaries[index - 1].locked,
                      duration <= min(primaries[index - 1].timelineDuration, item.timelineDuration) / 2 else {
                    return failure(["Неизвестный переход, несоседняя пара, блокировка или длительность вне допустимого диапазона."])
                }
                let outgoing = primaries[index - 1]
                // An optical overlap can also mix/attenuate source speech.
                // Missing ASR is not evidence that both boundary ranges are
                // silent. This edition requires explicitly muted source audio
                // or media with no audio track on both sides.
                guard timingSafe(), let outgoingAssetID = outgoing.assetID, let outgoingAsset = assets[outgoingAssetID],
                      !outgoingAsset.metadata.hasAudio || outgoing.effectiveAudioAdjustments.muted else {
                    return failure(["Переход перекрывает исходный звук; без надёжного анализа речи нужны явно отключённые дорожки обоих клипов."])
                }
                if card.id == "editing/wipe" {
                    let request = CinematicKnowledgeBase.normalized(plan.request)
                    let directions = [("влево", "wipe-left"), ("вправо", "wipe-right"), ("вверх", "wipe-up"), ("вниз", "wipe-down")]
                    guard directions.allSatisfy({ !request.contains($0.0) || styleID == $0.1 }) else {
                        return failure(["Направление перехода противоречит запросу."])
                    }
                }
                // Changing this boundary touches the preceding clip as well.
                guard authorizedScope.contains(outgoing.id), plan.scopeItemIDs.contains(outgoing.id) else {
                    return failure(["Переход затрагивает соседний клип вне области правки."])
                }
                let boundarySpeech = speech.contains { $0.phraseStart < item.sourceStart + duration }
                    || project.analyses.filter { $0.assetID == outgoing.assetID && $0.analyzedContentHash == outgoing.assetID.flatMap { assets[$0]?.contentHash } }
                        .flatMap(\.directorCandidates).compactMap { $0.insights?.speech }.contains {
                            $0.confidence >= card.minimumConfidence && $0.phraseEnd > outgoing.sourceStart + outgoing.sourceDuration - duration
                            && $0.phraseStart < outgoing.sourceStart + outgoing.sourceDuration
                        }
                guard !boundarySpeech else { return failure(["На границе есть подтверждённая речь; наплыв/маска могут нарушить её читаемость."]) }
                calls.append(.addTransitionObject(outgoingClipID: outgoing.id, incomingClipID: item.id, style: style, duration: duration, reason: reason))
            case "addEffect":
                guard validParameters(["startTime", "duration"]), let styleID = step.styleID, card.effectIDs.contains(styleID),
                      let type = TimelineEffectType(rawValue: styleID), let start = step.parameters["startTime"], let duration = step.parameters["duration"],
                      start >= item.timelineStart, duration >= 0.05, start + duration <= item.timelineStart + item.timelineDuration + 0.001 else {
                    return failure(["Неизвестный эффект, лишние параметры или выход за временные границы цели."])
                }
                calls.append(.addEffect(type: type, startTime: start, duration: duration, targetClipID: item.id, reason: reason))
            default: return failure(["Команда не разрешена локальной базой."])
            }
        }
        let result = DirectorEditingTools().apply(calls, to: timeline, assets: project.assets, analyses: project.analyses, plan: project.storyPlans.last)
        guard result.report.rejected.isEmpty, result.report.applied.count == calls.count else {
            return failure(result.report.rejected + ["План целиком отменён; ни одна правка не сохранена."])
        }
        guard timeline.items.filter(\.locked).allSatisfy({ original in
            result.timeline.items.first(where: { $0.id == original.id }) == original
                && abs(TimelineTiming.playbackTime(forTimelineTime: original.timelineStart, timeline: result.timeline)
                       - TimelineTiming.playbackTime(forTimelineTime: original.timelineStart, timeline: timeline)) < 0.001
        }) else { return failure(["Правка сдвинула бы заблокированный клип; план целиком отменён."]) }
        return result
    }
}
