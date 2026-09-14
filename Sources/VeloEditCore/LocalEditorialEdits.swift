import Foundation

public struct LocalEditorialEdit: Identifiable, Sendable {
    public var id: UUID = UUID()
    public var title: String
    public var before: Timeline
    public var after: Timeline
    public var affectedItemIDs: [UUID]
    public var start: Double
    public var end: Double
    public var detail: String
}

public enum LocalEditorialEditError: LocalizedError {
    case unavailable(String)
    public var errorDescription: String? { switch self { case .unavailable(let value): value } }
}

/// Read-only proposals in an explicitly bounded area. Applying one proposal
/// is one ordinary Timeline commit, so all dependent state shares its Undo.
public enum LocalEditorialEditPlanner {
    public static func alternatives(itemID: UUID, timeline: Timeline, project: ProjectManifest) -> [LocalEditorialEdit] {
        guard let index = timeline.items.firstIndex(where: { $0.id == itemID }), supported(timeline.items[index]) else { return [] }
        let original = timeline.items[index]
        guard !hasDependentMedia(timeline, ids: [itemID]) else { return [] }
        let context = EditorialAnalysisContext(analyses: project.analyses, events: project.events)
        let sourceMap = SourceTimelineAnalyzer().analyze(assets: project.assets, analyses: project.analyses)
        let order = Dictionary(uniqueKeysWithValues: sourceMap.orderedAssetIDs.enumerated().map { ($0.element, $0.offset) })
        let assets = Dictionary(uniqueKeysWithValues: project.assets.map { ($0.id, $0) })
        let previous = timeline.items[..<index].last { $0.overlay == nil && $0.kind != .title }
        let next = timeline.items.dropFirst(index + 1).first { $0.overlay == nil && $0.kind != .title }
        func before(_ asset: UUID, _ time: Double, _ other: TimelineItem) -> Bool {
            guard let otherAsset = other.assetID, let a = order[asset], let b = order[otherAsset] else { return false }
            return a < b || (a == b && time <= other.sourceStart + 0.0001)
        }
        let units = context.units.filter { unit in
            guard unit.id != original.candidateID, unit.quality >= 0.55, unit.evidence.confidence >= 0.55,
                  let asset = assets[unit.candidate.assetID], !asset.missing, !asset.excluded, asset.kind == .video,
                  unit.usableDuration >= original.sourceDuration else { return false }
            if let scene = original.eventSceneID { guard unit.sceneID == scene else { return false } }
            else if let event = original.eventID { guard unit.eventID == event else { return false } }
            else { guard unit.candidate.assetID == original.assetID else { return false } }
            let start = max(unit.sourceRange.start, unit.evidence.usableRange.start)
            let end = start + original.sourceDuration
            if let previous, let assetID = previous.assetID {
                guard let a = order[assetID], let b = order[unit.candidate.assetID], a < b || (a == b && previous.sourceStart + previous.sourceDuration <= start + 0.0001) else { return false }
            }
            if let next, !before(unit.candidate.assetID, end, next) { return false }
            if let range = EditorialMomentPolicy.protectedRange(unit), range.start < start || range.end > end { return false }
            return !timeline.items.contains { item in
                item.id != original.id && item.assetID == unit.candidate.assetID && item.sourceStart < end && item.sourceStart + item.sourceDuration > start
            }
        }.sorted { $0.quality == $1.quality ? $0.id.uuidString < $1.id.uuidString : $0.quality > $1.quality }
        let existing = timeline.items.filter { $0.id != itemID }.compactMap { item in context.units.first { $0.id == item.candidateID } }
        var accepted: [EditorialUnit] = []
        var edits: [LocalEditorialEdit] = []
        for unit in units {
            guard edits.count < 3 else { break }
            guard (existing + accepted).allSatisfy({ !ShotFamilyClusterer().isHardDuplicate($0, unit, adjacent: false) }) else { continue }
            var after = timeline
            after.items[index].candidateID = unit.id; after.items[index].assetID = unit.candidate.assetID
            after.items[index].sourceStart = max(unit.sourceRange.start, unit.evidence.usableRange.start)
            after.items[index].videoAdjustments?.subjectReframe = nil
            var adjustments = after.items[index].effectiveVideoAdjustments
            adjustments.crop = .fit; after.items[index].videoAdjustments = adjustments
            after.editorialReview = nil
            after.editorialBeatPlan?.beats.removeAll { $0.candidateID == original.candidateID }
            edits.append(.init(title: "Другой кадр", before: timeline, after: after, affectedItemIDs: [itemID],
                start: original.timelineStart, end: original.timelineStart + original.timelineDuration,
                detail: "Один фрагмент, \(String(format: "%.1f", original.timelineDuration)) с. Длительность фильма сохраняется."))
            accepted.append(unit)
        }
        return edits
    }

