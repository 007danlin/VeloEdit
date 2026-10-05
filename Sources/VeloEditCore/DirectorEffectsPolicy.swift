import Foundation

/// An explicit effects choice is independent of mood and survives plan
/// regeneration through DirectorBrief. Missing choices keep legacy behavior.
public enum DirectorEffectsPolicyEngine {
    public static func policy(for plan: StoryPlan) -> DirectorEffectsPolicy? {
        let text = plan.prompt.lowercased()
        if ["без эффект", "никаких эффект", "убери все эффект", "no effects", "without effects"].contains(where: text.contains) {
            return DirectorEffectsPolicy.none
        }
        if let policy = plan.directorBrief?.effectsPolicy { return policy }
        if text.contains("эффекты: много") || text.contains("много эффектов") { return .many }
        if text.contains("эффекты: нормально") { return .normal }
        if text.contains("эффекты: без") { return DirectorEffectsPolicy.none }
        return nil
    }

    public static func allowsEffects(in plan: StoryPlan) -> Bool {
        if let policy = policy(for: plan) { return policy != .none }
        return DirectorRequestContract.requestsEffects(plan.prompt) || EditorialIntentEnforcer.explicitCreativeRequest(plan.prompt)
    }

    public static func removingEffects(from source: Timeline) -> Timeline {
        var timeline = source
        timeline.effects = []
        timeline.transitionItems = []
        timeline.endingFadeDuration = 0
        timeline.audioClips = timeline.effectiveAudioClips.filter { $0.role != .soundEffect }
        for index in timeline.items.indices {
            timeline.items[index].effect = nil
            timeline.items[index].transition = nil
            if timeline.items[index].incomingEditDecision?.choice == .transition {
                timeline.items[index].incomingEditDecision = .init(choice: .cut,
                    motivation: "Выбрано «Без эффектов»: прямая склейка", confidence: 1)
            }
        }
        return timeline
    }

    /// Called only while composing a new edit. Review/enforcement never adds
    /// effects, so repeat validation cannot duplicate them or undo manual edits.
    public static func decorate(_ source: Timeline, plan: StoryPlan, candidates: [UUID: Candidate]) -> Timeline {
        guard let policy = policy(for: plan) else { return source }
        guard policy != .none else { return removingEffects(from: source) }
        var timeline = source
        let many = policy == .many
        let primary = timeline.items.filter { $0.overlay == nil && $0.kind != .title }
        let maximum = min(Int(ceil(Double(primary.count) * (many ? 0.5 : 0.2))),
            max(1, Int(ceil(timeline.duration / 60 * (many ? 6 : 2)))))
        var effects = timeline.effectiveEffects
        var added = effects.filter { $0.explanation.first?.hasPrefix("Режиссёр: эффекты — ") == true }.count
        var lastAccent = -Double.greatestFiniteMagnitude
        for item in primary {
            guard added < maximum, item.kind == .video, !item.locked, item.timelineDuration >= 2.5,
                  item.timelineStart - lastAccent >= (many ? 6 : 18),
                  !effects.contains(where: { $0.targetClipID == item.id }) else { continue }
            let candidate = item.candidateID.flatMap { candidates[$0] }
            // Keep speech and unstable material clear even in the "many" mode.
            guard (candidate?.insights?.speech?.confidence ?? 0) < 0.65,
                  (candidate?.scores.stability ?? 1) >= 0.55 else { continue }
            let moving = (candidate?.insights?.dynamics ?? candidate?.scores.action ?? 0) >= 0.65
            let type: TimelineEffectType = moving ? .cinematicMotionBlur : .pushIn
            effects.append(EffectTimelineItem(effectType: type, startTime: item.timelineStart,
                duration: item.timelineDuration,
                parameters: EffectPresetRegistry.preset(for: type).defaultParameters,
                intensity: many ? 0.24 : 0.12, targetClipID: item.id,
                explanation: ["Режиссёр: эффекты — \(policy.localizedTitle.lowercased())",
                    moving ? "Мягкое размытие подчёркивает движение" : "Плавное приближение в спокойном кадре"]))
            added += 1
            lastAccent = item.timelineStart
        }
        timeline.effects = effects
        var lastTransition = -Double.greatestFiniteMagnitude
        let transitions = timeline.effectiveTransitionItems.sorted { $0.startTime < $1.startTime }.filter { item in
            guard item.startTime - lastTransition >= (many ? 5 : 12) else { return false }
            lastTransition = item.startTime
            return true
        }
        let retained = Set(transitions.map(\.incomingClipID))
        for index in timeline.items.indices where !retained.contains(timeline.items[index].id) {
            timeline.items[index].transition = nil
            if timeline.items[index].incomingEditDecision?.choice == .transition {
                timeline.items[index].incomingEditDecision = .init(choice: .cut,
                    motivation: "Количество переходов ограничено выбранным уровнем эффектов", confidence: 1)
            }
        }
        timeline.transitionItems = transitions
        return timeline
    }
}
