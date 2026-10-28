import Foundation
import Testing
@testable import VeloEditCore

@Suite struct GroupedSourceReviewTests {
    private final class WorkClock: @unchecked Sendable {
        private let lock = NSLock()
        private var seconds: Double = 100
        func read() -> Double { lock.withLock { seconds } }
        func advance(_ delta: Double) { lock.withLock { seconds += delta } }
    }

    private actor Observer {
        struct Call: Sendable {
            let kind: String
            let context: Int
            let images: [String]
            let model: String
        }
        let root: URL
        let clock: WorkClock
        var calls: [Call] = []
        var failBoundary: Bool
        var failBoundaryImage: String?
        var receiptsAtFirstBoundary: Int?
        init(root: URL, clock: WorkClock, failBoundary: Bool = false, failBoundaryImage: String? = nil) {
            self.root = root; self.clock = clock; self.failBoundary = failBoundary
            self.failBoundaryImage = failBoundaryImage
        }
        func send(_ request: URLRequest) throws -> (Data, URLResponse) {
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            let required = (body["format"] as! [String: Any])["required"] as! [String]
            let model = body["model"] as! String
            let images = (body["messages"] as! [[String: Any]]).flatMap { $0["images"] as? [String] ?? [] }
            let content: [String: Any]
            let kind: String
            if required.contains("handlingEvidence") {
                kind = "technical"
                content = ["content": "landscape", "confidence": 0.95, "obstructionFraction": 0,
                    "handlingEvidence": "none", "observation": "An open river and its banks are visible"]
            } else if required.contains("purpose") {
                kind = "purpose"
                content = ["scene": "A coherent river view", "orientation": "upright", "opaqueCoverFraction": 0,
                    "purpose": "establishing", "purposeConfidence": 0.95,
                    "purposeEvidence": "The wide river and shore establish the location"]
            } else if required.contains("b_interaction") {
                kind = "contact"
                content = ["b_interaction": "none", "c_confidence": 0.95,
                    "a_observation": "No hands or camera contact are visible"]
            } else {
                kind = "boundary"
                if receiptsAtFirstBoundary == nil {
                    receiptsAtFirstBoundary = (try? FileManager.default.contentsOfDirectory(
                        at: root.appendingPathComponent("SelectedContentReview"), includingPropertiesForKeys: nil))?.count ?? 0
                }
                if failBoundary {
                    failBoundary = false
                    throw LocalAIInferenceFailure(model: model, reason: "Injected unfinished boundary")
                }
                if let failedImage = failBoundaryImage, images == [failedImage] {
                    failBoundaryImage = nil
                    throw LocalAIInferenceFailure(model: model, reason: "Injected failure after a completed source certificate")
                }
                if required.contains("peopleVisibility") {
                    content = ["a_observation": "No people are visible in this clear view of flowing water.",
                        "peopleVisibility": "absent", "peopleCount": 0, "postures": [], "confidence": 0.95]
                } else if required.contains("b_jointObjectPairs") {
                    content = ["a_observation": "No people visibly share physical support of an object.",
                        "b_jointObjectPairs": 0, "c_confidence": 0.95]
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
            }
            calls.append(Call(kind: kind, context: (body["options"] as! [String: Any])["num_ctx"] as! Int,
                images: images, model: model))
            // Two frame phases consume 900 seconds together, but each shot
            // needs only 450 seconds plus its own boundary work (<600).
            clock.advance(kind == "boundary" ? 5 : 30)
            let answer = String(decoding: try JSONSerialization.data(withJSONObject: content), as: UTF8.self)
            let envelope = try JSONSerialization.data(withJSONObject: ["model": model, "done": true,
                "done_reason": "stop", "message": ["content": answer]])
            return (envelope, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
    }

    private func fixture(root: URL, profile: FilmProcessProfile) async throws -> (MediaAsset, Timeline) {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("source.mp4")
        try Data("Fixture: every requested frame is preseeded; no decoder or model is used.".utf8).write(to: file)
        let asset = MediaAsset(originalURL: file, kind: .video, byteSize: 1, contentHash: "fixture",
            metadata: .init(duration: 12, width: 1280, height: 720, frameRate: 30, hasAudio: false))
        let timeline = Timeline(storyPlanID: UUID(), items: [1.0, 5.0].enumerated().map { index, start in
            TimelineItem(assetID: asset.id, kind: .video, sourceStart: start, sourceDuration: 2,
                timelineStart: Double(index) * 2, timelineDuration: 2)
        })
        let identity = FrameCacheKey.sourceIdentity(url: file, contentHash: asset.contentHash)
        let decodedIdentity = FrameCacheKey.sourceIdentity(url: file, contentHash: identity)
        let cache = FrameCache(rootURL: root.appendingPathComponent("SelectedContentFrames"))
        for item in timeline.items {
            let times = profile.reviewFractions.map { item.sourceStart + item.sourceDuration * $0 }
            let context = [item.sourceStart - 1] + times + [item.sourceStart + 2.25, item.sourceStart + 6]
            for time in context {
                var sample = VisualFrameSample(timestamp: time, motion: 0, exposure: 0.5, detail: 0.5,
                    labels: [], labelConfidence: 1, faceCount: 0, jpegBase64: "exact-frame-\(time)",
                    histogram: [], luminanceFingerprint: [])
                sample.actualTimestamp = time
                sample.pixelWidth = 1280; sample.pixelHeight = 720
                try await cache.store(sample, for: FrameCacheKey(sourceFile: decodedIdentity, timestamp: time,
                    resolution: 1280, processingPurpose: .aiDirector,
                    representation: AdaptiveFrameSampler.selectedContentRepresentation, decodeTimeScale: 600))
            }
        }
        return (asset, timeline)
    }

    @Test func completeFramesAreGroupedBeforeEveryRequiredBoundaryWithoutSpendingOtherShotsBudget() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = FilmProcessProfile(analysis: .resolve(mode: .fast))
        let (asset, timeline) = try await fixture(root: root, profile: profile)
        let clock = WorkClock(), updates = FilmBuildProgressRecorder()
        let observer = Observer(root: root, clock: clock)
        let reviewer = SelectedContentReviewer(cacheURL: root, model: profile.modelID,
            answerTransport: { try await observer.send($0) }, workUptime: { clock.read() })
        let result = try await FilmProcessContext.$current.withValue(profile) {
            try await reviewer.review(timeline: timeline, assets: [asset], progress: { await updates.record($0) })
        }
        #expect(result.map(\.itemID) == timeline.items.map(\.id))
        #expect(zip(result, timeline.items).allSatisfy { pair in pair.0.certifies(item: pair.1, phase: "source", assets: [asset]) })
        let calls = await observer.calls
        #expect(calls.prefix(30).map(\.kind) == Array(repeating: ["technical", "purpose", "contact"], count: 10).flatMap { $0 })
        #expect(calls.prefix(30).allSatisfy { $0.context == 4096 && $0.images.count == 1 })
        #expect(calls.dropFirst(30).allSatisfy { $0.kind == "boundary" && $0.context == profile.contextTokens })
        #expect(calls.filter { $0.images.count == 5 }.map(\.images) == [
            [1.04, 2, 2.96, 3.25, 7].map { "exact-frame-\($0)" },
            [5.04, 6, 6.96, 7.25, 11].map { "exact-frame-\($0)" }
        ])
        #expect(calls.allSatisfy { $0.model == profile.modelID })
        #expect(await observer.receiptsAtFirstBoundary == 0)
        #expect(result.allSatisfy { $0.actionBoundary?.passes == true })
        let progress = await updates.updates
        #expect(progress.last?.completed == 2 && progress.last?.total == 2)
        let frameProgress = progress.filter { $0.stage == .sourceFrames }
        let boundaryProgress = progress.filter { $0.stage == .sourceBoundaries }
        #expect(frameProgress.last?.completed == 2 && frameProgress.last?.total == 2)
        #expect(boundaryProgress.first?.completed == 0 && boundaryProgress.last?.completed == 2)
        #expect(progress.last?.stage == .sourceBoundaries)
        #expect(!result[0].certifies(item: timeline.items[0], phase: "mp4", assets: [asset]))
    }

