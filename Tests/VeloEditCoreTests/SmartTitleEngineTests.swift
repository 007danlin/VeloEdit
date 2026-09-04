import Foundation
import Testing
@testable import VeloEditCore

@Test func smartTitleReadinessCoversAtLeastTenConcreteScenes() throws {
    let scenarios: [(Set<String>, String)] = [
        (["buggy", "off-road"], "Поездка на багги"),
        (["cycling", "bicycle"], "Велопрогулка"),
        (["sunset", "cottage"], "Закат"),
        (["morning", "lake"], "Утро у озера"),
        (["mountain", "travel"], "Поездка в горы"),
        (["fishing", "river"], "Рыбалка"),
        (["rafting", "kayak"], "Сплав"),
        (["cottage", "family"], "Поездка на дачу"),
        (["hiking", "trail"], "Поход"),
        (["walk", "embankment"], "Прогулка по набережной"),
        (["birthday", "family"], "День рождения"),
        (["campfire", "night"], "Вечер у костра"),
        (["motorcycle"], "Мотопоездка"),
        (["running"], "Пробежка"),
        (["swimming"], "Плавание"),
        (["skiing"], "На склоне"),
        (["surfing"], "Сёрфинг"),
        (["climbing"], "Скалолазание"),
        (["horse riding"], "Конная прогулка")
    ]
    let decisions = scenarios.compactMap { tags, _ in
        SmartTitleEngine().decide(SmartTitleContext(purpose: .activity, tags: tags))
    }
    #expect(decisions.count == scenarios.count)
    #expect(Set(decisions.map(\.primaryText)).count == scenarios.count)
    for (decision, scenario) in zip(decisions, scenarios) {
        #expect(decision.primaryText == scenario.1)
        #expect(!SmartTitleEngine.isMeaningless(decision.primaryText))
        #expect(TitleTemplateRegistry.template(id: decision.templateID) != nil)
    }
}

@Test func smartTitleUsesHierarchyDateAndReliableLocationWithoutInventingFacts() throws {
    let calendar = Calendar(identifier: .gregorian)
    let date = try #require(calendar.date(from: DateComponents(year: 2026, month: 4, day: 16)))
    let chapter = try #require(SmartTitleEngine().decide(SmartTitleContext(
        purpose: .chapter,
        tags: ["cycling", "bicycle"],
        locationName: "Красногорск",
        locationConfidence: 0.91,
        captureDate: date,
        dateAddsContext: true,
        sequenceIndex: 3,
        sequenceCount: 4
    )))
    #expect(chapter.primaryText == "День 3 — Велопрогулка")
    #expect(chapter.secondaryText?.contains("Красногорск") == true)
    #expect(chapter.secondaryText?.contains("16 апреля 2026") == true)
    #expect(TitleTemplateRegistry.template(id: chapter.templateID)?.category == .chapterTitles)

    let reliable = SmartTitleEngine().decide(SmartTitleContext(
        purpose: .location,
        locationName: "Сочи",
        locationConfidence: 0.88
    ))
    #expect(reliable?.primaryText == "Сочи")
    #expect(TitleTemplateRegistry.template(id: reliable?.templateID)?.category == .locationTitles)

    let unknown = SmartTitleEngine().decide(SmartTitleContext(
        purpose: .location,
        locationName: "GPS 43.5, 39.7",
        locationConfidence: 0.20
    ))
    #expect(unknown == nil)
}

@Test func smartTitleRejectsMeaninglessAITextAndUsesSceneEvidenceInstead() throws {
    let banned = [
        "Ключевой момент", "Важный момент", "Яркий момент", "Незабываемый момент",
        "Захватывающая сцена", "Приключение", "Эмоциональный момент"
    ]
    for text in banned {
        #expect(SmartTitleEngine.isMeaningless(text))
        let decision = try #require(SmartTitleEngine().decide(SmartTitleContext(
            purpose: .activity,
            requestedText: text,
            tags: ["cycling"]
        )))
        #expect(decision.primaryText == "Велопрогулка")
    }
    #expect(SmartTitleEngine().decide(SmartTitleContext(purpose: .activity, requestedText: "Ключевой момент")) == nil)
}

@Test func contentConfirmedActivityTitleIgnoresStructuralOrInventedSceneNames() throws {
    #expect(SmartTitleEngine.isStructuralPlaceholder("Пик маршрута"))
    #expect(SmartTitleEngine.isStructuralPlaceholder("В движении"))
    #expect(SmartTitleEngine().contentConfirmedActivityTitle(tags: ["outdoor", "land"]) == nil)

    let buggy = try #require(SmartTitleEngine().contentConfirmedActivityTitle(
        tags: ["buggy", "dirt_road", "helmet"]
    ))
    #expect(buggy.primaryText == "Багги")

    let sourceGroupBuggy = try #require(SmartTitleEngine().contentConfirmedActivityTitle(
        tags: ["bicycle", "vehicle", "car", "dirt_road", "wheel", "helmet"],
        proposedTitle: "Багги",
        provenanceConfidence: 0.82
    ))
    #expect(sourceGroupBuggy.primaryText == "Багги")
    let uncorroborated = SmartTitleEngine().contentConfirmedActivityTitle(
        tags: ["bicycle", "outdoor"],
        proposedTitle: "Багги",
        provenanceConfidence: 0.82
    )
    #expect(uncorroborated?.primaryText == "Велопрогулка")
}

