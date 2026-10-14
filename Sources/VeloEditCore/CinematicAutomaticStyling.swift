import Foundation

/// Questionnaire-driven use of reviewed knowledge during automatic composition.
/// This is deliberately a small policy over measured, cached evidence. It does
/// not turn analysis-only cards into commands or ask a model to invent tools.
enum CinematicAutomaticStyling {
    struct Choice: Sendable {
        var type: TimelineEffectType
        var explanation: String
    }

    static var availableEffectIDs: Set<String> {
        guard let base = CinematicKnowledgeBase.bundled else { return [] }
        return Set([("effects/film-grain", TimelineEffectType.filmGrain), ("effects/vignette", .vignette)]
            .compactMap { pair in approved(pair.0, type: pair.1, base: base).map { _ in pair.1.rawValue } })
    }

    static func choices(plan: StoryPlan, assets: [MediaAsset], analyses: [AnalysisResult]) -> [UUID: Choice] {
        guard DirectorVisualStyle(plan: plan).mood == .cinematic,
              let policy = DirectorEffectsPolicyEngine.policy(for: plan), policy != .none,
              let base = CinematicKnowledgeBase.bundled else { return [:] }
        let byAsset = Dictionary(assets.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var result: [UUID: Choice] = [:]
        let grain = approved("effects/film-grain", type: .filmGrain, base: base)
        let vignette = approved("effects/vignette", type: .vignette, base: base)
        for analysis in analyses {
            guard let asset = byAsset[analysis.assetID], asset.kind == .video,
                  !asset.excluded, !asset.missing, !asset.contentHash.isEmpty,
                  analysis.analyzedContentHash == asset.contentHash,
                  analysis.deepMediaVersion == DeepAnalysisCache.version,
                  let duration = asset.metadata.duration, duration.isFinite, duration > 0 else { continue }
            for candidate in analysis.directorCandidates {
                guard candidate.assetID == asset.id, !candidate.excluded, !candidate.locked,
                      candidate.sourceStart.isFinite, candidate.sourceDuration.isFinite,
                      candidate.sourceStart >= 0, candidate.sourceDuration >= 2.5,
                      candidate.sourceStart + candidate.sourceDuration <= duration + 0.001,
                      candidate.scores.quality >= 0.65, candidate.scores.stability >= 0.65,
                      let insight = candidate.insights, insight.exposureQuality >= 0.65,
                      insight.noise <= 0.20, insight.shake <= 0.25,
                      (insight.speech?.confidence ?? 0) < 0.65 else { continue }
                // Prefer the cheapest static accent when measured subject
                // positions permit it; otherwise a little grain supports the
                // requested film look without changing framing, time or sound.
                if let vignette, centeredSubjects(insight.subjectTracking, candidate: candidate,
                                                  confidence: vignette.minimumConfidence) {
                    result[candidate.id] = Choice(type: .vignette,
                        explanation: "Локальный навык \(vignette.id): киношное настроение; наблюдаемые объекты находятся вдали от краёв; база \(base.edition)")
                } else if let grain {
                    result[candidate.id] = Choice(type: .filmGrain,
                        explanation: "Локальный навык \(grain.id): киношное настроение; стабильный кадр с низким измеренным шумом; база \(base.edition)")
                }
            }
        }
        return result
    }

    private static func approved(_ id: String, type: TimelineEffectType, base: CinematicKnowledgeBase) -> CinematicTechnique? {
        guard let card = base.technique(id: id), card.status == .applicable,
              card.allowedCommands.contains("addEffect"), card.effectIDs.contains(type.rawValue),
              let preset = EffectPresetRegistry.all.first(where: { $0.id == type.rawValue }),
              preset.previewSupported, preset.renderSupported else { return nil }
        return card
    }

    private static func centeredSubjects(_ summary: SubjectTrackingSummary?, candidate: Candidate, confidence: Double) -> Bool {
        guard let summary, summary.confidence >= confidence, summary.analyzedFrameCount >= 3,
              let main = summary.mainSubject, main.visibility >= 0.8 else { return false }
        let observations = summary.tracks.flatMap(\.observations).filter {
            $0.timestamp >= candidate.sourceStart && $0.timestamp <= candidate.sourceStart + candidate.sourceDuration
        }
        // Observations must span the actual source range. One central still is
        // insufficient to claim that the subject stays clear of the vignette.
        let times = Set(observations.map(\.timestamp)).sorted()
        guard times.count >= 3, let first = times.first, let last = times.last,
              first <= candidate.sourceStart + candidate.sourceDuration * 0.2,
              last >= candidate.sourceStart + candidate.sourceDuration * 0.8,
              times.contains(where: { $0 >= candidate.sourceStart + candidate.sourceDuration * 0.4
                  && $0 <= candidate.sourceStart + candidate.sourceDuration * 0.6 }) else { return false }
        return observations.allSatisfy {
            $0.confidence >= confidence && $0.region.x >= 0.2 && $0.region.y >= 0.2
                && $0.region.x + $0.region.width <= 0.8 && $0.region.y + $0.region.height <= 0.8
        }
    }
}
