import Foundation

/// Source replacement is a media operation, not an approximation using color
/// or audio commands. Plan the complete selection before committing any edit.
enum LocalShotReplacement {
    private static let visual = #"(?:фрагмент\w*|кус(?:ок|к\w*|очек\w*)|клип\w*|кадр\w*|эпизод\w*|момент\w*|сцен\w*|дубл\w*|отрыв\w*|участ\w*|видео\w*|shot|clip|footage|scene|segment)"#
    private static let change = #"(?:замен\w*|поменя\w*|смени\w*|сменить|меняй|переподбер\w*|переподобр\w*|перевыбер\w*|перевыбр\w*|replace|swap)"#
    private static let alternative = #"(?:друг\w*|ино[йею]|иную|иным|нов\w*|альтернатив\w*|another|different|alternative)"#
    private static let otherMedia = #"(?:музык\w*|трек\w*|звук\w*|аудио\w*|титр\w*|надпис\w*|назван\w*|цвет\w*|фильтр\w*|переход\w*|скорост\w*|громкост\w*|яркост\w*|контраст\w*|music|audio|title|color|filter|transition)"#

    private static func normalized(_ prompt: String) -> String {
        prompt.lowercased().replacingOccurrences(of: "ё", with: "е")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
    }

    private static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: #"\b(?:"# + pattern + #")\b"#, options: .regularExpression) != nil
    }

    static func allowsReplacement(_ prompt: String) -> Bool {
        let text = normalized(prompt)
        // A semantic model must also respect an explicit instruction to keep
        // the footage. Negating a music edit does not prohibit video replacement.
        let negatedChange = #"(?:не\s+(?:надо\s+|нужно\s+)?|don't\s+|do\s+not\s+)"# + change
        if matches(text, negatedChange + #"(?:\s+\w+){0,2}\s+"# + visual) { return false }
        if matches(text, visual + #"(?:\s+\w+){0,2}\s+(?:не\s+трогай|оставь\s+как\s+есть|сохрани)"#) { return false }
        if matches(text, #"(?:сохрани|не\s+трогай)\s+(?:этот\s+|исходный\s+)?"# + visual) { return false }
        if matches(text, #"не\s+(?:хочу|нужен|нужно|выбирай)\s+"# + alternative + #"\s+"# + visual) { return false }
        return !matches(text, negatedChange + #"(?:\s+(?:это|его|ничего))?[.!?]*$"#)
    }

    static func requestsReplacement(_ prompt: String) -> Bool {
        guard allowsReplacement(prompt) else { return false }
        let text = normalized(prompt)
        let clauses = text.components(separatedBy: CharacterSet(charactersIn: ",;.!?\n"))
        for clause in clauses {
            let hasVisual = matches(clause, visual)
            // Mentioning the selected clip does not make an audio/color edit a
            // footage replacement: “замени музыку в этом фрагменте”.
            if matches(clause, change + #"(?:\s+\w+){0,2}\s+"# + otherMedia),
               !matches(clause, change + #"(?:\s+(?:этот|выбранный|выделенный))?\s+"# + visual) { continue }
            if matches(clause, otherMedia) { continue }
            if matches(clause, #"(?:местами|перестав\w*|удлини\w*|укорот\w*)"#) { continue }
            if matches(clause, #"добав\w*"#), !matches(clause, "вместо") { continue }
            if matches(clause, change), hasVisual { return true }
            if clause.trimmingCharacters(in: .whitespaces).range(of: #"^(?:пожалуйста\s+)?"# + change + #"(?:\s+(?:его|это|на\s+другой|пожалуйста))*$"#, options: .regularExpression) != nil { return true }
            let select = #"(?:подбер\w*|подобр\w*|выбер\w*|выбр\w*|возьми|возьмем|постав\w*|встав\w*|покаж\w*|показ\w*|использ\w*|найд\w*|найти|хочу|давай|нужен|нужно|choose|pick|use|show|want)"#
            if matches(clause, alternative), (hasVisual || matches(clause, select)) { return true }
            if hasVisual, matches(clause, #"(?:не\s+подходит|не\s+нравится|неудачн\w*)"#) { return true }
        }
        return false
    }

    static func apply(to sliced: Timeline, itemIDs: Set<UUID>, original: Timeline, project: ProjectManifest) throws -> Timeline {
        let targets = sliced.items.filter { itemIDs.contains($0.id) && $0.overlay == nil && $0.kind == .video }
        guard !targets.isEmpty else { throw unavailable("В выделении нет видео для замены.") }
        // Replacement needs the selected scene's cached analysis only. Avoid
        // rebuilding the archive-wide pairwise shot-family index on each click.
        let ownership = project.events.reduce(into: [UUID: (event: UUID, scene: UUID)]()) { map, event in
            for scene in event.effectiveScenes { for id in scene.candidateIDs { map[id] = (event.id, scene.id) } }
        }
        let units = project.analyses.flatMap(\.directorCandidates).filter { !$0.excluded }.compactMap { candidate -> EditorialUnit? in
            let scope = ownership[candidate.id]
            guard targets.contains(where: {
                if let scene = $0.eventSceneID { return scope?.scene == scene }
                if let event = $0.eventID { return scope?.event == event }
                return candidate.assetID == $0.assetID
            }) else { return nil }
            return EditorialUnit(candidate: candidate, eventID: scope?.event, sceneID: scope?.scene)
        }
        let assets = Dictionary(uniqueKeysWithValues: project.assets.map { ($0.id, $0) })
        let rejected = original.items.filter { item in
            targets.contains { $0.timelineStart < item.timelineStart + item.timelineDuration - 0.0001 && $0.timelineStart + $0.timelineDuration > item.timelineStart + 0.0001 }
        }
        var result = sliced
        for target in targets {
            guard !target.locked, !target.isFreezeFrame, !target.isReversed, target.speedRamp == nil else {
                throw unavailable("Выбранный фрагмент заблокирован или использует обратное воспроизведение, стоп-кадр либо переменную скорость.")
            }
            // Detached source sound and telemetry must never silently retain
            // measurements from the shot that was removed.
            guard !sliced.effectiveAudioClips.contains(where: { $0.attachedToItemID == target.id }),
                  !sliced.effectiveTelemetryItems.contains(where: { $0.timelineStart < target.timelineStart + target.timelineDuration && $0.timelineEnd > target.timelineStart }) else {
                throw unavailable("Сначала отсоедините телеметрию или извлечённый звук выбранного фрагмента.")
            }
            let duration = target.sourceDuration
            let previous = result.items.last { $0.overlay == nil && $0.timelineStart + $0.timelineDuration <= target.timelineStart + 0.0001 }
            let next = result.items.first { $0.overlay == nil && $0.timelineStart >= target.timelineStart + target.timelineDuration - 0.0001 }
            let originalUnit = units.first { $0.id == target.candidateID }
            let clusterer = ShotFamilyClusterer()
            var options: [(unit: EditorialUnit, start: Double, ordered: Bool, distinct: Bool)] = []
            for unit in units {
                guard unit.id != target.candidateID, unit.discardReason == nil, !unit.evidence.hasHardOcclusion,
                      unit.quality >= 0.55, unit.evidence.confidence >= 0.55,
                      let asset = assets[unit.candidate.assetID], asset.kind == .video, !asset.missing, !asset.excluded else { continue }
                if let scene = target.eventSceneID {
                    guard unit.sceneID == scene else { continue }
                } else if let event = target.eventID {
                    guard unit.eventID == event else { continue }
                } else if unit.candidate.assetID != target.assetID { continue }
                let lower = max(unit.sourceRange.start, unit.evidence.usableRange.start)
                let upper = min(unit.sourceRange.end, unit.evidence.usableRange.end, asset.metadata.duration ?? unit.sourceRange.end)
                guard upper - lower >= duration - 0.0001 else { continue }
                let start = min(max(lower, target.sourceStart), upper - duration)
                let end = start + duration
                // Replacing an unwanted shot must also exclude its immediate
                // lead-in and continuation. A different candidate ID a few
                // seconds earlier can still show the same person entering.
                let separation = max(10, min(30, duration * 4))
                guard !rejected.contains(where: {
                    $0.assetID == asset.id && start < $0.sourceStart + $0.sourceDuration + separation - 0.0001
                        && end > $0.sourceStart - separation + 0.0001
                }) else { continue }
                if let protected = EditorialMomentPolicy.protectedRange(unit), protected.start < start || protected.end > end { continue }
                let occupied = rejected + result.items.filter { $0.id != target.id }
                guard !occupied.contains(where: { $0.assetID == asset.id && $0.sourceStart < end - 0.0001 && $0.sourceStart + $0.sourceDuration > start + 0.0001 }) else { continue }
                let ordered = (previous?.assetID != asset.id || previous!.sourceStart + previous!.sourceDuration <= start + 0.0001)
                    && (next?.assetID != asset.id || end <= next!.sourceStart + 0.0001)
                let relation = originalUnit.map { clusterer.relation($0, unit) }
                let distinct = relation != .hardDuplicate && relation != .sameSetup && relation != .sameActionState
                options.append((unit, start, ordered, distinct))
            }
            options.sort {
                // A later second of the same blocked composition is a poor
                // replacement even when it has a slightly higher sharpness.
                if $0.distinct != $1.distinct { return $0.distinct }
                if $0.ordered != $1.ordered { return $0.ordered }
                let sameA = $0.unit.candidate.assetID == target.assetID, sameB = $1.unit.candidate.assetID == target.assetID
                if sameA != sameB { return sameA }
                if $0.unit.quality != $1.unit.quality { return $0.unit.quality > $1.unit.quality }
                return $0.unit.id.uuidString < $1.unit.id.uuidString
            }
            guard let choice = options.first, let index = result.items.firstIndex(where: { $0.id == target.id }) else {
                throw unavailable("Для выделения не найден другой проверенный момент той же сцены нужной длины. Попробуйте выделить более короткий участок.")
            }
            result.items[index].candidateID = choice.unit.id
            result.items[index].assetID = choice.unit.candidate.assetID
            result.items[index].sourceStart = choice.start
            result.items[index].eventID = choice.unit.eventID ?? target.eventID
            result.items[index].eventSceneID = choice.unit.sceneID ?? target.eventSceneID
            result.items[index].editorialPurpose = choice.unit.candidate.insights?.sceneSummary
            result.items[index].explanation = choice.unit.candidate.explanation + ["Волшебная кисть: выбран другой исходный момент"]
            var adjustments = result.items[index].effectiveVideoAdjustments
            adjustments.subjectReframe = nil
            adjustments.crop = .fit
            result.items[index].videoAdjustments = adjustments
        }
        // Boundary slicing must not accumulate floating-point changes in
        // untouched shots. Keep their complete original model values.
        for item in original.items where !targets.contains(where: {
            $0.timelineStart < item.timelineStart + item.timelineDuration - 0.0001 && $0.timelineStart + $0.timelineDuration > item.timelineStart + 0.0001
        }) {
            if let index = result.items.firstIndex(where: { $0.id == item.id }) { result.items[index] = item }
        }
        result.editorialReview = nil
        result.filmDeliveryReport = nil
        result.editorialBeatPlan = nil
        return result
    }

    private static func unavailable(_ reason: String) -> LocalEditorialEditError {
        .unavailable("\(reason) Замена не выполнена; монтаж сохранён.")
    }
}
