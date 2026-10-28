import Foundation
import Testing
@testable import VeloEditCore

@Suite struct EditorialMiningScoreTests {
    private func fixture() -> (MediaAsset, Candidate, EditorialEvidence) {
        let asset = MediaAsset(originalURL: URL(fileURLWithPath: "/tmp/mining-score.mov"),
            kind: .video, byteSize: 1, contentHash: "exact-source", metadata: .init(duration: 20))
        let evidence = EditorialEvidence(samples: (0..<12).map {
            .init(sourceTime: 6 + Double($0) / 2, quality: 0.95, confidence: 0.8)
        }, usableRange: .init(start: 6, end: 12), entryQuality: 0.95, exitQuality: 0.95, confidence: 0.62)
        var candidate = Candidate(id: EditorialIdentity.uuid("mining-v4|\(asset.id)|\(asset.contentHash)|6.0|12.0"),
            assetID: asset.id, sourceStart: 6, sourceDuration: 6,
            scores: .init(quality: 0.7, interest: 0.1, action: 0, stability: 0.2),
            insights: .init(sceneSummary: "Measured scene", composition: 0.15,
                bestTakeScore: EditorialCandidateMiner.measuredQuality(evidence)))
        candidate.insights?.editorialEvidence = evidence
        return (asset, candidate, evidence)
    }

    @Test func sharpExposureCannotReplaceInterestAndComposition() throws {
        let (_, weak, evidence) = fixture()
        let scored = EditorialCandidateMiner.applyingMeasuredQuality(to: weak, evidence: evidence)
        var stronger = weak
        stronger.scores.interest = 0.9
        stronger.scores.stability = 0.9
        stronger.insights?.composition = 0.9
        let balanced = EditorialCandidateMiner.applyingMeasuredQuality(to: stronger, evidence: evidence)
        #expect(abs(scored.scores.quality - 0.95) < 1e-10)
        #expect(scored.scores.interest == weak.scores.interest)
        #expect(scored.insights?.editorialEvidence == evidence)
        #expect(EditorialUnit(candidate: scored).quality < 0.55)
        #expect(EditorialUnit(candidate: balanced).quality > 0.55)
        #expect(balanced.insights?.bestTakeScoreRule == EditorialCandidateMiner.scoreRule)
        // Improving the measured technical component still helps the score.
        var darker = evidence
        darker.samples = darker.samples.map { var sample = $0; sample.quality = 0.55; return sample }
        let lower = EditorialCandidateMiner.applyingMeasuredQuality(to: stronger, evidence: darker)
        #expect(EditorialUnit(candidate: lower).quality < EditorialUnit(candidate: balanced).quality)
    }

    private struct UnexpectedDecode: EditorialEvidenceAnalyzing {
        func analyze(candidate: Candidate, asset: MediaAsset) async throws -> EditorialEvidence {
            Issue.record("A score migration must not decode completed source windows again")
            throw URLError(.cannotDecodeContentData)
        }
    }

    @Test func completedLegacyMiningMigratesWithoutDecodingOrMovingIntervals() async throws {
        let (asset, candidate, evidence) = fixture()
        let input = AnalysisResult(assetID: asset.id, analyzedContentHash: asset.contentHash,
            candidates: [candidate], warnings: [EditorialCandidateMiner.completionMarker])
        let first = try await EditorialCandidateMiner().expandIfNeeded(analyses: [input], assets: [asset],
            requestedDuration: 20, force: true, analyzer: UnexpectedDecode())
        let migrated = try #require(first.first?.candidates.first)
        #expect(migrated.id == candidate.id && migrated.sourceStart == candidate.sourceStart
            && migrated.sourceDuration == candidate.sourceDuration)
        #expect(migrated.insights?.editorialEvidence == evidence)
        #expect(migrated.insights?.bestTakeScore != candidate.insights?.bestTakeScore)
        #expect(migrated.insights?.bestTakeScoreRule == EditorialCandidateMiner.scoreRule)
        let reopened = try JSONDecoder.veloEdit.decode([AnalysisResult].self, from: JSONEncoder.veloEdit.encode(first))
        let second = try await EditorialCandidateMiner().expandIfNeeded(analyses: reopened, assets: [asset],
            requestedDuration: 20, force: true, analyzer: UnexpectedDecode())
        #expect(second[0].candidates == first[0].candidates)
        #expect(second[0].warnings == input.warnings)
    }

    @Test func migrationRequiresExactProducerSourceRangeAndUnenrichedScore() {
        let (asset, original, _) = fixture()
        var foreign = original; foreign.id = UUID()
        var moved = original; moved.sourceStart += 0.1
        var enriched = original; enriched.insights?.semanticEventID = "later-semantic-assessment"
        var differentScore = original; differentScore.insights?.bestTakeScore = 0.8
        let candidates = [foreign, moved, enriched, differentScore]
        let input = AnalysisResult(assetID: asset.id, analyzedContentHash: asset.contentHash, candidates: candidates)
        #expect(EditorialCandidateMiner.restoringLegacyScores([input], assets: [asset])[0].candidates == candidates)
        let stale = AnalysisResult(assetID: asset.id, analyzedContentHash: "old-bytes", candidates: [original])
        #expect(EditorialCandidateMiner.restoringLegacyScores([stale], assets: [asset])[0].candidates == [original])
    }

    @Test func insufficientEvidenceDoesNotChangeScoreOrInventProvenance() {
        let (_, candidate, evidence) = fixture()
        var uncertain = evidence; uncertain.confidence = 0.54
        #expect(EditorialCandidateMiner.applyingMeasuredQuality(to: candidate, evidence: uncertain) == candidate)
    }
}
