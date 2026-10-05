import Foundation

public enum EditorialNarrativePurpose: String, Codable, Hashable, Sendable {
    case hook, orientation, setup, development, escalation, peak, reaction, transition, closure
}

public enum EditorialNarrativePattern: String, Codable, Hashable, Sendable {
    case journeyDiscovery, eventChapters, preparationActionResult, problemAttemptOutcome
    case placePeopleActivity, atmosphericObservation, rapidHighlight, minimalMontage
}

public struct EditorialNarrativeBeat: Codable, Hashable, Sendable {
    public var momentDecision: EditorialMomentDecision? = nil
    public var candidateID: UUID
    public var purpose: EditorialNarrativePurpose
    public var viewerInformation: String
    public var requiredChange: Double
    public var familyID: String?
    public var minimumEvidence: Double
    public var durationRange: ClosedRange<Double>
    public var allocatedDuration: Double
    public var fulfilled: Bool
}

public struct NarrativeBeatPlan: Codable, Hashable, Sendable {
    public var discardedCandidates: [UUID: EditorialDiscardReason]? = nil
    public var pattern: EditorialNarrativePattern
    public var beats: [EditorialNarrativeBeat]
    public var reasons: [String]
}

public struct NarrativeHypothesis: Codable, Hashable, Sendable {
    public var eventOrder: [UUID]? = nil
    public var sceneOrder: [UUID]? = nil
    public var pattern: EditorialNarrativePattern
    public var evidenceCoverage: Double
    public var reasons: [String]
}

public struct EditorialSequence: Sendable {
    public var units: [EditorialUnit]
    public var beatPlan: NarrativeBeatPlan
    public var discarded: [UUID: EditorialDiscardReason]
}

public enum EditorialDiscardReason: String, Codable, Hashable, Sendable {
    case duplicate, quality, noNarrativeFit, unsafeCrop, unsupportedMedia, contentBudget
}

public protocol NarrativePlanning: Sendable {
    func hypotheses(events: [Event], units: [EditorialUnit], budget: ContentBudget, intent: DirectorIntent) -> [NarrativeHypothesis]
}

public struct NarrativeHypothesisEngine: NarrativePlanning {
    public init() {}
    public func hypotheses(events: [Event], units: [EditorialUnit], budget: ContentBudget, intent: DirectorIntent) -> [NarrativeHypothesis] {
        let usable = units.filter { $0.usableDuration >= 0.5 }
        let progressing = usable.filter { $0.evidence.hasProgression }
        let completed = progressing.filter { $0.evidence.completion >= 0.65 }
        func coverage(_ supported: [EditorialUnit]) -> Double {
            guard !usable.isEmpty else { return 0 }
            var seen = Set<UUID>()
            let evidence = supported.filter { seen.insert($0.id).inserted }.reduce(0) { $0 + $1.evidence.confidence * $1.quality }
            return (evidence / Double(usable.count)).clamped01
        }
        func states(_ unit: EditorialUnit) -> Set<String> { unit.evidence.samples.reduce(into: Set<String>()) { $0.formUnion($1.actionState) } }
        let preparation = usable.filter { !states($0).isDisjoint(with: ["preparation", "setup", "готовится", "подготовка"]) }
        let problems = usable.filter { !states($0).isDisjoint(with: ["problem", "failed", "failure", "проблема", "неудача"]) }
        let journey = usable.filter { !states($0).isDisjoint(with: ["departure", "arrival", "discovery", "прибытие", "отправление"]) }
        let places = usable.filter { $0.evidence.shotScale == .wide && $0.evidence.confidence >= 0.55 }
        let people = usable.filter { $0.evidence.samples.contains { !$0.subjectKinds.filter { [.person, .face, .cyclist].contains($0) }.isEmpty } }
        var values: [NarrativeHypothesis] = []
        if events.count > 1 {
            let covered = usable.filter { $0.eventID != nil }
            values.append(.init(pattern: .eventChapters, evidenceCoverage: coverage(covered), reasons: ["Подтверждены отдельные события; переходы требуют глав или визуальных связок"]))
        }
        if !journey.isEmpty && !completed.isEmpty { values.append(.init(pattern: .journeyDiscovery, evidenceCoverage: coverage(journey + completed), reasons: ["Evidence отправления/прибытия и завершения"])) }
        if !preparation.isEmpty && !completed.isEmpty { values.append(.init(pattern: .preparationActionResult, evidenceCoverage: coverage(preparation + completed), reasons: ["Подготовка и результат подтверждены temporal states"])) }
        if !problems.isEmpty && !completed.isEmpty { values.append(.init(pattern: .problemAttemptOutcome, evidenceCoverage: coverage(problems + completed), reasons: ["Есть наблюдаемая проблема, попытка и результат"])) }
        if !places.isEmpty && !people.isEmpty && !completed.isEmpty { values.append(.init(pattern: .placePeopleActivity, evidenceCoverage: coverage(places + people + completed), reasons: ["Подтверждены место, люди, действие и завершение"])) }
        if progressing.count >= 3 { values.append(.init(pattern: .rapidHighlight, evidenceCoverage: coverage(progressing), reasons: ["Несколько разных изменений действия"])) }
        let atmospheric = usable.filter { $0.evidence.atmosphereValue >= 0.65 && $0.evidence.confidence >= 0.55 }
        if !atmospheric.isEmpty { values.append(.init(pattern: .atmosphericObservation, evidenceCoverage: coverage(atmospheric), reasons: ["Подтверждённая атмосферная функция; кульминация не выдумывается"])) }
        let order = events.sorted { ($0.startDate ?? .distantFuture) < ($1.startDate ?? .distantFuture) }.map(\.id)
        for index in values.indices where values[index].pattern == .eventChapters { values[index].eventOrder = order }
        values = Array(values.prefix(4))
        values.append(.init(pattern: .minimalMontage, evidenceCoverage: coverage(usable), reasons: ["Короткое наблюдение без недоказанного сюжета"]))
        return values
    }
}