@Test func automatedTitleQualityGateEnforcesProvenanceContainmentAndOneTrack() {
    func automatic(_ text: String, start: Double, duration: Double) -> TitleTimelineItem {
        TitleTimelineItem(
            kind: .title,
            text: text,
            startTime: start,
            duration: duration,
            explanation: ["Автоматическая глава события использует существующий шаблон"]
        )
    }
    let cycling = automatic("Велопрогулка", start: 0, duration: 4)
    let duplicate = automatic("Велопрогулка", start: 1, duration: 3)
    let buggy = automatic("Багги", start: 1.5, duration: 4)
    let structural = automatic("Кульминация", start: 5, duration: 2)
    let review = AutomatedTitlePolicy.reviewed(
        [cycling, duplicate, buggy, structural],
        timelineDuration: 7,
        containmentByTitleID: [
            cycling.id: 0...2,
            duplicate.id: 0...2,
            buggy.id: 2...5,
            structural.id: 5...7
        ]
    )

    #expect(review.titles.map(\.text) == ["Велопрогулка", "Багги"])
    #expect(review.titles[0].startTime >= 0 && review.titles[0].endTime <= 2)
    #expect(review.titles[1].startTime >= 2 && review.titles[1].endTime <= 5)
    #expect(review.titles[0].endTime <= review.titles[1].startTime)
    #expect(review.diagnostics.contains { $0.code == "adjacent-duplicate" })
    #expect(review.diagnostics.contains { $0.code == "unconfirmed-text" })
    #expect(review.diagnostics.contains { $0.code == "repaired-placement" })
}

@Test func smartTitleRespectsTemplateTextLimitsAndDisambiguatesChronology() throws {
    let long = try #require(SmartTitleEngine().decide(SmartTitleContext(
        purpose: .filmOpening,
        requestedText: "Поездка с друзьями в Сочи на майские праздники 2026 года",
        preferredTemplateID: "title.minimal-clean.v1"
    )))
    let template = try #require(TitleTemplateRegistry.template(id: long.templateID))
    #expect(long.primaryText.count <= template.textConstraints.maxCharacters)
    #expect(long.primaryText.contains("Сочи"))

    let duplicate = try #require(SmartTitleEngine().decide(SmartTitleContext(
        purpose: .chapter,
        tags: ["cycling"],
        locationName: "Красногорск",
        locationConfidence: 0.9,
        usedTitles: ["Велопрогулка"]
    )))
    #expect(duplicate.primaryText == "Велопрогулка — Красногорск")
}

@Test func semanticTemplateSelectionUsesExistingCategoryAndSubjectAvoidance() throws {
    let dynamic = try #require(SmartTitleEngine().decide(SmartTitleContext(
        purpose: .activity,
        tags: ["buggy", "action", "high-speed"]
    )))
    #expect(TitleTemplateRegistry.template(id: dynamic.templateID)?.category == .dynamicKinetic)

    let subject = NormalizedRegion(x: 0.62, y: 0.28, width: 0.32, height: 0.55)
    let protected = try #require(SmartTitleEngine().decide(SmartTitleContext(
        purpose: .shortLabel,
        tags: ["cycling"],
        avoidRegions: [subject]
    )))
    #expect(protected.explanation.contains { $0.contains("важных объектов") })
    #expect(TitleTemplateRegistry.template(id: protected.templateID) != nil)
}

@Test func timelineComposerProducesTemplateTitlesInsteadOfLegacyTitleCards() throws {
    let eventID = UUID()
    let sceneID = UUID()
    let asset = MediaAsset(
        originalURL: URL(fileURLWithPath: "/tmp/cycling.mov"),
        kind: .video,
        byteSize: 10,
        contentHash: "cycling",
        metadata: MediaMetadata(duration: 20, creationDate: Date(timeIntervalSince1970: 1_776_297_600))
    )
    let candidate = Candidate(
        assetID: asset.id,
        sourceStart: 0,
        sourceDuration: 12,
        scores: ClipScores(quality: 0.9, interest: 0.9, action: 0.72, stability: 0.88, uniqueness: 0.8),
        tags: ["cycling", "bicycle"],
        insights: CandidateInsights(sceneSummary: "велопрогулка в парке")
    )
    let analysis = AnalysisResult(assetID: asset.id, analyzedContentHash: asset.contentHash, candidates: [candidate])
    let chapter = StoryChapter(
        title: "Велопрогулка",
        candidateIDs: [candidate.id],
        role: .intro,
        eventID: eventID,
        eventSceneID: sceneID,
        chapterCardTitle: "Велопрогулка"
    )
    let story = EventStoryPlan(
        projectTitle: "Моё лето",
        entries: [EventStoryEntry(eventID: eventID, title: "Велопрогулка", startDate: asset.metadata.creationDate, endDate: asset.metadata.creationDate, allocatedDuration: 12, quality: 0.9, sceneIDs: [sceneID])],
        chapterCardsEnabled: true
    )
    let plan = StoryPlan(prompt: "Летний фильм", preset: .summerFilm, constraints: StoryConstraints(targetDuration: 20), chapters: [chapter], eventStory: story)
    let timeline = TimelineComposer().compose(plan: plan, assets: [asset], analyses: [analysis])

    #expect(timeline.items.allSatisfy { $0.kind != .title })
    #expect(timeline.effectiveTitleItems.count == 2)
    #expect(timeline.effectiveTitleItems.allSatisfy { $0.templateID != nil })
    #expect(timeline.effectiveTitleItems.allSatisfy { TitleTemplateRegistry.template(for: $0) != nil })
}
