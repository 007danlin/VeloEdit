import Foundation
import Testing
@testable import VeloEditCore

@Test func tz16RegistryIsCompleteTypedAndCapabilityAware() {
    #expect(EffectPresetRegistry.all.count == TimelineEffectType.allCases.count)
    #expect(Set(EffectPresetRegistry.all.map(\.category)) == Set(TimelineEffectCategory.allCases))
    #expect(EffectPresetRegistry.all.allSatisfy {
        !$0.id.isEmpty && !$0.name.isEmpty && !$0.subtitle.isEmpty &&
        $0.previewSupported && $0.renderSupported && $0.version >= 2 &&
        $0.parameter(named: "intensity") != nil
    })
    #expect(Set(EffectStackPresetRegistry.all.map(\.id)) == ["cinematic", "action", "vintage", "travel", "social"])
    #expect(EffectPresetRegistry.preset(for: .zoom).parameter(named: "positionX")?.isAdvanced == true)
    #expect(EffectPresetRegistry.preset(for: .zoom).parameter(named: "cropWidth")?.valueType == .rect)
}

@Test func tz16TypedValuesAndLegacyScalarsRoundTripTogether() throws {
    let values: [EffectParameterValue] = [
        .float(0.4), .int(7), .bool(true), .angle(32),
        .color(EffectColorValue(red: 0.2, green: 0.4, blue: 0.8)),
        .point(EffectPointValue(x: 0.3, y: 0.7)),
        .size(EffectSizeValue(width: 1920, height: 1080)),
        .rect(EffectRectValue(x: 0.1, y: 0.2, width: 0.7, height: 0.6)),
        .enumeration("2")
    ]
    let parameters = values.enumerated().map { EffectParameter(name: "p\($0.offset)", typedValue: $0.element) }
    let decoded = try JSONDecoder().decode([EffectParameter].self, from: JSONEncoder().encode(parameters))
    #expect(decoded == parameters)
    #expect(Set(decoded.compactMap(\.valueType)) == Set(EffectParameterValueType.allCases))

    let legacy = try JSONDecoder().decode(EffectParameter.self, from: Data(#"{"name":"legacy","value":0.75}"#.utf8))
    #expect(legacy.typedValue == nil)
    #expect(legacy.effectiveNumericValue == 0.75)
}

@Test func tz16EasingCurvesAreStableAndBounded() {
    for easing in KeyframeEasing.allCases {
        #expect(easing.transform(0) == 0)
        #expect(easing.transform(1) == 1)
        for step in 0...100 {
            let value = easing.transform(Double(step) / 100)
            #expect((0...1).contains(value))
        }
    }
}

@Test func tz16EffectStackReordersAndPresetStaysEditable() {
    let clip = TimelineItem(kind: .video, sourceDuration: 6, timelineStart: 0, timelineDuration: 6)
    let first = EffectTimelineItem(effectType: .brightness, startTime: 0, duration: 6, targetClipID: clip.id, stackOrder: 0)
    let second = EffectTimelineItem(effectType: .filmGrain, startTime: 0, duration: 6, targetClipID: clip.id, stackOrder: 1)
    var timeline = Timeline(storyPlanID: UUID(), items: [clip], effects: [first, second])
    #expect(EffectStackEngine.reorderEffect(in: &timeline, id: second.id, to: 0))
    #expect(EffectStackEngine.stack(in: timeline, for: clip.id).map(\.id) == [second.id, first.id])

    let preset = EffectStackPresetRegistry.preset(id: "social")!
    let ids = EffectStackPresetRegistry.apply(preset, to: &timeline, targetClipID: clip.id, startTime: 0, duration: 6, explanation: "test")
    #expect(ids.count == preset.components.count)
    let presetItems = timeline.effectiveEffects.filter { ids.contains($0.id) }
    #expect(presetItems.allSatisfy { $0.enabled && $0.duration == 6 })
    #expect(Set(presetItems.compactMap(\.effectStackPresetID)) == [preset.id])
    #expect(Set(presetItems.compactMap(\.effectStackPresetInstanceID)).count == 1)
    #expect(timeline.effectiveEffects.first(where: { ids.contains($0.id) && $0.effectType == .zoom })?.keyframes.count == 4)
}

@Test func tz16AIAnimationCreatesRealValidatedKeyframesAndBudgetsEffects() {
    let clip = TimelineItem(kind: .video, sourceDuration: 5, timelineStart: 0, timelineDuration: 5)
    let source = Timeline(storyPlanID: UUID(), items: [clip])
    let result = DirectorEditingTools().apply([
        .addAnimatedEffect(
            type: .zoom,
            startTime: 0,
            duration: 5,
            targetClipID: clip.id,
            keyframes: [
                EffectKeyframe(parameter: "scaleX", time: 0, value: 1),
                EffectKeyframe(parameter: "scaleX", time: 5, value: 1.1)
            ],
            reason: "smooth zoom"
        )
    ], to: source, assets: [], analyses: [])
    #expect(result.report.rejected.isEmpty)
    #expect(result.timeline.effectiveEffects.first?.keyframes.count == 2)
    #expect(result.timeline.effectiveEffects.first?.keyframes.allSatisfy { $0.typedValue != nil } == true)

    let budget = AIEffectBudgetPolicy.budget(for: .story)
    var crowded = source
    crowded.effects = (0..<budget.maximumEffectsPerClip).map {
        EffectTimelineItem(effectType: .brightness, startTime: 0, duration: 5, targetClipID: clip.id, stackOrder: $0)
    }
    #expect(!AIEffectBudgetPolicy.canAddEffect(.contrast, targetClipID: clip.id, to: crowded, budget: budget))
    #expect(!AIEffectBudgetPolicy.canAddEffect(.glitch, targetClipID: nil, to: source, budget: budget))
    #expect(AIEffectBudgetPolicy.canAddEffect(.glitch, targetClipID: nil, to: source, budget: budget, explicitCreativeRequest: true))
}

@Test func tz16TransitionDirectionEasingAndFCPXMLCapabilityPersist() throws {
    let first = TimelineItem(kind: .video, sourceDuration: 3, timelineStart: 0, timelineDuration: 3)
    let second = TimelineItem(kind: .video, sourceDuration: 3, timelineStart: 3, timelineDuration: 3)
    let transition = TimelineTransitionItem(
        style: .push,
        outgoingClipID: first.id,
        incomingClipID: second.id,
        startTime: 3,
        direction: .up,
        easing: .cubic
    )
    let decoded = try JSONDecoder().decode(TimelineTransitionItem.self, from: JSONEncoder().encode(transition))
    #expect(decoded.effectiveDirection == .up)
    #expect(decoded.effectiveEasing == .cubic)

    let effect = EffectTimelineItem(effectType: .filmLook, startTime: 0, duration: 3, targetClipID: first.id)
    let timeline = Timeline(storyPlanID: UUID(), items: [first, second], effects: [effect], transitionItems: [transition])
    let xml = try FCPXMLExporter().xml(timeline: timeline, assets: [])
    #expect(xml.contains("com.veloedit.effectCapability"))
    #expect(xml.contains("rendered-fallback"))
}

@Test func tz16NaturalLanguageUsesEditableEffectAndAnimationTools() {
    let clip = TimelineItem(kind: .video, sourceDuration: 5, timelineStart: 0, timelineDuration: 5)
    let timeline = Timeline(storyPlanID: UUID(), items: [clip])
    let project = ProjectManifest(name: "AI Effects", timelines: [timeline])
    let director = NaturalLanguageDirector()
    let zoomInput = NaturalLanguageDirectorInput(
        userRequest: "Сделай плавный зум на человеке",
        currentProject: project,
        timeline: timeline,
        selectedItemID: clip.id,
        playheadTime: 0
    )
    let zoomPlan = director.plan(input: zoomInput)
    #expect(zoomPlan.toolCalls.contains {
        if case .addAnimatedEffect(type: .zoom, _, _, _, let frames, _) = $0 { return frames.count == 4 }
        return false
    })
    let zoomResult = director.execute(plan: zoomPlan, input: zoomInput, recordHistory: false)
    #expect(zoomResult.committed)
    #expect(zoomResult.timeline.effectiveEffects.contains { $0.effectType == .zoom && $0.keyframes.count == 4 })

    let grain = EffectTimelineItem(effectType: .filmGrain, startTime: 0, duration: 5, targetClipID: clip.id)
    var withEffect = project
    let removalTimeline = Timeline(storyPlanID: UUID(), items: [clip], effects: [grain])
    withEffect.timelines = [removalTimeline]
    let removalPlan = director.plan(input: NaturalLanguageDirectorInput(
        userRequest: "Убери эффект плёночного зерна",
        currentProject: withEffect,
        timeline: removalTimeline,
        selectedItemID: clip.id
    ))
    #expect(removalPlan.toolCalls.contains { if case .removeEffect = $0 { return true }; return false })
    #expect(!removalPlan.toolCalls.contains { if case .addEffect = $0 { return true }; return false })
}
