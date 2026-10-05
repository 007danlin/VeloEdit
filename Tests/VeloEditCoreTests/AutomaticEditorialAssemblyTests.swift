import Foundation
import Testing
@testable import VeloEditCore

@Suite struct AutomaticEditorialAssemblyTests {
    private func candidate(asset: UUID, start: Double, tag: String, atmosphere: Bool = true) -> Candidate {
        var insights = CandidateInsights(sceneSummary: tag, dynamics: 0.5, sharpness: 0.9, exposureQuality: 0.9)
        insights.editorialEvidence = EditorialEvidence(usableRange: .init(start: start, end: start + 10), informationGain: 0.5, entryQuality: 0.9, exitQuality: 0.9, atmosphereValue: atmosphere ? 0.8 : 0, background: tag, confidence: 0.9)
        return Candidate(assetID: asset, sourceStart: start, sourceDuration: 10, scores: .init(quality: 0.9, interest: 0.9, action: 0.4, stability: 0.9, uniqueness: 0.9), tags: [tag], insights: insights)
    }
    private func analyses(_ candidates: [Candidate]) -> [AnalysisResult] {
        Dictionary(grouping: candidates, by: \.assetID).map { .init(assetID: $0.key, analyzedContentHash: "fixture", sceneTags: [], candidates: $0.value) }
    }
    private func fixture() -> (Timeline, StoryPlan, [AnalysisResult], [Event]) {
        let cameras = [UUID(), UUID()]
        let candidates = cameras.enumerated().flatMap { camera, id in
            (0..<3).map { candidate(asset: id, start: Double($0 * 20), tag: "camera-\(camera)-place-\($0)") }
        }
        let scenes = cameras.map { asset in EventScene(title: "Поход", assetIDs: [asset], candidateIDs: candidates.filter { $0.assetID == asset }.map(\.id), tags: ["hiking"]) }
        let events = [Event(title: "Поход", assetIDs: cameras, scenes: scenes)]
        let context = EditorialAnalysisContext(analyses: analyses(candidates), events: events)
        var plan = StoryPlan(prompt: "Фильм ровно 42 секунды", preset: .adventure, constraints: .init(targetDuration: 42),
            chapters: [StoryChapter(title: "Поход", candidateIDs: [candidates[0].id], eventID: events[0].id, eventSceneID: scenes[0].id)],
            directorBrief: .init(requestedDuration: 42, mood: .dynamic, musicPolicy: .none, titlePolicy: .keyOnly))
        plan.contentBudget = ContentBudgetEngine().budget(units: context.units, families: context.families, requestedDuration: 42, requestIsExplicit: true, style: .init())
        plan.narrativeBeatPlan = NarrativeBeatPlan(pattern: .eventChapters, beats: [], reasons: [])
        let items = candidates.enumerated().map { index, c in TimelineItem(candidateID: c.id, assetID: c.assetID, kind: .video, sourceStart: c.sourceStart, sourceDuration: 4, timelineStart: Double(index * 4), timelineDuration: 4) }
        return (Timeline(storyPlanID: plan.id, items: items), plan, analyses(candidates), events)
    }

    @Test func exactMeasuredDurationPreservesSourceOrderAndRepairsLateChapterCoverage() {
        let (timeline, plan, analysis, events) = fixture()
        let result = AutomaticEditorialAssembly.prepare(timeline: timeline, plan: plan, analyses: analysis, events: events)
        #expect(abs(result.timeline.duration - 42) < 0.001)
        #expect(result.timeline.items.count == 6)
        #expect(result.timeline.items.allSatisfy { $0.timelineDuration <= 8 && $0.sourceDuration == $0.timelineDuration && $0.speed == 1 })
        #expect(result.timeline.items.map(\.assetID) == timeline.items.map(\.assetID))
        for queue in Dictionary(grouping: result.timeline.items, by: \.assetID).values {
            #expect(queue.map(\.sourceStart) == queue.map(\.sourceStart).sorted())
        }
        #expect(result.plan.chapters.count == 1)
        #expect(Set(result.plan.chapters.flatMap(\.candidateIDs)) == Set(timeline.items.compactMap(\.candidateID)))
        #expect(result.timeline.effectiveTitleItems.map(\.text) == ["Поход"])
        #expect(result.timeline.effectiveTitleItems[0].style.fontSize == 72)
        #expect(result.plan.exactDurationRequirement == 42)
        #expect(result.plan.constraints.targetDuration == 42)
        let review = EditorialQualityGate().review(timeline: result.timeline, plan: result.plan, analyses: analysis)
        #expect(!review.findings.contains { [.mechanicalCadence, .hardDuplicate, .durationPadding, .shotFamilyRunTooLong, .falseNarrativeRole].contains($0.kind) })
    }

