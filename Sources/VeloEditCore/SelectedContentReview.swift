import Foundation
import CryptoKit
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

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

    func passes(timeline: Timeline, assets: [MediaAsset] = []) -> Bool {
        guard renderSignature == EditorialRenderSignature.signature(timeline) else { return false }
        let items = timeline.items.filter { $0.overlay == nil && $0.kind == .video }
        return !items.isEmpty && items.allSatisfy { item in
            [("source", source), ("mp4", rendered)].allSatisfy { phase, observations in
                observations.contains { assessment in
                    assessment.itemID == item.id && assessment.assetID == item.assetID
                        && assessment.phase == phase
                        && (assets.isEmpty || assets.contains { $0.id == item.assetID && $0.contentHash == assessment.sourceContentHash })
                        && abs(assessment.sourceStart - item.sourceStart) < 0.000_001
                        && abs(assessment.sourceDuration - item.sourceDuration) < 0.000_001
                        && assessment.sampleTimes.count >= 5 && assessment.status == .usable && assessment.confidence >= 0.75
                        && assessment.editorialPurpose.flatMap(SelectedContentReviewer.EditorialPurpose.init(rawValue:))?.isUseful == true
                        && (phase != "source" || assessment.actionBoundary?.passes == true)
                }
            }
        }
    }
}

