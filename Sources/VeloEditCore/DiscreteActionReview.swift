import Foundation

/// Visual boundary evidence for a finite action. Continuous travel, resting
/// and scenery do not acquire an invented arrival or a required final pose.
public struct DiscreteActionBoundary: Codable, Hashable, Sendable {
    public enum Verdict: String, Codable, Hashable, Sendable {
        case complete, continuous, notApplicable = "not-applicable", interrupted, uncertain
    }
    public var startObservation: String
    public var endObservation: String
    public var followingObservation: String
    public var verdict: Verdict
    public var confidence: Double

    var isValid: Bool {
        confidence.isFinite && (0...1).contains(confidence)
            && [startObservation, endObservation, followingObservation].allSatisfy {
                $0.split(whereSeparator: { !$0.isLetter }).filter { $0.count > 1 }.count >= 2
            }
    }
    var rejectsCut: Bool { isValid && verdict == .interrupted && confidence >= 0.85 }
    var passes: Bool { isValid && confidence >= 0.8 && [.complete, .continuous, .notApplicable].contains(verdict) }
}

extension SelectedContentReviewer {
    struct HeadwearState: Codable {
        var observation: String
        var people: Int
        var worn: Int
        var beingPutOn: Int
        var confidence: Double

        var isStructurallyValid: Bool {
            [people, worn, beingPutOn].allSatisfy { (0...8).contains($0) }
                && confidence.isFinite && (0...1).contains(confidence)
                && observation.split(whereSeparator: { !$0.isLetter }).count >= 3
        }

        var isValid: Bool { isStructurallyValid && worn + beingPutOn <= people }
    }

