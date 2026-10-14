import Foundation
import Testing
@testable import VeloEditCore

@Suite struct ObservationalFramingPolicyTests {
    private func candidate(asset: UUID, index: Int, value: Double = 0.8, shift: Double = 0) -> Candidate {
        let start = Double(index * 24)
        var c = Candidate(assetID: asset, sourceStart: start, sourceDuration: 12,
            scores: .init(quality: value, interest: value, action: 0.1, stability: 0.8), tags: ["label-\(index)"],
            insights: CandidateInsights())
        c.insights?.editorialEvidence = .init(samples: (0..<12).map { n in
            .init(sourceTime: start + Double(n), subjectRegions: [
                .init(x: 0.56 + shift, y: 0.60, width: 0.08, height: 0.13),
                .init(x: 0.24 + shift, y: 0.25, width: 0.55, height: 0.65)],
                subjectKinds: [.face, .person], composition: (0..<16).map { $0 == index % 16 ? 1.0 : 0.0 },
                motionEnergy: 0.5, quality: 0.9, confidence: 0.9)
        }, usableRange: .init(start: start, end: start + 12), informationGain: 0.4, confidence: 0.8)
        c.insights?.expressiveMoment = .init(sourceStart: start, sourceEnd: start + 12, sampleTimes: [start, start + 6, start + 11],
            composition: value, humanMoment: value, meaningfulMovement: value, confidence: 0.9,
            recommendedDuration: 8, observation: "A driver and passenger with readable faces ride along a changing background", model: "fixture")
        return c
    }

    private func slots(_ candidates: [Candidate]) -> [AutomaticEditorialAssembly.Slot] {
        candidates.map { c in
            .init(item: .init(candidateID: c.id, assetID: c.assetID, kind: .video, sourceStart: c.sourceStart,
                sourceDuration: 6, timelineStart: 0, timelineDuration: 6), unit: .init(candidate: c), capacity: 180, frames: 180)
        }
    }

    @Test func motionAndDriftingLabelsCannotMultiplyOneMeasuredFraming() {
        let asset = UUID()
        let cs = (0..<5).map { candidate(asset: asset, index: $0, value: 0.65 + Double($0) * 0.05) }
        let selected = ObservationalFramingPolicy.pruning(slots(cs))
        #expect(selected.map(\.unit.id) == [cs[3].id, cs[4].id])
        #expect(!ShotFamilyClusterer().isHardDuplicate(.init(candidate: cs[0]), .init(candidate: cs[1])))
    }

    @Test func changedFramingOrUncertainAnchorsCannotProveARepeat() {
        let asset = UUID(), a = candidate(asset: UUID(), index: 0)
        let b = candidate(asset: asset, index: 1)
        #expect(!ObservationalFramingPolicy.sameFraming(.init(candidate: a), .init(candidate: b)))
        var same = candidate(asset: asset, index: 2)
        #expect(ObservationalFramingPolicy.sameFraming(.init(candidate: b), .init(candidate: same)))
        #expect(!ObservationalFramingPolicy.sameFraming(.init(candidate: b), .init(candidate: candidate(asset: asset, index: 3, shift: 0.17))))
        let incomplete = Array(same.insights!.editorialEvidence!.samples.prefix(2))
        same.insights?.editorialEvidence?.samples = incomplete
        #expect(!ObservationalFramingPolicy.sameFraming(.init(candidate: b), .init(candidate: same)))
    }

    @Test func confirmedActionAndLockedCandidatesRemainProtectedInRepeatedView() {
        let asset = UUID()
        var cs = (0..<4).map { candidate(asset: asset, index: $0) }
        cs[1].insights?.editorialEvidence?.actionDelta = 0.8
        cs[1].insights?.editorialEvidence?.completion = 0.9
        #expect(!ObservationalFramingPolicy.sameFraming(.init(candidate: cs[0]), .init(candidate: cs[1])))
        let selected = ObservationalFramingPolicy.pruning(slots(cs))
        #expect(selected.contains { $0.unit.id == cs[1].id })
        cs[1].locked = true
        #expect(ObservationalFramingPolicy.pruning(slots(cs)).contains { $0.unit.id == cs[1].id })
    }

    @Test func anotherPersonsChangingBodyCannotReplaceTheMeasuredFaceAnchor() {
        let asset = UUID()
        var cs = (0..<5).map { candidate(asset: asset, index: $0, value: 0.65 + Double($0) * 0.05) }
        for index in cs.indices {
            for n in cs[index].insights!.editorialEvidence!.samples.indices {
                cs[index].insights?.editorialEvidence?.samples[n].subjectKinds += [.person, .person]
                cs[index].insights?.editorialEvidence?.samples[n].subjectRegions += [
                    .init(x: 0.48, y: 0.42, width: 0.24, height: 0.47),
                    .init(x: 0.04, y: 0.1, width: 0.35 + Double(index) * 0.1, height: 0.86)]
            }
        }
        #expect(ObservationalFramingPolicy.pruning(slots(cs)).map(\.unit.id) == [cs[3].id, cs[4].id])
        var detached = cs[0]
        for n in detached.insights!.editorialEvidence!.samples.indices {
            detached.insights?.editorialEvidence?.samples[n].subjectKinds = [.face, .person]
            detached.insights?.editorialEvidence?.samples[n].subjectRegions = [
                .init(x: 0.56, y: 0.60, width: 0.08, height: 0.13),
                .init(x: 0.04, y: 0.10, width: 0.25, height: 0.65)]
        }
        #expect(!ObservationalFramingPolicy.sameFraming(.init(candidate: cs[0]), .init(candidate: detached)))
    }

