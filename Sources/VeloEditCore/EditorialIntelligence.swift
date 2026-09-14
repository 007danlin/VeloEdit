import Foundation
import CryptoKit

// Editorial evidence is deliberately separate from highlight scores: motion,
// effects and a different source filename are not evidence of a new action.
public enum EditorialCameraMount: String, Codable, Hashable, Sendable {
    case unknown, handheld, fixed, bodyPOV, vehicleMounted, drone
}

public enum EditorialShotScale: String, Codable, Hashable, Sendable {
    case unknown, wide, medium, close, detail
}

public struct EditorialTemporalSample: Codable, Hashable, Sendable {
    public var sourceTime: Double
    public var subjectRegions: [NormalizedRegion]
    public var subjectKinds: [SubjectKind]
    public var actionState: Set<String>
    public var composition: [Double]
    public var motionEnergy: Double
    public var quality: Double
    /// Unknown is not zero. Foreground occlusion requires temporal evidence;
    /// the bounding box of a large intentional portrait is not an occluder.
    public var accidentalOcclusion: Double?
    public var confidence: Double

    public init(sourceTime: Double, subjectRegions: [NormalizedRegion] = [], subjectKinds: [SubjectKind] = [], actionState: Set<String> = [], composition: [Double] = [], motionEnergy: Double = 0, quality: Double = 0.5, accidentalOcclusion: Double? = nil, confidence: Double = 0.5) {
        self.sourceTime = sourceTime
        self.subjectRegions = subjectRegions
        self.subjectKinds = subjectKinds
        self.actionState = actionState
        self.composition = composition
        self.motionEnergy = motionEnergy.clamped01
        self.quality = quality.clamped01
        self.accidentalOcclusion = accidentalOcclusion?.clamped01
        self.confidence = confidence.clamped01
    }
}

public struct EditorialEvidence: Codable, Hashable, Sendable {
    public var analysisVersion: Int
    public var samples: [EditorialTemporalSample]
    public var usableRange: EditorialSourceRange
    public var actionDelta: Double
    public var visualDelta: Double
    public var informationGain: Double
    public var completion: Double
    public var entryQuality: Double
    public var exitQuality: Double
    public var unchangedSeconds: Double
    public var atmosphereValue: Double
    public var foregroundOcclusion: Double?
    public var intentionalReveal: Bool
    public var cameraMount: EditorialCameraMount
    public var shotScale: EditorialShotScale
    public var cameraAngle: String?
    public var background: String?
    public var confidence: Double
    public var provenance: [String]

    public init(samples: [EditorialTemporalSample] = [], usableRange: EditorialSourceRange, actionDelta: Double = 0, visualDelta: Double = 0, informationGain: Double = 0, completion: Double = 0, entryQuality: Double = 0.5, exitQuality: Double = 0.5, unchangedSeconds: Double = 0, atmosphereValue: Double = 0, foregroundOcclusion: Double? = nil, intentionalReveal: Bool = false, cameraMount: EditorialCameraMount = .unknown, shotScale: EditorialShotScale = .unknown, cameraAngle: String? = nil, background: String? = nil, confidence: Double = 0, provenance: [String] = []) {
        analysisVersion = EditorialEvidenceCache.version
        self.samples = samples.sorted { $0.sourceTime < $1.sourceTime }
        self.usableRange = usableRange
        self.actionDelta = actionDelta.clamped01
        self.visualDelta = visualDelta.clamped01
        self.informationGain = informationGain.clamped01
        self.completion = completion.clamped01
        self.entryQuality = entryQuality.clamped01
        self.exitQuality = exitQuality.clamped01
        self.unchangedSeconds = max(0, unchangedSeconds)
        self.atmosphereValue = atmosphereValue.clamped01
        self.foregroundOcclusion = foregroundOcclusion?.clamped01
        self.intentionalReveal = intentionalReveal
        self.cameraMount = cameraMount
        self.shotScale = shotScale
        self.cameraAngle = cameraAngle
        self.background = background
        self.confidence = confidence.clamped01
        self.provenance = provenance
    }

