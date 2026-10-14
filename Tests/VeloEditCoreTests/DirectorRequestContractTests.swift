import Foundation
import Testing
@testable import VeloEditCore

@Test func naturalPlaybackSpeedDoesNotRequireSpeedingFootage() {
    let interpreter = PromptInterpreter()
    for prompt in ["Сохрани естественную скорость и порядок действий", "Без замедления, обычная скорость", "Keep natural playback speed"] {
        #expect(!interpreter.interpret(prompt: prompt, preset: .story).includeTags.contains("high-speed"))
        #expect(interpreter.interpret(prompt: prompt, preset: .story).pacing == PromptInterpreter.defaults(for: .story).pacing)
    }
    #expect(interpreter.interpret(prompt: "Спокойный монтаж. Без замедления", preset: .story).pacing < PromptInterpreter.defaults(for: .story).pacing)
    #expect(interpreter.interpret(prompt: "Быстрый темп. Без замедления", preset: .story).pacing > PromptInterpreter.defaults(for: .story).pacing)
    #expect(interpreter.interpret(prompt: "Покажи скоростную езду. Сохрани естественную скорость", preset: .story).includeTags.contains("high-speed"))
    #expect(interpreter.interpret(prompt: "Не показывай разгон. Сохрани естественную скорость", preset: .story).excludeTags.contains("high-speed"))
    #expect(!interpreter.interpret(prompt: "Не заполняй фильм случайной землёй, одеждой или поворотами камеры", preset: .story).includeTags.contains("turn"))
    #expect(!interpreter.interpret(prompt: "Без поворотов камеры", preset: .story).excludeTags.contains("turn"))
    #expect(interpreter.interpret(prompt: "Покажи повороты дороги. Без поворотов камеры", preset: .story).includeTags.contains("turn"))
    #expect(!interpreter.interpret(prompt: "Дай пейзажу время для наблюдения", preset: .story).includeTags.contains("people"))
    #expect(interpreter.interpret(prompt: "В начале наблюдение за пейзажем", preset: .story).preferredIntroTags?.contains("people") != true)
    #expect(interpreter.interpret(prompt: "Покажи живых людей и пейзажи", preset: .story).includeTags.contains("people"))
    #expect(interpreter.interpret(prompt: "Не показывай людей. Больше времени для наблюдения", preset: .story).excludeTags.contains("people"))
}

private func chapterFixture() -> (StoryPlan, Timeline) {
    let fishing = UUID(), riding = UUID(), firstScene = UUID(), secondScene = UUID()
    let candidates = (0..<5).map { _ in UUID() }
    let chapters = candidates.enumerated().map { index, id in
        StoryChapter(title: index < 3 ? "Рыбалка" : "Поездка на багги", candidateIDs: [id],
                     eventID: index < 3 ? fishing : riding, eventSceneID: index < 3 ? firstScene : secondScene,
                     chapterCardTitle: index == 1 ? "Рыбалка" : nil)
    }
    let plan = StoryPlan(prompt: "Титры: названия каждой части и ключевых событий.", preset: .adventure,
                         constraints: StoryConstraints(targetDuration: 15), chapters: chapters,
                         directorBrief: DirectorBrief(requestedDuration: 15, musicPolicy: .none, titlePolicy: .keyOnly))
    let items = candidates.enumerated().map { index, id in
        TimelineItem(candidateID: id, assetID: UUID(), kind: .video, sourceDuration: 3,
                     timelineStart: Double(index) * 3, timelineDuration: 3,
                     eventID: chapters[index].eventID, eventSceneID: chapters[index].eventSceneID)
    }
    var timeline = Timeline(storyPlanID: plan.id, items: items)
    timeline.titleItems = [TitleTimelineItem(kind: .chapter, text: "Рыбалка", startTime: 3, duration: 1.8,
        targetClipID: items[1].id, explanation: ["Editorial chapter: подтверждённая смена события/активности"])]
    return (plan, timeline)
}

