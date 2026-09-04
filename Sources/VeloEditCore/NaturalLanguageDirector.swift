import Foundation

public enum NaturalLanguageDirectorError: LocalizedError {
    case timelineUnavailable

    public var errorDescription: String? {
        switch self {
        case .timelineUnavailable: return "Для естественной монтажной команды сначала нужен Timeline"
        }
    }
}

// MARK: - P8 intent and dependency model

public enum NaturalLanguageEditScope: String, Codable, CaseIterable, Hashable, Sendable {
    case global, section, event, shot, overlay, audio
}

public enum NaturalLanguageExecutionTier: String, Codable, CaseIterable, Hashable, Sendable {
    case instant, fast, deep
}

public enum NaturalLanguageOperationKind: String, Codable, CaseIterable, Hashable, Sendable {
    case format, reframe, extendMoment, removeMoment, restoreMoment, reorder
    case pacing, style, music, title, subtitles, translation, telemetry, audio, effect, transition, animation
    case genericEdit, autonomousEdit
}

public struct DirectorCanvasFormat: Codable, Hashable, Identifiable, CaseIterable, Sendable {
    public var width: Int
    public var height: Int
    public var label: String
    public var subjectAware: Bool
    public var safeAreasEnabled: Bool

    public init(width: Int, height: Int, label: String, subjectAware: Bool = true, safeAreasEnabled: Bool = true) {
        self.width = max(64, width - width % 2)
        self.height = max(64, height - height % 2)
        self.label = label
        self.subjectAware = subjectAware
        self.safeAreasEnabled = safeAreasEnabled
    }

    public var aspectRatio: Double { Double(width) / Double(max(1, height)) }

    /// Questionnaire choices and natural-language format commands share this
    /// exact value type, so framing, safe areas and delivery cannot disagree
    /// about the requested canvas.
    public static let landscape16x9 = DirectorCanvasFormat(
        width: 1_920,
        height: 1_080,
        label: "16:9"
    )
    public static let portrait9x16 = DirectorCanvasFormat(
        width: 1_080,
        height: 1_920,
        label: "9:16"
    )

    public static let allCases: [DirectorCanvasFormat] = [
        .landscape16x9,
        .portrait9x16
    ]

    public var id: String { "\(width)x\(height):\(label)" }

    public var localizedTitle: String {
        switch (width, height) {
        case (1_920, 1_080): return "Горизонтальное 16:9"
        case (1_080, 1_920): return "Вертикальное 9:16"
        default: return "\(label) · \(width)×\(height)"
        }
    }
}

public enum DirectorSubtitleLanguage: String, Codable, CaseIterable, Hashable, Sendable {
    case russian = "ru"
    case english = "en"
}

public enum DirectorSubtitleStyle: String, Codable, CaseIterable, Hashable, Sendable {
    case cinematic, vlog, travel, social
}

public struct DirectorSubtitleDirective: Codable, Hashable, Sendable {
    public var language: DirectorSubtitleLanguage
    public var style: DirectorSubtitleStyle
    public var speechOnly: Bool
    public var wordHighlighting: Bool

    public init(
        language: DirectorSubtitleLanguage,
        style: DirectorSubtitleStyle,
        speechOnly: Bool = true,
        wordHighlighting: Bool = true
    ) {
        self.language = language
        self.style = style
        self.speechOnly = speechOnly
        self.wordHighlighting = wordHighlighting
    }
}

public struct EditIntentTarget: Hashable, Sendable {
    public var query: String?
    public var itemIDs: [UUID]
    public var candidateIDs: [UUID]
    public var eventIDs: [UUID]
    public var confidence: Double
    public var evidence: [String]

    public init(
        query: String? = nil,
        itemIDs: [UUID] = [],
        candidateIDs: [UUID] = [],
        eventIDs: [UUID] = [],
        confidence: Double = 0,
        evidence: [String] = []
    ) {
        self.query = query
        self.itemIDs = itemIDs
        self.candidateIDs = candidateIDs
        self.eventIDs = eventIDs
        self.confidence = confidence.clamped01
        self.evidence = evidence
    }
}

/// The stable P8 contract produced before any Timeline mutation.
public struct EditIntent: Hashable, Sendable {
    public var scope: NaturalLanguageEditScope
    public var target: EditIntentTarget
    public var operation: NaturalLanguageOperationKind
    public var constraints: [String]
    public var desiredResult: String
    public var confidence: Double
    public var executionTier: NaturalLanguageExecutionTier

    public init(
        scope: NaturalLanguageEditScope,
        target: EditIntentTarget = EditIntentTarget(),
        operation: NaturalLanguageOperationKind,
        constraints: [String] = [],
        desiredResult: String,
        confidence: Double,
        executionTier: NaturalLanguageExecutionTier
    ) {
        self.scope = scope
        self.target = target
        self.operation = operation
        self.constraints = constraints
        self.desiredResult = desiredResult
        self.confidence = confidence.clamped01
        self.executionTier = executionTier
    }
}

public enum EditDependencyNode: String, Codable, CaseIterable, Hashable, Sendable {
    case canvas, videoLayer, audioLayer, titleLayout, telemetryLayout
    case neighboringCuts, transitions, musicSync, soundtrack, storyPlan
    case globalScoring, perceptualReview, preview
}

public struct EditDependencyPlan: Codable, Hashable, Sendable {
    public var nodes: Set<EditDependencyNode>
    public var predictedPreviewLayers: Set<PreviewLayerKind>
    public var reusesMediaAnalysis: Bool
    public var requiresGlobalScoring: Bool
    public var requiresBackgroundRefinement: Bool

    public init(
        nodes: Set<EditDependencyNode>,
        predictedPreviewLayers: Set<PreviewLayerKind>,
        reusesMediaAnalysis: Bool,
        requiresGlobalScoring: Bool,
        requiresBackgroundRefinement: Bool
    ) {
        self.nodes = nodes
        self.predictedPreviewLayers = predictedPreviewLayers
        self.reusesMediaAnalysis = reusesMediaAnalysis
        self.requiresGlobalScoring = requiresGlobalScoring
        self.requiresBackgroundRefinement = requiresBackgroundRefinement
    }
}

public struct EditDependencyGraph: Sendable {
    public init() {}

    public func plan(for intents: [EditIntent]) -> EditDependencyPlan {
        var nodes: Set<EditDependencyNode> = [.preview]
        var layers = Set<PreviewLayerKind>()
        var global = false
        for intent in intents {
            switch intent.operation {
            case .format, .reframe:
                nodes.formUnion([.canvas, .videoLayer, .titleLayout, .telemetryLayout])
                layers.formUnion([.sourceVideo, .effects, .titles, .telemetry])
            case .extendMoment, .removeMoment, .restoreMoment, .reorder, .pacing:
                nodes.formUnion([.videoLayer, .audioLayer, .neighboringCuts, .transitions, .musicSync])
                layers.formUnion([.timelineStructure, .sourceVideo, .sourceAudio, .transitions, .soundtrack])
            case .title, .subtitles, .translation:
                nodes.insert(.titleLayout)
                layers.insert(.titles)
            case .music:
                nodes.formUnion([.soundtrack, .musicSync])
                layers.insert(.soundtrack)
            case .audio:
                nodes.insert(.audioLayer)
                layers.insert(.sourceAudio)
            case .telemetry:
                nodes.insert(.telemetryLayout)
                layers.insert(.telemetry)
            case .effect, .animation:
                nodes.insert(.videoLayer)
                layers.formUnion([.effects, .sourceVideo])
            case .transition:
                nodes.formUnion([.neighboringCuts, .transitions])
                layers.insert(.transitions)
            case .style, .autonomousEdit:
                nodes.formUnion([.storyPlan, .globalScoring, .perceptualReview])
                layers.formUnion([.timelineStructure, .sourceVideo, .sourceAudio, .transitions, .soundtrack])
                global = true
            case .genericEdit:
                layers.formUnion([.effects, .sourceAudio, .transitions, .titles])
            }
            if intent.scope == .global && [.style, .pacing, .autonomousEdit].contains(intent.operation) {
                global = true
            }
        }
        if layers.isEmpty { layers.insert(.timelineStructure) }
        return EditDependencyPlan(
            nodes: nodes,
            predictedPreviewLayers: layers,
            reusesMediaAnalysis: true,
            requiresGlobalScoring: global,
            requiresBackgroundRefinement: global
        )
    }
}

public struct DirectorEventGraph: Hashable, Sendable {
    public var events: [Event]

    public init(events: [Event]) { self.events = events }

    public func eventIDs(candidateID: UUID, assetID: UUID?) -> [UUID] {
        events.compactMap { event in
            let containsCandidate = event.effectiveScenes.contains { $0.candidateIDs.contains(candidateID) }
            let containsAsset = assetID.map(event.assetIDs.contains) ?? false
            return containsCandidate || containsAsset ? event.id : nil
        }
    }
}

public struct NaturalLanguageDirectorInput: Sendable {
    public var userRequest: String
    public var currentProject: ProjectManifest
    public var timeline: Timeline
    public var assets: [MediaAsset]
    public var tasteProfile: PersonalTasteProfile
    public var styleProfile: ProjectStyleProfile
    public var eventGraph: DirectorEventGraph
    public var selectedItemID: UUID?
    public var playheadTime: Double?

