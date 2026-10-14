import Foundation
import Testing
@testable import VeloEditCore

@Suite struct CinematicAutomaticStylingTests {
    func fixture(count: Int = 20) -> (StoryPlan, Timeline, [MediaAsset], [AnalysisResult]) {
        let assets = (0..<count).map { index in
            MediaAsset(originalURL: URL(fileURLWithPath: "/tmp/automatic-cinema-\(index).mov"), kind: .video,
                byteSize: 1, contentHash: "cinema-\(index)",
                metadata: .init(duration: 30, width: 1920, height: 1080, frameRate: 60, hasAudio: true))
        }
        let analyses = assets.map { asset in
            AnalysisResult(assetID: asset.id, analyzedContentHash: asset.contentHash, candidates: [
                Candidate(assetID: asset.id, sourceStart: 2, sourceDuration: 3,
                    scores: .init(quality: 0.9, interest: 0.9, action: 0.1, stability: 0.9),
                    insights: .init(dynamics: 0.1, noise: 0.05, shake: 0.05, exposureQuality: 0.9))
            ], deepMediaVersion: DeepAnalysisCache.version)
        }
        let plan = StoryPlan(prompt: "Фильм о поездке", preset: .cinematic,
            constraints: .init(targetDuration: Double(count) * 3),
            chapters: [.init(title: "Поездка", candidateIDs: analyses.flatMap(\.directorCandidates).map(\.id))],
            directorBrief: .init(requestedDuration: Double(count) * 3, mood: .cinematic,
                musicPolicy: .none, sourceAudioPolicy: .preserve, titlePolicy: .none, effectsPolicy: .normal))
        let items = analyses.enumerated().map { index, analysis in
            let candidate = analysis.directorCandidates[0]
            return TimelineItem(candidateID: candidate.id, assetID: analysis.assetID, kind: .video,
                sourceStart: 2, sourceDuration: 3, timelineStart: Double(index) * 3, timelineDuration: 3,
                videoAdjustments: .init(crop: .fit))
        }
        return (plan, Timeline(storyPlanID: plan.id, items: items, originalAudioVolume: 1), assets, analyses)
    }

    func decorate(_ timeline: Timeline, _ plan: StoryPlan, _ assets: [MediaAsset], _ analyses: [AnalysisResult]) -> Timeline {
        DirectorEffectsPolicyEngine.decorate(timeline, plan: plan,
            candidates: Dictionary(uniqueKeysWithValues: analyses.flatMap(\.directorCandidates).map { ($0.id, $0) }),
            assets: assets, analyses: analyses)
    }

    @Test func questionnaireAloneAppliesReviewedSkillsWithoutChangingTimeOrSound() throws {
        var (plan, source, assets, analyses) = fixture()
        for (policy, count) in [(DirectorEffectsPolicy.normal, 2), (.many, 6)] {
            plan.directorBrief?.effectsPolicy = policy
            let result = decorate(source, plan, assets, analyses)
            #expect(result.effectiveEffects.count == count)
            #expect(result.effectiveEffects.allSatisfy { $0.effectType == .filmGrain && $0.explanation.joined().contains("effects/film-grain") })
            #expect(result.items == source.items && result.duration == source.duration)
            #expect(result.originalAudioVolume == 1 && result.effectiveAudioClips == source.effectiveAudioClips)
            #expect(decorate(result, plan, assets, analyses) == result)
            let decoded = try JSONDecoder.veloEdit.decode(Timeline.self, from: JSONEncoder.veloEdit.encode(result))
            #expect(decoded.items == result.items && decoded.effectiveEffects == result.effectiveEffects)
        }
        let composed = TimelineComposer().compose(plan: plan, assets: assets, analyses: analyses)
        #expect(composed.effectiveEffects.contains { $0.explanation.joined().contains("Локальный навык") })
        #expect(composed.items.allSatisfy { $0.speed == 1 })
    }

    @Test func unavailableOrUnmeasuredEvidenceNeverBecomesAutomaticKnowledge() {
        let (plan, source, assets, original) = fixture()
        for scenario in ["staleHash", "staleVersion", "noInsights", "noise", "exposure", "locked", "excluded", "wrongAsset"] {
            var analyses = original
            for index in analyses.indices {
                switch scenario {
                case "staleHash": analyses[index].analyzedContentHash = "old"
                case "staleVersion": analyses[index].deepMediaVersion = nil
                case "noInsights": analyses[index].candidates[0].insights = nil
                case "noise": analyses[index].candidates[0].insights?.noise = 0.8
                case "exposure": analyses[index].candidates[0].insights?.exposureQuality = 0.1
                case "locked": analyses[index].candidates[0].locked = true
                case "excluded": analyses[index].candidates[0].excluded = true
                default: analyses[index].candidates[0].assetID = UUID()
                }
            }
            let result = decorate(source, plan, assets, analyses)
            #expect(!result.effectiveEffects.contains { $0.explanation.joined().contains("Локальный навык") }, "\(scenario)")
        }
    }

