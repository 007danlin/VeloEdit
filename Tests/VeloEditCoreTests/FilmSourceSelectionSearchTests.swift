import Foundation
import Testing
@testable import VeloEditCore

struct FilmSourceSelectionSearchTests {
    private func fixture() -> (Timeline, StoryPlan, [AnalysisResult], [ShotContentAssessment]) {
        let asset = UUID()
        let candidates = [0.0, 10, 20, 30].map { start in
            var insights = CandidateInsights(sceneSummary: "Readable trip moment", dynamics: 0.5, sharpness: 0.9, exposureQuality: 0.9)
            insights.editorialEvidence = .init(usableRange: .init(start: start, end: start + 5),
                informationGain: 0.9, entryQuality: 0.9, exitQuality: 0.9, atmosphereValue: 0.8, confidence: 0.9)
            return Candidate(assetID: asset, sourceStart: start, sourceDuration: 5,
                scores: .init(quality: 0.9, interest: 0.9, action: 0.5, stability: 0.9), tags: ["travel"], insights: insights)
        }
        let analyses = [AnalysisResult(assetID: asset, analyzedContentHash: "fixture", sceneTags: [], candidates: candidates)]
        var plan = StoryPlan(prompt: "Фильм длительностью 15 секунд", preset: .story,
            constraints: .init(targetDuration: 15), chapters: [])
        plan.narrativeBeatPlan = .init(pattern: .minimalMontage, beats: [], reasons: [])
        let timeline = Timeline(storyPlanID: plan.id, items: candidates.prefix(3).enumerated().map { index, candidate in
            TimelineItem(candidateID: candidate.id, assetID: asset, kind: .video, sourceStart: candidate.sourceStart,
                sourceDuration: 5, timelineStart: Double(index) * 5, timelineDuration: 5)
        })
        return (timeline, plan, analyses, timeline.items.map { assessment($0) })
    }

    private func assessment(_ item: TimelineItem, status: ShotContentStatus = .usable) -> ShotContentAssessment {
        .init(itemID: item.id, assetID: item.assetID!, sourceContentHash: "fixture",
            sourceStart: item.sourceStart, sourceDuration: item.sourceDuration, sampleTimes: [0, 0.25, 0.5, 0.75, 0.98],
            phase: "source", model: "fixture", cacheKey: "fixture", status: status, confidence: 0.95,
            obstructedSamples: [], observation: "Readable river view", activity: "travel", editorialPurpose: "establishing",
            actionBoundary: .init(startObservation: "River visible", endObservation: "River visible",
                followingObservation: "River continues", verdict: .continuous, confidence: 0.95))
    }

