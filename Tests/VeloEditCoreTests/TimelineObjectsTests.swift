import Foundation
import Testing
@testable import VeloEditCore

@Test func standaloneTimelineObjectsRoundTripAndInterpolate() throws {
    let clipID = UUID()
    let effect = EffectTimelineItem(
        effectType: .zoom,
        startTime: 2,
        duration: 2,
        parameters: [EffectParameter(name: "intensity", value: 0.4)],
        keyframes: [
            EffectKeyframe(parameter: "intensity", time: 0, value: 0, easing: .easeIn),
            EffectKeyframe(parameter: "intensity", time: 2, value: 1, easing: .linear)
        ],
        targetClipID: clipID
    )
    #expect(abs(effect.parameterValue("intensity", at: 3) - 0.125) < 0.000_001)

    let title = TitleTimelineItem(
        kind: .wordLevelCaptions,
        text: "Быстрый красивый кадр",
        startTime: 0.5,
        duration: 3,
        words: [CaptionWord(word: "Быстрый", start: 0, end: 1)],
        targetClipID: clipID
    )
    let transition = TimelineTransitionItem(
        style: .zoom,
        outgoingClipID: clipID,
        incomingClipID: UUID(),
        startTime: 3,
        duration: 0.5
    )
    let timeline = Timeline(
        storyPlanID: UUID(),
        items: [TimelineItem(id: clipID, kind: .video, sourceDuration: 4, timelineStart: 0, timelineDuration: 4)],
        effects: [effect],
        titleItems: [title],
        transitionItems: [transition]
    )
    let decoded = try JSONDecoder().decode(Timeline.self, from: JSONEncoder().encode(timeline))
    #expect(decoded.effectiveEffects == [effect])
    #expect(decoded.effectiveTitleItems == [title])
    #expect(decoded.effectiveTransitionItems == [transition])
}

@Test func musicSyncBuildsStructureAndSnapsEditableObjects() {
    let clip = TimelineItem(kind: .video, sourceDuration: 8, timelineStart: 0, timelineDuration: 8)
    let effect = EffectTimelineItem(effectType: .flash, startTime: 1.13, duration: 0.72)
    let title = TitleTimelineItem(kind: .title, text: "Глава", startTime: 2.18, duration: 2)
    let timeline = Timeline(
        storyPlanID: UUID(),
        items: [clip],
        effects: [effect],
        titleItems: [title],
        music: MusicDirective(style: .cinematic, bpm: 120)
    )
    let engine = MusicSyncEngine()
    let result = engine.synchronize(timeline, bpm: 120, energy: 0.8)
    #expect(result.music?.structure?.beatTimestamps?.count == 17)
    #expect(result.music?.structure?.barBoundaries == [0, 2, 4, 6, 8])
    #expect(result.music?.structure?.drops?.isEmpty == false)
    #expect(result.effectiveEffects.first?.startTime == 1.25)
    #expect(result.effectiveTitleItems.first?.startTime == 2.25)
    #expect(engine.duckedMusicGain(originalAudioLevel: 1, settings: AudioDuckingSettings(enabled: true, attenuation: 0.35)) == 0.65)
}

@Test func measuredMusicBuildsDownbeatsPhrasesDropsAndRealAccents() {
    let envelope: [Double] = [
        0.08, 0.12, 0.10, 0.16, 0.72, 0.34, 0.28, 0.30,
        0.82, 0.42, 0.36, 0.40, 0.96, 0.62, 0.54, 0.48,
        0.22, 0.24, 0.20, 0.26, 0.88, 0.58, 0.50, 0.44,
        0.30, 0.28, 0.24, 0.20, 0.74, 0.46, 0.28, 0.12
    ]
    let structure = MusicSyncEngine().analyze(bpm: 120, duration: 16, energy: 0.72, energyEnvelope: envelope)
    #expect(structure.downbeatTimestamps?.isEmpty == false)
    #expect(structure.phraseBoundaries?.count ?? 0 >= 2)
    #expect(structure.accents?.contains(where: { $0.kind == .onset || $0.kind == .peak }) == true)
    #expect(structure.accents?.contains(where: { $0.kind == .drop }) == true)
    #expect(structure.drops?.contains(where: { $0 > 1.5 && $0 < 15 }) == true)
    #expect(structure.sections.first?.kind == .intro)
    #expect(structure.sections.last?.kind == .outro)
}

