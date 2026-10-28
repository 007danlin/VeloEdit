import Foundation
import CryptoKit

public enum ShotContentStatus: String, Codable, Hashable, Sendable {
    case usable, obstructed, unmotivated, uncertain
}

/// Content observations belong to an exact delivered interval, never its whole
/// parent scene. They are review metadata and cannot change the render hash.
public struct ShotContentAssessment: Codable, Hashable, Sendable {
    public var itemID: UUID
    public var assetID: UUID
    public var sourceContentHash: String
    public var sourceStart: Double
    public var sourceDuration: Double
    public var sampleTimes: [Double]
    public var phase: String
    public var model: String
    public var cacheKey: String
    public var status: ShotContentStatus
    public var confidence: Double
    public var obstructedSamples: [Int]
    public var observation: String
    public var activity: String
    public var editorialPurpose: String? = nil
    public var irrelevantSamples: [Int]? = nil
    public var interruptedScenery: Bool? = nil
    public var cameraAdjustmentSamples: [Int]? = nil
    public var unmotivatedEnding: Bool? = nil
    public var unmotivatedBeginning: Bool? = nil
    public var confirmedBoundaryRotationSamples: [Int]? = nil
    public var actionBoundary: DiscreteActionBoundary? = nil

    var requiresConcreteRepair: Bool {
        confidence >= 0.8 && ((status == .obstructed && rejectsRange) || actionBoundary?.rejectsCut == true)
    }

    func certifies(item: TimelineItem, phase expectedPhase: String, assets: [MediaAsset]) -> Bool {
        itemID == item.id && assetID == item.assetID && phase == expectedPhase
            && (assets.isEmpty || assets.contains { $0.id == item.assetID && $0.contentHash == sourceContentHash })
            && abs(sourceStart - item.sourceStart) < 0.000_001
            && abs(sourceDuration - item.sourceDuration) < 0.000_001
            && sampleTimes.count >= 5 && status == .usable && confidence >= 0.75
            && editorialPurpose.flatMap(SelectedContentReviewer.EditorialPurpose.init(rawValue:))?.isUseful == true
            && (expectedPhase != "source" || actionBoundary?.passes == true)
    }

    var rejectsRange: Bool {
        (status == .obstructed && confidence >= 0.7
            && (obstructedSamples.count >= 2 || !(cameraAdjustmentSamples ?? []).isEmpty
                || !(confirmedBoundaryRotationSamples ?? []).isEmpty))
            || (status == .unmotivated && confidence >= 0.75
                && ((irrelevantSamples?.count ?? 0) >= 3 || interruptedScenery == true && (irrelevantSamples?.count ?? 0) >= 2
                    || unmotivatedEnding == true && irrelevantSamples?.contains(4) == true
                    || unmotivatedBeginning == true && irrelevantSamples?.contains(0) == true && irrelevantSamples?.contains(1) == true
                    || actionBoundary?.rejectsCut == true))
    }
}

public struct SelectedContentReviewReport: Codable, Hashable, Sendable {
    public var renderSignature: String
    public var source: [ShotContentAssessment]
    public var rendered: [ShotContentAssessment]

    public func passes(timeline: Timeline, assets: [MediaAsset] = []) -> Bool {
        guard renderSignature == EditorialRenderSignature.signature(timeline) else { return false }
        let items = timeline.items.filter { OriginalMediaType.isVideo($0, assets: assets) }
        return !items.isEmpty && items.allSatisfy { item in
            [("source", source), ("mp4", rendered)].allSatisfy { phase, observations in
                observations.contains { assessment in
                    assessment.certifies(item: item, phase: phase, assets: assets)
                }
            }
        }
    }
}

/// Awaited by film creation before publishing the finished Timeline.
public protocol SelectedContentReviewing: Sendable {
    func review(timeline: Timeline, assets: [MediaAsset], renderedURL: URL?,
                progress: FilmBuildProgressHandler?, pass: Int, reason: String?) async throws -> [ShotContentAssessment]
}

/// Refresh observations after structural/duration repairs and before titles
/// consume them. This is an in-job ordering guard, not a persistent cache or a
/// certificate: the mandatory reviewer has already validated the frozen model,
/// rules and images earlier in the job. An unchanged negative result stays
/// negative; the rendered MP4 still requires its separate complete review.
enum SelectedSourceEvidenceRefresh {
    static func reviewIfChanged(timeline: Timeline, assets: [MediaAsset],
        observations: [ShotContentAssessment], reviewer: any SelectedContentReviewing,
        progress: FilmBuildProgressHandler?, pass: Int) async throws -> [ShotContentAssessment] {
        let videos = timeline.items.filter { OriginalMediaType.isVideo($0, assets: assets) }
        let current = videos.allSatisfy { item in
            observations.contains { review in
                review.itemID == item.id && review.assetID == item.assetID && review.phase == "source"
                    && assets.contains { $0.id == item.assetID && $0.contentHash == review.sourceContentHash }
                    && abs(review.sourceStart - item.sourceStart) < 0.000_001
                    && abs(review.sourceDuration - item.sourceDuration) < 0.000_001
                    && review.sampleTimes.count >= 5
            }
        }
        guard !current else { return observations }
        PerformanceTrace.current?.event("review.source-inputs-changed-before-titles")
        return try await reviewer.review(timeline: timeline, assets: assets, renderedURL: nil,
            progress: progress, pass: pass,
            reason: "Проверяю изменённые фрагменты перед титрами и экспортом")
    }
}

/// A bounded second look at the selected footage. It does not replace the
/// existing analysis/ranker, force an effect, or run a new source-wide scan.
struct SelectedContentReviewer: SelectedContentReviewing {
    static let version = "selected-content-v80-preserve-physical-cover"
    // Aggregation changed, but the independent questions, their validators,
    // weights and exact images did not. Recompute the verdict from preserved
    // raw evidence; never inherit a certificate produced by the old rules.
    static let observationVersion = "selected-content-v72-probability-scale-recovery"
    struct Answer: Codable {
        var status: ShotContentStatus
        var confidence: Double
        var obstructedSamples: [Int]
        var observation: String
        var activity: String
        var editorialPurpose: String? = nil
        var irrelevantSamples: [Int]? = nil
        var interruptedScenery: Bool? = nil
        var cameraAdjustmentSamples: [Int]? = nil
        var unmotivatedEnding: Bool? = nil
        var unmotivatedBeginning: Bool? = nil
        var confirmedBoundaryRotationSamples: [Int]? = nil
        var actionBoundary: DiscreteActionBoundary? = nil
    }
    enum FrameContent: String, Codable { case event, landscape, lensCover = "lens-cover", cameraHandling = "camera-handling", uncertain }
    enum HandlingEvidence: String, Codable { case none, invertedScene = "inverted-scene", directLensContact = "direct-lens-contact" }
    struct FrameVerdict: Codable {
        var index: Int
        var content: FrameContent
        var confidence: Double
        var obstructionFraction: Double = 0
        var handlingEvidence: HandlingEvidence = .none
        // Set only by the independent interaction observer, never by the
        // contact-sheet classifier or the purpose classifier.
        var cameraAdjustmentConfirmed: Bool? = nil
        // Agreement of primary technical and neutral orientation observations.
        var rotationConfirmed: Bool? = nil
        // Missing or contradictory gravity references cannot erase a physical
        // lens-cover observation. They still forbid certifying a clear shot.
        var orientationUnresolved: Bool? = nil
    }
    struct FrameAnswer: Codable {
        var frames: [FrameVerdict]
        var observation: String
        var activity: String
    }

    enum SceneOrientation: String, Codable { case upright, sideways, inverted, unclear }
    enum OrientationBasis: String, Codable { case worldReference = "world-reference", overheadDetail = "overhead-detail", uncertain }
    enum EditorialPurpose: String, Codable {
        case action, reaction, portrait, detail, establishing, none, unclear
        var isUseful: Bool { self != .none && self != .unclear }
    }
    struct OrientationFrame: Codable {
        var index: Int
        var scene: String
        var orientation: SceneOrientation
        var opaqueCoverFraction: Double
        var orientationBasis: OrientationBasis? = nil
        var purpose: EditorialPurpose? = nil
        var purposeConfidence: Double? = nil
        var purposeEvidence: String? = nil
    }
    struct OrientationAnswer: Codable { var frames: [OrientationFrame] }
    enum CameraInteraction: String, Codable { case cameraAdjustment = "camera-adjustment", equipmentWork = "equipment-work", socialGesture = "social-gesture", none, unclear }
    struct CameraInteractionFrame: Codable {
        var index: Int
        var interaction: CameraInteraction
        var confidence: Double
        var evidence: String
    }
    enum HandTarget: String, Codable {
        case filmedObject = "filmed-object", filmingLens = "filming-lens"
        case socialGesture = "social-gesture", none, unknown
    }
    struct HandTargetObservation: Codable {
        var observation: String
        var target: HandTarget
        var confidence: Double
    }
    static func corroboratingCameraClaim(_ claim: CameraInteractionFrame,
                                         with target: HandTargetObservation) -> CameraInteractionFrame? {
        guard claim.interaction == .cameraAdjustment,
              target.confidence.isFinite, (0.85...1).contains(target.confidence),
              target.observation.split(whereSeparator: \.isWhitespace).count >= 6 else { return nil }
        let interaction: CameraInteraction
        switch target.target {
        case .filmingLens: interaction = .cameraAdjustment
        case .filmedObject: interaction = .equipmentWork
        case .socialGesture: interaction = .socialGesture
        case .none: interaction = .none
        case .unknown: return nil
        }
        return CameraInteractionFrame(index: claim.index, interaction: interaction,
            confidence: min(claim.confidence, target.confidence), evidence: target.observation)
    }
    static func retainingCameraTargetUncertainty(_ claim: CameraInteractionFrame,
                                                 target: HandTargetObservation) -> CameraInteractionFrame? {
        guard claim.interaction == .cameraAdjustment,
              claim.confidence.isFinite, (0...1).contains(claim.confidence),
              target.confidence.isFinite, (0...1).contains(target.confidence),
              target.observation.split(whereSeparator: \.isWhitespace).count >= 6 else { return nil }
        if let corroborated = corroboratingCameraClaim(claim, with: target) { return corroborated }
        // A valid but unresolved physical target is evidence of uncertainty,
        // not malformed JSON. Keep collecting every remaining observation.
        // This cannot certify a clear shot or confirm a lens-contact rejection.
        return CameraInteractionFrame(index: claim.index, interaction: .unclear,
            confidence: min(claim.confidence, target.confidence),
            evidence: "Camera observer: \(claim.evidence) Target observer: \(target.observation)")
    }
    static func literalInteractionEvidence(_ frame: CameraInteractionFrame) -> Bool {
        let evidence = frame.evidence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard evidence.split(whereSeparator: { !$0.isLetter }).count >= 3 else { return false }
        // A real steering frame returned camera-adjustment with the entire
        // evidence field set to "equipment-work". An enum label, even with
        // high confidence, is not an independent observation of contact.
        let compact = evidence.lowercased().filter(\.isLetter)
        return !["cameraadjustment", "equipmentwork", "socialgesture", "none", "unclear"].contains(compact)
    }

