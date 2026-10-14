import Foundation
import Testing
@testable import VeloEditCore

@Suite struct ExpressiveMomentTests {
    private func candidate(start: Double = 0, confidence: Double = 0.9, value: Double = 0.9, hold: Double = 8) -> Candidate {
        var insights = CandidateInsights(bestTakeScore: 0.85)
        insights.editorialEvidence = .init(usableRange: .init(start: start, end: start + 12),
            entryQuality: 0.85, exitQuality: 0.85, confidence: 0.8)
        insights.expressiveMoment = .init(sourceStart: start, sourceEnd: start + 12,
            sampleTimes: [start, start + 6, start + 11.98], composition: value, humanMoment: 0.2,
            meaningfulMovement: 0.1, confidence: confidence, recommendedDuration: hold,
            observation: "Wide river valley and reflections remain visible across the interval", model: "fixture")
        return Candidate(assetID: UUID(), sourceStart: start, sourceDuration: 12,
            scores: .init(quality: 0.85, interest: 0.7, action: 0.1, stability: 0.8), tags: ["river"], insights: insights)
    }

    @Test func expressiveSceneryReceivesLongerNaturalHoldThanTechnicalQualityAlone() {
        let c = candidate()
        let expressive = EditorialUnit(candidate: c)
        var legacy = c; legacy.insights?.expressiveMoment = nil
        #expect(expressive.preferredDuration(pacing: 0.45) == 8)
        #expect(EditorialUnit(candidate: legacy).preferredDuration(pacing: 0.45) < 5)
        #expect(expressive.usableDuration == 10)
    }

    @Test func uncertaintyAndIncidentalContentCannotEarnLongHold() {
        #expect(EditorialUnit(candidate: candidate(confidence: 0.6)).preferredDuration(pacing: 0.4) < 5)
        #expect(EditorialUnit(candidate: candidate(value: 0.4)).preferredDuration(pacing: 0.4) < 5)
        var c = candidate(); c.insights?.editorialEvidence?.foregroundOcclusion = 0.8
        #expect(EditorialUnit(candidate: c).usableDuration == 0)
    }

    @Test func observationCannotBeBorrowedFromNeighboringRange() {
        var c = candidate(); c.sourceStart = 6
        #expect(ExpressiveMomentPolicy.duration(EditorialUnit(candidate: c), pacing: 0.4) == nil)
    }

    @Test func detailAndLandscapeKeepDifferentDurations() {
        #expect(EditorialUnit(candidate: candidate(hold: 4)).preferredDuration(pacing: 0.45) == 4)
        #expect(EditorialUnit(candidate: candidate(hold: 9)).preferredDuration(pacing: 0.45) == 9)
        #expect(!ExpressiveMomentPolicy.requested(in: "Собери прежний фильм"))
        #expect(ExpressiveMomentPolicy.requested(in: "Хочу больше красоты и времени, чтобы насладиться поездкой"))
    }

    @Test func discoveryRejectsRenumberedDuplicateOrMissingRows() throws {
        let j = ExpressiveMomentDiscovery.Judgement(index: 3, scene: "River reflects trees across the valley", composition: 0.8,
            humanMoment: 0, meaningfulMovement: 0.2, confidence: 0.8, recommendedDuration: 8, tags: ["river"])
        func data(_ rows: [ExpressiveMomentDiscovery.Judgement]) throws -> String {
            String(decoding: try JSONEncoder().encode(ExpressiveMomentDiscovery.Response(windows: rows)), as: UTF8.self)
        }
        #expect(try ExpressiveMomentDiscovery.parse(data([j]), indices: [3]).count == 1)
        var numeric = j; numeric.scene = "0.7"
        #expect(throws: (any Error).self) { try ExpressiveMomentDiscovery.parse(data([numeric]), indices: [3]) }
        #expect(throws: (any Error).self) { try ExpressiveMomentDiscovery.parse(data([j, j]), indices: [3, 4]) }
        #expect(throws: (any Error).self) { try ExpressiveMomentDiscovery.parse(data([j]), indices: [0]) }
    }

    @Test func repeatedBatchProseCannotCertifyDifferentSourceWindows() {
        let a = ExpressiveMomentDiscovery.Judgement(index: 8,
            scene: "A continuous pan from a dirt road to a wide river view, with a visible power pole at the start.",
            composition: 0.8, humanMoment: 0, meaningfulMovement: 0.3, confidence: 0.9,
            recommendedDuration: 6, tags: ["river"])
        var b = a; b.index = 9
        #expect(ExpressiveMomentDiscovery.requiresIndependentRows([a, b]))
        b.scene = "A CONTINUOUS pan from a dirt road to a wide river view with a visible power pole at the start!"
        #expect(ExpressiveMomentDiscovery.requiresIndependentRows([a, b]))
        b.scene = "Gravel road and fence remain visible without a river or people."
        #expect(!ExpressiveMomentDiscovery.requiresIndependentRows([a, b]))
        #expect(!ExpressiveMomentDiscovery.requiresIndependentRows([a]))
    }