    public var hasProgression: Bool { confidence >= 0.55 && actionDelta >= 0.18 }
    public var hasHardOcclusion: Bool { (foregroundOcclusion ?? 0) > 0.28 && !intentionalReveal }
}

public struct EditorialUnit: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID { candidate.id }
    public var candidate: Candidate
    public var eventID: UUID?
    public var sceneID: UUID?
    public var semanticEventID: String?
    public var shotFamilyID: String?
    public var discardReason: EditorialDiscardReason? = nil
    public var evidence: EditorialEvidence
    public var sourceRange: EditorialSourceRange { .init(start: candidate.sourceStart, end: candidate.sourceStart + candidate.sourceDuration) }

    public init(candidate: Candidate, eventID: UUID? = nil, sceneID: UUID? = nil) {
        self.candidate = candidate
        self.eventID = eventID
        self.sceneID = sceneID
        semanticEventID = candidate.insights?.semanticEventID
        evidence = candidate.insights?.editorialEvidence ?? EditorialEvidence(
            usableRange: .init(start: candidate.sourceStart, end: candidate.sourceStart + candidate.sourceDuration),
            entryQuality: candidate.scores.quality,
            exitQuality: candidate.scores.quality,
            confidence: 0.15,
            provenance: ["legacy: temporal evidence unavailable; conservative duration"]
        )
    }

    public var quality: Double { candidate.insights?.bestTakeScore ?? candidate.scores.composite }
    public var speechSeconds: Double {
        guard let speech = candidate.insights?.speech, speech.confidence >= 0.65 else { return 0 }
        return max(0, min(sourceRange.end, speech.phraseEnd) - max(sourceRange.start, speech.phraseStart))
    }
    public var usableDuration: Double {
        let range = max(0, min(sourceRange.end, evidence.usableRange.end) - max(sourceRange.start, evidence.usableRange.start))
        guard discardReason == nil, !evidence.hasHardOcclusion, quality >= 0.38 else { return 0 }
        if speechSeconds > 0 { return min(range, speechSeconds) }
        if evidence.hasProgression { return evidence.completion >= 0.65 && evidence.unchangedSeconds <= 15 ? range : min(range, 15) }
        if evidence.atmosphereValue >= 0.65 && evidence.confidence >= 0.55 { return min(range, 12) }
        // A good still composition supports a short observation, not the
        // remaining minutes of the camera recording.
        return min(range, 2.5 + quality * 3.5)
    }

    public func preferredDuration(pacing: Double) -> Double {
        if candidate.tags.contains("photo") { return min(usableDuration, PhotoPresentationPolicy.duration) }
        if speechSeconds > 0 { return usableDuration }
        if evidence.hasProgression && evidence.completion >= 0.65 { return usableDuration }
        let base = evidence.atmosphereValue >= 0.65 ? 4.2 : evidence.actionDelta >= 0.18 ? 1.6 : 2.5
        return min(usableDuration, max(1.2, base + 1.7 * evidence.informationGain + 1.3 * quality - pacing * 0.7))
    }
}

public struct ShotFamily: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var unitIDs: [UUID]
    public var representativeID: UUID
}

public struct ShotFamilyIndex: Codable, Hashable, Sendable {
    public static let version = 2
    public var families: [ShotFamily]
    public var familyByUnitID: [UUID: String]
    public init(families: [ShotFamily] = []) {
        self.families = families
        familyByUnitID = Dictionary(uniqueKeysWithValues: families.flatMap { family in family.unitIDs.map { ($0, family.id) } })
    }
}

public struct EditorialPairSimilarity: Hashable, Sendable {
    public var sourceOverlap: Double
    public var semanticSimilarity: Double
    public var compositionSimilarity: Double
    public var subjectStateSimilarity: Double
    public var cameraSetupSimilarity: Double
    public var actionSimilarity: Double
    public var backgroundSimilarity: Double
    public var temporalProximity: Double
    public var combined: Double
}

