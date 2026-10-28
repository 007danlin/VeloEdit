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
    struct SmallTaskClassification: Decodable {
        var a_reason: String
        var b_finiteTask: Bool
        var c_confidence: Double
    }

    struct SmallTaskOutcome: Decodable {
        enum Location: String, Decodable { case inside, after, none, unclear }
        var a_evidence: String
        var b_location: Location
        var c_confidence: Double

        var verdict: DiscreteActionBoundary.Verdict {
            switch b_location {
            case .inside: return .complete
            case .after: return .interrupted
            case .none: return .continuous
            case .unclear: return .uncertain
            }
        }
    }

    struct SmallBoundaryCategory: Decodable {
        enum Category: String, Decodable { case done, unfinished, activity, unknown }
        var b_category: Category
        var c_certainty: Double

        var location: SmallTaskOutcome.Location {
            switch b_category {
            case .done: return .inside
            case .unfinished: return .after
            case .activity: return .none
            case .unknown: return .unclear
            }
        }
    }

    struct SmallBoundaryClarification: Decodable {
        enum State: String, Decodable {
            case noFiniteTask = "no-finite-task-observed"
            case unfinished = "task-unfinished-at-cut"
            case finished = "task-finished-before-cut"
            case hidden = "task-state-not-visible"
        }
        var a_endState: String
        var b_state: State
        var c_confidence: Double
    }

    /// Resolve only the ambiguity between scenery and an unknown task ending.
    /// This is never a way to overwrite an observed completion/interruption or
    /// to turn an occluded task into a positive certificate.
    static func clarifiedSmallOutcome(_ original: SmallTaskOutcome,
                                      task: SmallTaskClassification,
                                      clarification: SmallBoundaryClarification) -> SmallTaskOutcome {
        guard !task.b_finiteTask, task.c_confidence.isFinite, (0.8...1).contains(task.c_confidence),
              original.b_location == .unclear, clarification.b_state == .noFiniteTask,
              clarification.c_confidence.isFinite, (0.8...1).contains(clarification.c_confidence),
              clarification.a_endState.split(whereSeparator: { !$0.isLetter }).filter({ $0.count > 1 }).count >= 6 else { return original }
        return SmallTaskOutcome(a_evidence: clarification.a_endState, b_location: .none,
            c_confidence: min(task.c_confidence, clarification.c_confidence))
    }

    static func smallBoundaryVerdict(finite: Bool, location: SmallTaskOutcome.Location) -> DiscreteActionBoundary.Verdict {
        switch (finite, location) {
        case (false, .none): return .continuous
        case (true, .inside): return .complete
        case (true, .after): return .interrupted
        default: return .uncertain
        }
    }

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
        let objects: Set<String> = ["helmet", "helmets", "hat", "hats", "cap", "caps", "balaclava", "headwear", "hood", "hoods"]
        let actions: Set<String> = ["adjusting", "adjusts", "adjusted", "holding", "holds", "held", "putting", "puts",
            "lifting", "lifts", "lifted", "pulling", "pulls", "pulled", "fitting", "fits", "donning", "dons", "removing", "removes", "put", "removed", "fitted"]
        let passive: Set<String> = ["held", "lifted", "pulled", "adjusted", "put", "removed", "fitted"]
        let relativeSubject: Set<String> = ["that", "which", "he", "she", "they"]
        let separators: Set<String> = ["and", "while", "whereas", "but", "wearing", "wears", "worn"]
        // A hat on one person plus tablets held by someone else is not a
        // headwear action. Keep the literal action and its object in the same
        // short phrase; general temporal/action checks still inspect all cuts.
        return descriptions.contains { description in
            description.lowercased().replacingOccurrences(of: "head covering", with: "headwear")
                .split(whereSeparator: { ",.;:!?\n".contains($0) }).contains { clause in
                    let words = clause.split(whereSeparator: { !$0.isLetter }).map(String.init)
                    return words.indices.contains { index in
                        guard objects.contains(words[index]) else { return false }
                        for direction in [-1, 1] {
                            for distance in 1...5 {
                                let other = index + direction * distance
                                guard words.indices.contains(other), !separators.contains(words[other]) else { break }
                                if actions.contains(words[other]), direction < 0 || passive.contains(words[other])
                                    || words[(index + 1)..<other].contains(where: relativeSubject.contains) { return true }
                            }
                        }
                        return false
                    }
                }
        }
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
            var peopleVisibility: String?
            var peopleCount: Int?
            var sitting: Int
            var standing: Int
            var bending: Int
            var other: Int
            var confidence: Double
            enum Keys: String, CodingKey { case a_observation, peopleVisibility, peopleCount, postures, sitting, standing, bending, other, confidence }
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: Keys.self)
                a_observation = try c.decode(String.self, forKey: .a_observation)
                peopleVisibility = try c.decodeIfPresent(String.self, forKey: .peopleVisibility)
                peopleCount = try c.decodeIfPresent(Int.self, forKey: .peopleCount)
                confidence = try c.decode(Double.self, forKey: .confidence)
                if let postures = try c.decodeIfPresent([String].self, forKey: .postures) {
                    guard postures.count == peopleCount, postures.allSatisfy({ ["sitting", "standing", "bending", "other"].contains($0) }) else { throw URLError(.cannotParseResponse) }
                    sitting = postures.filter { $0 == "sitting" }.count
                    standing = postures.filter { $0 == "standing" }.count
                    bending = postures.filter { $0 == "bending" }.count
                    other = postures.filter { $0 == "other" }.count
                } else {
                    sitting = try c.decode(Int.self, forKey: .sitting)
                    standing = try c.decode(Int.self, forKey: .standing)
                    bending = try c.decode(Int.self, forKey: .bending)
                    other = try c.decode(Int.self, forKey: .other)
                }
            }
        }
        guard samples.count == 8 else { throw URLError(.cannotParseResponse) }
        let objectFrames = objectSamples ?? [1, 3, 5, 6, 7].map { samples[$0] }
        guard objectFrames.count == 5,
              zip(objectFrames, [1, 3, 5, 6, 7]).allSatisfy({ abs(($0.0.actualTimestamp ?? $0.0.timestamp) - samples[$0.1].timestamp) <= 0.1 }) else {
            throw URLError(.cannotParseResponse)
        }
        let validateState: @Sendable (String) throws -> Void = { content in
            let state = try JSONDecoder().decode(State.self, from: Data(content.utf8))
            guard state.confidence.isFinite, (0...1).contains(state.confidence), [state.sitting, state.standing, state.bending, state.other].allSatisfy({ (0...8).contains($0) }),
                  state.sitting + state.standing + state.bending + state.other <= 8,
                  state.a_observation.split(whereSeparator: { !$0.isLetter }).filter({ $0.count > 1 }).count >= 3 else {
                throw URLError(.cannotParseResponse)
            }
            do {
                let count = state.sitting + state.standing + state.bending + state.other
                guard state.peopleVisibility == "absent" && count == 0
                    || state.peopleVisibility == "visible" && count > 0
                    || state.peopleVisibility == "unclear" && state.confidence < 0.8 else {
                    throw URLError(.cannotParseResponse)
                }
            }
        }
        var observedStates: [Int: State] = [:]
        let smallModel = model == AIAnalysisProfile.resolve(mode: .fast).modelID
        // The real eight-cell probe confused different people and reversed
        // motion. Each observer now receives only ONE image, with no account
        // of preceding/following frames to echo.
        // Explicit presence and one posture per person avoid conflating
        // zero people with zero certainty. Apply this observation contract to
        // every mode, preserving all four images and the confidence threshold.
        // End with the first image of the following five-image request, so
        // its identical image prefix stays hot. Independent requests retain
        // their original images/prompts; restore chronological order below.
        for index in [7, 5, 3, 1] {
            let body: [String: Any] = ["model": model, "stream": false, "think": false,
                "options": ["num_ctx": 4096, "num_predict": 320, "temperature": 0, "seed": 0],
                "format": ["type": "object", "required": ["a_observation", "peopleVisibility", "peopleCount", "postures", "confidence"], "properties": [
                    "a_observation": ["type": "string", "minLength": 12, "maxLength": 220],
                    "peopleVisibility": ["type": "string", "enum": ["absent", "visible", "unclear"]],
                    "peopleCount": ["type": "integer", "minimum": 0, "maximum": 8],
                    "postures": ["type": "array", "maxItems": 8, "items": ["type": "string", "enum": ["sitting", "standing", "bending", "other"]]],
                    "confidence": ["type": "number", "minimum": 0, "maximum": 1]]],
                "messages": [["role": "user", "images": [samples[index].jpegBase64], "content": "Look at this ONE image. Describe visible people and physical support in one short English sentence. peopleVisibility: absent, visible, or unclear. peopleCount: number of DIFFERENT people visible, each counted once. postures: exactly ONE entry per person, left to right. Choose sitting if the pelvis rests on a seat, even when leaning; bending if supported on legs with torso bent; standing if supported on legs upright; other if support is hidden. A hand alone is other. Do NOT label one person both standing and bending. If absent, peopleCount=0 and postures=[], and a_observation must still be a literal sentence describing the visible scene and absence of people, not the word absent. Confidence measures certainty of the literal observation, including clear absence. If support or visibility is unclear, lower confidence. Do not infer motion or intention. JSON only."]]]
            let answer = try await modelAnswer(body: body, responseURL: responseURL.deletingPathExtension().appendingPathExtension("state-\(index).json"),
                progressDetail: "Проверяю действие · наблюдение \(observedStates.count + 1) из 4",
                repairInstruction: "OBSERVATION FORMAT: a_observation must be a literal sentence with at least three words, including when people are absent. Describe the visible scene and absence; a category label is not an observation. peopleCount must equal the number of postures, one per person. Preserve genuinely unclear support and low certainty.",
                validateObservation: validateState)
            let state = try JSONDecoder().decode(State.self, from: Data(answer.utf8))
            observedStates[index] = state
        }
        let states = try [1, 3, 5, 7].map { index -> State in
            guard let state = observedStates[index] else { throw URLError(.cannotParseResponse) }
            return state
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
        var body: [String: Any] = ["model": model, "stream": false, "think": false,
            "options": ["num_ctx": 8192, "num_predict": 320, "temperature": 0, "seed": 0],
            "format": ["type": "object", "required": ["a_selectedAction", "b_endAndFollowing", "c_finiteTaskObserved", "d_immediateOutcomeMissing", "verdict", "confidence"], "properties": [
                "a_selectedAction": ["type": "string", "maxLength": 180],
                "b_endAndFollowing": ["type": "string", "maxLength": 220],
                "c_finiteTaskObserved": ["type": "boolean"],
                "d_immediateOutcomeMissing": ["type": "boolean"],
                "verdict": ["type": "string", "enum": ["complete", "continuous", "not-applicable", "interrupted", "uncertain"]],
                "confidence": ["type": "number", "minimum": 0, "maximum": 1]]],
            "messages": [["role": "user", "images": objectFrames.map(\.jpegBase64), "content": prompt]]]
        if smallModel {
            // 2B mixed up simultaneous task/outcome enums even when its
            // literal description was correct. First observe all five images;
            // then classify that observation in a separate text-only request.
            // Posture, shared-object and headwear observers remain independent.
            body["options"] = ["num_ctx": 8192, "num_predict": 320, "temperature": 0, "seed": 0, "repeat_penalty": 1.15]
            body["format"] = ["type": "object", "required": ["observation"],
                "properties": ["observation": ["type": "string", "maxLength": 500]]]
            body["messages"] = [["role": "user", "images": objectFrames.map(\.jpegBase64), "content": "In at most 40 English words, describe the visible activity in these FIVE ordered frames. Do not repeat sentences. A film clip ends at image 2; images 3 (+0.25s) and 4 (+4s) are just after it. Describe the SAME subjects and objects at the end and afterward, including physical support and hand contact. Is there a distinct physical task result, or only ongoing activity/scenery? Do not invent hidden actions, destinations or intentions."]]
        }
        let content = try await modelAnswer(body: body, responseURL: responseURL,
            progressDetail: "Проверяю, что действие не обрывается на склейке",
            repairInstruction: "OBSERVATION FORMAT: return literal observations, not labels or copied instructions. Describe actual visible uncertainty without inventing a task or increasing confidence.",
            validateObservation: { content in
                if smallModel {
                    struct Observation: Decodable { var observation: String }
                    let observation = try JSONDecoder().decode(Observation.self, from: Data(content.utf8)).observation
                    guard observation.split(whereSeparator: { !$0.isLetter }).filter({ $0.count > 1 }).count >= 6,
                          !observation.lowercased().contains("describe the visible activity") else { throw URLError(.cannotParseResponse) }
                } else {
                    let decision = try JSONDecoder().decode(Decision.self, from: Data(content.utf8))
                    guard decision.confidence.isFinite, (0...1).contains(decision.confidence),
                          [decision.a_selectedAction, decision.b_endAndFollowing].allSatisfy({
                              $0.split(whereSeparator: { !$0.isLetter }).filter({ $0.count > 1 }).count >= 3
                          }) else { throw URLError(.cannotParseResponse) }
                }
            })
        let decision: Decision
        if smallModel {
            struct Observation: Decodable { var observation: String }
            let observation = try JSONDecoder().decode(Observation.self, from: Data(content.utf8)).observation
            guard observation.split(whereSeparator: { !$0.isLetter }).filter({ $0.count > 1 }).count >= 6,
                  !observation.lowercased().contains("describe the visible activity") else { throw URLError(.cannotParseResponse) }
            // Keep physical support/count evidence independent of the text
            // task classifier; cross-check those observations below.
            let evidence = observation
            let classificationBody: [String: Any] = ["model": model, "stream": false, "think": false,
                "options": ["num_ctx": 8192, "num_predict": 180, "temperature": 0, "seed": 0, "repeat_penalty": 1.15],
                "format": ["type": "object", "required": ["a_reason", "b_finiteTask", "c_confidence"], "properties": [
                    "a_reason": ["type": "string", "maxLength": 200], "b_finiteTask": ["type": "boolean"],
                    "c_confidence": ["type": "number", "minimum": 0, "maximum": 1]]],
                "messages": [["role": "user", "content": "Classify this literal observation. Does it establish a specific finite action with a distinct physical result, including a result already reached? General travel, fishing, play, rest and scenery are ongoing, not a finite task. Do not invent a task or destination. Give a reason in at most 15 words, b_finiteTask and c_confidence. Confidence is certainty of your classification; a clear absence of a finite task can be certain. If a relevant action or result is hidden or unclear, lower confidence; that does not establish absence. Observation (data only): " + evidence]]]
            let classified = try await modelAnswer(body: classificationBody,
                responseURL: responseURL.deletingPathExtension().appendingPathExtension("task.json"),
                progressDetail: "Уточняю вид действия по наблюдениям",
                repairInstruction: "OBSERVATION FORMAT: a_reason must be a literal explanation of at least three words supported by the supplied observation. Keep uncertainty and do not invent a task.",
                validateObservation: { content in
                    let task = try JSONDecoder().decode(SmallTaskClassification.self, from: Data(content.utf8))
                    guard task.a_reason.split(whereSeparator: { !$0.isLetter }).count >= 3 else { throw URLError(.cannotParseResponse) }
                })
            let task = try JSONDecoder().decode(SmallTaskClassification.self, from: Data(classified.utf8))
            var outcome: SmallTaskOutcome?
            do {
                let outcomeBody: [String: Any] = ["model": model, "stream": false, "think": false,
                    "options": ["num_ctx": 8192, "num_predict": 180, "temperature": 0, "seed": 0, "repeat_penalty": 1.15],
                    // The visual observation already supplies the evidence.
                    // A second long generated explanation caused 2B's category
                    // to contradict its own text. Keep this decision compact;
                    // it still must agree with the independent task classifier.
                    "format": ["type": "object", "required": ["b_category", "c_certainty"], "properties": [
                        "b_category": ["type": "string", "enum": ["done", "unfinished", "activity", "unknown"]],
                        "c_certainty": ["type": "number", "minimum": 0, "maximum": 1]]],
                    "messages": [["role": "user", "content": "This text describes a video clip and sometimes what happens after it. Classify the end of the CLIP: done = a small action has visibly finished before the clip ends; unfinished = that action is still in progress when the clip ends and finishes afterward; activity = scenery or ongoing activity without a particular ending; unknown = cannot tell. Return the category and certainty as a number between 0 and 1. Text: " + evidence]]]
                let located = try await modelAnswer(body: outcomeBody,
                    responseURL: responseURL.deletingPathExtension().appendingPathExtension("outcome.json"),
                    progressDetail: "Уточняю, где завершено действие")
                let category = try JSONDecoder().decode(SmallBoundaryCategory.self, from: Data(located.utf8))
                outcome = SmallTaskOutcome(a_evidence: observation, b_location: category.location,
                    c_confidence: category.c_certainty)
                if category.b_category == .unknown, !task.b_finiteTask, task.c_confidence >= 0.8 {
                    // The compact category can mistake "no finite task" for
                    // "unknown ending". Ask one different, literal question
                    // about the instant of the cut. Hidden or conflicting
                    // states remain unknown, regardless of their confidence.
                    let clarificationBody: [String: Any] = ["model": model, "stream": false, "think": false,
                        "options": ["num_ctx": 8192, "num_predict": 240, "temperature": 0, "seed": 0],
                        "format": ["type": "object", "required": ["a_endState", "b_state", "c_confidence"], "properties": [
                            "a_endState": ["type": "string", "maxLength": 200],
                            "b_state": ["type": "string", "enum": ["no-finite-task-observed", "task-unfinished-at-cut", "task-finished-before-cut", "task-state-not-visible"]],
                            "c_confidence": ["type": "number", "minimum": 0, "maximum": 1]]],
                        "messages": [["role": "user", "content": "At the exact instant the clip ends, BEFORE any later event, describe the subject and its physical state in a_endState. Then classify that instant: no-finite-task-observed means scenery or continuous activity without an observed finite task; task-unfinished-at-cut means a specific finite task is still underway at the cut; task-finished-before-cut means a finite task has reached its physical result before the cut; task-state-not-visible means the relevant action or its state is hidden or cannot be determined. Events after the clip cannot make an unfinished task already finished. c_confidence is certainty of the classification, not the amount of completion. Keep hidden states hidden. Description: " + evidence]]]
                    let clarified = try await modelAnswer(body: clarificationBody,
                        responseURL: responseURL.deletingPathExtension().appendingPathExtension("outcome-clarified.json"),
                        progressDetail: "Уточняю неопределённую границу по состоянию в момент склейки")
                    let clarification = try JSONDecoder().decode(SmallBoundaryClarification.self, from: Data(clarified.utf8))
                    outcome = Self.clarifiedSmallOutcome(outcome!, task: task, clarification: clarification)
                }
            }
            guard task.a_reason.split(whereSeparator: { !$0.isLetter }).count >= 3,
                  outcome.map({ $0.a_evidence.split(whereSeparator: { !$0.isLetter }).count >= 3 }) ?? true else { throw URLError(.cannotParseResponse) }
            decision = Decision(a_selectedAction: observation, b_endAndFollowing: outcome?.a_evidence ?? observation,
                c_finiteTaskObserved: task.b_finiteTask, d_immediateOutcomeMissing: outcome?.b_location == .after,
                verdict: Self.smallBoundaryVerdict(finite: task.b_finiteTask, location: outcome?.b_location ?? .unclear),
                confidence: min(task.c_confidence, outcome?.c_confidence ?? task.c_confidence))
        } else {
            decision = try JSONDecoder().decode(Decision.self, from: Data(content.utf8))
        }
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
                let answer = try await modelAnswer(body: body, responseURL: responseURL.deletingPathExtension().appendingPathExtension("joint-\(index).json"),
                    progressDetail: "Уточняю взаимодействие людей · наблюдение \(jointObjects.count + 1) из 4",
                    repairInstruction: "OBSERVATION FORMAT: a_observation must describe actual hands and support, including absence or ambiguity, in at least three words. A count or label alone is not an observation.",
                    validateObservation: { content in
                        let state = try JSONDecoder().decode(JointObjectState.self, from: Data(content.utf8))
                        guard state.c_confidence.isFinite, (0...1).contains(state.c_confidence),
                              (0...8).contains(state.b_jointObjectPairs),
                              state.a_observation.split(whereSeparator: { !$0.isLetter }).filter({ $0.count > 1 }).count >= 3 else {
                            throw URLError(.cannotParseResponse)
                        }
                    })
                let state = try JSONDecoder().decode(JointObjectState.self, from: Data(answer.utf8))
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
                    responseURL: responseURL.deletingPathExtension().appendingPathExtension("headwear-\(position).json"),
                    progressDetail: "Уточняю завершение действия · наблюдение \(headwearEvidence.count + 1) из 4",
                    repairInstruction: "OBSERVATION FORMAT: observation must describe visible head coverings, their absence or hidden fit in at least three words. Preserve uncertain fit and confidence; do not invent an item.",
                    validateObservation: { content in
                        let observation = try JSONDecoder().decode(HeadwearState.self, from: Data(content.utf8))
                        guard observation.isStructurallyValid else { throw URLError(.cannotParseResponse) }
                    })
                let observation = try JSONDecoder().decode(HeadwearState.self, from: Data(content.utf8))
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
        // Every independent observation that was required for this cut must
        // support a positive certificate. In particular, zero shared-object
        // pairs with zero certainty is unknown contact, not verified absence.
        // A confident scene-level answer cannot erase that missing evidence.
        let independentConfidence = (states.map(\.confidence)
            + jointObjects.map(\.c_confidence) + headwearEvidence.map(\.confidence)).min() ?? 0
        let jointStart = jointObjects.first.map { " Shared object support: " + $0.a_observation } ?? ""
        let jointEnd = jointObjects.count == 4 ? " Shared object support: " + jointObjects[2].a_observation : ""
        let jointAfter = jointObjects.last.map { " Shared object support: " + $0.a_observation } ?? ""
        let boundary = DiscreteActionBoundary(startObservation: states[0].a_observation + " Visible action: " + decision.a_selectedAction + jointStart,
            endObservation: states[2].a_observation + " Boundary comparison: " + decision.b_endAndFollowing + jointEnd
                + (headwearEvidence.count == 4 ? " Headwear fit: " + headwearEvidence[2].observation : ""),
            followingObservation: states[3].a_observation + " Boundary comparison: " + decision.b_endAndFollowing + jointAfter
                + (headwearEvidence.last.map { " Headwear fit: " + $0.observation } ?? ""),
            verdict: verdict, confidence: min(missingPosture ? 1 : (missingHeadwearConfidence ?? missingJointConfidence ?? decision.confidence), independentConfidence))
        guard boundary.isValid else { throw URLError(.cannotParseResponse) }
        return boundary
    }
}
