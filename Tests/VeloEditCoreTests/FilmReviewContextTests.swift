import Foundation
import Testing
@testable import VeloEditCore

struct FilmReviewContextTests {
    private func legacy(_ profile: FilmProcessProfile) throws -> FilmProcessProfile {
        var data = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(profile)) as? [String: Any])
        data.removeValue(forKey: "singleImageReviewContextTokens")
        return try JSONDecoder().decode(FilmProcessProfile.self, from: JSONSerialization.data(withJSONObject: data))
    }

    @Test func smallContextNeverLeaksIntoMultiImageOrLongTextWork() throws {
        for mode in AIPowerMode.allCases {
            let profile = FilmProcessProfile(analysis: .resolve(mode: mode))
            try FilmProcessContext.$current.withValue(profile) {
                for scoped in [false, true] {
                    try FilmProcessContext.$minimumReviewContextTokens.withValue(scoped ? 4096 : nil) {
                        for images in [[], ["complete-original-image"], ["frame-1", "frame-2"]] as [[String]] {
                            for explicit in [4096, 8192, 32768] {
                                let original: [String: Any] = ["model": profile.modelID,
                                    "messages": [["role": "user", "content": "Every original observation", "images": images]],
                                    "options": ["num_ctx": explicit, "num_predict": 320]]
                                let body = try FilmProcessContext.requestBody(original)
                                let options = try #require(body["options"] as? [String: Any])
                                #expect(options["num_ctx"] as? Int == max(explicit,
                                    scoped && images.count == 1 && profile.singleImageReviewContextTokens != nil ? 4096 : profile.contextTokens))
                                #expect(options["num_predict"] as? Int == 320)
                                #expect(body["model"] as? String == profile.modelID)
                                #expect((body["messages"] as? [[String: Any]])?.first?["images"] as? [String] == images)
                            }
                        }
                    }
                }
            }
        }
    }

    @Test func recoveredLegacyJobsKeepTheirContextAndRawBoundaryIdentity() throws {
        for mode in AIPowerMode.allCases {
            let current = FilmProcessProfile(analysis: .resolve(mode: mode), modelDigest: "same-weights")
            let saved = try legacy(current)
            #expect(saved.singleImageReviewContextTokens == nil)
            #expect(saved.observationIdentity == current.observationIdentity)
            #expect(saved.reviewIdentity == current.observationIdentity)
            #expect((saved.reviewIdentity == current.reviewIdentity) == (current.singleImageReviewContextTokens == nil))
            try FilmProcessContext.$current.withValue(saved) {
                try FilmProcessContext.$minimumReviewContextTokens.withValue(4096) {
                    let body = try FilmProcessContext.requestBody(["model": saved.modelID,
                        "messages": [["role": "user", "images": ["complete-original-image"]]],
                        "options": ["num_ctx": 4096]])
                    #expect((body["options"] as? [String: Any])?["num_ctx"] as? Int == saved.contextTokens)
                }
            }
        }
    }

    @Test func exactReplyCacheSeparatesChangedImageRequestsButKeepsUnchangedTemporalWork() async throws {
        actor Calls {
            var contexts: [Int] = []
            func send(_ request: URLRequest) throws -> (Data, URLResponse) {
                let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
                contexts.append((body["options"] as! [String: Any])["num_ctx"] as! Int)
                let data = try JSONSerialization.data(withJSONObject: ["model": body["model"]!,
                    "done": true, "done_reason": "stop", "message": ["content": "{\"observation\":\"literal preserved evidence\"}"]])
                return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let current = FilmProcessProfile(analysis: .resolve(mode: .fast))
        let saved = try legacy(current)
        let calls = Calls()
        let reviewer = SelectedContentReviewer(cacheURL: root, model: current.modelID,
            answerTransport: { try await calls.send($0) }, evidenceContext: current.observationIdentity)
        func body(_ images: [String]) -> [String: Any] {
            ["model": current.modelID, "messages": [["role": "user", "content": "Same complete question", "images": images]],
             "options": ["num_ctx": 4096, "num_predict": 320]]
        }
        try await FilmProcessContext.$current.withValue(saved) {
            _ = try await reviewer.modelAnswer(body: body(["image-1"]), responseURL: root.appendingPathComponent("old-frame.json"))
            _ = try await reviewer.modelAnswer(body: body(["image-1", "image-2"]), responseURL: root.appendingPathComponent("old-boundary.json"))
        }
        try await FilmProcessContext.$current.withValue(current) {
            try await FilmProcessContext.$minimumReviewContextTokens.withValue(4096) {
                for name in ["new-frame", "reused-new-frame"] {
                    _ = try await reviewer.modelAnswer(body: body(["image-1"]), responseURL: root.appendingPathComponent(name + ".json"))
                }
                _ = try await reviewer.modelAnswer(body: body(["image-1", "image-2"]), responseURL: root.appendingPathComponent("retained-boundary.json"))
            }
        }
        #expect(await calls.contexts == [16384, 16384, 4096])
    }
}