public enum EditorialPairRelation: String, Codable, Hashable, Sendable {
    case hardDuplicate, sameSetup, sameActionState, relatedScene, distinctEditorialUnit, unknown
}

public protocol ShotFamilyClustering: Sendable {
    func cluster(units: [EditorialUnit]) -> ShotFamilyIndex
}

public struct ShotFamilyClusterer: ShotFamilyClustering {
    public init() {}

    public func relation(_ a: EditorialUnit, _ b: EditorialUnit) -> EditorialPairRelation {
        if isHardDuplicate(a, b, adjacent: false) { return .hardDuplicate }
        let pair = similarity(a, b)
        if pair.combined >= 0.78 { return addsState(b, after: a) ? .relatedScene : .sameSetup }
        if addsState(b, after: a), min(a.evidence.confidence, b.evidence.confidence) >= 0.55 { return .distinctEditorialUnit }
        if pair.actionSimilarity >= 0.9 && pair.compositionSimilarity >= 0.85 { return .sameActionState }
        if pair.semanticSimilarity >= 0.5 { return .relatedScene }
        // Unknown metadata and filenames alone cannot prove novelty.
        guard !a.evidence.samples.isEmpty, !b.evidence.samples.isEmpty,
              a.candidate.insights?.visualEmbedding != nil, b.candidate.insights?.visualEmbedding != nil else { return .unknown }
        return pair.compositionSimilarity < 0.65 ? .distinctEditorialUnit : .relatedScene
    }

