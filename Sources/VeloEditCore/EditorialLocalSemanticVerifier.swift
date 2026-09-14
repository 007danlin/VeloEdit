import Foundation

/// Local, deterministic semantic verification of the actual composited
/// frames. It deliberately does not read planner fulfillment or variant score.
/// The observations are heuristic, but unlike the previous empty production
/// boundary they are localized, reproducible and tied to a render signature.
public enum EditorialLocalSemanticVerifier {
    public static let version = 3

    public static func claims(
        timeline: Timeline,
        plan: StoryPlan,
        analyses: [AnalysisResult],
        frames: [PerceptualRenderedFrameEvidence],
        tracks: [LocalMusicTrack]
    ) -> [EditorialSemanticClaim] {
        let items = TimelineTiming.retimed(timeline.items).filter { $0.overlay == nil && $0.kind != .title }
        guard !items.isEmpty else { return [] }
        let decoded = frames.filter {
            $0.decodeFailed == false && !$0.isBlack && $0.expectedVisibleContent
                && !NaturalChapterTransitionPlanner.expectsCoveredSource(at: $0.timelineTime, timeline: timeline)
        }
        let signature = EditorialRenderSignature.signature(timeline)
        let context = EditorialAnalysisContext(analyses: analyses)
        let units = Dictionary(uniqueKeysWithValues: context.units.map { ($0.id, $0) })
        let itemSet = Set(items.map(\.id))

        func scopedFrames(for selected: [TimelineItem]) -> [PerceptualRenderedFrameEvidence] {
            decoded.filter { frame in selected.contains { frame.timelineTime >= $0.timelineStart && frame.timelineTime < $0.timelineStart + $0.timelineDuration } }
        }
        func claim(
            _ domain: EditorialEvidenceDomain,
            selected: [TimelineItem] = [],
            passed: Bool,
            confidence: Double = 0.82,
            observation: String,
            kind: EditorialFindingKind? = nil,
            repair: EditorialRepairClass = .structuralReplan
        ) -> EditorialSemanticClaim? {
            let scoped = selected.isEmpty ? items : selected
            let observations = scopedFrames(for: scoped)
            let times = Array(Set(observations.map { Int(($0.timelineTime * 600).rounded()) })).map { Double($0) / 600 }.sorted()
            guard times.count >= 2 else { return nil }
            let ids = scoped.map(\.id).filter { itemSet.contains($0) }
            guard !ids.isEmpty else { return nil }
            let finding = passed ? nil : kind.map { EditorialFinding(kind: $0, severity: 2, itemIDs: ids, repair: repair, reason: observation) }
            return EditorialSemanticClaim(domain: domain, status: passed ? .passed : .failed, itemIDs: ids, probeTimes: times, confidence: confidence, observation: observation, method: "LocalRenderedSemanticVerifier-v\(version)", renderSignature: signature, finding: finding)
        }

        func unit(for item: TimelineItem) -> EditorialUnit? { item.candidateID.flatMap { units[$0] } }
        func expectsPerson(_ item: TimelineItem) -> Bool {
            guard let unit = unit(for: item) else { return false }
            let kinds = Set(unit.evidence.samples.flatMap(\.subjectKinds))
            let tags = unit.candidate.tags.map { $0.lowercased() }
            return !kinds.isDisjoint(with: [.person, .face, .cyclist])
                || tags.contains { ["person", "people", "human", "cyclist", "driver"].contains($0) }
        }
        func hasRenderedPerson(_ item: TimelineItem) -> Bool {
            scopedFrames(for: [item]).contains { frame in
                frame.renderedSubjects?.contains { [.person, .face, .cyclist].contains($0.kind) && $0.confidence >= 0.45 } == true
            }
        }

        // A single Vision rectangle is not enough to block a production cut:
        // wide POV footage can produce an edge-touching human false positive or
        // a full-frame saliency box. Geometry defects must persist in one shot.
        func persistentlyFlaggedItems(
            _ predicate: (PerceptualRenderedFrameEvidence, TimelineItem) -> Bool
        ) -> [TimelineItem] {
            items.filter { item in
                let probes = scopedFrames(for: [item])
                guard probes.count >= 3 else { return false }
                let flagged = probes.filter { predicate($0, item) }.count
                return flagged >= 2 && Double(flagged) / Double(probes.count) >= 0.5
            }
        }

        func meaningfulHuman(_ observation: FrameSubjectObservation) -> Bool {
            [.person, .face, .cyclist].contains(observation.kind)
                && observation.confidence >= 0.6
                && observation.region.area >= 0.002
                && observation.region.area <= 0.72
        }

        func overlapFraction(_ lhs: NormalizedRegion, _ rhs: NormalizedRegion) -> Double {
            let x = max(0, min(lhs.x + lhs.width, rhs.x + rhs.width) - max(lhs.x, rhs.x))
            let y = max(0, min(lhs.y + lhs.height, rhs.y + rhs.height) - max(lhs.y, rhs.y))
            return x * y / max(0.000_001, min(lhs.area, rhs.area))
        }

        var result: [EditorialSemanticClaim] = []
        let expectedPeople = items.filter(expectsPerson)
        let observedPeople = expectedPeople.filter { item in
            if hasRenderedPerson(item) { return true }
            // A source track plus a successful explicit reframe safety report
            // is independent of the planner and covers small/distant people
            // that VNDetectHumanRectangles can legitimately miss.
            guard let unit = unit(for: item) else { return false }
            let tracked = unit.candidate.insights?.subjectTracking?.tracks.contains { [.person, .face, .cyclist].contains($0.kind) && $0.meanConfidence >= 0.55 } == true
            return tracked && item.effectiveVideoAdjustments.subjectReframe?.safetyReport?.passed != false
        }
        let subjectPass = expectedPeople.isEmpty || observedPeople.count >= max(1, Int(ceil(Double(expectedPeople.count) * 0.65)))
        let missingPeople = expectedPeople.filter { expected in !observedPeople.contains { $0.id == expected.id } }
        if let value = claim(.subjectCoverage, selected: subjectPass ? items : missingPeople, passed: subjectPass, observation: subjectPass ? "Люди/герои подтверждены source tracking и финальными кадрами" : "В финальной композиции потеряна значимая часть ожидаемых людей", kind: .unsafeReframe, repair: .framing) { result.append(value) }

        let unsafeFaceItems = persistentlyFlaggedItems { frame, item in
            guard expectsPerson(item) else { return false }
            return frame.renderedSubjects?.contains { observation in
                observation.kind == .face && meaningfulHuman(observation)
                    && observation.region.area <= 0.30
                    && (observation.region.x < 0.01 || observation.region.x + observation.region.width > 0.99 || observation.region.y + observation.region.height > 0.995)
            } == true
        }
        if let value = claim(.faceSafety, selected: unsafeFaceItems.isEmpty ? items : unsafeFaceItems, passed: unsafeFaceItems.isEmpty, observation: unsafeFaceItems.isEmpty ? "Обнаруженные лица находятся внутри безопасной области" : "Лицо устойчиво касается опасной границы финального кадра", kind: .unsafeReframe, repair: .framing) { result.append(value) }

        let unsafeBodyItems = persistentlyFlaggedItems { frame, item in
            guard expectsPerson(item) else { return false }
            return frame.renderedSubjects?.contains { observation in
                observation.kind == .person && meaningfulHuman(observation)
                    && observation.region.area >= 0.025
                    && observation.region.area <= 0.70
                    && (observation.region.x < 0.005 || observation.region.x + observation.region.width > 0.995 || observation.region.y + observation.region.height > 0.998)
            } == true
        }
        if let value = claim(.bodySafety, selected: unsafeBodyItems.isEmpty ? items : unsafeBodyItems, passed: unsafeBodyItems.isEmpty, observation: unsafeBodyItems.isEmpty ? "Обнаруженные фигуры не имеют опасного бокового/верхнего обрезания" : "Тело человека устойчиво обрезано опасной границей финального кадра", kind: .unsafeReframe, repair: .framing) { result.append(value) }

        let occludedItems = persistentlyFlaggedItems { frame, item in
            guard expectsPerson(item), (frame.verticalOccluderScore ?? 0) >= 0.62 else { return false }
            return frame.renderedSubjects?.contains(where: meaningfulHuman) == true
        }
        if let value = claim(.foregroundOcclusion, selected: occludedItems.isEmpty ? items : occludedItems, passed: occludedItems.isEmpty, observation: occludedItems.isEmpty ? "Высококонтрастная foreground-окклюзия не обнаружена на рискованных probes" : "Найдена устойчивая вертикальная foreground-помеха рядом с подтверждённым героем", kind: .foregroundOcclusion, repair: .framing) { result.append(value) }

        let dominantItems = persistentlyFlaggedItems { frame, item in
            guard expectsPerson(item) else { return false }
            let subjects: [FrameSubjectObservation] = frame.renderedSubjects ?? []
            guard let person = subjects.filter(meaningfulHuman).max(by: { $0.region.area < $1.region.area }) else { return false }
            let salient: [FrameSubjectObservation] = frame.renderedSalientRegions ?? []
            let labels = (frame.renderedLabels ?? []).joined(separator: " ")
            let technicalLabel = ["vehicle", "automobile", "car", "truck", "bus", "motorcycle", "dashboard", "windshield", "pole"].contains(where: labels.contains)
            guard technicalLabel else { return false }
            return salient.contains { region in
                region.kind == .vehicle && region.region.area >= 0.46
                    && region.region.area > person.region.area * 1.8
                    && overlapFraction(region.region, person.region) >= 0.28
            }
        }
        if let value = claim(.dominantForegroundObject, selected: dominantItems.isEmpty ? items : dominantItems, passed: dominantItems.isEmpty, observation: dominantItems.isEmpty ? "Нерелевантный foreground-объект не доминирует в композиции" : "Подтверждённый технический/транспортный foreground-объект устойчиво перекрывает сюжетного субъекта", kind: .dominantForegroundObject, repair: .framing) { result.append(value) }

        let knownFamilies = items.compactMap { $0.candidateID.flatMap { context.families.familyByUnitID[$0] } }
        let familyPass = knownFamilies.count == items.compactMap(\.candidateID).count
        if let value = claim(.shotFamilyIdentity, passed: familyPass, observation: familyPass ? "Каждый выбранный план имеет измеренную shot-family identity" : "Для части выбранных планов shot-family identity не определена", kind: .hardDuplicate) { result.append(value) }

        func representative(_ item: TimelineItem) -> PerceptualRenderedFrameEvidence? {
            scopedFrames(for: [item]).min { abs($0.timelineTime - item.timelineStart - item.timelineDuration / 2) < abs($1.timelineTime - item.timelineStart - item.timelineDuration / 2) }
        }
        func structuralDistance(_ lhs: [Float], _ rhs: [Float]) -> Double? {
            guard lhs.count == rhs.count, !lhs.isEmpty else { return nil }
            let lm = Double(lhs.reduce(0, +)) / Double(lhs.count)
            let rm = Double(rhs.reduce(0, +)) / Double(rhs.count)
            return zip(lhs, rhs).reduce(0) { $0 + abs((Double($1.0) - lm) - (Double($1.1) - rm)) } / Double(lhs.count)
        }
        // Compare each shot with the last shot already retained, not merely
        // with its original left neighbour. Otherwise deleting B from A-B-A
        // can expose an A-A duplicate and force another full export. This is a
        // one-pass adjacent fixed point and still permits a meaningful return
        // to the same setup later in the story.
        let representatives = Dictionary(uniqueKeysWithValues: items.compactMap { item in representative(item).map { (item.id, $0) } })
        var duplicateItems = Set<UUID>()
        var retained: [TimelineItem] = []
        for item in items {
            guard let current = representatives[item.id] else {
                retained.append(item)
                continue
            }
            let lowGain = unit(for: item).map { max($0.evidence.informationGain, $0.evidence.actionDelta) < 0.16 } ?? true
            let duplicatesRetained = lowGain && retained.last.map { earlier in
                guard let previous = representatives[earlier.id] else { return false }
                let distance = structuralDistance(previous.lumaFingerprint ?? [], current.lumaFingerprint ?? []) ?? 1
                let hashDistance = previous.perceptualHash.flatMap { first in current.perceptualHash.map { (first ^ $0).nonzeroBitCount } } ?? 64
                let sameFamily = earlier.candidateID.flatMap { context.families.familyByUnitID[$0] } == item.candidateID.flatMap { context.families.familyByUnitID[$0] }
                return distance < 0.055 || hashDistance <= 5 || sameFamily && distance < 0.105
            } == true
            if duplicatesRetained {
                duplicateItems.insert(item.id)
            } else {
                retained.append(item)
            }
        }
        let duplicateTimelineItems = items.filter { duplicateItems.contains($0.id) }
        if let value = claim(.visualNovelty, selected: duplicateItems.isEmpty ? items : duplicateTimelineItems, passed: duplicateItems.isEmpty, observation: duplicateItems.isEmpty ? "Соседние планы различимы по фактической композиции или изменению состояния" : "Найдены соседние визуально взаимозаменяемые планы без нового состояния", kind: .hardDuplicate, repair: .removeDuplicate) { result.append(value) }

        let progressing = items.filter { item in unit(for: item).map { $0.evidence.hasProgression || $0.evidence.visualDelta >= 0.12 || $0.evidence.informationGain >= 0.14 || $0.speechSeconds > 0 } == true }
        let allStill = items.allSatisfy { $0.kind == .photo || $0.isFreezeFrame }
        let stillObservation = allStill && items.allSatisfy { item in unit(for: item).map { $0.quality >= 0.5 } ?? false }
        let progressionPass = stillObservation || !progressing.isEmpty && Double(progressing.count) / Double(items.count) >= 0.25
        let stagnant = items.filter { item in !progressing.contains(where: { $0.id == item.id }) }
        if let value = claim(.actionProgression, selected: progressionPass ? items : stagnant, passed: progressionPass, observation: progressionPass ? (stillObservation ? "Атмосферная still-последовательность подтверждена качеством и изменением композиции" : "Последовательность содержит измеримые изменения действия/состояния") : "Последовательность не подтверждает развитие действия", kind: .falseNarrativeRole) { result.append(value) }

        let complete = stillObservation || items.contains { item in unit(for: item).map { $0.evidence.completion >= 0.45 || $0.evidence.exitQuality >= 0.58 || $0.speechSeconds > 0 } == true }
        if let value = claim(.momentCompletion, passed: complete, observation: complete ? "В фильме присутствует завершённый момент, результат или реакция" : "Выбранные ranges не подтверждают завершение момента", kind: .incompleteMoment) { result.append(value) }

        let first = Array(items.prefix(1)), last = Array(items.suffix(1))
        let hookPass = first.first.flatMap { unit(for: $0) }.map { $0.evidence.entryQuality >= 0.34 || $0.evidence.actionDelta >= 0.12 || $0.quality >= 0.62 } ?? false
        if let value = claim(.hookFulfillment, selected: first, passed: hookPass, observation: hookPass ? "Первый план визуально читаем и формирует вход в историю" : "Первый план не подтверждает функцию hook/orientation", kind: .missingHook) { result.append(value) }
        let closurePass = last.first.flatMap { item in unit(for: item).map { item.kind == .photo && $0.quality >= 0.5 || $0.evidence.completion >= 0.34 || $0.evidence.exitQuality >= 0.52 || $0.evidence.atmosphereValue >= 0.62 } } ?? false
        if let value = claim(.closureFulfillment, selected: last, passed: closurePass, observation: closurePass ? "Последний план подтверждает завершение/выход/атмосферную точку" : "Последний план не подтверждает closure", kind: .missingClosure) { result.append(value) }

        var missingBridge = false
        for (left, right) in zip(items, items.dropFirst()) {
            guard let a = unit(for: left), let b = unit(for: right), a.eventID != b.eventID || a.sceneID != b.sceneID else { continue }
            let tokensA = a.candidate.tags.union(Set((a.candidate.insights?.sceneSummary ?? "").lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)))
            let tokensB = b.candidate.tags.union(Set((b.candidate.insights?.sceneSummary ?? "").lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)))
            let titleBoundary = timeline.effectiveTitleItems.contains { abs($0.startTime - right.timelineStart) <= 1.0 }
            if tokensA.intersection(tokensB).isEmpty && !titleBoundary && EditorialContinuityGraph().edge(from: a, to: b).cost > 0.78 { missingBridge = true }
        }
        if let value = claim(.eventBridge, passed: !missingBridge, observation: missingBridge ? "Между разными событиями нет visual/audio/title bridge" : "Переходы между событиями имеют общий контекст или явную chapter boundary", kind: .eventTransitionWithoutBridge) { result.append(value) }

        let titles = timeline.effectiveTitleItems.filter(\.enabled)
        let titlePass = titles.allSatisfy { title in
            !SmartTitleEngine.isPlaceholderTitle(title.text, allowsNumericText: title.kind == .date)
        }
        if !titles.isEmpty, let value = claim(.titleGrounding, passed: titlePass, observation: titlePass ? "Титры содержательны и привязаны к покрываемым сценам" : "Обнаружен placeholder/бессодержательный автоматический титр", kind: .chapterCoverageMismatch, repair: .decoration) { result.append(value) }

        if !timeline.effectiveTelemetryItems.isEmpty {
            let bad = timeline.effectiveTelemetryItems.contains { overlay in
                guard overlay.settings.metrics.contains(.gForce) else { return false }
                let owner = items.first { $0.id == overlay.targetClipID }
                let telemetry = analyses.first { $0.assetID == (overlay.linkedAssetID ?? owner?.assetID) }?.telemetry
                let values = (telemetry?.timedSamples ?? []).compactMap { sample -> Double? in
                    if let value = sample.gForce { return value }
                    if let x = sample.gForceX, let y = sample.gForceY { return hypot(x, y) }
                    return nil
                }
                return values.map(abs).max() ?? 0 <= 0.15
            }
            if let value = claim(.telemetryMeaningfulness, passed: !bad, observation: bad ? "Telemetry не подтверждена значимым измеренным изменением" : "Telemetry соответствует измеренному событию", kind: .meaninglessTelemetry, repair: .decoration) { result.append(value) }
        }

        if let trackID = timeline.music?.trackID, let track = tracks.first(where: { $0.id == trackID }) {
            let words = ([track.title] + track.genres + track.moods).joined(separator: " ").lowercased()
            let calm = (plan.autonomousDecision?.finalStyle.energy ?? 0.5) < 0.48
            let strong = ["western", "showdown", "horror", "suspense", "battle"].contains(where: words.contains)
            let musicPass = !(calm && strong && !plan.prompt.lowercased().split(separator: " ").contains { words.contains($0) })
            if let value = claim(.musicNarrativeFit, passed: musicPass, observation: musicPass ? "Музыкальный характер не противоречит измеренной энергии истории" : "Выраженный жанр музыки конфликтует с историей", kind: .musicNarrativeMismatch, repair: .decoration) { result.append(value) }
        }
        return result
    }
}
