import Foundation

public enum EditorialFindingKind: String, Codable, CaseIterable, Hashable, Sendable {
    case sourceCoverageGap, sourceChronologyViolation
    case hardDuplicate, missingPrimaryVideo, mechanicalCadence, shotFamilyRunTooLong, dominantSetup, lowInformationSpan
    case falseNarrativeRole, missingHook, missingClosure, eventTransitionWithoutBridge, chapterCoverageMismatch
    case unsafeReframe, cropJump, foregroundOcclusion, audioPolicyViolation, musicNarrativeMismatch
    case unmotivatedEffect, meaninglessTelemetry, pendingIntentUnsatisfied, durationPadding, staleGenerationResult
    case blankRenderedFrame, renderedEvidenceUnavailable, previewExportMismatch
    case unreadableTitle, incompleteMoment, longSpeechWithoutVisualDevelopment, audioPeakViolation
    case durationUnderflow, audioLoudnessViolation, blockingEvidenceUnknown, dominantForegroundObject
}

public enum EditorialRepairClass: String, Codable, Hashable, Sendable {
    case intent, technical, removeDuplicate, structuralReplan, framing, decoration, rhythm, none
}

public struct EditorialFinding: Codable, Hashable, Sendable {
    public var kind: EditorialFindingKind
    /// 3 = critical, 2 = high, 1 = advisory. Scores never compensate a gate.
    public var severity: Int
    public var itemIDs: [UUID]
    public var repair: EditorialRepairClass
    public var reason: String
}

enum EditorialContentBudgetPolicy {
    static let renderedSafetyRepairMarker = "Rendered safety repair: удалённые candidates исключены из обязательных narrative beats"

    static func effectiveLowerBound(decision: ContentBudgetDecision, timeline: Timeline) -> Double {
        guard decision.durationConstraintStatus == .compromisedInsufficientContent,
              timeline.editorialBeatPlan?.reasons.contains(renderedSafetyRepairMarker) == true else {
            return decision.budget.safeRange.lowerBound
        }
        // Only a render-proven safety exclusion may lower the already
        // compromised floor. The committed film remains bounded by real
        // surviving beats and never grows through duplicate/padding content.
        let beatDuration = timeline.editorialBeatPlan?.beats.reduce(0) { $0 + $1.allocatedDuration } ?? timeline.duration
        return min(decision.budget.safeRange.lowerBound, timeline.duration, beatDuration)
    }
}

public struct EditorialReview: Codable, Hashable, Sendable {
    public var sourceCoverage: [SourceCoverageDecision]? = nil
    public var evidenceVersion: Int? = nil
    public var evidenceDomains: [EditorialDomainEvidence]? = nil
    public var familyDistribution: EditorialFamilyDistribution? = nil
    public var exportVerification: EditorialExportVerification? = nil
    public var findings: [EditorialFinding]
    public var familyHistogram: [String: Double]
    public var maximumFamilyRun: Double
    public var informationDensity: Double
    public var narrativeCoherence: Double
    public var framingSafety: Double
    public var audioCoherence: Double
    public var shotFamilyDiversity: Double
    public var rhythmQuality: Double
    public var audioMasteringReport: EditorialAudioMasteringReport? = nil
    public var scoreComponents: [String: Double]? = nil
    public var editorialScore: Double
    public var duration: ContentBudgetDecision?
    public var renderedProbeCount: Int
    public var editorialSignature: String?
    public var conservativeFallback: Bool
    public var discardedCandidates: [UUID: EditorialDiscardReason]
    public var criticalCount: Int { findings.filter { $0.severity >= 3 }.count }
    public var highCount: Int { findings.filter { $0.severity == 2 }.count }
    public var hardGatePassed: Bool { criticalCount == 0 }
    public var rankingEligible: Bool {
        !findings.contains { $0.severity >= 2 && $0.kind != .blockingEvidenceUnknown }

    }
    public var blockingUnknowns: [EditorialDomainEvidence] {
        (evidenceDomains ?? []).filter { $0.required && $0.status != .failed && !$0.isSufficient }
    }
    public var candidateEligible: Bool {
        guard evidenceVersion == EditorialEvidenceVerifier.version, let domains = evidenceDomains,
              domains.count == EditorialEvidenceDomain.allCases.count,
              Set(domains.map(\.domain)) == Set(EditorialEvidenceDomain.allCases),
              !domains.contains(where: { $0.domain != .pendingIntentSatisfaction && $0.blocksProduction }) else { return false }
        return criticalCount == 0 && highCount == 0
    }
    public var productionEligible: Bool {
        candidateEligible && evidenceDomains?.first(where: { $0.domain == .pendingIntentSatisfaction })?.isSufficient == true
    }

}