    public func similarity(_ a: EditorialUnit, _ b: EditorialUnit) -> EditorialPairSimilarity {
        let sameSource = a.candidate.assetID == b.candidate.assetID
        let overlap = sameSource ? max(0, min(a.sourceRange.end, b.sourceRange.end) - max(a.sourceRange.start, b.sourceRange.start)) / max(0.05, min(a.sourceRange.duration, b.sourceRange.duration)) : 0
        func tokens(_ unit: EditorialUnit) -> Set<String> {
            let summary = unit.candidate.insights?.sceneSummary ?? ""
            let technical: Set<String> = ["4k", "1080p", "720p", "horizontal", "vertical", "landscape", "portrait", "hdr", "sdr", "video", "photo", "high-fps", "60fps", "120fps", "stable", "sharp"]
            return Set(summary.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)).union(unit.candidate.tags).subtracting(technical)
        }
        let aa = tokens(a), bb = tokens(b)
        let semantic = aa.isEmpty || bb.isEmpty ? 0 : Double(aa.intersection(bb).count) / Double(aa.union(bb).count)
        let av = a.candidate.insights?.visualEmbedding?.values ?? []
        let bv = b.candidate.insights?.visualEmbedding?.values ?? []
        var embedding: Double
        if !av.isEmpty, av.count == bv.count {
            let dot = zip(av, bv).reduce(0.0) { $0 + Double($1.0) * Double($1.1) }
            let norm = sqrt(av.reduce(0.0) { $0 + Double($1) * Double($1) } * bv.reduce(0.0) { $0 + Double($1) * Double($1) })
            embedding = norm > 0 ? (dot / norm).clamped01 : semantic
        } else { embedding = semantic }
        // Compare several temporal compositions rather than a single thumbnail.
        // Histogram agreement reinforces measured similarity; it never proves
        // that two semantically different shots are interchangeable on its own.
        let aSamples = a.evidence.samples.filter { $0.composition.count >= 16 }
        let bSamples = b.evidence.samples.filter { $0.composition.count >= 16 }
        // Histogram agreement cannot affect semantically unrelated shots.
        // Avoid the quadratic temporal comparison when its result is unused.
        if semantic >= 0.5, aSamples.count >= 3, bSamples.count >= 3 {
            let pairs = aSamples.compactMap { sample -> Double? in
                let distances = bSamples.filter { $0.composition.count == sample.composition.count }.map { other in
                    min(1, zip(sample.composition, other.composition).reduce(0) { $0 + abs($1.0 - $1.1) } / 2)
                }.sorted()
                return distances.isEmpty ? nil : 1 - distances[distances.count / 2]
            }
            if !pairs.isEmpty, semantic >= 0.5 {
                embedding = 0.7 * embedding + 0.3 * pairs.reduce(0, +) / Double(pairs.count)
            }
        }
        let ak = Set(a.evidence.samples.flatMap(\.subjectKinds)), bk = Set(b.evidence.samples.flatMap(\.subjectKinds))
        let subjects = ak.isEmpty || bk.isEmpty ? semantic : Double(ak.intersection(bk).count) / Double(max(1, ak.union(bk).count))
        let statesA = a.evidence.samples.last?.actionState ?? [], statesB = b.evidence.samples.last?.actionState ?? []
        let action = statesA.isEmpty || statesB.isEmpty ? semantic : Double(statesA.intersection(statesB).count) / Double(max(1, statesA.union(statesB).count))
        let scale = a.evidence.shotScale == .unknown || b.evidence.shotScale == .unknown ? semantic : a.evidence.shotScale == b.evidence.shotScale ? 1.0 : 0.0
        let mount = a.evidence.cameraMount == .unknown || b.evidence.cameraMount == .unknown ? semantic : a.evidence.cameraMount == b.evidence.cameraMount ? 1.0 : 0.0
        let background = a.evidence.background == nil || b.evidence.background == nil ? embedding : a.evidence.background == b.evidence.background ? 1.0 : 0.0
        let proximity = sameSource ? max(0, 1 - abs(a.sourceRange.start - b.sourceRange.start) / 90) : 0
        let combined = max(overlap, embedding * 0.35 + semantic * 0.15 + subjects * 0.10 + action * 0.15 + scale * 0.10 + mount * 0.08 + background * 0.07)
        return .init(sourceOverlap: overlap, semanticSimilarity: semantic, compositionSimilarity: embedding, subjectStateSimilarity: subjects, cameraSetupSimilarity: (scale + mount) / 2, actionSimilarity: action, backgroundSimilarity: background, temporalProximity: proximity, combined: combined)
    }

    public func isHardDuplicate(_ a: EditorialUnit, _ b: EditorialUnit, adjacent: Bool = true, frameRate: Double = 30) -> Bool {
        if a.candidate.assetID == b.candidate.assetID {
            if abs(a.sourceRange.start - b.sourceRange.start) <= 2 / max(1, frameRate) { return true }
            let overlap = max(0, min(a.sourceRange.end, b.sourceRange.end) - max(a.sourceRange.start, b.sourceRange.start)) / max(0.05, min(a.sourceRange.duration, b.sourceRange.duration))
            if overlap >= (adjacent ? 0.18 : 0.90) { return true }
        }
        // Most measured shots already add information. Their visual vectors
        // cannot make this predicate true, so avoid recomputing every temporal
        // histogram pair during every iteration of the sequence search.
        guard b.evidence.informationGain < 0.12, !addsState(b, after: a) else { return false }
        return similarity(a, b).combined >= 0.92
    }

    public func addsState(_ b: EditorialUnit, after a: EditorialUnit) -> Bool {
        if a.evidence.shotScale != .unknown, b.evidence.shotScale != .unknown, a.evidence.shotScale != b.evidence.shotScale { return true }
        let from = a.evidence.samples.last?.actionState ?? []
        let to = b.evidence.samples.last?.actionState ?? []
        return b.evidence.hasProgression && (!to.subtracting(from).isEmpty || b.evidence.completion > a.evidence.completion + 0.18)
    }

    private final class FamilyCacheEntry: NSObject {
        let units: [EditorialUnit]
        let index: ShotFamilyIndex
        init(units: [EditorialUnit], index: ShotFamilyIndex) { self.units = units; self.index = index }
    }
    private static let familyCache: NSCache<NSNumber, FamilyCacheEntry> = {
        let cache = NSCache<NSNumber, FamilyCacheEntry>()
        cache.countLimit = 3
        cache.totalCostLimit = 64 * 1_024 * 1_024
        return cache
    }()

    public func cluster(units: [EditorialUnit]) -> ShotFamilyIndex {
        // Variant review repeatedly clusters the exact same immutable evidence.
        // Hashes locate an entry; full value equality prevents stale results or
        // hash collisions from changing any editorial decision.
        var hasher = Hasher()
        hasher.combine(units)
        let key = NSNumber(value: hasher.finalize())
        if let cached = Self.familyCache.object(forKey: key), cached.units == units { return cached.index }
        var groups: [[EditorialUnit]] = []
        for unit in units.sorted(by: { $0.quality == $1.quality ? $0.id.uuidString < $1.id.uuidString : $0.quality > $1.quality }) {
            // Complete-link avoids a transitive chain merging unrelated setups.
            if let index = groups.firstIndex(where: { $0.allSatisfy { similarity($0, unit).combined >= 0.78 } }) {
                groups[index].append(unit)
            } else { groups.append([unit]) }
        }
        let result = ShotFamilyIndex(families: groups.map { group in
            let ids = group.map(\.id).sorted { $0.uuidString < $1.uuidString }
            return ShotFamily(id: "family-" + EditorialIdentity.hash(ids.map(\.uuidString).joined(separator: "|")), unitIDs: ids, representativeID: group[0].id)
        })
        let cost = units.reduce(0) { $0 + 2_048 + $1.evidence.samples.reduce(0) { $0 + 128 + $1.composition.count * 8 } }
        Self.familyCache.setObject(FamilyCacheEntry(units: units, index: result), forKey: key, cost: cost)
        return result
    }
}

