import Foundation

public enum EditorialEvidenceDomain: String, Codable, CaseIterable, Hashable, Sendable {
    case primaryMediaPresence, renderDecode, subjectCoverage, faceSafety, bodySafety
    case foregroundOcclusion, dominantForegroundObject, shotFamilyIdentity, visualNovelty
    case actionProgression, momentCompletion, hookFulfillment, closureFulfillment, eventBridge
    case titleGrounding, titleReadability, telemetryMeaningfulness, musicNarrativeFit
    case sourceAudioPolicy, integratedLoudness, truePeak, previewExportParity
    case contentBudgetLowerBound, contentBudgetUpperBound, pendingIntentSatisfaction
}

public enum EditorialEvidenceState: String, Codable, Hashable, Sendable { case passed, failed, unknown }

/// Evidence describes observations, never a planner's confidence in its own choice.
public struct EditorialDomainEvidence: Codable, Hashable, Sendable {
    public var domain: EditorialEvidenceDomain
    public var status: EditorialEvidenceState
    public var required: Bool
    public var confidence: Double
    public var coverage: Double
    public var itemIDs: [UUID]
    public var probeTimes: [Double]
    public var provenance: [String]
    public var reason: String
    public var finding: EditorialFinding?

    public var isSufficient: Bool {
        status == .passed && confidence.isFinite && coverage.isFinite
            && confidence >= 0.7 && confidence <= 1 && coverage >= 0.95 && coverage <= 1
            && !provenance.isEmpty
    }
    public var blocksProduction: Bool { required && !isSufficient || status == .failed }
}

/// A semantic service may provide localized claims. No overall aesthetic score
/// or planner fulfillment flag is accepted as evidence. Production currently
/// leaves unsupported domains unknown when no approved reviewer is available.
public struct EditorialSemanticClaim: Codable, Hashable, Sendable {
    public var domain: EditorialEvidenceDomain
    public var status: EditorialEvidenceState
    public var itemIDs: [UUID]
    public var probeTimes: [Double]
    public var confidence: Double
    public var observation: String
    public var method: String
    public var renderSignature: String
    public var finding: EditorialFinding?
}

public struct EditorialFamilyDistribution: Codable, Hashable, Sendable {
    public var familyCount: Int
    public var maxFamilyShare: Double
    public var dominanceExcess: Double
    public var normalizedEntropy: Double
    public var effectiveFamilyCount: Double
    public var maximumRun: Double
    public var excessive: Bool

    public init(histogram: [String: Double], maximumRun: Double, atmospheric: Bool) {
        let durations = histogram.values.filter { $0.isFinite && $0 > 0 }
        let total = durations.reduce(0, +)
        let shares = total > 0 ? durations.map { $0 / total } : []
        familyCount = shares.count
        maxFamilyShare = shares.max() ?? 0
        dominanceExcess = familyCount > 0 ? max(0, maxFamilyShare - 1 / Double(familyCount)) : 0
        let entropy = -shares.reduce(0) { $0 + $1 * log($1) }
        normalizedEntropy = familyCount > 1 ? entropy / log(Double(familyCount)) : 0
        effectiveFamilyCount = familyCount > 0 ? exp(entropy) : 0
        self.maximumRun = maximumRun
        // Three equally represented families are feasible. Concentration and
        // an uninterrupted run are separate risks; neither uses a fixed 32%.
        excessive = familyCount > 1 && dominanceExcess > (atmospheric ? 0.35 : 0.20)
            && (normalizedEntropy < 0.85 || maximumRun > (atmospheric ? 20 : 12))
    }
}