@Test func questionnaireTitleRequirementSurvivesIntentParsing() {
    let prompt = "Формат: Горизонтальное 16:9. Точная длительность: 5 мин. Настроение: киношное. Музыка: подобрать под видео. Звук: приглушить звук исходников. Титры: названия каждой части и ключевых событий."
    let intents = IntentLedgerEngine.intents(prompt: prompt, brief: DirectorBrief(titlePolicy: .keyOnly), pending: [prompt], newAssetIDs: [])
    #expect(intents.contains(.addTitles))
    #expect(!intents.contains { if case .unverifiedInstruction = $0 { return true }; return false })
    let compound = IntentLedgerEngine.intents(prompt: "Добавь титры. Сделай неведомое действие", brief: nil,
                                             pending: ["Добавь титры. Сделай неведомое действие"], newAssetIDs: [])
    #expect(compound.contains(.addTitles))
    #expect(compound.contains { if case .unverifiedInstruction = $0 { return true }; return false })
    #expect(DirectorRequestContract.requiresStoryRebuild("Раздели рыбалку и багги на части и добавь музыку"))
}

@Test func chapterTitlesStartAtZeroAndEveryPartWithoutDependingOnNarrativeBeats() {
    let (plan, source) = chapterFixture()
    #expect(EditorialPresentationPolicy.missingChapterTitles(in: source, plan: plan).count == 2)
    let fixed = EditorialIntentEnforcer.enforce(source, plan: plan)
    #expect(fixed.effectiveTitleItems.map(\.startTime) == [0, 9])
    #expect(fixed.effectiveTitleItems.map(\.text) == ["Рыбалка", "Поездка на багги"])
    #expect(fixed.effectiveTitleItems.allSatisfy { $0.animation.entrance == .none })
    #expect(fixed.effectiveTitleItems.allSatisfy { $0.targetClipID == nil })
    #expect(EditorialPresentationPolicy.missingChapterTitles(in: fixed, plan: plan).isEmpty)
    #expect(EditorialIntentEnforcer.enforce(fixed, plan: plan).effectiveTitleItems == fixed.effectiveTitleItems)
    #expect(fixed.items == source.items)
    #expect(EditorialQualityGate().review(timeline: source, plan: plan, analyses: []).findings.contains { $0.kind == .unreadableTitle })
}

@Test func chapterRepairReanchorsAfterShorteningWithoutUndoingReadabilityFix() {
    let (plan, source) = chapterFixture()
    var timeline = EditorialIntentEnforcer.enforce(source, plan: plan)
    let originalIDs = timeline.effectiveTitleItems.map(\.id)
    for index in timeline.titleItems!.indices {
        timeline.titleItems![index].templateID = "title.minimal-clean.v1"
        timeline.titleItems![index].style.backgroundOpacity = 1
        timeline.titleItems![index].animation = TitleAnimation(entrance: .none, exit: .none, duration: 0)
        timeline.titleItems![index].explanation.append("Rendered OCR repair: high-contrast static title")
    }
    timeline.items[0].sourceDuration = 1.5
    timeline.items[0].timelineDuration = 1.5
    timeline.items = TimelineTiming.retimed(timeline.items)
    #expect(!EditorialPresentationPolicy.missingChapterTitles(in: timeline, plan: plan).isEmpty)
    let repaired = EditorialPresentationPolicy.ensuringChapterTitles(in: timeline, plan: plan, preserveExistingPresentation: true)
    #expect(repaired.effectiveTitleItems.map(\.id) == originalIDs)
    #expect(repaired.effectiveTitleItems.map(\.startTime) == [0, 7.5])
    #expect(EditorialPresentationPolicy.missingChapterTitles(in: repaired, plan: plan).isEmpty)
    #expect(repaired.effectiveTitleItems.allSatisfy { $0.style.backgroundOpacity == 1 })
    #expect(EditorialIntentEnforcer.enforce(repaired, plan: plan).effectiveTitleItems == repaired.effectiveTitleItems)
}