    public init(
        userRequest: String,
        currentProject: ProjectManifest,
        timeline: Timeline,
        assets: [MediaAsset]? = nil,
        tasteProfile: PersonalTasteProfile? = nil,
        styleProfile: ProjectStyleProfile? = nil,
        eventGraph: DirectorEventGraph? = nil,
        selectedItemID: UUID? = nil,
        playheadTime: Double? = nil
    ) {
        self.userRequest = userRequest
        self.currentProject = currentProject
        self.timeline = timeline
        self.assets = assets ?? currentProject.assets
        self.tasteProfile = tasteProfile ?? currentProject.personalTasteProfile ?? PersonalTasteProfile()
        self.styleProfile = styleProfile ?? AutonomousProjectStyleEngine().infer(
            assets: currentProject.assets,
            analyses: currentProject.analyses,
            fallbackPreset: currentProject.storyPlans.last?.preset ?? .story,
            events: currentProject.events
        )
        self.eventGraph = eventGraph ?? DirectorEventGraph(events: currentProject.events)
        self.selectedItemID = selectedItemID
        self.playheadTime = playheadTime
    }
}

public struct NaturalLanguageEditingPlan: Hashable, Sendable {
    public var request: String
    public var intents: [EditIntent]
    public var toolCalls: [DirectorToolCall]
    public var commands: [EditorCommand]
    public var dependencyPlan: EditDependencyPlan
    public var executionTier: NaturalLanguageExecutionTier
    public var rejectedReasons: [String]
    public var confidence: Double

    public init(
        request: String,
        intents: [EditIntent],
        toolCalls: [DirectorToolCall],
        commands: [EditorCommand],
        dependencyPlan: EditDependencyPlan,
        executionTier: NaturalLanguageExecutionTier,
        rejectedReasons: [String] = [],
        confidence: Double
    ) {
        self.request = request
        self.intents = intents
        self.toolCalls = toolCalls
        self.commands = commands
        self.dependencyPlan = dependencyPlan
        self.executionTier = executionTier
        self.rejectedReasons = rejectedReasons
        self.confidence = confidence.clamped01
    }

    public var requiresBackgroundRefinement: Bool { dependencyPlan.requiresBackgroundRefinement }
}

public struct NaturalLanguageCommandRecord: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var request: String
    public var summary: String
    public var operationKinds: [NaturalLanguageOperationKind]
    public var affectedItemIDs: [UUID]
    public var confidence: Double
    public var rejectedReasons: [String]
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        request: String,
        summary: String,
        operationKinds: [NaturalLanguageOperationKind],
        affectedItemIDs: [UUID],
        confidence: Double,
        rejectedReasons: [String] = [],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.request = request
        self.summary = summary
        self.operationKinds = operationKinds
        self.affectedItemIDs = affectedItemIDs
        self.confidence = confidence.clamped01
        self.rejectedReasons = rejectedReasons
        self.createdAt = createdAt
    }
}

public struct NaturalLanguageEditResult: Sendable {
    public var timeline: Timeline
    public var plan: NaturalLanguageEditingPlan
    public var commandReport: EditorCommandReport
    public var toolReport: DirectorToolExecutionReport
    public var invalidation: TimelineInvalidationPlan
    public var safetyViolations: [String]
    public var committed: Bool
    public var userSummary: String

    public init(
        timeline: Timeline,
        plan: NaturalLanguageEditingPlan,
        commandReport: EditorCommandReport,
        toolReport: DirectorToolExecutionReport,
        invalidation: TimelineInvalidationPlan,
        safetyViolations: [String],
        committed: Bool,
        userSummary: String
    ) {
        self.timeline = timeline
        self.plan = plan
        self.commandReport = commandReport
        self.toolReport = toolReport
        self.invalidation = invalidation
        self.safetyViolations = safetyViolations
        self.committed = committed
        self.userSummary = userSummary
    }
}

// MARK: - Natural-language planning

public struct NaturalLanguageDirector: Sendable {
    private let translator: any SubtitleTranslationProviding

    public init(translator: any SubtitleTranslationProviding = OfflineBilingualSubtitleTranslator()) {
        self.translator = translator
    }

