import Foundation

public struct ConservativeEditorialFallback: Sendable {
    public var story: StoryPlanVariant
    public var timeline: Timeline
}

public struct ConservativeFallbackBuilder: Sendable {
    public init() {}
    public func build(stories: [StoryPlanVariant], reviewed: [Timeline], assets: [MediaAsset], analyses: [AnalysisResult]) -> ConservativeEditorialFallback? {
        candidates(stories: stories, reviewed: reviewed, assets: assets, analyses: analyses, limit: 1).first
    }

    /// Bound both composition work and expensive rendered checks. A failed
    /// rendered candidate must not prevent trying another safe composition.
    public func candidates(stories: [StoryPlanVariant], reviewed: [Timeline], assets: [MediaAsset], analyses: [AnalysisResult], limit: Int = 6) -> [ConservativeEditorialFallback] {
        guard limit > 0 else { return [] }
        var results: [ConservativeEditorialFallback] = []
        let originals = analyses.flatMap(\.directorCandidates)
        var operations = 0
        for (story, timeline) in zip(stories, reviewed) {
            let disallowedItems = Set((timeline.editorialReview?.findings ?? []).filter {
                [.blankRenderedFrame, .foregroundOcclusion, .unsafeReframe, .dominantForegroundObject, .hardDuplicate].contains($0.kind)
            }.flatMap(\.itemIDs))
            let disallowedCandidates = Set(timeline.items.filter { disallowedItems.contains($0.id) }.compactMap(\.candidateID))
            // A repair must be allowed to replace the rejected shot with any
            // independently safe analyzed candidate. Restricting the pool to
            // clips already present in the failed montage only shortened the
            // same bad edit and made Content Budget underflow inevitable.
            let retained = originals.filter {
                !disallowedCandidates.contains($0.id) && !$0.excluded
                    && !EditorialUnit(candidate: $0).evidence.hasHardOcclusion
            }.sorted { $0.scores.composite == $1.scores.composite ? $0.id.uuidString < $1.id.uuidString : $0.scores.composite > $1.scores.composite }
            guard !retained.isEmpty else { continue }
            let sizes = Array(Set([retained.count, max(1, retained.count * 3 / 4), max(1, retained.count / 2)])).sorted(by: >)
            for count in sizes where operations < 6 {
                operations += 1
                let pool = Array(retained.prefix(count))
                let poolIDs = Set(pool.map(\.id))
                guard originals.filter(\.locked).allSatisfy({ poolIDs.contains($0.id) }) else { continue }
                var context = EditorialAnalysisContext(analyses: analyses)
                context.units.removeAll { !poolIDs.contains($0.id) }
                context.families = ShotFamilyClusterer().cluster(units: context.units)
                var plan = EditorialStoryPlanner.applying(to: story.plan, context: context, strategy: "quiet-observational")
                // Reducing the pool cannot lower the original acceptance contract.
                plan.contentBudget = story.plan.contentBudget
                plan.contentBudget?.durationConstraintStatus = .compromisedInsufficientContent
                plan.contentBudget?.reason += " Conservative fallback: длинная структура не прошла quality gates."
                var fallback = TimelineComposer().compose(plan: plan, assets: assets, analyses: analyses)
                // Fallback uses clean cuts. Generated overlap transitions can
                // both obscure source content and shift chapter timing. This
                // is a new, simpler composition and still must pass real probes.
                for index in fallback.items.indices where fallback.items[index].overlay == nil {
                    fallback.items[index].transition = nil
                }
                fallback.transitionItems = []
                plan.contentBudget?.reason += " Fallback использует чистые склейки без перекрытий."
                fallback = AutomaticFramingPolicy.applying(to: fallback, assets: assets, analyses: analyses)
                fallback.music = timeline.music
                fallback.directorRun = timeline.directorRun
                // A rough cut can be shorter than the delivery minimum even
                // when unused measured ranges support the requested film.
                // Run the same bounded assembly used at delivery before
                // rejecting it; all quality and rendered gates still apply.
                // Normalize every plain fallback before ranking it. A rough
                // cut can hit the total target while individual shots still
                // exceed the requested pacing; duration alone is insufficient.
                let assembled = AutomaticEditorialAssembly.prepare(timeline: fallback, plan: plan,
                    analyses: analyses, events: [], assets: assets, excluded: disallowedCandidates)
                fallback = assembled.timeline
                plan = assembled.plan
                fallback.editorialReview = EditorialQualityGate().review(timeline: fallback, plan: plan, analyses: analyses)
                fallback.editorialReview?.conservativeFallback = true
                if fallback.editorialReview?.rankingEligible == true {
                    results.append(ConservativeEditorialFallback(story: StoryPlanVariant(plan: plan, strategy: "conservative-fallback", seedScore: fallback.editorialReview?.editorialScore ?? 0), timeline: fallback))
                    if results.count >= limit { return results }
                }
            }
        }
        return results
    }
}