    static func applyingInteractionCertainty(_ contacts: [CameraInteractionFrame], to original: Answer,
                                             intentionalFadeSamples: [Int] = []) -> Answer? {
        let required = Set(0..<5).subtracting(intentionalFadeSamples)
        guard Set(contacts.map(\.index)) == required, contacts.count == required.count,
              contacts.allSatisfy({ $0.confidence.isFinite && (0...1).contains($0.confidence)
                  && literalInteractionEvidence($0) }) else { return nil }
        var answer = original
        // The independent observer is mandatory even when the primary never
        // claims camera handling. An uncertain "none" cannot silently pass
        // just because the corroboration branch was not entered.
        if original.status == .usable, contacts.contains(where: {
            $0.interaction == .unclear || $0.confidence < 0.75
                || $0.interaction == .cameraAdjustment && $0.confidence < 0.9
        }) {
            answer.status = .uncertain
            answer.confidence = min(answer.confidence, contacts.map(\.confidence).min() ?? 0)
        }
        return answer
    }
    /// Technical readability is insufficient. A random patch of ground and a
    /// cropped coat can be sharp and upright without contributing anything.
    /// Require observed editorial content across the actual selected interval,
    /// without equating beauty with faces or rejecting purposeful equipment POV.
    static func applyingPurpose(_ observer: OrientationAnswer, to technical: Answer,
                                intentionalFadeSamples: [Int] = []) -> Answer? {
        guard observer.frames.count == 5, Set(observer.frames.map(\.index)) == Set(0..<5),
              observer.frames.allSatisfy({ frame in
                  guard frame.purpose != nil, let confidence = frame.purposeConfidence,
                        let evidence = frame.purposeEvidence else { return false }
                  return confidence.isFinite && (0...1).contains(confidence)
                      && !evidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              }) else { return nil }
        let inspected = observer.frames.filter { !intentionalFadeSamples.contains($0.index) }
        guard !inspected.isEmpty else { return nil }
        let useful = inspected.filter { $0.purpose?.isUseful == true && ($0.purposeConfidence ?? 0) >= 0.75 }
        let empty = inspected.filter { $0.purpose == .some(.none) && ($0.purposeConfidence ?? 0) >= 0.75 }
        // A majority cannot certify observations the model did not establish.
        // In real footage 4B reported an incidental ending as `none, 0.0`,
        // confusing certainty with usefulness. Ignoring those two samples let
        // a camera drop pass on the strength of its earlier coherent frames.
        let unresolved = inspected.contains {
            $0.purpose == .unclear || ($0.purposeConfidence ?? 0) < 0.75
        }
        // A real automatic replacement showed a route in its first samples,
        // then drifted into incidental bank/fence views. A scenery-only shot
        // needs sustained framing; a bare majority cannot certify its tail.
        // Keep the more tolerant rule for observable actions/reactions.
        let interruptedScenery = empty.count >= 2 && !useful.isEmpty
            && useful.allSatisfy { $0.purpose == .establishing }
        // Actual buggy footage passed a majority vote although the camera
        // swung away from the people into an incidental view before the cut.
        // A confidently observed meaningless ending cannot borrow purpose
        // from the beginning. Normal equipment details remain useful; an
        // intentional fade is already removed from the inspected samples.
        let unmotivatedEnding = empty.contains { $0.index == 4 && ($0.purposeConfidence ?? 0) >= 0.9 }
        let unmotivatedBeginning = [0, 1].allSatisfy { index in empty.contains { $0.index == index } }
        var result = technical
        result.unmotivatedBeginning = unmotivatedBeginning
        result.irrelevantSamples = empty.map(\.index).sorted()
        result.interruptedScenery = interruptedScenery
        result.unmotivatedEnding = unmotivatedEnding
        result.observation += " Роль кадра по отдельным изображениям: " + inspected.sorted { $0.index < $1.index }.map {
            "FRAME \($0.index): \($0.purpose!.rawValue) — \($0.purposeEvidence!)"
        }.joined(separator: "; ")
        // Already proven obstruction remains an obstruction; editorial evidence
        // cannot turn technical failure into a successful review.
        guard technical.status != .obstructed else { return result }
        let majority = inspected.count / 2 + 1
        if empty.count >= max(3, majority) || interruptedScenery || unmotivatedEnding || unmotivatedBeginning {
            result.status = .unmotivated
            result.confidence = empty.compactMap(\.purposeConfidence).min() ?? 0
            result.editorialPurpose = EditorialPurpose.none.rawValue
        } else if !unresolved && empty.isEmpty && useful.count >= majority && technical.status == .usable {
            result.editorialPurpose = useful.first!.purpose!.rawValue
            result.confidence = min(result.confidence, useful.compactMap(\.purposeConfidence).min() ?? 0)
        } else {
            result.status = .uncertain
            result.editorialPurpose = EditorialPurpose.unclear.rawValue
        }
        return result
    }

    static func confirmHandling(_ primary: FrameAnswer, observer: OrientationAnswer,
                                contacts: [CameraInteractionFrame] = [], intentionalFadeSamples: [Int] = [],
                                independentPurpose: OrientationAnswer? = nil) -> FrameAnswer? {
        guard observer.frames.count == 5, Set(observer.frames.map(\.index)) == Set(0..<5),
              independentPurpose == nil || (independentPurpose?.frames.count == 5
                  && Set(independentPurpose?.frames.map(\.index) ?? []) == Set(0..<5)),
              observer.frames.allSatisfy({ !$0.scene.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                  && $0.opaqueCoverFraction.isFinite && (0...1).contains($0.opaqueCoverFraction) }),
              Set(contacts.map(\.index)).count == contacts.count,
              contacts.allSatisfy({ (0..<5).contains($0.index) && $0.confidence.isFinite && (0...1).contains($0.confidence)
                  && literalInteractionEvidence($0) }) else { return nil }
        let observations = Dictionary(uniqueKeysWithValues: observer.frames.map { ($0.index, $0) })
        let interactions = Dictionary(uniqueKeysWithValues: contacts.map { ($0.index, $0) })
        let purposeObservations = Dictionary(uniqueKeysWithValues: (independentPurpose?.frames ?? []).map { ($0.index, $0) })
        var result = primary
        let cameraClaims = contacts.filter { $0.interaction == .cameraAdjustment && $0.confidence >= 0.75 }
        let laterEquipment = contacts.filter { $0.index >= 2 && $0.interaction == .equipmentWork && $0.confidence >= 0.75 }
        // An open POV hand can be misread before it visibly grips a rod/case.
        // Only an entry cluster followed by repeated identified gear work can
        // resolve that ambiguity; it cannot excuse a later reach to the lens.
        let approachToGear = !cameraClaims.isEmpty && cameraClaims.allSatisfy { $0.index <= 1 }
            && laterEquipment.count >= 2
        let unsupportedRotations = primary.frames.filter { frame in
            guard let observed = observations[frame.index] else { return false }
            return (observed.orientation == .sideways || observed.orientation == .inverted)
                && frame.handlingEvidence != .invertedScene
                && frame.content != .cameraHandling
        }.count
        for index in result.frames.indices {
            result.frames[index].cameraAdjustmentConfirmed = nil
            result.frames[index].rotationConfirmed = nil
            result.frames[index].orientationUnresolved = nil
            if intentionalFadeSamples.contains(result.frames[index].index) { result.frames[index].handlingEvidence = .none; continue }
            guard let observed = observations[result.frames[index].index] else { return nil }
            let interaction = interactions[result.frames[index].index]
            let gearWork = interaction?.interaction == .equipmentWork && (interaction?.confidence ?? 0) >= 0.75
                || approachToGear && cameraClaims.contains { $0.index == result.frames[index].index }
            let readableGear = gearWork && observed.opaqueCoverFraction <= 0.35
            // The primary called an opened fabric bag "lens-cover" while
            // the independent physical observer saw zero accidental cover
            // and the interaction observer identified the hand gripping it.
            // An actual lens reach or unidentified opaque material cannot use
            // this correction. Confirmed rotation remains a separate guard.
            if readableGear && result.frames[index].obstructionFraction >= 0.55 {
                result.frames[index].content = .event
                result.frames[index].obstructionFraction = observed.opaqueCoverFraction
            }
            // A real bag-opening interval was falsely "sideways" in two
            // isolated downward close-ups. Without a visible world reference,
            // object angle cannot confirm camera rotation. Only independently
            // identified gear work can resolve such an overhead detail; an
            // ambiguous patch of ground or actual lens reach stays guarded.
            let overheadGear = observed.orientationBasis != nil && observed.orientationBasis != .worldReference
                && observed.opaqueCoverFraction <= 0.35
                && gearWork
            let rotated = observed.orientation == .inverted || observed.orientation == .sideways
            let primaryRotation = result.frames[index].handlingEvidence == .invertedScene
            let corroboratesRotation = primaryRotation || primary.frames[index].content == .cameraHandling
            let orientationEstablished = (observed.orientation != .unclear
                    && ((!rotated && !primaryRotation) || observed.orientationBasis == .worldReference))
                    || overheadGear
            if !orientationEstablished {
                // Opaque contact can hide the world references needed to
                // measure rotation. An unknown orientation is not permission
                // to use the frame, nor a reason to erase independently
                // corroborated lens contact. All observers have already run.
                result.frames[index].orientationUnresolved = true
                result.frames[index].handlingEvidence = .none
                if let interaction, interaction.interaction == .cameraAdjustment,
                   interaction.confidence >= 0.9,
                   !(approachToGear && cameraClaims.contains { $0.index == result.frames[index].index }) {
                    result.frames[index].handlingEvidence = .directLensContact
                    result.frames[index].cameraAdjustmentConfirmed = true
                    result.frames[index].confidence = min(result.frames[index].confidence, interaction.confidence)
                }
                continue
            }
            if rotated && observed.orientationBasis == .worldReference {
                if corroboratesRotation {
                    result.frames[index].rotationConfirmed = primaryRotation && result.frames[index].confidence >= 0.9
                    result.frames[index].handlingEvidence = .invertedScene
                } else {
                    // Repeating one observer's wrong orientation label does
                    // not make it independent confirmation. Identified clear
                    // gear resolves the observed bag false positive; otherwise
                    // repeated disagreement stays uncertain and cannot pass.
                    result.frames[index].handlingEvidence = .none
                    let purposeOrientation = purposeObservations[result.frames[index].index]?.orientation
                    let independentRotation = purposeOrientation == .sideways || purposeOrientation == .inverted
                    // The purpose and neutral observers can both notice a
                    // rotated boundary that the primary missed. Do not let
                    // a one-frame disagreement disappear in a usable majority.
                    // This preserves uncertainty; purpose confidence is not
                    // an orientation score or a positive rotation certificate.
                    if independentRotation || !readableGear && unsupportedRotations >= 2 {
                        result.frames[index].orientationUnresolved = true
                    }
                }
            } else if approachToGear && cameraClaims.contains(where: { $0.index == result.frames[index].index }) {
                result.frames[index].handlingEvidence = .none
            } else if let interaction = interactions[result.frames[index].index],
               interaction.interaction == .cameraAdjustment, interaction.confidence >= 0.9 {
                // A contact-sheet model can miss the approaching hand entirely.
                // The independent literal observer must be able to reject that
                // technical tail even when the primary called it normal scenery.
                result.frames[index].handlingEvidence = .directLensContact
                result.frames[index].cameraAdjustmentConfirmed = true
                result.frames[index].confidence = min(result.frames[index].confidence, interaction.confidence)
            } else if result.frames[index].handlingEvidence == .directLensContact {
                // An open view does not disprove a hand adjusting the camera.
                // Independent literal contact observations distinguish that
                // gesture from useful hands working with fishing/steering gear.
                guard let interaction = interactions[result.frames[index].index], interaction.confidence >= 0.75,
                      interaction.interaction != .unclear else { return nil }
                if interaction.interaction == .cameraAdjustment {
                    result.frames[index].cameraAdjustmentConfirmed = true
                } else {
                    result.frames[index].handlingEvidence = .none
                }
            } else {
                result.frames[index].handlingEvidence = .none
            }
            // A conflicting orientation label cannot hide independently
            // observed physical lens contact. The entry-to-gear resolution
            // remains limited to the early cluster, never the actual tail.
            if let interaction, interaction.interaction == .cameraAdjustment, interaction.confidence >= 0.9,
               !(approachToGear && cameraClaims.contains { $0.index == result.frames[index].index }) {
                result.frames[index].handlingEvidence = .directLensContact
                result.frames[index].cameraAdjustmentConfirmed = true
                result.frames[index].confidence = min(result.frames[index].confidence, interaction.confidence)
            }
        }
        result.observation = "Независимая проверка положения сцены: " + observer.frames.sorted { $0.index < $1.index }.map {
            "FRAME \($0.index): \($0.orientation.rawValue) — \($0.scene)"
        }.joined(separator: "; ")
        if !contacts.isEmpty {
            result.observation += " Взаимодействие рук: " + contacts.sorted { $0.index < $1.index }.map {
                "FRAME \($0.index): \($0.interaction.rawValue) — \($0.evidence)"
            }.joined(separator: "; ")
        }
        return result
    }