/// A bounded second look at the selected footage. It does not replace the
/// existing analysis/ranker, force an effect, or run a new source-wide scan.
struct SelectedContentReviewer: Sendable {
    static let version = "selected-content-v58-camera-target-corroboration"
    static func verificationModel(preferred: String) async -> String {
        // A tiny model is useful for broad indexing, but real clip checks
        // exposed contradictory/truncated verdicts. Do not silently certify
        // with it. Use an already installed stronger verifier; never download.
        guard preferred == "qwen3-vl:2b-instruct" else { return preferred }
        let runtime = OllamaVisionRuntime()
        if ProcessInfo.processInfo.physicalMemory >= 32 * 1_024 * 1_024 * 1_024,
           await runtime.isAvailable(model: "qwen3-vl:30b-a3b-instruct") { return "qwen3-vl:30b-a3b-instruct" }
        if await runtime.isAvailable(model: "qwen3-vl:8b-instruct") { return "qwen3-vl:8b-instruct" }
        return "qwen3-vl:4b-instruct"
    }
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
    static func literalInteractionEvidence(_ frame: CameraInteractionFrame) -> Bool {
        let evidence = frame.evidence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !evidence.isEmpty else { return false }
        guard frame.interaction != .none && frame.interaction != .unclear else { return true }
        // A real steering frame returned camera-adjustment with the entire
        // evidence field set to "equipment-work". An enum label, even with
        // high confidence, is not an independent observation of contact.
        let compact = evidence.lowercased().filter(\.isLetter)
        return !["cameraadjustment", "equipmentwork", "socialgesture", "none", "unclear"].contains(compact)
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
        } else if useful.count >= majority && technical.status == .usable {
            result.editorialPurpose = useful.first!.purpose!.rawValue
            result.confidence = min(result.confidence, useful.compactMap(\.purposeConfidence).min() ?? 0)
        } else {
            result.status = .uncertain
            result.editorialPurpose = EditorialPurpose.unclear.rawValue
        }
        return result
    }

    static func confirmHandling(_ primary: FrameAnswer, observer: OrientationAnswer,
                                contacts: [CameraInteractionFrame] = [], intentionalFadeSamples: [Int] = []) -> FrameAnswer? {
        guard observer.frames.count == 5, Set(observer.frames.map(\.index)) == Set(0..<5),
              observer.frames.allSatisfy({ !$0.scene.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                  && $0.opaqueCoverFraction.isFinite && (0...1).contains($0.opaqueCoverFraction) }),
              Set(contacts.map(\.index)).count == contacts.count,
              contacts.allSatisfy({ (0..<5).contains($0.index) && $0.confidence.isFinite && (0...1).contains($0.confidence)
                  && literalInteractionEvidence($0) }) else { return nil }
        let observations = Dictionary(uniqueKeysWithValues: observer.frames.map { ($0.index, $0) })
        let interactions = Dictionary(uniqueKeysWithValues: contacts.map { ($0.index, $0) })
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
            guard (observed.orientation != .unclear
                    && ((!rotated && !primaryRotation) || observed.orientationBasis == .worldReference))
                    || overheadGear else { return nil }
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
                    if !readableGear && unsupportedRotations >= 2 { result.frames[index].content = .uncertain }
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
            "FRAME \($0.index): \($0.orientation.rawValue)"
        }.joined(separator: "; ") + ". " + (observer.frames.first?.scene ?? "")
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
        let uncertain = inspected.contains { $0.content == .uncertain || $0.confidence < 0.75
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

    func review(timeline: Timeline, assets: [MediaAsset], renderedURL: URL? = nil,
                progress: FilmBuildProgressHandler? = nil) async throws -> [ShotContentAssessment] {
        let items = timeline.items.filter { $0.overlay == nil && $0.kind == .video }
        guard !items.isEmpty else { return [] }
        let byID = Dictionary(assets.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let phase = renderedURL == nil ? "source" : "mp4"
        let frameCache = FrameCache(rootURL: cacheURL.appendingPathComponent("SelectedContentFrames"))
        let root = cacheURL.appendingPathComponent("SelectedContentReview")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var available = await OllamaVisionRuntime().isAvailable(model: model)
        var consecutiveFailures = 0
        var result: [ShotContentAssessment] = []
        for (index, item) in items.enumerated() {
            try Task.checkCancellation()
            guard let assetID = item.assetID, let asset = byID[assetID] else { continue }
            let fractions = [0.02, 0.25, 0.5, 0.75, 0.98]
            let times = fractions.map { fraction in
                renderedURL == nil ? item.sourceStart + item.sourceDuration * fraction
                    : TimelineTiming.playbackTime(forTimelineTime: item.timelineStart + item.timelineDuration * fraction, timeline: timeline)
            }
            let identity = renderedURL.map { FrameCacheKey.sourceIdentity(url: $0, contentHash: EditorialRenderSignature.signature(timeline)) }
                ?? FrameCacheKey.sourceIdentity(url: asset.originalURL, contentHash: asset.contentHash)
            let key = EditorialIdentity.hash("\(Self.version)|\(model)|\(phase)|\(identity)|\(times)")
            let receipt = root.appendingPathComponent(key + ".json")
            var assessment = ShotContentAssessment(itemID: item.id, assetID: assetID, sourceContentHash: asset.contentHash, sourceStart: item.sourceStart,
                sourceDuration: item.sourceDuration, sampleTimes: times, phase: phase, model: model, cacheKey: key,
                status: .uncertain, confidence: 0, obstructedSamples: [],
                observation: "Локальная проверка содержания недоступна", activity: "unknown")
            await progress?(FilmBuildProgress(.verifying, completed: index, total: items.count,
                detail: phase == "source" ? "Проверяю содержание выбранных исходных участков" : "Проверяю содержание итогового MP4"))
            if let data = try? Data(contentsOf: receipt), let cached = try? JSONDecoder().decode(Answer.self, from: data),
               Self.valid(cached) {
                assessment = Self.applying(cached, to: assessment)
            } else if available {
                do {
                    let samples = try await AdaptiveFrameSampler().selectedContentSamples(url: renderedURL ?? asset.originalURL,
                        sourceHash: identity, timestamps: times, frameCache: frameCache)
                    guard samples.count == times.count,
                          zip(samples, times).allSatisfy({ abs(($0.0.actualTimestamp ?? $0.0.timestamp) - $0.1) <= 0.1 }) else {
                        throw URLError(.cannotDecodeContentData)
                    }
                    let exemptions = renderedURL == nil ? [] : times.enumerated().compactMap { index, time -> Int? in
                        let fade = FilmEndingFade(duration: timeline.endingFadeDuration,
                            movieDuration: AutomaticFilmDurationPolicy.renderedDuration(of: timeline), frameRate: timeline.frameRate)
                        return (fade?.opacity(at: time) ?? 1) < 0.35 ? index : nil
                    }
                    var answer = try await judge(samples: samples, intentionalFadeSamples: exemptions,
                        responseURL: cacheURL.appendingPathComponent("SelectedContentResponses").appendingPathComponent(key + ".json"))
                    if renderedURL == nil, answer.status == .usable {
                        let end = item.sourceStart + item.sourceDuration
                        let lastTime = max(0, (asset.metadata.duration ?? end) - 1 / max(24, asset.metadata.frameRate ?? 30))
                        let contextTimes = [max(0, item.sourceStart - 1)] + times
                            + [min(lastTime, end + 0.25), min(lastTime, end + 4)]
                        let context = try await AdaptiveFrameSampler().selectedContentSamples(url: asset.originalURL,
                            sourceHash: identity, timestamps: contextTimes, frameCache: frameCache)
                        guard context.count == 8,
                              zip(context, contextTimes).allSatisfy({ abs(($0.0.actualTimestamp ?? $0.0.timestamp) - $0.1) <= 0.1 }) else {
                            throw URLError(.cannotDecodeContentData)
                        }
                        let objectTimes = [1, 3, 5, 6, 7].map { contextTimes[$0] }
                        let objectSamples = try await AdaptiveFrameSampler().selectedContentSamples(url: asset.originalURL,
                            sourceHash: identity, timestamps: objectTimes, frameCache: frameCache, maximumSize: 1280)
                        answer = try Self.applyingBoundary(try await inspectActionBoundary(samples: context, objectSamples: objectSamples,
                            responseURL: cacheURL.appendingPathComponent("SelectedContentResponses").appendingPathComponent(key + ".action.json")), to: answer)
                    }
                    consecutiveFailures = 0
                    assessment = Self.applying(answer, to: assessment)
                    // Unknown results are retryable. A timeout cannot poison
                    // the persistent cache as a successful content review.
                    if answer.status != .uncertain {
                        try JSONEncoder().encode(answer).write(to: receipt, options: .atomic)
                    }
                } catch is CancellationError { throw CancellationError() }
                catch {
                    assessment.observation = "Содержание не проверено: \(error.localizedDescription)"
                    consecutiveFailures += 1
                    if consecutiveFailures >= 2 { available = false }
                }
            }
            result.append(assessment)
        }
        return result
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
        let prompt = """
        The image is a contact sheet of FIVE chronological frames of one documentary clip, labeled FRAME 0 through FRAME 4. Inspect all five cells. For each frame classify its MAIN visible content: event (recognizable people, activity, vehicle interior, meaningful detail), landscape (route/scenery), lens-cover (accidental opaque foreground concealing the scene), camera-handling (clear accidental camera adjustment/repositioning, e.g. upside-down selfie while rotating the camera; not an intended filmed activity), uncertain.
        Estimate obstructionFraction: fraction of the ENTIRE frame hidden by an accidental opaque foreground obstruction, 0 to 1. This is NOT the area occupied by a normal subject/object. A fishing rod, hands working with fishing equipment, opening a bag, a close portrait, steering hands, buggy roll cage, seat belts or passenger legs are normal event content. Do not count these as lens obstruction. If a hand/sleeve actually obscures only a small part of the scene, obstructionFraction is small, not 1. A tiny visible corner behind an opaque material hiding most of the scene does not mean the view is unobstructed.
        Do not mark normal walking/driving/paddling motion or purposeful work with gear as camera-handling. Use the sequence to distinguish camera adjustment from activity. observation: one concise Russian sentence of visible evidence. activity: short Russian activity or unknown. Give five frames with index, content, obstructionFraction, confidence. Return only JSON.
        Camera-handling needs VISIBLE proof, not an inference from subject motion. Set handlingEvidence to inverted-scene ONLY if the entire scene is upside down or rotated at least 90 degrees, to direct-lens-contact ONLY if a hand/face visibly contacts the lens/camera rather than fishing gear or another object, else none. With handlingEvidence none classify normal activity as event or landscape, never camera-handling. Camera motion alone and hands reaching toward the fishing rod are not proof of handling the camera. Do not invent hidden contact. Focus on the observable scene.
        Confirmed intentional final fade indices: \(intentionalFadeSamples). The planned fade itself is not an accidental obstruction. Inspect other cells independently.
        """
        let frameFields: [String: Any] = ["index": ["type": "integer", "minimum": 0, "maximum": 4],
            "content": ["type": "string", "enum": ["event", "landscape", "lens-cover", "camera-handling", "uncertain"]],
            "obstructionFraction": ["type": "number", "minimum": 0, "maximum": 1],
            "confidence": ["type": "number", "minimum": 0, "maximum": 1],
            "handlingEvidence": ["type": "string", "enum": ["none", "inverted-scene", "direct-lens-contact"]]]
        let fields: [String: Any] = [
            "frames": ["type": "array", "minItems": 5, "maxItems": 5,
                "items": ["type": "object", "additionalProperties": false, "required": frameFields.keys.sorted(), "properties": frameFields]],
            "observation": ["type": "string", "maxLength": 300], "activity": ["type": "string", "maxLength": 80]]
        let body: [String: Any] = ["model": model, "stream": false, "think": false, "keep_alive": "10m",
            "options": ["num_predict": 480, "num_ctx": 4096, "temperature": 0, "seed": 0, "repeat_penalty": 1.15],
            "format": ["type": "object", "additionalProperties": false, "required": fields.keys.sorted(), "properties": fields],
            "messages": [["role": "user", "content": prompt, "images": [try Self.contactSheet(samples)]]]]
        let content = try await modelAnswer(body: body, responseURL: responseURL)
        var frameAnswer = try JSONDecoder().decode(FrameAnswer.self, from: Data(content.utf8))
        for index in frameAnswer.frames.indices {
            frameAnswer.frames[index].cameraAdjustmentConfirmed = nil
            frameAnswer.frames[index].rotationConfirmed = nil
        }
        // Every selected frame gets an independent observation. A contact-sheet
        // model previously repeated the first cell and missed later rotations.
        let observer = try await inspectPurpose(samples: samples,
            responseURL: responseURL.deletingPathExtension().appendingPathExtension("purpose.json"))
        // Do not let the primary classifier decide whether the independent
        // contact observer runs: real footage passed as scenery despite a hand
        // reaching straight toward the lens at the cut.
        let contacts = try await inspectCameraInteraction(samples: samples,
            indices: samples.indices.filter { !intentionalFadeSamples.contains($0) },
            responseURL: responseURL.deletingPathExtension().appendingPathExtension("contact.json"))
        if frameAnswer.frames.contains(where: { $0.handlingEvidence != .none || $0.content == .cameraHandling })
            || contacts.contains(where: { $0.interaction == .cameraAdjustment && $0.confidence >= 0.9 }) {
            let orientation = try await inspectOrientation(samples: samples,
                responseURL: responseURL.deletingPathExtension().appendingPathExtension("orientation.json"))
            guard let confirmed = Self.confirmHandling(frameAnswer, observer: orientation,
                contacts: contacts, intentionalFadeSamples: intentionalFadeSamples) else { throw URLError(.cannotParseResponse) }
            frameAnswer = confirmed
        }
        guard let technical = Self.resolve(frameAnswer, intentionalFadeSamples: intentionalFadeSamples),
              let answer = Self.applyingPurpose(observer, to: technical, intentionalFadeSamples: intentionalFadeSamples), Self.valid(answer) else {
            throw URLError(.cannotParseResponse)
        }
        return answer
    }

    private func inspectPurpose(samples: [VisualFrameSample], responseURL: URL) async throws -> OrientationAnswer {
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
        Assess visible editorial purpose, without inventing a story: action (readable person/gear interaction or travel activity), reaction (readable human response), portrait (recognizable face/person intentionally framed), detail (clearly framed relevant object with legible features), establishing (a coherent, readable view of a place or route), none (incidental ground/fence/fragmented body edge with no readable subject or activity), unclear. A cropped torso/coat at the edge, scraps of bank/vegetation and a fence do NOT become a portrait or an establishing shot merely because they are visible. Ordinary greenery alone is not evidence of a composed scenery view. A downward accidental view with no focal subject has purpose none. Conversely, hands visibly operating a fishing rod, opening equipment, steering, a passenger in a vehicle, a person walking along a visible route, and a coherent river/road view can have clear purpose. Do not require a face in purposeful POV or equipment detail. Do not confuse prettiness with narrative usefulness. purposeEvidence must name what the image actually reveals and how its framing supports the selected purpose; for none describe what is missing. Use short literal English statements. Return only JSON.
        """
        let fields: [String: Any] = ["scene": ["type": "string", "maxLength": 120],
            "orientation": ["type": "string", "enum": ["upright", "sideways", "inverted", "unclear"]],
            "opaqueCoverFraction": ["type": "number", "minimum": 0, "maximum": 1],
            "purpose": ["type": "string", "enum": ["action", "reaction", "portrait", "detail", "establishing", "none", "unclear"]],
            "purposeConfidence": ["type": "number", "minimum": 0, "maximum": 1],
            "purposeEvidence": ["type": "string", "maxLength": 160]]
        var frames: [OrientationFrame] = []
        for (index, sample) in samples.enumerated() {
            let body: [String: Any] = ["model": model, "stream": false, "think": false,
                "options": ["num_ctx": 4096, "num_predict": 300, "temperature": 0, "seed": 0],
                "format": ["type": "object", "required": fields.keys.sorted(), "properties": fields],
                "messages": [["role": "user", "content": prompt, "images": [sample.jpegBase64]]]]
            let content = try await modelAnswer(body: body, responseURL: responseURL.deletingPathExtension().appendingPathExtension("frame-\(index).json"))
            let observation = try JSONDecoder().decode(SingleFrame.self, from: Data(content.utf8))
            frames.append(.init(index: index, scene: observation.scene, orientation: observation.orientation,
                opaqueCoverFraction: observation.opaqueCoverFraction, purpose: observation.purpose,
                purposeConfidence: observation.purposeConfidence, purposeEvidence: observation.purposeEvidence))
        }
        return OrientationAnswer(frames: frames)
    }

    private func inspectCameraInteraction(samples: [VisualFrameSample], indices: [Int], responseURL: URL) async throws -> [CameraInteractionFrame] {
        struct SingleFrame: Decodable { var interaction: CameraInteraction; var confidence: Double; var evidence: String }
        let prompt = "Inspect the SINGLE image for visible hand interaction. Classify camera-adjustment only for a clearly foreshortened near-camera reach straight toward the filming lens, visible contact with it, or manipulation of the filming camera. This can occur while most of the scene remains visible; covered area alone is not proof. Classify social-gesture for a wave, thumbs-up, peace sign or other communication toward the viewer without manipulating the camera. A gesture addressed to the viewer is not camera adjustment. Classify equipment-work when the hand visibly grips/operates an identifiable fishing rod, steering wheel, bag, case, helmet or other filmed equipment. POV hands and an angled scene alone are not camera-adjustment. Classify none when no hand interaction is visible; use unclear when the target cannot be identified. Evidence must be a literal English description naming the visible hand action and its target. A class label such as equipment-work is not evidence. Do not invent contact with a hidden camera. Return only JSON."
        let fields: [String: Any] = ["interaction": ["type": "string", "enum": ["camera-adjustment", "equipment-work", "social-gesture", "none", "unclear"]],
            "confidence": ["type": "number", "minimum": 0, "maximum": 1], "evidence": ["type": "string", "maxLength": 130]]
        var result: [CameraInteractionFrame] = []
        for index in indices.sorted() {
            guard samples.indices.contains(index) else { throw URLError(.cannotParseResponse) }
            var accepted: CameraInteractionFrame?
            for attempt in 0..<2 {
                let body: [String: Any] = ["model": model, "stream": false, "think": false,
                    "options": ["num_ctx": 4096, "num_predict": 160, "temperature": 0, "seed": 0],
                    "format": ["type": "object", "required": fields.keys.sorted(), "properties": fields],
                    "messages": [["role": "user", "content": prompt + (attempt == 0 ? "" : " Describe the actual visible fingers/hand and the object they act on in a sentence; do not put a classification label in evidence."), "images": [samples[index].jpegBase64]]]]
                let content = try await modelAnswer(body: body,
                    responseURL: responseURL.deletingPathExtension().appendingPathExtension("frame-\(index)-attempt-\(attempt).json"))
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
                guard let corroborated = Self.corroboratingCameraClaim(accepted, with: target) else {
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
        let content = try await modelAnswer(body: body, responseURL: responseURL)
        return try JSONDecoder().decode(HandTargetObservation.self, from: Data(content.utf8))
    }

    private func inspectOrientation(samples: [VisualFrameSample], responseURL: URL) async throws -> OrientationAnswer {
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
        for (index, sample) in samples.enumerated() {
            let body: [String: Any] = ["model": model, "stream": false, "think": false,
                "options": ["num_ctx": 4096, "num_predict": 180, "temperature": 0, "seed": 0],
                "format": ["type": "object", "required": ["scene", "orientation", "orientationBasis", "opaqueCoverFraction"], "properties": fields],
                "messages": [["role": "user", "content": prompt, "images": [sample.jpegBase64]]]]
            let content = try await modelAnswer(body: body, responseURL: responseURL.deletingPathExtension().appendingPathExtension("frame-\(index).json"))
            let observation = try JSONDecoder().decode(SingleFrame.self, from: Data(content.utf8))
            frames.append(.init(index: index, scene: observation.scene, orientation: observation.orientation,
                opaqueCoverFraction: observation.opaqueCoverFraction, orientationBasis: observation.orientationBasis))
        }
        return OrientationAnswer(frames: frames)
    }

    func modelAnswer(body: [String: Any], responseURL: URL) async throws -> String {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:11434/api/chat")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        try FileManager.default.createDirectory(at: responseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Exact local requests and responses let an audit inspect the images
        // actually received by the model, rather than trusting a summary.
        let requestData = request.httpBody!
        let requestURL = responseURL.deletingPathExtension().appendingPathExtension("request.json")
        // Earlier cache writers could overwrite a request before comparing it
        // with its old response. Their pairs have no reliable provenance.
        let exactCache = responseURL.deletingLastPathComponent().appendingPathComponent("ByExactRequestV2")
        try FileManager.default.createDirectory(at: exactCache, withIntermediateDirectories: true)
        let digest = SHA256.hash(data: requestData).map { String(format: "%02x", $0) }.joined()
        let exactReceipt = exactCache.appendingPathComponent(digest + ".json")
        let exactRequest = exactCache.appendingPathComponent(digest + ".request.json")
        func verifiedContent(_ data: Data) -> String? {
            guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
                  envelope.done == true, envelope.done_reason == "stop", envelope.model == model,
                  let content = envelope.message?.content,
                  (try? JSONSerialization.jsonObject(with: Data(content.utf8))) != nil else { return nil }
            return content
        }
        if (try? Data(contentsOf: exactRequest)) == requestData,
           let data = try? Data(contentsOf: exactReceipt), let content = verifiedContent(data) {
            // Remove the old response before associating this path with a new
            // request, so an interrupted write cannot create a false pair.
            if FileManager.default.fileExists(atPath: responseURL.path) { try FileManager.default.removeItem(at: responseURL) }
            try requestData.write(to: requestURL, options: .atomic)
            try data.write(to: responseURL, options: .atomic)
            return content
        }
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
        let (data, response) = try await transportResponse(for: request)
        try data.write(to: responseURL, options: .atomic)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        guard let content = verifiedContent(data) else {
            throw URLError(.cannotParseResponse)
        }
        try requestData.write(to: exactRequest, options: .atomic)
        try data.write(to: exactReceipt, options: .atomic)
        return content
    }

    private func transportResponse(for request: URLRequest) async throws -> (Data, URLResponse) {
        for attempt in 0..<2 {
            do {
                let result: (Data, URLResponse)
                if let answerTransport { result = try await answerTransport(request) }
                else { result = try await URLSession.shared.data(for: request) }
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

    static func contactSheet(_ samples: [VisualFrameSample]) throws -> String {
        let rows = (samples.count + 2) / 3
        guard (1...9).contains(samples.count), let context = CGContext(data: nil, width: 960, height: rows * 214,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw URLError(.cannotDecodeContentData) }
        context.setFillColor(CGColor(gray: 0.04, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 960, height: rows * 214))
        for (index, sample) in samples.enumerated() {
            guard let bytes = Data(base64Encoded: sample.jpegBase64),
                  let source = CGImageSourceCreateWithData(bytes as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw URLError(.cannotDecodeContentData) }
            let x = Double(index % 3) * 320, bottom = Double(rows - 1 - index / 3) * 214
            let scale = min(320 / Double(image.width), 180 / Double(image.height))
            let width = Double(image.width) * scale, height = Double(image.height) * scale
            context.draw(image, in: CGRect(x: x + (320 - width) / 2, y: bottom + 34 + (180 - height) / 2, width: width, height: height))
            context.textPosition = CGPoint(x: x + 10, y: bottom + 8)
            let label = NSAttributedString(string: "FRAME \(index)", attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 22, nil),
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1)])
            CTLineDraw(CTLineCreateWithAttributedString(label), context)
        }
        guard let image = context.makeImage() else { throw URLError(.cannotDecodeContentData) }
        let bytes = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(bytes, UTType.jpeg.identifier as CFString, 1, nil) else { throw URLError(.cannotDecodeContentData) }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw URLError(.cannotDecodeContentData) }
        return (bytes as Data).base64EncodedString()
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
                          && (review.status == .uncertain || review.confidence < 0.75)
                  }) else { return nil }
            return candidateID
        })
    }
}