@Test func chapterHeadingReplacesOverlappingAutomaticOpenerButKeepsManualText() {
    let (plan, source) = chapterFixture()
    var timeline = source
    let automatic = TitleTimelineItem(kind: .chapter, text: "День 1 — Рыбалка", startTime: 0, duration: 6, explanation: ["Автоматическая глава события"])
    let manual = TitleTimelineItem(kind: .lowerThird, text: "Александр", startTime: 6, duration: 2)
    timeline.titleItems = timeline.effectiveTitleItems + [automatic, manual]
    let repaired = EditorialPresentationPolicy.ensuringChapterTitles(in: timeline, plan: plan)
    #expect(!repaired.effectiveTitleItems.contains { $0.id == automatic.id })
    #expect(repaired.effectiveTitleItems.contains(manual))
    #expect(repaired.effectiveTitleItems.filter { $0.startTime == 0 }.count == 1)
    #expect(EditorialPresentationPolicy.missingChapterTitles(in: repaired, plan: plan).isEmpty)
}

@Test func unknownPartStillGetsLabelAndRepeatedEventTitleSurvivesCleanup() {
    var (plan, timeline) = chapterFixture()
    for index in 3..<5 { plan.chapters[index].title = "Съёмка" }
    let fixed = EditorialPresentationPolicy.ensuringChapterTitles(in: timeline, plan: plan)
    #expect(fixed.effectiveTitleItems.count == 2)
    #expect(fixed.effectiveTitleItems.last?.startTime == 9)
    for index in 3..<5 { plan.chapters[index].title = "Рыбалка" }
    timeline = EditorialPresentationPolicy.ensuringChapterTitles(in: timeline, plan: plan)
    let cleaned = AutomatedTitlePolicy.reviewed(
        timeline.effectiveTitleItems,
        timelineDuration: timeline.duration,
        containmentByTitleID: AutomatedTitlePolicy.inferredContainmentByTitleID(
            timeline.effectiveTitleItems,
            timeline: timeline
        )
    ).titles
    #expect(cleaned.count == 2)
    #expect(cleaned.map(\.startTime) == [0, 9])
}

@Test func tooShortPartCannotSilentlyPassTitleContract() {
    var (plan, timeline) = chapterFixture()
    timeline.items = Array(timeline.items.prefix(1))
    timeline.items[0].sourceDuration = 0.8
    timeline.items[0].timelineDuration = 0.8
    plan.constraints.targetDuration = 0.8
    let validation = TimelineDeliveryContract().validateAndRepair(timeline: timeline, plan: plan, assets: [])
    #expect(validation.blockingIssues.contains { $0.kind == .titlePolicy })
}

@Test func cinematicMoodDoesNotAuthorizeCutawaysOrColorChanges() {
    #expect(!DirectorRequestContract.requestsCutaways("Киношный динамичный фильм"))
    #expect(!DirectorRequestContract.requestsColorCorrection("Настроение: киношное"))
    #expect(!DirectorRequestContract.requestsEffects("Без эффектов и цветокоррекции"))
    #expect(DirectorRequestContract.requestsCutaways("Добавь перебивки внутри сцены"))
    #expect(!DirectorRequestContract.requestsCutaways("Добавь перебивки. Теперь без перебивок"))
    #expect(DirectorRequestContract.requestsColorCorrection("Примени цветокоррекцию"))
    let (plan, source) = chapterFixture()
    var timeline = source
    var overlay = source.items[3]
    overlay.id = UUID()
    overlay.overlay = OverlaySettings(style: .cutaway, baseItemID: source.items[0].id)
    timeline.items.append(overlay)
    #expect(EditorialIntentEnforcer.enforce(timeline, plan: plan).items == source.items)
}