public protocol EditorialSequenceSearching: Sendable {
    func sequences(hypothesis: NarrativeHypothesis, units: [EditorialUnit], families: ShotFamilyIndex, budget: ContentBudget) -> [EditorialSequence]
}

public struct EditorialSequenceSearch: EditorialSequenceSearching {
    private struct Input: Hashable {
        var hypothesis: NarrativeHypothesis
        var units: [EditorialUnit]
        var families: ShotFamilyIndex
        var target: Double
        var pacing: Double
        var priority: [UUID: Double]
        var maximumCount: Int?
        var sourceOrder: [UUID: Int]
    }
    private final class CachedSequence: NSObject {
        let input: Input
        let result: EditorialSequence
        init(input: Input, result: EditorialSequence) { self.input = input; self.result = result }
    }
    private static let cache: NSCache<NSNumber, CachedSequence> = {
        let cache = NSCache<NSNumber, CachedSequence>()
        cache.countLimit = 8
        cache.totalCostLimit = 64 * 1_024 * 1_024
        return cache
    }()

    public init() {}
    public func sequences(hypothesis: NarrativeHypothesis, units: [EditorialUnit], families: ShotFamilyIndex, budget: ContentBudget) -> [EditorialSequence] {
        [sequence(hypothesis: hypothesis, units: units, families: families, target: budget.idealDuration, pacing: 0.5)]
    }

