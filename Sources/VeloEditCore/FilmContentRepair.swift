import Foundation

/// Persisted separately from the working edit: a failed experiment cannot
/// overwrite the last technically verified movie, including across restart.
public final class FilmVerifiedAlternative: Codable, Sendable {
    let timeline: Timeline
    let plan: StoryPlan
    let concreteDefects: Int
    init(timeline: Timeline, plan: StoryPlan, concreteDefects: Int) {
        self.timeline = timeline; self.plan = plan; self.concreteDefects = concreteDefects
    }
}
public struct FilmContentRepairState: Codable, Sendable {
    var attempts = 0
    var visited: Set<String> = []
    var best: FilmVerifiedAlternative?
    var reason: String? = nil
    var sourceSearch: FilmSourceSelectionSearch? = nil
    static let maximumAttempts = 2

    mutating func retain(timeline: Timeline, plan: StoryPlan, defects: Int) -> Bool {
        visited.insert(EditorialRenderSignature.signature(timeline))
        guard best == nil || defects < best!.concreteDefects else { return false }
        best = .init(timeline: timeline, plan: plan, concreteDefects: defects)
        return true
    }
    mutating func permit(signature: String, improved: Bool, defects: Int) -> Bool {
        guard defects > 0 else { reason = nil; return false }
        guard improved else { reason = "Повторная проверка не показала улучшения; сохранён лучший проверенный вариант"; return false }
        guard attempts < Self.maximumAttempts else { reason = "Лимит улучшений исчерпан; сохранён лучший проверенный вариант"; return false }
        guard visited.insert(signature).inserted else { reason = "Этот вариант уже проверен; повторная пересборка остановлена"; return false }
        attempts += 1
        reason = "Исправляю подтверждённое перекрытие кадра или обрезанное действие"
        return true
    }
}

/// Search over a finite set of measured candidates, before encoding a film.
/// Uncertain evidence excludes only that candidate, not neighboring footage.
/// No proposal is a certificate: every new interval still enters the source
/// reviewer, and the final export always has its own content review.
struct FilmSourceSelectionSearch: Codable, Sendable {
    static var currentRules: String { "source-search-v3|" + SelectedContentReviewer.version }
    var rulesVersion: String? = Self.currentRules
    var excluded: Set<UUID> = []
    var visited: Set<String> = []
    var attempts = 0

    static func selectionIdentity(_ timeline: Timeline) -> String {
        timeline.items.sorted { $0.timelineStart < $1.timelineStart }.map {
            [$0.assetID?.uuidString ?? "", $0.kind.rawValue,
             String($0.sourceStart.bitPattern), String($0.sourceDuration.bitPattern),
             String($0.timelineStart.bitPattern), String($0.timelineDuration.bitPattern),
             String($0.speed.bitPattern)].joined(separator: ":")
        }.joined(separator: "|")
    }