public enum EditorialLimitingFactor: String, Codable, Hashable, Sendable {
    case repeatedSetup, weakEvidence, insufficientAction, unsafeComposition, insufficientContent, atmosphereBudget
}

public struct ContentBudget: Codable, Hashable, Sendable {
    public var idealDuration: Double
    public var safeRange: ClosedRange<Double>
    public var absoluteCeiling: Double
    public var strongUnitCount: Int
    public var distinctEventCount: Int
    public var distinctSceneCount: Int
    public var distinctShotFamilyCount: Int
    public var usableActionSeconds: Double
    public var usableAtmosphereSeconds: Double
    public var usableSpeechSeconds: Double
    public var confidence: Double
    public var limitingFactors: [EditorialLimitingFactor]
}

public enum DurationConstraintStatus: String, Codable, Hashable, Sendable {
    case satisfied, expandedSearchSatisfied, compromisedInsufficientContent, failedTechnical
}

public struct ContentBudgetDecision: Codable, Hashable, Sendable {
    public var budget: ContentBudget
    public var requestedDuration: Double?
    public var supportedDuration: Double
    public var committedDuration: Double?
    public var durationConstraintStatus: DurationConstraintStatus
    public var requiresExpandedMining: Bool
    public var feasibility: Double
    public var reason: String
}

public protocol ContentBudgeting: Sendable {
    func budget(units: [EditorialUnit], families: ShotFamilyIndex, requestedDuration: Double?, requestIsExplicit: Bool, style: DirectorStyleVector) -> ContentBudgetDecision
}