    static func needsHeadwearBoundaryCheck(_ descriptions: [String]) -> Bool {
        let words = Set(descriptions.joined(separator: " ").lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init))
        return !words.isDisjoint(with: ["helmet", "hat", "cap", "balaclava", "headwear", "hood"])
            && !words.isDisjoint(with: ["adjusting", "holding", "putting", "lifting", "pulling", "fitting", "donning"])
    }

    static func missingHeadwearOutcome(_ states: [HeadwearState]) -> Double? {
        guard states.count == 4, states.allSatisfy(\.isValid),
              let end = states.dropLast().last, let after = states.last,
              end.people > 0, states.allSatisfy({ $0.people == end.people }),
              end.beingPutOn > 0, after.worn > end.worn,
              states.prefix(2).contains(where: { $0.worn < after.worn }) else { return nil }
        let confidence = states.map(\.confidence).min() ?? 0
        return confidence
    }

    static func uncertainHeadwearEvidence(_ states: [HeadwearState]) -> Bool {
        states.count != 4 || states.contains { !$0.isValid || $0.confidence < 0.75 }
    }

    static func applyingBoundary(_ boundary: DiscreteActionBoundary, to original: Answer) throws -> Answer {
        guard boundary.isValid else { throw URLError(.cannotParseResponse) }
        var answer = original
        answer.actionBoundary = boundary
        if boundary.rejectsCut {
            answer.status = .unmotivated
            answer.confidence = boundary.confidence
            answer.observation += " Граница действия: " + boundary.endObservation + "; далее: " + boundary.followingObservation
        } else if boundary.verdict == .interrupted || boundary.verdict == .uncertain || boundary.confidence < 0.8 {
            answer.status = .uncertain
        }
        return answer
    }

    static func missingPostureOutcome(_ poses: [(sitting: Int, standing: Int, bending: Int, other: Int)]) -> Bool {
        guard poses.count == 4 else { return false }
        func total(_ p: (sitting: Int, standing: Int, bending: Int, other: Int)) -> Int { p.sitting + p.standing + p.bending + p.other }
        let end = poses[2], after = poses[3]
        guard total(end) > 0, total(end) == total(after) else { return false }
        // A new action beginning only outside the cut is not a missing outcome.
        let introducedSit = poses.prefix(2).contains { total($0) < total(end) || $0.bending < end.bending }
        let introducedStand = poses.prefix(2).contains { $0.bending < end.bending }
        return introducedSit && after.sitting > end.sitting && after.standing + after.bending < end.standing + end.bending
            || introducedStand && after.standing > end.standing && after.sitting < end.sitting
    }

    static func boundaryVerdict(finiteTaskObserved: Bool, immediateOutcomeMissing: Bool,
        proposed: DiscreteActionBoundary.Verdict, observedMissingPosture: Bool) -> DiscreteActionBoundary.Verdict {
        if observedMissingPosture { return .interrupted }
        if immediateOutcomeMissing && !finiteTaskObserved { return .uncertain }
        if proposed == .interrupted && (!finiteTaskObserved || !immediateOutcomeMissing) { return .uncertain }
        if [.complete, .continuous, .notApplicable].contains(proposed) && immediateOutcomeMissing { return .uncertain }
        if !finiteTaskObserved && !immediateOutcomeMissing && proposed != .uncertain { return .continuous }
        return proposed
    }

    static func missingJointObjectOutcome(_ observations: [(pairs: Int, confidence: Double)]) -> Double? {
        guard observations.count == 4 else { return nil }
        let end = observations[2], after = observations[3]
        guard end.pairs > 0, after.pairs < end.pairs else { return nil }
        let witnesses = observations.prefix(2).filter { $0.pairs < end.pairs }.map(\.confidence)
        guard let earlier = witnesses.max() else { return nil }
        let confidence = min(earlier, end.confidence, after.confidence)
        return confidence.isFinite && confidence >= 0.75 ? confidence : nil
    }

    func inspectActionBoundary(samples: [VisualFrameSample], objectSamples: [VisualFrameSample]? = nil, responseURL: URL) async throws -> DiscreteActionBoundary {
        struct State: Decodable {
            var a_observation: String
            var sitting: Int
            var standing: Int
            var bending: Int
            var other: Int
            var confidence: Double
        }
        guard samples.count == 8 else { throw URLError(.cannotParseResponse) }
        let objectFrames = objectSamples ?? [1, 3, 5, 6, 7].map { samples[$0] }
        guard objectFrames.count == 5,
              zip(objectFrames, [1, 3, 5, 6, 7]).allSatisfy({ abs(($0.0.actualTimestamp ?? $0.0.timestamp) - samples[$0.1].timestamp) <= 0.1 }) else {
            throw URLError(.cannotParseResponse)
        }
        var states: [State] = []
        // The real eight-cell probe confused different people and reversed
        // motion. Each observer now receives only ONE image, with no account
        // of preceding/following frames to echo.
        for index in [1, 3, 5, 7] {
            let body: [String: Any] = ["model": model, "stream": false, "think": false,
                "options": ["num_ctx": 4096, "num_predict": 320, "temperature": 0, "seed": 0],
                "format": ["type": "object", "required": ["a_observation", "sitting", "standing", "bending", "other", "confidence"],
                    "properties": ["a_observation": ["type": "string", "maxLength": 220],
                        "sitting": ["type": "integer", "minimum": 0, "maximum": 8],
                        "standing": ["type": "integer", "minimum": 0, "maximum": 8],
                        "bending": ["type": "integer", "minimum": 0, "maximum": 8],
                        "other": ["type": "integer", "minimum": 0, "maximum": 8],
                        "confidence": ["type": "number", "minimum": 0, "maximum": 1]]],
                "messages": [["role": "user", "images": [samples[index].jpegBase64], "content": "Inspect physical support and posture in this SINGLE image. A seated person leaning forward or extending an arm REMAINS sitting: inspect whether their pelvis rests on a bench/chair/board. Standing requires legs bearing weight with the pelvis clear of the seat. Bending means a person supported by their legs bending down, not a seated person leaning. If physical support is hidden, use other. Ignore raised arms when deciding sitting versus standing. Describe each visible person and the visible physical support literally in ONE short English sentence (at most 30 words). Then count visible people by posture, each person ONCE. Do not infer movement, prior/following states, intention, handover, dialogue or arrival. confidence means certainty of the physical evidence. Return only JSON."]]]
            let answer = try await modelAnswer(body: body, responseURL: responseURL.deletingPathExtension().appendingPathExtension("state-\(index).json"))
            let state = try JSONDecoder().decode(State.self, from: Data(answer.utf8))
            guard state.confidence.isFinite, (0...1).contains(state.confidence), [state.sitting, state.standing, state.bending, state.other].allSatisfy({ (0...8).contains($0) }),
                  state.sitting + state.standing + state.bending + state.other <= 8,
                  state.a_observation.split(whereSeparator: { !$0.isLetter }).filter({ $0.count > 1 }).count >= 3 else {
                throw URLError(.cannotParseResponse)
            }
            states.append(state)
        }
        struct Decision: Decodable {
            var a_selectedAction: String
            var b_endAndFollowing: String
            var c_finiteTaskObserved: Bool
            var d_immediateOutcomeMissing: Bool
            var verdict: DiscreteActionBoundary.Verdict
            var confidence: Double
        }
        // The independent single-frame object observer invented transfers
        // when its prose switched between nearby objects. Compare the actual
        // ordered images instead, including the nearest post-cut frame so a
        // later NEW task cannot masquerade as a missing immediate outcome.
        let prompt = """
        Inspect these FIVE chronological images of a documentary cut. IMAGE 0 SELECTED START; IMAGE 1 SELECTED MIDDLE; IMAGE 2 SELECTED END; IMAGE 3 IMMEDIATELY AFTER CUT (+0.25s); IMAGE 4 LATER AFTER CUT (+4s). Images 3 and 4 are OUTSIDE the selection.
        a_selectedAction: at most 20 English words describing only the visible action INSIDE images 0–2. b_endAndFollowing: at most 25 words comparing the SAME person's/object's physical state at image 2, then 3 and 4. Describe actual support, hand contact and orientation. Touching or reaching alone does not prove an intended lifting, packing or transfer task. Do not guess hidden contents, handover or intention. Different objects are not states of the same object.
        c_finiteTaskObserved is true only when a finite task is visibly underway INSIDE images 0–2, with a distinct immediate outcome. d_immediateOutcomeMissing is true only if that SAME task is still unfinished at image 2 and continues or reaches its immediate outcome in images 3–4. A NEW action beginning only after the selection is not a missing outcome. A later different object/state alone cannot establish interruption. Do not require cleanup or storage after a task which visibly finishes inside the selection.
        Driving, rest, repeated playing/gestures, fishing and paddling are continuous unless a distinct finite immediate outcome is actually missing. Do not require the whole activity, journey or conversation to finish. Equal sitting counts alone do not prove an object task complete. If a relevant finite task/state is obscured or the images cannot establish its boundary, use uncertain rather than inventing completion or transfer.
        verdict: complete if an observed finite immediate outcome is visible INSIDE; continuous for an ongoing activity without a missing finite outcome; not-applicable for scenery; interrupted only with both booleans true; uncertain when evidence does not establish the boundary. Passing verdicts require d_immediateOutcomeMissing=false. confidence measures visible evidence. Return only JSON.
        """
        let body: [String: Any] = ["model": model, "stream": false, "think": false,
            "options": ["num_ctx": 8192, "num_predict": 320, "temperature": 0, "seed": 0],
            "format": ["type": "object", "required": ["a_selectedAction", "b_endAndFollowing", "c_finiteTaskObserved", "d_immediateOutcomeMissing", "verdict", "confidence"], "properties": [
                "a_selectedAction": ["type": "string", "maxLength": 180],
                "b_endAndFollowing": ["type": "string", "maxLength": 220],
                "c_finiteTaskObserved": ["type": "boolean"],
                "d_immediateOutcomeMissing": ["type": "boolean"],
                "verdict": ["type": "string", "enum": ["complete", "continuous", "not-applicable", "interrupted", "uncertain"]],
                "confidence": ["type": "number", "minimum": 0, "maximum": 1]]],
            "messages": [["role": "user", "images": objectFrames.map(\.jpegBase64), "content": prompt]]]
        let content = try await modelAnswer(body: body, responseURL: responseURL)
        let decision = try JSONDecoder().decode(Decision.self, from: Data(content.utf8))
        guard decision.confidence.isFinite, (0...1).contains(decision.confidence),
              [decision.a_selectedAction, decision.b_endAndFollowing].allSatisfy({
                  $0.split(whereSeparator: { !$0.isLetter }).filter({ $0.count > 1 }).count >= 3
              }) else { throw URLError(.cannotParseResponse) }
        // Retain the independently measured support/count evidence: a newly
        // appearing or disappearing person cannot become the same person's task.
        let missingPosture = Self.missingPostureOutcome(states.map { ($0.sitting, $0.standing, $0.bending, $0.other) })
        var verdict = Self.boundaryVerdict(finiteTaskObserved: decision.c_finiteTaskObserved,
            immediateOutcomeMissing: decision.d_immediateOutcomeMissing,
            proposed: decision.verdict, observedMissingPosture: missingPosture)
        struct JointObjectState: Decodable {
            var a_observation: String
            var b_jointObjectPairs: Int
            var c_confidence: Double
        }
        var jointObjects: [JointObjectState] = []
        var missingJointConfidence: Double?
        func people(_ state: State) -> Int { state.sitting + state.standing + state.bending + state.other }
        if !missingPosture, people(states[2]) >= 2, people(states[2]) == people(states[3]) {
            // Five-image temporal prose missed a real manipulation at the cut.
            // Independently inspect shared physical support in ONE image at a
            // time. This guard can only reject observed incomplete interaction;
            // its absence never supplies a positive completion certificate.
            for (position, index) in zip([0, 1, 2, 4], [1, 3, 5, 7]) {
                let body: [String: Any] = ["model": model, "stream": false, "think": false,
                    "options": ["num_ctx": 4096, "num_predict": 220, "temperature": 0, "seed": 0],
                    "format": ["type": "object", "required": ["a_observation", "b_jointObjectPairs", "c_confidence"],
                        "properties": ["a_observation": ["type": "string", "maxLength": 220],
                            "b_jointObjectPairs": ["type": "integer", "minimum": 0, "maximum": 8],
                            "c_confidence": ["type": "number", "minimum": 0, "maximum": 1]]],
                    "messages": [["role": "user", "images": [objectFrames[position].jpegBase64], "content": "Inspect ONLY this SINGLE image. Describe visible hands and physical object support in one short English sentence, at most 25 words. Then count pairs of DIFFERENT PEOPLE whose hands simultaneously touch/hold the SAME object while it is supported only by their hands (not resting on a table, post, ground or other fixed support). Count each pair once, regardless of how many fingers/hands. Nearby hands touching DIFFERENT objects do not count. Two hands of ONE person do not count. Contact with a fixed supported game board/steering wheel does not count. Hand-to-hand contact without an object does not count. Inspect actual fingers/contact/support; do not infer intention, transfer, motion, task or previous/following states. If contact/support is hidden, lower confidence. Return JSON."]]]
                let answer = try await modelAnswer(body: body, responseURL: responseURL.deletingPathExtension().appendingPathExtension("joint-\(index).json"))
                let state = try JSONDecoder().decode(JointObjectState.self, from: Data(answer.utf8))
                guard state.c_confidence.isFinite, (0...1).contains(state.c_confidence),
                      (0...8).contains(state.b_jointObjectPairs),
                      state.a_observation.split(whereSeparator: { !$0.isLetter }).filter({ $0.count > 1 }).count >= 3 else {
                    throw URLError(.cannotParseResponse)
                }
                jointObjects.append(state)
            }
            missingJointConfidence = Self.missingJointObjectOutcome(jointObjects.map { ($0.b_jointObjectPairs, $0.c_confidence) })
            if missingJointConfidence != nil {
                verdict = .interrupted
            } else if jointObjects[2].b_jointObjectPairs > 0, jointObjects[2].c_confidence >= 0.75,
                      jointObjects[3].b_jointObjectPairs < jointObjects[2].b_jointObjectPairs,
                      jointObjects.prefix(2).contains(where: { $0.b_jointObjectPairs < jointObjects[2].b_jointObjectPairs }) {
                // An uncertain post-cut witness cannot prove interruption,
                // but cannot silently restore the scene-level positive label.
                verdict = .uncertain
            }
        }
        var headwearEvidence: [HeadwearState] = []
        var missingHeadwearConfidence: Double?
        if [.complete, .continuous, .notApplicable].contains(verdict),
           Self.needsHeadwearBoundaryCheck([decision.a_selectedAction, decision.b_endAndFollowing, states[2].a_observation]) {
            // A scene-level answer called putting headwear on "continuous
            // preparation" even though the visible outcome lay after the cut.
            // Inspect physical fit independently, without the temporal prose.
            for position in [0, 1, 2, 4] {
                let body: [String: Any] = ["model": model, "stream": false, "think": false,
                    "options": ["num_ctx": 4096, "num_predict": 220, "temperature": 0, "seed": 0],
                    "format": ["type": "object", "required": ["observation", "people", "worn", "beingPutOn", "confidence"],
                        "properties": ["observation": ["type": "string", "maxLength": 220],
                            "people": ["type": "integer", "minimum": 0, "maximum": 8],
                            "worn": ["type": "integer", "minimum": 0, "maximum": 8],
                            "beingPutOn": ["type": "integer", "minimum": 0, "maximum": 8],
                            "confidence": ["type": "number", "minimum": 0, "maximum": 1]]],
                    "messages": [["role": "user", "images": [objectFrames[position].jpegBase64],
                        "content": "Inspect ONLY this SINGLE image. Describe the visible position and support of hats, helmets, hoods or cloth head coverings relative to each person's head in one literal English sentence. Count visible people once each. worn: people whose head covering is already fitted on the head, including a worn item merely touched or adjusted. beingPutOn: people visibly holding an UNFITTED head covering directly against/over their head or face in the process of fitting it; do NOT count an already worn item, touching hair, a social gesture, an object held away from the head, or a helmet on a vehicle/table. The two counts must be disjoint. Do not infer intent or previous/following states. If fit or object identity is obscured, lower confidence. Return JSON."]]]
                let content = try await modelAnswer(body: body,
                    responseURL: responseURL.deletingPathExtension().appendingPathExtension("headwear-\(position).json"))
                let observation = try JSONDecoder().decode(HeadwearState.self, from: Data(content.utf8))
                guard observation.isStructurallyValid else { throw URLError(.cannotParseResponse) }
                headwearEvidence.append(observation)
            }
            missingHeadwearConfidence = Self.missingHeadwearOutcome(headwearEvidence)
            if let confidence = missingHeadwearConfidence {
                verdict = confidence >= 0.85 ? .interrupted : .uncertain
            } else if Self.uncertainHeadwearEvidence(headwearEvidence) {
                // A complete response with impossible physical counts is
                // conflicting visual evidence, not an unavailable probe.
                // Preserve its observations and mark the boundary uncertain;
                // native assembly may try another exact candidate. Never
                // normalize the counts or promote it to an interruption.
                verdict = .uncertain
            }
        }
        let postureConfidence = states.map(\.confidence).min() ?? 0
        let jointStart = jointObjects.first.map { " Shared object support: " + $0.a_observation } ?? ""
        let jointEnd = jointObjects.count == 4 ? " Shared object support: " + jointObjects[2].a_observation : ""
        let jointAfter = jointObjects.last.map { " Shared object support: " + $0.a_observation } ?? ""
        let boundary = DiscreteActionBoundary(startObservation: states[0].a_observation + " Visible action: " + decision.a_selectedAction + jointStart,
            endObservation: states[2].a_observation + " Boundary comparison: " + decision.b_endAndFollowing + jointEnd
                + (headwearEvidence.count == 4 ? " Headwear fit: " + headwearEvidence[2].observation : ""),
            followingObservation: states[3].a_observation + " Boundary comparison: " + decision.b_endAndFollowing + jointAfter
                + (headwearEvidence.last.map { " Headwear fit: " + $0.observation } ?? ""),
            verdict: verdict, confidence: min(missingPosture ? 1 : (missingHeadwearConfidence ?? missingJointConfidence ?? decision.confidence), postureConfidence))
        guard boundary.isValid else { throw URLError(.cannotParseResponse) }
        return boundary
    }
}
