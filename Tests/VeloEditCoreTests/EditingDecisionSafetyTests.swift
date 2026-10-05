import Foundation
import Testing
@testable import VeloEditCore

@Suite struct EditingDecisionSafetyTests {
    @Test func styleRepairCannotMoveALaterSourceMomentToTheOpening() {
        let asset = MediaAsset(originalURL: URL(fileURLWithPath: "/tmp/ordered.mov"), kind: .video,
            byteSize: 1, contentHash: "fixture", metadata: .init(duration: 30))
        let plan = StoryPlan(prompt: "Лучший фильм", preset: .story, constraints: .init(targetDuration: 12), chapters: [])
        let first = TimelineItem(assetID: asset.id, kind: .video, sourceStart: 0, sourceDuration: 6, timelineStart: 0, timelineDuration: 6)
        let last = TimelineItem(assetID: asset.id, kind: .video, sourceStart: 20, sourceDuration: 6, timelineStart: 6, timelineDuration: 6)
        let original = Timeline(storyPlanID: plan.id, items: [first, last])
        var candidate = original; candidate.items = TimelineTiming.retimed([last, first])
        let failures = TimelineSafetyValidator().violations(candidate: candidate, comparedTo: original,
            plan: plan, analyses: [], assets: [asset])
        #expect(failures.contains { $0.contains("хронологию") })
        #expect(TimelineSafetyValidator().violations(candidate: original, comparedTo: original,
            plan: plan, analyses: [], assets: [asset]).isEmpty)
    }
    @Test func cachedEvidenceMustNotBridgeAnUnusableMiddleFrame() {
        var insights = CandidateInsights()
        insights.editorialEvidence = .init(samples: (0..<12).map { index in
            .init(sourceTime: Double(index), quality: index == 9 ? 0.08 : 0.9, confidence: 0.7)
        }, usableRange: .init(start: 0, end: 12), confidence: 0.62)
        let candidate = Candidate(assetID: UUID(), sourceStart: 0, sourceDuration: 12,
            scores: .init(quality: 0.9, interest: 0.8, action: 0.4, stability: 0.8), insights: insights)
        let unit = EditorialUnit(candidate: candidate)
        #expect(unit.evidence.usableRange.start == 0)
        #expect(unit.evidence.usableRange.end == 8.05)
        #expect(unit.evidence.foregroundOcclusion == nil)
        // Original analysis remains intact; no false human/semantic label.
        #expect(candidate.insights?.editorialEvidence?.usableRange.end == 12)
        var unusable = candidate
        unusable.insights?.editorialEvidence?.samples = (0..<12).map {
            .init(sourceTime: Double($0), quality: 0.1, confidence: 0.7)
        }
        #expect(EditorialUnit(candidate: unusable).usableDuration == 0)
    }
    private struct FlatScorer: MontageGlobalScoring {
        func score(plan: StoryPlan, timeline: Timeline, assets: [MediaAsset], analyses: [AnalysisResult]) -> MontageGlobalScore {
            .init(total: 0.8, highlightQuality: 0.8, storyArc: 0.8, diversity: 0.8, durationFit: 0.8,
                  musicalAlignment: 0.8, reviewQuality: 0.8)
        }
    }
    private struct TimelinePreferenceScorer: MontageGlobalScoring {
        var preferredID: UUID
        func score(plan: StoryPlan, timeline: Timeline, assets: [MediaAsset], analyses: [AnalysisResult]) -> MontageGlobalScore {
            var score = FlatScorer().score(plan: plan, timeline: timeline, assets: assets, analyses: analyses)
            score.total = timeline.id == preferredID ? 0.95 : 0.75
            return score
        }
    }
    @Test func fallbackNamesCannotAliasRankerEvidenceOrItsSafetyReference() throws {
        let asset = MediaAsset(originalURL: URL(fileURLWithPath: "/tmp/same-strategy.mov"), kind: .video,
            byteSize: 1, contentHash: "fixture", metadata: .init(duration: 60))
        let plan = StoryPlan(prompt: "Фильм", preset: .story, constraints: .init(targetDuration: 12), chapters: [])
        let first = TimelineItem(candidateID: UUID(), assetID: asset.id, kind: .video,
            sourceStart: 0, sourceDuration: 6, timelineStart: 0, timelineDuration: 6)
        var repeatShot = first; repeatShot.id = UUID(); repeatShot.timelineStart = 6
        let repeated = Timeline(storyPlanID: plan.id, items: [first, repeatShot])
        var distinct = repeated; distinct.id = UUID(); distinct.items[1].candidateID = UUID(); distinct.items[1].sourceStart = 10
        let stories = [StoryPlanVariant(plan: plan, strategy: "conservative-fallback", seedScore: 1),
            StoryPlanVariant(plan: plan, strategy: "conservative-fallback", seedScore: 1)]
        var weights = Array(repeating: 0.0, count: EditingDecisionFeatures.names.count)
        weights[1] = -1
        var model = EditingDecisionRanker(schemaVersion: EditingDecisionFeatures.schemaVersion, modelID: "same-name-fixture",
            featureNames: EditingDecisionFeatures.names, weights: weights, trainingDataSHA256: "fixture",
            labelProvenance: "test-only", validatedForDefault: false)
        let selected = try #require(MontageVariantSelector(scorer: FlatScorer(), decisionRanker: model)
            .select(stories: stories, timelines: [repeated, distinct], assets: [asset], analyses: []))
        #expect(selected.timeline.id == distinct.id)
        #expect(selected.timeline.editingDecisionSelection?.legacyTimelineID == repeated.id)
        #expect(selected.timeline.editingDecisionSelection?.selectedTimelineID == distinct.id)

        // Deliberately hostile preference weights must not promote a repeat
        // when the exact legacy winner (not the first namesake) is safe.
        model.weights[1] = 1
        let scorer = TimelinePreferenceScorer(preferredID: distinct.id)
        let legacy = try #require(MontageVariantSelector(scorer: scorer, decisionRanker: nil)
            .select(stories: stories, timelines: [repeated, distinct], assets: [asset], analyses: []))
        #expect(legacy.timeline.id == distinct.id)
        let guarded = try #require(MontageVariantSelector(scorer: scorer, decisionRanker: model)
            .select(stories: stories, timelines: [repeated, distinct], assets: [asset], analyses: []))
        #expect(guarded.timeline.id == distinct.id)
        #expect(guarded.timeline.editingDecisionSelection?.legacyTimelineID == distinct.id)
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["VELOEDIT_TEST_RANKER_MODEL"] != nil))
    func trainedArtifactChangesSelectionWithoutWorseningChronology() throws {
        let path = try #require(ProcessInfo.processInfo.environment["VELOEDIT_TEST_RANKER_MODEL"])
        let model = try JSONDecoder().decode(EditingDecisionRanker.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        #expect(model.isValid)
        let asset = MediaAsset(originalURL: URL(fileURLWithPath: "/tmp/trained-model-fixture.mov"),
            kind: .video, byteSize: 1, contentHash: "fixture", metadata: .init(duration: 60))
        let plan = StoryPlan(prompt: "Фильм", preset: .story, constraints: .init(targetDuration: 12), chapters: [])
        let first = TimelineItem(candidateID: UUID(), assetID: asset.id, kind: .video,
            sourceStart: 0, sourceDuration: 6, timelineStart: 0, timelineDuration: 6)
        var repeated = first; repeated.id = UUID(); repeated.timelineStart = 6
        let a = Timeline(storyPlanID: plan.id, items: [first, repeated])
        var b = a; b.id = UUID(); b.items[1].candidateID = UUID(); b.items[1].sourceStart = 10
        let stories = [StoryPlanVariant(plan: plan, strategy: "repeated", seedScore: 1),
            StoryPlanVariant(plan: plan, strategy: "distinct", seedScore: 1)]
        let legacy = try #require(MontageVariantSelector(scorer: FlatScorer(), decisionRanker: nil)
            .select(stories: stories, timelines: [a,b], assets: [asset], analyses: []))
        let selected = try #require(MontageVariantSelector(scorer: FlatScorer(), decisionRanker: model)
            .select(stories: stories, timelines: [a,b], assets: [asset], analyses: []))
        #expect(legacy.story.strategy == "repeated")
        #expect(selected.story.strategy == "distinct")
        #expect(selected.timeline.editingDecisionSelection?.modelID == model.modelID)
        #expect(EditorialChronologyReport.inspect(timeline: selected.timeline, assets: [asset]).confirmedErrorCount == 0)
    }
    @Test func optInRankerChangesRealSelectorAndCannotPromoteRewind() throws {
        let assets = (0..<2).map { i in MediaAsset(originalURL: URL(fileURLWithPath: "/tmp/ranker-\(i).mp4"),
            kind: .video, byteSize: 1, contentHash: "\(i)", metadata: .init(duration: 60,
            creationDate: Date(timeIntervalSince1970: 1000 + Double(i)*100), dateSource: .embeddedMetadata, dateConfidence: 0.98)) }
        let plan = StoryPlan(prompt: "Фильм", preset: .story, constraints: .init(targetDuration: 12), chapters: [])
        let a = Timeline(storyPlanID: plan.id, items: [
            TimelineItem(candidateID: UUID(), assetID: assets[0].id, kind: .video, sourceStart: 0, sourceDuration: 6, timelineStart: 0, timelineDuration: 6),
            TimelineItem(candidateID: UUID(), assetID: assets[0].id, kind: .video, sourceStart: 10, sourceDuration: 6, timelineStart: 6, timelineDuration: 6)])
        var b = a; b.id = UUID(); b.items[1].assetID = assets[1].id; b.items[1].sourceStart = 0
        b.items[1].candidateID = UUID()
        let stories = [StoryPlanVariant(plan: plan, strategy: "legacy", seedScore: 1), StoryPlanVariant(plan: plan, strategy: "alternative", seedScore: 1)]
        let legacy = try #require(MontageVariantSelector(scorer: FlatScorer(), decisionRanker: nil).select(stories: stories, timelines: [a,b], assets: assets, analyses: []))
        var weights = Array(repeating: 0.0, count: EditingDecisionFeatures.names.count); weights[8] = 1
        let model = EditingDecisionRanker(schemaVersion: EditingDecisionFeatures.schemaVersion, modelID: "fixture", featureNames: EditingDecisionFeatures.names,
            weights: weights, trainingDataSHA256: "fixture", labelProvenance: "test-only", validatedForDefault: false)
        let selected = try #require(MontageVariantSelector(scorer: FlatScorer(), decisionRanker: model).select(stories: stories, timelines: [a,b], assets: assets, analyses: []))
        #expect(legacy.story.strategy == "legacy")
        #expect(selected.story.strategy == "alternative")
        #expect(selected.timeline.editingDecisionSelection?.legacyStrategy == "legacy")
        b.items[0].assetID = assets[1].id; b.items[1].assetID = assets[0].id
        let safe = try #require(MontageVariantSelector(scorer: FlatScorer(), decisionRanker: model).select(stories: stories, timelines: [a,b], assets: assets, analyses: []))
        #expect(safe.story.strategy == "legacy")
    }
    @Test func copyingOnDifferentDaysDoesNotOverrideCameraSequence() {
        let assets = [2, 1].enumerated().map { index, number in
            MediaAsset(originalURL: URL(fileURLWithPath: "/tmp/clock-fixture/GX01000\(number).MP4"), kind: .video,
                byteSize: 1, contentHash: "\(number)", metadata: .init(duration: 10,
                    creationDate: Date(timeIntervalSince1970: 1_700_000_000 + Double(index)*86_400),
                    dateSource: .fileCreationDate, dateConfidence: 0.68))
        }
        let order = SourceTimelineAnalyzer().analyze(assets: assets, analyses: []).orderedAssetIDs
        #expect(order == [assets[1].id, assets[0].id])
    }
    @Test func actionProtectionMustNotSilentlyClampAwayCompletion() {
        let boundary = MomentBoundary(anticipationStart: 8, peakTime: 13, completionEnd: 17, confidence: 0.9)
        let candidate = Candidate(assetID: UUID(), sourceStart: 10, sourceDuration: 5,
            scores: .init(quality: 0.8, interest: 0.8, action: 0.8, stability: 0.8), momentBoundary: boundary)
        let required = EditorialMomentPolicy.protectedRange(EditorialUnit(candidate: candidate))
        #expect(required?.start == 8)
        #expect(required?.end == 17)
    }
    @Test func speechProtectionKeepsFullKnownPhraseOutsideCandidate() {
        var insights = CandidateInsights(sceneSummary: "speech")
        insights.speech = .init(text: "Нужно оставить реплику целиком.", phraseStart: 6, phraseEnd: 18,
            confidence: 0.95, startsAtPhraseBoundary: true, endsAtPhraseBoundary: true)
        let candidate = Candidate(assetID: UUID(), sourceStart: 10, sourceDuration: 5,
            scores: .init(quality: 0.8, interest: 0.8, action: 0.2, stability: 0.8), insights: insights)
        let required = EditorialMomentPolicy.protectedRange(EditorialUnit(candidate: candidate))
        #expect(required?.start == 6)
        #expect(required?.end == 18)
    }
    @Test func invalidModelIsRejectedAndEmptyFeaturesAreNotScored() {
        let valid = EditingDecisionRanker(schemaVersion: EditingDecisionFeatures.schemaVersion, modelID: "test", featureNames: EditingDecisionFeatures.names,
            weights: Array(repeating: -1, count: EditingDecisionFeatures.names.count), trainingDataSHA256: "fixture",
            labelProvenance: "test-only", validatedForDefault: false)
        #expect(valid.isValid)
        #expect(valid.utility(.init(values: [])) == nil)
        var invalid = valid; invalid.weights[0] = .nan
        #expect(!invalid.isValid)
        invalid = valid; invalid.featureNames.reverse()
        #expect(!invalid.isValid)
    }
}