public struct ContentBudgetEngine: ContentBudgeting {
    public init() {}
    public func budget(units: [EditorialUnit], families: ShotFamilyIndex, requestedDuration: Double?, requestIsExplicit: Bool, style: DirectorStyleVector) -> ContentBudgetDecision {
        let byID = Dictionary(uniqueKeysWithValues: units.map { ($0.id, $0) })
        let requested = requestIsExplicit ? requestedDuration.flatMap {
            $0.isFinite && $0 > 0 ? AutomaticFilmDurationPolicy.normalizedRequest($0) : nil
        } : nil
        var accepted: [EditorialUnit] = []
        var action = 0.0, atmosphere = 0.0, speech = 0.0
        let clusterer = ShotFamilyClusterer()
        for family in families.families {
            let ranked = family.unitIDs.compactMap { byID[$0] }.filter { $0.usableDuration >= 0.5 }.sorted { $0.quality == $1.quality ? $0.id.uuidString < $1.id.uuidString : $0.quality > $1.quality }
            var retained: [EditorialUnit] = []
            for unit in ranked {
                let hardRepeat = accepted.first { clusterer.isHardDuplicate($0, unit, adjacent: false) }
                let measuredNovelContinuation = requested != nil && unit.evidence.informationGain >= 0.18 && accepted.allSatisfy {
                    $0.candidate.assetID != unit.candidate.assetID || clusterer.similarity($0, unit).sourceOverlap < 0.18
                }
                guard hardRepeat == nil || measuredNovelContinuation else { continue }
                let progresses = retained.contains { clusterer.addsState(unit, after: $0) || clusterer.addsState($0, after: unit) }
                let changesScope = retained.contains {
                    (unit.sceneID != nil && $0.sceneID != nil && unit.sceneID != $0.sceneID) ||
                    (unit.eventID != nil && $0.eventID != nil && unit.eventID != $0.eventID)
                }
                let visuallyInformative = unit.evidence.informationGain >= 0.18 && retained.allSatisfy {
                    clusterer.similarity($0, unit).combined < 0.90
                }
                let temporallyNovel = requested != nil && unit.evidence.informationGain >= 0.18 && retained.allSatisfy {
                    $0.candidate.assetID != unit.candidate.assetID || clusterer.similarity($0, unit).sourceOverlap < 0.18
                }
                // A long journey can legitimately remain on one camera mount:
                // new places and observable visual change still add story.
                // Truly repeated setup fixtures remain rejected by the hard
                // duplicate and <0.90 novelty requirements above.
                guard retained.isEmpty || progresses || changesScope || visuallyInformative || temporallyNovel else { continue }
                let coefficient = retained.isEmpty || progresses ? 1.0 : changesScope ? 0.85 : 0.70
                let duration = unit.usableDuration * coefficient
                if unit.speechSeconds > 0 { speech += duration }
                else if unit.evidence.atmosphereValue >= 0.65 && !unit.evidence.hasProgression { atmosphere += duration }
                else { action += duration }
                retained.append(unit)
                accepted.append(unit)
            }
        }
        // Pacing preferences constrain the automatic recommendation, not the
        // physical capacity of an explicit request. These ranges already
        // passed novelty/quality checks; one action shot must not suddenly
        // erase most of a measured observational journey.
        let ceiling = action + atmosphere + speech
        let recommendedAtmosphere = requested == nil && action + speech > 0
            ? min(atmosphere, (action + speech) * 0.25) : atmosphere
        let recommendedCapacity = action + recommendedAtmosphere + speech
        let preferred = min(recommendedCapacity, accepted.reduce(0) { $0 + $1.preferredDuration(pacing: style.pacing) })
        let ideal = min(ceiling, max(AutomaticFilmDurationPolicy.minimumDuration, preferred))
        let feasibility = requested.map { ceiling / $0 }
            ?? min(1, ceiling / AutomaticFilmDurationPolicy.minimumDuration)
        var limiting: [EditorialLimitingFactor] = []
        if accepted.count < units.count { limiting.append(.repeatedSetup) }
        if units.contains(where: { $0.evidence.confidence < 0.55 }) { limiting.append(.weakEvidence) }
        if units.contains(where: { $0.evidence.hasHardOcclusion }) { limiting.append(.unsafeComposition) }
        if feasibility < 1 { limiting.append(.insufficientContent) }
        // Keep an insufficient ceiling honest; delivery independently refuses
        // films below the product minimum instead of padding weak material.
        let lower = min(ceiling, max(AutomaticFilmDurationPolicy.minimumDuration, min(ideal * 0.8, requested ?? ideal)))
        let budget = ContentBudget(idealDuration: ideal, safeRange: lower...ceiling, absoluteCeiling: ceiling, strongUnitCount: accepted.count, distinctEventCount: Set(accepted.compactMap(\.eventID)).count, distinctSceneCount: Set(accepted.compactMap(\.sceneID)).count, distinctShotFamilyCount: families.families.count, usableActionSeconds: action, usableAtmosphereSeconds: atmosphere, usableSpeechSeconds: speech, confidence: accepted.isEmpty ? 0 : accepted.reduce(0) { $0 + $1.evidence.confidence } / Double(accepted.count), limitingFactors: limiting)
        let target = requested.map { min($0, ceiling) } ?? ideal
        return ContentBudgetDecision(budget: budget, requestedDuration: requested, supportedDuration: ceiling, durationConstraintStatus: feasibility + 0.000_001 >= 1 ? .satisfied : .compromisedInsufficientContent, requiresExpandedMining: feasibility < 1, feasibility: feasibility, reason: "\(requested.map { "Запрошено \(Int($0.rounded())) с; " } ?? "")поддерживается \(Int(ceiling.rounded())) с: \(accepted.count) сильных моментов, \(families.families.count) разных camera setups. Цель \(Int(target.rounded())) с; минимум фильма — 10 с; расширение пустых диапазонов запрещено.")
    }
}

