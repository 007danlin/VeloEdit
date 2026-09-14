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
    @Test func invalidSceneIdentityNeverCrashesOrSilentlyLabelsAnotherClip() throws {
        for values in [[scene(4), scene(4)], [scene(0), scene(7)], [scene(4)], [scene(0), scene(4), scene(7)]] {
            let content = try json(values)
            #expect(throws: URLError.self) { try OllamaVisionRuntime.parseBatch(content, indices: [4, 7]) }
        }
        let content = try json([scene(4, quality: 7)])
        #expect(throws: URLError.self) { try OllamaVisionRuntime.parseBatch(content, indices: [4]) }
    }
}