    public func plan(
        input: NaturalLanguageDirectorInput,
        supplementalCommands: [EditorCommand] = []
    ) -> NaturalLanguageEditingPlan {
        let text = NLText.normalized(input.userRequest)
        let resolver = DirectorTargetResolver(input: input)
        let generalTarget = resolver.resolve(query: input.userRequest)
        var intents: [EditIntent] = []
        var calls: [DirectorToolCall] = []
        var rejected: [String] = []

        let deterministicCommands = EditorCommandParser().parse(
            input.userRequest,
            preset: input.currentProject.storyPlans.last?.preset ?? .story
        )
        var commands = mergedCommands(
            deterministic: deterministicCommands,
            supplemental: supplementalCommands
        )
        let storyPreset = input.currentProject.storyPlans.last?.preset ?? .story
        let baseStoryConstraints = input.currentProject.storyPlans.last?.constraints
            ?? PromptInterpreter.defaults(for: storyPreset)
        var interpretedStoryConstraints = PromptInterpreter().interpret(
            prompt: input.userRequest,
            preset: storyPreset,
            base: baseStoryConstraints
        )
        if deterministicCommands.contains(where: { $0.semanticCategory == "duration" }) {
            // An explicit “selected/first/all clips are N seconds” command is
            // a local editor operation, not a request to resize the film.
            interpretedStoryConstraints.targetDuration = baseStoryConstraints.targetDuration
        }
        if deterministicCommands.contains(where: { $0.semanticCategory == "speed" }),
           !isVaguePacing(text) {
            interpretedStoryConstraints.pacing = baseStoryConstraints.pacing
        }
        if deterministicCommands.contains(where: { $0.semanticCategory == "transition" }) {
            interpretedStoryConstraints.transitionFrequency = baseStoryConstraints.transitionFrequency
        }
        let requiresStoryConstraintRebuild = interpretedStoryConstraints != baseStoryConstraints

        if isVaguePacing(text) {
            // “Сделай быстрее” means denser editing, not 2× playback of every
            // source clip. Explicit rates still remain ordinary commands.
            commands.removeAll { $0.semanticCategory == "speed" }
        }

        if let format = Self.canvasFormat(from: input.userRequest) {
            intents.append(EditIntent(
                scope: .global,
                operation: .format,
                constraints: ["subject-aware reframe", "safe areas", "reuse media analysis"],
                desiredResult: "Формат \(format.label) \(format.width)×\(format.height)",
                confidence: 0.98,
                executionTier: .instant
            ))
            calls.append(.setCanvas(
                width: format.width,
                height: format.height,
                subjectAware: format.subjectAware,
                reason: "P8: формат \(format.label), subject-aware reframe и safe areas"
            ))
        }

        let asksExtension = NLText.containsAny(text, [
            "сделай подольше", "продли момент", "продли лод", "оставь больше момента",
            "момент подольше", "подольше лод", "extend the moment", "make it longer"
        ])
        if asksExtension {
            if let itemID = generalTarget.itemIDs.first,
               let edit = PhaseAwareNaturalLanguageTrimmer().extensionCalls(
                    itemID: itemID,
                    request: text,
                    timeline: input.timeline,
                    assets: input.assets,
                    analyses: input.currentProject.analyses
               ) {
                calls.append(contentsOf: edit.calls)
                intents.append(EditIntent(
                    scope: .event,
                    target: generalTarget,
                    operation: .extendMoment,
                    constraints: edit.constraints,
                    desiredResult: edit.summary,
                    confidence: min(generalTarget.confidence, edit.confidence),
                    executionTier: .instant
                ))
            } else {
                rejected.append("Не найден монтажный момент, который можно безопасно продлить")
            }
        }

        let asksRemoval = NLText.containsAny(text, [
            "убери этот момент", "удали этот момент", "убери скуч", "удали сцен", "remove this moment"
        ])
        if asksRemoval {
            let targets = Array(generalTarget.itemIDs.prefix(4))
            let primaryCount = input.timeline.items.filter { $0.kind != .title && $0.overlay == nil }.count
            if targets.isEmpty {
                rejected.append("Сцена для удаления не найдена")
            } else if targets.count >= max(1, primaryCount / 2) {
                rejected.append("Автоматическое удаление отклонено: неоднозначная цель затрагивает слишком большую часть фильма")
            } else {
                calls.append(contentsOf: targets.map {
                    .rippleDelete(itemID: $0, reason: "P8: удалён найденный по смыслу момент")
                })
                intents.append(EditIntent(
                    scope: .event,
                    target: generalTarget,
                    operation: .removeMoment,
                    constraints: ["one command = one Undo", "preserve remaining story"],
                    desiredResult: "Удалить только найденный момент",
                    confidence: generalTarget.confidence,
                    executionTier: .instant
                ))
            }
        }

        let asksRestoration = NLText.containsAny(text, [
            "верни тот кадр", "верни кадр", "верни момент", "восстанови момент", "restore the shot"
        ])
        if asksRestoration {
            let used = Set(input.timeline.items.compactMap(\.candidateID))
            if let candidateID = generalTarget.candidateIDs.first(where: { !used.contains($0) }),
               let candidate = input.currentProject.analyses.flatMap(\.directorCandidates).first(where: { $0.id == candidateID }) {
                let range = Self.completeRange(for: candidate)
                let role = candidate.insights?.roleScores.max(by: { $0.value < $1.value })?.key ?? .bRoll
                let anchor = input.timeline.items.last(where: { $0.overlay == nil && $0.kind != .title })?.id
                calls.append(.insert(
                    candidateID: candidate.id,
                    sourceStart: range.lowerBound,
                    sourceDuration: range.upperBound - range.lowerBound,
                    afterItemID: anchor,
                    role: role,
                    reason: "P8: возвращён найденный по смыслу кадр"
                ))
                intents.append(EditIntent(
                    scope: .event,
                    target: generalTarget,
                    operation: .restoreMoment,
                    constraints: ["complete moment", "source bounds"],
                    desiredResult: "Вернуть ранее неиспользованный подходящий кадр",
                    confidence: generalTarget.confidence,
                    executionTier: .fast
                ))
            } else {
                rejected.append("Подходящий неиспользованный кадр не найден")
            }
        }

        if let swap = swapQueries(in: text) {
            let first = resolver.resolve(query: swap.0)
            let second = resolver.resolve(query: swap.1)
            if let firstID = first.itemIDs.first, let secondID = second.itemIDs.first, firstID != secondID {
                calls.append(.swap(itemID: firstID, withItemID: secondID, reason: "P8: сцены поменяны местами"))
                intents.append(EditIntent(
                    scope: .section,
                    target: EditIntentTarget(
                        query: "\(swap.0) ↔ \(swap.1)",
                        itemIDs: [firstID, secondID],
                        candidateIDs: first.candidateIDs + second.candidateIDs,
                        eventIDs: first.eventIDs + second.eventIDs,
                        confidence: min(first.confidence, second.confidence),
                        evidence: first.evidence + second.evidence
                    ),
                    operation: .reorder,
                    constraints: ["preserve clips", "recalculate neighboring cuts"],
                    desiredResult: "Поменять две сцены местами",
                    confidence: min(first.confidence, second.confidence),
                    executionTier: .instant
                ))
            } else {
                rejected.append("Для перестановки не удалось однозначно найти обе сцены")
            }
        } else if let relation = relationQueries(in: text) {
            let moved = resolver.resolve(query: relation.target)
            let anchor = resolver.resolve(query: relation.anchor)
            if let movedID = moved.itemIDs.first, let anchorID = anchor.itemIDs.first,
               let anchorIndex = input.timeline.items.firstIndex(where: { $0.id == anchorID }) {
                let beforeID: UUID?
                if relation.after {
                    beforeID = input.timeline.items[(anchorIndex + 1)...].first(where: { $0.overlay == nil && $0.kind != .title })?.id
                } else {
                    beforeID = anchorID
                }
                calls.append(.reorder(itemID: movedID, beforeItemID: beforeID, reason: "P8: локальная перестановка сцены"))
                intents.append(EditIntent(
                    scope: .section,
                    target: moved,
                    operation: .reorder,
                    constraints: ["local reorder", "preserve material"],
                    desiredResult: relation.after ? "Поставить сцену после указанного события" : "Поставить сцену перед указанным событием",
                    confidence: min(moved.confidence, anchor.confidence),
                    executionTier: .instant
                ))
            }
        }

        if isVaguePacing(text) {
            let faster = NLText.containsAny(text, ["быстрее", "плотнее", "динамичнее", "энергичнее", "dense action"])
            let factor = faster ? 0.82 : 1.16
            let trimCalls = PhaseAwareNaturalLanguageTrimmer().pacingCalls(
                factor: factor,
                timeline: input.timeline,
                assets: input.assets,
                analyses: input.currentProject.analyses
            )
            calls.append(contentsOf: trimCalls)
            intents.append(EditIntent(
                scope: .global,
                operation: .pacing,
                constraints: ["trim around MomentBoundary.peakTime", "keep anticipation and reaction handles"],
                desiredResult: faster ? "Уплотнить монтаж без ускорения исходников" : "Дать кадрам больше воздуха",
                confidence: trimCalls.isEmpty ? 0.45 : 0.88,
                executionTier: .fast
            ))
        }

        if let subtitleDirective = Self.subtitleDirective(from: text, input: input) {
            let subtitles = SubtitleTimelineBuilder(translator: translator).build(directive: subtitleDirective, input: input)
            if subtitles.isEmpty {
                rejected.append("В готовом анализе нет распознанной речи для субтитров")
            } else {
                calls.append(.replaceSubtitles(items: subtitles, reason: "P8: редактируемые локальные субтитры"))
                intents.append(EditIntent(
                    scope: .overlay,
                    operation: subtitleDirective.language == .russian ? .subtitles : .translation,
                    constraints: ["speech only", "word timestamps", "face avoidance", "safe area", "editable"],
                    desiredResult: "\(subtitleDirective.language == .russian ? "Русские" : "Английские") субтитры · \(subtitleDirective.style.rawValue)",
                    confidence: 0.92,
                    executionTier: .fast
                ))
            }
        }

        if NLText.containsAny(text, ["оставь оригинальный звук", "оригинальный звук воды", "слышно воду", "верни живой звук"]),
           let itemID = generalTarget.itemIDs.first,
           let item = input.timeline.items.first(where: { $0.id == itemID }) {
            var audio = item.effectiveAudioAdjustments
            audio.muted = false
            audio.volume = max(1, audio.volume)
            calls.append(.setAudioAdjustments(itemID: itemID, adjustments: audio, reason: "P8: сохранён оригинальный синхронный звук события"))
            intents.append(EditIntent(
                scope: .audio,
                target: generalTarget,
                operation: .audio,
                constraints: ["event-local audio"],
                desiredResult: "Сохранить оригинальный звук найденного момента",
                confidence: generalTarget.confidence,
                executionTier: .instant
            ))
        }

        if NLText.containsAny(text, ["дроп совпад", "дроп совпадет", "дроп совпадёт", "drop match", "drop совпад"]),
           let bpm = input.timeline.music?.bpm {
            calls.append(.syncToBeat(bpm: bpm, reason: "P8: музыкальный акцент синхронизирован с монтажной кульминацией"))
            intents.append(EditIntent(
                scope: .audio,
                target: generalTarget,
                operation: .music,
                constraints: ["drop–climax alignment", "preserve moment peak"],
                desiredResult: "Совместить drop с кульминацией",
                confidence: 0.82,
                executionTier: .deep
            ))
        }

        // Effects and transitions are translated to the same typed Timeline
        // objects the Inspector edits. AI animation always emits real
        // keyframes; it never bakes a separate visual shortcut.
        let effectTargetID = input.selectedItemID.flatMap { id in input.timeline.items.contains(where: { $0.id == id }) ? id : nil }
            ?? generalTarget.itemIDs.first
        let effectTargetItem = effectTargetID.flatMap { id in input.timeline.items.first(where: { $0.id == id }) }
        let effectStart = effectTargetItem?.timelineStart ?? min(max(0, input.playheadTime ?? 0), max(0, input.timeline.duration - 0.05))
        let effectDuration = max(0.05, min(effectTargetItem?.timelineDuration ?? 3, max(0.05, input.timeline.duration - effectStart)))

        let asksEffectRemoval = NLText.containsAny(text, ["убери эффект", "удали эффект", "remove effect"])
        if asksEffectRemoval {
            let candidates = input.timeline.effectiveEffects.filter { effect in
                if let effectTargetID { return effect.targetClipID == effectTargetID }
                let time = input.playheadTime ?? 0
                return time >= effect.startTime && time <= effect.endTime
            }
            if let effect = candidates.last {
                calls.append(.removeEffect(effectID: effect.id, reason: "P8: удалён выбранный эффект"))
                intents.append(EditIntent(scope: .shot, target: generalTarget, operation: .effect, desiredResult: "Убрать эффект", confidence: 0.94, executionTier: .instant))
            } else {
                rejected.append("Эффект для удаления не найден")
            }
        }

        let requestedEffect: TimelineEffectType? = {
            if NLText.containsAny(text, ["плёночное зерно", "пленочное зерно", "film grain"]) { return .filmGrain }
            if NLText.containsAny(text, ["motion blur", "размытие движения", "размытие в движении"]) { return .motionBlur }
            if NLText.containsAny(text, ["лёгкую тряску", "легкую тряску", "light shake", "лёгкое дрожание", "легкое дрожание"]) { return .shake }
            return nil
        }()
        if let requestedEffect, !asksEffectRemoval {
            calls.append(.addEffect(
                type: requestedEffect,
                startTime: effectStart,
                duration: effectDuration,
                targetClipID: effectTargetID,
                reason: "P8: пользователь явно запросил \(requestedEffect.localizedTitle)"
            ))
            intents.append(EditIntent(scope: .shot, target: generalTarget, operation: .effect, constraints: ["AI effect budget", "editable Timeline object"], desiredResult: "Добавить \(requestedEffect.localizedTitle)", confidence: 0.96, executionTier: .instant))
        }

        let requestedPresetID: String? = {
            if NLText.containsAny(text, ["cinematic travel preset", "кинематографичный travel preset", "travel preset", "пресет travel"]) { return "travel" }
            if NLText.containsAny(text, ["cinematic preset", "кинематографичный пресет", "пресет cinematic"]) { return "cinematic" }
            if NLText.containsAny(text, ["action preset", "пресет action"]) { return "action" }
            if NLText.containsAny(text, ["vintage preset", "пресет vintage"]) { return "vintage" }
            if NLText.containsAny(text, ["social preset", "пресет social"]) { return "social" }
            return nil
        }()
        if let presetID = requestedPresetID {
            calls.append(.applyEffectPreset(presetID: presetID, startTime: effectStart, duration: effectDuration, targetClipID: effectTargetID, reason: "P8: применён data-driven preset \(presetID)"))
            intents.append(EditIntent(scope: .shot, target: generalTarget, operation: .effect, constraints: ["ordinary effects", "one Undo"], desiredResult: "Применить пресет \(presetID)", confidence: 0.96, executionTier: .instant))
        }

        if NLText.containsAny(text, ["плавный зум", "smooth zoom", "зум на человек", "zoom on person"]) {
            let endScale = NLText.containsAny(text, ["сильн", "closer", "крупнее"]) ? 1.18 : 1.08
            calls.append(.addAnimatedEffect(
                type: .zoom,
                startTime: effectStart,
                duration: effectDuration,
                targetClipID: effectTargetID,
                keyframes: [
                    EffectKeyframe(parameter: "scaleX", time: 0, value: 1, easing: .easeInOut),
                    EffectKeyframe(parameter: "scaleX", time: effectDuration, value: endScale, easing: .easeInOut),
                    EffectKeyframe(parameter: "scaleY", time: 0, value: 1, easing: .easeInOut),
                    EffectKeyframe(parameter: "scaleY", time: effectDuration, value: endScale, easing: .easeInOut)
                ],
                reason: "P8: плавный zoom создан настоящими keyframes"
            ))
            intents.append(EditIntent(scope: .shot, target: generalTarget, operation: .animation, constraints: ["real keyframes", "ease-in-out", "subject-aware target"], desiredResult: "Плавно приблизить человека", confidence: effectTargetID == nil ? 0.62 : 0.94, executionTier: .instant))
        }

        let asksTransitionRemoval = NLText.containsAny(text, ["убери переход", "удали переход", "без перехода", "remove transition"])
        let asksShorterTransition = NLText.containsAny(text, ["переход короче", "сделай переход короче", "shorter transition"])
        let asksSofterTransition = NLText.containsAny(text, ["переход мягче", "сделай переход мягче", "softer transition"])
        let referenceTime = effectTargetItem?.timelineStart ?? input.playheadTime ?? 0
        let nearestTransition = input.timeline.effectiveTransitionItems.min {
            abs($0.startTime - referenceTime) < abs($1.startTime - referenceTime)
        }
        if asksTransitionRemoval, let nearestTransition {
            calls.append(.removeTransitionObject(transitionID: nearestTransition.id, reason: "P8: возвращена чистая склейка"))
            intents.append(EditIntent(scope: .section, target: generalTarget, operation: .transition, desiredResult: "Убрать переход", confidence: 0.96, executionTier: .instant))
        } else if (asksShorterTransition || asksSofterTransition), let nearestTransition {
            calls.append(.editTransitionObject(
                transitionID: nearestTransition.id,
                duration: asksShorterTransition ? max(0.08, nearestTransition.duration * 0.72) : nil,
                intensity: asksSofterTransition ? nearestTransition.effectiveIntensity * 0.68 : nil,
                direction: nil,
                easing: asksSofterTransition ? .easeInOut : nil,
                reason: "P8: существующий переход скорректирован без замены"
            ))
            intents.append(EditIntent(scope: .section, target: generalTarget, operation: .transition, desiredResult: asksShorterTransition ? "Сделать переход короче" : "Сделать переход мягче", confidence: 0.94, executionTier: .instant))
        } else if NLText.containsAny(text, ["добавь переход", "add transition"]) {
            let primary = input.timeline.items.filter { $0.overlay == nil && $0.kind != .title }.sorted { $0.timelineStart < $1.timelineStart }
            let incomingIndex = primary.indices.dropFirst().min { abs(primary[$0].timelineStart - referenceTime) < abs(primary[$1].timelineStart - referenceTime) }
            if let incomingIndex {
                let style: TransitionStyle = NLText.containsAny(text, ["свет", "flash"]) ? .lightFlash : .crossDissolve
                let preset = TransitionPresetRegistry.preset(for: style)
                calls.append(.addTransitionObject(outgoingClipID: primary[incomingIndex - 1].id, incomingClipID: primary[incomingIndex].id, style: style, duration: preset.defaultDuration, reason: "P8: переход выбран по монтажному контексту"))
                intents.append(EditIntent(scope: .section, target: generalTarget, operation: .transition, constraints: ["motivated", "AI transition budget"], desiredResult: "Добавить уместный переход", confidence: 0.88, executionTier: .instant))
            } else {
                rejected.append("Для перехода нужны два соседних основных клипа")
            }
        }

        let commandCategories = Set(commands.map(\.semanticCategory))
        if commandCategories.contains(where: { $0 == "add-title" || $0 == "title-style" || $0 == "remove-titles" }) {
            intents.append(EditIntent(scope: .overlay, operation: .title, desiredResult: "Изменить титры", confidence: 0.94, executionTier: .instant))
        }
        if commandCategories.contains(where: { $0 == "music" || $0 == "music-volume" }) {
            intents.append(EditIntent(scope: .audio, operation: .music, desiredResult: "Изменить музыку", confidence: 0.94, executionTier: .fast))
        }
        if commandCategories.contains("telemetry") {
            intents.append(EditIntent(scope: .overlay, target: generalTarget, operation: .telemetry, desiredResult: "Изменить телеметрию", confidence: 0.90, executionTier: .instant))
        }
        if !commands.isEmpty {
            intents.append(EditIntent(scope: .shot, target: generalTarget, operation: .genericEdit, desiredResult: "Применить типизированные editing tools", confidence: 0.93, executionTier: .instant))
        }

        if Self.requiresAutonomousEdit(text) || requiresStoryConstraintRebuild {
            let tasteConfidence = min(1, Double(input.tasteProfile.totalSignalCount) / 20)
            intents.append(EditIntent(
                scope: .global,
                operation: .autonomousEdit,
                constraints: requiresStoryConstraintRebuild
                    ? ["exact story constraints", "reuse media analysis", "PersonalTaste", "ProjectStyle", "EventGraph"]
                    : ["PersonalTaste", "ProjectStyle", "EventGraph", "P6 perceptual review"],
                desiredResult: requiresStoryConstraintRebuild
                    ? "Пересобрать историю по точным ограничениям пользователя"
                    : "Самостоятельно выбрать лучший монтаж по материалу и вкусу",
                confidence: max(0.62, input.styleProfile.confidence * 0.65 + tasteConfidence * 0.35),
                executionTier: .deep
            ))
        } else if Self.requiresStyleRebuild(text) {
            intents.append(EditIntent(
                scope: .global,
                operation: .style,
                constraints: ["reuse analysis", "P3/P4/P6/P7"],
                desiredResult: "Локально или глобально обновить монтажную грамматику",
                confidence: 0.86,
                executionTier: .deep
            ))
        }

        if intents.isEmpty {
            intents.append(EditIntent(
                scope: .global,
                target: generalTarget,
                operation: .autonomousEdit,
                constraints: ["do not ask for low-risk choices", "reuse PersonalTaste"],
                desiredResult: "Интерпретировать запрос как автономную режиссёрскую правку",
                confidence: 0.58,
                executionTier: .deep
            ))
        }

        let dependencies = EditDependencyGraph().plan(for: intents)
        let tier: NaturalLanguageExecutionTier = intents.contains(where: { $0.executionTier == .deep })
            ? .deep
            : intents.contains(where: { $0.executionTier == .fast }) ? .fast : .instant
        let confidence = intents.reduce(0) { $0 + $1.confidence } / Double(max(1, intents.count))
        return NaturalLanguageEditingPlan(
            request: input.userRequest,
            intents: intents,
            toolCalls: calls,
            commands: commands,
            dependencyPlan: dependencies,
            executionTier: tier,
            rejectedReasons: rejected,
            confidence: confidence
        )
    }

