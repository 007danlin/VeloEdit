import Foundation
import Testing
@testable import VeloEditCore

struct VisionEvidenceLayoutTests {
    @Test func sharedEvidenceStillRequiresSelfContainedDescriptions() {
        #expect(!VisionEvidenceLayout.isStandaloneDescription("Same as scene 1, no change."))
        #expect(!VisionEvidenceLayout.isStandaloneDescription("Continues the sequence from scene 1."))
        #expect(!VisionEvidenceLayout.isStandaloneDescription("Как в сцене 2."))
        #expect(VisionEvidenceLayout.isStandaloneDescription("Boats cross a turquoise harbor beside a hotel."))
    }
    @Test func multipleImagesHaveExplicitSeparatedMarkersWithoutChangingEvidenceOrOptions() {
        let original: [String: Any] = ["model": "qwen3-vl:8b-instruct", "options": ["num_ctx": 32768],
            "messages": [["role": "user", "content": "Evaluate images 0 and 1 independently.", "images": ["a", "b"]]]]
        let encoded = LocalVisionMessageEncoding.separatingImages(in: original)
        let message = (encoded["messages"] as! [[String: Any]])[0]
        #expect(message["images"] as? [String] == ["a", "b"])
        #expect(message["content"] as? String == "Image 0: [img]\nImage 1: [img]\nEvaluate images 0 and 1 independently.")
        #expect(encoded["model"] as? String == original["model"] as? String)
        #expect(NSDictionary(dictionary: encoded["options"] as! [String: Any]).isEqual(to: original["options"] as! [String: Any]))
        #expect(NSDictionary(dictionary: LocalVisionMessageEncoding.separatingImages(in: encoded)).isEqual(to: encoded))
        let primary = LocalVisionMessageEncoding.separatingImages(in: original, firstIndex: 1)
        #expect(((primary["messages"] as! [[String: Any]])[0]["content"] as! String).hasPrefix("Image 1: [img]\nImage 2: [img]"))
    }

    @Test func singleAndTemporalObserversShareTheSameImagePrefix() {
        let original: [String: Any] = ["messages": [["content": "Inspect this SINGLE image.", "images": ["a"]]]]
        let encoded = LocalVisionMessageEncoding.separatingImages(in: original)
        let message = (encoded["messages"] as! [[String: Any]])[0]
        #expect(message["images"] as? [String] == ["a"])
        #expect(message["content"] as? String == "Image 0: [img]\nInspect this SINGLE image.")
        #expect(NSDictionary(dictionary: LocalVisionMessageEncoding.separatingImages(in: encoded)).isEqual(to: encoded))
        let empty: [String: Any] = ["messages": [["content": "Text only.", "images": [] as [String]]]]
        #expect(NSDictionary(dictionary: LocalVisionMessageEncoding.separatingImages(in: empty)).isEqual(to: empty))
    }

    private func frame(_ image: String, at time: Double) -> VisualFrameSample {
        VisualFrameSample(timestamp: time, motion: 0, exposure: 0.8, detail: 0.8,
                          labels: [], labelConfidence: 0, faceCount: 0,
                          jpegBase64: image, histogram: [], luminanceFingerprint: [])
    }

    @Test func sharedImagesReconstructEverySceneAndRepeatedMomentExactly() {
        let scenes = [[frame("a", at: 1), frame("b", at: 2), frame("b", at: 3)],
                      [frame("b", at: 2), frame("c", at: 4)],
                      [frame("a", at: 1), frame("b", at: 2), frame("b", at: 3)]]
        let layout = VisionEvidenceLayout(frames: scenes)
        #expect(layout.images == ["a", "b", "c"])
        for (index, scene) in scenes.enumerated() {
            #expect(layout.references[index].map { layout.images[$0 - 1] } == scene.map(\.jpegBase64))
            #expect(layout.references[index].count == scene.count)
        }
        #expect(layout.references[0] == [1, 2, 2])
    }

    @Test func similarButDifferentPixelsAreNeverMerged() {
        let layout = VisionEvidenceLayout(frames: [[frame("almost-identical-A", at: 1)],
                                                  [frame("almost-identical-B", at: 1)]])
        #expect(layout.images.count == 2)
        #expect(layout.references == [[1], [2]])
    }

    @Test func schedulingPreservesBatchMembershipAndEachScenesTemporalOrder() {
        let scenes = [[frame("c", at: 1), frame("d", at: 2)],
                      [frame("a", at: 3), frame("b", at: 4)],
                      [frame("e", at: 5)]]
        let order = VisionEvidenceLayout.order(frames: scenes, after: ["a", "b", "c"])
        #expect(order == [1, 0, 2])
        #expect(Set(order) == Set(scenes.indices))
        let ordered = order.map { scenes[$0] }
        let layout = VisionEvidenceLayout(frames: ordered)
        for (position, originalIndex) in order.enumerated() {
            #expect(layout.references[position].map { layout.images[$0 - 1] } == scenes[originalIndex].map(\.jpegBase64))
            #expect(ordered[position].map(\.timestamp) == scenes[originalIndex].map(\.timestamp))
        }
    }

    @Test func noReuseOrEqualReuseKeepsOriginalOrder() {
        let scenes = [[frame("a", at: 1)], [frame("a", at: 2)], [frame("c", at: 3)]]
        #expect(VisionEvidenceLayout.order(frames: scenes, after: []) == [0, 1, 2])
        #expect(VisionEvidenceLayout.order(frames: scenes, after: ["a"]) == [0, 1, 2])
        #expect(VisionEvidenceLayout.order(frames: scenes, after: ["unrelated"]) == [0, 1, 2])
    }
}