    @Test func unmeasuredInsertCannotResetTheBudgetForAKnownView() {
        let asset = UUID()
        var cs = (0..<7).map { candidate(asset: asset, index: $0, value: 0.6 + Double($0) * 0.04) }
        cs[2].insights?.editorialEvidence?.samples = []
        cs[4] = candidate(asset: asset, index: 4, shift: 0.17)
        let selected = ObservationalFramingPolicy.pruning(slots(cs))
        #expect(selected.map(\.unit.id) == [cs[2].id, cs[4].id, cs[5].id, cs[6].id])
    }

    @Test func confirmedActionResetsObservationBudgetWithoutLosingChronology() {
        let asset = UUID()
        var cs = (0..<7).map { candidate(asset: asset, index: $0, value: 0.6 + Double($0) * 0.04) }
        cs[3].insights?.editorialEvidence?.actionDelta = 0.8
        cs[3].insights?.editorialEvidence?.completion = 0.9
        #expect(ObservationalFramingPolicy.pruning(slots(cs)).map(\.unit.id)
            == [cs[1].id, cs[2].id, cs[3].id, cs[5].id, cs[6].id])
    }

    @Test func lockedObservationsSurviveAcrossUnknownAnchors() {
        let asset = UUID()
        var cs = (0..<6).map { candidate(asset: asset, index: $0, value: 0.6 + Double($0) * 0.04) }
        cs[0].locked = true
        cs[2].insights?.editorialEvidence?.samples = []
        #expect(ObservationalFramingPolicy.pruning(slots(cs)).map(\.unit.id) == [cs[0].id, cs[2].id, cs[5].id])
    }

    @Test func completeLinkDoesNotTreatGradualCameraReframingAsOneView() {
        let asset = UUID()
        let cs = (0..<4).map { candidate(asset: asset, index: $0, value: 0.6 + Double($0) * 0.04, shift: Double($0) * 0.035) }
        #expect(ObservationalFramingPolicy.pruning(slots(cs)).map(\.unit.id) == [cs[1].id, cs[2].id, cs[3].id])
    }

    @Test func softAssemblyKeepsStrongestViewsWithoutRestoringAnUnobservedQualityPeak() {
        let asset = MediaAsset(originalURL: URL(fileURLWithPath: "/tmp/moving-portraits.mov"), kind: .video,
            byteSize: 1, contentHash: "portraits", metadata: .init(duration: 150, creationDate: Date(timeIntervalSince1970: 1_000)))
        let other = MediaAsset(originalURL: URL(fileURLWithPath: "/tmp/technical-peak.mov"), kind: .video,
            byteSize: 1, contentHash: "technical", metadata: .init(duration: 30, creationDate: Date(timeIntervalSince1970: 2_000)))
        let cs = (0..<5).map { candidate(asset: asset.id, index: $0, value: 0.65 + Double($0) * 0.05) }
        var technical = candidate(asset: other.id, index: 0, value: 0.99)
        technical.insights?.expressiveMoment = nil
        let analyses = [AnalysisResult(assetID: asset.id, analyzedContentHash: asset.contentHash, candidates: cs),
            AnalysisResult(assetID: other.id, analyzedContentHash: other.contentHash, candidates: [technical])]
        var plan = StoryPlan(prompt: "Больше красоты, дать кадрам время, без заполнения времени", preset: .story,
            constraints: .init(targetDuration: 225), chapters: [], directorBrief: .init(mood: .calm, musicPolicy: .none, titlePolicy: .none))
        plan.narrativeBeatPlan = .init(pattern: .eventChapters, beats: [], reasons: [])
        let timeline = Timeline(storyPlanID: plan.id, items: slots([cs[0]]).map(\.item))
        let soft = AutomaticEditorialAssembly.prepare(timeline: timeline, plan: plan, analyses: analyses,
            events: [], assets: [asset, other]).timeline
        #expect(soft.items.compactMap(\.candidateID) == [cs[3].id, cs[4].id])
        #expect(soft.duration <= 20 && soft.items.allSatisfy { $0.speed == 1 })
        // The existing default selection and source-coverage behavior remains
        // available when the user has not requested observational selection.
        plan.prompt = "Собери прежний фильм"
        let ordinary = AutomaticEditorialAssembly.prepare(timeline: timeline, plan: plan, analyses: analyses,
            events: [], assets: [asset, other]).timeline
        #expect(ordinary.items.contains { $0.assetID == other.id })
    }

    @Test func clipCountUnderstandsTheActuallyRequestedVariants() {
        #expect(PromptInterpreter.requestedClipCount(from: "Выбери 1 лучший фрагмент") == 1)
        #expect(PromptInterpreter.requestedClipCount(from: "Выбери 3 разных фрагмента") == 3)
        #expect(PromptInterpreter.requestedClipCount(from: "Оставь 2 отдельных плана") == 2)
        #expect(PromptInterpreter.requestedClipCount(from: "Темп 8–10 секунд") == nil)
        #expect(PromptInterpreter.requestedClipCount(from: "2026 год, 120 секунд, без титров") == nil)
    }
}