    @Test func failedBoundaryDoesNotPersistPartialCertificatesAndRecoveryReusesAllCompletedFrameObservations() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = FilmProcessProfile(analysis: .resolve(mode: .fast))
        let (asset, timeline) = try await fixture(root: root, profile: profile)
        let clock = WorkClock()
        let observer = Observer(root: root, clock: clock, failBoundary: true)
        let reviewer = SelectedContentReviewer(cacheURL: root, model: profile.modelID,
            answerTransport: { try await observer.send($0) }, workUptime: { clock.read() })
        await #expect(throws: LocalAIInferenceFailure.self) {
            try await FilmProcessContext.$current.withValue(profile) {
                try await reviewer.review(timeline: timeline, assets: [asset])
            }
        }
        #expect(await observer.calls.count == 30)
        let receipts = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("SelectedContentReview"), includingPropertiesForKeys: nil)
        #expect(receipts.isEmpty)
        let result = try await FilmProcessContext.$current.withValue(profile) {
            try await reviewer.review(timeline: timeline, assets: [asset])
        }
        let calls = await observer.calls
        #expect(calls.filter { $0.kind != "boundary" }.count == 30)
        #expect(calls.dropFirst(30).allSatisfy { $0.kind == "boundary" && $0.context == profile.contextTokens })
        #expect(zip(result, timeline.items).allSatisfy { pair in pair.0.certifies(item: pair.1, phase: "source", assets: [asset]) })
        let completeCount = calls.count
        _ = try await FilmProcessContext.$current.withValue(profile) {
            try await reviewer.review(timeline: timeline, assets: [asset])
        }
        #expect(await observer.calls.count == completeCount)
    }

    @Test func laterBoundaryFailureKeepsAnEarlierCompletedSourceCertificate() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = FilmProcessProfile(analysis: .resolve(mode: .fast))
        let (asset, timeline) = try await fixture(root: root, profile: profile)
        let clock = WorkClock()
        let observer = Observer(root: root, clock: clock, failBoundaryImage: "exact-frame-11.0")
        let reviewer = SelectedContentReviewer(cacheURL: root, model: profile.modelID,
            answerTransport: { try await observer.send($0) }, workUptime: { clock.read() })
        await #expect(throws: LocalAIInferenceFailure.self) {
            try await FilmProcessContext.$current.withValue(profile) {
                try await reviewer.review(timeline: timeline, assets: [asset])
            }
        }
        let receipts = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("SelectedContentReview"), includingPropertiesForKeys: nil)
        #expect(receipts.count == 1)
        let saved = try JSONDecoder().decode(SelectedContentReviewer.Answer.self, from: Data(contentsOf: #require(receipts.first)))
        #expect(saved.status == .usable && saved.actionBoundary?.passes == true)
        let callsBefore = await observer.calls
        let result = try await FilmProcessContext.$current.withValue(profile) {
            try await reviewer.review(timeline: timeline, assets: [asset])
        }
        #expect(zip(result, timeline.items).allSatisfy { pair in pair.0.certifies(item: pair.1, phase: "source", assets: [asset]) })
        let callsAfter = await observer.calls
        #expect(callsAfter.filter { $0.kind != "boundary" }.count == 30)
        #expect(callsAfter.dropFirst(callsBefore.count).allSatisfy { $0.kind == "boundary" })
        #expect(callsAfter.filter { $0.kind == "boundary" }.count == 2 * callsBefore.filter { $0.kind == "boundary" }.count)
    }
}