    mutating func alternative(timeline: Timeline, plan: StoryPlan, analyses: [AnalysisResult],
        events: [Event], assets: [MediaAsset], source: [ShotContentAssessment],
        rendered: [ShotContentAssessment] = [], recordTrace: Bool = true) -> (timeline: Timeline, plan: StoryPlan)? {
        let evidence = source + rendered
        let rejected = SelectedContentReviewer.repairCandidateIDs(evidence, analyses: analyses)
            .union(SelectedContentReviewer.uncertifiedCandidateIDs(evidence, timeline: timeline))
        // Each attempt must retire at least one previously tried candidate.
        // Thus recovery cannot loop, even when a model keeps abstaining.
        guard !rejected.subtracting(excluded).isEmpty else { return nil }
        excluded.formUnion(rejected)
        visited.insert(Self.selectionIdentity(timeline))
        // Preserve exact certified cuts, not merely their candidate IDs.
        let certified = timeline.items.filter { item in
            !(item.candidateID.map(excluded.contains) ?? false) && source.contains {
                $0.certifies(item: item, phase: "source", assets: assets)
            }
        }
        let mandatory: Set<TimelineDeliveryIssueKind> = [.exactDuration, .exactClipCount, .missingRequiredTag,
            .excludedTagPresent, .maximumTagShare, .preferredRoleTag, .canvasFormat, .forbiddenMusic, .originalAudioVolume]
        func admissible(_ proposal: (timeline: Timeline, plan: StoryPlan), excluding: Set<UUID>) -> Bool {
            guard !visited.contains(Self.selectionIdentity(proposal.timeline)),
                  Set(proposal.timeline.items.compactMap(\.candidateID)).isDisjoint(with: excluding),
                  AutomaticFilmDelivery.preservesDelivery(proposal.timeline, original: timeline, plan: plan) else { return false }
            let contract = TimelineDeliveryContract().validateAndRepair(timeline: proposal.timeline,
                plan: proposal.plan, assets: assets, analyses: analyses)
            return !contract.issues.contains(where: { mandatory.contains($0.kind) })
        }
        var trying = excluded
        typealias Proposal = (timeline: Timeline, plan: StoryPlan)
        typealias Trial = (proposal: Proposal, exclusions: Set<UUID>)
        var firstFeasible: Trial?
        var rearranged: Trial?
        var chosen: Trial?
        var referenceCoverage: Set<UUID>?
        let certifiedIDs = Set(certified.compactMap(\.candidateID))
        // A different candidate UUID can select almost the same uncertain
        // footage. Prefer a genuinely different measured interval first. This
        // is search ordering, not a negative certificate for adjacent footage;
        // retain the feasible overlapping proposal if no other cut can fulfill
        // the brief without moving already certified moments.
        let unresolved = timeline.items.filter { $0.candidateID.map(rejected.contains) ?? false }
        for _ in 0..<max(1, analyses.flatMap(\.directorCandidates).count) {
            let proposal = AutomaticEditorialAssembly.prepareForSourceReview(timeline: timeline, plan: plan,
                analyses: analyses, events: events, assets: assets, verifiedSource: source, excluded: trying)
            guard admissible(proposal, excluding: trying) else { break }
            let coverage = Set(proposal.timeline.items.compactMap(\.assetID))
            if referenceCoverage == nil { referenceCoverage = coverage }
            let preservesCoverage = referenceCoverage!.isSubset(of: coverage)
            let retained = certified.filter { old in proposal.timeline.items.contains {
                $0.assetID == old.assetID && $0.sourceStart == old.sourceStart && $0.sourceDuration == old.sourceDuration
            } }.count
            if retained < certified.count || !preservesCoverage {
                // Exact receipts are an optimization, not a demand to freeze
                // the whole edit. Native family/coverage rules may need to
                // replace another shot to satisfy the requested duration.
                // Keep that feasible edit only as a fallback; changed ranges
                // must earn new source and MP4 receipts in the normal pipeline.
                if rearranged == nil, preservesCoverage { rearranged = (proposal, trying) }
                if recordTrace {
                    PerformanceTrace.current?.event("assembly.deferred-reallocation", values: [
                        "retainedSourceRanges": Double(retained), "previousCertifiedRanges": Double(certified.count),
                        "preservesSourceCoverage": preservesCoverage ? 1 : 0])
                }
                // Native family/coverage allocation can let a high-ranked
                // replacement displace a certified survivor. Try the remaining
                // measured candidates before paying to review that survivor
                // again. These temporary exclusions belong to this trial only;
                // they are not negative content certificates.
                // Reusing receipts must not erase a recording represented by
                // the native feasible edit just because all its alternatives
                // were temporarily excluded by this optimization search.
                let alternatives = Set(proposal.timeline.items.compactMap(\.candidateID))
                    .subtracting(certifiedIDs).subtracting(trying)
                guard !alternatives.isEmpty else { break }
                trying.formUnion(alternatives)
                continue
            }
            if firstFeasible == nil { firstFeasible = (proposal, trying) }
            let aliases = Set(proposal.timeline.items.compactMap { item -> UUID? in
                guard let id = item.candidateID, !certified.contains(where: { $0.candidateID == id }),
                      unresolved.contains(where: { previous in
                          guard previous.assetID == item.assetID else { return false }
                          let overlap = max(0, min(previous.sourceStart + previous.sourceDuration, item.sourceStart + item.sourceDuration)
                              - max(previous.sourceStart, item.sourceStart))
                          return overlap >= 0.8 * min(previous.sourceDuration, item.sourceDuration)
                      }) else { return nil }
                return id
            })
            if aliases.isEmpty { chosen = (proposal, trying); break }
            guard !aliases.subtracting(trying).isEmpty else { break }
            trying.formUnion(aliases)
        }
        guard let trial = chosen ?? firstFeasible ?? rearranged else { return nil }
        let proposal = trial.proposal
        // A fallback must retain the exclusions under which it was actually
        // feasible, not the later trials that temporarily excluded its inputs.
        excluded = trial.exclusions
        if chosen == nil, firstFeasible == nil, recordTrace {
            PerformanceTrace.current?.event("assembly.rearranged-alternative", values: [
                "retainedSourceRanges": Double(certified.filter { old in proposal.timeline.items.contains {
                    $0.assetID == old.assetID && $0.sourceStart == old.sourceStart && $0.sourceDuration == old.sourceDuration
                } }.count), "previousCertifiedRanges": Double(certified.count)])
        }
        visited.insert(Self.selectionIdentity(proposal.timeline))
        attempts += 1
        return proposal
    }
}
