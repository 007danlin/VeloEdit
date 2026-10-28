import Foundation
import Testing
@testable import VeloEditCore

@Suite struct ReviewObserverSchedulingTests {
    private actor Observer {
        let model: String
        let technicalFlag: Int?
        let contactFlag: Int?
        let purposeFlag: Int?
        let unresolvedTarget: Bool
        var requests: [(kind: String, index: Int, body: Data)] = []

        init(model: String, technicalFlag: Int?, contactFlag: Int?, purposeFlag: Int? = nil, unresolvedTarget: Bool = false) {
            self.model = model
            self.technicalFlag = technicalFlag
            self.contactFlag = contactFlag
            self.purposeFlag = purposeFlag
            self.unresolvedTarget = unresolvedTarget
        }

        func send(_ request: URLRequest) throws -> (Data, URLResponse) {
            let body = try #require(try JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
            #expect(body["model"] as? String == model)
            let message = try #require((body["messages"] as? [[String: Any]])?.first)
            let images = try #require(message["images"] as? [String])
            #expect(images.count == 1)
            let image = try #require(images.first)
            let index = try #require(Int(image.replacingOccurrences(of: "frame-", with: "")))
            let required = try #require((body["format"] as? [String: Any])?["required"] as? [String])
            let kind: String
            let answer: [String: Any]
            if required.contains("handlingEvidence") {
                kind = "technical"
                answer = ["observation": "A person stands beside the river", "content": "event", "obstructionFraction": 0,
                    "confidence": 0.95, "handlingEvidence": index == technicalFlag ? "direct-lens-contact" : "none"]
            } else if required.contains("purpose") {
                kind = "purpose"
                answer = ["scene": "A person beside a tree", "orientation": index == purposeFlag ? "sideways" : "upright", "opaqueCoverFraction": 0,
                    "purpose": "portrait", "purposeConfidence": 0.95, "purposeEvidence": "A clearly framed person beside the river"]
            } else if required.contains("b_interaction") {
                kind = "contact"
                let prompt = try #require(message["content"] as? String)
                #expect(prompt.contains("c_confidence must be a decimal probability")
                    == (model == AIAnalysisProfile.resolve(mode: .quality).modelID))
                answer = ["b_interaction": index == contactFlag ? "camera-adjustment" : "none", "c_confidence": 0.95,
                    "a_observation": index == contactFlag ? "A foreshortened arm reaches toward the recording lens" : "No hand interaction is visible"]
            } else if required.contains("target") {
                kind = "target"
                answer = unresolvedTarget
                    ? ["observation": "The visible hand's target cannot be identified in this image", "target": "unknown", "confidence": 0.7]
                    : ["observation": "A near hand reaches straight toward the recording viewpoint", "target": "filming-lens", "confidence": 0.95]
            } else {
                kind = "orientation"
                #expect(required.contains("orientationBasis"))
                answer = ["scene": "A tree grows vertically from ground toward sky", "orientation": "upright",
                    "orientationBasis": "world-reference", "opaqueCoverFraction": 0]
            }
            requests.append((kind, index, request.httpBody!))
            let content = String(data: try JSONSerialization.data(withJSONObject: answer), encoding: .utf8)!
            return (try JSONSerialization.data(withJSONObject: ["model": model, "done": true, "done_reason": "stop", "message": ["content": content]]),
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
    }

    @Test func independentPurposeRotationTriggersNeutralCheckWithoutPrimaryOrHandClaim() async throws {
        for mode in AIPowerMode.allCases {
            let model = AIAnalysisProfile.resolve(mode: mode).modelID
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let observer = Observer(model: model, technicalFlag: nil, contactFlag: nil, purposeFlag: 4)
            let samples = (0..<5).map { VisualFrameSample(timestamp: Double($0), motion: 0, exposure: 0.5,
                detail: 0.5, labels: [], labelConfidence: 1, faceCount: 1, jpegBase64: "frame-\($0)", histogram: [], luminanceFingerprint: []) }
            let reviewer = SelectedContentReviewer(cacheURL: root, model: model, answerTransport: { try await observer.send($0) })
            let (_, _, _, orientation) = try await reviewer.inspectFrameEvidence(samples: samples,
                primary: nil, intentionalFadeSamples: [], responseURL: root.appendingPathComponent("answer.json"))
            #expect(orientation?.frames.map(\.index) == Array(0..<5))
            let requests = await observer.requests
            for kind in ["technical", "purpose", "contact", "orientation"] {
                #expect(requests.filter { $0.kind == kind }.map(\.index).sorted() == Array(0..<5))
            }
            #expect(requests.first(where: { $0.kind == "orientation" })?.index == 4)
        }
    }

    @Test func unresolvedHandTargetRetainsAllOtherObservationsWithoutCertifyingContact() async throws {
        for mode in AIPowerMode.allCases {
            let model = AIAnalysisProfile.resolve(mode: mode).modelID
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let observer = Observer(model: model, technicalFlag: nil, contactFlag: 2, unresolvedTarget: true)
            let samples = (0..<5).map { VisualFrameSample(timestamp: Double($0), motion: 0, exposure: 0.5,
                detail: 0.5, labels: [], labelConfidence: 1, faceCount: 1, jpegBase64: "frame-\($0)", histogram: [], luminanceFingerprint: []) }
            let reviewer = SelectedContentReviewer(cacheURL: root, model: model, answerTransport: { try await observer.send($0) })
            let (technical, purpose, contacts, orientation) = try await reviewer.inspectFrameEvidence(samples: samples,
                primary: nil, intentionalFadeSamples: [], responseURL: root.appendingPathComponent("answer.json"))
            #expect(purpose.frames.count == 5 && contacts.count == 5 && orientation?.frames.count == 5)
            #expect(contacts[2].interaction == .unclear)
            #expect(contacts[2].evidence.contains("Camera observer:") && contacts[2].evidence.contains("Target observer:"))
            let requests = await observer.requests
            for kind in ["purpose", "contact", "orientation"] {
                #expect(requests.filter { $0.kind == kind }.map(\.index).sorted() == Array(0..<5))
            }
            let answer = try #require(SelectedContentReviewer.resolve(technical))
            let guarded = try #require(SelectedContentReviewer.applyingInteractionCertainty(contacts, to: answer))
            #expect(guarded.status == .uncertain && guarded.cameraAdjustmentSamples?.isEmpty != false)
        }
    }

    @Test func hotImageSchedulingPreservesEveryIndependentCheckIncludingLateClaims() async throws {
        let models = ["qwen3-vl:2b-instruct", "qwen3-vl:4b-instruct", "qwen3-vl:8b-instruct", "qwen3-vl:30b-a3b-instruct"]
        let samples = (0..<5).map { VisualFrameSample(timestamp: Double($0), motion: 0, exposure: 0.5,
            detail: 0.5, labels: [], labelConfidence: 1, faceCount: 1, jpegBase64: "frame-\($0)", histogram: [], luminanceFingerprint: []) }
        for model in models {
            var neutralRequests: [Int: Data] = [:]
            for (technicalFlag, contactFlag) in [(nil, nil), (0, nil), (3, nil), (nil, 3)] as [(Int?, Int?)] {
                let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: root) }
                let observer = Observer(model: model, technicalFlag: technicalFlag, contactFlag: contactFlag)
                let reviewer = SelectedContentReviewer(cacheURL: root, model: model, answerTransport: { try await observer.send($0) })
                let (_, purposes, contacts, neutral) = try await reviewer.inspectFrameEvidence(samples: samples,
                    primary: nil, intentionalFadeSamples: [], responseURL: root.appendingPathComponent("answer.json"))
                #expect(purposes.frames.map(\.index) == Array(0..<5))
                #expect(contacts.map(\.index) == Array(0..<5))
                let requests = await observer.requests
                for kind in ["technical", "purpose", "contact"] {
                    #expect(requests.filter { $0.kind == kind }.map(\.index) == Array(0..<5))
                }
                #expect(requests.filter { $0.kind == "technical" }.count == 5)
                let rotations = requests.filter { $0.kind == "orientation" }
                if technicalFlag != nil || contactFlag != nil {
                    #expect(neutral?.frames.map(\.index) == Array(0..<5))
                    #expect(rotations.count == 5 && rotations.map(\.index).sorted() == Array(0..<5))
                    let trigger = technicalFlag ?? contactFlag!
                    #expect(rotations.first?.index == trigger)
                    if trigger < 4 {
                        let neutralPosition = try #require(requests.firstIndex { $0.kind == "orientation" })
                        let nextPurpose = try #require(requests.firstIndex { $0.kind == "purpose" && $0.index == trigger + 1 })
                        #expect(neutralPosition < nextPurpose)
                    }
                    for rotation in rotations {
                        if let prior = neutralRequests[rotation.index] { #expect(prior == rotation.body) }
                        neutralRequests[rotation.index] = rotation.body
                    }
                } else {
                    #expect(neutral == nil && rotations.isEmpty)
                }
            }
        }
    }
}