    @Test func literalOrdinaryRouteCannotBorrowAnExpressiveLandscapeScore() {
        var e = candidate().insights!.expressiveMoment!
        e.observation = "A gravel road curves left with a monument and trees in the background, showing a slight camera pan."
        e.composition = 0.8; e.meaningfulMovement = 0.8; e.humanMoment = 0.3
        #expect(e.value == 0.55 && !e.supportsObservation)
        e.observation = "A continuous panoramic view of a river winding through a green valley with trees and cloudy sky."
        #expect(e.value == 0.8 && e.supportsObservation)
        e.observation = "A buggy wheel and suspension visibly work over a rough gravel road."
        #expect(e.value == 0.8 && e.supportsObservation)
        e.observation = "A person in a jacket stands on a grassy slope with a sign, ending with a parked car."
        e.humanMoment = 0.8; e.meaningfulMovement = 0.3
        #expect(e.value == 0.55 && !e.supportsObservation)
    }

    @Test func softObservationDoesNotPadAndPreservesCaptureChronology() {
        var first = candidate(), second = candidate(start: 24)
        let asset = MediaAsset(originalURL: URL(fileURLWithPath: "/tmp/expressive-fixture.mov"), kind: .video,
            byteSize: 1, contentHash: "fixture", metadata: .init(duration: 100, creationDate: Date()))
        first.assetID = asset.id; second.assetID = asset.id
        first.tags = ["valley"]; second.tags = ["portrait"]
        first.insights?.editorialEvidence?.background = "valley"
        second.insights?.editorialEvidence?.background = "portrait"
        let analyses = [AnalysisResult(assetID: asset.id, analyzedContentHash: asset.contentHash,
            sceneTags: [], candidates: [second, first])]
        var plan = StoryPlan(prompt: "Больше красоты, дать кадрам время, сохранить хронологию", preset: .story,
            constraints: .init(targetDuration: 225), chapters: [],
            directorBrief: .init(mood: .calm, musicPolicy: .none, titlePolicy: .none))
        plan.narrativeBeatPlan = .init(pattern: .eventChapters, beats: [], reasons: [])
        let timeline = Timeline(storyPlanID: plan.id, items: [TimelineItem(candidateID: second.id,
            assetID: asset.id, kind: .video, sourceStart: 24, sourceDuration: 3, timelineStart: 0, timelineDuration: 3)])
        let edited = AutomaticEditorialAssembly.prepare(timeline: timeline, plan: plan,
            analyses: analyses, events: [], assets: [asset]).timeline
        #expect(edited.duration < 30)
        #expect(edited.items.filter { $0.kind == .video }.map(\.sourceStart) == [0, 24])
        #expect(edited.items.allSatisfy { $0.speed == 1 && $0.timelineDuration <= 10 })
    }

    private func countLimitedAssembly(separateAssets: Bool) -> (Timeline, [UUID]) {
        var candidates: [Candidate] = []
        var assets: [MediaAsset] = []
        for index in 0..<4 {
            if separateAssets || assets.isEmpty {
                assets.append(MediaAsset(originalURL: URL(fileURLWithPath: "/tmp/expressive-count-\(index).mov"),
                    kind: .video, byteSize: 1, contentHash: "count-\(index)",
                    metadata: .init(duration: 120, creationDate: Date(timeIntervalSince1970: Double(index * 1000)))))
            }
            var c = candidate(start: Double(index * 24), value: 0.95 - Double(index) * 0.08)
            c.assetID = assets.last!.id
            c.tags = ["view-\(index)"]
            c.insights?.editorialEvidence?.background = "view-\(index)"
            candidates.append(c)
        }
        let analyses = assets.map { asset in
            AnalysisResult(assetID: asset.id, analyzedContentHash: asset.contentHash,
                candidates: candidates.filter { $0.assetID == asset.id })
        }
        var plan = StoryPlan(prompt: "Больше красоты. Выбери 2 лучших фрагмента самостоятельно.", preset: .story,
            constraints: .init(targetDuration: 225, targetClipCount: 2), chapters: [],
            directorBrief: .init(mood: .calm, musicPolicy: .none, titlePolicy: .none))
        plan.narrativeBeatPlan = .init(pattern: .eventChapters, beats: [], reasons: [])
        let seed = candidates.last!
        let timeline = Timeline(storyPlanID: plan.id, items: [TimelineItem(candidateID: seed.id,
            assetID: seed.assetID, kind: .video, sourceStart: seed.sourceStart, sourceDuration: 3,
            timelineStart: 0, timelineDuration: 3)])
        return (AutomaticEditorialAssembly.prepare(timeline: timeline, plan: plan,
            analyses: analyses, events: [], assets: assets).timeline, Array(candidates.prefix(2).map(\.id)))
    }

    @Test func expressiveDiscoveryHonorsRequestedShotCountWithinOneSource() {
        let (edited, strongest) = countLimitedAssembly(separateAssets: false)
        let shots = edited.items.filter { $0.kind == .video }
        #expect(shots.count == 2)
        #expect(shots.compactMap(\.candidateID) == strongest)
        #expect(shots.allSatisfy { $0.speed == 1 && $0.timelineDuration >= 6 })
    }

    @Test func sourceCoverageDoesNotOverrideExplicitShotCount() {
        let (edited, strongest) = countLimitedAssembly(separateAssets: true)
        let shots = edited.items.filter { $0.kind == .video }
        #expect(shots.count == 2)
        #expect(shots.compactMap(\.candidateID) == strongest)
    }
}