@Test func genericOutdoorTagsDoNotAuthorizeCrossEventCutaway() {
    let (plan, timeline) = chapterFixture()
    let base = timeline.items[0]
    let foreign = Candidate(id: timeline.items[3].candidateID!, assetID: timeline.items[3].assetID!, sourceStart: 0,
                            sourceDuration: 3, scores: ClipScores(quality: 0.9, interest: 0.9, action: 0.2, stability: 0.9),
                            tags: ["people", "outdoor", "sky"])
    #expect(!EditorialCutawayPolicy.allows(foreign, over: base, plan: plan, analyses: []))
    var same = foreign
    same.id = UUID()
    same.assetID = base.assetID!
    #expect(EditorialCutawayPolicy.allows(same, over: base, plan: plan, analyses: []))
}

@Test func generationDoesNotReplayMusicSelectionFromPendingQuestionnaire() {
    let commands = EditorCommandParser().parse("Музыка: подобрать под видео. Приглуши звук исходников", preset: .adventure)
    #expect(commands.contains { $0.semanticCategory == "music" })
    let retained = DirectorRequestContract.commandsAfterGeneration(commands)
    #expect(!retained.contains { $0.semanticCategory == "music" })
    #expect(retained == commands.filter { $0.semanticCategory != "music" && $0.semanticCategory != "telemetry" })
}

@Test func creativeBriefCannotSlowEveryShotOrDissolveEveryCut() {
    let prompt = "Собери законченный фильм об этой поездке длительностью от 2 до 3 минут. Используй осмысленные склейки по действию. Плавные переходы и замедления применяй только там, где они помогают рассказу и подходят исходникам. Нужен цельный фильм, а не демонстрация эффектов."
    let commands = DirectorRequestContract.commandsAfterGeneration(prompt: prompt)
    #expect(commands.isEmpty)
    let items = (0..<2).map { TimelineItem(assetID: UUID(), kind: .video, sourceDuration: 75,
        timelineStart: Double($0) * 75, timelineDuration: 75) }
    let original = Timeline(storyPlanID: UUID(), items: items)
    let result = EditorCommandExecutor().apply(commands, to: original).timeline
    #expect(result.items == original.items)
    #expect(AutomaticFilmDurationPolicy.renderedDuration(of: result) == 150)
}

@Test(arguments: [
    "Замедли все клипы в 2 раза, если это уместно",
    "Если это уместно, замедли все клипы в 2 раза",
    "Замедление вообще не в тему. Переходы мне не нравятся",
    "Не надо замедлять весь фильм",
    "Добавь эффект камеры в первом видео, но только если он подходит"
])
func conditionalAndNegativeFeedbackCannotBecomeGlobalCommands(prompt: String) {
    #expect(DirectorRequestContract.commandsAfterGeneration(prompt: prompt).isEmpty)
}

@Test func preciseInstructionsInsideBriefKeepTheirScopeAndDecimalValues() {
    let prompt = "Собери фильм о поездке. Замедли первый клип в 2 раза. Установи скорость 1.5 во втором клипе."
    #expect(DirectorRequestContract.commandsAfterGeneration(prompt: prompt) == [.setSpeed(0.5, .first), .setSpeed(1.5, .number(2))])
    #expect(DirectorRequestContract.commandsAfterGeneration(prompt: "Замедли все клипы в 2 раза") == [.setSpeed(0.5, .all)])
    #expect(DirectorRequestContract.commandsAfterGeneration(prompt: "Убери замедление во всех клипах") == [.removeSlowMotion(.all)])
    #expect(!DirectorRequestContract.requestsSlowMotion("Замедление вообще не в тему"))
    #expect(!PromptInterpreter().interpret(prompt: "Замедление вообще не в тему", preset: .story).allowSlowMotion)
}

@Test func questionnaireSourceAudioRemainsExplicitWithoutLooseTimelineCommands() {
    let commands = DirectorRequestContract.commandsAfterGeneration(prompt:
        "Настроение: киношное. Музыка: подобрать под видео. Звук: приглушить звук исходников.")
    #expect(commands == [.setOriginalAudioVolume(0.20)])
}