    public func execute(
        plan: NaturalLanguageEditingPlan,
        input: NaturalLanguageDirectorInput,
        recordHistory: Bool = true
    ) -> NaturalLanguageEditResult {
        let tools = DirectorEditingTools().apply(
            plan.toolCalls,
            to: input.timeline,
            assets: input.assets,
            analyses: input.currentProject.analyses,
            plan: input.currentProject.storyPlans.last
        )
        let selectedCandidateID = input.selectedItemID.flatMap { id in
            input.timeline.items.first(where: { $0.id == id })?.candidateID
        }
        let edited = EditorCommandExecutor().apply(
            plan.commands,
            to: tools.timeline,
            selectedItemID: input.selectedItemID ?? plan.intents.flatMap(\.target.itemIDs).first,
            selectedCandidateID: selectedCandidateID
        )
        var candidate = Self.clampedToSources(edited.timeline, assets: input.assets)
        let safety = NaturalLanguageTimelineSafetyValidator().violations(candidate: candidate, comparedTo: input.timeline, plan: plan, assets: input.assets)
        let changed = candidate != input.timeline
        let committed = safety.isEmpty && changed
        if !committed { candidate = input.timeline }

        let toolRejected = tools.report.rejected
        let allRejected = plan.rejectedReasons + toolRejected + edited.report.ignored + safety
        let appliedCount = tools.report.applied.count + edited.report.applied.count
        let summary: String
        if committed {
            let desired = plan.intents.map(\.desiredResult).uniqued().prefix(3).joined(separator: "; ")
            summary = "Готово: \(desired). Изменений: \(appliedCount)."
        } else if !allRejected.isEmpty {
            summary = "Правка не применена: \(allRejected.prefix(2).joined(separator: "; "))."
        } else {
            summary = "Запрос уже соответствует текущему монтажу."
        }

        if committed, recordHistory {
            var history = candidate.naturalLanguageHistory ?? []
            history.append(NaturalLanguageCommandRecord(
                request: plan.request,
                summary: summary,
                operationKinds: plan.intents.map(\.operation).uniqued(),
                affectedItemIDs: Array(Set(
                    edited.report.affectedItemIDs + plan.intents.flatMap(\.target.itemIDs)
                )),
                confidence: plan.confidence,
                rejectedReasons: allRejected
            ))
            if history.count > 100 { history.removeFirst(history.count - 100) }
            candidate.naturalLanguageHistory = history
        }

        let invalidation = TimelineInvalidationPlanner.plan(from: input.timeline, to: candidate)
        return NaturalLanguageEditResult(
            timeline: candidate,
            plan: plan,
            commandReport: edited.report,
            toolReport: tools.report,
            invalidation: invalidation,
            safetyViolations: safety,
            committed: committed,
            userSummary: summary
        )
    }

