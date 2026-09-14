import Foundation
import Testing
@testable import VeloEditCore

@Test(arguments: ["Добавь титры", "Сделай ролик с титрами", "Add a title", "Include captions"])
func titleRecoveryRecognizesExplicitRequests(prompt: String) {
    #expect(EditorialIntentEnforcer.requestsAdditionalTitles(prompt))
    #expect(IntentLedgerEngine.intents(prompt: prompt, brief: nil, pending: [], newAssetIDs: []).contains(.addTitles))
}

@Test(arguments: ["Добавь музыку. Титры оставить как есть", "Добавь музыку, титры не нужны", "Убрать титры", "Do not add titles", "Without captions", "Количество титров изменено — примените правки к фильму"])
func titleRecoveryDoesNotInventAdditionFromUnrelatedInstructions(prompt: String) {
    #expect(!EditorialIntentEnforcer.requestsAdditionalTitles(prompt))
    #expect(!IntentLedgerEngine.intents(prompt: prompt, brief: nil, pending: [prompt], newAssetIDs: []).contains(.addTitles))
}

@Test func titleRecoveryUsesLatestInstructionAndUpdatesBriefBothWays() {
    let removed = "Добавь титры\nТеперь без титров"
    let added = "Без титров\nТеперь добавь титры"
    #expect(EditorialIntentEnforcer.titleRequest(removed) == false)
    #expect(EditorialIntentEnforcer.titleRequest(added) == true)
    #expect(!IntentLedgerEngine.intents(prompt: "Без титров", brief: nil, pending: ["Добавь титры"], newAssetIDs: []).contains(.addTitles))
    #expect(EditorialIntentEnforcer.updatedBrief(DirectorBrief(titlePolicy: .minimal), prompt: removed)?.titlePolicy == DirectorTitlePolicy.none)
    #expect(EditorialIntentEnforcer.updatedBrief(DirectorBrief(titlePolicy: .none), prompt: added)?.titlePolicy == .minimal)
    #expect(EditorialIntentEnforcer.updatedBrief(DirectorBrief(titlePolicy: .keyOnly), prompt: "Добавь титры для всех частей")?.titlePolicy == .keyOnly)
    let plan = StoryPlan(prompt: added, preset: .memories, constraints: StoryConstraints(targetDuration: 5), chapters: [])
    #expect(!ExplicitDeliveryRequirements(plan: plan).forbidsTitles)
}

@Test(arguments: [[TimelineItemKind.photo], [.video], [.photo, .video]])
func titleRecoveryBuildsReadableOpeningWithoutNarrativeAnalysis(kinds: [TimelineItemKind]) {
    let plan = StoryPlan(prompt: "Добавь титры", preset: .memories, constraints: StoryConstraints(targetDuration: 5), chapters: [])
    let items = kinds.enumerated().map { index, kind in
        TimelineItem(assetID: UUID(), kind: kind, sourceDuration: 3, timelineStart: Double(index) * 3, timelineDuration: 3)
    }
    let source = Timeline(storyPlanID: plan.id, items: items)
    let result = EditorialIntentEnforcer.enforce(source, plan: plan)
    #expect(EditorialPresentationPolicy.hasReadableTitle(in: result))
    #expect(result.items == source.items)
    #expect(EditorialIntentEnforcer.enforce(result, plan: plan).effectiveTitleItems == result.effectiveTitleItems)
    // Recreating the same opening must not reject a whole successful film.
    #expect(IntentLedgerEngine.validate(.addTitles, timeline: result, previous: result, analyses: [], assets: []).0 == .fulfilled)
}

@Test func titleRecoveryRejectsInvisibleAndUnreadableTitles() {
    let item = TimelineItem(assetID: UUID(), kind: .photo, sourceDuration: 5, timelineStart: 0, timelineDuration: 5)
    var timeline = Timeline(storyPlanID: UUID(), items: [item])
    let titles = [
        TitleTimelineItem(kind: .title, text: "Текст", startTime: 0, duration: 3, enabled: false),
        TitleTimelineItem(kind: .title, text: " \n ", startTime: 0, duration: 3),
        TitleTimelineItem(kind: .title, text: "Текст", startTime: 8, duration: 3),
        TitleTimelineItem(kind: .title, text: "Текст", startTime: 4.5, duration: 3),
        TitleTimelineItem(kind: .title, text: "Текст", startTime: 0, duration: 0.5)
    ]
    for title in titles {
        timeline.titleItems = [title]
        #expect(IntentLedgerEngine.validate(.addTitles, timeline: timeline, previous: nil, analyses: [], assets: []).0 == .recoverableFailure)
        let plan = StoryPlan(prompt: "Добавь титры", preset: .memories, constraints: StoryConstraints(targetDuration: 5), chapters: [])
        #expect(EditorialPresentationPolicy.hasReadableTitle(in: EditorialIntentEnforcer.enforce(timeline, plan: plan)))
    }
}