enum EditorialIdentity {
    static func uuid(_ value: String) -> UUID {
        let bytes = Array(SHA256.hash(data: Data(value.utf8)).prefix(16))
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], (bytes[6] & 15) | 80, bytes[7], (bytes[8] & 63) | 128, bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
    static func hash(_ value: String) -> String { SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined() }
}

public struct EditorialAnalysisContext: Sendable {
    public var expandedMiningPerformed: Bool
    public var units: [EditorialUnit]
    public var families: ShotFamilyIndex
    public init(analyses: [AnalysisResult], events: [Event] = []) {
        expandedMiningPerformed = !analyses.isEmpty && analyses.allSatisfy { $0.warnings.contains(EditorialCandidateMiner.completionMarker) }
        let scopes = events.reduce(into: [UUID: (UUID, UUID)]()) { result, event in
            for scene in event.effectiveScenes { for id in scene.candidateIDs { result[id] = (event.id, scene.id) } }
        }
        units = analyses.flatMap(\.directorCandidates).filter { !$0.excluded }.map { candidate in
            EditorialUnit(candidate: candidate, eventID: scopes[candidate.id]?.0, sceneID: scopes[candidate.id]?.1)
        }
        // An imported document is evaluated, not automatically inserted as a
        // visually novel ending to unrelated outdoor footage. Maps/navigation,
        // music/performance coverage and locked material retain their context.
        let outdoor: Set<String> = ["outdoor", "cycling", "fishing", "hiking", "river", "forest"]
        let documents: Set<String> = ["document", "printed_page", "sheet_music"]
        let related: Set<String> = ["music", "musician", "concert", "performance", "lecture", "education", "presentation"]
        let nonDocuments = units.filter { $0.candidate.tags.isDisjoint(with: documents) }
        let outdoorCount = nonDocuments.filter { !$0.candidate.tags.isDisjoint(with: outdoor) }.count
        if nonDocuments.count >= 2, Double(outdoorCount) / Double(nonDocuments.count) >= 0.6,
           nonDocuments.allSatisfy({ $0.candidate.tags.isDisjoint(with: related) }) {
            for index in units.indices where !units[index].candidate.locked {
                let tags = units[index].candidate.tags
                if !tags.isDisjoint(with: documents), tags.isDisjoint(with: ["map", "route", "navigation", "person", "people"]) {
                    units[index].discardReason = .noNarrativeFit
                }
            }
        }
        families = ShotFamilyClusterer().cluster(units: units)
        for index in units.indices { units[index].shotFamilyID = families.familyByUnitID[units[index].id] }
    }
}
