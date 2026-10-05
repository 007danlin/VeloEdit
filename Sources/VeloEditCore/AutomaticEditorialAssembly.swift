import Foundation

/// The final automatic edit uses the same measured ranges as verification.
/// It runs after P6 (which can add/remove candidates), before rendering, and
/// again after a rendered safety exclusion. No file names or project IDs are
/// inputs to editorial decisions.
enum AutomaticEditorialAssembly {
    static let marker = "Automatic editorial assembly v3: request duration"

    struct Slot {
        var item: TimelineItem
        var unit: EditorialUnit
        var capacity: Int
        var frames: Int
    }

    static func prepare(timeline source: Timeline, plan original: StoryPlan, analyses: [AnalysisResult], events: [Event], assets: [MediaAsset] = [], excluded: Set<UUID> = [], preferShortShots: Bool = true) -> (timeline: Timeline, plan: StoryPlan) {
        // Connected/manual edits and retiming carry their own contracts. This
        // policy owns the plain, automatically generated primary storyline.
        guard original.narrativeBeatPlan != nil, !source.items.isEmpty,
              source.items.allSatisfy({ !$0.locked && $0.overlay == nil && ($0.kind == .video || $0.kind == .photo) && !$0.isFreezeFrame && !$0.isReversed && $0.speedRamp == nil && abs($0.speed - 1) < 0.001 }),
              source.effectiveAudioClips.isEmpty else { return (source, original) }
        let context = EditorialAnalysisContext(analyses: analyses, events: events)
        let sourceMap = assets.isEmpty ? original.eventStory?.diagnostics?.sourceMap : SourceTimelineAnalyzer().analyze(assets: assets, analyses: analyses)
        let units = Dictionary(uniqueKeysWithValues: context.units.map { ($0.id, $0) })
        let kinds = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0.kind) })
        func itemKind(_ unit: EditorialUnit) -> TimelineItemKind {
            kinds[unit.candidate.assetID] == .photo || unit.candidate.tags.contains("photo") ? .photo : .video
        }
        let allowedAssets = assets.isEmpty ? nil : Set(assets.filter { !$0.excluded && !$0.missing && ($0.kind == .video || $0.kind == .photo) }.map(\.id))
        let forbidden = analyses.flatMap(\.directorCandidates).filter { $0.excluded || !original.constraints.excludeTags.isDisjoint(with: $0.tags) }
        var artisticOmissions = Set<UUID>()
        func allowed(_ unit: EditorialUnit) -> Bool {
            (allowedAssets?.contains(unit.candidate.assetID) ?? true)
                && !artisticOmissions.contains(unit.id)
                && !unit.candidate.excluded && unit.discardReason == nil && !unit.evidence.hasHardOcclusion
                && original.constraints.excludeTags.isDisjoint(with: unit.candidate.tags)
                && !forbidden.contains { $0.assetID == unit.candidate.assetID && $0.sourceStart < unit.sourceRange.end && $0.sourceStart + $0.sourceDuration > unit.sourceRange.start }
        }
        let fps = max(1, source.frameRate)
        let maximumShot: Double = switch DirectorVisualStyle(plan: original).mood {
        case .dynamic: 8
        case .calm: 10
        case .cinematic: 12
        }
        var plan = original
        plan.episodePlan = EditorialEpisodePlan.build(units: context.units,
            sourceOrder: Dictionary(uniqueKeysWithValues: (sourceMap?.entries ?? []).map { ($0.assetID, $0.order) }))
        var timeline = source
        var rejected = excluded
        for (id, reason) in source.editorialBeatPlan?.discardedCandidates ?? [:] where reason == .unsafeCrop { rejected.insert(id) }
        var items = source.items.filter { item in
            item.candidateID.flatMap { units[$0] }.map { !rejected.contains($0.id) && allowed($0) } ?? false
        }
        guard items.allSatisfy({ $0.candidateID.flatMap { units[$0] } != nil }) else { return (source, original) }
        let requested = FilmDurationRequirement.parse(prompt: original.prompt, explicitSeconds: original.directorBrief?.explicitRequestedDuration ?? original.contentBudget?.requestedDuration, mode: original.directorBrief?.durationMode).target
        if requested == nil, EditorialCoherenceExperiment.current == .conciseRoute, let episodes = plan.episodePlan {
            let initialIDs = Set(items.compactMap(\.candidateID))
            let retained = EditorialCoherenceExperiment.conciseRouteIDs(selected: initialIDs, plan: episodes, units: units)
            artisticOmissions = initialIDs.subtracting(retained)
            items.removeAll { $0.candidateID.map(artisticOmissions.contains) ?? false }
        }
        let artisticDuration = artisticOmissions.isEmpty ? source.duration : items.reduce(0) { $0 + $1.timelineDuration }
        let target = requested ?? max(AutomaticFilmDurationPolicy.minimumDuration, artisticDuration)
        var targetFrames = Int((target * fps).rounded())
        let clusterer = ShotFamilyClusterer()
        func makeSlots(_ media: [TimelineItem]) -> [Slot] {
            let ranges = slots(items: media, units: units, maximumShot: maximumShot, fps: fps, pacing: plan.constraints.pacing, preferShortShots: preferShortShots)
            let sequence = ordered(ranges, plan: original, events: events, sourceMap: sourceMap)
            return preferShortShots ? limitedRuns(sequence, families: context.families.familyByUnitID, fps: fps) : sequence
        }
        var selected = makeSlots(items)
        let contextMarker = "Context hypothesis v1: earlier observed setting before participants"
        if requested == nil, EditorialCoherenceExperiment.current == .context,
           let first = selected.first, let episodes = plan.episodePlan,
           let opening = EditorialCoherenceExperiment.contextCandidate(before: first.unit, plan: episodes,
               units: units.filter { allowed($0.value) && !rejected.contains($0.key) }),
           allowed(opening), !rejected.contains(opening.id), !items.contains(where: { $0.candidateID == opening.id }) {
            let duration = opening.preferredDuration(pacing: plan.constraints.pacing)
            let item = TimelineItem(id: EditorialIdentity.uuid("context-opening-\(source.id)-\(opening.id)"),
                candidateID: opening.id, assetID: opening.candidate.assetID, kind: itemKind(opening),
                sourceStart: opening.evidence.usableRange.start, sourceDuration: duration,
                timelineStart: 0, timelineDuration: duration, videoAdjustments: VideoAdjustments(crop: .fit),
                eventID: opening.eventID, eventSceneID: opening.sceneID, explanation: [contextMarker])
            let proposed = makeSlots(items + [item])
            if proposed.first?.unit.id == opening.id,
               Set(selected.map { $0.unit.id }).isSubset(of: Set(proposed.map { $0.unit.id })) {
                items.append(item)
                selected = proposed
                targetFrames += Int((duration * fps).rounded())
            }
        }
        if let first = selected.first, !protected(first.unit), !first.unit.candidate.locked {
            // Compare unused candidates in the opening source window as well
            // as the rough edit. No later recording is moved in front of an
            // earlier required event.
            let openings = context.units.filter {
                allowed($0) && !rejected.contains($0.id) && $0.candidate.assetID == first.unit.candidate.assetID &&
                    $0.sourceRange.start >= first.unit.sourceRange.start &&
                    $0.sourceRange.start <= first.unit.sourceRange.start + 15 &&
                    $0.usableDuration >= 3 && EditorialMomentPolicy.openingValue($0) > EditorialMomentPolicy.openingValue(first.unit) + 0.15
            }.sorted { EditorialMomentPolicy.openingValue($0) > EditorialMomentPolicy.openingValue($1) }
            if let opening = openings.first, !items.contains(where: { $0.candidateID == opening.id }) {
                items.append(TimelineItem(id: EditorialIdentity.uuid("automatic-opening-\(source.id)-\(opening.id)"),
                    candidateID: opening.id, assetID: opening.candidate.assetID, kind: itemKind(opening),
                    sourceStart: opening.evidence.usableRange.start, sourceDuration: min(maximumShot, opening.usableDuration),
                    timelineStart: first.item.timelineStart, timelineDuration: min(maximumShot, opening.usableDuration),
                    videoAdjustments: VideoAdjustments(crop: .fit), eventID: opening.eventID, eventSceneID: opening.sceneID))
                selected = makeSlots(items)
            }
        }
        // A rejected edge shot is replaced from unused measured candidates,
        // never by looping the previous shot or extending beyond its evidence.
        if selected.reduce(0, { $0 + $1.capacity }) < targetFrames {
            let ranked = context.units.filter { allowed($0) && !rejected.contains($0.id) && $0.quality >= 0.55 && $0.usableDuration >= 1.5 }
                .sorted { $0.quality == $1.quality ? $0.id.uuidString < $1.id.uuidString : $0.quality > $1.quality }
            for unit in ranked {
                if selected.reduce(0, { $0 + $1.capacity }) >= targetFrames || original.constraints.targetClipCount.map({ items.count >= $0 }) == true { break }
                guard !items.contains(where: { $0.candidateID == unit.id }),
                      selected.allSatisfy({ !preferShortShots || !clusterer.isHardDuplicate($0.unit, unit, adjacent: false) }) else { continue }
                let item = TimelineItem(id: EditorialIdentity.uuid("automatic-shot-\(source.id)-\(unit.id)"), candidateID: unit.id, assetID: unit.candidate.assetID, kind: itemKind(unit),
                    sourceStart: max(unit.sourceRange.start, unit.evidence.usableRange.start), sourceDuration: min(maximumShot, unit.usableDuration),
                    timelineStart: 0, timelineDuration: min(maximumShot, unit.usableDuration), videoAdjustments: VideoAdjustments(crop: .fit),
                    eventID: unit.eventID, eventSceneID: unit.sceneID,
                    explanation: ["Автоматическая сборка: дополнительный подтверждённый неповторяющийся момент"])
                let proposed = makeSlots(items + [item])
                if proposed.reduce(0, { $0 + $1.capacity }) > selected.reduce(0, { $0 + $1.capacity }) {
                    items.append(item)
                    selected = proposed
                }
            }
        }
        // Reserve a measured representative from an omitted recording before
        // spending the duration on longer shots from already covered sources.
        // This also runs after a render rejection: try another safe range from
        // that source instead of silently losing the whole recording.
        let coveragePool = context.units.filter { allowed($0) && EditorialSourceCoverage.eligible($0, rejected: rejected) }
            .sorted { $0.quality == $1.quality ? $0.id.uuidString < $1.id.uuidString : $0.quality > $1.quality }
        let sourceIDs = Array(Set(coveragePool.map { $0.candidate.assetID })).sorted { a, b in
            let left = coveragePool.first { $0.candidate.assetID == a }!
            let right = coveragePool.first { $0.candidate.assetID == b }!
            return left.quality == right.quality ? a.uuidString < b.uuidString : left.quality > right.quality
        }
        func measuredUnit(_ slot: Slot) -> EditorialUnit {
            var unit = slot.unit
            unit.candidate.sourceStart = slot.item.sourceStart
            unit.candidate.sourceDuration = Double(slot.capacity) / fps
            return unit
        }
        func sourceIDsOf(_ slots: [Slot]) -> Set<UUID> { Set(slots.map { $0.unit.candidate.assetID }) }
        func minimumFrames(_ slots: [Slot]) -> Int {
            slots.reduce(0) { $0 + (protected($1.unit) ? $1.frames : Int((EditorialSourceCoverage.minimumShotDuration * fps).rounded(.up))) }
        }
        for assetID in sourceIDs where !sourceIDsOf(selected).contains(assetID) {
            for unit in coveragePool where unit.candidate.assetID == assetID {
                guard selected.allSatisfy({ !clusterer.isHardDuplicate(measuredUnit($0), unit, adjacent: false) }) else { continue }
                let item = TimelineItem(id: EditorialIdentity.uuid("automatic-coverage-\(source.id)-\(unit.id)"), candidateID: unit.id,
                    assetID: assetID, kind: itemKind(unit), sourceStart: max(unit.sourceRange.start, unit.evidence.usableRange.start),
                    sourceDuration: min(maximumShot, unit.usableDuration), timelineStart: 0,
                    timelineDuration: min(maximumShot, unit.usableDuration), videoAdjustments: VideoAdjustments(crop: .fit),
                    eventID: unit.eventID, eventSceneID: unit.sceneID,
                    explanation: ["Представлен ранее пропущенный исходник: подтверждённый пригодный неповторяющийся момент"])
                var proposed = makeSlots(selected.map(\.item) + [item])
                // A shot-count limit may require replacing an optional extra,
                // but never the only representative of another recording.
                while minimumFrames(proposed) > targetFrames || original.constraints.targetClipCount.map({ proposed.count > $0 }) == true {
                    let counts = Dictionary(grouping: proposed, by: { $0.unit.candidate.assetID }).mapValues(\.count)
                    guard let index = proposed.indices.filter({
                        !protected(proposed[$0].unit) && counts[proposed[$0].unit.candidate.assetID, default: 0] > 1
                    }).min(by: { proposed[$0].unit.quality < proposed[$1].unit.quality }) else { break }
                    proposed.remove(at: index)
                }
                guard proposed.contains(where: { $0.unit.id == unit.id }),
                      sourceIDsOf(selected).isSubset(of: sourceIDsOf(proposed)),
                      Set(selected.filter { protected($0.unit) }.map { $0.unit.id }).isSubset(of: Set(proposed.map { $0.unit.id })),
                      minimumFrames(proposed) <= targetFrames,
                      original.constraints.targetClipCount.map({ proposed.count <= $0 }) ?? true,
                      proposed.reduce(0, { $0 + $1.capacity }) >= min(targetFrames, selected.reduce(0, { $0 + $1.capacity })),
                      zip(proposed, proposed.dropFirst()).allSatisfy({ !clusterer.isHardDuplicate(measuredUnit($0), measuredUnit($1)) }) else { continue }
                selected = proposed
                items = proposed.map(\.item)
                break
            }
        }
        guard !selected.isEmpty else { return (source, original) }
        // Skip a weak chronological prefix only when the remaining measured
        // ranges can still fulfill the request and no required moment is lost.
        // Do this after refill so duration recovery cannot reinsert that prefix.
        if let first = selected.first, !first.item.explanation.contains(contextMarker) {
            let candidates = selected.indices.prefix(4).filter { index in
                let slot = selected[index]
                return slot.unit.eventID == first.unit.eventID && slot.unit.sceneID == first.unit.sceneID &&
                    selected[..<index].allSatisfy { !protected($0.unit) && !$0.unit.candidate.locked } &&
                    sourceIDsOf(selected).isSubset(of: sourceIDsOf(Array(selected[index...]))) &&
                    selected[index...].reduce(0, { $0 + $1.capacity }) >= targetFrames
            }
            if let best = candidates.max(by: { EditorialMomentPolicy.openingValue(selected[$0].unit) < EditorialMomentPolicy.openingValue(selected[$1].unit) }),
               EditorialMomentPolicy.openingValue(selected[best].unit) >= max(0.5, EditorialMomentPolicy.openingValue(first.unit) + 0.15) {
                selected.removeFirst(best)
            }
        }
        if let last = selected.last {
            let candidates = selected.indices.suffix(3).filter { index in
                selected[index].unit.eventID == last.unit.eventID &&
                    selected[(index + 1)...].allSatisfy { !protected($0.unit) && !$0.unit.candidate.locked } &&
                    sourceIDsOf(selected).isSubset(of: sourceIDsOf(Array(selected[...index]))) &&
                    selected[...index].reduce(0, { $0 + $1.capacity }) >= targetFrames
            }
            if let best = candidates.max(by: { EditorialMomentPolicy.closingValue(selected[$0].unit) < EditorialMomentPolicy.closingValue(selected[$1].unit) }),
               EditorialMomentPolicy.closingValue(selected[best].unit) >= max(0.5, EditorialMomentPolicy.closingValue(last.unit) + 0.15) {
                selected = Array(selected[...best])
            }
        }
        let capacity = selected.reduce(0) { $0 + $1.capacity }
        if requested != nil, capacity < targetFrames, preferShortShots {
            let expanded = prepare(timeline: source, plan: original, analyses: analyses, events: events,
                                   assets: assets, excluded: excluded, preferShortShots: false)
            if expanded.timeline.duration > Double(capacity) / fps + 1 / fps { return expanded }
        }
        let desired = min(targetFrames, capacity)
        guard selected.filter({ protected($0.unit) }).reduce(0, { $0 + $1.frames }) <= desired else { return (source, original) }
        // Balanced water filling on the output frame grid avoids one long
        // shot receiving the whole deficit and keeps exact duration stable.
        func fullness(_ index: Int) -> Double {
            Double(selected[index].frames) / max(1, selected[index].unit.preferredDuration(pacing: plan.constraints.pacing) * fps)
        }
        while selected.reduce(0, { $0 + $1.frames }) < desired {
            guard let index = selected.indices.filter({ selected[$0].frames < selected[$0].capacity }).min(by: {
                fullness($0) == fullness($1) ? selected[$0].unit.quality > selected[$1].unit.quality : fullness($0) < fullness($1)
            }) else { break }
            selected[index].frames += 1
        }
        while selected.reduce(0, { $0 + $1.frames }) > desired {
            guard let index = selected.indices.filter({ selected[$0].frames > Int(0.5 * fps) && !protected(selected[$0].unit) }).max(by: { selected[$0].frames < selected[$1].frames }) else { break }
            selected[index].frames -= 1
        }
        let prepared = selected
        var cursor = 0
        timeline.items = prepared.enumerated().map { index, slot in
            var item = slot.item
            item.timelineStart = Double(cursor) / fps
            item.timelineDuration = Double(slot.frames) / fps
            item.sourceDuration = item.timelineDuration
            if index == prepared.count - 1, !protected(slot.unit), EditorialMomentPolicy.closingValue(slot.unit) >= 0.5 {
                let end = min(slot.unit.sourceRange.end, slot.unit.evidence.usableRange.end)
                item.sourceStart = max(item.sourceStart, (end * fps).rounded(.down) / fps - item.sourceDuration)
            }
            item.eventID = slot.unit.eventID ?? item.eventID
            item.eventSceneID = slot.unit.sceneID ?? item.eventSceneID
            item.storyRole = index == 0 ? .intro : index == prepared.count - 1 ? .outro : slot.unit.evidence.hasProgression && slot.unit.evidence.completion >= 0.65 ? .climax : .action
            // Recompute boundary transitions below from the new neighbours.
            item.transition = nil
            item.incomingEditDecision = nil
            cursor += slot.frames
            return item
        }
        timeline.transitionItems = []
        timeline.adaptiveSoundtrack = nil
        timeline.editorialReview = nil
        plan = reconcile(timeline: timeline, plan: plan, analyses: analyses, events: events, context: context, sourceMap: sourceMap)
        plan.sourceCoverageAssetIDs = Set(context.units.filter(allowed).map { $0.candidate.assetID }).sorted { $0.uuidString < $1.uuidString }
        if var budget = plan.contentBudget {
            let supported = Double(capacity) / fps
            let satisfied = requested.map { supported + 1 / fps >= $0 } ?? true
            budget.supportedDuration = supported
            budget.budget.absoluteCeiling = supported
            budget.budget.idealDuration = Double(cursor) / fps
            budget.budget.safeRange = (satisfied && requested != nil ? Double(cursor) / fps : min(supported, max(10, Double(cursor) / fps * 0.8)))...supported
            budget.budget.strongUnitCount = selected.count
            budget.budget.distinctEventCount = Set(selected.compactMap { $0.unit.eventID }).count
            budget.budget.distinctSceneCount = Set(selected.compactMap { $0.unit.sceneID }).count
            budget.budget.distinctShotFamilyCount = Set(selected.compactMap { context.families.familyByUnitID[$0.unit.id] }).count
            budget.budget.usableActionSeconds = selected.filter { $0.unit.speechSeconds == 0 && $0.unit.evidence.atmosphereValue < 0.65 }.reduce(0) { $0 + Double($1.capacity) / fps }
            budget.budget.usableAtmosphereSeconds = selected.filter { $0.unit.speechSeconds == 0 && $0.unit.evidence.atmosphereValue >= 0.65 }.reduce(0) { $0 + Double($1.capacity) / fps }
            budget.budget.usableSpeechSeconds = selected.filter { $0.unit.speechSeconds > 0 }.reduce(0) { $0 + Double($1.capacity) / fps }
            budget.durationConstraintStatus = satisfied ? .satisfied : .compromisedInsufficientContent
            budget.feasibility = requested.map { min(1, supported / max(0.001, $0)) } ?? 1
            budget.requiresExpandedMining = !satisfied && !context.expandedMiningPerformed
            budget.budget.limitingFactors.removeAll { $0 == .insufficientContent }
            if !satisfied { budget.budget.limitingFactors.append(.insufficientContent) }
            budget.reason = "Автоматическая финальная сборка: \(selected.count) неповторяющихся моментов; вместимость \(Int(supported.rounded())) с рассчитана по непересекающимся проверенным диапазонам."
            plan.contentBudget = budget
        }
        plan.constraints.targetDuration = requested ?? original.constraints.targetDuration
        timeline.editorialBeatPlan = plan.narrativeBeatPlan
        for id in rejected { timeline.editorialBeatPlan?.discardedCandidates?[id] = .unsafeCrop }
        plan.narrativeBeatPlan = timeline.editorialBeatPlan
        timeline = EditorialPresentationPolicy.ensuringChapterTitles(in: timeline, plan: plan, preserveExistingPresentation: true)
        timeline = PhotoPresentationPolicy.applying(to: timeline, plan: plan, assets: assets, analyses: analyses)
        timeline = AutomaticTelemetryPolicy.rebuilding(in: timeline, plan: plan, analyses: analyses)
        if !artisticOmissions.isEmpty {
            plan.episodePlan?.limitations.append("Experimental route compression omitted \(artisticOmissions.count) shots; technical quality is not the reason. Human A/B review required.")
        }
        return (timeline, plan)
    }

    /// Joint run capacity matters as well as each individual shot. Two safe
    /// eight-second shots from the same setup are not a safe sixteen-second
    /// run. Reserve the verifier's twelve-second ceiling before allocating.
    static func limitedRuns(_ slots: [Slot], families: [UUID: String], fps: Double) -> [Slot] {
        var result: [Slot] = []
        var run = 0
        var lastFamily: String?
        for var slot in slots {
            let family = families[slot.unit.id] ?? slot.unit.id.uuidString
            run = family == lastFamily ? run + 1 : 1
            lastFamily = family
            guard run <= 2 || protected(slot.unit) else { continue }
            if run == 2, !protected(slot.unit), let prior = result.last {
                let ceiling = Int(12 * fps)
                if prior.capacity + slot.capacity > ceiling {
                    if protected(prior.unit) {
                        slot.capacity = max(0, ceiling - prior.capacity)
                    } else {
                        let first = Int((Double(ceiling) * Double(prior.capacity) / Double(prior.capacity + slot.capacity)).rounded(.down))
                        result[result.count - 1].capacity = first
                        result[result.count - 1].frames = min(prior.frames, first)
                        slot.capacity = ceiling - first
                    }
                }
            }
            guard slot.capacity >= Int(1.5 * fps) else { continue }
            slot.frames = min(slot.frames, slot.capacity)
            result.append(slot)
        }
        return result
    }

    static func protected(_ unit: EditorialUnit) -> Bool {
        unit.candidate.locked || EditorialMomentPolicy.protectedRange(unit) != nil
    }

    static func slots(items: [TimelineItem], units: [UUID: EditorialUnit], maximumShot: Double, fps: Double, pacing: Double, preferShortShots: Bool = true) -> [Slot] {
        var result: [Slot] = []
        let sorted = items.sorted { $0.sourceStart == $1.sourceStart ? $0.id.uuidString < $1.id.uuidString : $0.sourceStart < $1.sourceStart }
        var ends: [UUID: Double] = [:]
        for var item in sorted {
            guard let id = item.candidateID, let unit = units[id], let asset = item.assetID else { continue }
            let lower = max(unit.sourceRange.start, unit.evidence.usableRange.start)
            let upper = min(unit.sourceRange.end, unit.evidence.usableRange.end)
            let required = EditorialMomentPolicy.protectedRange(unit)
            let seed = required?.start ?? item.sourceStart
            let start = (max(lower, seed, ends[asset, default: 0]) * fps).rounded(.up) / fps
            let next = sorted.filter { $0.assetID == asset && $0.sourceStart > start + 0.001 }.map(\.sourceStart).min() ?? upper
            // Temporal evidence bounds physical capacity. Preferred observation length
            // and same-setup run length are taste constraints, not missing media.
            let measured = unit.evidence.confidence >= 0.55 && unit.quality >= 0.55 && !unit.evidence.hasHardOcclusion
                ? max(0, upper - start) : unit.usableDuration
            let available = preferShortShots || protected(unit) ? unit.usableDuration : measured
            let cap = min(available, preferShortShots && !protected(unit) ? maximumShot : available, min(upper, next) - start)
            let frames = Int((max(0, cap) * fps).rounded(.down))
            guard frames >= Int(1.5 * fps) else { continue }
            if let required = EditorialMomentPolicy.protectedRange(unit),
               start > required.start + 1 / fps || start + Double(frames) / fps < required.end - 1 / fps { continue }
            if protected(unit) && Double(frames) / fps + 1 / fps < unit.preferredDuration(pacing: pacing) { continue }
            item.sourceStart = start
            ends[asset] = start + Double(frames) / fps
            let requiredFrames = EditorialMomentPolicy.protectedRange(unit).map { Int((($0.end - start) * fps).rounded(.up)) } ?? 0
            result.append(Slot(item: item, unit: unit, capacity: frames, frames: min(frames, max(requiredFrames, Int(2 * fps), Int((unit.preferredDuration(pacing: pacing) * fps).rounded())))))
        }
        return result
    }

    private static func label(unit: EditorialUnit, plan: StoryPlan, events: [Event], units: [EditorialUnit]) -> String {
        if let approved = plan.approvedSourceChapterLabels?[unit.candidate.assetID] { return approved.text }
        let scene = events.flatMap(\.effectiveScenes).first { $0.id == unit.sceneID }
        let scope = units.filter { unit.sceneID != nil ? $0.sceneID == unit.sceneID : unit.eventID != nil ? $0.eventID == unit.eventID : $0.candidate.assetID == unit.candidate.assetID }
        let tags = Set(scope.flatMap { $0.candidate.tags }).union(scene?.tags ?? [])
        if let title = SmartTitleEngine().contentConfirmedActivityTitle(tags: tags, summaries: scope.compactMap { $0.candidate.insights?.sceneSummary }) { return title.primaryText }
        // An old generated scene/chapter name is a conclusion, not independent
        // source evidence. Otherwise a corrected vocabulary would immediately
        // reintroduce its old hallucination through this fallback. Explicitly
        // approved user labels are handled above.
        if !tags.isDisjoint(with: ["boat", "watercraft", "paddle", "water", "water_body"]) { return "На воде" }
        if !tags.isDisjoint(with: ["outdoor", "forest", "grass", "land"]) { return "На природе" }
        return "Моменты дня"
    }

    private static func ordered(_ slots: [Slot], plan: StoryPlan, events: [Event], sourceMap: SourceMap?) -> [Slot] {
        // Capture order is the primary constraint. Variety changes selection
        // and shot lengths, never the recording order of the selected moments.
        var ranks: [UUID: Int] = [:]
        let clocks = Dictionary(uniqueKeysWithValues: (sourceMap?.entries ?? []).filter { $0.chronologyConfidence >= 0.9 && $0.captureDate != nil }.map { ($0.assetID, $0.captureDate!) })
        for id in sourceMap?.orderedAssetIDs ?? events.flatMap(\.assetIDs) where ranks[id] == nil { ranks[id] = ranks.count }
        for slot in slots.sorted(by: { $0.item.timelineStart < $1.item.timelineStart }) where ranks[slot.unit.candidate.assetID] == nil {
            ranks[slot.unit.candidate.assetID] = ranks.count
        }
        return slots.sorted {
            let leftClock = clocks[$0.unit.candidate.assetID]?.addingTimeInterval($0.item.sourceStart)
            let rightClock = clocks[$1.unit.candidate.assetID]?.addingTimeInterval($1.item.sourceStart)
            if let a = leftClock, let b = rightClock, a != b { return a < b }
            if (leftClock != nil) != (rightClock != nil) { return leftClock != nil }
            if sourceMap == nil {
                let a = plan.approvedSourceChapterLabels?[$0.unit.candidate.assetID]?.order ?? Int.max
                let b = plan.approvedSourceChapterLabels?[$1.unit.candidate.assetID]?.order ?? Int.max
                if a != b { return a < b }
            }
            let a = ranks[$0.unit.candidate.assetID, default: Int.max]
            let b = ranks[$1.unit.candidate.assetID, default: Int.max]
            if a != b { return a < b }
            if $0.item.sourceStart != $1.item.sourceStart { return $0.item.sourceStart < $1.item.sourceStart }
            return $0.item.id.uuidString < $1.item.id.uuidString
        }
    }

    static func reconcile(timeline: Timeline, plan original: StoryPlan, analyses: [AnalysisResult], events: [Event], context supplied: EditorialAnalysisContext? = nil, sourceMap suppliedMap: SourceMap? = nil) -> StoryPlan {
        var plan = original
        let context = supplied ?? EditorialAnalysisContext(analyses: analyses, events: events)
        let units = Dictionary(uniqueKeysWithValues: context.units.map { ($0.id, $0) })
        let sourceMap = suppliedMap ?? original.eventStory?.diagnostics?.sourceMap
        let groups = Dictionary(uniqueKeysWithValues: (sourceMap?.entries ?? []).map { ($0.assetID, $0.activityGroupID) })
        var previousScope: String?
        var chapters: [StoryChapter] = []
        var beats: [EditorialNarrativeBeat] = []
        for (index, item) in timeline.items.enumerated() {
            guard let id = item.candidateID, let unit = units[id] else { continue }
            let title = label(unit: unit, plan: original, events: events, units: context.units)
            let event = unit.eventID ?? item.eventID
            let group = groups[unit.candidate.assetID]
            let approvedOrder = original.approvedSourceChapterLabels?[unit.candidate.assetID]?.order
            let scope = "\(event?.uuidString ?? "none")|\(group?.uuidString ?? "none")|reference:\(approvedOrder.map(String.init) ?? "none")"
            if scope == previousScope {
                chapters[chapters.count - 1].candidateIDs.append(id)
                chapters[chapters.count - 1].allocatedDuration = (chapters.last?.allocatedDuration ?? 0) + item.timelineDuration
            } else {
                chapters.append(StoryChapter(id: EditorialIdentity.uuid("automatic-chapter-\(plan.id)-\(id)"), title: title, candidateIDs: [id], role: index == 0 ? .intro : .action, purpose: title, eventID: event, eventSceneID: group ?? unit.sceneID ?? item.eventSceneID, chapterCardTitle: title, allocatedDuration: item.timelineDuration))
            }
            previousScope = scope
            let purpose: EditorialNarrativePurpose = index == 0 ? .hook : index == timeline.items.count - 1 ? .closure : .development
            let fulfilled = purpose == .closure ? EditorialMomentPolicy.closingValue(unit) >= 0.5 : purpose == .hook ? EditorialMomentPolicy.openingValue(unit) >= 0.5 : unit.quality >= 0.38
            beats.append(EditorialNarrativeBeat(candidateID: id, purpose: purpose, viewerInformation: unit.candidate.insights?.sceneSummary ?? title, requiredChange: 0, familyID: context.families.familyByUnitID[id], minimumEvidence: 0.38, durationRange: 0.5...max(0.5, unit.usableDuration), allocatedDuration: item.timelineDuration, fulfilled: fulfilled))
            beats[beats.count - 1].momentDecision = EditorialMomentDecision(
                sourceRange: .init(start: item.sourceStart, end: item.sourceStart + item.sourceDuration),
                protectedRange: EditorialMomentPolicy.protectedRange(unit),
                openingValue: purpose == .hook ? EditorialMomentPolicy.openingValue(unit) : nil,
                closingValue: purpose == .closure ? EditorialMomentPolicy.closingValue(unit) : nil,
                reasons: [fulfilled ? "Основание: измеренные наблюдения исходного диапазона" : "Ограничение материала: выразительность края не подтверждена"])
        }
        plan.chapters = chapters
        var beatPlan = NarrativeBeatPlan(pattern: chapters.count > 1 ? .eventChapters : original.narrativeBeatPlan?.pattern ?? .minimalMontage, beats: beats, reasons: [marker])
        beatPlan.discardedCandidates = timeline.editorialBeatPlan?.discardedCandidates ?? [:]
        plan.narrativeBeatPlan = beatPlan
        plan.beatGraph = nil
        if var story = plan.eventStory {
            for index in story.entries.indices { story.entries[index].allocatedDuration = timeline.items.filter { $0.eventID == story.entries[index].eventID }.reduce(0) { $0 + $1.timelineDuration } }
            plan.eventStory = story
        }
        return plan
    }
}