    @Test func replacesUnknownBeforeExportPreservesGoodRangesAndPersistsFiniteSearch() throws {
        let (timeline, plan, analyses, good) = fixture()
        var reviews = good
        reviews[1].status = .uncertain
        var search = FilmSourceSelectionSearch()
        let proposed = search.alternative(timeline: timeline, plan: plan, analyses: analyses,
            events: [], assets: [], source: reviews)
        let replacement = try #require(proposed)
        #expect(search.attempts == 1)
        #expect(search.excluded == [timeline.items[1].candidateID!])
        #expect(replacement.timeline.items.contains { $0.candidateID == analyses[0].directorCandidates[3].id })
        #expect(abs(replacement.timeline.duration - 15) < 0.04)
        for item in [timeline.items[0], timeline.items[2]] {
            #expect(replacement.timeline.items.contains {
                $0.assetID == item.assetID && $0.sourceStart == item.sourceStart && $0.sourceDuration == item.sourceDuration
            })
        }
        #expect(replacement.timeline.selectedContentReview == nil)
        var restored = try JSONDecoder.veloEdit.decode(FilmSourceSelectionSearch.self, from: JSONEncoder.veloEdit.encode(search))
        let settled = AutomaticEditorialAssembly.prepareForSourceReview(timeline: replacement.timeline,
            plan: replacement.plan, analyses: analyses, events: [], assets: [], verifiedSource: reviews, excluded: restored.excluded)
        #expect(Set(settled.timeline.items.compactMap(\.candidateID)).isDisjoint(with: restored.excluded))
        let repeated = restored.alternative(timeline: timeline, plan: plan, analyses: analyses,
            events: [], assets: [], source: reviews)
        #expect(repeated == nil)
        #expect(restored.attempts == 1)
    }

    @Test func missingEvidenceAndManualEditsNeverTriggerBlindReselection() {
        let (timeline, plan, analyses, good) = fixture()
        var missing = good
        missing[1].status = .uncertain
        missing[1].confidence = 0
        var search = FilmSourceSelectionSearch()
        let unavailable = search.alternative(timeline: timeline, plan: plan, analyses: analyses,
            events: [], assets: [], source: missing)
        #expect(unavailable == nil)
        #expect(search.excluded.isEmpty)
        missing[1].confidence = 0.9
        var manual = timeline
        manual.items[0].locked = true
        let locked = search.alternative(timeline: manual, plan: plan, analyses: analyses,
            events: [], assets: [], source: missing)
        #expect(locked == nil)
    }

    @Test func noCandidateCanReappearAndNewIDsDoNotCreateNewVisualCuts() throws {
        let (timeline, plan, analyses, good) = fixture()
        var renamed = timeline
        for index in renamed.items.indices { renamed.items[index].id = UUID(); renamed.items[index].candidateID = UUID() }
        #expect(FilmSourceSelectionSearch.selectionIdentity(timeline) == FilmSourceSelectionSearch.selectionIdentity(renamed))
        var search = FilmSourceSelectionSearch()
        var reviews = good; reviews[1].status = .uncertain
        let proposed = search.alternative(timeline: timeline, plan: plan, analyses: analyses,
            events: [], assets: [], source: reviews)
        let replacement = try #require(proposed)
        let replacementReviews = replacement.timeline.items.map { item in
            assessment(item, status: item.sourceStart == 30 ? .uncertain : .usable)
        }
        let exhausted = search.alternative(timeline: replacement.timeline, plan: replacement.plan, analyses: analyses,
            events: [], assets: [], source: replacementReviews)
        #expect(exhausted == nil)
        #expect(search.excluded.count == 2)
        #expect(search.attempts == 1)
    }

    @Test func historicalRepairStateRemainsDecodable() throws {
        let data = Data(#"{"attempts":0,"visited":[]}"#.utf8)
        let old = try JSONDecoder.veloEdit.decode(FilmContentRepairState.self, from: data)
        #expect(old.sourceSearch == nil)
    }

    @Test func anotherCandidateIDForAlmostTheSameFootageDoesNotHideAFreshAlternative() throws {
        let (timeline, plan, original, good) = fixture()
        var analyses = original
        var alias = analyses[0].candidates[3]
        alias.id = UUID()
        alias.sourceStart = 11
        alias.sourceDuration = 4
        alias.scores.quality = 1
        alias.insights?.editorialEvidence?.usableRange = .init(start: 11, end: 15)
        analyses[0].candidates.insert(alias, at: 3)
        var reviews = good; reviews[1].status = .uncertain
        var search = FilmSourceSelectionSearch()
        let proposal = search.alternative(timeline: timeline, plan: plan, analyses: analyses,
            events: [], assets: [], source: reviews)
        let cut = try #require(proposal?.timeline)
        #expect(!cut.items.contains { $0.candidateID == alias.id })
        #expect(cut.items.contains { $0.sourceStart == 30 })
        #expect(abs(cut.duration - 15) < 0.04)
    }

    @Test func exhaustedFreshSearchKeepsTheFeasibleFallbackInputsAvailable() throws {
        let (timeline, plan, original, good) = fixture()
        var analyses = original
        var alias = analyses[0].candidates[3]
        alias.sourceStart = 11
        alias.sourceDuration = 5
        alias.insights?.editorialEvidence?.usableRange = .init(start: 11, end: 16)
        analyses[0].candidates[3] = alias
        var source = good
        source[1].status = .uncertain
        var search = FilmSourceSelectionSearch()
        let result = search.alternative(timeline: timeline, plan: plan,
            analyses: analyses, events: [], assets: [], source: source)
        let proposal = try #require(result)
        #expect(proposal.timeline.items.contains { $0.candidateID == alias.id })
        #expect(search.excluded == [timeline.items[1].candidateID!])
        let restored = try JSONDecoder.veloEdit.decode(FilmSourceSelectionSearch.self,
            from: JSONEncoder.veloEdit.encode(search))
        #expect(Set(proposal.timeline.items.compactMap(\.candidateID)).isDisjoint(with: restored.excluded))
        #expect(abs(proposal.timeline.duration - 15) < 0.04)
    }
}