    @Test func noEffectsLegacyMoodAndLocksRemainAuthoritative() {
        var (plan, source, assets, analyses) = fixture()
        plan.directorBrief?.effectsPolicy = nil
        #expect(decorate(source, plan, assets, analyses) == source)
        plan.directorBrief?.effectsPolicy = DirectorEffectsPolicy.none
        #expect(decorate(source, plan, assets, analyses).effectiveEffects.isEmpty)
        plan.directorBrief?.effectsPolicy = .many
        for mood in [DirectorNarrativeMood.calm, .dynamic] {
            plan.directorBrief?.mood = mood
            #expect(CinematicAutomaticStyling.choices(plan: plan, assets: assets, analyses: analyses).isEmpty)
        }
        plan.directorBrief?.mood = .cinematic
        for index in source.items.indices { source.items[index].locked = true }
        #expect(decorate(source, plan, assets, analyses) == source)
        plan.prompt = "Без эффектов"
        #expect(CinematicAutomaticStyling.choices(plan: plan, assets: assets, analyses: analyses).isEmpty)
    }

    @Test func vignetteRequiresTemporalSubjectEvidenceAndUnchangedFraming() {
        var (plan, source, assets, analyses) = fixture(count: 1)
        let track = SubjectTrack(kind: .person, label: "person", observations: [2.1, 3.5, 4.9].map {
            .init(timestamp: $0, region: .init(x: 0.35, y: 0.3, width: 0.3, height: 0.4), confidence: 0.95)
        }, meanConfidence: 0.95, visibility: 1, compositionQuality: 0.9)
        analyses[0].candidates[0].insights?.subjectTracking = .init(tracks: [track], mainSubjectID: track.id, confidence: 0.95, analyzedFrameCount: 3)
        #expect(decorate(source, plan, assets, analyses).effectiveEffects.first?.effectType == .vignette)
        source.items[0].sourceStart = 2.2
        source.items[0].sourceDuration = 2.6
        #expect(decorate(source, plan, assets, analyses).effectiveEffects.first?.effectType != .vignette)
        source.items[0].sourceStart = 2
        source.items[0].sourceDuration = 3
        analyses[0].candidates[0].insights?.subjectTracking?.tracks[0].observations[1].timestamp = 2.2
        #expect(decorate(source, plan, assets, analyses).effectiveEffects.first?.effectType == .filmGrain)
        analyses[0].candidates[0].insights?.subjectTracking?.tracks[0].observations[1].timestamp = 3.5
        source.items[0].videoAdjustments?.crop = .fill
        #expect(decorate(source, plan, assets, analyses).effectiveEffects.first?.effectType != .vignette)
        source.items[0].videoAdjustments?.crop = .fit
        analyses[0].candidates[0].insights?.subjectTracking?.tracks[0].observations.removeLast()
        #expect(decorate(source, plan, assets, analyses).effectiveEffects.first?.effectType == .filmGrain)
        var edge = track
        edge.observations[1].region = .init(x: 0.8, y: 0.3, width: 0.1, height: 0.2)
        analyses[0].candidates[0].insights?.subjectTracking = .init(tracks: [track, edge], mainSubjectID: track.id, confidence: 0.95, analyzedFrameCount: 3)
        #expect(decorate(source, plan, assets, analyses).effectiveEffects.first?.effectType == .filmGrain)
    }

    @Test func finalAssemblyRefreshPreservesManualEffectsAndRebindsAutomaticAccents() {
        let (plan, source, assets, analyses) = fixture()
        var cut = decorate(source, plan, assets, analyses)
        let manual = EffectTimelineItem(effectType: .contrast, startTime: 3, duration: 3, targetClipID: source.items[1].id)
        cut.effects?.append(manual)
        cut.items.removeFirst()
        cut.items = TimelineTiming.retimed(cut.items)
        let candidates = Dictionary(uniqueKeysWithValues: analyses.flatMap(\.directorCandidates).map { ($0.id, $0) })
        let refreshed = DirectorEffectsPolicyEngine.refreshAutomaticDecoration(cut, plan: plan, candidates: candidates, assets: assets, analyses: analyses)
        #expect(refreshed.effectiveEffects.contains(manual))
        #expect(refreshed.effectiveEffects.filter { $0.id != manual.id }.allSatisfy { effect in
            refreshed.items.contains { $0.id == effect.targetClipID && $0.timelineStart == effect.startTime && $0.timelineDuration == effect.duration }
        })
        #expect(refreshed.items == cut.items && refreshed.duration == cut.duration)
        #expect(DirectorEffectsPolicyEngine.refreshAutomaticDecoration(refreshed, plan: plan, candidates: candidates,
            assets: assets, analyses: analyses) == refreshed)
    }
}
