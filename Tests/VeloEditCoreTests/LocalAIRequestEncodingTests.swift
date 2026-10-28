import Foundation
import Testing
@testable import VeloEditCore

struct LocalAIRequestEncodingTests {
    private let order = ["observation", "confidence", "content", "handlingEvidence", "obstructionFraction"]
    private var body: [String: Any] {
        ["model": "fixture", "stream": true, "think": false,
         "messages": [["role": "user", "content": "Keep \"quotes\", /slashes/ and русские слова", "images": ["same-frame"]]],
         "format": ["type": "object", "required": order.sorted(), "additionalProperties": false,
                    "properties": ["observation": ["type": "string", "minLength": 12, "maxLength": 200],
                                   "confidence": ["type": "number", "minimum": 0, "maximum": 1],
                                   "content": ["type": "string", "enum": ["event", "uncertain"]],
                                   "handlingEvidence": ["type": "string", "enum": ["none", "direct-lens-contact"]],
                                   "obstructionFraction": ["type": "number", "minimum": 0, "maximum": 1]]]]
    }

    @Test func changesOnlySchemaPropertyOrderAndRejectsMissingFields() throws {
        let sorted = try LocalAIRequestEncoding.data(body)
        #expect(try sorted == JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]))
        let ordered = try LocalAIRequestEncoding.data(body, responseFieldOrder: order)
        #expect(ordered != sorted)
        let decoded = try JSONSerialization.jsonObject(with: ordered)
        #expect(try JSONSerialization.data(withJSONObject: decoded, options: [.sortedKeys]) == sorted)
        let text = String(decoding: ordered, as: UTF8.self)
        #expect(text.contains(#""properties":{"observation":{"#))
        #expect(throws: URLError.self) { try LocalAIRequestEncoding.data(body, responseFieldOrder: Array(order.dropLast())) }
        #expect(throws: URLError.self) { try LocalAIRequestEncoding.data(body, responseFieldOrder: Array(repeating: "observation", count: order.count)) }
    }

    @Test func transportAndRecoveryPreserveAlreadyStreamingRequestBytes() async throws {
        actor Captured {
            var bodies: [Data] = []
            func respond(_ request: URLRequest) throws -> (Data, URLResponse) {
                bodies.append(request.httpBody!)
                if bodies.count == 1 { throw LocalAITransportFailure.noProgress }
                return (Data(), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
        }
        let captured = Captured()
        let client = LocalAIInferenceClient(recover: { model in #expect(model == "fixture") },
            transport: { request, _, _ in try await captured.respond(request) })
        let data = try LocalAIRequestEncoding.data(body, responseFieldOrder: order)
        var request = URLRequest(url: URL(string: "http://127.0.0.1:1/api/chat")!)
        request.httpBody = data
        _ = try await client.response(for: request, preservingRequestBody: true)
        #expect(await captured.bodies == [data, data])
    }

    @Test func nestedTitleOrderKeepsAllConstraintsAndRejectsAnUnknownPath() throws {
        let body: [String: Any] = ["format": ["type": "object", "properties": ["titles": ["type": "array", "maxItems": 2,
            "items": ["type": "object", "properties": ["text": ["type": "string", "maxLength": 48],
                "proposalIndex": ["type": "integer", "enum": [0, 1]]], "required": ["proposalIndex", "text"], "additionalProperties": false]]]]]
        let ordered = try LocalAIRequestEncoding.data(body, responseArrayItemFieldOrders: ["titles": ["text", "proposalIndex"]])
        let decoded = try JSONSerialization.jsonObject(with: ordered)
        #expect(try JSONSerialization.data(withJSONObject: decoded, options: [.sortedKeys]) == LocalAIRequestEncoding.data(body))
        #expect(String(decoding: ordered, as: UTF8.self).contains(#""properties":{"text":{"#))
        #expect(throws: URLError.self) { try LocalAIRequestEncoding.data(body, responseArrayItemFieldOrders: ["missing": ["text", "proposalIndex"]]) }
        #expect(throws: URLError.self) { try LocalAIRequestEncoding.data(body, responseArrayItemFieldOrders: ["titles": ["text"]]) }
    }

    @Test func ordinaryCallersKeepTheirPreviousCanonicalSchemaOrder() async throws {
        actor Captured {
            var body: Data?
            func respond(_ request: URLRequest) -> (Data, URLResponse) {
                body = request.httpBody
                return (Data(), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
        }
        let captured = Captured()
        let client = LocalAIInferenceClient(recover: { _ in Issue.record("Unexpected recovery") },
            transport: { request, _, _ in await captured.respond(request) })
        var request = URLRequest(url: URL(string: "http://127.0.0.1:1/api/chat")!)
        request.httpBody = try LocalAIRequestEncoding.data(body, responseFieldOrder: order)
        _ = try await client.response(for: request)
        let expected = try LocalAIRequestEncoding.data(body)
        #expect(await captured.body == expected)
        var nonstreaming = body
        nonstreaming["stream"] = false
        request.httpBody = try LocalAIRequestEncoding.data(nonstreaming, responseFieldOrder: order)
        await #expect(throws: URLError.self) {
            _ = try await client.response(for: request, preservingRequestBody: true)
        }
        #expect(await captured.body == expected)
    }

    @Test func newOrderCannotReuseOldAnswerButUnchangedIndependentAnswersRemainReusable() async throws {
        actor Captured {
            var count = 0
            func respond() throws -> String {
                count += 1
                return #"{"observation":"A clear visible scene", "confidence":0.95, "content":"event", "handlingEvidence":"none", "obstructionFraction":0}"#
            }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let captured = Captured()
        let reviewer = SelectedContentReviewer(cacheURL: root, model: "fixture", answerTransport: { request in
            let content = try await captured.respond()
            let data = try JSONSerialization.data(withJSONObject: ["model": "fixture", "done": true,
                "done_reason": "stop", "message": ["content": content]])
            return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        _ = try await reviewer.modelAnswer(body: body, responseURL: root.appendingPathComponent("original.json"))
        _ = try await reviewer.modelAnswer(body: body, responseURL: root.appendingPathComponent("ordered.json"), responseFieldOrder: order)
        #expect(await captured.count == 2)
        _ = try await reviewer.modelAnswer(body: body, responseURL: root.appendingPathComponent("ordered-again.json"), responseFieldOrder: order)
        _ = try await reviewer.modelAnswer(body: body, responseURL: root.appendingPathComponent("original-again.json"))
        #expect(await captured.count == 2)
    }

    @Test(arguments: AIPowerMode.allCases)
    func orderIsFrozenAndDoesNotInvalidateUnchangedObservationInputs(mode: AIPowerMode) throws {
        let profile = FilmProcessProfile(analysis: .resolve(mode: mode))
        #expect((profile.technicalObservationFirst == true) == (mode == .fast))
        var saved = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(profile)) as? [String: Any])
        saved.removeValue(forKey: "technicalObservationFirst")
        let legacy = try JSONDecoder().decode(FilmProcessProfile.self, from: JSONSerialization.data(withJSONObject: saved))
        #expect(legacy.technicalObservationFirst == nil)
        #expect(try legacy.bindingModelDigest("same-weights").technicalObservationFirst == nil)
        #expect(legacy.observationIdentity == profile.observationIdentity)
        #expect((legacy.reviewIdentity != profile.reviewIdentity) == (mode == .fast))
        #expect(try JSONDecoder().decode(FilmProcessProfile.self, from: JSONEncoder().encode(profile)) == profile)
    }
}
