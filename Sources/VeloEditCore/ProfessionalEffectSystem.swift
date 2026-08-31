import Foundation

// MARK: - Deterministic per-clip effect stacks

public enum EffectStackEngine {
    public static func orderedForRendering(_ effects: [EffectTimelineItem]) -> [EffectTimelineItem] {
        effects.enumerated().sorted { lhs, rhs in
            // Legacy projects had only array order. Keep that exact visual
            // result until an explicit stack edit writes `stackOrder`.
            let lhsOrder = lhs.element.stackOrder ?? lhs.offset
            let rhsOrder = rhs.element.stackOrder ?? rhs.offset
            if lhsOrder == rhsOrder { return lhs.offset < rhs.offset }
            return lhsOrder < rhsOrder
        }.map(\.element)
    }

    public static func stack(in timeline: Timeline, for clipID: UUID?) -> [EffectTimelineItem] {
        orderedForRendering(timeline.effectiveEffects.filter { $0.targetClipID == clipID })
    }

    /// Reorders one target's stack without disturbing effects assigned to
    /// other clips. The operation mutates one Timeline snapshot and therefore
    /// remains one logical Undo step in the app.
    @discardableResult
    public static func reorderEffect(in timeline: inout Timeline, id: UUID, to requestedIndex: Int) -> Bool {
        var all = timeline.effectiveEffects
        guard let selected = all.first(where: { $0.id == id }) else { return false }
        var stack = orderedForRendering(all.filter { $0.targetClipID == selected.targetClipID })
        guard stack.count > 1, let oldIndex = stack.firstIndex(where: { $0.id == id }) else { return false }
        let newIndex = min(max(0, requestedIndex), stack.count - 1)
        guard newIndex != oldIndex else { return false }
        let moved = stack.remove(at: oldIndex)
        stack.insert(moved, at: newIndex)
        let orderByID = Dictionary(uniqueKeysWithValues: stack.enumerated().map { ($0.element.id, $0.offset) })
        for index in all.indices {
            if let order = orderByID[all[index].id] { all[index].stackOrder = order }
        }
        timeline.effects = all
        return true
    }
}

// MARK: - Data-driven combinations of ordinary effects

public struct EffectStackPresetComponent: Codable, Hashable, Sendable {
    public var type: TimelineEffectType
    public var intensity: Double
    public var parameters: [EffectParameter]
    public var keyframes: [EffectKeyframe]

    public init(
        type: TimelineEffectType,
        intensity: Double,
        parameters: [EffectParameter] = [],
        keyframes: [EffectKeyframe] = []
    ) {
        self.type = type
        self.intensity = intensity.clamped01
        self.parameters = parameters
        self.keyframes = keyframes
    }
}

public struct EffectStackPresetDefinition: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var summary: String
    public var semanticTags: Set<String>
    public var components: [EffectStackPresetComponent]
    public var version: Int

    public init(
        id: String,
        name: String,
        summary: String,
        semanticTags: Set<String>,
        components: [EffectStackPresetComponent],
        version: Int = 1
    ) {
        self.id = id
        self.name = name
        self.summary = summary
        self.semanticTags = semanticTags
        self.components = components
        self.version = version
    }
}

public enum EffectStackPresetRegistry {
    public static let all: [EffectStackPresetDefinition] = [
        EffectStackPresetDefinition(
            id: "cinematic", name: "Cinematic", summary: "Киноконтраст, мягкая виньетка и деликатное зерно",
            semanticTags: ["cinematic", "emotion", "travel"],
            components: [
                .init(type: .cinematicContrast, intensity: 0.34),
                .init(type: .cinematicVignette, intensity: 0.20),
                .init(type: .filmGrain, intensity: 0.16)
            ]
        ),
        EffectStackPresetDefinition(
            id: "action", name: "Action", summary: "Контраст, резкость и аккуратный motion emphasis",
            semanticTags: ["action", "sport", "high-energy"],
            components: [
                .init(type: .contrast, intensity: 0.58),
                .init(type: .sharpness, intensity: 0.32),
                .init(type: .motionBlur, intensity: 0.18, parameters: [EffectParameter(name: "angle", value: 0, valueType: .angle)])
            ]
        ),
        EffectStackPresetDefinition(
            id: "vintage", name: "Vintage", summary: "Выцветание, тёплый сдвиг, зерно и виньетка",
            semanticTags: ["memory", "archive", "nostalgic"],
            components: [
                .init(type: .vintage, intensity: 0.42),
                .init(type: .filmGrain, intensity: 0.24),
                .init(type: .vignette, intensity: 0.20)
            ]
        ),
        EffectStackPresetDefinition(
            id: "travel", name: "Travel", summary: "Естественный цвет и сдержанный киноконтраст",
            semanticTags: ["travel", "nature", "calm"],
            components: [
                .init(type: .colorGrade, intensity: 0.30),
                .init(type: .cinematicContrast, intensity: 0.22)
            ]
        ),
        EffectStackPresetDefinition(
            id: "social", name: "Social", summary: "Выразительный цвет и плавный punch-in",
            semanticTags: ["social", "vertical", "fast"],
            components: [
                .init(type: .contrast, intensity: 0.62),
                .init(type: .vibrance, intensity: 0.58),
                .init(type: .zoom, intensity: 0.20, keyframes: [
                    EffectKeyframe(parameter: "scaleX", time: 0, value: 1, easing: .easeInOut, typedValue: .float(1)),
                    EffectKeyframe(parameter: "scaleX", time: 3, value: 1.08, easing: .easeInOut, typedValue: .float(1.08)),
                    EffectKeyframe(parameter: "scaleY", time: 0, value: 1, easing: .easeInOut, typedValue: .float(1)),
                    EffectKeyframe(parameter: "scaleY", time: 3, value: 1.08, easing: .easeInOut, typedValue: .float(1.08))
                ])
            ]
        )
    ]