/// The same risk schedule drives decoding and coverage. A truncated probe list
/// remains incomplete rather than quietly redefining the required coverage.
public enum EditorialProbeSchedule {
    public static func times(timeline: Timeline) -> [Double] {
        guard timeline.duration.isFinite, timeline.duration > 0 else { return [] }
        let step = 1 / max(15, timeline.frameRate)
        let last = max(0, timeline.duration - step)
        var requested = [min(step, last), last]
        for item in TimelineTiming.retimed(timeline.items) where item.kind != .title {
            let start = item.timelineStart, length = item.timelineDuration
            guard start.isFinite, length.isFinite, length > 0 else { continue }
            let margin = min(step, length / 4)
            requested += [start + margin, start + length / 2, start + length - margin, start - step, start + step]
            requested += stride(from: start + 2, to: start + length, by: 2).map { $0 }
            if let keyframes = item.effectiveVideoAdjustments.subjectReframe?.keyframes {
                // Invert the actual speed/reverse mapping; dividing by speed
                // alone is incorrect for speed ramps and reversed clips.
                for keyframe in keyframes where keyframe.sourceTime >= item.sourceStart && keyframe.sourceTime <= item.sourceStart + item.sourceDuration {
                    var lo = 0.0, hi = length
                    for _ in 0..<32 {
                        let mid = (lo + hi) / 2
                        let source = item.sourceTime(atTimelineTime: start + mid)
                        if (source < keyframe.sourceTime) != item.isReversed { lo = mid } else { hi = mid }
                    }
                    let time = start + (lo + hi) / 2
                    requested += [time - step, time, time + step]
                }
            }
        }
        func interval(_ start: Double, _ duration: Double) {
            guard start.isFinite, duration.isFinite, duration > 0 else { return }
            requested += [start + min(step, duration / 4), start + duration / 2, start + duration - min(step, duration / 4)]
        }
        for effect in timeline.effectiveEffects where effect.enabled { interval(effect.startTime, effect.duration) }
        for title in timeline.effectiveTitleItems where title.enabled {
            interval(title.startTime, title.duration)
            requested += TitleReadabilityInspector.times(title, frameRate: timeline.frameRate)
        }
        for telemetry in timeline.effectiveTelemetryItems { interval(telemetry.timelineStart, telemetry.timelineDuration) }
        return Array(Set(requested.filter { $0.isFinite && $0 >= 0 && $0 < timeline.duration }.map { Int(($0 * 600).rounded()) }))
            .map { min(last, Double($0) / 600) }.sorted()
    }

    public static func coverage(required: [Double], observed: [Double], tolerance: Double = 1 / 120) -> Double {
        guard !required.isEmpty else { return 0 }
        return Double(required.filter { time in observed.contains { $0.isFinite && abs($0 - time) <= tolerance } }.count) / Double(required.count)
    }
}

public enum EditorialEvidenceVerifier {
    /// Version 4 requires current per-title preview and encoded-file evidence.
    /// Older reviews remain readable but cannot silently cross this production
    /// boundary without being rendered and verified again.
    public static let version = 4

