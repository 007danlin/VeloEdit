import Foundation
import CryptoKit
import Testing
@testable import VeloEditCore

@Suite struct EditingDecisionDefaultTests {
    private struct FlatScorer: MontageGlobalScoring {
        func score(plan: StoryPlan, timeline: Timeline, assets: [MediaAsset], analyses: [AnalysisResult]) -> MontageGlobalScore {
            .init(total: 0.8, highlightQuality: 0.8, storyArc: 0.8, diversity: 0.8,
                  durationFit: 0.8, musicalAlignment: 0.8, reviewQuality: 0.8)
        }
    }
    private func fixture() -> (MediaAsset, [StoryPlanVariant], [Timeline]) {
        let asset = MediaAsset(originalURL: URL(fileURLWithPath: "/tmp/default-ranker-fixture.mov"),
            kind: .video, byteSize: 1, contentHash: "fixture", metadata: .init(duration: 60))
        let plan = StoryPlan(prompt: "Фильм", preset: .story, constraints: .init(targetDuration: 12), chapters: [])
        let first = TimelineItem(candidateID: UUID(), assetID: asset.id, kind: .video,
            sourceStart: 0, sourceDuration: 6, timelineStart: 0, timelineDuration: 6)
        var repeated = first; repeated.id = UUID(); repeated.timelineStart = 6
        let a = Timeline(storyPlanID: plan.id, items: [first, repeated])
        var b = a; b.id = UUID(); b.items[1].candidateID = UUID(); b.items[1].sourceStart = 10
        return (asset, [.init(plan: plan, strategy: "repeated", seedScore: 1),
                        .init(plan: plan, strategy: "distinct", seedScore: 1)], [a,b])
    }
    private func selected(_ model: EditingDecisionRanker?) throws -> DirectedMontageVariant {
        let (asset, stories, timelines) = fixture()
        return try #require(MontageVariantSelector(scorer: FlatScorer(), decisionRanker: model)
            .select(stories: stories, timelines: timelines, assets: [asset], analyses: []))
    }
    @Test func embeddedArtifactIsExactlyThePreviouslyTrainedModel() throws {
        let digest = SHA256.hash(data: BundledEditingDecisionModel.data).map { String(format: "%02x", $0) }.joined()
        #expect(digest == "8086cdaea539838a53668cd4a6cd1c56f75a9379f5d4128c85edc6b0020da355")
        let model = try #require(EditingDecisionRanker.load(environment: [:]))
        #expect(model.modelID == "technical-pairwise-balanced-features2-211f051b90e5")
        #expect(model.labelProvenance == "automatic-technical-dominance")
        #expect(!model.validatedForDefault) // Original metadata, not a new training claim.
    }
    @Test func defaultSelectorUsesModelForAllAnalysisProfiles() throws {
        let (asset, stories, timelines) = fixture()
        for mode in AIPowerMode.allCases {
            let profile = AIAnalysisProfile.resolve(mode: mode, thermalState: .nominal)
            let analyses = [AnalysisResult(assetID: asset.id, analyzedContentHash: asset.contentHash,
                candidates: [], completedDepth: profile.targetDepth)]
            let legacy = try #require(MontageVariantSelector(scorer: FlatScorer(), decisionRanker: nil)
                .select(stories: stories, timelines: timelines, assets: [asset], analyses: analyses))
            let actual = try #require(MontageVariantSelector(scorer: FlatScorer())
                .select(stories: stories, timelines: timelines, assets: [asset], analyses: analyses))
            #expect(legacy.timeline.id == timelines[0].id)
            #expect(actual.timeline.id == timelines[1].id)
            let receipt = try #require(actual.timeline.editingDecisionSelection)
            #expect(receipt.evaluatedCandidateCount == 2)
            #expect(receipt.legacyTimelineID == legacy.timeline.id)
            #expect(receipt.selectedTimelineID == actual.timeline.id)
            #expect(try #require(receipt.selectedUtility) > #require(receipt.legacyUtility))
        }
    }
    @Test func disablingAndFailedLoadingKeepLegacyChoice() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let corrupt = root.appendingPathComponent("corrupt.json")
        try Data("broken".utf8).write(to: corrupt)
        var old = try #require(EditingDecisionRanker.load(environment: [:])); old.schemaVersion = 1
        let incompatible = root.appendingPathComponent("old.json")
        try JSONEncoder().encode(old).write(to: incompatible)
        let cases: [EditingDecisionRanker?] = [
            EditingDecisionRanker.load(environment: ["VELOEDIT_EDIT_RANKER": "off"]),
            EditingDecisionRanker.load(environment: [:], enabled: false),
            EditingDecisionRanker.load(environment: ["VELOEDIT_EDIT_RANKER": root.appendingPathComponent("absent.json").path]),
            EditingDecisionRanker.load(environment: ["VELOEDIT_EDIT_RANKER": corrupt.path]),
            EditingDecisionRanker.load(environment: ["VELOEDIT_EDIT_RANKER": incompatible.path]),
            EditingDecisionRanker.load(environment: [:], bundledData: Data("broken".utf8)),
            EditingDecisionRanker.load(environment: [:], bundledData: try JSONEncoder().encode(old))]
        for model in cases {
            #expect(model == nil)
            let result = try selected(model)
            #expect(result.story.strategy == "repeated")
            #expect(result.timeline.editingDecisionSelection == nil)
        }
    }
    @Test func explicitPathStillLoadsAndDisabledPreferenceWins() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("model-\(UUID()).json")
        try BundledEditingDecisionModel.data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try selected(EditingDecisionRanker.load(environment: ["VELOEDIT_EDIT_RANKER": url.path])).story.strategy == "distinct")
        #expect(EditingDecisionRanker.load(environment: ["VELOEDIT_EDIT_RANKER": url.path], enabled: false) == nil)
    }
    @Test func invalidInjectedModelAndNonfiniteScoresDoNotClaimParticipation() throws {
        var model = try #require(EditingDecisionRanker.load(environment: [:]))
        model.featureNames.reverse()
        #expect(try selected(model).timeline.editingDecisionSelection == nil)
        model = try #require(EditingDecisionRanker.load(environment: [:]))
        model.weights = Array(repeating: Double.greatestFiniteMagnitude, count: model.weights.count)
        let fallback = try selected(model)
        #expect(fallback.story.strategy == "repeated")
        #expect(fallback.timeline.editingDecisionSelection == nil)
    }
    @Test func disabledRunClearsOldParticipationReceiptAndOldReceiptsStillDecode() throws {
        let (asset, stories, original) = fixture()
        var timelines = original
        timelines[0].editingDecisionSelection = .init(modelID: "old-run", legacyStrategy: "repeated",
                                                      selectedStrategy: "repeated", labelProvenance: "test")
        let result = try #require(MontageVariantSelector(scorer: FlatScorer(), decisionRanker: nil)
            .select(stories: stories, timelines: timelines, assets: [asset], analyses: []))
        #expect(result.timeline.editingDecisionSelection == nil)
        let old = try JSONDecoder().decode(EditingDecisionSelection.self,
            from: Data(#"{"modelID":"old","legacyStrategy":"a","selectedStrategy":"b","labelProvenance":"automatic"}"#.utf8))
        #expect(old.evaluatedCandidateCount == nil)
    }
}