public struct EditorialQualityGate: Sendable {
    public init() {}
    public func review(timeline: Timeline, plan: StoryPlan, analyses: [AnalysisResult], renderedFrames: [PerceptualRenderedFrameEvidence]? = nil, requireRenderedEvidence: Bool = false, requireCompleteEvidence: Bool = true, musicTracks: [LocalMusicTrack] = [], context suppliedContext: EditorialAnalysisContext? = nil) -> EditorialReview {
        let context = suppliedContext ?? EditorialAnalysisContext(analyses: analyses)
        let byID = Dictionary(uniqueKeysWithValues: context.units.map { ($0.id, $0) })
        let items = timeline.items.filter { $0.overlay == nil && $0.kind != .title }.sorted { $0.timelineStart < $1.timelineStart }
        var findings: [EditorialFinding] = []
        func add(_ kind: EditorialFindingKind, _ severity: Int, _ ids: [UUID], _ repair: EditorialRepairClass, _ reason: String) {
            findings.append(.init(kind: kind, severity: severity, itemIDs: ids, repair: repair, reason: reason))
        }
        if items.isEmpty { add(.missingPrimaryVideo, 3, [], .structuralReplan, "Нет primary video/photo") }
        let sourceCoverage = plan.narrativeBeatPlan == nil ? nil : EditorialSourceCoverage.decisions(timeline: timeline, context: context, plan: plan)
        for gap in sourceCoverage ?? [] where gap.reason == .selectionGap {
            // Rough variants are still selecting their representatives. The
            // complete source-coverage contract belongs to final assembly.
            let severity = plan.sourceCoverageAssetIDs == nil ? 1 : 2
            add(.sourceCoverageGap, severity, [], .structuralReplan, "Исходник \(gap.assetID): \(gap.detail); кандидаты: \(gap.candidateIDs)")
        }
        if plan.narrativeBeatPlan != nil {
            let reversals = EditorialSourceCoverage.chronologyViolations(timeline: timeline, sourceMap: plan.eventStory?.diagnostics?.sourceMap)
            if !reversals.isEmpty { add(.sourceChronologyViolation, 2, reversals, .structuralReplan, "Нарушен хронологический порядок автоматической сборки") }
        }
        if !AutomaticFilmDurationPolicy.meetsMinimum(timeline) {
            add(.durationUnderflow, 3, [], .structuralReplan, AutomaticFilmDurationPolicy.failureMessage(for: timeline))
        }
        for block in EditorialPresentationPolicy.missingChapterTitles(in: timeline, plan: plan) {
            add(.unreadableTitle, 3, block.items.map(\.id), .decoration,
                "Нет читаемого титра с начала части «\(block.text)» на \(block.start) с")
        }
        let invalidCutaways = EditorialCutawayPolicy.invalidOverlayIDs(in: timeline, plan: plan, analyses: analyses)
        if !invalidCutaways.isEmpty {
            add(.unmotivatedEffect, 3, Array(invalidCutaways), .decoration, "Перебивка взята из другой или неподтверждённой сцены")
        }
        var histogram: [String: Double] = [:]
        var lastFamily: String?, runCount = 0
        var runSeconds = 0.0, maxRun = 0.0, gains = 0.0
        let clusterer = ShotFamilyClusterer()
        var seen: [EditorialUnit] = []
        let atmospheric = plan.narrativeBeatPlan?.pattern == .atmosphericObservation
        for item in items {
            guard let id = item.candidateID, var unit = byID[id] else { continue }
            unit.candidate.sourceStart = item.sourceStart
            unit.candidate.sourceDuration = item.sourceDuration
            let family = context.families.familyByUnitID[id] ?? id.uuidString
            histogram[family, default: 0] += item.timelineDuration
            runCount = family == lastFamily ? runCount + 1 : 1
            runSeconds = family == lastFamily ? runSeconds + item.timelineDuration : item.timelineDuration
            maxRun = max(maxRun, runSeconds)
            if runCount > 2 || runSeconds > (atmospheric ? 20 : 12) + 0.05 && !unit.evidence.hasProgression && unit.speechSeconds == 0 {
                add(.shotFamilyRunTooLong, 3, [item.id], .structuralReplan, "Повтор camera setup: \(runCount) планов, \(Int(runSeconds)) с")
            }
            lastFamily = family
            if seen.enumerated().contains(where: { clusterer.isHardDuplicate($0.element, unit, adjacent: $0.offset == seen.count - 1, frameRate: timeline.frameRate) }) {
                add(.hardDuplicate, 3, [item.id], .removeDuplicate, "Повтор source range или взаимозаменяемого setup без нового состояния")
            }
            let novel = !seen.contains { context.families.familyByUnitID[$0.id] == family }
            gains += (novel ? 0.82 : max(unit.evidence.informationGain, unit.evidence.actionDelta)) * min(item.timelineDuration, unit.usableDuration) / max(0.05, item.timelineDuration)
            if unit.evidence.hasHardOcclusion { add(.foregroundOcclusion, 3, [item.id], .technical, "Случайная foreground-окклюзия превышает 28%") }
            if item.sourceDuration > unit.usableDuration + 0.1 && !item.locked {
                add(.durationPadding, 3, [item.id], .structuralReplan, "Длительность плана превышает подтверждённое действие/речь/наблюдение")
            }
            if let report = item.effectiveVideoAdjustments.subjectReframe?.safetyReport, !report.passed {
                add(.unsafeReframe, 3, [item.id], .framing, report.reasons.joined(separator: "; "))
            }
            if let boundary = unit.candidate.momentBoundary, boundary.confirmedActionConfidence >= 0.65,
               item.sourceStart > boundary.anticipationStart + 1 / max(1, timeline.frameRate)
                || item.sourceStart + item.sourceDuration < boundary.completionEnd - 1 / max(1, timeline.frameRate) {
                add(.incompleteMoment, 2, [item.id], .structuralReplan, "Подтверждённые границы действия обрезаны: подготовка или завершение отсутствуют")
            }
            if item.storyRole == .climax && plan.narrativeBeatPlan != nil && !(unit.evidence.hasProgression && unit.evidence.completion >= 0.65) {
                add(.falseNarrativeRole, 2, [item.id], .structuralReplan, "Climax label не подтверждён завершением действия")
            }
            if unit.speechSeconds > 0, ExplicitDeliveryRequirements(plan: plan).originalAudioVolume != 0, let speech = unit.candidate.insights?.speech {
                if item.sourceStart > speech.phraseStart + 0.1 || item.sourceStart + item.sourceDuration < speech.phraseEnd - 0.1 {
                    add(.incompleteMoment, 2, [item.id], .structuralReplan, "Полезная речевая фраза обрезана")
                }
                if item.timelineDuration > 20 {
                    let cutaways = timeline.items.filter { $0.overlay?.baseItemID == item.id && $0.overlay?.style == .cutaway }.sorted { $0.timelineStart < $1.timelineStart }
                    var cursor = item.timelineStart
                    var longest = 0.0
                    for cutaway in cutaways {
                        longest = max(longest, cutaway.timelineStart - cursor)
                        cursor = max(cursor, cutaway.timelineStart + cutaway.timelineDuration)
                    }
                    longest = max(longest, item.timelineStart + item.timelineDuration - cursor)
                    if longest > 20 { add(.longSpeechWithoutVisualDevelopment, 2, [item.id], .structuralReplan, "Речь длиннее 20 с требует связанного внутреннего cutaway") }
                }
            }
            seen.append(unit)
        }
        let duration = max(0.05, timeline.duration)
        let dominant = (histogram.values.max() ?? 0) / duration
        let distribution = EditorialFamilyDistribution(histogram: histogram, maximumRun: maxRun, atmospheric: atmospheric)
        if distribution.excessive {
            add(.dominantSetup, 2, [], .structuralReplan, "Доминирование setup: превышение равномерной доли \(distribution.dominanceExcess), entropy \(distribution.normalizedEntropy), run \(maxRun) с")
        }
        let durations = items.map(\.timelineDuration).sorted()
        let cadenceCount = durations.map { value in durations.filter { abs($0 - value) <= 2 / max(1, timeline.frameRate) }.count }.max() ?? 0
        let contentDurations = seen.map { $0.preferredDuration(pacing: plan.constraints.pacing) }
        let naturallyUniform = cadenceCount == items.count && seen.count == items.count && seen.allSatisfy { $0.evidence.confidence >= 0.55 } &&
            Set(seen.compactMap { context.families.familyByUnitID[$0.id] }).count == seen.count &&
            (contentDurations.max() ?? 0) - (contentDurations.min() ?? 0) < 0.25
        let mechanical = !naturallyUniform && items.count >= 5 && Double(cadenceCount) / Double(items.count) >= 0.65
        if mechanical { add(.mechanicalCadence, 2, items.map(\.id), .rhythm, "Не менее 65% планов имеют одинаковую длительность ±2 frames") }
        for window in (timeline.duration > 120 ? [20.0, 45.0, 90.0] : [20.0]) where timeline.duration >= window {
            for start in stride(from: 0.0, through: timeline.duration - window, by: window / 2) {
                let block = items.filter { $0.timelineStart < start + window && $0.timelineStart + $0.timelineDuration > start }
                let units = block.compactMap { $0.candidateID.flatMap { byID[$0] } }
                let families = Set(units.compactMap { context.families.familyByUnitID[$0.id] })
                if families.count <= 1 && !units.contains(where: { $0.evidence.hasProgression || $0.speechSeconds > 0 || $0.evidence.atmosphereValue >= 0.65 }) {
                    add(.lowInformationSpan, 2, block.map(\.id), .structuralReplan, "Окно \(Int(start))–\(Int(start + window)) с не добавляет нового состояния")
                }
            }
        }
        if let beatPlan = timeline.editorialBeatPlan ?? plan.narrativeBeatPlan {
            for beat in beatPlan.beats {
                let item = items.first { $0.candidateID == beat.candidateID }
                var fulfilled = item != nil
                if let item, let unit = byID[beat.candidateID], beat.purpose == .peak {
                    fulfilled = fulfilled && unit.evidence.hasProgression && unit.evidence.completion >= 0.65
                    if let boundary = unit.candidate.momentBoundary { fulfilled = fulfilled && item.sourceStart <= boundary.peakTime && item.sourceStart + item.sourceDuration >= boundary.completionEnd - 0.1 }
                }
                if !fulfilled { add(beat.purpose == .closure ? .missingClosure : .missingHook, 3, [], .structuralReplan, "Не выполнена narrative function: \(beat.purpose.rawValue)") }
            }
        }
        let mute = ExplicitDeliveryRequirements(plan: plan).originalAudioVolume == 0
        if mute && (timeline.effectiveOriginalAudioVolume > 0 || !timeline.effectiveAudioClips.isEmpty || timeline.items.contains(where: { $0.kind == .video && !$0.effectiveAudioAdjustments.muted })) {
            add(.audioPolicyViolation, 3, [], .intent, "Hard mute нарушен embedded/detached/natural audio")
        }
        if plan.explicitMusicTrackID == nil && plan.directorBrief?.musicPolicy != .specificTrack,
           let trackID = timeline.music?.trackID, let track = musicTracks.first(where: { $0.id == trackID }),
           (plan.autonomousDecision?.finalStyle.energy ?? 0.5) < 0.48 {
            let words = ([track.title] + track.genres + track.moods).joined(separator: " ").lowercased()
            let strongGenre = ["western", "showdown", "horror", "suspense", "battle"]
            if strongGenre.contains(where: { words.contains($0) && !plan.prompt.lowercased().contains($0) }) {
                add(.musicNarrativeMismatch, 2, [], .decoration, "Выраженный жанр музыки противоречит спокойной narrative curve")
            }
        }
        if !TelemetryOverlayRequestPolicy.requestsOverlay(in: plan.prompt) {
            for overlay in timeline.effectiveTelemetryItems where overlay.settings.metrics.contains(.gForce) {
                let owner = timeline.items.first { $0.id == overlay.targetClipID }
                let telemetry = analyses.first { $0.assetID == (overlay.linkedAssetID ?? owner?.assetID) }?.telemetry
                let values = (telemetry?.timedSamples ?? []).filter { $0.timestamp >= overlay.sourceStart && $0.timestamp <= overlay.sourceStart + overlay.timelineDuration * (owner?.speed ?? 1) }.compactMap { sample -> Double? in
                    if let value = sample.gForce { return value }
                    if let x = sample.gForceX, let y = sample.gForceY { return hypot(x, y) }
                    return nil
                }
                if values.isEmpty || (values.map(abs).max() ?? 0) <= 0.15 {
                    add(.meaninglessTelemetry, 2, [overlay.id], .decoration, "G-force не подтверждён значимым измеренным изменением")
                }
            }
        }
        if !EditorialIntentEnforcer.explicitCreativeRequest(plan.prompt) && timeline.effectiveEffects.contains(where: { $0.enabled && $0.effectType.category == .stylized }) {
            add(.unmotivatedEffect, 3, [], .decoration, "Stylized effect без explicit creative intent")
        }
        if let budget = plan.contentBudget {
            let tolerance = 2 / max(1, timeline.frameRate)
            if timeline.duration > min(budget.supportedDuration, budget.budget.absoluteCeiling, budget.budget.safeRange.upperBound) + tolerance {
                add(.durationPadding, 3, [], .structuralReplan, "Timeline превышает Content Budget")
            }
            let effectiveLowerBound = EditorialContentBudgetPolicy.effectiveLowerBound(decision: budget, timeline: timeline)
            if timeline.duration + tolerance < effectiveLowerBound {
                add(.durationUnderflow, 2, [], .structuralReplan, "Timeline \(timeline.duration) с ниже безопасного минимума \(effectiveLowerBound) с; требуется expanded mining/replan")
            }
        }
        if requireRenderedEvidence && (renderedFrames?.isEmpty ?? true) { add(.renderedEvidenceUnavailable, 3, [], .technical, "Нет проверенных кадров финальной композиции") }
        if let renderedFrames {
            for item in items {
                let candidate = item.candidateID.flatMap { byID[$0] }
                let sourceFaceWasSafe = candidate?.candidate.insights?.subjectTracking?.tracks.contains { $0.kind == .face && $0.meanConfidence >= 0.8 && $0.observations.allSatisfy { !$0.region.touchesEdge } } == true
                let probes = renderedFrames.filter { $0.timelineTime >= item.timelineStart && $0.timelineTime < item.timelineStart + item.timelineDuration && $0.decodeFailed != true && !$0.isBlack }
                let unsafe = probes.filter { frame in
                    frame.renderedSubjects?.contains(where: {
                        $0.kind == .face && $0.confidence >= 0.8 && $0.region.area >= 0.002
                            && $0.region.area <= 0.30 && $0.region.touchesEdge
                    }) == true
                }.count
                if sourceFaceWasSafe, probes.count >= 3, unsafe >= 2, Double(unsafe) / Double(probes.count) >= 0.5 {
                    add(.unsafeReframe, 3, [item.id], .framing, "Лицо устойчиво касается края на реально скомпонованных кадрах")
                }
            }
            let titleEvidence = renderedFrames.flatMap { $0.titleEvidence ?? [] }
                + renderedFrames.compactMap(\.exportVerification).flatMap { $0.titleEvidence ?? [] }
            for evidence in titleEvidence where evidence.isCurrent(for: timeline) && !evidence.passed {
                add(.unreadableTitle, 2, [evidence.titleID], .decoration,
                    "OCR титра на \(evidence.timelineTime) с (\(evidence.source)): \(evidence.failure ?? "ниже порога 0.5")")
            }
            for frame in renderedFrames where frame.expectedVisibleContent && (frame.isBlack || frame.decodeFailed == true) {
                let ids = items.filter { frame.timelineTime >= $0.timelineStart && frame.timelineTime < $0.timelineStart + $0.timelineDuration }.map(\.id)
                add(.blankRenderedFrame, 3, ids, .technical, "Пустой/недекодируемый кадр финальной композиции на \(frame.timelineTime) с")
            }
        }
        let mastering = renderedFrames?.compactMap(\.audioMasteringReport).first
        if let peak = mastering?.outputTruePeakDBTP, peak > -1 {
            add(.audioPeakViolation, 3, [], .technical, "Итоговый микс превышает −1 dBTP")
        }
        let audible = timeline.music?.trackID != nil || !timeline.effectiveAudioClips.isEmpty || timeline.effectiveOriginalAudioVolume > 0 && items.contains { $0.kind == .video && !$0.effectiveAudioAdjustments.muted }
        if audible, let lufs = mastering?.outputLUFS,
           !EditorialLoudnessPolicy.accepts(lufs: lufs, truePeak: mastering?.outputTruePeakDBTP,
               allowsQuietMix: SourceAudioMixPolicy.allowsQuietDelivery(timeline: timeline, plan: plan)) {
            add(.audioLoudnessViolation, 2, [], .technical, "Громкость \(lufs) LUFS вне допустимого диапазона; peak/headroom не заменяет loudness pass")
        }
        let domains = EditorialEvidenceVerifier.verify(timeline: timeline, plan: plan, analyses: analyses, frames: renderedFrames ?? [], findings: findings, units: byID)
        if requireRenderedEvidence {
            for record in domains where record.domain != .pendingIntentSatisfaction && record.blocksProduction {
                if let finding = record.finding {
                    if !findings.contains(finding) { findings.append(finding) }
                } else if requireCompleteEvidence || record.status == .failed {
                    // Sparse variant ranking deliberately has no complete
                    // decode/audio/export proof. Keep measured failures, but
                    // reserve missing-evidence findings for the full review.
                    add(.blockingEvidenceUnknown, 2, record.itemIDs, .none, "\(record.domain.rawValue): \(record.reason); coverage=\(record.coverage), confidence=\(record.confidence), status=\(record.status.rawValue)")
                }
            }
        }
        let density = items.isEmpty ? 0 : (gains / Double(items.count)).clamped01
        let narrativeDomains = domains.filter { [.hookFulfillment, .closureFulfillment, .actionProgression, .eventBridge].contains($0.domain) }
        let narrative = Double(narrativeDomains.filter(\.isSufficient).count) / Double(max(1, narrativeDomains.count))
        let framingDomains = domains.filter { $0.required && [.bodySafety, .faceSafety, .subjectCoverage, .foregroundOcclusion].contains($0.domain) }
        let framing = Double(framingDomains.filter(\.isSufficient).count) / Double(max(1, framingDomains.count))
        let audioDomains = domains.filter { $0.required && [.sourceAudioPolicy, .integratedLoudness, .truePeak].contains($0.domain) }
        let audio = Double(audioDomains.filter(\.isSufficient).count) / Double(max(1, audioDomains.count))
        let rhythm = mechanical ? 0.4 : 0.9
        let diversity = histogram.count >= 3 ? (1 - dominant).clamped01 : 0.85
        let completeness = findings.contains { [.incompleteMoment, .missingClosure].contains($0.kind) } ? 0.35 : 0.9
        let core = Self.geometricMean([narrative, density, completeness, diversity, rhythm, framing, audio])
        let technical = seen.isEmpty ? 0 : seen.reduce(0) { $0 + $1.quality } / Double(seen.count)
        let edges = zip(seen, seen.dropFirst()).map { EditorialContinuityGraph().edge(from: $0, to: $1) }
        let continuity = edges.isEmpty ? 1 : 1 - edges.reduce(0) { $0 + $1.cost } / Double(edges.count)
        let titleProbes = renderedFrames?.compactMap(\.titleReadability) ?? []
        let titleQuality = titleProbes.isEmpty ? (timeline.effectiveTitleItems.isEmpty ? 1 : 0.8) : titleProbes.reduce(0, +) / Double(titleProbes.count)
        let musicFit = findings.contains { $0.kind == .musicNarrativeMismatch } ? 0.2 : 0.9
        let styleFit = findings.contains { $0.kind == .unmotivatedEffect } ? 0.2 : 0.9
        let craft = Self.geometricMean([technical, continuity, titleQuality, musicFit, styleFit])
        let score = max(0, 0.78 * core + 0.22 * craft - Double(findings.filter { $0.severity >= 2 }.count) * 0.05)
        var durationDecision = plan.contentBudget
        if var decision = durationDecision {
            let effectiveLowerBound = EditorialContentBudgetPolicy.effectiveLowerBound(decision: decision, timeline: timeline)
            decision.budget.safeRange = effectiveLowerBound...decision.budget.safeRange.upperBound
            durationDecision = decision
        }
        durationDecision?.committedDuration = timeline.duration
        if let requested = durationDecision?.requestedDuration, abs(timeline.duration - requested) > 2 / max(1, timeline.frameRate), durationDecision?.durationConstraintStatus == .satisfied {
            durationDecision?.durationConstraintStatus = .compromisedInsufficientContent
        }
        if findings.contains(where: { $0.kind == .durationUnderflow }) {
            durationDecision?.requiresExpandedMining = true
            durationDecision?.durationConstraintStatus = .compromisedInsufficientContent
            durationDecision?.reason += " Фактическая длительность ниже безопасного минимума; production commit запрещён."
        }
        return EditorialReview(sourceCoverage: sourceCoverage, evidenceVersion: EditorialEvidenceVerifier.version, evidenceDomains: domains, familyDistribution: distribution, exportVerification: renderedFrames?.compactMap(\.exportVerification).first, findings: findings, familyHistogram: histogram, maximumFamilyRun: maxRun, informationDensity: density, narrativeCoherence: narrative, framingSafety: framing, audioCoherence: audio, shotFamilyDiversity: diversity, rhythmQuality: rhythm, audioMasteringReport: mastering, scoreComponents: ["narrativeCoherence": narrative, "informationDensity": density, "momentCompleteness": completeness, "shotFamilyDiversity": diversity, "rhythmQuality": rhythm, "framingSafety": framing, "audioCoherence": audio, "technicalQuality": technical, "continuity": continuity, "titleQuality": titleQuality, "musicNarrativeFit": musicFit, "styleFit": styleFit], editorialScore: score, duration: durationDecision, renderedProbeCount: renderedFrames?.count ?? 0, editorialSignature: renderedFrames == nil ? nil : EditorialRenderSignature.signature(timeline), conservativeFallback: false, discardedCandidates: plan.narrativeBeatPlan?.discardedCandidates ?? [:])
    }

