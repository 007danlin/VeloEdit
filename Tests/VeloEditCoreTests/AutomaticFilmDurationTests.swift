import Foundation
import Testing
@testable import VeloEditCore

struct AutomaticFilmDurationTests {
    @Test(arguments: [0.0, 2.0, 5.0, 9.5, 10.0, 30.0])
    func requestedRuntimeHasTenSecondFloor(_ requested: Double) {
        let expected = max(10, requested)
        #expect(DirectorBrief(requestedDuration: requested).requestedDuration == expected)
        #expect(StoryConstraints(targetDuration: requested).targetDuration == expected)
        #expect(PromptInterpreter().interpret(prompt: "Сделай фильм на \(requested) секунд", preset: .story).targetDuration == expected)
    }

    @Test func oldConstraintValuesCannotBypassPromptNormalization() {
        var legacy = StoryConstraints()
        legacy.targetDuration = 5
        #expect(PromptInterpreter().interpret(prompt: "Сделай спокойнее", preset: .story, base: legacy).targetDuration == 10)
        #expect(AutomaticFilmDurationPolicy.normalizedRequest(.nan) == 10)
    }

    @Test func deliveryMeasuresTheRenderedRuntimeAfterTransitions() throws {
        let short = montage(totalDuration: 10, overlap: 0.5)
        #expect(short.duration == 10)
        #expect(AutomaticFilmDurationPolicy.renderedDuration(of: short) == 9.5)
        let plan = StoryPlan(prompt: "Короткий фильм", preset: .story, constraints: .init(targetDuration: 10), chapters: [])
        let blocked = TimelineDeliveryContract().validateAndRepair(timeline: short, plan: plan, assets: [])
        #expect(blocked.blockingIssues.contains { $0.kind == .minimumDuration })
        #expect(!blocked.canPersist)
        #expect(throws: EditorialGenerationError.self) { try AutomaticFilmDurationPolicy.validate(short) }

        let valid = montage(totalDuration: 10.5, overlap: 0.5)
        #expect(AutomaticFilmDurationPolicy.renderedDuration(of: valid) == 10)
        #expect(TimelineDeliveryContract().validateAndRepair(timeline: valid, plan: plan, assets: []).canPersist)
        try AutomaticFilmDurationPolicy.validate(valid)
        // A one-frame shortfall may not be rounded up to a successful film.
        #expect(!AutomaticFilmDurationPolicy.meetsMinimum(montage(totalDuration: 10 - 1 / 30.0)))
    }

    @Test func selectorRejectsShortVariantsEvenWithoutEditorialReview() throws {
        let plan = StoryPlan(prompt: "Короткий фильм", preset: .story, constraints: .init(targetDuration: 10), chapters: [])
        let shortStory = StoryPlanVariant(plan: plan, strategy: "too-short", seedScore: 1)
        let validStory = StoryPlanVariant(plan: plan, strategy: "ten-seconds", seedScore: 0.5)
        let short = montage(totalDuration: 9)
        #expect(MontageVariantSelector().select(stories: [shortStory], timelines: [short], assets: [], analyses: []) == nil)
        let winner = try #require(MontageVariantSelector().select(stories: [shortStory, validStory], timelines: [short, montage(totalDuration: 10)], assets: [], analyses: []))
        #expect(winner.story.strategy == "ten-seconds")
    }

    @Test func compromisedBudgetCannotAuthorizeASubTenSecondFilm() {
        let timeline = montage(totalDuration: 8)
        var plan = StoryPlan(prompt: "Короткий фильм", preset: .story, constraints: .init(targetDuration: 10), chapters: [])
        plan.contentBudget = .init(budget: .init(idealDuration: 8, safeRange: 6...8, absoluteCeiling: 8,
            strongUnitCount: 1, distinctEventCount: 1, distinctSceneCount: 1, distinctShotFamilyCount: 1,
            usableActionSeconds: 8, usableAtmosphereSeconds: 0, usableSpeechSeconds: 0, confidence: 1, limitingFactors: [.insufficientContent]),
            requestedDuration: 10, supportedDuration: 8, durationConstraintStatus: .compromisedInsufficientContent,
            requiresExpandedMining: false, feasibility: 0.8, reason: "All material inspected")
        let review = EditorialQualityGate().review(timeline: timeline, plan: plan, analyses: [])
        #expect(review.findings.contains { $0.kind == .durationUnderflow && $0.severity == 3 })
        #expect(!review.rankingEligible)
        #expect(review.evidenceDomains?.first { $0.domain == .contentBudgetLowerBound }?.status == .failed)
    }

    private func montage(totalDuration: Double, overlap: Double = 0) -> Timeline {
        let first = TimelineItem(assetID: UUID(), kind: .video, sourceDuration: totalDuration / 2,
                                 timelineStart: 0, timelineDuration: totalDuration / 2)
        let second = TimelineItem(assetID: UUID(), kind: .video, sourceDuration: totalDuration / 2,
                                  timelineStart: totalDuration / 2, timelineDuration: totalDuration / 2)
        let transitions: [TimelineTransitionItem] = overlap > 0 ? [
            .init(style: .crossDissolve, outgoingClipID: first.id, incomingClipID: second.id,
                  startTime: totalDuration / 2, duration: overlap)
        ] : []
        return Timeline(storyPlanID: UUID(), items: [first, second], transitionItems: transitions)
    }
}
