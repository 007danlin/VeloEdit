import Foundation
import Testing
@testable import VeloEditCore

struct LocalModelResponseValidationTests {
    let schema: [String: Any] = ["type": "object", "required": ["confidence"],
        "properties": ["confidence": ["type": "number", "minimum": 0, "maximum": 1]]]

    @Test func invalidProbabilitiesNeverBecomeUsableCachedEvidence() throws {
        for value in ["100", "-0.1", "true", "\"0.95\""] {
            #expect(throws: (any Error).self) {
                try LocalModelResponseValidation.validate("{\"confidence\":\(value)}", schema: schema)
            }
        }
        try LocalModelResponseValidation.validate(#"{"confidence":0.95}"#, schema: schema)
    }

    @Test func verdictBranchesValidateTheirNestedEvidenceAndCannotAcceptContradictorySuccess() throws {
        func branch(_ accepted: Bool) -> [String: Any] {
            ["type": "object", "required": ["accepted", "reasons", "unsupportedClaims"],
             "properties": ["accepted": ["const": accepted],
                "reasons": ["type": "array", "minItems": 1, "items": ["type": "string"]],
                "unsupportedClaims": ["type": "array", "maxItems": accepted ? 0 : 4, "items": ["type": "string"]]]]
        }
        let schema: [String: Any] = ["oneOf": [branch(true), branch(false)]]
        for invalid in [#"{"accepted":true,"reasons":[],"unsupportedClaims":[]}"#,
                        #"{"accepted":true,"reasons":["Looks plausible"],"unsupportedClaims":["place"]}"#,
                        #"{"accepted":1,"reasons":["Numeric boolean"],"unsupportedClaims":[]}"#] {
            #expect(throws: URLError.self) { try LocalModelResponseValidation.validate(invalid, schema: schema) }
        }
        try LocalModelResponseValidation.validate(#"{"accepted":true,"reasons":["Supported visible subject"],"unsupportedClaims":[]}"#, schema: schema)
        try LocalModelResponseValidation.validate(#"{"accepted":false,"reasons":["Unsupported place"],"unsupportedClaims":["place"]}"#, schema: schema)
        #expect(throws: URLError.self) {
            try LocalModelResponseValidation.validate(#"{"accepted":true,"reasons":["Ambiguous schema"],"unsupportedClaims":[]}"#,
                schema: ["oneOf": [branch(true), branch(true)]])
        }
    }

    private actor Transport {
        var requests: [[String: Any]] = []
        let alwaysInvalid: Bool
        init(alwaysInvalid: Bool = false) { self.alwaysInvalid = alwaysInvalid }
        func send(_ request: URLRequest) throws -> (Data, URLResponse) {
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            requests.append(body)
            let content = requests.count == 1 || alwaysInvalid ? #"{"confidence":100}"# : #"{"confidence":0.95}"#
            let data = try JSONSerialization.data(withJSONObject: ["model": "fixture", "done": true,
                "done_reason": "stop", "message": ["content": content]])
            return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        var count: Int { requests.count }
        func preservedInputs() -> Bool {
            guard requests.count == 2,
                  let first = requests[0]["messages"] as? [[String: Any]],
                  let second = requests[1]["messages"] as? [[String: Any]] else { return false }
            return first[0]["images"] as? [String] == second[0]["images"] as? [String]
                && requests[0]["model"] as? String == requests[1]["model"] as? String
                && NSDictionary(dictionary: requests[0]["options"] as! [String: Any])
                    .isEqual(to: requests[1]["options"] as! [String: Any])
                && (second[0]["content"] as? String)?.hasPrefix(first[0]["content"] as! String) == true
        }
    }

    private var body: [String: Any] {
        ["model": "fixture", "format": schema, "stream": false,
         "options": ["num_ctx": 8192, "num_predict": 320, "temperature": 0],
         "messages": [["role": "user", "content": "Assess this exact range.", "images": ["frame-a", "frame-b"]]]]
    }

    @Test func malformedReplyRepairsOnlyThatRequestAndReusesItsExactValidatedResult() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = Transport()
        let reviewer = SelectedContentReviewer(cacheURL: root, model: "fixture", answerTransport: { try await transport.send($0) })
        let answer = try await reviewer.modelAnswer(body: body, responseURL: root.appendingPathComponent("first.json"))
        #expect(answer == #"{"confidence":0.95}"#)
        #expect(await transport.count == 2)
        #expect(await transport.preservedInputs())
        let reused = try await reviewer.modelAnswer(body: body, responseURL: root.appendingPathComponent("second.json"))
        #expect(reused == answer)
        #expect(await transport.count == 2)
        let stored = try String(contentsOf: root.appendingPathComponent("second.request.json"), encoding: .utf8)
        #expect(stored.contains("FORMAT REPAIR"))
    }

    @Test func repeatedInvalidRepliesRemainFailures() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = Transport(alwaysInvalid: true)
        let reviewer = SelectedContentReviewer(cacheURL: root, model: "fixture", answerTransport: { try await transport.send($0) })
        await #expect(throws: URLError.self) {
            _ = try await reviewer.modelAnswer(body: body, responseURL: root.appendingPathComponent("bad.json"))
        }
        #expect(await transport.count == 2)
        let receipts = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("ByExactRequestV3").path)
        #expect(receipts.isEmpty)
    }

    @Test func privateRuntimeBoundsMemoryWithoutChangingModelsOrPrecision() {
        let inherited = ["OLLAMA_MODELS": "/test/models", "OLLAMA_KV_CACHE_TYPE": "q8_0", "OLLAMA_HOST": "127.0.0.1:11434"]
        let environment = LocalAIRuntimeConfiguration.serverEnvironment(inherited: inherited, physicalMemory: 32 * 1_073_741_824)
        #expect(environment["OLLAMA_MODELS"] == inherited["OLLAMA_MODELS"])
        #expect(environment["OLLAMA_KV_CACHE_TYPE"] == "f16")
        #expect(environment["OLLAMA_HOST"] == "127.0.0.1:11435")
        #expect(environment["LLAMA_ARG_CACHE_RAM"] == "2048")
        #expect(environment["OLLAMA_CONTEXT_LENGTH"] == "32768")
        #expect(environment["OLLAMA_NUM_PARALLEL"] == "1")
    }

    @Test func shuttingDownAnUnownedManagerCannotStartOrStopAForeignService() async {
        let manager = LocalAIModelManager()
        await manager.shutdownOwnedService()
        await #expect(throws: CancellationError.self) {
            try await manager.ensureService()
        }
    }

    private actor IndependentTransport {
        var sequence: [String] = []
        func send(_ request: URLRequest) throws -> (Data, URLResponse) {
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            let messages = body["messages"] as! [[String: Any]]
            let purpose = (messages[0]["content"] as! String).contains("Assess visible editorial purpose")
            let images = messages[0]["images"] as! [String]
            #expect(messages.count == 1 && images.count == 1)
            sequence.append((purpose ? "purpose:" : "contact:") + images[0])
            let content: [String: Any] = purpose
                ? ["scene": "Clear river landscape", "orientation": "upright", "opaqueCoverFraction": 0,
                   "purpose": "establishing", "purposeConfidence": 0.95, "purposeEvidence": "A wide river view establishes the location"]
                : ["b_interaction": "none", "c_confidence": 0.95, "a_observation": "No hands are visible in this river landscape"]
            let encoded = String(data: try JSONSerialization.data(withJSONObject: content), encoding: .utf8)!
            let data = try JSONSerialization.data(withJSONObject: ["model": "fixture", "done": true,
                "done_reason": "stop", "message": ["content": encoded]])
            return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
    }

    @Test func frameSchedulingKeepsEveryIndependentObserverAndFrameIndex() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = IndependentTransport()
        let samples = (0..<5).map { VisualFrameSample(timestamp: Double($0), motion: 0, exposure: 0.5,
            detail: 0.5, labels: [], labelConfidence: 1, faceCount: 0,
            jpegBase64: "image-\($0)", histogram: [], luminanceFingerprint: []) }
        let reviewer = SelectedContentReviewer(cacheURL: root, model: "fixture", answerTransport: { try await transport.send($0) })
        let (purposes, contacts) = try await reviewer.inspectIndependentFrames(samples: samples,
            intentionalFadeSamples: [4], responseURL: root.appendingPathComponent("frames.json"))
        #expect(purposes.frames.map(\.index) == [0, 1, 2, 3, 4])
        #expect(contacts.map(\.index) == [0, 1, 2, 3])
        #expect(await transport.sequence == ["purpose:image-0", "contact:image-0", "purpose:image-1", "contact:image-1",
            "purpose:image-2", "contact:image-2", "purpose:image-3", "contact:image-3", "purpose:image-4"])
    }

    @Test func observationStringLengthsAreCheckedInUnicodeCodePoints() throws {
        let stringSchema: [String: Any] = ["type": "string", "minLength": 2, "maxLength": 2]
        try LocalModelResponseValidation.validate(#""е́""#, schema: stringSchema)
        try LocalModelResponseValidation.validate(#""ab""#, schema: stringSchema)
        for content in [#""a""#, #""abc""#] {
            #expect(throws: URLError.self) { try LocalModelResponseValidation.validate(content, schema: stringSchema) }
        }
    }

    private actor ObservationTransport {
        var prompts: [String] = []
        var inputs: [[String]] = []
        var models: [String] = []
        let alwaysInvalid: Bool
        init(alwaysInvalid: Bool = false) { self.alwaysInvalid = alwaysInvalid }
        func send(_ request: URLRequest) throws -> (Data, URLResponse) {
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            let messages = body["messages"] as! [[String: Any]]
            prompts.append(messages.compactMap { $0["content"] as? String }.joined(separator: "\n"))
            inputs.append(messages.flatMap { $0["images"] as? [String] ?? [] })
            models.append(body["model"] as! String)
            let content = prompts.count == 1 || alwaysInvalid
                ? #"{"observation":"absent"}"# : #"{"observation":"No people are visible beside the river."}"#
            return (try JSONSerialization.data(withJSONObject: ["model":"fixture", "done":true,
                "done_reason":"stop", "message":["content":content]]),
                HTTPURLResponse(url: request.url!, statusCode:200, httpVersion:nil, headerFields:nil)!)
        }
        var count: Int { prompts.count }
        var secondIsRepairWithSameEvidence: Bool {
            prompts.count == 2 && prompts[1].contains("FORMAT REPAIR") && prompts[1].contains("OBSERVATION FORMAT")
                && inputs[0] == inputs[1] && models == ["fixture", "fixture"]
        }
    }

    private var observationBody: [String: Any] {
        ["model":"fixture", "stream":false, "options":["num_predict":320],
         "format":["type":"object", "required":["observation"],
            "properties":["observation":["type":"string"]]],
         "messages":[["role":"user", "content":"Describe these exact images.", "images":["frame-a","frame-b"]]]]
    }

    private static func validateLiteralObservation(_ content: String) throws {
        let value = try JSONDecoder().decode([String:String].self, from:Data(content.utf8))
        guard (value["observation"] ?? "").split(whereSeparator: { !$0.isLetter }).count >= 3 else {
            throw URLError(.cannotParseResponse)
        }
    }

    @Test func callerInvariantIsCheckedBeforeCachingAndRepairedWithoutChangingEvidence() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = ObservationTransport()
        let reviewer = SelectedContentReviewer(cacheURL:root, model:"fixture", answerTransport:{ try await transport.send($0) })
        let answer = try await reviewer.modelAnswer(body:observationBody, responseURL:root.appendingPathComponent("first.json"),
            repairInstruction:"OBSERVATION FORMAT: provide a literal sentence, including absence.",
            validateObservation:Self.validateLiteralObservation)
        #expect(answer.contains("No people"))
        #expect(await transport.secondIsRepairWithSameEvidence)
        #expect(try await reviewer.modelAnswer(body:observationBody, responseURL:root.appendingPathComponent("reuse.json"),
            repairInstruction:"OBSERVATION FORMAT: provide a literal sentence, including absence.",
            validateObservation:Self.validateLiteralObservation) == answer)
        #expect(await transport.count == 2)
    }

    @Test func invalidPreviouslyCachedObservationGoesDirectlyToTargetedRepair() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = ObservationTransport()
        let reviewer = SelectedContentReviewer(cacheURL:root, model:"fixture", answerTransport:{ try await transport.send($0) })
        // Reproduce the old writer, which checked JSON shape but not the caller invariant.
        _ = try await reviewer.modelAnswer(body:observationBody, responseURL:root.appendingPathComponent("legacy.json"))
        let answer = try await reviewer.modelAnswer(body:observationBody, responseURL:root.appendingPathComponent("recovered.json"),
            repairInstruction:"OBSERVATION FORMAT: provide a literal sentence, including absence.",
            validateObservation:Self.validateLiteralObservation)
        #expect(answer.contains("No people"))
        #expect(await transport.secondIsRepairWithSameEvidence)
        #expect(await transport.count == 2)
    }

    @Test func twoStructurallyInvalidObservationsCannotBecomeACompletedCheck() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = ObservationTransport(alwaysInvalid:true)
        let reviewer = SelectedContentReviewer(cacheURL:root, model:"fixture", answerTransport:{ try await transport.send($0) })
        await #expect(throws: URLError.self) {
            _ = try await reviewer.modelAnswer(body:observationBody, responseURL:root.appendingPathComponent("bad.json"),
                validateObservation:Self.validateLiteralObservation)
        }
        #expect(await transport.count == 2)
        #expect(try FileManager.default.contentsOfDirectory(atPath:root.appendingPathComponent("ByExactRequestV3").path).isEmpty)
    }

    @Test func restartedJobDoesNotResendEitherRejectedRecipeOrRecordProgress() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = Transport(alwaysInvalid: true)
        let progress = SelectedContentReviewer.ObservationProgress()
        for name in ["first", "restarted", "restarted-again"] {
            let reviewer = SelectedContentReviewer(cacheURL: root, model: "fixture",
                answerTransport: { try await transport.send($0) }, observationProgress: progress)
            await #expect(throws: URLError.self) {
                _ = try await reviewer.modelAnswer(body: body, responseURL: root.appendingPathComponent(name + ".json"))
            }
        }
        #expect(await transport.count == 2)
        #expect(await progress.count == 0)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("ByExactRequestV3").path).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("RejectedByExactRequestV1").path).count == 4)
    }

    @Test func rejectedRecipeDoesNotPreventChangedEvidenceWeightsOrRules() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = Transport(alwaysInvalid: true)
        var input = body
        for step in 0..<4 {
            if step == 1 {
                var messages = input["messages"] as! [[String: Any]]
                messages[0]["images"] = ["different-frame", "frame-b"]
                input["messages"] = messages
            }
            let reviewer = SelectedContentReviewer(cacheURL: root, model: "fixture",
                answerTransport: { try await transport.send($0) },
                modelDigestOverride: step >= 2 ? "weights-b" : "weights-a",
                evidenceContext: step == 3 ? "new-interval-and-rules" : "original-interval-and-rules")
            await #expect(throws: URLError.self) {
                _ = try await reviewer.modelAnswer(body: input, responseURL: root.appendingPathComponent("step-\(step).json"))
            }
            #expect(await transport.count == (step + 1) * 2)
        }
    }

    private actor SequenceTransport {
        let contents: [String]
        let completed: Bool
        var count = 0
        init(_ contents: [String], completed: Bool = true) {
            self.contents = contents; self.completed = completed
        }
        func send(_ request: URLRequest) throws -> (Data, URLResponse) {
            let content = contents[min(count, contents.count - 1)]
            count += 1
            let data = try JSONSerialization.data(withJSONObject: ["model": "fixture", "done": completed,
                "done_reason": "stop", "message": ["content": content]])
            return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
    }

    @Test func malformedJSONCanRepairAndNewTargetedRecipeCanProgressAfterKnownFailures() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let invalid = SequenceTransport([#"{"confidence":"#])
        let original = SelectedContentReviewer(cacheURL: root, model: "fixture", answerTransport: { try await invalid.send($0) })
        await #expect(throws: URLError.self) {
            _ = try await original.modelAnswer(body: body, responseURL: root.appendingPathComponent("invalid.json"))
        }
        #expect(await invalid.count == 2)
        let corrected = SequenceTransport([#"{"confidence":0.95}"#])
        let changed = SelectedContentReviewer(cacheURL: root, model: "fixture", answerTransport: { try await corrected.send($0) })
        let answer = try await changed.modelAnswer(body: body, responseURL: root.appendingPathComponent("targeted.json"),
            repairInstruction: "Finish the confidence field and close the JSON object.")
        #expect(answer == #"{"confidence":0.95}"#)
        #expect(await corrected.count == 1)
        #expect(try String(contentsOf: root.appendingPathComponent("targeted.request.json"), encoding: .utf8).contains("Finish the confidence"))
    }

    @Test func incompleteEnvelopeDoesNotBecomePermanentRejectedObservation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let incomplete = SequenceTransport([#"{"confidence":0.95}"#], completed: false)
        let reviewer = SelectedContentReviewer(cacheURL: root, model: "fixture", answerTransport: { try await incomplete.send($0) })
        await #expect(throws: URLError.self) {
            _ = try await reviewer.modelAnswer(body: body, responseURL: root.appendingPathComponent("incomplete.json"))
        }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("RejectedByExactRequestV1").path))
        let complete = SequenceTransport([#"{"confidence":0.95}"#])
        let resumed = SelectedContentReviewer(cacheURL: root, model: "fixture", answerTransport: { try await complete.send($0) })
        #expect(try await resumed.modelAnswer(body: body, responseURL: root.appendingPathComponent("resumed.json")) == #"{"confidence":0.95}"#)
        #expect(await complete.count == 1)
    }

}
