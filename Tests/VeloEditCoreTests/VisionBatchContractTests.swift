import Foundation
import Testing
@testable import VeloEditCore

@Suite struct VisionBatchContractTests {
    private func scene(_ index: Int, quality: Double = 0.8) -> [String: Any] {
        ["index": index, "scene": "A buggy beside a road", "tags": ["buggy", "outdoor"],
         "reason": "Shows the vehicle", "interest": 0.7, "action": 0.1,
         "quality": quality, "stability": 0.8, "storyValue": 0.7]
    }
    private func json(_ values: [[String: Any]]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: ["scenes": values]), as: UTF8.self)
    }
    @Test func schemaCarriesActualIndicesAndExactSceneCountWithoutPlaceholderScores() throws {
        let schema = OllamaVisionRuntime.responseSchema(indices: [4, 7])
        let properties = try #require(schema["properties"] as? [String: Any])
        let scenes = try #require(properties["scenes"] as? [String: Any])
        #expect(scenes["minItems"] as? Int == 2)
        #expect(scenes["maxItems"] as? Int == 2)
        let item = try #require(scenes["items"] as? [String: Any])
        let fields = try #require(item["properties"] as? [String: Any])
        #expect((fields["index"] as? [String: Any])?["enum"] as? [Int] == [4, 7])
        #expect(!(item["required"] as? [String] ?? []).contains("originalAudioUsefulness"))
        #expect(JSONSerialization.isValidJSONObject(schema))
    }

    @Test func observationOrderChangesWireOrderWithoutChangingEvidenceOrConstraints() throws {
        let body: [String: Any] = ["model": "qwen3-vl:2b-instruct", "format": OllamaVisionRuntime.responseSchema(indices: [4, 7]),
            "messages": [["role": "user", "content": "Describe both intervals", "images": ["first", "second", "first"]]],
            "options": ["num_ctx": 16384, "num_predict": 768, "temperature": 0, "seed": 42]]
        for request in [body, LocalModelResponseValidation.repairBody(body)] {
            let old = try OllamaVisionRuntime.requestData(request, sceneObservationFirst: false)
            let ordered = try OllamaVisionRuntime.requestData(request, sceneObservationFirst: true)
            #expect(old != ordered)
            #expect(try JSONSerialization.data(withJSONObject: JSONSerialization.jsonObject(with: ordered), options: [.sortedKeys]) == old)
            let text = String(decoding: ordered, as: UTF8.self)
            let index = try #require(text.range(of: #""index":{"#))
            let scene = try #require(text.range(of: #""scene":{"#))
            let action = try #require(text.range(of: #""action":{"#))
            #expect(index.lowerBound < scene.lowerBound && scene.lowerBound < action.lowerBound)
        }
    }

    @Test(arguments: AIPowerMode.allCases)
    func savedAnalysisOrderAndUnchangedReviewEvidenceRemainFrozen(mode: AIPowerMode) throws {
        let profile = AIAnalysisProfile.resolve(mode: mode)
        #expect(profile.sceneObservationFirst == nil)
        var saved = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(profile)) as? [String: Any])
        saved.removeValue(forKey: "sceneObservationFirst")
        let legacy = try JSONDecoder().decode(AIAnalysisProfile.self, from: JSONSerialization.data(withJSONObject: saved))
        #expect(legacy.sceneObservationFirst == nil)
        #expect(legacy.cacheKey == profile.cacheKey)
        saved["sceneObservationFirst"] = true
        let frozenExperiment = try JSONDecoder().decode(AIAnalysisProfile.self, from: JSONSerialization.data(withJSONObject: saved))
        #expect(frozenExperiment.cacheKey == legacy.cacheKey + ":scene-observation-first-v2-wire")
        #expect(frozenExperiment.cacheKey != legacy.cacheKey + ":scene-observation-first-v1")
        #expect(try FilmProcessProfile(analysis: frozenExperiment).bindingModelDigest("unchanged-weights").analysis.sceneObservationFirst == true)
        let oldFilm = FilmProcessProfile(analysis: legacy)
        let rebound = try oldFilm.bindingModelDigest("unchanged-weights")
        #expect(rebound.analysis.sceneObservationFirst == nil)
        #expect(rebound.modelID == profile.modelID)
        #expect(oldFilm.reviewIdentity == FilmProcessProfile(analysis: profile).reviewIdentity)
        #expect(try JSONDecoder().decode(AIAnalysisProfile.self, from: JSONEncoder().encode(profile)) == profile)
        #expect(AIAnalysisProfile.resolve(mode: mode, thermalState: .serious).sceneObservationFirst == profile.sceneObservationFirst)
    }

    @Test func actualAnalysisTransportRetainsSceneOrderThroughFormatRepair() async throws {
        actor Captured {
            var requests: [Data] = []
            func reply(_ request: URLRequest) throws -> (Data, URLResponse) {
                requests.append(try #require(request.httpBody))
                let content = requests.count == 1 ? "{}" : #"{"scenes":[{"index":4,"scene":"A bird flying against the sky","reason":"Readable calm wildlife scene","tags":["bird","sky"],"action":0.2,"interest":0.8,"quality":0.8,"stability":0.8,"storyValue":0.8}]}"#
                let data = try JSONSerialization.data(withJSONObject: ["model": "qwen3-vl:2b-instruct", "done": true,
                    "done_reason": "stop", "message": ["role": "assistant", "content": content]])
                return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
        }
        let captured = Captured()
        let client = LocalAIInferenceClient(recover: { _ in Issue.record("No transport recovery expected") },
            modelDigest: { _ in "fixture-weights" },
            transport: { request, _, _ in try await captured.reply(request) })
        let runtime = OllamaVisionRuntime(inferenceClient: client, installedModelDigest: { _ in "fixture-weights" })
        let frames = [1.0, 2.0, 3.0].map { time in
            VisualFrameSample(timestamp: time, motion: 0, exposure: 0.5, detail: 0.5, labels: [], labelConfidence: 1,
                faceCount: 0, jpegBase64: "exact-frame-\(time)", histogram: [], luminanceFingerprint: [])
        }
        let result = try await runtime.analyzeBatch(scenes: [.init(index: 4, frames: frames, telemetry: nil, sourceWindow: 1...3)],
            model: "qwen3-vl:2b-instruct", thinking: false, timeout: 20, sceneObservationFirst: true)
        #expect(result[4]?.interest == 0.8)
        let requests = await captured.requests
        #expect(requests.count == 2)
        for data in requests {
            let text = String(decoding: data, as: UTF8.self)
            let scene = try #require(text.range(of: #""scene":{"#))
            let action = try #require(text.range(of: #""action":{"#))
            #expect(scene.lowerBound < action.lowerBound)
            let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(body["stream"] as? Bool == true)
            let messages = try #require(body["messages"] as? [[String: Any]])
            #expect(messages.flatMap { $0["images"] as? [String] ?? [] } == frames.map(\.jpegBase64))
        }
    }
    @Test func validBatchKeepsIdentityAndDoesNotTurnCalmnessIntoBadQuality() throws {
        let batch = try OllamaVisionRuntime.parseBatch(json([scene(7), scene(4)]), indices: [4, 7])
        #expect(Set(batch.keys) == [4, 7])
        #expect(batch[4]?.quality == 0.8)
        #expect(batch[4]?.action == 0.1)
        #expect(batch[4]?.tags?.contains("buggy") == true)
    }
    @Test func malformedDescriptionsCannotBecomeRankedOrCachedSceneEvidence() throws {
        for field in ["scene", "reason"] {
            for text in ["1", ":{", "scene index=1", "{0} A person stands by the river", "{\"index\": 2, \"action\": 0}", "See scene 1 for the details"] {
                var value = scene(4); value[field] = text
                let content = try json([value])
                #expect(throws: URLError.self) { try OllamaVisionRuntime.parseBatch(content, indices: [4]) }
            }
        }
        for description in ["A hand covers the view.", "The dark image does not reveal a readable scene.", "Человек стоит у берега реки.", "A device screen shows {status: ready} beside the controls."] {
            var value = scene(4); value["scene"] = description
            let result = try OllamaVisionRuntime.parseBatch(json([value]), indices: [4])
            #expect(result[4]?.scene == description)
        }
    }

    @Test func groupedSceneInputsKeepEveryImageAndDistinguishOutsideContext() {
        func frame(_ image: String, at time: Double) -> VisualFrameSample {
            .init(timestamp: time, motion: 0, exposure: 0.5, detail: 0.5, labels: [], labelConfidence: 1,
                faceCount: 0, jpegBase64: image, histogram: [], luminanceFingerprint: [])
        }
        let scenes = [VLMSceneInput(index: 4, frames: [frame("a", at: 1), frame("b", at: 2)], telemetry: nil, sourceWindow: 1...3),
            VLMSceneInput(index: 9, frames: [frame("b", at: 2), frame("c", at: 4)], telemetry: nil, sourceWindow: 3...5)]
        let layout = VisionEvidenceLayout(frames: scenes.map(\.frames))
        for shared in [false, true] {
            let text = OllamaVisionRuntime.sceneGrouping(scenes: scenes, layout: layout, sharesImages: shared)
            #expect(text.contains("scene index=4: frames=2, selected=[1.0,3.0]s"))
            #expect(text.contains("scene index=9: frames=2, selected=[3.0,5.0]s"))
            #expect(text.contains("image 1 at 1.0s outside=false; image 2 at 2.0s outside=false"))
            #expect(text.contains(shared ? "image 2 at 2.0s outside=true; image 3 at 4.0s outside=false"
                : "image 3 at 2.0s outside=true; image 4 at 4.0s outside=false"))
        }
    }

    @Test func invalidSceneIdentityNeverCrashesOrSilentlyLabelsAnotherClip() throws {
        for values in [[scene(4), scene(4)], [scene(0), scene(7)], [scene(4)], [scene(0), scene(4), scene(7)]] {
            let content = try json(values)
            #expect(throws: URLError.self) { try OllamaVisionRuntime.parseBatch(content, indices: [4, 7]) }
        }
        let content = try json([scene(4, quality: 7)])
        #expect(throws: URLError.self) { try OllamaVisionRuntime.parseBatch(content, indices: [4]) }
    }
}