    public static func geometricMean(_ values: [Double]) -> Double {
        guard !values.isEmpty, values.allSatisfy({ $0 > 0 && $0.isFinite }) else { return 0 }
        return exp(values.reduce(0) { $0 + log($1.clamped01) } / Double(values.count))
    }
}

public enum EditorialIntentEnforcer {
    public static func explicitCreativeRequest(_ prompt: String) -> Bool {
        let text = prompt.lowercased()
        guard !["без эффект", "убери эффект", "no effect", "без глитч"].contains(where: text.contains) else { return false }
        return ["glitch", "глитч", "pixelate", "пикселизац", "halftone", "rgb split", "стилизован"].contains(where: text.contains)
    }

    public static func enforce(_ source: Timeline, plan: StoryPlan) -> Timeline {
        var timeline = source
        if DirectorEffectsPolicyEngine.policy(for: plan) == DirectorEffectsPolicy.none {
            timeline = DirectorEffectsPolicyEngine.removingEffects(from: timeline)
        }
        let requested = Set(EditorCommandParser().parse(plan.prompt, preset: plan.preset).map(\.semanticCategory))
        if !DirectorRequestContract.requestsColorCorrection(plan.prompt),
           requested.isDisjoint(with: ["filter", "brightness", "contrast", "saturation", "warmth", "exposure", "highlights", "shadows", "auto-enhance"]) {
            for index in timeline.items.indices where !timeline.items[index].locked {
                guard var video = timeline.items[index].videoAdjustments else { continue }
                video.filter = .none; video.filterIntensity = 1
                video.brightness = 0; video.contrast = 1; video.saturation = 1
                video.warmth = 0; video.tint = 0; video.exposure = 0
                video.highlights = 0; video.shadows = 0
                timeline.items[index].videoAdjustments = video
            }
        }
        if !DirectorEffectsPolicyEngine.allowsEffects(in: plan) {
            timeline.audioClips = timeline.effectiveAudioClips.filter { $0.role != .soundEffect }
            timeline.effects = timeline.effectiveEffects.filter { effect in
                effect.targetClipID.map { id in timeline.items.contains { $0.id == id && $0.locked } } == true
            }
            for index in timeline.items.indices where !timeline.items[index].locked {
                if timeline.items[index].kind == .video && !requested.contains("effect") { timeline.items[index].effect = nil }
                if var video = timeline.items[index].videoAdjustments {
                    if !requested.contains("vignette") { video.vignette = 0 }
                    if !requested.contains("grain") { video.grain = 0 }
                    if !requested.contains("sharpening") { video.sharpening = 0 }
                    if !requested.contains("video-denoise") { video.denoise = 0 }
                    if !requested.contains("blur") { video.blur = 0 }
                    if !requested.contains("stabilization") { video.stabilization = 0 }
                    if !requested.contains("rolling-shutter") { video.rollingShutterCorrection = false }
                    timeline.items[index].videoAdjustments = video
                }
                if var audio = timeline.items[index].audioAdjustments {
                    audio.effect = AudioEffect.none
                    if !requested.contains("noise-reduction") { audio.noiseReduction = 0 }
                    if !requested.contains("eq") { audio.eqPreset = .flat }
                    timeline.items[index].audioAdjustments = audio
                }
            }
        }
        if !DirectorRequestContract.requestsCutaways(plan.prompt) {
            timeline.items.removeAll { $0.overlay?.style == .cutaway }
        }
        if timeline.editorialBeatPlan == nil { timeline.editorialBeatPlan = plan.narrativeBeatPlan }
        let requirements = ExplicitDeliveryRequirements(plan: plan)
        let volume = requirements.originalAudioVolume
        if requirements.forbidsTitles {
            timeline.titleItems = plan.directorBrief?.subtitlesEnabled(preset: plan.preset) == true
                ? timeline.effectiveTitleItems.filter { [.subtitle, .automaticSubtitles, .wordLevelCaptions].contains($0.kind) } : []
            timeline.items.removeAll { $0.kind == .title }
            timeline.items = TimelineTiming.retimed(timeline.items)
        }
        if requirements.forbidsMusic {
            timeline.music = nil
            timeline.adaptiveSoundtrack = nil
            timeline.audioClips = timeline.effectiveAudioClips.filter { $0.role != .music }
        }
        if volume == 0 {
            timeline.originalAudioVolume = 0
            timeline.audioClips = []
            timeline.audioDucking = nil
            for index in timeline.items.indices {
                var audio = timeline.items[index].effectiveAudioAdjustments
                audio.muted = true
                audio.volume = 0
                timeline.items[index].audioAdjustments = audio
            }
        } else if let volume, volume < 1 {
            timeline = SourceAudioMixPolicy.applyingRequestedVolume(volume, to: timeline)
        }
        if plan.narrativeBeatPlan != nil && !explicitCreativeRequest(plan.prompt) {
            timeline.effects = timeline.effectiveEffects.filter { $0.effectType.category != .stylized }
        }
        timeline = EditorialPresentationPolicy.chapters(in: timeline, plan: plan)
        timeline = EditorialPresentationPolicy.ensuringRequestedTitle(in: timeline, plan: plan)
        return EditorialPresentationPolicy.stylingGeneratedTitles(in: timeline, plan: plan)
    }
}

