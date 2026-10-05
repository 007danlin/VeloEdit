// Original non-incremental search used as an independent equivalence oracle.
// Its final ordering follows the chronology contract introduced in September
// 2026; the old "move best closure to end" policy is intentionally not retained.
import Foundation
@testable import VeloEditCore

struct BaselineEditorialSequenceSearch: EditorialSequenceSearching {
    public init() {}
    public func sequences(hypothesis: NarrativeHypothesis, units: [EditorialUnit], families: ShotFamilyIndex, budget: ContentBudget) -> [EditorialSequence] {
        [sequence(hypothesis: hypothesis, units: units, families: families, target: budget.idealDuration, pacing: 0.5)]
    }

    public func sequence(hypothesis: NarrativeHypothesis, units: [EditorialUnit], families: ShotFamilyIndex, target: Double, pacing: Double, priority: [UUID: Double] = [:], maximumCount: Int? = nil) -> EditorialSequence {
        let clusterer = ShotFamilyClusterer()
        var remaining = units.sorted { $0.id.uuidString < $1.id.uuidString }
        var selected: [EditorialUnit] = []
        var discarded: [UUID: EditorialDiscardReason] = [:]
        var seconds = 0.0
        let useScenes = !(hypothesis.sceneOrder?.isEmpty ?? true)
        let scopeOrder = useScenes ? hypothesis.sceneOrder! : hypothesis.eventOrder ?? []
        let scopeRanks = Dictionary(uniqueKeysWithValues: scopeOrder.enumerated().map { ($0.element, $0.offset) })
        var minimumScopeRank = 0
        var budgetScopeRank: Int?
        var scopeStartSeconds = 0.0
        var scopeAllowance = target
        var scopeStartCount = 0
        var scopeCountAllowance = Int.max
        func scopeRank(_ unit: EditorialUnit) -> Int? { (useScenes ? unit.sceneID : unit.eventID).flatMap { scopeRanks[$0] } }
        while !remaining.isEmpty {
            if let maximumCount, selected.count >= maximumCount { break }
            let scored: [(EditorialUnit, Double)] = remaining.map { unit in
                (unit, selectionScore(unit, selected: selected, families: families) + priority[unit.id, default: 0])
            }.sorted { left, right in
                if left.1 != right.1 { return left.1 > right.1 }
                return left.0.id.uuidString < right.0.id.uuidString
            }
            var eligible = scored.filter { pair in
                let protected = pair.0.speechSeconds > 0 || pair.0.evidence.hasProgression && pair.0.evidence.completion >= 0.65
                return pair.1 > 0 && ((!protected && selected.isEmpty) || seconds + pair.0.preferredDuration(pacing: pacing) <= target + 0.05 || pair.0.candidate.locked)
            }
            if hypothesis.pattern == .eventChapters {
                // A candidate rejected by the current continuity edge can
                // become attractive again after a different scene. Once that
                // scene starts, previous chapter scopes must stay closed.
                eligible.removeAll { scopeRank($0.0).map { $0 < minimumScopeRank } ?? false }
                // Reserve time for later recorded activities before filling
                // the first chapter. Chronological sorting alone lets a rich
                // opening consume the whole film and silently drop its end.
                while let earliest = eligible.compactMap({ scopeRank($0.0) }).min() {
                    let ranks = Set(eligible.compactMap { scopeRank($0.0) })
                    if budgetScopeRank != earliest {
                        budgetScopeRank = earliest
                        scopeStartSeconds = seconds
                        scopeStartCount = selected.count
                        scopeAllowance = max(0, target - seconds) / Double(ranks.count)
                        scopeCountAllowance = maximumCount.map { max(1, ($0 - selected.count) / ranks.count) } ?? Int.max
                    }
                    let inScope = eligible.filter { scopeRank($0.0) == earliest }
                    let alreadyRepresented = selected.count > scopeStartCount
                    let withinBudget = inScope.filter {
                        $0.0.candidate.locked || !alreadyRepresented || ranks.count == 1 ||
                        (seconds - scopeStartSeconds + $0.0.preferredDuration(pacing: pacing) <= scopeAllowance + 0.05 && selected.count - scopeStartCount < scopeCountAllowance)
                    }
                    if !withinBudget.isEmpty {
                        eligible = withinBudget
                        break
                    }
                    minimumScopeRank = earliest + 1
                    eligible.removeAll { scopeRank($0.0).map { $0 < minimumScopeRank } ?? false }
                }
            }
            guard let best = eligible.first else { break }
            let duration = best.0.preferredDuration(pacing: pacing)
            if seconds + duration > target + 0.05 && !selected.isEmpty && !best.0.candidate.locked { break }
            selected.append(best.0)
            if hypothesis.pattern == .eventChapters, let rank = scopeRank(best.0) { minimumScopeRank = rank }
            seconds += duration
            remaining.removeAll { $0.id == best.0.id }
        }
        for unit in remaining {
            let closedScope = hypothesis.pattern == .eventChapters && (scopeRank(unit).map { $0 < minimumScopeRank } ?? false)
            discarded[unit.id] = unit.discardReason ?? (unit.evidence.hasHardOcclusion ? .unsafeCrop : unit.usableDuration < 0.5 ? .quality : selected.contains(where: { clusterer.similarity($0, unit).combined >= 0.78 }) ? .duplicate : closedScope ? .noNarrativeFit : .contentBudget)
        }
        var sources: [UUID] = []
        for unit in selected where !sources.contains(unit.candidate.assetID) { sources.append(unit.candidate.assetID) }
        selected = sources.flatMap { source in
            selected.filter { $0.candidate.assetID == source }.sorted {
                $0.sourceRange.start == $1.sourceRange.start
                    ? $0.id.uuidString < $1.id.uuidString : $0.sourceRange.start < $1.sourceRange.start
            }
        }
        let beats = selected.enumerated().map { index, unit -> EditorialNarrativeBeat in
            let purpose: EditorialNarrativePurpose
            if index == 0 { purpose = .hook }
            else if index == selected.count - 1 { purpose = .closure }
            else if unit.evidence.completion >= 0.65 && unit.evidence.hasProgression { purpose = .peak }
            else if selected[index - 1].eventID != unit.eventID || selected[index - 1].sceneID != unit.sceneID { purpose = .transition }
            else { purpose = .development }
            let minimal = hypothesis.pattern == .minimalMontage || hypothesis.pattern == .atmosphericObservation
            let fulfilled = purpose == .closure ? closureValue(unit) >= (minimal ? 0.5 : 0.65) : purpose == .peak ? unit.evidence.completion >= 0.65 : unit.quality >= 0.38
            return EditorialNarrativeBeat(candidateID: unit.id, purpose: purpose, viewerInformation: unit.candidate.insights?.sceneSummary ?? "Наблюдение за подтверждённым содержанием кадра", requiredChange: purpose == .peak ? 0.18 : 0, familyID: families.familyByUnitID[unit.id], minimumEvidence: purpose == .peak ? 0.65 : 0.38, durationRange: 0.5...max(0.5, unit.usableDuration), allocatedDuration: unit.preferredDuration(pacing: pacing), fulfilled: fulfilled)
        }
        return EditorialSequence(units: selected, beatPlan: NarrativeBeatPlan(pattern: hypothesis.pattern, beats: beats, reasons: hypothesis.reasons), discarded: discarded)
    }

