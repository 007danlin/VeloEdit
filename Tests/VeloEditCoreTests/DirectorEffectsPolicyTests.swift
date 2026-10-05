import Foundation
import Testing
@testable import VeloEditCore

@Suite struct DirectorEffectsPolicyTests {
    private func fixture(_ policy: DirectorEffectsPolicy?) -> (StoryPlan, Timeline, [UUID: Candidate]) {
        let candidates = (0..<20).map { index in
            Candidate(assetID: UUID(), sourceStart: 0, sourceDuration: 3,
                scores: ClipScores(quality: 0.9, interest: 0.8, action: index.isMultiple(of: 2) ? 0.8 : 0.2, stability: 0.9))
        }
        let plan = StoryPlan(prompt: "Фильм о поездке", preset: .cinematic,
            constraints: .init(targetDuration: 60), chapters: [],
            directorBrief: .init(musicPolicy: .none, titlePolicy: .none, effectsPolicy: policy))
        let items = candidates.enumerated().map { index, candidate in
            TimelineItem(candidateID: candidate.id, assetID: candidate.assetID, kind: .video,
                sourceDuration: 3, timelineStart: Double(index) * 3, timelineDuration: 3)
        }
        return (plan, Timeline(storyPlanID: plan.id, items: items), Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0) }))
    }

    @Test func choicesPersistAndMissingChoicePreservesOldProjects() throws {
        for policy in DirectorEffectsPolicy.allCases {
            let (plan, _, _) = fixture(policy)
            let restored = try JSONDecoder.veloEdit.decode(StoryPlan.self, from: JSONEncoder.veloEdit.encode(plan))
            #expect(restored.directorBrief?.effectsPolicy == policy)
            #expect(DirectorEffectsPolicyEngine.policy(for: restored) == policy)
        }
        let (plan, timeline, candidates) = fixture(nil)
        var encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder.veloEdit.encode(plan.directorBrief)) as? [String: Any])
        encoded.removeValue(forKey: "effectsPolicy")
        let old = try JSONDecoder.veloEdit.decode(DirectorBrief.self, from: JSONSerialization.data(withJSONObject: encoded))
        #expect(old.effectsPolicy == nil)
        #expect(DirectorEffectsPolicyEngine.decorate(timeline, plan: plan, candidates: candidates) == timeline)
    }

    @Test func noneNormalAndManyProduceDifferentBudgetsThatSurviveFinalReview() {
        var counts: [Int] = []
        for policy in DirectorEffectsPolicy.allCases {
            let (plan, original, candidates) = fixture(policy)
            let decorated = DirectorEffectsPolicyEngine.decorate(original, plan: plan, candidates: candidates)
            let reviewed = EditorialIntentEnforcer.enforce(decorated, plan: plan)
            counts.append(reviewed.effectiveEffects.count)
            #expect(reviewed.effectiveEffects == decorated.effectiveEffects)
            #expect(reviewed.duration == original.duration)
            #expect(EditorialIntentEnforcer.enforce(reviewed, plan: plan) == reviewed)
            #expect(DirectorEffectsPolicyEngine.decorate(decorated, plan: plan, candidates: candidates).effectiveEffects.count == decorated.effectiveEffects.count,
                "Repeated composition decoration must not exceed the configured budget")
        }
        #expect(counts[0] == 0)
        #expect(counts[1] == 2)
        #expect(counts[2] == 6)
    }

    @Test func noEffectsRemovesPhotoMotionTransitionsAndEndingFadeOnDelivery() {
        let (plan, source, _) = fixture(DirectorEffectsPolicy.none)
        var timeline = source
        timeline.items[0].kind = .photo
        timeline.items[0].effect = ClipEffect.zoomIn.rawValue
        timeline.items[1].transition = TransitionStyle.glitch.rawValue
        timeline.transitionItems = [.init(style: .glitch, outgoingClipID: timeline.items[0].id,
            incomingClipID: timeline.items[1].id, startTime: 3)]
        timeline.effects = [.init(effectType: .glitch, startTime: 0, duration: 3)]
        timeline.endingFadeDuration = 2
        let result = TimelineDeliveryContract().validateAndRepair(timeline: timeline, plan: plan, assets: []).timeline
        #expect(result.effectiveEffects.isEmpty)
        #expect(result.effectiveTransitionItems.isEmpty)
        #expect(result.items.allSatisfy { $0.effect == nil && $0.transition == nil })
        #expect(result.endingFadeDuration == 0)
        #expect(result.duration == timeline.duration)
    }

    @Test func explicitNoEffectsTextWinsAndNoTransitionsStillAllowsClipEffects() {
        var (plan, timeline, candidates) = fixture(.many)
        plan.prompt = "Без эффектов"
        #expect(DirectorEffectsPolicyEngine.policy(for: plan) == DirectorEffectsPolicy.none)
        #expect(DirectorEffectsPolicyEngine.decorate(timeline, plan: plan, candidates: candidates).effectiveEffects.isEmpty)
        plan.prompt = "Без переходов"
        #expect(DirectorEffectsPolicyEngine.decorate(timeline, plan: plan, candidates: candidates).effectiveEffects.count == 6)
    }

    @Test func composerUsesEffectsAnswerEvenWithoutEffectsInPrompt() {
        var counts: [Int] = []
        for policy in DirectorEffectsPolicy.allCases {
            var (plan, _, candidates) = fixture(policy)
            let ordered = candidates.values.sorted { $0.id.uuidString < $1.id.uuidString }
            plan.chapters = [.init(title: "Поездка", candidateIDs: ordered.map(\.id))]
            let assets = ordered.map { candidate in
                MediaAsset(id: candidate.assetID, originalURL: URL(fileURLWithPath: "/tmp/\(candidate.assetID).mov"),
                    kind: .video, byteSize: 1, contentHash: candidate.assetID.uuidString,
                    metadata: .init(duration: 3, width: 1920, height: 1080))
            }
            let analyses = zip(assets, ordered).map { asset, candidate in
                AnalysisResult(assetID: asset.id, analyzedContentHash: asset.contentHash, candidates: [candidate])
            }
            let result = TimelineComposer().compose(plan: plan, assets: assets, analyses: analyses)
            counts.append(result.effectiveEffects.count)
            if policy == .none { #expect(result.effectiveTransitionItems.isEmpty) }
        }
        #expect(counts[0] == 0 && counts[1] > 0 && counts[2] > counts[1])
    }
}
