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