    public func sequence(hypothesis: NarrativeHypothesis, units: [EditorialUnit], families: ShotFamilyIndex, target: Double, pacing: Double, priority: [UUID: Double] = [:], maximumCount: Int? = nil, sourceOrder: [UUID: Int] = [:]) -> EditorialSequence {
        let input = Input(hypothesis: hypothesis, units: units, families: families, target: target,
                          pacing: pacing, priority: priority, maximumCount: maximumCount, sourceOrder: sourceOrder)
        var hasher = Hasher()
        hasher.combine(input)
        let key = NSNumber(value: hasher.finalize())
        // A hash only locates an entry: full value equality validates all frame
        // evidence, source windows, scopes, priorities and quality constraints.
        if let cached = Self.cache.object(forKey: key), cached.input == input {
            PerformanceTrace.current?.event("sequence.reused", values: ["units": Double(units.count)])
            return cached.result
        }
        let clusterer = ShotFamilyClusterer()
        // Inputs are immutable for this search. A selected prefix only grows:
        // compare each newly selected unit once, keeping the exact predicate.
        var duplicateChecks = SequenceDuplicateMemo()
        var remaining = units.sorted { $0.id.uuidString < $1.id.uuidString }
        var selected: [EditorialUnit] = []
        var selectedByFamily: [String?: [EditorialUnit]] = [:]
        var selectedEvents = Set<UUID?>()
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
            // Keep the large immutable evidence values in one array. Sorting
            // and filtering whole units at every selection step repeatedly
            // retains/copies their nested observations on large projects.
            let scored: [(index: Int, score: Double)] = remaining.indices.map { index in
                let unit = remaining[index]
                return (index, selectionScore(unit, selected: selected, families: families,
                    same: selectedByFamily[families.familyByUnitID[unit.id], default: []],
                    eventAlreadySelected: selectedEvents.contains(unit.eventID),
                    hasDuplicate: unit.usableDuration >= 0.5 && duplicateChecks.containsDuplicate(of: unit, in: selected)) + priority[unit.id, default: 0])
            }.sorted { left, right in
                if left.score != right.score { return left.score > right.score }
                return remaining[left.index].id.uuidString < remaining[right.index].id.uuidString
            }
            var eligible = scored.filter { pair in
                let unit = remaining[pair.index]
                let protected = unit.speechSeconds > 0 || unit.evidence.hasProgression && unit.evidence.completion >= 0.65
                return pair.score > 0 && ((!protected && selected.isEmpty) || seconds + unit.preferredDuration(pacing: pacing) <= target + 0.05 || unit.candidate.locked)
            }
            if hypothesis.pattern == .eventChapters {
                // A candidate rejected by the current continuity edge can
                // become attractive again after a different scene. Once that
                // scene starts, previous chapter scopes must stay closed.
                eligible.removeAll { scopeRank(remaining[$0.index]).map { $0 < minimumScopeRank } ?? false }
                // Reserve time for later recorded activities before filling
                // the first chapter. Chronological sorting alone lets a rich
                // opening consume the whole film and silently drop its end.
                while let earliest = eligible.compactMap({ scopeRank(remaining[$0.index]) }).min() {
                    let ranks = Set(eligible.compactMap { scopeRank(remaining[$0.index]) })
                    if budgetScopeRank != earliest {
                        budgetScopeRank = earliest
                        scopeStartSeconds = seconds
                        scopeStartCount = selected.count
                        scopeAllowance = max(0, target - seconds) / Double(ranks.count)
                        scopeCountAllowance = maximumCount.map { max(1, ($0 - selected.count) / ranks.count) } ?? Int.max
                    }
                    let inScope = eligible.filter { scopeRank(remaining[$0.index]) == earliest }
                    let alreadyRepresented = selected.count > scopeStartCount
                    let withinBudget = inScope.filter { pair in
                        let unit = remaining[pair.index]
                        return unit.candidate.locked || !alreadyRepresented || ranks.count == 1 ||
                        (seconds - scopeStartSeconds + unit.preferredDuration(pacing: pacing) <= scopeAllowance + 0.05 && selected.count - scopeStartCount < scopeCountAllowance)
                    }
                    if !withinBudget.isEmpty {
                        eligible = withinBudget
                        break
                    }
                    minimumScopeRank = earliest + 1
                    eligible.removeAll { scopeRank(remaining[$0.index]).map { $0 < minimumScopeRank } ?? false }
                }
            }
            guard let bestIndex = eligible.first?.index else { break }
            let best = remaining[bestIndex]
            let duration = best.preferredDuration(pacing: pacing)
            if seconds + duration > target + 0.05 && !selected.isEmpty && !best.candidate.locked { break }
            selected.append(best)
            selectedByFamily[families.familyByUnitID[best.id], default: []].append(best)
            selectedEvents.insert(best.eventID)
            if hypothesis.pattern == .eventChapters, let rank = scopeRank(best) { minimumScopeRank = rank }
            seconds += duration
            remaining.removeAll { $0.id == best.id }
        }
        for unit in remaining {
            let closedScope = hypothesis.pattern == .eventChapters && (scopeRank(unit).map { $0 < minimumScopeRank } ?? false)
            discarded[unit.id] = unit.discardReason ?? (unit.evidence.hasHardOcclusion ? .unsafeCrop : unit.usableDuration < 0.5 ? .quality : selected.contains(where: { clusterer.similarity($0, unit).combined >= 0.78 }) ? .duplicate : closedScope ? .noNarrativeFit : .contentBudget)
        }
        // Role/closure scores select content, not time travel. Keep stable
        // source order even for the pre-assembly variants and speech overlays.
        var order = sourceOrder
        for unit in selected where order[unit.candidate.assetID] == nil {
            order[unit.candidate.assetID] = (order.values.max() ?? -1) + 1
        }
        selected.sort {
            let a = order[$0.candidate.assetID, default: Int.max], b = order[$1.candidate.assetID, default: Int.max]
            if a != b { return a < b }
            if $0.sourceRange.start != $1.sourceRange.start { return $0.sourceRange.start < $1.sourceRange.start }
            return $0.id.uuidString < $1.id.uuidString
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
        let result = EditorialSequence(units: selected, beatPlan: NarrativeBeatPlan(pattern: hypothesis.pattern, beats: beats, reasons: hypothesis.reasons), discarded: discarded)
        let cost = units.reduce(0) { total, unit in
            total + 2_048 + unit.evidence.samples.reduce(0) { $0 + 512 + $1.composition.count * 8 }
        } + selected.count * 1_024
        if cost <= 64 * 1_024 * 1_024 {
            Self.cache.setObject(CachedSequence(input: input, result: result), forKey: key, cost: cost)
        }
        PerformanceTrace.current?.event("sequence.computed", values: ["units": Double(units.count)])
        return result
    }