    @Test func duplicateFastPathPreservesOverlapAndInformationThresholds() {
        let clusterer = ShotFamilyClusterer(), asset = UUID()
        let a = EditorialUnit(candidate: candidate(asset: asset, start: 0, tag: "shore"))
        for sameSource in [true, false] {
            for start in [0.0, 0.03, 0.07, 1, 5, 8.2, 9, 10, 20] {
                for information in [0.0, 0.119, 0.12, 0.8] {
                    var b = EditorialUnit(candidate: candidate(asset: sameSource ? asset : UUID(), start: start, tag: "shore"))
                    b.evidence.informationGain = information
                    for adjacent in [true, false] {
                        let pair = clusterer.similarity(a, b)
                        let priorRule = (sameSource && (abs(a.sourceRange.start - b.sourceRange.start) <= 2.0 / 30 || pair.sourceOverlap >= (adjacent ? 0.18 : 0.90)))
                            || (pair.combined >= 0.92 && !clusterer.addsState(b, after: a) && information < 0.12)
                        #expect(clusterer.isHardDuplicate(a, b, adjacent: adjacent) == priorRule)
                    }
                }
            }
        }
    }

    @Test func staleAutomaticSceneNameCannotSupplyItsOwnEvidence() {
        let asset = UUID()
        var shot = candidate(asset: asset, start: 0, tag: "forest")
        shot.tags.insert("research")
        let scene = EventScene(title: "У моря", assetIDs: [asset], candidateIDs: [shot.id], tags: shot.tags)
        let event = Event(title: "У моря", assetIDs: [asset], scenes: [scene])
        let plan = StoryPlan(prompt: "Фильм", preset: .adventure, constraints: .init(targetDuration: 5),
                             chapters: [StoryChapter(title: "У моря", candidateIDs: [shot.id])])
        let timeline = Timeline(storyPlanID: plan.id, items: [TimelineItem(candidateID: shot.id, assetID: asset,
            kind: .video, sourceStart: 0, sourceDuration: 5, timelineStart: 0, timelineDuration: 5)])
        let revised = AutomaticEditorialAssembly.reconcile(timeline: timeline, plan: plan,
            analyses: analyses([shot]), events: [event])
        #expect(revised.chapters.map(\.title) == ["На природе"])
    }

    @Test func approvedReferenceRestoresSourceLabelsAndOrderWithoutCopyingItsCuts() throws {
        let (timeline, plan, analysis, events) = fixture()
        let assets = analysis.enumerated().map { index, a in
            MediaAsset(id: a.assetID, originalURL: URL(fileURLWithPath: "/tmp/source-\(index).mov"), kind: .video,
                byteSize: 1, contentHash: "content-\(index)", metadata: .init(duration: 60, width: 1920, height: 1080))
        }
        var approved = timeline
        approved.items = [TimelineItem(assetID: assets[1].id, kind: .video, sourceStart: 1, sourceDuration: 5, timelineStart: 0, timelineDuration: 5),
                          TimelineItem(assetID: assets[0].id, kind: .video, sourceStart: 1, sourceDuration: 5, timelineStart: 5, timelineDuration: 5)]
        approved.titleItems = ["Сплав по реке", "Привал у реки"].enumerated().map { index, text in
            TitleTimelineItem(kind: .chapter, templateID: "title.minimal-clean.v1", text: text, startTime: Double(index * 5), duration: 3.5,
                style: EditorialPresentationPolicy.compactChapterStyle, animation: .init(entrance: .none, exit: .none, duration: 0))
        }
        let reference = try #require(ChapterTitleReference(name: "Идеал", timeline: approved, assets: assets))
        let roundtrip = try JSONDecoder.veloEdit.decode(ChapterTitleReference.self, from: JSONEncoder.veloEdit.encode(reference))
        let configured = roundtrip.applying(to: plan, assets: assets)
        let result = AutomaticEditorialAssembly.prepare(timeline: timeline, plan: configured, analyses: analysis, events: events)
        #expect(result.timeline.items.count == 6)
        #expect(abs(result.timeline.duration - 42) < 0.001)
        #expect(result.timeline.items.first?.assetID == assets[1].id)
        #expect(result.timeline.effectiveTitleItems.map(\.text) == ["Сплав по реке", "Привал у реки"])
        #expect(result.timeline.effectiveTitleItems.allSatisfy { $0.style == reference.style && $0.duration == 3.5 })
        // A renamed/reimported source is identified by its content, while
        // unrelated footage never inherits a reference activity label.
        var reimported = assets[0]; reimported.id = UUID()
        var unrelated = assets[1]; unrelated.contentHash = "new-content"
        let rebound = reference.applying(to: plan, assets: [reimported, unrelated])
        #expect(rebound.approvedSourceChapterLabels?[reimported.id]?.text == "Привал у реки")
        #expect(rebound.approvedSourceChapterLabels?[unrelated.id] == nil)
    }