    public static func canvasFormat(from request: String) -> DirectorCanvasFormat? {
        let text = NLText.normalized(request)
        if NLText.containsAny(text, ["tiktok", "тикток", "9:16", "9х16", "вертикаль", "для телефона"]) {
            return DirectorCanvasFormat(width: 1_080, height: 1_920, label: "9:16")
        }
        if NLText.containsAny(text, ["21:9", "21х9", "ультраширок", "широкоформатное кино", "widescreen cinema"]) {
            return DirectorCanvasFormat(width: 2_560, height: 1_080, label: "21:9")
        }
        if NLText.containsAny(text, ["16:9", "16х9", "для телевизора", "для тв", "телевизор", "горизонталь", "горизонтальный", "горизонтальное", "landscape"]) {
            return DirectorCanvasFormat(width: 1_920, height: 1_080, label: "16:9")
        }
        if NLText.containsAny(text, ["4:3", "4х3", "старое видео", "old video"]) {
            return DirectorCanvasFormat(width: 1_440, height: 1_080, label: "4:3")
        }
        if NLText.containsAny(text, ["3:4", "3х4"]) {
            return DirectorCanvasFormat(width: 1_080, height: 1_440, label: "3:4")
        }
        if NLText.containsAny(text, ["1:1", "1х1", "квадрат", "square"]) {
            return DirectorCanvasFormat(width: 1_080, height: 1_080, label: "1:1")
        }
        if let resolution = NLText.firstMatch(in: text, pattern: #"(?:формат|разрешение|canvas)?\s*(\d{3,4})\s*[xх×]\s*(\d{3,4})"#),
           resolution.count == 2, let width = Int(resolution[0]), let height = Int(resolution[1]), width > 0, height > 0 {
            return DirectorCanvasFormat(width: width, height: height, label: "custom")
        }
        if let ratio = NLText.firstMatch(in: text, pattern: #"(?:формат|aspect|соотношение)\s*(\d+(?:[\.,]\d+)?)\s*[:/]\s*(\d+(?:[\.,]\d+)?)"#),
           ratio.count == 2,
           let lhs = Double(ratio[0].replacingOccurrences(of: ",", with: ".")),
           let rhs = Double(ratio[1].replacingOccurrences(of: ",", with: ".")), lhs > 0, rhs > 0 {
            let value = lhs / rhs
            let width: Int
            let height: Int
            if value >= 1 {
                height = 1_080
                width = Int((Double(height) * value / 2).rounded()) * 2
            } else {
                width = 1_080
                height = Int((Double(width) / value / 2).rounded()) * 2
            }
            return DirectorCanvasFormat(width: width, height: height, label: "\(ratio[0]):\(ratio[1])")
        }
        return nil
    }

    private static func subtitleDirective(from text: String, input: NaturalLanguageDirectorInput) -> DirectorSubtitleDirective? {
        guard NLText.containsAny(text, ["субтитр", "caption", "captions"]) else { return nil }
        let language: DirectorSubtitleLanguage = NLText.containsAny(text, ["английск", "english"]) ? .english : .russian
        let style: DirectorSubtitleStyle
        if NLText.containsAny(text, ["минимал", "кинематограф", "cinematic"]) { style = .cinematic }
        else if NLText.containsAny(text, ["влог", "vlog", "крупн", "поживее"]) { style = .vlog }
        else if NLText.containsAny(text, ["соцсет", "social", "анимир", "динамич"]) { style = .social }
        else if input.styleProfile.vector.cinematic > 0.68 { style = .cinematic }
        else if input.styleProfile.vector.energy > 0.68 { style = .social }
        else { style = .travel }
        return DirectorSubtitleDirective(
            language: language,
            style: style,
            speechOnly: !NLText.containsAny(text, ["везде", "весь текст"]),
            wordHighlighting: style == .social || style == .vlog
        )
    }

    private static func completeRange(for candidate: Candidate) -> ClosedRange<Double> {
        guard let boundary = candidate.momentBoundary else {
            return candidate.sourceStart...(candidate.sourceStart + candidate.sourceDuration)
        }
        let candidateEnd = candidate.sourceStart + candidate.sourceDuration
        let start = max(candidate.sourceStart, boundary.anticipationStart)
        let end = min(candidateEnd, max(boundary.completionEnd, boundary.effectiveReactionEnd))
        return start...max(start + 0.05, end)
    }

    private static func clampedToSources(_ source: Timeline, assets: [MediaAsset]) -> Timeline {
        var timeline = source
        let durations = Dictionary(uniqueKeysWithValues: assets.compactMap { asset in
            asset.metadata.duration.map { (asset.id, $0) }
        })
        let frame = 1 / max(1, timeline.frameRate)
        for index in timeline.items.indices {
            guard let assetID = timeline.items[index].assetID, let duration = durations[assetID] else { continue }
            let preservedTimelineDuration = timeline.items[index].timelineDuration
            timeline.items[index].sourceStart = min(max(0, timeline.items[index].sourceStart), max(0, duration - 0.05))
            timeline.items[index].sourceDuration = min(
                timeline.items[index].sourceDuration,
                max(0.05, duration - timeline.items[index].sourceStart)
            )
            if timeline.items[index].isFreezeFrame {
                // A freeze intentionally holds one source frame for an
                // arbitrary output duration. Recomputing its Timeline length
                // from sourceDuration collapses a multi-second hold to a frame.
                timeline.items[index].sourceDuration = min(
                    max(frame, timeline.items[index].sourceDuration),
                    max(frame, duration - timeline.items[index].sourceStart)
                )
                timeline.items[index].timelineDuration = max(frame, preservedTimelineDuration)
            } else {
                let outputFactor = timeline.items[index].speedRamp?.outputDuration(sourceDuration: 1) ?? (1 / timeline.items[index].speed)
                timeline.items[index].timelineDuration = max(0.05, timeline.items[index].sourceDuration * outputFactor)
            }
        }
        timeline.items = TimelineTiming.retimed(timeline.items)
        return timeline
    }

    private func mergedCommands(deterministic: [EditorCommand], supplemental: [EditorCommand]) -> [EditorCommand] {
        guard !supplemental.isEmpty else { return deterministic }
        let categories = Set(deterministic.map(\.semanticCategory))
        return deterministic + supplemental.filter { !categories.contains($0.semanticCategory) }
    }

    private func isVaguePacing(_ text: String) -> Bool {
        let vague = NLText.containsAny(text, [
            "сделай быстрее", "чуть быстрее", "плотнее экшен", "экшен плотнее", "кадры подышат",
            "пусть кадры подышат", "не так быстро", "монтаж динамичнее", "сделай динамичнее"
        ])
        let explicitRate = text.range(of: #"\d+(?:[\.,]\d+)?\s*[xх]"#, options: .regularExpression) != nil || text.contains("скорость")
        return vague && !explicitRate
    }

    private static func requiresAutonomousEdit(_ text: String) -> Bool {
        NLText.containsAny(text, [
            "сделай красиво", "сделай как считаешь лучше", "сам выбери длину", "не спрашивай меня",
            "просто сделай красиво", "do your best", "make it beautiful"
        ])
    }

    private static func requiresStyleRebuild(_ text: String) -> Bool {
        NLText.containsAny(text, [
            "кинематографич", "отпускной фильм", "сделай атмосфер", "больше экшена", "меньше экшена",
            "энергичнее", "стиль путешеств", "vacation film"
        ])
    }

    private func swapQueries(in text: String) -> (String, String)? {
        guard let range = text.range(of: "поменяй местами") ?? text.range(of: "swap") else { return nil }
        let tail = String(text[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = tail.components(separatedBy: " и ").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return parts.count >= 2 ? (parts[0], parts[1]) : nil
    }

    private func relationQueries(in text: String) -> (target: String, anchor: String, after: Bool)? {
        guard NLText.containsAny(text, ["поставь", "перемести", "move"]) else { return nil }
        for marker in [" после ", " перед "] {
            guard let range = text.range(of: marker) else { continue }
            var target = String(text[..<range.lowerBound])
            for verb in ["поставь", "перемести", "move"] { target = target.replacingOccurrences(of: verb, with: "") }
            let anchor = String(text[range.upperBound...])
            return (
                target.trimmingCharacters(in: .whitespacesAndNewlines),
                anchor.trimmingCharacters(in: .whitespacesAndNewlines),
                marker.contains("после")
            )
        }
        return nil
    }
}

// MARK: - Contextual event/candidate resolver

public struct DirectorTargetResolver: Sendable {
    private let input: NaturalLanguageDirectorInput
    private let candidates: [UUID: Candidate]
    private let assets: [UUID: MediaAsset]

    public init(input: NaturalLanguageDirectorInput) {
        self.input = input
        self.candidates = Dictionary(uniqueKeysWithValues: input.currentProject.analyses.flatMap(\.directorCandidates).map { ($0.id, $0) })
        self.assets = Dictionary(uniqueKeysWithValues: input.assets.map { ($0.id, $0) })
    }

    public func resolve(query: String) -> EditIntentTarget {
        let text = NLText.normalized(query)
        if let ordinal = NLText.ordinal(in: text) {
            let primary = input.timeline.items.filter { $0.kind != .title && $0.overlay == nil }
            if primary.indices.contains(ordinal - 1) {
                let item = primary[ordinal - 1]
                return target(for: item, query: query, confidence: 0.98, evidence: ["ordinal timeline reference"])
            }
        }
        if NLText.containsAny(text, ["тот момент", "этот момент", "этот кадр", "эта сцена", "selected"]),
           let contextual = contextualItem() {
            return target(for: contextual, query: query, confidence: 0.96, evidence: ["selected/playhead timeline context"])
        }

        let queryTokens = NLText.semanticTokens(text)
        if queryTokens.isEmpty, let contextual = contextualItem() {
            return target(for: contextual, query: query, confidence: 0.72, evidence: ["implicit timeline context"])
        }

        struct Match {
            var item: TimelineItem?
            var candidate: Candidate
            var eventIDs: [UUID]
            var score: Double
            var evidence: [String]
        }
        var matches: [Match] = []
        let timelineByCandidate = Dictionary(grouping: input.timeline.items.compactMap { item -> (UUID, TimelineItem)? in
            item.candidateID.map { ($0, item) }
        }, by: \.0).mapValues { $0.map(\.1) }

        for candidate in candidates.values where !candidate.excluded {
            let asset = assets[candidate.assetID]
            let eventIDs = input.eventGraph.eventIDs(candidateID: candidate.id, assetID: candidate.assetID)
            var evidenceTokens = Set(candidate.tags.flatMap { NLText.semanticTokens($0) })
            if let summary = candidate.insights?.sceneSummary { evidenceTokens.formUnion(NLText.semanticTokens(summary)) }
            if let emotion = candidate.insights?.emotion { evidenceTokens.formUnion(NLText.semanticTokens(emotion)) }
            if let asset {
                evidenceTokens.formUnion(NLText.semanticTokens(asset.displayName))
                evidenceTokens.formUnion(NLText.semanticTokens(asset.originalURL.deletingPathExtension().lastPathComponent))
            }
            var explanations: [String] = []
            for eventID in eventIDs {
                guard let event = input.eventGraph.events.first(where: { $0.id == eventID }) else { continue }
                evidenceTokens.formUnion(NLText.semanticTokens(event.title))
                evidenceTokens.formUnion(event.tags.flatMap { NLText.semanticTokens($0) })
                for scene in event.effectiveScenes where scene.candidateIDs.contains(candidate.id) || scene.assetIDs.contains(candidate.assetID) {
                    evidenceTokens.formUnion(NLText.semanticTokens(scene.title))
                    evidenceTokens.formUnion(scene.tags.flatMap { NLText.semanticTokens($0) })
                }
            }
            let intersection = queryTokens.intersection(evidenceTokens)
            let coverage = queryTokens.isEmpty ? 0 : Double(intersection.count) / Double(queryTokens.count)
            let union = queryTokens.union(evidenceTokens)
            let jaccard = union.isEmpty ? 0 : Double(intersection.count) / Double(union.count)
            var score = coverage * 0.70 + jaccard * 0.15
            if !intersection.isEmpty { explanations.append("semantic tokens: \(intersection.sorted().joined(separator: ", "))") }
            if !eventIDs.isEmpty, coverage > 0 { score += 0.08; explanations.append("EventGraph context") }
            if let selected = input.selectedItemID,
               timelineByCandidate[candidate.id]?.contains(where: { $0.id == selected }) == true {
                score += 0.12
            }
            if let playhead = input.playheadTime,
               let item = timelineByCandidate[candidate.id]?.first(where: { playhead >= $0.timelineStart && playhead <= $0.timelineStart + $0.timelineDuration }) {
                score += 0.10
                if let selectedCandidate = contextualItem()?.candidateID.flatMap({ candidates[$0] }),
                   let lhs = selectedCandidate.insights?.visualEmbedding,
                   let rhs = candidate.insights?.visualEmbedding {
                    score += lhs.cosineSimilarity(to: rhs) * 0.05
                    explanations.append("embedding + timeline adjacency")
                }
                _ = item
            }
            let quality = SemanticSceneIndex.bestTakeScore(candidate)
            score += quality * 0.07
            if score > 0.08 {
                matches.append(Match(
                    item: timelineByCandidate[candidate.id]?.first,
                    candidate: candidate,
                    eventIDs: eventIDs,
                    score: score.clamped01,
                    evidence: explanations
                ))
            }
        }

        let ordered = matches.sorted {
            $0.score == $1.score ? SemanticSceneIndex.bestTakeScore($0.candidate) > SemanticSceneIndex.bestTakeScore($1.candidate) : $0.score > $1.score
        }
        guard let best = ordered.first else {
            return EditIntentTarget(query: query, confidence: 0, evidence: ["no semantic match"])
        }
        let close = ordered.filter { $0.score >= max(0.18, best.score - 0.09) }
        let itemIDs = close.compactMap(\.item?.id).uniqued()
        return EditIntentTarget(
            query: query,
            itemIDs: itemIDs,
            candidateIDs: close.map(\.candidate.id).uniqued(),
            eventIDs: close.flatMap(\.eventIDs).uniqued(),
            confidence: best.score,
            evidence: best.evidence
        )
    }

    private func contextualItem() -> TimelineItem? {
        if let selected = input.selectedItemID, let item = input.timeline.items.first(where: { $0.id == selected }) { return item }
        if let playhead = input.playheadTime {
            return input.timeline.items.first { playhead >= $0.timelineStart && playhead <= $0.timelineStart + $0.timelineDuration }
        }
        return nil
    }

    private func target(for item: TimelineItem, query: String, confidence: Double, evidence: [String]) -> EditIntentTarget {
        let eventIDs = item.candidateID.map { input.eventGraph.eventIDs(candidateID: $0, assetID: item.assetID) } ?? item.eventID.map { [$0] } ?? []
        return EditIntentTarget(
            query: query,
            itemIDs: [item.id],
            candidateIDs: item.candidateID.map { [$0] } ?? [],
            eventIDs: eventIDs,
            confidence: confidence,
            evidence: evidence
        )
    }
}

// MARK: - Phase-aware trim and duration compensation

private struct PhaseAwareEdit {
    var calls: [DirectorToolCall]
    var constraints: [String]
    var summary: String
    var confidence: Double
}

private struct PhaseAwareNaturalLanguageTrimmer: Sendable {
    func extensionCalls(
        itemID: UUID,
        request: String,
        timeline: Timeline,
        assets: [MediaAsset],
        analyses: [AnalysisResult]
    ) -> PhaseAwareEdit? {
        guard let targetIndex = timeline.items.firstIndex(where: { $0.id == itemID }),
              !timeline.items[targetIndex].locked,
              let candidateID = timeline.items[targetIndex].candidateID,
              let candidate = analyses.flatMap(\.directorCandidates).first(where: { $0.id == candidateID }) else { return nil }
        let target = timeline.items[targetIndex]
        let assetsByID = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) })
        let assetEnd = target.assetID.flatMap { assetsByID[$0]?.metadata.duration } ?? (candidate.sourceStart + candidate.sourceDuration)
        let boundary = candidate.momentBoundary
        let requestedExtra = NLText.firstNumber(in: request, pattern: #"(?:на|еще|ещё)\s*(\d+(?:[\.,]\d+)?)\s*(?:сек|с\b)"#)
        let currentEnd = target.sourceStart + target.sourceDuration
        let fullStart = max(0, min(target.sourceStart, boundary?.anticipationStart ?? target.sourceStart))
        let fullEnd = min(assetEnd, max(currentEnd, boundary.map { max($0.completionEnd, $0.effectiveReactionEnd) } ?? currentEnd))
        var desiredDuration = max(target.sourceDuration, fullEnd - fullStart)
        if let requestedExtra { desiredDuration = max(desiredDuration, target.sourceDuration + requestedExtra) }
        else if desiredDuration <= target.sourceDuration + 0.02 { desiredDuration = min(assetEnd, target.sourceDuration * 1.35) }

        let preserveDuration = !NLText.containsAny(request, ["не сохраняй длительность", "пусть фильм станет длиннее", "можно длиннее фильм"])
        let requestedDelta = max(0, desiredDuration - target.sourceDuration)
        let neighborOrder = timeline.items.indices
            .filter { $0 != targetIndex && timeline.items[$0].kind != .title && timeline.items[$0].overlay == nil && !timeline.items[$0].locked }
            .sorted { abs($0 - targetIndex) < abs($1 - targetIndex) }
        let candidateByID = Dictionary(uniqueKeysWithValues: analyses.flatMap(\.directorCandidates).map { ($0.id, $0) })
        let capacities = neighborOrder.map { index -> (Int, Double) in
            let item = timeline.items[index]
            let minimum = minimumCompleteDuration(item: item, candidate: item.candidateID.flatMap { candidateByID[$0] })
            return (index, max(0, item.timelineDuration - minimum))
        }
        let capacity = capacities.reduce(0) { $0 + $1.1 }
        let actualDelta = preserveDuration ? min(requestedDelta, capacity) : requestedDelta
        desiredDuration = target.sourceDuration + actualDelta
        let desiredRange = range(
            item: target,
            candidate: candidate,
            duration: desiredDuration,
            assetEnd: assetEnd,
            expanding: true
        )
        var calls: [DirectorToolCall] = [
            .trim(
                itemID: target.id,
                sourceStart: desiredRange.lowerBound,
                sourceDuration: desiredRange.upperBound - desiredRange.lowerBound,
                reason: "P8: anticipation → peak → completion/reaction сохранены при продлении"
            )
        ]
        var remaining = actualDelta
        if preserveDuration {
            for (index, available) in capacities where remaining > 0.001 && available > 0.001 {
                let item = timeline.items[index]
                let reduction = min(remaining, available)
                let newDuration = max(0.25, item.timelineDuration - reduction)
                let sourceDuration = newDuration / max(0.01, item.speedRamp?.outputDuration(sourceDuration: 1) ?? (1 / item.speed))
                let assetEnd = item.assetID.flatMap { assetsByID[$0]?.metadata.duration } ?? (item.sourceStart + item.sourceDuration)
                let candidate = item.candidateID.flatMap { candidateByID[$0] }
                let compensatedRange = range(item: item, candidate: candidate, duration: sourceDuration, assetEnd: assetEnd, expanding: false)
                calls.append(.trim(
                    itemID: item.id,
                    sourceStart: compensatedRange.lowerBound,
                    sourceDuration: compensatedRange.upperBound - compensatedRange.lowerBound,
                    reason: "P8: соседний cut компенсирует длительность без потери peak/reaction"
                ))
                remaining -= reduction
            }
        }
        return PhaseAwareEdit(
            calls: calls,
            constraints: [
                "peakTime protected", "anticipation handle ≥ 0.25 s", "reaction handle ≥ 0.35 s",
                preserveDuration ? "total duration preserved" : "duration growth allowed", "neighboring cuts recalculated"
            ],
            summary: "Продлить момент с сохранением anticipation, peak и reaction",
            confidence: boundary?.confidence ?? 0.56
        )
    }

    func pacingCalls(
        factor: Double,
        timeline: Timeline,
        assets: [MediaAsset],
        analyses: [AnalysisResult]
    ) -> [DirectorToolCall] {
        let candidates = Dictionary(uniqueKeysWithValues: analyses.flatMap(\.directorCandidates).map { ($0.id, $0) })
        let assetsByID = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) })
        return timeline.items.compactMap { item in
            guard item.kind != .title, item.overlay == nil, !item.locked,
                  let candidate = item.candidateID.flatMap({ candidates[$0] }) else { return nil }
            let minimum = minimumCompleteDuration(item: item, candidate: candidate)
            let desiredTimeline = factor < 1
                ? max(minimum, item.timelineDuration * factor)
                : item.timelineDuration * factor
            let sourceDuration = desiredTimeline / max(0.01, item.speedRamp?.outputDuration(sourceDuration: 1) ?? (1 / item.speed))
            let assetEnd = item.assetID.flatMap { assetsByID[$0]?.metadata.duration } ?? (item.sourceStart + item.sourceDuration)
            let edited = range(item: item, candidate: candidate, duration: sourceDuration, assetEnd: assetEnd, expanding: factor > 1)
            guard abs((edited.upperBound - edited.lowerBound) - item.sourceDuration) > 0.015 else { return nil }
            return .trim(
                itemID: item.id,
                sourceStart: edited.lowerBound,
                sourceDuration: edited.upperBound - edited.lowerBound,
                reason: "P8: phase-aware pacing вокруг peakTime с anticipation/reaction handles"
            )
        }
    }