    public static func preset(id: String) -> EffectStackPresetDefinition? {
        all.first { $0.id == id }
    }

    @discardableResult
    public static func apply(
        _ preset: EffectStackPresetDefinition,
        to timeline: inout Timeline,
        targetClipID: UUID?,
        startTime: Double,
        duration: Double,
        explanation: String
    ) -> [UUID] {
        let safeStart = min(max(0, startTime), max(0, timeline.duration - 0.05))
        let safeDuration = min(max(0.05, duration), max(0.05, timeline.duration - safeStart))
        let firstOrder = EffectStackEngine.stack(in: timeline, for: targetClipID).count
        let presetInstanceID = UUID()
        var created: [EffectTimelineItem] = []
        for (offset, component) in preset.components.enumerated() {
            let definition = EffectPresetRegistry.preset(for: component.type)
            let supplied = Set(component.parameters.map(\.name))
            let defaults = definition.defaultParameters.filter { !supplied.contains($0.name) }
            let keyframes = component.keyframes.map { frame in
                var copy = frame
                copy.time = min(copy.time, safeDuration)
                return copy
            }
            created.append(EffectTimelineItem(
                effectType: component.type,
                startTime: safeStart,
                duration: safeDuration,
                parameters: defaults + component.parameters,
                intensity: component.intensity,
                keyframes: keyframes,
                targetClipID: targetClipID,
                stackOrder: firstOrder + offset,
                effectStackPresetID: preset.id,
                effectStackPresetInstanceID: presetInstanceID,
                explanation: [explanation, "Data-driven preset \(preset.name); renderer remains the ordinary effect stack"]
            ))
        }
        timeline.effects = timeline.effectiveEffects + created
        return created.map(\.id)
    }
}

// MARK: - Conservative AI effect budgets

public struct AIEffectBudget: Codable, Hashable, Sendable {
    public var maximumEffectsPerClip: Int
    public var maximumSimultaneousHeavyEffects: Int
    public var maximumTransitionsPerMinute: Int
    public var maximumCreativeEffectsPerClip: Int

    public init(
        maximumEffectsPerClip: Int,
        maximumSimultaneousHeavyEffects: Int,
        maximumTransitionsPerMinute: Int,
        maximumCreativeEffectsPerClip: Int = 1
    ) {
        self.maximumEffectsPerClip = max(1, maximumEffectsPerClip)
        self.maximumSimultaneousHeavyEffects = max(1, maximumSimultaneousHeavyEffects)
        self.maximumTransitionsPerMinute = max(1, maximumTransitionsPerMinute)
        self.maximumCreativeEffectsPerClip = max(0, maximumCreativeEffectsPerClip)
    }
}

public enum AIEffectBudgetPolicy {
    public static func budget(for preset: FilmPreset?, taste: PersonalTasteProfile? = nil) -> AIEffectBudget {
        let base: AIEffectBudget
        switch preset {
        case .highlight, .adventure:
            base = AIEffectBudget(maximumEffectsPerClip: 3, maximumSimultaneousHeavyEffects: 1, maximumTransitionsPerMinute: 8)
        case .summerFilm:
            base = AIEffectBudget(maximumEffectsPerClip: 3, maximumSimultaneousHeavyEffects: 1, maximumTransitionsPerMinute: 6)
        case .cinematic, .memories:
            base = AIEffectBudget(maximumEffectsPerClip: 3, maximumSimultaneousHeavyEffects: 1, maximumTransitionsPerMinute: 5)
        case .story, .none:
            base = AIEffectBudget(maximumEffectsPerClip: 3, maximumSimultaneousHeavyEffects: 1, maximumTransitionsPerMinute: 4)
        }
        guard let estimate = taste?.adaptiveEstimate(for: "effectPreference"), estimate.confidence >= 0.55 else { return base }
        if estimate.value < -0.45 {
            return AIEffectBudget(
                maximumEffectsPerClip: max(1, base.maximumEffectsPerClip - 1),
                maximumSimultaneousHeavyEffects: 1,
                maximumTransitionsPerMinute: max(2, base.maximumTransitionsPerMinute - 2)
            )
        }
        return base
    }

    public static func canAddEffect(
        _ type: TimelineEffectType,
        targetClipID: UUID?,
        to timeline: Timeline,
        budget: AIEffectBudget,
        explicitCreativeRequest: Bool = false
    ) -> Bool {
        let stack = timeline.effectiveEffects.filter { $0.enabled && $0.targetClipID == targetClipID }
        guard stack.count < budget.maximumEffectsPerClip else { return false }
        let definition = EffectPresetRegistry.preset(for: type)
        if definition.isHeavy {
            let heavy = stack.filter { EffectPresetRegistry.preset(for: $0.effectType).isHeavy }.count
            guard heavy < budget.maximumSimultaneousHeavyEffects else { return false }
        }
        if definition.aiUsage.requiresExplicitCreativeRequest && !explicitCreativeRequest { return false }
        let creative = stack.filter { EffectPresetRegistry.preset(for: $0.effectType).aiUsage.requiresExplicitCreativeRequest }.count
        return !definition.aiUsage.requiresExplicitCreativeRequest || creative < budget.maximumCreativeEffectsPerClip
    }

    public static func canAddTransition(to timeline: Timeline, budget: AIEffectBudget) -> Bool {
        let minutes = max(1.0 / 60, timeline.duration / 60)
        let allowed = max(1, Int(ceil(minutes * Double(budget.maximumTransitionsPerMinute))))
        return timeline.effectiveTransitionItems.filter(\.enabled).count < allowed
    }
}
