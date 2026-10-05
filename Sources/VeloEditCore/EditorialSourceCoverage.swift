import Foundation

public enum SourceCoverageReason: String, Codable, Hashable, Sendable {
    case included, excludedByUser, missingMedia, analysisUnavailable
    case noNarrativeFit, unsafeRanges, insufficientQuality, duplicate
    case durationBudget, clipLimit, selectionGap
}

/// Evidence for each input, including omissions. A failed shot is not evidence
/// that its entire recording is unusable, and selection is not narrative proof.
public struct SourceCoverageDecision: Codable, Hashable, Sendable {
    public var assetID: UUID
    public var reason: SourceCoverageReason
    public var candidateIDs: [UUID]
    public var relatedCandidateIDs: [UUID]
    public var detail: String
}

public enum EditorialSourceCoverage {
    static let minimumShotDuration = 1.5

    static func eligible(_ unit: EditorialUnit, rejected: Set<UUID>) -> Bool {
        !unit.candidate.excluded && !rejected.contains(unit.id) && unit.discardReason == nil
            && unit.quality >= 0.55 && unit.evidence.confidence >= 0.55
            && unit.usableDuration >= minimumShotDuration
    }

    static func minimumDuration(_ unit: EditorialUnit) -> Double {
        max(minimumShotDuration, EditorialMomentPolicy.protectedRange(unit)?.duration ?? 0)
    }

    static func decisions(timeline: Timeline, context: EditorialAnalysisContext, assets: [MediaAsset] = [], plan: StoryPlan? = nil) -> [SourceCoverageDecision] {
        let primary = timeline.items.filter { $0.overlay == nil && $0.kind != .title }
        let byID = Dictionary(uniqueKeysWithValues: context.units.map { ($0.id, $0) })
        let selected = primary.compactMap { item -> EditorialUnit? in
            guard let id = item.candidateID, var unit = byID[id] else { return nil }
            unit.candidate.sourceStart = item.sourceStart
            unit.candidate.sourceDuration = item.sourceDuration
            return unit
        }
        let rejected = Set((timeline.editorialBeatPlan?.discardedCandidates ?? [:]).filter { $0.value == .unsafeCrop }.keys)
        let groups = Dictionary(grouping: context.units, by: { $0.candidate.assetID })
        let assetIDs = assets.isEmpty ? (plan?.sourceCoverageAssetIDs ?? groups.keys.sorted { $0.uuidString < $1.uuidString }) : assets.map(\.id)
        let clusterer = ShotFamilyClusterer()
        return assetIDs.map { assetID in
            let units = groups[assetID] ?? []
            let asset = assets.first { $0.id == assetID }
            let used = primary.filter { $0.assetID == assetID }
            func result(_ reason: SourceCoverageReason, _ detail: String, candidates: [UUID] = [], related: [UUID] = []) -> SourceCoverageDecision {
                .init(assetID: assetID, reason: reason, candidateIDs: candidates, relatedCandidateIDs: related, detail: detail)
            }
            if !used.isEmpty { return result(.included, "Включено \(used.count) фрагментов", candidates: used.compactMap(\.candidateID)) }
            if asset?.excluded == true { return result(.excludedByUser, "Исходник исключён пользователем") }
            if asset?.missing == true { return result(.missingMedia, "Исходник недоступен") }
            if units.isEmpty { return result(.analysisUnavailable, "Нет доступных результатов анализа; причина пропуска не установлена") }
            let permitted = units.filter { plan?.constraints.excludeTags.isDisjoint(with: $0.candidate.tags) ?? true }
            if permitted.isEmpty { return result(.excludedByUser, "Содержание исключено явными требованиями к фильму", candidates: units.map(\.id)) }
            if units.allSatisfy({ $0.discardReason == .noNarrativeFit }) {
                return result(.noNarrativeFit, "Все моменты исключены проверкой контекста истории", candidates: units.map(\.id))
            }
            let eligible = permitted.filter { Self.eligible($0, rejected: rejected) }.sorted { $0.quality == $1.quality ? $0.id.uuidString < $1.id.uuidString : $0.quality > $1.quality }
            if eligible.isEmpty {
                let unsafe = units.allSatisfy { rejected.contains($0.id) || $0.evidence.hasHardOcclusion }
                return result(unsafe ? .unsafeRanges : .insufficientQuality,
                    unsafe ? "Все проверенные диапазоны отклонены по безопасности кадра" : "Нет подтверждённого пригодного диапазона длиной хотя бы 1,5 с",
                    candidates: units.map(\.id))
            }
            let novel = eligible.filter { unit in !selected.contains { clusterer.isHardDuplicate($0, unit, adjacent: false) } }
            if novel.isEmpty {
                let matches = selected.filter { prior in eligible.contains { clusterer.isHardDuplicate(prior, $0, adjacent: false) } }
                return result(.duplicate, "Каждый пригодный момент имеет подтверждённый повтор среди выбранных кадров", candidates: eligible.map(\.id), related: matches.map(\.id))
            }
            let best = novel[0]
            if let limit = plan?.constraints.targetClipCount, Set(primary.compactMap(\.assetID)).count >= limit {
                return result(.clipLimit, "Лимит \(limit) кадров не позволяет представить ещё один исходник", candidates: [best.id])
            }
            // Count one representative per selected source plus protected
            // moments. Long optional shots can be shortened to make room.
            let minimum = Dictionary(grouping: selected, by: { $0.candidate.assetID }).values.reduce(0.0) { total, units in
                let protected = units.filter { AutomaticEditorialAssembly.protected($0) }
                return total + (protected.isEmpty ? minimumShotDuration : protected.reduce(0) { $0 + minimumDuration($1) })
            }
            let shortestAlternative = novel.map(minimumDuration).min() ?? minimumShotDuration
            if let plan, minimum + shortestAlternative > (plan.contentBudget?.requestedDuration ?? plan.constraints.targetDuration) + 1 / max(1, timeline.frameRate) {
                return result(.durationBudget, "Минимальные неповторяющиеся моменты не помещаются в заданную длительность", candidates: [best.id])
            }
            return result(.selectionGap, "Есть пригодный неповторяющийся момент, но исходник целиком пропущен без подтверждённой причины", candidates: [best.id])
        }
    }

    static func chronologyViolations(timeline: Timeline, sourceMap: SourceMap?) -> [UUID] {
        let entries = Dictionary(uniqueKeysWithValues: (sourceMap?.entries ?? []).map { ($0.assetID, $0) })
        let ordered = timeline.items.filter { $0.overlay == nil && $0.kind != .title }.sorted { $0.timelineStart < $1.timelineStart }
        var previous: TimelineItem?
        var lastSourceStart: [UUID: Double] = [:]
        var violations: [UUID] = []
        for item in ordered {
            let tolerance = 1 / max(1, timeline.frameRate)
            var reversed = false
            if let id = item.assetID {
                reversed = lastSourceStart[id].map { item.sourceStart + tolerance < $0 } ?? false
                lastSourceStart[id] = item.sourceStart
            }
            if let prior = previous, let a = prior.assetID, let b = item.assetID, a != b,
               let first = entries[a], let second = entries[b],
               first.chronologyConfidence >= 0.90, second.chronologyConfidence >= 0.90,
               let startA = first.captureDate, let startB = second.captureDate {
                // Compare moments, so overlapping cameras can alternate while
                // the action progresses. An inferred rank is not proof of error.
                reversed = reversed || startB.addingTimeInterval(item.sourceStart + tolerance) < startA.addingTimeInterval(prior.sourceStart)
            }
            if reversed { violations.append(item.id) }
            previous = item
        }
        return violations
    }
}
