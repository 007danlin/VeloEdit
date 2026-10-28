import Foundation
import Testing
@testable import VeloEditCore

@Suite(.serialized) struct RejectedExportSchedulingTests {
    private actor Observer {
        let reject: Bool
        var kinds: Set<String> = []
        init(reject: Bool) { self.reject = reject }

        func send(_ request: URLRequest) throws -> (Data, URLResponse) {
            let body = try #require(try JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
            let required = try #require((body["format"] as? [String: Any])?["required"] as? [String])
            let answer: [String: Any]
            if required.contains("handlingEvidence") {
                kinds.insert("technical")
                answer = ["observation": "Explicit synthetic readable image fixture", "content": reject ? "uncertain" : "event",
                    "obstructionFraction": 0, "confidence": 0.95, "handlingEvidence": "none"]
            } else if required.contains("purpose") {
                kinds.insert("purpose")
                answer = ["scene": "Explicit synthetic fixture", "orientation": "upright", "opaqueCoverFraction": 0,
                    "purpose": "detail", "purposeConfidence": 0.95, "purposeEvidence": "Clearly framed synthetic test subject"]
            } else {
                #expect(required.contains("b_interaction"))
                kinds.insert("contact")
                answer = ["a_observation": "No hands are visible in this synthetic fixture", "b_interaction": "none", "c_confidence": 0.95]
            }
            let content = String(decoding: try JSONSerialization.data(withJSONObject: answer), as: UTF8.self)
            return (try JSONSerialization.data(withJSONObject: ["model": body["model"]!, "done": true,
                "done_reason": "stop", "message": ["content": content]]),
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
    }

    @Test(arguments: [false, true], [false, true])
    func onlyRejectedExportWithFeasibleReplacementCanEndEarly(reject: Bool, replacement: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let movie = try await TitleCardVideoGenerator().generate(text: "Fixture", style: TitleStyle(), duration: 4,
            width: 160, height: 90, frameRate: 15, destination: root.appendingPathComponent("movie.mov"))
        let asset = try await MediaImporter().makeAsset(url: movie)
        let items = (0..<2).map { i in TimelineItem(candidateID: UUID(), assetID: asset.id, kind: .video,
            sourceStart: Double(i) * 2, sourceDuration: 2, timelineStart: Double(i) * 2, timelineDuration: 2) }
        let timeline = Timeline(storyPlanID: UUID(), width: 160, height: 90, frameRate: 15, items: items)
        let observer = Observer(reject: reject)
        var reviewer = SelectedContentReviewer(cacheURL: root.appendingPathComponent("cache"), model: "qwen3-vl:2b-instruct",
            answerTransport: { try await observer.send($0) })
        reviewer.renderedReplacementAvailable = { completed in
            #expect(completed.count == 1)
            #expect(completed[0].sampleTimes.count == 5)
            #expect(completed[0].status == .uncertain)
            return replacement
        }
        let rendered = try await reviewer.review(timeline: timeline, assets: [asset], renderedURL: movie)
        #expect(rendered.count == (reject && replacement ? 1 : 2))
        if !reject {
            #expect(rendered.allSatisfy { $0.status == .usable }, "\(rendered)")
        }
        #expect(await observer.kinds == ["technical", "purpose", "contact"])
        let source = items.map { item in ShotContentAssessment(itemID: item.id, assetID: asset.id,
            sourceContentHash: asset.contentHash, sourceStart: item.sourceStart, sourceDuration: item.sourceDuration,
            sampleTimes: [0, 0.25, 0.5, 0.75, 0.98], phase: "source", model: "synthetic-fixture", cacheKey: "source",
            status: .usable, confidence: 0.95, obstructedSamples: [], observation: "Synthetic source certificate",
            activity: "continuous", editorialPurpose: "detail", actionBoundary: .init(startObservation: "Synthetic fixture visible",
                endObservation: "Synthetic fixture still visible", followingObservation: "Same synthetic fixture continues", verdict: .continuous, confidence: 0.95)) }
        let report = SelectedContentReviewReport(renderSignature: EditorialRenderSignature.signature(timeline),
            source: source, rendered: rendered)
        #expect(report.passes(timeline: timeline, assets: [asset]) == !reject)
    }
}