@Test func directorToolsMutateIndependentObjects() {
    let first = TimelineItem(kind: .video, sourceDuration: 4, timelineStart: 0, timelineDuration: 4)
    let second = TimelineItem(kind: .video, sourceDuration: 4, timelineStart: 4, timelineDuration: 4)
    let source = Timeline(
        storyPlanID: UUID(),
        items: [first, second],
        music: MusicDirective(style: .energetic, bpm: 120)
    )
    let tools = DirectorEditingTools()
    let initial = tools.apply([
        .addEffect(type: .cinematicVignette, startTime: 0, duration: 4, targetClipID: first.id, reason: "Тест"),
        .addTitleObject(text: "Путешествие", kind: .cinematicTitle, templateID: "title.cinematic.v1", startTime: 0, duration: 2.5, reason: "Тест"),
        .addTransitionObject(outgoingClipID: first.id, incomingClipID: second.id, style: .push, duration: 0.4, reason: "Тест"),
        .syncToBeat(bpm: 120, reason: "Тест")
    ], to: source, assets: [], analyses: [])
    #expect(initial.report.rejected.isEmpty)
    #expect(initial.timeline.effectiveEffects.count == 1)
    #expect(initial.timeline.effectiveTitleItems.count == 1)
    #expect(initial.timeline.effectiveTransitionItems.first?.style == .push)
    #expect(initial.timeline.music?.structure?.beatTimestamps?.isEmpty == false)

    let effectID = initial.timeline.effectiveEffects[0].id
    let titleID = initial.timeline.effectiveTitleItems[0].id
    let keyframe = EffectKeyframe(parameter: "intensity", time: 1, value: 0.8, easing: .easeOut)
    let edited = tools.apply([
        .setEffectParameter(effectID: effectID, name: "intensity", value: 0.72, reason: "Тест"),
        .addEffectKeyframe(effectID: effectID, keyframe: keyframe, reason: "Тест"),
        .editTitleObject(titleID: titleID, text: "Новая глава", style: nil, animation: TitleAnimation(entrance: .scale), reason: "Тест")
    ], to: initial.timeline, assets: [], analyses: [])
    #expect(edited.report.rejected.isEmpty)
    #expect(edited.timeline.effectiveEffects[0].intensity == 0.72)
    #expect(edited.timeline.effectiveEffects[0].keyframes == [keyframe])
    #expect(edited.timeline.effectiveTitleItems[0].text == "Новая глава")
    #expect(edited.timeline.effectiveTitleItems[0].animation.entrance == .fade)
    #expect(edited.timeline.effectiveTitleItems[0].explanation.contains { $0.contains("отклонено") })
}

@Test func fcpxmlCarriesEditableObjectMetadataAndFallbackSignal() throws {
    let asset = MediaAsset(
        originalURL: URL(fileURLWithPath: "/tmp/source.mov"),
        kind: .video,
        byteSize: 1,
        contentHash: "test",
        metadata: MediaMetadata(duration: 8, width: 1920, height: 1080, frameRate: 30, codec: "avc1", hasAudio: true)
    )
    let first = TimelineItem(assetID: asset.id, kind: .video, sourceDuration: 4, timelineStart: 0, timelineDuration: 4)
    let second = TimelineItem(assetID: asset.id, kind: .video, sourceStart: 4, sourceDuration: 4, timelineStart: 4, timelineDuration: 4, transition: TransitionStyle.zoom.rawValue)
    let effect = EffectTimelineItem(effectType: .filmGrain, startTime: 0, duration: 8, targetClipID: first.id)
    let title = TitleTimelineItem(
        kind: .wordLevelCaptions,
        text: "Вперёд",
        startTime: 1,
        duration: 1,
        words: [CaptionWord(word: "Вперёд", start: 0, end: 1)]
    )
    let transition = TimelineTransitionItem(style: .zoom, outgoingClipID: first.id, incomingClipID: second.id, startTime: 4)
    let timeline = Timeline(storyPlanID: UUID(), items: [first, second], effects: [effect], titleItems: [title], transitionItems: [transition])
    let exporter = FCPXMLExporter()
    let xml = try exporter.xml(timeline: timeline, assets: [asset])
    #expect(xml.contains("com.veloedit.effectObject"))
    #expect(xml.contains("com.veloedit.titleObject.words"))
    #expect(xml.contains("com.veloedit.transitionObject"))
    #expect(xml.contains("Вперёд"))
    #expect(exporter.requiresRenderedFallback(for: timeline))
}