    static func verify(timeline: Timeline, plan: StoryPlan, analyses: [AnalysisResult], frames: [PerceptualRenderedFrameEvidence], findings: [EditorialFinding], units suppliedUnits: [UUID: EditorialUnit]? = nil) -> [EditorialDomainEvidence] {
        // All records belong to this immutable snapshot. Encode it once, before
        // entering nested setters/filters, instead of copying the large value
        // and JSON-encoding it again for every domain and semantic claim.
        let renderSignature = EditorialRenderSignature.signature(timeline)
        let items = timeline.items.filter { $0.overlay == nil && $0.kind != .title }.sorted { $0.timelineStart < $1.timelineStart }
        let ids = items.map(\.id)
        let schedule = EditorialProbeSchedule.times(timeline: timeline)
        let decoded = frames.filter { $0.decodeFailed == false && (!$0.isBlack || !$0.expectedVisibleContent) }
        let decodedTimes = decoded.map(\.timelineTime)
        let coverage = EditorialProbeSchedule.coverage(required: schedule, observed: decodedTimes)
        // Only subject evidence is read here. Family clustering was already
        // performed by the quality gate and must not run again for every
        // variant/probe just to look up a candidate's subjects.
        let units = suppliedUnits ?? Dictionary(uniqueKeysWithValues: analyses.flatMap(\.directorCandidates)
            .filter { !$0.excluded }.map { ($0.id, EditorialUnit(candidate: $0)) })
        let expectsPeople = items.contains { item in
            guard let unit = item.candidateID.flatMap({ units[$0] }) else { return item.kind == .video }
            return unit.evidence.samples.contains { !Set($0.subjectKinds).isDisjoint(with: [.person, .face, .cyclist]) }
                || !unit.candidate.tags.isDisjoint(with: ["person", "people", "cycling", "fishing"])
        }
        let hasTitles = timeline.effectiveTitleItems.contains(where: \.enabled)
        let audible = timeline.music?.trackID != nil || !(timeline.effectiveAdaptiveSoundtrack?.segments.isEmpty ?? true)
            || !timeline.effectiveAudioClips.isEmpty || timeline.effectiveOriginalAudioVolume > 0 && items.contains { $0.kind == .video && !$0.effectiveAudioAdjustments.muted }
        let optional: Set<EditorialEvidenceDomain> = Set((expectsPeople ? [] : [.subjectCoverage, .faceSafety, .bodySafety])
            + (hasTitles ? [] : [.titleGrounding, .titleReadability])
            + (timeline.effectiveTelemetryItems.isEmpty ? [.telemetryMeaningfulness] : [])
            + (timeline.music?.trackID == nil ? [.musicNarrativeFit] : [])
            + (audible ? [] : [.integratedLoudness, .truePeak]))
        var records = EditorialEvidenceDomain.allCases.map { domain in
            EditorialDomainEvidence(domain: domain, status: .unknown, required: !optional.contains(domain), confidence: 0, coverage: 0, itemIDs: ids, probeTimes: [], provenance: [], reason: optional.contains(domain) ? "Область не применяется к этой композиции" : "Независимое измерение отсутствует", finding: nil)
        }
        func set(_ domain: EditorialEvidenceDomain, passed: Bool, coverage: Double = 1, reason: String, kinds: [EditorialFindingKind] = []) {
            let i = records.firstIndex { $0.domain == domain }!
            records[i].status = passed ? .passed : .failed
            records[i].confidence = 1
            records[i].coverage = coverage
            records[i].provenance = ["deterministic-verifier-v\(EditorialEvidenceVerifier.version)", renderSignature]
            records[i].reason = reason
            records[i].finding = findings.first { kinds.contains($0.kind) }
            if !passed, records[i].finding == nil, let kind = kinds.first {
                records[i].finding = .init(kind: kind, severity: 2, itemIDs: ids, repair: .technical, reason: reason)
            }
        }
        set(.primaryMediaPresence, passed: !items.isEmpty, reason: "Проверено наличие основной последовательности", kinds: [.missingPrimaryVideo])
        if !frames.isEmpty {
            set(.renderDecode, passed: !frames.contains { $0.decodeFailed == true || $0.isBlack && $0.expectedVisibleContent }, coverage: coverage, reason: "Покрытие обязательных рискованных точек композиции", kinds: [.blankRenderedFrame])
        }
        if let decision = plan.contentBudget {
            let lower = EditorialContentBudgetPolicy.effectiveLowerBound(decision: decision, timeline: timeline)
            let upper = min(decision.budget.absoluteCeiling, decision.budget.safeRange.upperBound, decision.supportedDuration)
            let valid = lower.isFinite && upper.isFinite && lower >= 0 && upper >= lower && upper > 0
            let tolerance = 2 / max(1, timeline.frameRate)
            set(.contentBudgetLowerBound, passed: valid && timeline.duration + tolerance >= lower && AutomaticFilmDurationPolicy.meetsMinimum(timeline), reason: "Фактически \(AutomaticFilmDurationPolicy.renderedDuration(of: timeline)) с после переходов; минимум фильма 10 с; безопасный минимум материала \(lower) с", kinds: [.durationUnderflow])
            set(.contentBudgetUpperBound, passed: valid && timeline.duration <= upper + tolerance, reason: "Фактически \(timeline.duration) с; безопасный максимум \(upper) с", kinds: [.durationPadding])
        }
        set(.sourceAudioPolicy, passed: !findings.contains { $0.kind == .audioPolicyViolation }, reason: "Проверены embedded и detached дорожки против явного intent", kinds: [.audioPolicyViolation])
        let export = frames.compactMap(\.exportVerification).first { $0.renderSignature == renderSignature }
        if let export {
            set(.previewExportParity, passed: export.aspectRatioMatches && export.durationDifference <= 2 / max(1, timeline.frameRate) && export.probes.allSatisfy(\.passed), coverage: EditorialProbeSchedule.coverage(required: schedule, observed: export.probes.filter(\.passed).map(\.time)), reason: export.provenance, kinds: [.previewExportMismatch])
        }
        if audible, let report = export?.encodedAudio {
            let measuredCoverage = min(1, Double(report.measuredFrames) / max(1, timeline.duration * 48_000))
            if let lufs = report.outputLUFS, lufs.isFinite {
                let quietRequested = SourceAudioMixPolicy.allowsQuietDelivery(timeline: timeline, plan: plan)
                set(.integratedLoudness, passed: EditorialLoudnessPolicy.accepts(lufs: lufs, truePeak: report.outputTruePeakDBTP, allowsQuietMix: quietRequested), coverage: measuredCoverage, reason: "\(lufs) LUFS; \(quietRequested ? "сохранено запрошенное приглушение исходников" : "целевой диапазон \(EditorialLoudnessPolicy.allowedLUFS)"). \(report.peakLimited ? "Достигнут предел headroom" : "")", kinds: [.audioLoudnessViolation])
            }
            if let peak = report.outputTruePeakDBTP, peak.isFinite {
                set(.truePeak, passed: peak <= EditorialLoudnessPolicy.maximumTruePeak, coverage: measuredCoverage, reason: "\(peak) dBTP", kinds: [.audioPeakViolation])
            }
        }
        if hasTitles {
            let previewTitles = frames.flatMap { $0.titleEvidence ?? [] }
            let previewStatus = TitleReadabilityInspector.coverage(timeline: timeline, evidence: previewTitles, source: "preview")
            let deliveryStatus = TitleReadabilityInspector.coverage(timeline: timeline, evidence: export?.titleEvidence ?? [], source: "mp4")
            if !previewTitles.isEmpty && (export != nil || !previewStatus.passed) {
                set(.titleReadability, passed: previewStatus.passed && deliveryStatus.passed,
                    coverage: previewStatus.complete && deliveryStatus.complete ? 1 : 0,
                    reason: "OCR каждого титра: начало/середина/конец читаемого показа, отдельно композиция и MP4; порог 0.5",
                    kinds: [.unreadableTitle])
            }
        }

        // Localized independent semantic claims can fill only semantic domains.
        // They cannot override duration, audio, decode, CAS or parity checks.
        let semantic: Set<EditorialEvidenceDomain> = [.subjectCoverage, .faceSafety, .bodySafety, .foregroundOcclusion, .dominantForegroundObject, .shotFamilyIdentity, .visualNovelty, .actionProgression, .momentCompletion, .hookFulfillment, .closureFulfillment, .eventBridge, .titleGrounding, .telemetryMeaningfulness, .musicNarrativeFit]
        let claims = frames.flatMap { $0.editorialClaims ?? [] }
        // Visibility is independent of the evidence domain. Mapping a timeline
        // time through every transition is expensive on long montages; retain
        // the same points once and apply only the domain's item scope below.
        let visibleSchedule = claims.isEmpty ? [] : schedule.filter { time in
            FilmEndingFade.expectsVisibleContent(atTimelineTime: time, timeline: timeline)
                && !NaturalChapterTransitionPlanner.expectsCoveredSource(at: time, timeline: timeline)
        }
        for domain in semantic {
            let index = records.firstIndex { $0.domain == domain }!
            let relevant: [UUID] = domain == .hookFulfillment ? Array(ids.prefix(1)) : domain == .closureFulfillment ? Array(ids.suffix(1)) : ids
            let valid = claims.filter { claim in
                claim.domain == domain && claim.renderSignature == renderSignature
                    && claim.confidence.isFinite && (0.7...1).contains(claim.confidence)
                    && !claim.observation.isEmpty && !claim.method.isEmpty && !claim.itemIDs.isEmpty
                    && Set(claim.itemIDs).isSubset(of: Set(ids)) && Set(claim.probeTimes).count >= 2
                    && claim.probeTimes.allSatisfy { time in
                        decodedTimes.contains { abs($0 - time) < 1 / 120 }
                            && items.contains { claim.itemIDs.contains($0.id) && time >= $0.timelineStart && time < $0.timelineStart + $0.timelineDuration }
                    }
            }
            guard !valid.isEmpty else { continue }
            let times = valid.flatMap(\.probeTimes)
            let requiredTimes = visibleSchedule.filter { time in
                items.contains { relevant.contains($0.id) && time >= $0.timelineStart && time < $0.timelineStart + $0.timelineDuration }
            }
            records[index].coverage = EditorialProbeSchedule.coverage(required: requiredTimes, observed: times)
            records[index].confidence = valid.map(\.confidence).min() ?? 0
            records[index].status = valid.contains { $0.status == .failed } ? .failed : valid.allSatisfy { $0.status == .passed } ? .passed : .unknown
            records[index].probeTimes = times
            records[index].provenance = valid.map(\.method)
            records[index].reason = valid.map(\.observation).joined(separator: "; ")
            records[index].finding = valid.compactMap(\.finding).first
        }
        // Known deterministic defects always defeat a semantic pass.
        let failureDomains: [EditorialFindingKind: EditorialEvidenceDomain] = [.unsafeReframe: .bodySafety, .foregroundOcclusion: .foregroundOcclusion, .hardDuplicate: .visualNovelty, .missingHook: .hookFulfillment, .missingClosure: .closureFulfillment, .falseNarrativeRole: .actionProgression, .incompleteMoment: .momentCompletion, .meaninglessTelemetry: .telemetryMeaningfulness]
        for finding in findings where finding.severity >= 2 {
            guard let domain = failureDomains[finding.kind], let index = records.firstIndex(where: { $0.domain == domain }) else { continue }
            records[index].status = .failed
            records[index].finding = finding
            records[index].reason = finding.reason
        }
        return records
    }
}

public enum EditorialLoudnessPolicy {
    public static let targetLUFS = -16.0
    public static let allowedLUFS = -20.0 ... -12.0
    public static let maximumTruePeak = -1.0

    /// Highly dynamic material may legitimately stop at the true-peak ceiling
    /// before reaching -20 LUFS. Accept that narrow, measured exception while
    /// continuing to reject genuinely quiet mixes such as the recorded -28 LUFS
    /// regression. This is based on the encoded output, not predicted gain.
    public static func accepts(lufs: Double, truePeak: Double?, allowsQuietMix: Bool = false) -> Bool {
        guard lufs.isFinite else { return false }
        if allowedLUFS.contains(lufs) { return true }
        if allowsQuietMix && lufs < allowedLUFS.lowerBound { return true }
        guard lufs >= -24, lufs < allowedLUFS.lowerBound, let truePeak else { return false }
        return truePeak >= -1.6 && truePeak <= maximumTruePeak
    }
}