    static func resolve(_ answer: FrameAnswer, intentionalFadeSamples: [Int] = []) -> Answer? {
        guard answer.frames.count == 5, Set(answer.frames.map(\.index)) == Set(0..<5),
              answer.frames.allSatisfy({ $0.confidence.isFinite && (0...1).contains($0.confidence)
                  && $0.obstructionFraction.isFinite && (0...1).contains($0.obstructionFraction) }) else { return nil }
        let inspected = answer.frames.filter { !intentionalFadeSamples.contains($0.index) }
        guard !inspected.isEmpty else { return nil }
        let covers = inspected.filter {
            $0.content == .lensCover && $0.obstructionFraction >= 0.55 && $0.confidence >= 0.7
                || $0.handlingEvidence != .none && $0.confidence >= 0.75
        }
        // A generic camera-handling label is not evidence: on real fishing
        // footage it was inferred solely from hands moving the rod. Require
        // the separately observed inversion/lens contact instead.
        // One close-up can be a meaningful detail (opening a case, fishing
        // hands) or a brief transition. Actual-source review exposed an
        // isolated confident false positive on such a detail. Refuse a range
        // only when at least two samples confirm a sustained interruption.
        // A separately confirmed camera adjustment is different: even one
        // boundary sample proves the edit includes the technical tail.
        let observedContacts = covers.filter { $0.cameraAdjustmentConfirmed == true }
        // A lone entry/middle inference is not a sustained interruption.
        // A lens reach at the actual cut, or repeated contact, is different.
        let confirmedContacts = observedContacts.count >= 2 ? observedContacts : observedContacts.filter { $0.index == 4 }
        let boundaryRotations = covers.filter { $0.rotationConfirmed == true && ($0.index == 0 || $0.index == 4) }
        let interrupted = covers.count >= 2 || !confirmedContacts.isEmpty || !boundaryRotations.isEmpty
        let uncertain = inspected.contains { $0.content == .uncertain || $0.orientationUnresolved == true || $0.confidence < 0.75
            || ($0.content == .event || $0.content == .landscape) && $0.obstructionFraction >= 0.55 }
        // A real response contained all five valid classifications but no
        // prose. Preserve those facts without inventing an action description.
        // Missing/uncertain frame verdicts still cannot certify a range.
        let observation = answer.observation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Покадровая разметка модели: " + answer.frames.sorted { $0.index < $1.index }.map {
                "FRAME \($0.index): \($0.content.rawValue), confidence \(Int(($0.confidence * 100).rounded()))%, obstruction \(Int(($0.obstructionFraction * 100).rounded()))%, handling evidence \($0.handlingEvidence.rawValue)"
            }.joined(separator: "; ") : answer.observation
        return Answer(status: interrupted ? .obstructed : (uncertain ? .uncertain : .usable),
            confidence: (interrupted ? covers : inspected).map(\.confidence).min() ?? 0,
            obstructedSamples: covers.map(\.index).sorted(), observation: observation, activity: answer.activity,
            cameraAdjustmentSamples: confirmedContacts.map(\.index).sorted(),
            confirmedBoundaryRotationSamples: boundaryRotations.map(\.index).sorted())
    }
    private struct Envelope: Decodable {
        struct Message: Decodable { var content: String }
        var message: Message?
        var done: Bool?
        var model: String?
        var done_reason: String?
    }

    let cacheURL: URL
    let model: String
    typealias AnswerTransport = @Sendable (URLRequest) async throws -> (Data, URLResponse)
    var answerTransport: AnswerTransport? = nil
    var requestProgress: FilmBuildProgressHandler? = nil
    // Match the inference watchdog's active-uptime clock. A real 8B audit
    // slept for 15 minutes: a calendar deadline expired after only 75 seconds
    // of active work and discarded the unfinished shot after wake-up.
    var deadlineUptime: TimeInterval? = nil
    var workUptime: @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    var inferenceClient: LocalAIInferenceClient = .shared
    var modelDigestOverride: String? = nil
    var evidenceContext: String? = nil
    var observationProgress: ObservationProgress? = nil
    // Only automatic film assembly supplies this callback. It must establish
    // an admissible replacement before retiring an already rejected export.
    // A partial report never satisfies the final all-items delivery gate.
    var renderedReplacementAvailable: (@Sendable ([ShotContentAssessment]) -> Bool)? = nil

    actor ObservationProgress {
        private var completed: Set<String> = []
        func record(_ key: String) { completed.insert(key) }
        var count: Int { completed.count }
    }

    // No decoded images are retained while other shots are checked. Every
    // finished model observation already has its exact-request disk receipt;
    // this pending value is never a completed source certificate.
    private struct PendingSourceBoundary {
        var index: Int
        var reviewer: SelectedContentReviewer
        var assessment: ShotContentAssessment
        var answer: Answer
        var sourceURL: URL
        var sourceIdentity: String
        var contextTimes: [Double]
        var receipt: URL
        var responseURL: URL
        var consumedSeconds: Double
    }

    func review(timeline: Timeline, assets: [MediaAsset], renderedURL: URL? = nil,
                progress: FilmBuildProgressHandler? = nil, pass: Int = 1, reason: String? = nil) async throws -> [ShotContentAssessment] {
        let items = timeline.items.filter { OriginalMediaType.isVideo($0, assets: assets) }
        guard !items.isEmpty else { return [] }
        let byID = Dictionary(assets.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let phase = renderedURL == nil ? "source" : "mp4"
        let frameCache = FrameCache(rootURL: cacheURL.appendingPathComponent("SelectedContentFrames"))
        let root = cacheURL.appendingPathComponent("SelectedContentReview")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var available: Bool
        if answerTransport != nil { available = true }
        else { available = await OllamaVisionRuntime().isAvailable(model: model) }
        let modelIdentity: String
        if answerTransport != nil { modelIdentity = "injected-transport" }
        else {
            let digest = await LocalAIModelManager.shared.installedModelDigest(model: model)
            try FilmProcessContext.current?.validate(model: model, digest: digest)
            modelIdentity = digest ?? UUID().uuidString
        }
        // A full independent observation takes several model requests. A 90 s
        // shot / 180 s film deadline discarded every result on a real 24-shot
        // film. Bound each shot, not the entire movie; uncertainty is not a pass.
        let profile = FilmProcessContext.current ?? FilmProcessProfile(analysis: .resolve(mode: .fast))
        let singleImageContext = FilmProcessContext.current?.singleImageReviewContextTokens
        let groupSourceObservers = renderedURL == nil && singleImageContext != nil
        let stage: FilmBuildProgress.Stage = renderedURL != nil ? .renderedContent
            : groupSourceObservers ? .sourceFrames : .sourceContent
        var consecutiveFailures = 0
        var result = [ShotContentAssessment?](repeating: nil, count: items.count)
        var pendingBoundaries: [PendingSourceBoundary] = []
        if FilmProcessContext.current != nil {
            PerformanceTrace.current?.event("review.observers.phase", fields: ["model": model, "phase": phase + (groupSourceObservers || renderedURL != nil ? ".frames" : ".interleaved")],
                values: ["shots": Double(items.count), "contextTokens": Double(singleImageContext ?? profile.contextTokens)])
        }
        for (index, item) in items.enumerated() {
            try Task.checkCancellation()
            guard let assetID = item.assetID, let asset = byID[assetID] else { continue }
            let started = workUptime()
            let completedBeforeShot = groupSourceObservers ? index : result.lazy.compactMap { $0 }.count
            var deferredBoundary = false
            var reviewer = self
            reviewer.deadlineUptime = min(deadlineUptime ?? .infinity,
                workUptime() + (FilmProcessContext.current?.shotBudgetSeconds ?? 600))
            let operation = phase == "source" ? "исходного видео" : "готового видео"
            let operationPrefix = groupSourceObservers || renderedURL != nil ? "кадры " : ""
            let observations = ObservationProgress()
            reviewer.observationProgress = observations
            reviewer.requestProgress = { update in
                let saved = await observations.count
                await progress?(FilmBuildProgress(stage, completed: completedBeforeShot, total: items.count,
                    detail: "Проверка \(pass): \(operationPrefix)\(operation) \(index + 1) из \(items.count). \(update.detail ?? "")"
                        + (saved > 0 ? " · Получено наблюдений: \(saved)" : "")
                        + (reason.map { " · " + $0 } ?? ""), isHeartbeat: update.isHeartbeat))
            }
            let fractions = profile.reviewFractions
            let times = fractions.map { fraction in
                renderedURL == nil ? item.sourceStart + item.sourceDuration * fraction
                    : TimelineTiming.playbackTime(forTimelineTime: item.timelineStart + item.timelineDuration * fraction, timeline: timeline)
            }
            let identity = renderedURL.map { FrameCacheKey.sourceIdentity(url: $0, contentHash: EditorialRenderSignature.signature(timeline)) }
                ?? FrameCacheKey.sourceIdentity(url: asset.originalURL, contentHash: asset.contentHash)
            let end = item.sourceStart + item.sourceDuration
            let lastTime = max(0, (asset.metadata.duration ?? end) - 1 / max(24, asset.metadata.frameRate ?? 30))
            let contextTimes = renderedURL == nil
                ? [max(0, item.sourceStart - profile.boundaryLeadSeconds)] + times
                    + [min(lastTime, end + profile.boundaryNearSeconds), min(lastTime, end + profile.boundaryFollowingSeconds)]
                : []
            // A corrected duration/frame rate may move the post-cut evidence
            // even when the selected interval itself stays byte-identical.
            let frameIdentity = "\(AdaptiveFrameSampler.selectedContentRepresentation)|\(model)|\(modelIdentity)|\(phase)|\(identity)|\(times)|\(contextTimes)"
            let key = EditorialIdentity.hash("\(Self.version)|\(profile.reviewIdentity)|\(frameIdentity)")
            let observationKey = EditorialIdentity.hash("\(Self.observationVersion)|\(profile.observationIdentity)|\(frameIdentity)")
            // The completed-shot receipt remains tied to this exact MP4.
            // A newly exported file must be decoded again. Its individual VLM
            // replies may reuse an earlier MP4 reply only when the source
            // interval, requested output times, rules, weights AND actual JPEG
            // request bytes match. New generated timeline IDs alone must not
            // force the model to judge identical rendered pixels again.
            reviewer.evidenceContext = renderedURL == nil ? observationKey
                : Self.renderedResponseContext(asset: asset, item: item, times: times, profile: profile)
            let receipt = root.appendingPathComponent(key + ".json")
            var assessment = ShotContentAssessment(itemID: item.id, assetID: assetID, sourceContentHash: asset.contentHash, sourceStart: item.sourceStart,
                sourceDuration: item.sourceDuration, sampleTimes: times, phase: phase, model: model, cacheKey: key,
                status: .uncertain, confidence: 0, obstructedSamples: [],
                observation: "Локальная проверка содержания недоступна", activity: "unknown")
            await progress?(FilmBuildProgress(stage, completed: completedBeforeShot, total: items.count,
                detail: "Фрагмент \(index + 1) из \(items.count) · \(asset.displayName). Подготавливаю кадры"))
            if let data = try? Data(contentsOf: receipt), let cached = try? JSONDecoder().decode(Answer.self, from: data),
               Self.valid(cached), phase != "source" || cached.status != .usable || cached.actionBoundary != nil {
                PerformanceTrace.current?.event("review.cache", fields: ["model": model, "phase": phase, "key": key, "origin": "reused"])
                assessment = Self.applying(cached, to: assessment)
            } else if available, reviewer.deadlineUptime.map({ $0 > workUptime() }) ?? true {
                PerformanceTrace.current?.event("review.cache", fields: ["model": model, "phase": phase, "key": key, "origin": "computed"])
                do {
                    let samples = try await AdaptiveFrameSampler().selectedContentSamples(url: renderedURL ?? asset.originalURL,
                        sourceHash: identity, timestamps: times, frameCache: frameCache, maximumSize: profile.reviewLongEdge)
                    guard samples.count == times.count,
                          zip(samples, times).allSatisfy({ abs(($0.0.actualTimestamp ?? $0.0.timestamp) - $0.1) <= 0.1 }) else {
                        throw URLError(.cannotDecodeContentData)
                    }
                    let exemptions = renderedURL == nil ? [] : times.enumerated().compactMap { index, time -> Int? in
                        let fade = FilmEndingFade(duration: timeline.endingFadeDuration,
                            movieDuration: AutomaticFilmDurationPolicy.renderedDuration(of: timeline), frameRate: timeline.frameRate)
                        return (fade?.opacity(at: time) ?? 1) < 0.35 ? index : nil
                    }
                    var answer = try await FilmProcessContext.$minimumReviewContextTokens.withValue(singleImageContext) {
                        try await reviewer.judge(samples: samples, intentionalFadeSamples: exemptions,
                            responseURL: cacheURL.appendingPathComponent("SelectedContentResponses").appendingPathComponent(key + ".json"))
                    }
                    if groupSourceObservers, answer.status == .usable {
                        pendingBoundaries.append(PendingSourceBoundary(index: index, reviewer: reviewer,
                            assessment: assessment, answer: answer, sourceURL: asset.originalURL,
                            sourceIdentity: identity, contextTimes: contextTimes, receipt: receipt,
                            responseURL: cacheURL.appendingPathComponent("SelectedContentResponses").appendingPathComponent(key + ".action.json"),
                            consumedSeconds: workUptime() - started))
                        deferredBoundary = true
                    } else if renderedURL == nil, answer.status == .usable {
                        let context = try await AdaptiveFrameSampler().selectedContentSamples(url: asset.originalURL,
                            sourceHash: identity, timestamps: contextTimes, frameCache: frameCache, maximumSize: profile.reviewLongEdge)
                        guard context.count == 8,
                              zip(context, contextTimes).allSatisfy({ abs(($0.0.actualTimestamp ?? $0.0.timestamp) - $0.1) <= 0.1 }) else {
                            throw URLError(.cannotDecodeContentData)
                        }
                        let objectTimes = [1, 3, 5, 6, 7].map { contextTimes[$0] }
                        let objectSamples = try await AdaptiveFrameSampler().selectedContentSamples(url: asset.originalURL,
                            sourceHash: identity, timestamps: objectTimes, frameCache: frameCache, maximumSize: profile.boundaryLongEdge)
                        let boundary = try await FilmProcessContext.$minimumReviewContextTokens.withValue(profile.contextTokens) {
                            try await reviewer.inspectActionBoundary(samples: context, objectSamples: objectSamples,
                                responseURL: cacheURL.appendingPathComponent("SelectedContentResponses").appendingPathComponent(key + ".action.json"))
                        }
                        answer = try Self.applyingBoundary(boundary, to: answer)
                    }
                    consecutiveFailures = 0
                    if !deferredBoundary { assessment = Self.applying(answer, to: assessment) }
                    // Unknown results are retryable. A timeout cannot poison
                    // the persistent cache as a successful content review.
                    if !deferredBoundary, answer.status != .uncertain {
                        try JSONEncoder().encode(answer).write(to: receipt, options: .atomic)
                    }
                } catch is CancellationError { throw CancellationError() }
                catch {
                    if error is LocalAIInferenceFailure || error is FilmProcessProfileError { throw error }
                    assessment.observation = "Содержание не проверено: \(error.localizedDescription)"
                    // A slow or ambiguous shot says nothing about the next
                    // one. Stop network attempts only when the local service
                    // itself is unreachable, never after two model timeouts.
                    let code = (error as? URLError)?.code
                    consecutiveFailures = [.cannotConnectToHost, .cannotFindHost].contains(code) ? consecutiveFailures + 1 : 0
                    if consecutiveFailures >= 2 { available = false }
                }
            }
            if !deferredBoundary { result[index] = assessment }
            let completed = result.compactMap { $0 }
            await progress?(FilmBuildProgress(stage, completed: groupSourceObservers ? index + 1 : completed.count, total: items.count,
                detail: groupSourceObservers
                    ? "Проверка кадров: обработано \(index + 1) из \(items.count). Границы действий проверяются отдельно."
                    : "Обработано \(completed.count) из \(items.count) · подтверждено \(completed.filter { $0.status != .uncertain }.count)"))
            if renderedURL != nil, index + 1 < items.count,
               !assessment.certifies(item: item, phase: "mp4", assets: assets),
               renderedReplacementAvailable?(completed) == true {
                PerformanceTrace.current?.event("review.rejected-export-retired", fields: ["model": model],
                    values: ["completedRanges": Double(completed.count), "totalRanges": Double(items.count)])
                await progress?(FilmBuildProgress(stage, completed: index + 1, total: items.count,
                    detail: "Найден неподтверждённый фрагмент. Подготовлена замена; новый монтаж пройдёт полную проверку."))
                break
            }
        }
        // Stay at the existing large allocation for all temporal comparisons;
        // switching context for every shot would repeatedly reload the model.
        if !pendingBoundaries.isEmpty, answerTransport == nil {
            let digest = await LocalAIModelManager.shared.installedModelDigest(model: model)
            try FilmProcessContext.current?.validate(model: model, digest: digest)
        }
        if !pendingBoundaries.isEmpty {
            PerformanceTrace.current?.event("review.observers.phase", fields: ["model": model, "phase": "source.boundaries"],
                values: ["shots": Double(pendingBoundaries.count), "contextTokens": Double(profile.contextTokens)])
        }
        let boundaryCount = pendingBoundaries.count
        for (boundaryIndex, pending) in pendingBoundaries.enumerated() {
            try Task.checkCancellation()
            var reviewer = pending.reviewer
            var assessment = pending.assessment
            let completedBeforeBoundary = boundaryIndex
            let remaining = max(0, profile.shotBudgetSeconds - pending.consumedSeconds)
            reviewer.deadlineUptime = min(deadlineUptime ?? .infinity, workUptime() + remaining)
            let observations = reviewer.observationProgress
            reviewer.requestProgress = { update in
                let saved = await observations?.count ?? 0
                await progress?(FilmBuildProgress(.sourceBoundaries, completed: completedBeforeBoundary, total: boundaryCount,
                    detail: "Проверка \(pass): границы действий исходного видео \(pending.index + 1) из \(items.count). \(update.detail ?? "")"
                        + (saved > 0 ? " · Получено наблюдений: \(saved)" : "")
                        + (reason.map { " · " + $0 } ?? ""), isHeartbeat: update.isHeartbeat))
            }
            await progress?(FilmBuildProgress(.sourceBoundaries, completed: boundaryIndex, total: boundaryCount,
                detail: "Подготавливаю проверку границ · фрагмент \(pending.index + 1) из \(items.count)"))
            if available, remaining > 0, reviewer.deadlineUptime.map({ $0 > workUptime() }) ?? true {
                do {
                    let context = try await AdaptiveFrameSampler().selectedContentSamples(url: pending.sourceURL,
                        sourceHash: pending.sourceIdentity, timestamps: pending.contextTimes,
                        frameCache: frameCache, maximumSize: profile.reviewLongEdge)
                    guard context.count == 8,
                          zip(context, pending.contextTimes).allSatisfy({ abs(($0.0.actualTimestamp ?? $0.0.timestamp) - $0.1) <= 0.1 }) else {
                        throw URLError(.cannotDecodeContentData)
                    }
                    let objectTimes = [1, 3, 5, 6, 7].map { pending.contextTimes[$0] }
                    let objectSamples = try await AdaptiveFrameSampler().selectedContentSamples(url: pending.sourceURL,
                        sourceHash: pending.sourceIdentity, timestamps: objectTimes,
                        frameCache: frameCache, maximumSize: profile.boundaryLongEdge)
                    let boundary = try await FilmProcessContext.$minimumReviewContextTokens.withValue(profile.contextTokens) {
                        try await reviewer.inspectActionBoundary(samples: context, objectSamples: objectSamples,
                            responseURL: pending.responseURL)
                    }
                    let answer = try Self.applyingBoundary(boundary, to: pending.answer)
                    assessment = Self.applying(answer, to: assessment)
                    consecutiveFailures = 0
                    if answer.status != .uncertain {
                        try JSONEncoder().encode(answer).write(to: pending.receipt, options: .atomic)
                    }
                } catch is CancellationError { throw CancellationError() }
                catch {
                    if error is LocalAIInferenceFailure || error is FilmProcessProfileError { throw error }
                    assessment.observation = "Границы действия не проверены: \(error.localizedDescription)"
                    let code = (error as? URLError)?.code
                    consecutiveFailures = [.cannotConnectToHost, .cannotFindHost].contains(code) ? consecutiveFailures + 1 : 0
                    if consecutiveFailures >= 2 { available = false }
                }
            } else {
                assessment.observation = "Кадры проверены; проверка границ действия ещё не завершена. Наблюдения сохранены."
            }
            result[pending.index] = assessment
            let completed = result.compactMap { $0 }
            await progress?(FilmBuildProgress(.sourceBoundaries, completed: boundaryIndex + 1, total: boundaryCount,
                detail: "Границы действий: фрагмент \(pending.index + 1) из \(items.count) · обработано \(completed.count), подтверждено \(completed.filter { $0.status != .uncertain }.count)"))
        }
        return result.compactMap { $0 }
    }

    static func renderedResponseContext(asset: MediaAsset, item: TimelineItem,
                                        times: [Double], profile: FilmProcessProfile) -> String {
        let source = FrameCacheKey.sourceIdentity(url: asset.originalURL, contentHash: asset.contentHash)
        return EditorialIdentity.hash(["mp4-exact-pixels-v1", profile.observationIdentity, source,
            String(item.sourceStart.bitPattern), String(item.sourceDuration.bitPattern),
            times.map { String($0.bitPattern) }.joined(separator: ",")].joined(separator: "|"))
    }

    private static func applying(_ answer: Answer, to original: ShotContentAssessment) -> ShotContentAssessment {
        var result = original
        result.status = answer.status
        result.confidence = answer.confidence
        result.obstructedSamples = answer.obstructedSamples
        result.observation = answer.observation
        result.activity = answer.activity
        result.editorialPurpose = answer.editorialPurpose
        result.irrelevantSamples = answer.irrelevantSamples
        result.interruptedScenery = answer.interruptedScenery
        result.cameraAdjustmentSamples = answer.cameraAdjustmentSamples
        result.unmotivatedEnding = answer.unmotivatedEnding
        result.unmotivatedBeginning = answer.unmotivatedBeginning
        result.confirmedBoundaryRotationSamples = answer.confirmedBoundaryRotationSamples
        result.actionBoundary = answer.actionBoundary
        return result
    }

    static func valid(_ answer: Answer) -> Bool {
        answer.confidence.isFinite && (0...1).contains(answer.confidence)
            && Set(answer.obstructedSamples).count == answer.obstructedSamples.count
            && answer.obstructedSamples.allSatisfy { (0..<5).contains($0) }
            && !answer.observation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && Set(answer.cameraAdjustmentSamples ?? []).count == (answer.cameraAdjustmentSamples ?? []).count
            && (answer.cameraAdjustmentSamples ?? []).allSatisfy { answer.obstructedSamples.contains($0) }
            && Set(answer.confirmedBoundaryRotationSamples ?? []).count == (answer.confirmedBoundaryRotationSamples ?? []).count
            && (answer.confirmedBoundaryRotationSamples ?? []).allSatisfy { ($0 == 0 || $0 == 4) && answer.obstructedSamples.contains($0) }
            && (answer.status != .obstructed || answer.obstructedSamples.count >= 2 || !(answer.cameraAdjustmentSamples ?? []).isEmpty
                || !(answer.confirmedBoundaryRotationSamples ?? []).isEmpty)
            && (answer.status != .usable || answer.obstructedSamples.count <= 1)
            && (answer.status != .usable || (answer.cameraAdjustmentSamples ?? []).isEmpty)
            && (answer.status != .usable || (answer.confirmedBoundaryRotationSamples ?? []).isEmpty)
            && (answer.irrelevantSamples ?? []).allSatisfy { (0..<5).contains($0) }
            && Set(answer.irrelevantSamples ?? []).count == (answer.irrelevantSamples ?? []).count
            && (answer.unmotivatedEnding != true || answer.irrelevantSamples?.contains(4) == true)
            && (answer.status != .usable || answer.unmotivatedEnding != true)
            && (answer.unmotivatedBeginning != true || answer.irrelevantSamples?.contains(0) == true && answer.irrelevantSamples?.contains(1) == true)
            && (answer.status != .usable || answer.unmotivatedBeginning != true)
            && (answer.actionBoundary == nil || answer.actionBoundary?.isValid == true)
            && (answer.status != .usable || answer.actionBoundary?.rejectsCut != true)
            && (answer.status != .unmotivated || (answer.irrelevantSamples?.count ?? 0) >= 3
                || answer.interruptedScenery == true && answer.editorialPurpose == EditorialPurpose.none.rawValue
                    && (answer.irrelevantSamples?.count ?? 0) >= 2
                || answer.unmotivatedEnding == true && answer.editorialPurpose == EditorialPurpose.none.rawValue
                    && answer.irrelevantSamples?.contains(4) == true
                || answer.unmotivatedBeginning == true && answer.editorialPurpose == EditorialPurpose.none.rawValue
                    && answer.irrelevantSamples?.contains(0) == true && answer.irrelevantSamples?.contains(1) == true
                || answer.actionBoundary?.rejectsCut == true)
    }

    private func judge(samples: [VisualFrameSample], intentionalFadeSamples: [Int], responseURL: URL) async throws -> Answer {
        // A five-cell collage has a sixth blank area and letterboxing. Real
        // 30B observations attributed that padding to the source (birds,
        // speech, waterfall) and invented rotation in a natural pan. Observe
        // each original sampled image at full review resolution in every
        // mode, keeping its independent purpose/contact checks beside it.
        var (frameAnswer, observer, contacts, orientation) = try await inspectFrameEvidence(samples: samples,
            primary: nil, intentionalFadeSamples: intentionalFadeSamples, responseURL: responseURL)
        for index in frameAnswer.frames.indices {
            frameAnswer.frames[index].cameraAdjustmentConfirmed = nil
            frameAnswer.frames[index].rotationConfirmed = nil
        }
        // Every selected frame gets an independent observation. A contact-sheet
        // model previously repeated the first cell and missed later rotations.
        // Do not let the primary classifier decide whether the independent
        // contact observer runs: real footage passed as scenery despite a hand
        // reaching straight toward the lens at the cut.
        if let orientation {
            guard let confirmed = Self.confirmHandling(frameAnswer, observer: orientation,
                contacts: contacts, intentionalFadeSamples: intentionalFadeSamples,
                independentPurpose: observer) else { throw URLError(.cannotParseResponse) }
            frameAnswer = confirmed
        }
        guard let technical = Self.resolve(frameAnswer, intentionalFadeSamples: intentionalFadeSamples),
              let purposeful = Self.applyingPurpose(observer, to: technical, intentionalFadeSamples: intentionalFadeSamples),
              let answer = Self.applyingInteractionCertainty(contacts, to: purposeful,
                  intentionalFadeSamples: intentionalFadeSamples), Self.valid(answer) else {
            throw URLError(.cannotParseResponse)
        }
        return answer
    }

    /// Schedule every independent observer for an image while its prefix is
    /// still hot. Scheduling never adds another observer's answer to a prompt.
    /// Once a handling claim requires neutral orientation, all sampled images
    /// are still inspected, including earlier images before the claim appeared.
    func inspectFrameEvidence(samples: [VisualFrameSample], primary: FrameAnswer?, intentionalFadeSamples: [Int],
                              responseURL: URL) async throws
        -> (FrameAnswer, OrientationAnswer, [CameraInteractionFrame], OrientationAnswer?) {
        var frames = primary?.frames ?? []
        var descriptions: [String] = []
        var purposes: [OrientationFrame] = []
        var contacts: [CameraInteractionFrame] = []
        var orientations: [OrientationFrame] = []
        var needsOrientation = frames.contains { $0.handlingEvidence != .none || $0.content == .cameraHandling }
        let orientationURL = responseURL.deletingPathExtension().appendingPathExtension("orientation.json")
        for index in samples.indices {
            if primary == nil {
                let technical = try await inspectTechnicalFrames(samples: samples, indices: [index],
                    intentionalFadeSamples: intentionalFadeSamples, responseURL: responseURL)
                frames += technical.frames
                descriptions.append(technical.observation)
                needsOrientation = needsOrientation || technical.frames.contains {
                    $0.handlingEvidence != .none || $0.content == .cameraHandling
                }
            }
            let (purpose, contact) = try await inspectIndependentFrames(samples: samples, indices: [index],
                intentionalFadeSamples: intentionalFadeSamples, responseURL: responseURL)
            purposes += purpose.frames
            contacts += contact
            // The independent purpose observer also inspects scene orientation.
            // Its rotation finding must reach the neutral physical check even
            // when the primary called the image readable and no hand is visible.
            // A useful landscape can still be sideways in the exported film.
            needsOrientation = needsOrientation || purpose.frames.contains {
                $0.orientation == .sideways || $0.orientation == .inverted
            }
            needsOrientation = needsOrientation || contact.contains {
                $0.interaction == .unclear || $0.interaction == .cameraAdjustment && $0.confidence >= 0.9
            }
            if needsOrientation {
                orientations += try await inspectOrientation(samples: samples, indices: [index], responseURL: orientationURL).frames
            }
        }
        if needsOrientation {
            let completed = Set(orientations.map(\.index))
            let missing = samples.indices.filter { !completed.contains($0) }
            orientations += try await inspectOrientation(samples: samples, indices: missing, responseURL: orientationURL).frames
            orientations.sort { $0.index < $1.index }
        }
        let technical = primary ?? FrameAnswer(frames: frames, observation: descriptions.joined(separator: "; "), activity: "unknown")
        return (technical, OrientationAnswer(frames: purposes), contacts,
            needsOrientation ? OrientationAnswer(frames: orientations) : nil)
    }

    /// Each mode receives one observable question and one full sampled image
    /// at a time, with no artificial blank cells or letterboxing to classify. The
    /// independent purpose/contact/orientation and action checks still follow.
    private func inspectTechnicalFrames(samples: [VisualFrameSample], indices: [Int], intentionalFadeSamples: [Int],
                                                  responseURL: URL) async throws -> FrameAnswer {
        struct Observation: Decodable {
            var observation: String
            var content: FrameContent
            var obstructionFraction: Double
            var confidence: Double
            var handlingEvidence: HandlingEvidence
        }
        var frames: [FrameVerdict] = []
        var observations: [String] = []
        for index in indices {
            let sample = samples[index]
            let fields: [String: Any] = ["observation": ["type": "string", "minLength": 12, "maxLength": 200],
                "content": ["type": "string", "enum": ["event", "landscape", "lens-cover", "camera-handling", "uncertain"]],
                "obstructionFraction": ["type": "number", "minimum": 0, "maximum": 1],
                "confidence": ["type": "number", "minimum": 0, "maximum": 1],
                "handlingEvidence": ["type": "string", "enum": ["none", "inverted-scene", "direct-lens-contact"]]]
            let prompt = """
            Inspect this ONE image literally. First describe what is visible in one short English sentence.
            Classify its main content: event (a readable filmed subject or activity, including people, animals/wildlife, vehicles, purposeful hands or equipment), landscape (place or route), lens-cover (accidental opaque material hides the scene), camera-handling (visible direct lens contact or the whole scene rotated at least 90 degrees), uncertain.
            obstructionFraction is the fraction hidden by accidental opaque material, NOT the size of a normal subject. Hands using gear, a bag, passenger legs and a roll cage are subjects, not lens covers. Only actual contact with the filming lens is direct-lens-contact; hands touching another object are none. Camera movement cannot be inferred from one image. Do not invent hidden contact or rotation. When evidence is unclear, use uncertain.
            This frame is an intentional final fade: \(intentionalFadeSamples.contains(index)). A planned fade is not a lens cover. Return only JSON.
            """
            let body: [String: Any] = ["model": model, "stream": false, "think": false,
                "options": ["num_ctx": 4096, "num_predict": 240, "temperature": 0, "seed": 0],
                "format": ["type": "object", "required": fields.keys.sorted(), "additionalProperties": false, "properties": fields],
                "messages": [["role": "user", "content": prompt, "images": [sample.jpegBase64]]]]
            let content = try await modelAnswer(body: body,
                responseURL: responseURL.deletingPathExtension().appendingPathExtension("technical-frame-\(index).json"),
                progressDetail: "Проверяю читаемость · кадр \(index + 1) из \(samples.count)",
                responseFieldOrder: FilmProcessContext.current?.technicalObservationFirst == true
                    ? ["observation", "confidence", "content", "handlingEvidence", "obstructionFraction"] : nil,
                repairInstruction: "OBSERVATION FORMAT: observation must describe the visible image in a literal sentence of at least three words, including unclear or obscured views.",
                validateObservation: { content in
                    let observation = try JSONDecoder().decode(Observation.self, from: Data(content.utf8))
                    guard observation.observation.split(whereSeparator: \.isWhitespace).count >= 3 else { throw URLError(.cannotParseResponse) }
                })
            let observation = try JSONDecoder().decode(Observation.self, from: Data(content.utf8))
            frames.append(FrameVerdict(index: index, content: observation.content, confidence: observation.confidence,
                obstructionFraction: observation.obstructionFraction, handlingEvidence: observation.handlingEvidence))
            observations.append("FRAME \(index): " + observation.observation)
        }
        return FrameAnswer(frames: frames, observation: observations.joined(separator: "; "), activity: "unknown")
    }

    func inspectIndependentFrames(samples: [VisualFrameSample], indices: [Int]? = nil, intentionalFadeSamples: [Int],
                                  responseURL: URL) async throws -> (OrientationAnswer, [CameraInteractionFrame]) {
        var purposes: [OrientationFrame] = []
        var contacts: [CameraInteractionFrame] = []
        // Keep the current image's prefix hot. These are still separate,
        // unchanged prompts; neither observer sees the other one's answer.
        for index in indices ?? Array(samples.indices) {
            let purpose = try await inspectPurpose(samples: samples, indices: [index],
                responseURL: responseURL.deletingPathExtension().appendingPathExtension("purpose.json"))
            purposes += purpose.frames
            if !intentionalFadeSamples.contains(index) {
                contacts += try await inspectCameraInteraction(samples: samples, indices: [index],
                    responseURL: responseURL.deletingPathExtension().appendingPathExtension("contact.json"))
            }
        }
        return (OrientationAnswer(frames: purposes), contacts)
    }

    func inspectPurpose(samples: [VisualFrameSample], indices: [Int], responseURL: URL) async throws -> OrientationAnswer {
        // Real contact-sheet requests repeated the first cell's description
        // and missed later 90-degree camera turns. Inspect each exact image
        // independently; no negative/positive label is supplied to the observer.
        struct SingleFrame: Decodable {
            var scene: String
            var orientation: SceneOrientation
            var opaqueCoverFraction: Double
            var purpose: EditorialPurpose
            var purposeConfidence: Double
            var purposeEvidence: String
        }
        let prompt = """
        Inspect this SINGLE documentary image literally. Describe its main visible subject. Is the scene upright, sideways (about 90 degrees), inverted (about 180 degrees), or unclear? Judge sky, ground and people relative to the image edges, not one object. opaqueCoverFraction means accidental opaque material hiding the view, not a normal filmed subject.
        Assess visible editorial purpose, without inventing a story: action (readable human or animal activity, gear interaction, or travel), reaction (readable human response), portrait (recognizable face/person intentionally framed), detail (clearly framed relevant object with legible features), establishing (a coherent, readable view of a place or route), none (incidental ground/fence/fragmented body edge with no readable subject or activity), unclear. A cropped torso/coat at the edge, scraps of bank/vegetation and a fence do NOT become a portrait or an establishing shot merely because they are visible. Ordinary greenery alone is not evidence of a composed scenery view. A downward accidental view with no focal subject has purpose none. Conversely, hands visibly operating a fishing rod, opening equipment, steering, a passenger in a vehicle, a person walking along a visible route, and a coherent river/road view can have clear purpose. Do not require a face in purposeful POV or equipment detail. Wildlife and landscapes do not need human interaction to be useful: judge whether the animal, activity or place is visibly readable and coherently framed. Do not confuse prettiness with narrative usefulness. purposeEvidence must name what the image actually reveals and how its framing supports the selected purpose; for none describe what is missing. Use short literal English statements. Return only JSON.
        purposeConfidence measures certainty that your selected category is correct, including none. It is NOT an amount of usefulness. A clearly observed absence of purpose can have high confidence. If the image does not establish a category, use unclear and low confidence. Never increase confidence to make a clip pass.
        """
        let fields: [String: Any] = ["scene": ["type": "string", "maxLength": 120],
            "orientation": ["type": "string", "enum": ["upright", "sideways", "inverted", "unclear"]],
            "opaqueCoverFraction": ["type": "number", "minimum": 0, "maximum": 1],
            "purpose": ["type": "string", "enum": ["action", "reaction", "portrait", "detail", "establishing", "none", "unclear"]],
            "purposeConfidence": ["type": "number", "minimum": 0, "maximum": 1],
            "purposeEvidence": ["type": "string", "maxLength": 160]]
        var frames: [OrientationFrame] = []
        for index in indices {
            guard samples.indices.contains(index) else { throw URLError(.cannotParseResponse) }
            let sample = samples[index]
            let body: [String: Any] = ["model": model, "stream": false, "think": false,
                "options": ["num_ctx": 4096, "num_predict": 300, "temperature": 0, "seed": 0],
                "format": ["type": "object", "required": fields.keys.sorted(), "properties": fields],
                "messages": [["role": "user", "content": prompt, "images": [sample.jpegBase64]]]]
            let content = try await modelAnswer(body: body, responseURL: responseURL.deletingPathExtension().appendingPathExtension("frame-\(index).json"),
                progressDetail: "Оцениваю содержание · кадр \(index + 1) из \(samples.count)")
            var observation = try JSONDecoder().decode(SingleFrame.self, from: Data(content.utf8))
            if observation.purpose == .unclear || observation.purposeConfidence < 0.75 {
                // One targeted re-observation addresses the unresolved
                // classification. Keep the same model and exact image, record
                // both replies, and retain uncertainty when this cannot help.
                var clarification = body
                clarification["messages"] = [["role": "user", "images": [sample.jpegBase64],
                    "content": prompt + " The previous observation did not establish the purpose category with sufficient certainty. Inspect this image again independently. Distinguish no useful subject (none) from inability to tell (unclear). Confidence is certainty of the chosen category, including a negative finding, not how useful or attractive the shot is. State only visible evidence. If it remains ambiguous, preserve that uncertainty."]]
                let clarified = try await modelAnswer(body: clarification,
                    responseURL: responseURL.deletingPathExtension().appendingPathExtension("frame-\(index)-clarified.json"),
                    progressDetail: "Уточняю неопределённую оценку содержания · кадр \(index + 1) из \(samples.count)")
                observation = try JSONDecoder().decode(SingleFrame.self, from: Data(clarified.utf8))
            }
            frames.append(.init(index: index, scene: observation.scene, orientation: observation.orientation,
                opaqueCoverFraction: observation.opaqueCoverFraction, purpose: observation.purpose,
                purposeConfidence: observation.purposeConfidence, purposeEvidence: observation.purposeEvidence))
        }
        return OrientationAnswer(frames: frames)
    }

    private func inspectCameraInteraction(samples: [VisualFrameSample], indices: [Int], responseURL: URL) async throws -> [CameraInteractionFrame] {
        struct SingleFrame: Decodable {
            var interaction: CameraInteraction
            var confidence: Double
            var evidence: String
            enum CodingKeys: String, CodingKey {
                case evidence = "a_observation", interaction = "b_interaction", confidence = "c_confidence"
            }
        }
        // Paired real-scene checks found 8B emits percentages; the same wording
        // changed 2B's interaction categories, so preserve the other models' prompts.
        let probabilityScale = model == AIAnalysisProfile.resolve(mode: .quality).modelID
            ? " c_confidence must be a decimal probability from 0.0 to 1.0 inclusive, never a percentage: for example 0.95, not 95 or 100." : ""
        let prompt = "Inspect the SINGLE image for visible hand interaction. First write a_observation: a literal English sentence about the visible hands and their targets, or their absence. If no hands are visible, say so and describe the visible scene; do not invent fingers or an action just to fill this field. If a possible hand or its target is obscured, explain that uncertainty. Then choose b_interaction and c_confidence.\(probabilityScale) Confidence measures how well the CHOSEN CLASS describes this image, including none; it is not the probability that camera manipulation exists. Use low confidence when the visible evidence is ambiguous. A bare class label is never an observation. Classify camera-adjustment only for a clearly foreshortened near-camera reach straight toward the filming lens, visible contact with it, or manipulation of the filming camera. This can occur while most of the scene remains visible; covered area alone is not proof. Classify social-gesture for a wave, thumbs-up, peace sign or other communication toward the viewer without manipulating the camera. A gesture addressed to the viewer is not camera adjustment. Classify equipment-work when the hand visibly grips/operates an identifiable fishing rod, steering wheel, bag, case, helmet or other filmed equipment. POV hands and an angled scene alone are not camera-adjustment. Classify none when no hand interaction is visible; use unclear when the target cannot be identified. The observation must describe the actual presence or absence of hands and interaction. A class label such as equipment-work or none is not evidence. Do not invent contact with a hidden camera. Return only JSON."
        let fields: [String: Any] = ["a_observation": ["type": "string", "minLength": 12, "maxLength": 180],
            "b_interaction": ["type": "string", "enum": ["camera-adjustment", "equipment-work", "social-gesture", "none", "unclear"]],
            "c_confidence": ["type": "number", "minimum": 0, "maximum": 1]]
        var result: [CameraInteractionFrame] = []
        for index in indices.sorted() {
            guard samples.indices.contains(index) else { throw URLError(.cannotParseResponse) }
            var accepted: CameraInteractionFrame?
            for attempt in 0..<2 {
                let body: [String: Any] = ["model": model, "stream": false, "think": false,
                    "options": ["num_ctx": 4096, "num_predict": 160, "temperature": 0, "seed": 0],
                    "format": ["type": "object", "required": fields.keys.sorted(), "properties": fields],
                    "messages": [["role": "user", "content": prompt + (attempt == 0 ? "" : " OBSERVATION REPAIR: The prior answer lacked a literal observation. State what the image actually shows about hands and their target. When no hands are visible, explicitly describe their absence; when obscured, describe the ambiguity. Do not invent a hand, use a bare label, or raise confidence just to pass validation."), "images": [samples[index].jpegBase64]]]]
                let content = try await modelAnswer(body: body,
                    responseURL: responseURL.deletingPathExtension().appendingPathExtension("frame-\(index)-attempt-\(attempt).json"),
                    progressDetail: "Проверяю движения камеры · кадр \(index + 1) из \(samples.count), попытка \(attempt + 1)")
                let observation = try JSONDecoder().decode(SingleFrame.self, from: Data(content.utf8))
                let frame = CameraInteractionFrame(index: index, interaction: observation.interaction,
                    confidence: observation.confidence, evidence: observation.evidence)
                if Self.literalInteractionEvidence(frame) { accepted = frame; break }
            }
            guard var accepted else { throw URLError(.cannotParseResponse) }
            if accepted.interaction == .cameraAdjustment {
                // The interaction classifier hallucinated a lens reach in
                // ordinary game, phone and resting-hand images. A separate
                // spatial observation must identify the recording viewpoint
                // as the target before that claim can reject useful footage.
                // Disagreement without a clear alternative remains uncertain.
                let target = try await inspectHandTarget(sample: samples[index],
                    responseURL: responseURL.deletingPathExtension()
                        .appendingPathExtension("target-frame-\(index).json"))
                guard let corroborated = Self.retainingCameraTargetUncertainty(accepted, target: target) else {
                    throw URLError(.cannotParseResponse)
                }
                accepted = corroborated
            }
            result.append(accepted)
        }
        return result
    }

    private func inspectHandTarget(sample: VisualFrameSample, responseURL: URL) async throws -> HandTargetObservation {
        let prompt = "Describe the visible hands in this single image, their depth in the scene, and the objects they touch or point toward. First write a literal observation. Then identify the interaction target. Use filmed-object when hands are at the depth of a visible game, bottle, phone, leg, steering wheel, bag or other scene object. Holding a phone or camera visible within the scene is filmed-object, not the recording lens. Use filming-lens only when a near-camera hand or forearm clearly extends from the person toward this recording viewpoint, with visible perspective enlargement/foreshortening or physical contact at the image plane. A distant hand, hand on a knee, game piece, or screen is not such a reach. Use social-gesture for a wave or sign without a lens reach; none for no visible hand interaction; unknown when the target cannot be identified. Do not infer a reach merely because a palm faces the viewer. Return observation, target, confidence as JSON. Do not infer anything outside the image."
        let fields: [String: Any] = [
            "observation": ["type": "string", "maxLength": 220],
            "target": ["type": "string", "enum": ["filmed-object", "filming-lens", "social-gesture", "none", "unknown"]],
            "confidence": ["type": "number", "minimum": 0, "maximum": 1]]
        let body: [String: Any] = ["model": model, "stream": false, "think": false,
            "options": ["num_ctx": 4096, "num_predict": 250, "temperature": 0, "seed": 0],
            "format": ["type": "object", "required": ["observation", "target", "confidence"], "properties": fields],
            "messages": [["role": "user", "content": prompt, "images": [sample.jpegBase64]]]]
        let content = try await modelAnswer(body: body, responseURL: responseURL,
            progressDetail: "Уточняю положение рук относительно камеры",
            repairInstruction: "OBSERVATION FORMAT: observation must describe the visible hand and target, absence or uncertainty in at least six words. Do not invent a target or increase confidence.",
            validateObservation: { content in
                let target = try JSONDecoder().decode(HandTargetObservation.self, from: Data(content.utf8))
                guard target.confidence.isFinite, (0...1).contains(target.confidence),
                      target.observation.split(whereSeparator: \.isWhitespace).count >= 6 else { throw URLError(.cannotParseResponse) }
            })
        return try JSONDecoder().decode(HandTargetObservation.self, from: Data(content.utf8))
    }

    private func inspectOrientation(samples: [VisualFrameSample], indices: [Int], responseURL: URL) async throws -> OrientationAnswer {
        // Keep the neutral physical observer separate from editorial judgement.
        // Combining the questions made normal downward equipment close-ups
        // falsely "sideways". The isolated prompt passed real rotated footage
        // and normal fishing/gear controls. Purpose never supplies rotation proof.
        struct SingleFrame: Decodable {
            var scene: String
            var orientation: SceneOrientation
            var opaqueCoverFraction: Double
            var orientationBasis: OrientationBasis
        }
        let prompt = "Describe the SINGLE attached image literally. Is the entire scene upright, sideways (about 90 degrees), inverted (about 180 degrees), or unclear? A world-reference requires a visible gravity reference: a horizon, standing person's head above feet, upright architecture, or trees rooted in ground with crowns toward sky. Describe that reference and its direction relative to the image edges in scene. An angled bag, rod, hand, fabric, wheel, or ground texture alone does NOT prove scene rotation. A downward close-up of hands working on identifiable equipment with no visible world reference is overhead-detail, orientation unclear. Other views with no reliable reference are uncertain, orientation unclear. Never infer inversion merely from a close-up object angle. Estimate opaqueCoverFraction for accidental lens cover, not normal equipment or hands. Return JSON with scene, orientation, orientationBasis (world-reference, overhead-detail, uncertain), opaqueCoverFraction."
        let fields: [String: Any] = ["scene": ["type": "string", "maxLength": 120],
            "orientation": ["type": "string", "enum": ["upright", "sideways", "inverted", "unclear"]],
            "orientationBasis": ["type": "string", "enum": ["world-reference", "overhead-detail", "uncertain"]],
            "opaqueCoverFraction": ["type": "number", "minimum": 0, "maximum": 1]]
        var frames: [OrientationFrame] = []
        for index in indices {
            guard samples.indices.contains(index) else { throw URLError(.cannotParseResponse) }
            let sample = samples[index]
            let body: [String: Any] = ["model": model, "stream": false, "think": false,
                "options": ["num_ctx": 4096, "num_predict": 180, "temperature": 0, "seed": 0],
                "format": ["type": "object", "required": ["scene", "orientation", "orientationBasis", "opaqueCoverFraction"], "properties": fields],
                "messages": [["role": "user", "content": prompt, "images": [sample.jpegBase64]]]]
            let content = try await modelAnswer(body: body, responseURL: responseURL.deletingPathExtension().appendingPathExtension("frame-\(index).json"),
                progressDetail: "Проверяю положение изображения · кадр \(index + 1) из \(samples.count)")
            let observation = try JSONDecoder().decode(SingleFrame.self, from: Data(content.utf8))
            frames.append(.init(index: index, scene: observation.scene, orientation: observation.orientation,
                opaqueCoverFraction: observation.opaqueCoverFraction, orientationBasis: observation.orientationBasis))
        }
        return OrientationAnswer(frames: frames)
    }

    func modelAnswer(body: [String: Any], responseURL: URL, progressDetail: String = "Проверяю выбранные кадры",
                     responseFieldOrder: [String]? = nil,
                     responseArrayItemFieldOrders: [String: [String]] = [:],
                     repairInstruction: String = "",
                     validateObservation: (@Sendable (String) throws -> Void)? = nil) async throws -> String {
        let repair = LocalModelResponseValidation.repairBody(body, additionalInstruction: repairInstruction)
        // Both recipes have exact, separately verifiable request/response pairs.
        // A previously repaired observation never needs to repeat its bad reply.
        var originalCacheInvalid = false
        for (index, recipe) in [body, repair].enumerated() {
            do {
                if let content = try await modelAnswerAttempt(body: recipe, responseURL: responseURL,
                    progressDetail: progressDetail, responseFieldOrder: responseFieldOrder, responseArrayItemFieldOrders: responseArrayItemFieldOrders,
                    cacheOnly: true, validateObservation: validateObservation) { return content }
            } catch {
                guard (error as? URLError)?.code == .cannotParseResponse || error is DecodingError else { throw error }
                // A saved malformed observation is a known failure, not a cache
                // miss. Do not resend its unchanged prompt before the repair.
                guard index == 0 else { throw error }
                originalCacheInvalid = true
            }
        }
        if originalCacheInvalid {
            guard (FilmProcessContext.current?.responseRepairAttempts ?? 1) > 0 else { throw URLError(.cannotParseResponse) }
            try Task.checkCancellation()
            return try await modelAnswerAttempt(body: repair, responseURL: responseURL,
                progressDetail: "Уточняю формат сохранённого ответа · " + progressDetail,
                responseFieldOrder: responseFieldOrder, responseArrayItemFieldOrders: responseArrayItemFieldOrders,
                cacheOnly: false, validateObservation: validateObservation)!
        }
        do {
            return try await modelAnswerAttempt(body: body, responseURL: responseURL,
                progressDetail: progressDetail, responseFieldOrder: responseFieldOrder, responseArrayItemFieldOrders: responseArrayItemFieldOrders,
                cacheOnly: false, validateObservation: validateObservation)!
        } catch {
            guard (error as? URLError)?.code == .cannotParseResponse || error is DecodingError else { throw error }
            guard (FilmProcessContext.current?.responseRepairAttempts ?? 1) > 0 else { throw error }
            try Task.checkCancellation()
            return try await modelAnswerAttempt(body: repair, responseURL: responseURL,
                progressDetail: "Уточняю формат ответа · " + progressDetail,
                responseFieldOrder: responseFieldOrder, responseArrayItemFieldOrders: responseArrayItemFieldOrders, cacheOnly: false, validateObservation: validateObservation)!
        }
    }

    private func modelAnswerAttempt(body: [String: Any], responseURL: URL, progressDetail: String,
                                    responseFieldOrder: [String]?,
                                    responseArrayItemFieldOrders: [String: [String]],
                                    cacheOnly: Bool,
                                    validateObservation: (@Sendable (String) throws -> Void)?) async throws -> String? {
        var body = try FilmProcessContext.requestBody(LocalVisionMessageEncoding.separatingImages(in: body))
        if var options = body["options"] as? [String: Any] {
            // New frozen jobs group one-image observations separately from
            // temporal comparisons. Honor that stage's verified allocation;
            // legacy standalone callers retain their former 8K minimum.
            let minimum = FilmProcessContext.minimumContextTokens(for: body) ?? 8192
            options["num_ctx"] = max(minimum, options["num_ctx"] as? Int ?? minimum)
            body["options"] = options
            body["keep_alive"] = "10m"
        }
        let legacyBody = body
        if answerTransport == nil { body["stream"] = true }
        var request = URLRequest(url: LocalAIRuntimeConfiguration.baseURL.appendingPathComponent("api/chat"))
        request.httpMethod = "POST"
        let remaining = deadlineUptime.map { $0 - workUptime() } ?? 120
        request.timeoutInterval = max(0.1, min(120, remaining))
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try LocalAIRequestEncoding.data(body, responseFieldOrder: responseFieldOrder, responseArrayItemFieldOrders: responseArrayItemFieldOrders)
        try FileManager.default.createDirectory(at: responseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Exact local requests and responses let an audit inspect the images
        // actually received by the model, rather than trusting a summary.
        let requestData = request.httpBody!
        let requestURL = responseURL.deletingPathExtension().appendingPathExtension("request.json")
        // Earlier cache writers could overwrite a request before comparing it
        // with its old response. Their pairs have no reliable provenance.
        let exactCache = responseURL.deletingLastPathComponent().appendingPathComponent("ByExactRequestV3")
        try FileManager.default.createDirectory(at: exactCache, withIntermediateDirectories: true)
        let modelDigest: String?
        if let modelDigestOverride { modelDigest = modelDigestOverride }
        else if answerTransport != nil { modelDigest = "injected-transport" }
        else { modelDigest = await LocalAIModelManager.shared.installedModelDigest(model: model) }
        if answerTransport == nil { try FilmProcessContext.current?.validate(model: model, digest: modelDigest) }
        let scope = Self.observationVersion + "|" + (evidenceContext ?? "exact-request") + "|"
        var identity = Data((scope + (modelDigest ?? UUID().uuidString)).utf8)
        identity.append(requestData)
        let digest = SHA256.hash(data: identity).map { String(format: "%02x", $0) }.joined()
        let exactReceipt = exactCache.appendingPathComponent(digest + ".json")
        let exactRequest = exactCache.appendingPathComponent(digest + ".request.json")
        // Rejected, completed answers are not successful checks. Remember their
        // exact recipe separately so restarting a job cannot resend the same
        // deterministically invalid answer before its targeted repair.
        let rejectedCache = responseURL.deletingLastPathComponent().appendingPathComponent("RejectedByExactRequestV1")
        func verifiedContent(_ data: Data) throws -> String {
            let envelope = try JSONDecoder().decode(Envelope.self, from: data)
            guard envelope.done == true, envelope.done_reason == "stop", envelope.model == model,
                  let content = envelope.message?.content else { throw URLError(.cannotParseResponse) }
            try LocalModelResponseValidation.validate(content, schema: body["format"] as? [String: Any])
            // Caller invariants must hold before caching, progress or reuse.
            // JSON shape alone does not establish a usable observation.
            try validateObservation?(content)
            return content
        }
        // Streaming changes delivery only. A complete old response remains
        // reusable when every model input is byte-identical except `stream`.
        // Retain the original pair so its transport provenance is not relabelled.
        let legacyData = try LocalAIRequestEncoding.data(legacyBody, responseFieldOrder: responseFieldOrder, responseArrayItemFieldOrders: responseArrayItemFieldOrders)
        for candidateData in requestData == legacyData ? [requestData] : [requestData, legacyData] {
            var candidateIdentity = Data((scope + (modelDigest ?? UUID().uuidString)).utf8)
            candidateIdentity.append(candidateData)
            let key = SHA256.hash(data: candidateIdentity).map { String(format: "%02x", $0) }.joined()
            if (try? Data(contentsOf: exactCache.appendingPathComponent(key + ".request.json"))) == candidateData,
               let data = try? Data(contentsOf: exactCache.appendingPathComponent(key + ".json")) {
                let content: String
                do { content = try verifiedContent(data) }
                catch {
                    PerformanceTrace.current?.event("review.request.cache-invalid", fields: ["model": model, "key": key, "operation": progressDetail])
                    throw error
                }
                if FileManager.default.fileExists(atPath: responseURL.path) { try FileManager.default.removeItem(at: responseURL) }
                try candidateData.write(to: requestURL, options: .atomic)
                try data.write(to: responseURL, options: .atomic)
                await observationProgress?.record(key)
                await requestProgress?(FilmBuildProgress(.verifying, detail: "Использую сохранённый ответ · " + progressDetail))
                PerformanceTrace.current?.event("review.request.cache", fields: ["model": model, "key": key, "origin": "reused", "operation": progressDetail])
                return content
            }
            if (try? Data(contentsOf: rejectedCache.appendingPathComponent(key + ".request.json"))) == candidateData,
               let data = try? Data(contentsOf: rejectedCache.appendingPathComponent(key + ".json")),
               let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
               envelope.done == true, envelope.model == model,
               ["stop", "length"].contains(envelope.done_reason ?? ""), envelope.message?.content != nil {
                do { _ = try verifiedContent(data) }
                catch {
                    PerformanceTrace.current?.event("review.request.known-failure", fields: ["model": model, "key": key, "operation": progressDetail])
                    await requestProgress?(FilmBuildProgress(.verifying, detail: "Сохранённый ответ требует исправления · " + progressDetail))
                    throw error
                }
            }
        }
        if cacheOnly { return nil }
        PerformanceTrace.current?.event("review.request.cache", fields: ["model": model, "key": digest, "origin": "computed", "operation": progressDetail])
        guard deadlineUptime.map({ $0 > workUptime() }) ?? true else { throw LocalAIInferenceFailure(model: model, reason: "текущая проверка не завершилась вовремя") }
        // Legacy raw pairs remain available for audit, never for certification.
        // Keep both sides before replacing a path, including on network failure.
        if FileManager.default.fileExists(atPath: responseURL.path) {
            let archive = responseURL.deletingLastPathComponent().appendingPathComponent("Superseded/" + UUID().uuidString)
            try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: responseURL, to: archive.appendingPathComponent(responseURL.lastPathComponent))
            if FileManager.default.fileExists(atPath: requestURL.path) {
                try FileManager.default.moveItem(at: requestURL, to: archive.appendingPathComponent(requestURL.lastPathComponent))
            }
        }
        try requestData.write(to: requestURL, options: .atomic)
        let (data, response) = try await transportResponse(for: request, detail: progressDetail)
        try data.write(to: responseURL, options: .atomic)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        let content: String
        do { content = try verifiedContent(data) }
        catch {
            // A transport failure, incomplete stream or wrong model is not a
            // deterministic answer. It must remain recoverable on the same model.
            if let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
               envelope.done == true, envelope.model == model,
               ["stop", "length"].contains(envelope.done_reason ?? ""), envelope.message?.content != nil {
                try FileManager.default.createDirectory(at: rejectedCache, withIntermediateDirectories: true)
                try requestData.write(to: rejectedCache.appendingPathComponent(digest + ".request.json"), options: .atomic)
                try data.write(to: rejectedCache.appendingPathComponent(digest + ".json"), options: .atomic)
                PerformanceTrace.current?.event("review.request.rejected", fields: ["model": model, "key": digest, "operation": progressDetail])
            }
            throw error
        }
        try requestData.write(to: exactRequest, options: .atomic)
        try data.write(to: exactReceipt, options: .atomic)
        await observationProgress?.record(digest)
        await requestProgress?(FilmBuildProgress(.verifying, detail: "Наблюдение сохранено · " + progressDetail))
        try await AutonomousJobContext.store?.recordInferenceProgress()
        return content
    }

    private func transportResponse(for request: URLRequest, detail: String) async throws -> (Data, URLResponse) {
        if answerTransport == nil {
            await requestProgress?(FilmBuildProgress(.verifying, detail: detail))
            let observer = requestProgress
            return try await inferenceClient.response(for: request, progress: { update in
                var contextual = update
                contextual.detail = detail + " · " + (update.detail ?? "")
                await observer?(contextual)
            },
                maximumDuration: deadlineUptime.map { $0 - workUptime() }, preservingRequestBody: true)
        }
        for attempt in 0..<2 {
            do {
                var request = request
                if let deadlineUptime {
                    let remaining = deadlineUptime - workUptime()
                    guard remaining > 0 else { throw URLError(.timedOut) }
                    request.timeoutInterval = min(request.timeoutInterval, remaining)
                }
                let attemptDetail = attempt == 0 ? detail : "Повторяю запрос после сбоя · " + detail
                let result = try await transportAttempt(for: request, detail: attemptDetail)
                // Ollama reports a model startup timeout as HTTP 500 rather
                // than a URLSession timeout. Retry the same evidence once;
                // never turn a failed startup into a visual verdict.
                if attempt == 0, let http = result.1 as? HTTPURLResponse, http.statusCode == 500,
                   let body = try? JSONSerialization.jsonObject(with: result.0) as? [String: Any],
                   let message = body["error"] as? String,
                   message.lowercased().contains("timed out waiting for llama-server to start") {
                    try Task.checkCancellation()
                    continue
                }
                return result
            } catch {
                try Task.checkCancellation()
                guard attempt == 0, let urlError = error as? URLError,
                      [.timedOut, .networkConnectionLost, .cannotConnectToHost].contains(urlError.code) else { throw error }
                // Retry exactly the same evidence request once. A transport
                // failure is not an observation about the selected footage.
            }
        }
        throw URLError(.networkConnectionLost)
    }

    private func transportAttempt(for request: URLRequest, detail: String) async throws -> (Data, URLResponse) {
        let observer = requestProgress
        await observer?(FilmBuildProgress(.verifying, detail: detail))
        let started = ProcessInfo.processInfo.systemUptime
        let heartbeat = Task {
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                guard !Task.isCancelled else { return }
                let seconds = Int(ProcessInfo.processInfo.systemUptime - started)
                await observer?(FilmBuildProgress(.verifying,
                    detail: "\(detail) · ожидаю ответ \(seconds) с", isHeartbeat: true))
            }
        }
        do {
            let result: (Data, URLResponse)
            if let answerTransport { result = try await answerTransport(request) }
            else { result = try await URLSession.shared.data(for: request) }
            heartbeat.cancel()
            await heartbeat.value
            try Task.checkCancellation()
            await observer?(FilmBuildProgress(.verifying, detail: "Получен ответ · " + detail))
            return result
        } catch {
            heartbeat.cancel()
            await heartbeat.value
            throw error
        }
    }

    /// Refuse the observed bad interval and all overlapping mining windows.
    /// Other ranges from that recording remain eligible. The original ranker
    /// and automatic assembly choose replacements and preserve chronology.
    static func rejectedCandidateIDs(_ assessments: [ShotContentAssessment], analyses: [AnalysisResult]) -> Set<UUID> {
        Set(analyses.flatMap(\.directorCandidates).filter { candidate in
            assessments.contains { assessment in
                assessment.rejectsRange && assessment.assetID == candidate.assetID
                    && candidate.sourceStart < assessment.sourceStart + assessment.sourceDuration
                    && candidate.sourceStart + candidate.sourceDuration > assessment.sourceStart
            }
        }.map(\.id))
    }

    static func repairCandidateIDs(_ assessments: [ShotContentAssessment], analyses: [AnalysisResult]) -> Set<UUID> {
        rejectedCandidateIDs(assessments.filter(\.requiresConcreteRepair), analyses: analyses)
    }

    /// An isolated unknown is not a negative observation and cannot condemn
    /// neighboring footage. When the verifier has established usable content
    /// elsewhere, let the native assembler try another exact candidate rather
    /// than repeatedly retaining a range it cannot certify. A wholly missing
    /// verifier remains a visible delivery failure, not a random reselection.
    static func uncertifiedCandidateIDs(_ assessments: [ShotContentAssessment], timeline: Timeline) -> Set<UUID> {
        guard assessments.contains(where: { $0.status == .usable && $0.confidence >= 0.75
            && $0.editorialPurpose.flatMap(EditorialPurpose.init(rawValue:))?.isUseful == true }) else { return [] }
        return Set(timeline.items.compactMap { item in
            guard let candidateID = item.candidateID, item.overlay == nil, item.kind == .video,
                  assessments.contains(where: { review in
                      review.itemID == item.id && review.assetID == item.assetID
                          && abs(review.sourceStart - item.sourceStart) < 0.000_001
                          && abs(review.sourceDuration - item.sourceDuration) < 0.000_001
                          // Zero confidence is a missing/failed probe, not
                          // uncertain visual evidence. Keep this cut for retry;
                          // the mandatory delivery check still cannot pass.
                          && review.confidence > 0
                          && (review.status == .uncertain || review.status == .unmotivated || review.confidence < 0.75)
                  }) else { return nil }
            return candidateID
        })
    }
}