public enum EditorialRenderSignature {
    // JSONEncoder's generic containers otherwise keep several full Timeline
    // values on the caller's stack. A transparent reference wrapper preserves
    // exactly the same Codable payload while keeping those containers small.
    private final class Snapshot: Encodable {
        let timeline: Timeline
        init(_ timeline: Timeline) { self.timeline = timeline }
        func encode(to encoder: Encoder) throws { try timeline.encode(to: encoder) }
    }

    public static func signature(_ timeline: Timeline) -> String {
        var copy = timeline
        copy.editorialReview = nil
        copy.filmDeliveryReport = nil
        copy.editorialRegeneration = nil
        copy.editorialBeatPlan?.discardedCandidates = nil
        copy.directorRun = nil
        copy.naturalLanguageHistory = nil
        copy.versionName = nil
        copy.createdAt = Date(timeIntervalSince1970: 0)
        let aspect = Double(max(1, copy.width)) / Double(max(1, copy.height))
        copy.height = 10_000
        copy.width = Int((aspect * 10_000).rounded())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(Snapshot(copy))).map { EditorialIdentity.hash($0.base64EncodedString()) } ?? "invalid-signature"
    }
}

public enum EditorialStructuralRepair {
    public static func repair(timeline: Timeline, plan: StoryPlan, assets: [MediaAsset], analyses: [AnalysisResult], forceReplan: Bool = false) -> Timeline {
        let sanitized = EditorialIntentEnforcer.enforce(timeline, plan: plan)
        let baseline = EditorialQualityGate().review(timeline: sanitized, plan: plan, analyses: analyses)
        guard forceReplan || plan.narrativeBeatPlan != nil && !baseline.rankingEligible else { return sanitized }
        let structural: Set<EditorialFindingKind> = [.hardDuplicate, .shotFamilyRunTooLong, .dominantSetup, .lowInformationSpan, .falseNarrativeRole, .missingHook, .missingClosure, .durationPadding, .durationUnderflow, .mechanicalCadence]
        guard forceReplan || baseline.findings.contains(where: { structural.contains($0.kind) }) else { return sanitized }
        // One full replan is one bounded speculative operation. No random
        // shuffling, source extension or role-only repair is accepted.
        let context = EditorialAnalysisContext(analyses: analyses)
        var rebuiltPlan = EditorialStoryPlanner.applying(to: plan, context: context)
        rebuiltPlan.contentBudget?.durationConstraintStatus = .compromisedInsufficientContent
        var rebuilt = EditorialIntentEnforcer.enforce(TimelineComposer().compose(plan: rebuiltPlan, assets: assets, analyses: analyses), plan: rebuiltPlan)
        rebuilt = AutomaticFramingPolicy.applying(to: rebuilt, assets: assets, analyses: analyses)
        rebuilt.music = sanitized.music
        let after = EditorialQualityGate().review(timeline: rebuilt, plan: rebuiltPlan, analyses: analyses)
        let locked = sanitized.items.filter(\.locked)
        guard locked.allSatisfy({ original in rebuilt.items.contains { $0.candidateID == original.candidateID && $0.sourceStart == original.sourceStart && $0.sourceDuration == original.sourceDuration } }),
              after.criticalCount <= baseline.criticalCount, after.highCount <= baseline.highCount,
              forceReplan && after.rankingEligible || after.criticalCount < baseline.criticalCount || after.highCount < baseline.highCount || after.editorialScore > baseline.editorialScore + 0.005 else { return sanitized }
        rebuilt.editorialReview = after
        rebuilt.editorialReview?.conservativeFallback = true
        return rebuilt
    }
}