    @Test func similarCameraPairSharesRunBudgetBeforeExactAllocation() {
        let candidates = [candidate(asset: UUID(), start: 0, tag: "scene"), candidate(asset: UUID(), start: 20, tag: "scene")]
        let units = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, EditorialUnit(candidate: $0)) })
        let items = candidates.map { TimelineItem(candidateID: $0.id, assetID: $0.assetID, kind: .video, sourceStart: $0.sourceStart, sourceDuration: 8, timelineStart: 0, timelineDuration: 8) }
        let slots = AutomaticEditorialAssembly.slots(items: items, units: units, maximumShot: 8, fps: 30, pacing: 0.8)
        let limited = AutomaticEditorialAssembly.limitedRuns(slots, families: Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, "same-camera-setup") }), fps: 30)
        #expect(limited.count == 2)
        #expect(limited.reduce(0) { $0 + $1.capacity } == 360)
        #expect(limited.allSatisfy { $0.capacity >= $0.frames })
    }

    @Test func overlappingEvidenceIsNeverCountedOrPlayedTwice() {
        let asset = UUID()
        let candidates = [candidate(asset: asset, start: 0, tag: "river"), candidate(asset: asset, start: 5, tag: "boat")]
        let units = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, EditorialUnit(candidate: $0)) })
        let items = candidates.map { TimelineItem(candidateID: $0.id, assetID: asset, kind: .video, sourceStart: $0.sourceStart, sourceDuration: 4, timelineStart: 0, timelineDuration: 4) }
        let slots = AutomaticEditorialAssembly.slots(items: items, units: units, maximumShot: 8, fps: 30, pacing: 0.8)
        #expect(slots.reduce(0) { $0 + $1.capacity } == 390)
        #expect(slots[0].item.sourceStart + Double(slots[0].capacity) / 30 <= slots[1].item.sourceStart)
    }

    @Test func impossibleRequestPreservesOriginalDurationContract() {
        let (timeline, original, analysis, events) = fixture()
        var plan = original
        plan.prompt = "Фильм ровно 100 секунд"
        plan.contentBudget?.requestedDuration = 100
        plan.directorBrief?.requestedDuration = 100
        let result = AutomaticEditorialAssembly.prepare(timeline: timeline, plan: plan, analyses: analysis, events: events)
        #expect(result.timeline.duration == 60)
        #expect(result.plan.contentBudget?.durationConstraintStatus == .compromisedInsufficientContent)
        #expect(result.plan.exactDurationRequirement == 100)
        #expect(result.plan.constraints.targetDuration == 100)
    }

    @Test(arguments: 0..<8) func fallbackRepairsAMeasuredShortCutBeforeApplyingDeliveryMinimum(_ seed: Int) throws {
        let (timeline, plan, analysis, _) = fixture()
        var short = timeline
        short.items = Array(short.items.prefix(2))
        let assets = analysis.enumerated().map { index, a in
            MediaAsset(id: a.assetID, originalURL: URL(fileURLWithPath: "/tmp/fallback-\(index).mov"), kind: .video,
                byteSize: 1, contentHash: "fallback-\(index)", metadata: .init(duration: 60, width: 1920, height: 1080))
        }
        #expect(!AutomaticFilmDurationPolicy.meetsMinimum(short))
        let result = try #require(ConservativeFallbackBuilder().build(
            stories: [StoryPlanVariant(plan: plan, strategy: "test", seedScore: 1)], reviewed: [short], assets: assets, analyses: analysis))
        #expect(abs(result.timeline.duration - 42) < 0.04)
        #expect(AutomaticFilmDurationPolicy.meetsMinimum(result.timeline))
        #expect(result.timeline.editorialReview?.rankingEligible == true)
        #expect(result.timeline.items.allSatisfy { $0.sourceDuration <= 8 })
    }

    @Test func rejectedCandidateStaysExcludedDuringRefillAndReopen() {
        let (timeline, plan, analysis, events) = fixture()
        let rejected = timeline.items[0].candidateID!
        let first = AutomaticEditorialAssembly.prepare(timeline: timeline, plan: plan, analyses: analysis, events: events, excluded: [rejected])
        let second = AutomaticEditorialAssembly.prepare(timeline: first.timeline, plan: first.plan, analyses: analysis, events: events)
        #expect(!second.timeline.items.contains { $0.candidateID == rejected })
        #expect(second.timeline.duration <= 42)
    }

    @Test func addingAnActionShotDoesNotEraseExplicitObservationCapacity() {
        let candidates = (0..<8).map { candidate(asset: UUID(), start: 0, tag: "landscape-\($0)") }
        let before = EditorialAnalysisContext(analyses: analyses(candidates))
        let after = EditorialAnalysisContext(analyses: analyses(candidates + [candidate(asset: UUID(), start: 0, tag: "action", atmosphere: false)]))
        let engine = ContentBudgetEngine()
        let a = engine.budget(units: before.units, families: before.families, requestedDuration: 60, requestIsExplicit: true, style: .init())
        let b = engine.budget(units: after.units, families: after.families, requestedDuration: 60, requestIsExplicit: true, style: .init())
        #expect(b.supportedDuration >= a.supportedDuration)
        #expect(b.durationConstraintStatus == .satisfied)
    }
}