    private func selectionScore(_ unit: EditorialUnit, selected: [EditorialUnit], families: ShotFamilyIndex,
                                same: [EditorialUnit], eventAlreadySelected: Bool, hasDuplicate: Bool) -> Double {
        let clusterer = ShotFamilyClusterer()
                if unit.usableDuration < 0.5 { return -100 }
                if hasDuplicate { return -100 }
                if same.count >= 3 { return -100 }
                if !same.isEmpty && !same.allSatisfy({ clusterer.addsState(unit, after: $0) }) { return -100 }
                var continuity = 0.0
                if let prior = selected.last {
                    if clusterer.isHardDuplicate(prior, unit) { return -100 }
                    let lastTwo = selected.suffix(2)
                    if lastTwo.count == 2 && lastTwo.allSatisfy({ families.familyByUnitID[$0.id] == families.familyByUnitID[unit.id] }) { return -100 }
                    if prior.eventID == unit.eventID && prior.candidate.assetID == unit.candidate.assetID && unit.sourceRange.start < prior.sourceRange.start { continuity += 0.7 }
                    if prior.eventID != unit.eventID && (unit.eventID != nil && eventAlreadySelected) { continuity += 1 }
                    continuity += EditorialContinuityGraph().edge(from: prior, to: unit).cost
                }
                let coverage: Double = eventAlreadySelected ? 0.0 : 0.35
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

public enum EditorialStoryPlanner {
    public static func applying(to source: StoryPlan, context input: EditorialAnalysisContext, events: [Event] = [], strategy: String = "contextual", priority: [UUID: Double] = [:]) -> StoryPlan {
        var plan = source
        var context = input
        // Repair/fallback can receive a filtered candidate pool without the
        // full Event objects. The verified scopes already in StoryPlan must
        // survive that boundary; otherwise the search can interleave events.
        for index in context.units.indices where context.units[index].eventID == nil {
            if let chapter = source.chapters.first(where: { $0.candidateIDs.contains(context.units[index].id) }) {
                context.units[index].eventID = chapter.eventID
                context.units[index].sceneID = chapter.eventSceneID
            }
        }
        let style = plan.autonomousDecision?.finalStyle ?? DirectorStyleVector()
        let requested = plan.directorBrief?.explicitRequestedDuration ?? plan.autonomousDecision?.duration.contentBudgetDecision?.requestedDuration ?? plan.constraints.targetDuration
        var decision = ContentBudgetEngine().budget(units: context.units, families: context.families, requestedDuration: requested, requestIsExplicit: plan.directorBrief?.explicitRequestedDuration != nil || AutonomousDurationOptimizer.requestContainsExplicitDuration(plan.prompt), style: style)
        if context.expandedMiningPerformed {
            decision.requiresExpandedMining = false
            if decision.durationConstraintStatus == .satisfied { decision.durationConstraintStatus = .expandedSearchSatisfied }
        }
        // Evidence enrichment can increase the independently supported lower
        // bound after AutonomousDirector chose its earlier target. Keeping the
        // stale shorter target makes TimelineComposer truncate an otherwise
        // feasible sequence and guarantees an underflow. A genuinely explicit
        // short request is already reflected in safeRange.lowerBound by the
        // budget engine, so this reconciliation never overrides that intent.
        plan.constraints.targetDuration = FilmDurationRequirement.parse(prompt: plan.prompt,
            explicitSeconds: plan.directorBrief?.explicitRequestedDuration, mode: plan.directorBrief?.durationMode).target ?? min(
            decision.budget.safeRange.upperBound,
            max(plan.constraints.targetDuration, decision.budget.safeRange.lowerBound)
        )
        var hypotheses = NarrativeHypothesisEngine().hypotheses(events: events, units: context.units, budget: decision.budget, intent: .createFilm)
        if !hypotheses.contains(where: { $0.pattern == .eventChapters }) {
            let present = Set(context.units.filter { $0.usableDuration > 0 }.compactMap(\.eventID))
            var seenEvents = Set<UUID>()
            let ordered = ((source.eventStory?.entries.map(\.eventID) ?? []) + source.chapters.compactMap(\.eventID)).filter { present.contains($0) && seenEvents.insert($0).inserted }
            if ordered.count > 1 {
                hypotheses.insert(NarrativeHypothesis(eventOrder: ordered, pattern: .eventChapters, evidenceCoverage: Double(context.units.filter { $0.eventID != nil }.count) / Double(max(1, context.units.count)), reasons: ["Сохранены подтверждённые события и их порядок при structural repair/fallback"]), at: 0)
            }
        }
        let presentScenes = Set(context.units.filter { $0.usableDuration > 0 }.compactMap(\.sceneID))
        var seenScenes = Set<UUID>()
        let sceneOrder = ((source.eventStory?.entries.flatMap(\.sceneIDs) ?? []) + source.chapters.compactMap(\.eventSceneID)).filter { presentScenes.contains($0) && seenScenes.insert($0).inserted }
        if sceneOrder.count > 1 {
            if let index = hypotheses.firstIndex(where: { $0.pattern == .eventChapters }) { hypotheses[index].sceneOrder = sceneOrder }
            else {
                hypotheses.insert(NarrativeHypothesis(sceneOrder: sceneOrder, pattern: .eventChapters, evidenceCoverage: Double(context.units.filter { $0.sceneID != nil }.count) / Double(max(1, context.units.count)), reasons: ["Подтверждённые сцены/занятия внутри одного события сохраняют порядок глав"]), at: 0)
            }
        }
        let hypothesis = strategy == "quiet-observational" ? hypotheses.first(where: { $0.pattern == .eventChapters || $0.pattern == .atmosphericObservation }) ?? hypotheses.last! : hypotheses.first!
        // The independently supported safe floor is a hard generation target,
        // not merely a later verifier threshold. Using the earlier ideal here
        // silently shortened enriched/repaired plans below their own budget.
        let target = decision.requestedDuration.map { min($0, decision.supportedDuration) }
            ?? min(decision.supportedDuration, max(plan.constraints.targetDuration, decision.budget.safeRange.lowerBound))
        var sourceOrder = Dictionary(uniqueKeysWithValues: (source.eventStory?.diagnostics?.sourceMap?.entries ?? []).map { ($0.assetID, $0.order) })
        let byCandidate = Dictionary(uniqueKeysWithValues: context.units.map { ($0.id, $0.candidate.assetID) })
        for id in source.chapters.flatMap(\.candidateIDs) {
            if let asset = byCandidate[id], sourceOrder[asset] == nil { sourceOrder[asset] = (sourceOrder.values.max() ?? -1) + 1 }
        }
        plan.episodePlan = EditorialEpisodePlan.build(units: context.units, sourceOrder: sourceOrder)
        let sequence = EditorialSequenceSearch().sequence(hypothesis: hypothesis, units: context.units, families: context.families, target: target, pacing: plan.constraints.pacing, priority: priority, maximumCount: plan.constraints.targetClipCount, sourceOrder: sourceOrder)
        let originalChapters = plan.chapters
        let selectedCapacity = sequence.units.reduce(0) { $0 + $1.usableDuration }
        if let requested = decision.requestedDuration, selectedCapacity + 0.001 < requested {
            decision.durationConstraintStatus = .compromisedInsufficientContent
            decision.reason += " Ограничения последовательности поддерживают \(Int(selectedCapacity.rounded())) с."
        }
        let allocated = sequence.beatPlan.beats.reduce(0) { $0 + $1.allocatedDuration }
        if allocated + 0.05 < decision.budget.safeRange.lowerBound {
            if context.expandedMiningPerformed, allocated >= 0.5 {
                // The source-wide budget can be larger than a coherent edit:
                // family repetition and chronology deliberately reject some
                // otherwise usable seconds. Once full mining has completed,
                // that sequence capacity is the honest final ceiling. Keeping
                // the old global floor here creates an impossible retry loop.
                let previousFloor = decision.budget.safeRange.lowerBound
                let sequenceCeiling = min(decision.supportedDuration, allocated)
                let sequenceFloor = min(previousFloor, sequenceCeiling * 0.8)
                decision.supportedDuration = sequenceCeiling
                decision.budget.idealDuration = min(decision.budget.idealDuration, sequenceCeiling)
                decision.budget.safeRange = sequenceFloor...sequenceCeiling
                decision.budget.absoluteCeiling = min(decision.budget.absoluteCeiling, sequenceCeiling)
                decision.durationConstraintStatus = .compromisedInsufficientContent
                decision.requiresExpandedMining = false
                decision.feasibility = decision.requestedDuration.map { min(1, sequenceCeiling / max(0.001, $0)) } ?? 1
                if !decision.budget.limitingFactors.contains(.insufficientContent) {
                    decision.budget.limitingFactors.append(.insufficientContent)
                }
                decision.reason += " Полный поиск завершён: связная неповторяющаяся последовательность поддерживает \(Int(sequenceCeiling.rounded())) с вместо глобального минимума \(Int(previousFloor.rounded())) с; недостижимый хвост не заполняется повторами."
            } else {
                decision.requiresExpandedMining = true
                decision.durationConstraintStatus = .compromisedInsufficientContent
                decision.reason += " Последовательность \(allocated) с ниже безопасного минимума \(decision.budget.safeRange.lowerBound) с; необходим дополнительный поиск, автоматический pass запрещён."
            }
        }
        plan.chapters = sequence.beatPlan.beats.map { beat in
            let unit = context.units.first { $0.id == beat.candidateID }
            let prior = originalChapters.first { $0.candidateIDs.contains(beat.candidateID) }
                ?? originalChapters.first { $0.eventSceneID != nil && $0.eventSceneID == unit?.sceneID }
            let scene = events.flatMap(\.effectiveScenes).first { $0.id == unit?.sceneID }
            let role: StoryRole
            switch beat.purpose {
            case .hook: role = .intro
            case .closure: role = .outro
            case .peak: role = .climax
            case .reaction: role = .reaction
            case .orientation, .setup: role = .setup
            case .transition: role = .bRoll
            default: role = .buildup
            }
            return StoryChapter(title: prior?.title ?? scene?.title ?? "", candidateIDs: [beat.candidateID], role: role, purpose: beat.viewerInformation, eventID: prior?.eventID ?? unit?.eventID, eventSceneID: prior?.eventSceneID ?? unit?.sceneID, chapterCardTitle: prior != nil ? prior?.chapterCardTitle : (scene.map { SmartTitleEngine.isStructuralPlaceholder($0.title) ? nil : $0.title } ?? nil), isColdOpen: prior?.isColdOpen, allocatedDuration: beat.allocatedDuration, coveragePlan: prior?.coveragePlan)
        }
        plan.contentBudget = decision
        plan.narrativeBeatPlan = sequence.beatPlan
        var discarded = source.narrativeBeatPlan?.discardedCandidates ?? [:]
        discarded.merge(sequence.discarded) { _, current in current }
        for selected in sequence.units { discarded.removeValue(forKey: selected.id) }
        plan.narrativeBeatPlan?.discardedCandidates = discarded
        plan.constraints.targetDuration = target
        if var story = plan.eventStory {
            let present = Set(plan.chapters.compactMap(\.eventID))
            story.entries.removeAll { !present.contains($0.eventID) }
            for i in story.entries.indices {
                story.entries[i].allocatedDuration = plan.chapters.filter { $0.eventID == story.entries[i].eventID }.reduce(0) { $0 + ($1.allocatedDuration ?? 0) }
            }
            plan.eventStory = story
        }
        return plan
    }
}

/// Lifetime is one search over immutable units and an append-only selected list.
/// IDs locate the fixed unit; this is deliberately not a persistent/global cache.
struct SequenceDuplicateMemo {
    private var checks: [UUID: (count: Int, duplicate: Bool)] = [:]

    mutating func containsDuplicate(of unit: EditorialUnit, in selected: [EditorialUnit]) -> Bool {
        let previous = checks[unit.id] ?? (count: 0, duplicate: false)
        precondition(selected.count >= previous.count)
        let duplicate = previous.duplicate || selected.dropFirst(previous.count).contains {
            ShotFamilyClusterer().isHardDuplicate($0, unit, adjacent: false)
        }
        checks[unit.id] = (selected.count, duplicate)
        return duplicate
    }
}
