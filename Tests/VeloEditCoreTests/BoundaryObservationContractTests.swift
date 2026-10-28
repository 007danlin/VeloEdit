import Foundation
import Testing
@testable import VeloEditCore

@Suite struct BoundaryObservationContractTests {
    private actor Observer {
        let certainty: Double
        let visibility: String
        let count: Int
        let postures: [String]
        let jointCertainty: Double
        let postureByImage: [String: String]
        var models: Set<String> = []
        var postureImages: [[String]] = []
        init(certainty: Double = 0.95, visibility: String = "absent", count: Int = 0, postures: [String] = [], jointCertainty: Double = 0.95, postureByImage: [String: String] = [:]) {
            self.certainty = certainty; self.visibility = visibility
            self.count = count; self.postures = postures
            self.jointCertainty = jointCertainty
            self.postureByImage = postureByImage
        }
        func send(_ request: URLRequest) throws -> (Data, URLResponse) {
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            let model = body["model"] as! String
            models.insert(model)
            let required = (body["format"] as! [String: Any])["required"] as! [String]
            let content: [String: Any]
            if required.contains("peopleVisibility") {
                let messages = body["messages"] as! [[String: Any]]
                let images = messages.flatMap { $0["images"] as? [String] ?? [] }
                postureImages.append(images)
                if let image = images.first, let posture = postureByImage[image] {
                    content = ["a_observation": "A person is \(posture) with visible physical support.",
                        "peopleVisibility": "visible", "peopleCount": 1, "postures": [posture], "confidence": certainty]
                } else {
                    content = ["a_observation": "No people are visible in this clear view of flowing water.",
                        "peopleVisibility": visibility, "peopleCount": count, "postures": postures, "confidence": certainty]
                }
            } else if required.contains("b_jointObjectPairs") {
                content = ["a_observation": "The two people do not visibly share physical support of an object.",
                    "b_jointObjectPairs": 0, "c_confidence": jointCertainty]
            } else if required.contains("b_finiteTask") {
                content = ["a_reason": "Water flows continuously without a distinct task", "b_finiteTask": false, "c_confidence": 0.95]
            } else if required.contains("b_category") {
                content = ["b_category": "activity", "c_certainty": 0.95]
            } else if required.contains("a_selectedAction") {
                content = ["a_selectedAction": "Water flows continuously over rocks without a finite task.",
                    "b_endAndFollowing": "The same water continues flowing before and after the cut.",
                    "c_finiteTaskObserved": false, "d_immediateOutcomeMissing": false,
                    "verdict": "continuous", "confidence": 0.95]
            } else {
                content = ["observation": "Water flows continuously over rocks before and after the selected interval."]
            }
            let encoded = String(decoding: try JSONSerialization.data(withJSONObject: content), as: UTF8.self)
            let envelope = try JSONSerialization.data(withJSONObject: ["model": model, "done": true,
                "done_reason": "stop", "message": ["content": encoded]])
            return (envelope, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
    }

    private var samples: [VisualFrameSample] {
        (0..<8).map { .init(timestamp: Double($0), motion: 0, exposure: 0.5, detail: 0.5,
            labels: [], labelConfidence: 1, faceCount: 0, jpegBase64: "image-\($0)", histogram: [], luminanceFingerprint: []) }
    }

    @Test func everyModeChecksAllFourImagesAndDoesNotNormalizeZeroCertainty() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for mode in AIPowerMode.allCases {
            for certainty in [0.0, 0.95] {
                let observer = Observer(certainty: certainty)
                let model = AIAnalysisProfile.resolve(mode: mode).modelID
                let cache = root.appendingPathComponent("\(mode.rawValue)-\(certainty)")
                let reviewer = SelectedContentReviewer(cacheURL: cache, model: model,
                    answerTransport: { try await observer.send($0) })
                let boundary = try await reviewer.inspectActionBoundary(samples: samples,
                    responseURL: cache.appendingPathComponent("boundary.json"))
                #expect(boundary.passes == (certainty >= 0.8))
                #expect(await observer.models == [model])
                #expect(await observer.postureImages == [7, 5, 3, 1].map { ["image-\($0)"] })
            }
        }
    }

    @Test func cacheSchedulingDoesNotReverseTheObservedAction() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for mode in AIPowerMode.allCases {
            let observer = Observer(postureByImage: ["image-1": "standing", "image-3": "bending", "image-5": "bending", "image-7": "sitting"])
            let cache = root.appendingPathComponent(mode.rawValue)
            let reviewer = SelectedContentReviewer(cacheURL: cache, model: AIAnalysisProfile.resolve(mode: mode).modelID,
                answerTransport: { try await observer.send($0) })
            let boundary = try await reviewer.inspectActionBoundary(samples: samples,
                responseURL: cache.appendingPathComponent("boundary.json"))
            #expect(boundary.verdict == .interrupted)
            #expect(boundary.startObservation.contains("standing"))
            #expect(boundary.endObservation.contains("bending"))
            #expect(boundary.followingObservation.contains("sitting"))
        }
    }

    @Test func contradictoryPresenceCannotCertifyAnyModesBoundary() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for mode in AIPowerMode.allCases {
            for (visibility, count, postures) in [("absent", 1, ["sitting"]), ("visible", 0, []), ("unclear", 0, []), ("absent", 0, ["sitting"])] {
                let observer = Observer(visibility: visibility, count: count, postures: postures)
                let cache = root.appendingPathComponent(UUID().uuidString)
                let reviewer = SelectedContentReviewer(cacheURL: cache, model: AIAnalysisProfile.resolve(mode: mode).modelID,
                    answerTransport: { try await observer.send($0) })
                await #expect(throws: (any Error).self) {
                    try await reviewer.inspectActionBoundary(samples: samples, responseURL: cache.appendingPathComponent("boundary.json"))
                }
            }
        }
    }

    @Test func uncertainIndependentAbsenceCannotBecomeAPositiveCertificate() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for mode in AIPowerMode.allCases {
            for jointCertainty in [0.0, 0.7, 0.79, 0.95] {
                let observer = Observer(visibility: "visible", count: 2,
                    postures: ["sitting", "sitting"], jointCertainty: jointCertainty)
                let cache = root.appendingPathComponent(UUID().uuidString)
                let model = AIAnalysisProfile.resolve(mode: mode).modelID
                let reviewer = SelectedContentReviewer(cacheURL: cache, model: model,
                    answerTransport: { try await observer.send($0) })
                let boundary = try await reviewer.inspectActionBoundary(samples: samples,
                    responseURL: cache.appendingPathComponent("boundary.json"))
                #expect(boundary.passes == (jointCertainty >= 0.8))
                #expect(boundary.confidence <= jointCertainty)
                #expect(await observer.models == [model])
            }
        }
    }
}