    private func minimumCompleteDuration(item: TimelineItem, candidate: Candidate?) -> Double {
        guard let boundary = candidate?.momentBoundary else { return min(item.timelineDuration, max(0.75, item.timelineDuration * 0.55)) }
        let protected = max(0.70, min(boundary.duration, (boundary.peakTime - boundary.anticipationStart) * 0.45 + (boundary.effectiveReactionEnd - boundary.peakTime) * 0.55))
        let factor = item.speedRamp?.outputDuration(sourceDuration: 1) ?? (1 / item.speed)
        return min(item.timelineDuration, max(0.70, protected * factor))
    }

    private func range(item: TimelineItem, candidate: Candidate?, duration: Double, assetEnd: Double, expanding: Bool) -> ClosedRange<Double> {
        let safeDuration = min(max(0.05, duration), max(0.05, assetEnd))
        guard let boundary = candidate?.momentBoundary else {
            let center = item.sourceStart + item.sourceDuration / 2
            let start = min(max(0, center - safeDuration / 2), max(0, assetEnd - safeDuration))
            return start...(start + safeDuration)
        }
        let peak = boundary.peakTime
        let anticipationHandle = max(0.25, min(0.8, peak - boundary.anticipationStart))
        let reactionHandle = max(0.35, min(1.1, boundary.effectiveReactionEnd - peak))
        var start = min(item.sourceStart, peak - anticipationHandle)
        if !expanding { start = peak - min(anticipationHandle, safeDuration * 0.42) }
        start = min(max(0, start), max(0, assetEnd - safeDuration))
        var end = start + safeDuration
        if end < peak + reactionHandle {
            end = min(assetEnd, peak + reactionHandle)
            start = max(0, end - safeDuration)
        }
        for protected in boundary.doNotCutRanges ?? [] where protected.confidence >= 0.42 {
            if protected.contains(start) { start = max(0, min(protected.start, assetEnd - safeDuration)); end = start + safeDuration }
            if protected.contains(end) { end = min(assetEnd, max(protected.end, start + safeDuration)); start = max(0, end - safeDuration) }
        }
        return start...max(start + 0.05, min(assetEnd, end))
    }
}