    private func selectionScore(_ unit: EditorialUnit, selected: [EditorialUnit], families: ShotFamilyIndex) -> Double {
        let clusterer = ShotFamilyClusterer()
                let same = selected.filter { families.familyByUnitID[$0.id] == families.familyByUnitID[unit.id] }
                if unit.usableDuration < 0.5 { return -100 }
                if selected.contains(where: { clusterer.isHardDuplicate($0, unit, adjacent: false) }) { return -100 }
                if !same.isEmpty && !same.allSatisfy({ clusterer.addsState(unit, after: $0) }) { return -100 }
                if same.count >= 3 { return -100 }
                var continuity = 0.0
                if let prior = selected.last {
                    if clusterer.isHardDuplicate(prior, unit) { return -100 }
                    let lastTwo = selected.suffix(2)
                    if lastTwo.count == 2 && lastTwo.allSatisfy({ families.familyByUnitID[$0.id] == families.familyByUnitID[unit.id] }) { return -100 }
                    if prior.eventID == unit.eventID && prior.candidate.assetID == unit.candidate.assetID && unit.sourceRange.start < prior.sourceRange.start { continuity += 0.7 }
                    if prior.eventID != unit.eventID && selected.contains(where: { $0.eventID == unit.eventID && unit.eventID != nil }) { continuity += 1 }
                    continuity += EditorialContinuityGraph().edge(from: prior, to: unit).cost
                }
                let coverage: Double = selected.contains(where: { $0.eventID == unit.eventID }) ? 0.0 : 0.35
                let content = unit.quality * 0.4 + unit.evidence.informationGain * 0.5 + unit.evidence.actionDelta * 0.4
                let novelty: Double = same.isEmpty ? 0.5 : 0
                let audio = min(1.0, unit.speechSeconds / 5) * 0.2
                var value: Double = content
                value += audio
                value += coverage
                value += novelty
                value -= continuity
                value -= Double(same.count) * 0.3
                if unit.candidate.locked { value += 10 }
                return value
    }

    private func closureValue(_ unit: EditorialUnit) -> Double { max(unit.evidence.completion, unit.evidence.exitQuality * (unit.evidence.hasProgression ? 0.65 : 0.9)) }
}