    public static func duration(itemID: UUID, longer: Bool, timeline: Timeline, project: ProjectManifest) throws -> LocalEditorialEdit {
        guard let index = timeline.items.firstIndex(where: { $0.id == itemID }), supported(timeline.items[index]) else {
            throw LocalEditorialEditError.unavailable("Фрагмент заблокирован или использует особую скорость. Текущая версия сохранена.")
        }
        let original = timeline.items[index]
        let units = Dictionary(project.analyses.flatMap(\.directorCandidates).map { ($0.id, EditorialUnit(candidate: $0)) }, uniquingKeysWith: { a, _ in a })
        let fps = max(1, timeline.frameRate)
        let delta = (min(1.5, max(0.5, original.timelineDuration * 0.2)) * fps).rounded() / fps * (longer ? 1 : -1)
        // Compensate only in an immediate, unlocked neighbour of the same
        // chapter. The outer boundary and every later absolute position stay.
        let neighbours = [index + 1, index - 1].filter { timeline.items.indices.contains($0) }
        for neighbour in neighbours {
            let other = timeline.items[neighbour]
            guard supported(other), other.eventID == original.eventID, other.eventSceneID == original.eventSceneID,
                  !hasDependentMedia(timeline, ids: [itemID, other.id]) else { continue }
            var after = timeline
            after.items[index].sourceDuration += delta; after.items[index].timelineDuration += delta
            after.items[neighbour].sourceDuration -= delta; after.items[neighbour].timelineDuration -= delta
            let changed = [index, neighbour]
            guard changed.allSatisfy({ i in
                let item = after.items[i]
                guard item.timelineDuration >= 1.5, let id = item.candidateID, let unit = units[id],
                      item.sourceStart >= max(unit.sourceRange.start, unit.evidence.usableRange.start) - 0.001,
                      item.sourceStart + item.sourceDuration <= min(unit.sourceRange.end, unit.evidence.usableRange.end) + 0.001 else { return false }
                if let range = EditorialMomentPolicy.protectedRange(unit), item.sourceStart > range.start + 1 / fps || item.sourceStart + item.sourceDuration < range.end - 1 / fps { return false }
                return !after.items.contains { other in other.id != item.id && other.assetID == item.assetID && other.sourceStart < item.sourceStart + item.sourceDuration - 0.001 && other.sourceStart + other.sourceDuration > item.sourceStart + 0.001 }
            }) else { continue }
            after.items = TimelineTiming.retimed(after.items)
            let ids: Set<UUID> = [itemID, other.id]
            for i in after.titleItems?.indices ?? 0..<0 {
                guard let target = after.titleItems?[i].targetClipID, ids.contains(target),
                      let old = timeline.items.first(where: { $0.id == target }), let new = after.items.first(where: { $0.id == target }) else { continue }
                after.titleItems?[i].startTime += new.timelineStart - old.timelineStart
            }
            for i in after.transitionItems?.indices ?? 0..<0 {
                guard let incoming = after.transitionItems?[i].incomingClipID, ids.contains(incoming),
                      let old = timeline.items.first(where: { $0.id == incoming }), let new = after.items.first(where: { $0.id == incoming }) else { continue }
                after.transitionItems?[i].startTime += new.timelineStart - old.timelineStart
            }
            after.editorialReview = nil
            let lower = min(index, neighbour), upper = max(index, neighbour)
            return .init(title: longer ? "Оставить момент подольше" : "Покороче", before: timeline, after: after,
                affectedItemIDs: [timeline.items[lower].id, timeline.items[upper].id], start: timeline.items[lower].timelineStart,
                end: timeline.items[upper].timelineStart + timeline.items[upper].timelineDuration,
                detail: "Два соседних фрагмента этой главы: \(longer ? "+" : "−")\(String(format: "%.1f", abs(delta))) с у выбранного, компенсация у соседнего. Длительность фильма сохраняется.")
        }
        throw LocalEditorialEditError.unavailable("В этой области нельзя изменить длину без потери момента, сдвига связанных дорожек или нарушения блокировки. Текущая версия сохранена. Для большей области используйте «Правка с AI» с явным указанием соседних сцен.")
    }

    private static func supported(_ item: TimelineItem) -> Bool {
        item.kind == .video && !item.locked && item.overlay == nil && !item.isFreezeFrame && !item.isReversed && item.speedRamp == nil && abs(item.speed - 1) < 0.001
    }

    private static func hasDependentMedia(_ timeline: Timeline, ids: Set<UUID>) -> Bool {
        let items = timeline.items.filter { ids.contains($0.id) }
        let start = items.map(\.timelineStart).min() ?? 0
        let end = items.map { $0.timelineStart + $0.timelineDuration }.max() ?? 0
        return timeline.items.contains { $0.overlay?.baseItemID.map(ids.contains) == true } ||
            timeline.effectiveAudioClips.contains { $0.timelineStart < end && $0.timelineStart + $0.timelineDuration > start } ||
            timeline.effectiveTelemetryItems.contains { $0.timelineStart < end && $0.timelineStart + $0.timelineDuration > start } ||
            timeline.effectiveEffects.contains { $0.startTime < end && $0.endTime > start } ||
            timeline.effectiveAdaptiveSoundtrack?.segments.contains { $0.timelineStart > start && $0.timelineStart < end } == true
    }
}