// MARK: - Editable offline subtitles and translation

public protocol SubtitleTranslationProviding: Sendable {
    func translate(_ text: String, from sourceLocale: String?, to language: DirectorSubtitleLanguage) -> String
}

/// A deterministic offline fallback for common RU/EN travel phrases. The
/// protocol lets a richer local model replace it without changing P8 planning.
public struct OfflineBilingualSubtitleTranslator: SubtitleTranslationProviding, Sendable {
    public init() {}

    public func translate(_ text: String, from sourceLocale: String?, to language: DirectorSubtitleLanguage) -> String {
        let source = sourceLocale?.lowercased() ?? ""
        if source.hasPrefix(language.rawValue) { return text }
        let normalized = NLText.normalized(text).trimmingCharacters(in: .punctuationCharacters)
        let phrases: [DirectorSubtitleLanguage: [String: String]] = [
            .russian: [
                "what a beautiful day": "Какой прекрасный день",
                "let's go": "Поехали",
                "look at the water": "Посмотри на воду",
                "we made it": "Мы добрались",
                "this is amazing": "Это потрясающе"
            ],
            .english: [
                "какой прекрасный день": "What a beautiful day",
                "поехали": "Let's go",
                "посмотри на воду": "Look at the water",
                "мы добрались": "We made it",
                "это потрясающе": "This is amazing"
            ]
        ]
        if let exact = phrases[language]?[normalized] { return exact }
        return text
    }
}

private struct SubtitleTimelineBuilder: Sendable {
    let translator: any SubtitleTranslationProviding

    func build(directive: DirectorSubtitleDirective, input: NaturalLanguageDirectorInput) -> [TitleTimelineItem] {
        let candidates = Dictionary(uniqueKeysWithValues: input.currentProject.analyses.flatMap(\.directorCandidates).map { ($0.id, $0) })
        return input.timeline.items.compactMap { item -> TitleTimelineItem? in
            guard item.kind == .video, !item.isReversed,
                  let candidate = item.candidateID.flatMap({ candidates[$0] }),
                  let speech = candidate.insights?.speech,
                  speech.confidence >= 0.32 else { return nil }
            let sourceStart = max(item.sourceStart, speech.phraseStart)
            let sourceEnd = min(item.sourceStart + item.sourceDuration, speech.phraseEnd)
            guard sourceEnd - sourceStart >= 0.08 else { return nil }
            let scale = item.timelineDuration / max(0.001, item.sourceDuration)
            let startTime = item.timelineStart + (sourceStart - item.sourceStart) * scale
            let duration = max(0.08, (sourceEnd - sourceStart) * scale)
            let translated = translator.translate(speech.text, from: speech.localeIdentifier, to: directive.language)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !translated.isEmpty else { return nil }
            let style = subtitleStyle(directive.style, tracking: candidate.insights?.subjectTracking, vertical: input.timeline.height > input.timeline.width)
            let words = captionWords(
                translatedText: translated,
                sourceWords: speech.words ?? [],
                sourceStart: sourceStart,
                sourceEnd: sourceEnd,
                outputDuration: duration
            )
            return TitleTimelineItem(
                kind: words.isEmpty ? .automaticSubtitles : .wordLevelCaptions,
                templateID: words.isEmpty ? "caption.clean.v1" : "caption.word-focus.v1",
                text: translated,
                startTime: startTime,
                duration: duration,
                track: 2,
                style: style,
                animation: subtitleAnimation(directive.style),
                words: words,
                activeWordHighlighting: directive.wordHighlighting,
                targetClipID: item.id,
                explanation: [
                    "P8 NaturalLanguageDirector subtitles",
                    "language=\(directive.language.rawValue)",
                    "style=\(directive.style.rawValue)",
                    speech.speakerID.map { "speaker=\($0)" } ?? "speaker=unknown",
                    "safe-area + face avoidance"
                ]
            )
        }
    }

