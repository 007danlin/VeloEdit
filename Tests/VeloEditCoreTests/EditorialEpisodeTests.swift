import Foundation
import Testing
@testable import VeloEditCore

@Suite struct EditorialEpisodeTests {
    private func unit(_ asset: UUID, start: Double, tags: Set<String>, measured: Bool = true, speech: Bool = false) -> EditorialUnit {
        var insights = CandidateInsights(sceneSummary: tags.sorted().joined(separator: ", "))
        insights.editorialEvidence = .init(samples: (0..<12).map {
            .init(sourceTime: start + Double($0) * 0.6, quality: 0.9, confidence: 0.8)
        }, usableRange: .init(start: start, end: start + 8), atmosphereValue: 0.8, confidence: measured ? 0.62 : 0.15)
        if speech { insights.speech = .init(text: "Полная реплика", phraseStart: start, phraseEnd: start + 8, confidence: 0.9, startsAtPhraseBoundary: true, endsAtPhraseBoundary: true) }
        return EditorialUnit(candidate: .init(assetID: asset, sourceStart: start, sourceDuration: 8,
            scores: .init(quality: 0.9, interest: 0.8, action: 0.1, stability: 0.9), tags: tags, insights: insights))
    }

    @Test func episodesDescribeObservedContextAndNeverInventAnEnding() {
        let asset = UUID()
        let forest = unit(asset, start: 0, tags: ["forest", "path"])
        let route = unit(asset, start: 10, tags: ["forest", "path"])
        let people = unit(asset, start: 20, tags: ["people", "forest"])
        let unknown = unit(asset, start: 30, tags: ["arrival", "climax"], measured: false)
        let plan = EditorialEpisodePlan.build(units: [people, route, unknown, forest], sourceOrder: [asset: 0])
        #expect(plan.episodes.count == 3)
        #expect(plan.episodes[0].candidateIDs == [forest.id, route.id])
        #expect(plan.episodes[1].purpose == "participants")
        #expect(plan.episodes.last?.purpose == "observation-unknown")
        #expect(!plan.episodes.contains { $0.purpose == "observed-outcome" })
    }

    @Test func contextIsConditionalEarlierAndFromTheSameSource() {
        let asset = UUID()
        let forest = unit(asset, start: 0, tags: ["forest", "path"])
        let people = unit(asset, start: 20, tags: ["people", "forest"])
        let units = [forest, people]
        let map = Dictionary(uniqueKeysWithValues: units.map { ($0.id, $0) })
        let plan = EditorialEpisodePlan.build(units: units, sourceOrder: [asset: 0])
        #expect(EditorialCoherenceExperiment.contextCandidate(before: people, plan: plan, units: map)?.id == forest.id)
        #expect(EditorialCoherenceExperiment.contextCandidate(before: forest, plan: plan, units: map) == nil)
        var otherSource = forest
        otherSource.candidate.assetID = UUID()
        let cross = EditorialEpisodePlan.build(units: [otherSource, people], sourceOrder: [otherSource.candidate.assetID: 0, asset: 1])
        #expect(EditorialCoherenceExperiment.contextCandidate(before: people, plan: cross, units: [otherSource.id: otherSource, people.id: people]) == nil)
    }

    @Test func routeHypothesisKeepsAnchorsSpeechAndSignificantNaturalSound() {
        let asset = UUID()
        var units = (0..<6).map { unit(asset, start: Double($0 * 10), tags: ["forest", "path"], speech: $0 == 2) }
        units[3].candidate.insights?.audioEvents = [.init(kind: .laughter, startTime: 30, endTime: 34, confidence: 0.6, intensity: 0.5)]
        let map = Dictionary(uniqueKeysWithValues: units.map { ($0.id, $0) })
        let plan = EditorialEpisodePlan.build(units: units, sourceOrder: [asset: 0])
        let kept = EditorialCoherenceExperiment.conciseRouteIDs(selected: Set(units.map(\.id)), plan: plan, units: map)
        #expect(kept == Set([units[0].id, units[2].id, units[3].id, units[5].id]))
        #expect(units.count == 6) // Source evidence is never rewritten.
    }

    @Test func unknownContentAndDifferentSettingsAreNotCompressedTogether() {
        let asset = UUID()
        let units = (0..<6).map { unit(asset, start: Double($0 * 10),
            tags: $0 < 3 ? ["forest", "path"] : ["field", "road"], measured: false) }
        let map = Dictionary(uniqueKeysWithValues: units.map { ($0.id, $0) })
        let plan = EditorialEpisodePlan.build(units: units, sourceOrder: [asset: 0])
        #expect(EditorialCoherenceExperiment.conciseRouteIDs(selected: Set(units.map(\.id)), plan: plan, units: map) == Set(units.map(\.id)))
        #expect(plan.episodes.allSatisfy { $0.context.isEmpty && !$0.routeObservation })
    }

    @Test func aNewObservedObjectKeepsItsShotEvenInsideTheSameRouteEpisode() {
        let asset = UUID()
        var units = (0..<5).map { unit(asset, start: Double($0 * 10), tags: ["forest", "path"]) }
        units[2].candidate.tags.insert("deer")
        let map = Dictionary(uniqueKeysWithValues: units.map { ($0.id, $0) })
        let plan = EditorialEpisodePlan.build(units: units, sourceOrder: [asset: 0])
        let kept = EditorialCoherenceExperiment.conciseRouteIDs(selected: Set(units.map(\.id)), plan: plan, units: map)
        #expect(kept == Set([units[0].id, units[2].id, units[4].id]))
    }
}