    private func captionWords(
        translatedText: String,
        sourceWords: [TranscriptWord],
        sourceStart: Double,
        sourceEnd: Double,
        outputDuration: Double
    ) -> [CaptionWord] {
        let translatedTokens = translatedText.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !translatedTokens.isEmpty else { return [] }
        let usable = sourceWords.filter { $0.startTime <= sourceEnd && $0.endTime >= sourceStart }
        if usable.count == translatedTokens.count {
            let sourceSpan = max(0.001, sourceEnd - sourceStart)
            return zip(translatedTokens, usable).map { token, word in
                CaptionWord(
                    word: token,
                    start: min(outputDuration, max(0, (word.startTime - sourceStart) / sourceSpan * outputDuration)),
                    end: min(outputDuration, max(0, (word.endTime - sourceStart) / sourceSpan * outputDuration))
                )
            }
        }
        let interval = outputDuration / Double(translatedTokens.count)
        return translatedTokens.enumerated().map { index, token in
            CaptionWord(word: token, start: Double(index) * interval, end: Double(index + 1) * interval)
        }
    }

    private func subtitleStyle(_ preset: DirectorSubtitleStyle, tracking: SubjectTrackingSummary?, vertical: Bool) -> TitleStyle {
        let subjectY = tracking?.mainSubject?.observations.map { $0.region.centerY }.average
        let y = (subjectY ?? 0.4) > 0.58 ? 0.17 : (vertical ? 0.76 : 0.84)
        switch preset {
        case .cinematic:
            return TitleStyle(fontSize: 54, textColorHex: "#FFFFFF", backgroundColorHex: "#111111", fontWeight: 0.62, yPosition: y, shadow: 0.72, strokeWidth: 1.2, backgroundOpacity: 0.10)
        case .vlog:
            return TitleStyle(fontSize: 70, textColorHex: "#FFFFFF", backgroundColorHex: "#111111", fontWeight: 0.82, yPosition: y, shadow: 0.55, strokeWidth: 1.8, backgroundOpacity: 0.32, activeWordColorHex: "#FFD60A")
        case .travel:
            return TitleStyle(fontSize: 60, textColorHex: "#FFFFFF", backgroundColorHex: "#111111", fontWeight: 0.70, yPosition: y, shadow: 0.62, strokeWidth: 1.2, backgroundOpacity: 0.22, activeWordColorHex: "#5AC8FA")
        case .social:
            return TitleStyle(fontSize: 76, textColorHex: "#FFFFFF", backgroundColorHex: "#111111", fontWeight: 0.90, yPosition: y, shadow: 0.45, strokeWidth: 2.0, backgroundOpacity: 0.38, activeWordColorHex: "#FFCC00")
        }
    }

    private func subtitleAnimation(_ style: DirectorSubtitleStyle) -> TitleAnimation {
        switch style {
        case .cinematic, .travel: return TitleAnimation(entrance: .fade, exit: .fade, duration: 0.22)
        case .vlog: return TitleAnimation(entrance: .scale, exit: .fade, duration: 0.16)
        case .social: return TitleAnimation(entrance: .kinetic, exit: .scale, duration: 0.12)
        }
    }
}

// MARK: - Transaction safety

private struct NaturalLanguageTimelineSafetyValidator: Sendable {
    func violations(
        candidate: Timeline,
        comparedTo original: Timeline,
        plan: NaturalLanguageEditingPlan,
        assets: [MediaAsset]
    ) -> [String] {
        var result: [String] = []
        if candidate.width < 64 || candidate.height < 64 || candidate.width > 8_192 || candidate.height > 8_192 {
            result.append("invalid canvas")
        }
        let primary = candidate.items.filter { $0.kind != .title && $0.overlay == nil }
        if !original.items.filter({ $0.kind != .title && $0.overlay == nil }).isEmpty && primary.isEmpty {
            result.append("the command would remove the complete primary story")
        }
        let durations = Dictionary(uniqueKeysWithValues: assets.compactMap { asset in asset.metadata.duration.map { (asset.id, $0) } })
        for item in candidate.items {
            if !item.sourceStart.isFinite || !item.sourceDuration.isFinite || !item.timelineDuration.isFinite || item.timelineDuration < 0.05 {
                result.append("non-finite or empty item \(item.id)")
            }
            if let assetID = item.assetID, let duration = durations[assetID], item.sourceStart + item.sourceDuration > duration + 0.002 {
                result.append("source range overflow \(item.id)")
            }
        }
        if plan.executionTier != .deep,
           plan.intents.allSatisfy({ $0.scope != .global || $0.operation == .format }),
           abs(candidate.duration - original.duration) > max(0.1, original.duration * 0.08),
           plan.intents.contains(where: { $0.operation == .extendMoment && $0.constraints.contains("total duration preserved") }) {
            result.append("local edit violated the global duration constraint")
        }
        return result.uniqued()
    }
}

// MARK: - Text helpers

private enum NLText {
    static func normalized(_ value: String) -> String {
        value.lowercased()
            .replacingOccurrences(of: "ё", with: "е")
            .replacingOccurrences(of: "–", with: "-")
            .replacingOccurrences(of: "—", with: "-")
    }

    static func containsAny(_ text: String, _ values: [String]) -> Bool { values.contains(where: text.contains) }

    static func firstNumber(in text: String, pattern: String) -> Double? {
        firstMatch(in: text, pattern: pattern)?.first.flatMap { Double($0.replacingOccurrences(of: ",", with: ".")) }
    }

    static func firstMatch(in text: String, pattern: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges > 1 else { return nil }
        return (1..<match.numberOfRanges).compactMap { index in
            Range(match.range(at: index), in: text).map { String(text[$0]) }
        }
    }

    static func ordinal(in text: String) -> Int? {
        let words: [(Int, [String])] = [
            (1, ["первая сцена", "первый момент", "первый кадр"]),
            (2, ["вторая сцена", "второй момент", "второй кадр"]),
            (3, ["третья сцена", "третий момент", "третий кадр"]),
            (4, ["четвертая сцена", "четвертый момент", "четвертый кадр"]),
            (5, ["пятая сцена", "пятый момент", "пятый кадр"])
        ]
        if let value = words.first(where: { containsAny(text, $0.1) }) { return value.0 }
        return firstMatch(in: text, pattern: #"(?:сцена|момент|кадр|клип)\s*(\d+)"#)?.first.flatMap(Int.init)
    }

    static func semanticTokens(_ value: String) -> Set<String> {
        let stop: Set<String> = [
            "сделай", "добавь", "убери", "удали", "верни", "продли", "оставь", "поставь", "перемести",
            "момент", "сцена", "кадр", "клип", "видео", "фильм", "там", "где", "этот", "тот", "мне",
            "чуть", "больше", "меньше", "подольше", "после", "перед", "the", "a", "an", "this", "that",
            "make", "add", "remove", "shot", "scene", "video"
        ]
        var tokens = Set(normalized(value)
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count > 1 && !stop.contains($0) })
        let synonyms: [String: Set<String>] = [
            "лодка": ["лодка", "лодке", "boat", "kayak", "canoe"],
            "лодке": ["лодка", "лодке", "boat", "kayak", "canoe"],
            "boat": ["лодка", "лодке", "boat", "kayak", "canoe"],
            "прыжок": ["прыжок", "прыгаем", "jump", "splash"],
            "прыгаем": ["прыжок", "прыгаем", "jump", "splash"],
            "jump": ["прыжок", "прыгаем", "jump", "splash"],
            "велосипед": ["велосипед", "велосипеде", "bike", "bicycle", "cycling", "cyclist"],
            "велосипеде": ["велосипед", "велосипеде", "bike", "bicycle", "cycling", "cyclist"],
            "bike": ["велосипед", "велосипеде", "bike", "bicycle", "cycling", "cyclist"],
            "вода": ["вода", "водой", "water", "river", "splash"],
            "водой": ["вода", "водой", "water", "river", "splash"],
            "water": ["вода", "водой", "water", "river", "splash"],
            "закат": ["закат", "sunset", "dusk", "golden"],
            "sunset": ["закат", "sunset", "dusk", "golden"],
            "дорога": ["дорога", "road", "drive", "driving"],
            "road": ["дорога", "road", "drive", "driving"],
            "сплав": ["сплав", "rafting", "raft", "river"]
        ]
        for token in Array(tokens) { tokens.formUnion(synonyms[token] ?? []) }
        return tokens
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}

private extension Array where Element == Double {
    var average: Double? { isEmpty ? nil : reduce(0, +) / Double(count) }
}
