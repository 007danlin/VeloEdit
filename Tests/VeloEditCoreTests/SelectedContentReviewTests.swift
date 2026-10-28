import Foundation
import Testing
@testable import VeloEditCore

@Suite struct SelectedContentReviewTests {
    @Test func negativeAndUncertainInteractionStillRequireLiteralEvidence() throws {
        for interaction in [SelectedContentReviewer.CameraInteraction.none, .unclear, .cameraAdjustment, .equipmentWork] {
            for text in ["none", "unclear", "equipment-work", "0", ""] {
                let frame = SelectedContentReviewer.CameraInteractionFrame(index: 0, interaction: interaction,
                    confidence: 0.99, evidence: text)
                #expect(!SelectedContentReviewer.literalInteractionEvidence(frame))
            }
        }
        let absent = SelectedContentReviewer.CameraInteractionFrame(index: 0, interaction: .none,
            confidence: 0.95, evidence: "No hands are visible over this open river")
        #expect(SelectedContentReviewer.literalInteractionEvidence(absent))
        let ambiguous = SelectedContentReviewer.CameraInteractionFrame(index: 0, interaction: .unclear,
            confidence: 0.4, evidence: "A blurred foreground shape cannot be identified as a hand")
        #expect(SelectedContentReviewer.literalInteractionEvidence(ambiguous))
        let primary = SelectedContentReviewer.Answer(status: .usable, confidence: 0.99,
            obstructedSamples: [], observation: "Readable river landscape", activity: "Scenery")
        let contacts = (0..<5).map { index in var frame = absent; frame.index = index; return frame }
        var uncertain = contacts; uncertain[2] = ambiguous; uncertain[2].index = 2
        #expect(SelectedContentReviewer.applyingInteractionCertainty(uncertain, to: primary)?.status == .uncertain)
    }

    @Test func independentUnknownContactCannotBorrowPrimaryConfidence() throws {
        let primary = SelectedContentReviewer.Answer(status: .usable, confidence: 0.99,
            obstructedSamples: [], observation: "Clear readable river scene", activity: "Scenery")
        let contacts = (0..<5).map { SelectedContentReviewer.CameraInteractionFrame(index: $0,
            interaction: .none, confidence: 0.95, evidence: "No hands are visible in this frame") }
        #expect(SelectedContentReviewer.applyingInteractionCertainty(contacts, to: primary)?.status == .usable)
        for confidence in [0.0, 0.7] {
            var ambiguous = contacts
            ambiguous[4].confidence = confidence
            let result = try #require(SelectedContentReviewer.applyingInteractionCertainty(ambiguous, to: primary))
            #expect(result.status == .uncertain && result.confidence <= confidence)
        }
        var ambiguous = contacts
        ambiguous[4].interaction = .unclear
        #expect(SelectedContentReviewer.applyingInteractionCertainty(ambiguous, to: primary)?.status == .uncertain)
        ambiguous[4].interaction = .cameraAdjustment
        ambiguous[4].confidence = 0.8
        #expect(SelectedContentReviewer.applyingInteractionCertainty(ambiguous, to: primary)?.status == .uncertain)
        #expect(SelectedContentReviewer.applyingInteractionCertainty(Array(contacts.dropLast()), to: primary) == nil)
        #expect(SelectedContentReviewer.applyingInteractionCertainty(Array(contacts.dropLast()), to: primary,
            intentionalFadeSamples: [4])?.status == .usable)
        var rejected = primary
        rejected.status = .obstructed
        #expect(SelectedContentReviewer.applyingInteractionCertainty(ambiguous, to: rejected)?.status == .obstructed)
    }

    private final class WorkClock: @unchecked Sendable {
        let lock = NSLock()
        private var time: Double = 100
        func read() -> Double { lock.withLock { time } }
        func advance(_ seconds: Double) { lock.withLock { time += seconds } }
    }

    @Test func shotBudgetUsesActiveWorkTimeAndKeepsCompletedExactResults() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = WorkClock()
        let reviewer = SelectedContentReviewer(cacheURL: root, model: "fixture", answerTransport: { request in
            #expect(request.timeoutInterval <= 60)
            return (Data(#"{"model":"fixture","done":true,"done_reason":"stop","message":{"content":"{\"observation\":\"literal verified observation\"}"}}"#.utf8),
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, deadlineUptime: 160, workUptime: { clock.read() })
        let body: [String: Any] = ["model": "fixture", "messages": [["role": "user", "content": "First exact observation"]]]
        _ = try await reviewer.modelAnswer(body: body, responseURL: root.appendingPathComponent("first.json"))
        // No Date deadline: only active time is charged. Once it is spent,
        // unfinished work is bounded while the completed exact answer survives.
        clock.advance(61)
        _ = try await reviewer.modelAnswer(body: body, responseURL: root.appendingPathComponent("saved.json"))
        let next: [String: Any] = ["model": "fixture", "messages": [["role": "user", "content": "Different unfinished observation"]]]
        await #expect(throws: LocalAIInferenceFailure.self) {
            try await reviewer.modelAnswer(body: next, responseURL: root.appendingPathComponent("next.json"))
        }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("next.json").path))
    }

    @Test func verifierKeepsOneContextSizeWithoutChangingEvidence() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let reviewer = SelectedContentReviewer(cacheURL: root, model: "fixture", answerTransport: { request in
            (Data(#"{"model":"fixture","done":true,"done_reason":"stop","message":{"content":"{\"observation\":\"literal evidence\"}"}}"#.utf8),
             HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        for context in [4096, 8192, 16384] {
            let response = root.appendingPathComponent("context-\(context).json")
            _ = try await reviewer.modelAnswer(body: ["model": "fixture", "options": ["num_ctx": context, "num_predict": 320],
                "messages": [["role": "user", "content": "Same independent question", "images": ["all-original-pixels"]]]], responseURL: response)
            let request = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: response.deletingPathExtension().appendingPathExtension("request.json"))) as? [String: Any])
            let options = try #require(request["options"] as? [String: Int])
            #expect(options["num_ctx"] == max(8192, context))
            #expect(options["num_predict"] == 320)
            let message = try #require((request["messages"] as? [[String: Any]])?.first)
            #expect(message["images"] as? [String] == ["all-original-pixels"])
            #expect(message["content"] as? String == "Image 0: [img]\nSame independent question")
        }
    }

    private actor ReviewTransport {
        var timeouts = 4
        var calls = 0
        func send(_ request: URLRequest) throws -> (Data, URLResponse) {
            calls += 1
            if timeouts > 0 { timeouts -= 1; throw URLError(.timedOut) }
            let body = try #require(try JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
            let format = body["format"] as! [String: Any]
            let fields = format["required"] as! [String]
            let content: [String: Any]
            if fields.contains("handlingEvidence") {
                content = ["content": "landscape", "confidence": 0.95, "obstructionFraction": 0,
                    "handlingEvidence": "none", "observation": "An open river and its banks are visible"]
            } else if fields.contains("purpose") {
                content = ["scene": "A coherent river view", "orientation": "upright", "opaqueCoverFraction": 0,
                    "purpose": "establishing", "purposeConfidence": 0.95, "purposeEvidence": "The wide river and shore establish the location"]
            } else {
                content = ["b_interaction": "none", "c_confidence": 0.95, "a_observation": "No hands or camera contact are visible"]
            }
            let answer = String(data: try JSONSerialization.data(withJSONObject: content), encoding: .utf8)!
            return (try JSONSerialization.data(withJSONObject: ["model": "fixture", "done": true,
                "done_reason": "stop", "message": ["content": answer]]),
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
    }

    @Test func twoSlowShotsDoNotDisableRemainingContentReviewAndProgressFinishes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let movie = try await TitleCardVideoGenerator().generate(text: "River", style: TitleStyle(), duration: 4,
            width: 160, height: 90, frameRate: 30, destination: root.appendingPathComponent("source.mov"))
        let asset = MediaAsset(originalURL: movie, kind: .video, byteSize: 1, contentHash: "review-fixture",
            metadata: .init(duration: 4, width: 160, height: 90, frameRate: 30, hasAudio: false))
        let timeline = Timeline(storyPlanID: UUID(), items: (0..<3).map {
            TimelineItem(assetID: asset.id, kind: .video, sourceDuration: 1, timelineStart: Double($0), timelineDuration: 1)
        })
        let transport = ReviewTransport(), updates = FilmBuildProgressRecorder()
        let reviewer = SelectedContentReviewer(cacheURL: root, model: "fixture", answerTransport: { try await transport.send($0) })
        let result = try await reviewer.review(timeline: timeline, assets: [asset], renderedURL: movie,
            progress: { await updates.record($0) })
        #expect(result.map(\.status) == [.uncertain, .uncertain, .usable])
        #expect(await transport.calls > 4)
        let progress = await updates.updates
        #expect(progress.allSatisfy { $0.stage == .renderedContent })
        #expect(progress.last?.completed == 3 && progress.last?.total == 3)
        let calls = await transport.calls
        var cachedTimeline = timeline
        cachedTimeline.items = [timeline.items[2]]
        let cached = try await reviewer.review(timeline: cachedTimeline, assets: [asset], renderedURL: movie)
        #expect(cached.last?.status == .usable)
        // A different edit signature cannot borrow an MP4 certificate.
        #expect(await transport.calls > calls)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["VELOEDIT_CONTENT_REVIEW_PROJECT"] != nil))
    func liveSelectedShotCompletesIndependentReview() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["VELOEDIT_CONTENT_REVIEW_PROJECT"])
        let store = try ProjectStore(open: URL(fileURLWithPath: path))
        let project = await store.manifest
        var timeline = try #require(project.timelines.last)
        timeline.items = [try #require(timeline.items.first { $0.kind == .video })]
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("veloedit-live-content-review")
        let reviewer = SelectedContentReviewer(cacheURL: root, model: "qwen3-vl:30b-a3b-instruct")
        let started = Date()
        let result = try await reviewer.review(timeline: timeline, assets: project.assets,
            progress: { print("LIVE CONTENT: \($0.countLabel) \($0.detail ?? "")") })
        let answer = try #require(result.first)
        print("LIVE CONTENT RESULT: \(Date().timeIntervalSince(started))s, \(answer.status), confidence=\(answer.confidence), boundary=\(String(describing: answer.actionBoundary?.verdict))")
        #expect(answer.confidence > 0)
        #expect(answer.actionBoundary != nil || answer.status == .obstructed || answer.status == .unmotivated)
    }

    private actor ObjectBoundaryTransport {
        var index = 0
        let invalidObjectEvidence: Bool
        let incorrectPositiveBoundary: Bool
        let uncertainFollowingContact: Bool
        init(invalidObjectEvidence: Bool = false, incorrectPositiveBoundary: Bool = false, uncertainFollowingContact: Bool = false) {
            self.invalidObjectEvidence = invalidObjectEvidence
            self.incorrectPositiveBoundary = incorrectPositiveBoundary
            self.uncertainFollowingContact = uncertainFollowingContact
        }
        func send(_ request: URLRequest) throws -> (Data, URLResponse) {
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            let messages = body["messages"] as! [[String: Any]]
            let prompt = messages[0]["content"] as! String
            let content: [String: Any]
            if let images = messages[0]["images"] as? [String] {
                let format = body["format"] as! [String: Any]
                if (format["required"] as! [String]).contains("b_jointObjectPairs") {
                    let joint = images == ["fixture-image-5"]
                    content = ["a_observation": joint ? "Both people's hands hold the same unsupported object." : "Each person holds a separate object in their hands.",
                        "b_jointObjectPairs": joint ? 1 : 0,
                        "c_confidence": uncertainFollowingContact && images == ["fixture-image-7"] ? 0.7 : 0.95]
                } else if (format["required"] as! [String]).contains("a_observation") {
                    content = ["a_observation": "One person bends on their legs and one person sits on a chair.",
                        "peopleVisibility": "visible", "peopleCount": 2, "postures": ["sitting", "bending"], "confidence": 0.95]
                } else {
                    let retained = !incorrectPositiveBoundary && images == [1,3,5,6,7].map { "fixture-image-\($0)" }
                        && prompt.contains("IMMEDIATELY AFTER CUT")
                    content = ["a_selectedAction": invalidObjectEvidence ? "0.9" : "The person holds the tilted blue bottle over another person's hands.",
                        "b_endAndFollowing": "The tilted blue bottle is still held at the end, then upright on the bag after the cut.",
                        "c_finiteTaskObserved": retained, "d_immediateOutcomeMissing": retained,
                        "verdict": retained ? "interrupted" : "continuous", "confidence": 0.95]
                }
            } else {
                throw URLError(.cannotParseResponse)
            }
            let string = String(data: try JSONSerialization.data(withJSONObject: content), encoding: .utf8)!
            let data = try JSONSerialization.data(withJSONObject: ["model": "fixture", "done": true,
                "done_reason": "stop", "message": ["content": string]])
            return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
    }
    private func boundarySamples() -> [VisualFrameSample] {
        (0..<8).map { VisualFrameSample(timestamp: Double($0), motion: 0, exposure: 0.5,
            detail: 0.5, labels: [], labelConfidence: 1, faceCount: 2,
            jpegBase64: "fixture-image-\($0)", histogram: [], luminanceFingerprint: []) }
    }
    @Test func actionBoundaryRetainsLiteralObjectStatesForItsDecision() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = ObjectBoundaryTransport()
        let reviewer = SelectedContentReviewer(cacheURL: root, model: "fixture", answerTransport: { try await transport.send($0) })
        let boundary = try await reviewer.inspectActionBoundary(samples: boundarySamples(), responseURL: root.appendingPathComponent("boundary.json"))
        #expect(boundary.verdict == .interrupted && boundary.rejectsCut)
        #expect(boundary.endObservation.contains("tilted blue bottle"))
        #expect(boundary.followingObservation.contains("upright on the bag"))
    }
    @Test func malformedObjectEvidenceCannotCertifyAContinuousAction() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = ObjectBoundaryTransport(invalidObjectEvidence: true)
        let reviewer = SelectedContentReviewer(cacheURL: root, model: "fixture", answerTransport: { try await transport.send($0) })
        await #expect(throws: (any Error).self) {
            try await reviewer.inspectActionBoundary(samples: boundarySamples(), responseURL: root.appendingPathComponent("boundary.json"))
        }
    }
    @Test func aMissingOutcomeCannotPassUnderAnyPositiveBoundaryLabel() {
        for verdict in [DiscreteActionBoundary.Verdict.complete, .continuous, .notApplicable] {
            #expect(SelectedContentReviewer.boundaryVerdict(finiteTaskObserved: true, immediateOutcomeMissing: true,
                proposed: verdict, observedMissingPosture: false) == .uncertain)
        }
        #expect(SelectedContentReviewer.boundaryVerdict(finiteTaskObserved: false, immediateOutcomeMissing: true,
            proposed: .interrupted, observedMissingPosture: false) == .uncertain)
    }
    @Test func jointObjectReleaseAfterCutCannotCertifyManipulationAsComplete() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = ObjectBoundaryTransport(incorrectPositiveBoundary: true)
        let reviewer = SelectedContentReviewer(cacheURL: root, model: "fixture", answerTransport: { try await transport.send($0) })
        let boundary = try await reviewer.inspectActionBoundary(samples: boundarySamples(), responseURL: root.appendingPathComponent("boundary.json"))
        #expect(boundary.rejectsCut)
        #expect(boundary.endObservation.contains("same unsupported object"))
        #expect(boundary.followingObservation.contains("separate object"))
    }
    @Test func jointSupportProofCannotInventAnOutcomeFromANewTaskOrUncertainContact() {
        #expect(SelectedContentReviewer.missingJointObjectOutcome([(0,0.95),(0,0.95),(0,0.95),(1,0.95)]) == nil)
        #expect(SelectedContentReviewer.missingJointObjectOutcome([(1,0.95),(1,0.95),(1,0.95),(0,0.95)]) == nil)
        #expect(SelectedContentReviewer.missingJointObjectOutcome([(0,0.95),(0,0.95),(1,0.5),(0,0.95)]) == nil)
        #expect(SelectedContentReviewer.missingJointObjectOutcome([(0,0.8),(0,0.7),(1,0.9),(0,0.8)]) == 0.8)
    }
    @Test func uncertainSharedReleaseCannotSupplyPositiveCompletionCertificate() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = ObjectBoundaryTransport(incorrectPositiveBoundary: true, uncertainFollowingContact: true)
        let reviewer = SelectedContentReviewer(cacheURL: root, model: "fixture", answerTransport: { try await transport.send($0) })
        let boundary = try await reviewer.inspectActionBoundary(samples: boundarySamples(), responseURL: root.appendingPathComponent("boundary.json"))
        #expect(boundary.verdict == .uncertain)
        #expect(!boundary.passes && !boundary.rejectsCut)
    }
    @Test func anUncertainBoundaryCannotBeCertifiedByTheAbsenceOfATask() {
        #expect(SelectedContentReviewer.boundaryVerdict(finiteTaskObserved: false, immediateOutcomeMissing: false,
            proposed: .uncertain, observedMissingPosture: false) == .uncertain)
        #expect(SelectedContentReviewer.boundaryVerdict(finiteTaskObserved: true, immediateOutcomeMissing: false,
            proposed: .interrupted, observedMissingPosture: false) == .uncertain)
    }
    @Test func interruptedFiniteActionCannotBorrowItsOutcomeFromAfterTheCut() throws {
        let base = SelectedContentReviewer.Answer(status: .usable, confidence: 0.9,
            obstructedSamples: [], observation: "People are visible", activity: "rest", editorialPurpose: "action")
        let boundary = DiscreteActionBoundary(startObservation: "Person approaches the bench",
            endObservation: "Person bends but remains standing", followingObservation: "Person is now seated",
            verdict: .interrupted, confidence: 0.95)
        let result = try SelectedContentReviewer.applyingBoundary(boundary, to: base)
        #expect(result.status == .unmotivated && SelectedContentReviewer.valid(result))
        #expect(result.actionBoundary?.rejectsCut == true)
        var uncertain = boundary; uncertain.confidence = 0.6
        #expect(try SelectedContentReviewer.applyingBoundary(uncertain, to: base).status == .uncertain)
        var continuing = boundary; continuing.verdict = .continuous
        #expect(try SelectedContentReviewer.applyingBoundary(continuing, to: base).status == .usable)
        // Real local-model probes contradicted their own literal observations:
        // "complete" alongside a missing seated outcome; "complete" with no task.
        #expect(SelectedContentReviewer.boundaryVerdict(finiteTaskObserved: true, immediateOutcomeMissing: true,
            proposed: .complete, observedMissingPosture: true) == .interrupted)
        #expect(SelectedContentReviewer.boundaryVerdict(finiteTaskObserved: false, immediateOutcomeMissing: false,
            proposed: .complete, observedMissingPosture: false) == .continuous)
        #expect(SelectedContentReviewer.boundaryVerdict(finiteTaskObserved: true, immediateOutcomeMissing: true,
            proposed: .complete, observedMissingPosture: false) == .uncertain)
        #expect(SelectedContentReviewer.missingPostureOutcome([(1,0,0,0),(1,0,0,0),(1,1,0,0),(2,0,0,0)]))
        #expect(!SelectedContentReviewer.missingPostureOutcome([(2,0,0,0),(2,0,0,0),(2,0,0,0),(1,1,0,0)]))
        #expect(!SelectedContentReviewer.missingPostureOutcome([(1,1,0,0),(1,1,0,0),(1,1,0,0),(2,0,0,0)]))
        var invalid = boundary; invalid.followingObservation = "0.9"
        #expect(throws: (any Error).self) { try SelectedContentReviewer.applyingBoundary(invalid, to: base) }
    }
    private actor ResponseTransport {
        var count = 0
        var failuresRemaining = 0
        var startupFailuresRemaining = 0
        func failOnce() { failuresRemaining = 1 }
        func failRepeatedly() { failuresRemaining = 2 }
        func failStartup(_ count: Int) { startupFailuresRemaining = count }
        func send(_ request: URLRequest) throws -> (Data, URLResponse) {
            count += 1
            if failuresRemaining > 0 { failuresRemaining -= 1; throw URLError(.networkConnectionLost) }
            if startupFailuresRemaining > 0 {
                startupFailuresRemaining -= 1
                return (Data(#"{"error":"timed out waiting for llama-server to start - "}"#.utf8),
                    HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!)
            }
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: String]
            let content = String(data: try JSONSerialization.data(withJSONObject: ["observation": body["prompt"]!]), encoding: .utf8)!
            let data = try JSONSerialization.data(withJSONObject: ["model": "fixture", "done": true,
                "done_reason": "stop", "message": ["content": content]])
            return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
    }

    @Test func transientContentTransportRetriesTheSameRequest() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = ResponseTransport()
        await transport.failOnce()
        let reviewer = SelectedContentReviewer(cacheURL: root, model: "fixture", answerTransport: { try await transport.send($0) })
        let answer = try await reviewer.modelAnswer(body: ["prompt": "literal source evidence"], responseURL: root.appendingPathComponent("answer.json"))
        #expect(answer.contains("literal source evidence"))
        #expect(await transport.count == 2)
        _ = try await reviewer.modelAnswer(body: ["prompt": "literal source evidence"], responseURL: root.appendingPathComponent("reused.json"))
        #expect(await transport.count == 2)
    }

    @Test func modelStartupFailureRetriesOnceWithoutCachingAnErrorAsEvidence() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = ResponseTransport()
        await transport.failStartup(1)
        let reviewer = SelectedContentReviewer(cacheURL: root, model: "fixture", answerTransport: { try await transport.send($0) })
        _ = try await reviewer.modelAnswer(body: ["prompt": "exact frames"], responseURL: root.appendingPathComponent("success.json"))
        #expect(await transport.count == 2)
        await transport.failStartup(2)
        do {
            _ = try await reviewer.modelAnswer(body: ["prompt": "different exact frames"], responseURL: root.appendingPathComponent("failed.json"))
            Issue.record("Failed model startup became accepted evidence")
        } catch { #expect((error as? URLError)?.code == .badServerResponse) }
        #expect(await transport.count == 4)
        _ = try await reviewer.modelAnswer(body: ["prompt": "different exact frames"], responseURL: root.appendingPathComponent("retry.json"))
        #expect(await transport.count == 5)
    }

    @Test func missingContentEvidenceCannotExcludeAnUnobservedCandidate() {
        let asset = UUID()
        let items = [0.0, 10].map { TimelineItem(candidateID: UUID(), assetID: asset,
            kind: .video, sourceStart: $0, sourceDuration: 5, timelineStart: $0 / 2, timelineDuration: 5) }
        let timeline = Timeline(storyPlanID: UUID(), items: items)
        var unavailable = assessment(items[1], status: .uncertain)
        unavailable.confidence = 0
        unavailable.activity = "unknown"
        unavailable.editorialPurpose = nil
        unavailable.actionBoundary = nil
        unavailable.observation = "Содержание не проверено: The request timed out."
        let reviews = [assessment(items[0]), unavailable]
        #expect(SelectedContentReviewer.uncertifiedCandidateIDs(reviews, timeline: timeline).isEmpty)
        let report = SelectedContentReviewReport(renderSignature: EditorialRenderSignature.signature(timeline),
            source: reviews, rendered: items.map { assessment($0, phase: "mp4") })
        #expect(!report.passes(timeline: timeline))
    }

    @Test func changedRequestAtSameResponsePathCannotReuseAnOldAnswer() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = ResponseTransport()
        let reviewer = SelectedContentReviewer(cacheURL: root, model: "fixture", answerTransport: { try await transport.send($0) })
        let url = root.appendingPathComponent("answer.json")
        let old = try await reviewer.modelAnswer(body: ["prompt": "old"], responseURL: url)
        let fresh = try await reviewer.modelAnswer(body: ["prompt": "fresh"], responseURL: url)
        #expect(old != fresh && fresh.contains("fresh"))
        #expect(await transport.count == 2)
        let copy = root.appendingPathComponent("other.json")
        #expect(try await reviewer.modelAnswer(body: ["prompt": "fresh"], responseURL: copy) == fresh)
        #expect(await transport.count == 2)
        #expect(try Data(contentsOf: copy.deletingPathExtension().appendingPathExtension("request.json"))
            == JSONSerialization.data(withJSONObject: ["prompt": "fresh"], options: [.sortedKeys]))
    }

    @Test func failedChangedRequestCannotRelabelThePreviousResponse() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = ResponseTransport()
        let reviewer = SelectedContentReviewer(cacheURL: root, model: "fixture", answerTransport: { try await transport.send($0) })
        let url = root.appendingPathComponent("answer.json")
        let old = try await reviewer.modelAnswer(body: ["prompt": "old"], responseURL: url)
        await transport.failRepeatedly()
        await #expect(throws: URLError.self) { try await reviewer.modelAnswer(body: ["prompt": "fresh"], responseURL: url) }
        #expect(!FileManager.default.fileExists(atPath: url.path))
        let fresh = try await reviewer.modelAnswer(body: ["prompt": "fresh"], responseURL: url)
        #expect(old != fresh && fresh.contains("fresh"))
        #expect(await transport.count == 4)
        let archive = root.appendingPathComponent("Superseded")
        #expect(try FileManager.default.contentsOfDirectory(at: archive, includingPropertiesForKeys: nil).count == 1)
    }

    private func assessment(_ item: TimelineItem, status: ShotContentStatus = .usable,
                            phase: String = "source") -> ShotContentAssessment {
        ShotContentAssessment(itemID: item.id, assetID: item.assetID!, sourceContentHash: "fixture", sourceStart: item.sourceStart,
            sourceDuration: item.sourceDuration, sampleTimes: [0, 1, 2, 3, 4], phase: phase,
            model: "fixture", cacheKey: "fixture", status: status, confidence: 0.9,
            obstructedSamples: status == .obstructed ? [1, 2, 3] : [],
            observation: status == .obstructed ? "Одежда закрывает основное поле зрения" : "Рыбалка у реки", activity: "fishing",
            editorialPurpose: status == .usable ? "action" : "none",
            irrelevantSamples: status == .unmotivated ? [0, 1, 2, 3, 4] : [],
            actionBoundary: .init(startObservation: "Rod above river", endObservation: "Rod above river",
                followingObservation: "Fishing continues visibly", verdict: .continuous, confidence: 0.9))
    }

    @Test func obstructionChangesAutomaticSelectionWithoutBanningTheWholeRecording() {
        let asset = UUID()
        let candidates = [0.0, 4, 20, 40].map { start -> Candidate in
            var insight = CandidateInsights(sceneSummary: "Рыбалка", dynamics: 0.4, sharpness: 0.9, exposureQuality: 0.9)
            insight.editorialEvidence = EditorialEvidence(usableRange: .init(start: start, end: start + 10),
                informationGain: 0.6, entryQuality: 0.9, exitQuality: 0.9, atmosphereValue: 0.8, confidence: 0.9)
            return Candidate(assetID: asset, sourceStart: start, sourceDuration: 10,
                scores: .init(quality: 0.9, interest: 0.9, action: 0.4, stability: 0.9, uniqueness: 0.9),
                tags: ["fishing"], insights: insight)
        }
        let analyses = [AnalysisResult(assetID: asset, analyzedContentHash: "fixture", sceneTags: [], candidates: candidates)]
        let items = [candidates[0], candidates[2]].enumerated().map { index, candidate in
            TimelineItem(candidateID: candidate.id, assetID: asset, kind: .video, sourceStart: candidate.sourceStart,
                sourceDuration: 6, timelineStart: Double(index * 6), timelineDuration: 6)
        }
        var plan = StoryPlan(prompt: "Фильм длительностью 12 секунд", preset: .story,
            constraints: .init(targetDuration: 12), chapters: [])
        plan.narrativeBeatPlan = .init(pattern: .minimalMontage, beats: [], reasons: [])
        let original = Timeline(storyPlanID: plan.id, items: items)
        let rejected = SelectedContentReviewer.rejectedCandidateIDs([assessment(items[0], status: .obstructed)], analyses: analyses)
        #expect(rejected == [candidates[0].id, candidates[1].id])
        let revised = AutomaticEditorialAssembly.prepare(timeline: original, plan: plan, analyses: analyses, events: [], excluded: rejected)
        #expect(!Set(revised.timeline.items.compactMap(\.candidateID)).isDisjoint(with: [candidates[2].id, candidates[3].id]))
        #expect(Set(revised.timeline.items.compactMap(\.candidateID)).isDisjoint(with: rejected))
        #expect(revised.timeline.items.map(\.sourceStart) == revised.timeline.items.map(\.sourceStart).sorted())
        #expect(revised.timeline.items.allSatisfy { $0.speed == 1 && $0.assetID == asset })
        #expect(abs(revised.timeline.duration - 12) < 0.04)
        // A technically readable but meaningless coat/bank view must change
        // native selection through the same general interval exclusion path.
        let meaningless = SelectedContentReviewer.rejectedCandidateIDs([assessment(items[0], status: .unmotivated)], analyses: analyses)
        #expect(meaningless == rejected)
        var uneven = original
        uneven.items[0].sourceDuration = 4
        uneven.items[0].timelineDuration = 4
        uneven.items[1].sourceDuration = 8
        uneven.items[1].timelineDuration = 8
        uneven.items[1].timelineStart = 4
        let positive = assessment(uneven.items[1])
        let stable = AutomaticEditorialAssembly.prepare(timeline: uneven, plan: plan,
            analyses: analyses, events: [], excluded: rejected, verifiedSource: [positive])
        let retained = stable.timeline.items.first { $0.candidateID == uneven.items[1].candidateID }
        #expect(retained?.sourceStart == uneven.items[1].sourceStart)
        #expect(retained?.sourceDuration == uneven.items[1].sourceDuration)
        #expect(Set(stable.timeline.items.compactMap(\.candidateID)).isDisjoint(with: rejected))
        #expect(abs(stable.timeline.duration - 12) < 0.04)
        #expect(stable.timeline.items.map(\.sourceStart) == stable.timeline.items.map(\.sourceStart).sorted())
        let resumed = AutomaticEditorialAssembly.prepare(timeline: stable.timeline, plan: stable.plan,
            analyses: analyses, events: [], verifiedSource: [positive])
        #expect(resumed.timeline.items.first { $0.id == positive.itemID }?.sourceStart == 20)
        #expect(resumed.timeline.items.first { $0.id == positive.itemID }?.sourceDuration == 8)
    }

    @Test func uncertaintyAndIntentionalCloseupsCannotTriggerARejection() {
        let item = TimelineItem(assetID: UUID(), kind: .video, sourceDuration: 5, timelineStart: 0, timelineDuration: 5)
        #expect(!assessment(item, status: .uncertain).rejectsRange)
        #expect(!assessment(item).rejectsRange)
        var lowConfidence = assessment(item, status: .obstructed)
        lowConfidence.confidence = 0.5
        #expect(!lowConfidence.rejectsRange)
    }

    @Test func isolatedUnknownCanBeReplacedWithoutCondemningItsNeighbors() {
        let asset = UUID()
        let items = [0.0, 10, 20].map { start in
            TimelineItem(candidateID: UUID(), assetID: asset, kind: .video, sourceStart: start,
                sourceDuration: 5, timelineStart: start / 2, timelineDuration: 5)
        }
        let timeline = Timeline(storyPlanID: UUID(), items: items)
        let unknown = assessment(items[1], status: .uncertain)
        #expect(!unknown.rejectsRange)
        let identified = [assessment(items[0]), unknown, assessment(items[2])]
        #expect(SelectedContentReviewer.uncertifiedCandidateIDs(identified, timeline: timeline) == [items[1].candidateID!])
        #expect(SelectedContentReviewer.uncertifiedCandidateIDs(items.map { assessment($0, status: .uncertain) }, timeline: timeline).isEmpty)
        var stale = unknown
        stale.sourceStart += 1
        #expect(SelectedContentReviewer.uncertifiedCandidateIDs([assessment(items[0]), stale], timeline: timeline).isEmpty)
        let plan = StoryPlan(prompt: "Фильм длительностью 15 секунд", preset: .story, constraints: .init(targetDuration: 15), chapters: [])
        let analyses = [AnalysisResult(assetID: asset, analyzedContentHash: "fixture", sceneTags: [], candidates:
            [0.0, 10, 20, 30].map { start in
                var insights = CandidateInsights(sceneSummary: "Поездка", dynamics: 0.5, sharpness: 0.9, exposureQuality: 0.9)
                insights.editorialEvidence = .init(usableRange: .init(start: start, end: start + 5),
                    informationGain: 0.9, entryQuality: 0.9, exitQuality: 0.9, atmosphereValue: 0.8, confidence: 0.9)
                return Candidate(assetID: asset, sourceStart: start, sourceDuration: 5,
                    scores: .init(quality: 0.9, interest: 0.9, action: 0.5, stability: 0.9), tags: ["travel"], insights: insights)
            })]
        var nativePlan = plan
        nativePlan.narrativeBeatPlan = .init(pattern: .minimalMontage, beats: [], reasons: [])
        var native = timeline
        for i in native.items.indices { native.items[i].candidateID = analyses[0].directorCandidates[i].id }
        let reviews = [assessment(native.items[0]), assessment(native.items[1], status: .uncertain), assessment(native.items[2])]
        let excluded = SelectedContentReviewer.uncertifiedCandidateIDs(reviews, timeline: native)
        let repaired = AutomaticEditorialAssembly.prepare(timeline: native, plan: nativePlan, analyses: analyses,
            events: [], excluded: excluded, verifiedSource: reviews)
        #expect(Set(repaired.timeline.items.compactMap(\.candidateID)).isDisjoint(with: excluded))
        #expect(repaired.timeline.items.contains { $0.candidateID == analyses[0].directorCandidates[3].id })
        #expect(repaired.timeline.items.map(\.sourceStart) == repaired.timeline.items.map(\.sourceStart).sorted())
    }

    @Test func finalReportRequiresBothOriginalAndEncodedObservationsForEveryActualRange() {
        let item = TimelineItem(assetID: UUID(), kind: .video, sourceStart: 8, sourceDuration: 5, timelineStart: 0, timelineDuration: 5)
        var timeline = Timeline(storyPlanID: UUID(), items: [item])
        let signature = EditorialRenderSignature.signature(timeline)
        var report = SelectedContentReviewReport(renderSignature: signature,
            source: [assessment(item)], rendered: [assessment(item, phase: "mp4")])
        #expect(report.passes(timeline: timeline))
        let boundary = report.source[0].actionBoundary
        report.source[0].actionBoundary = nil
        report.source[0].editorialPurpose = "establishing"
        #expect(!report.passes(timeline: timeline))
        report.source[0].actionBoundary = boundary
        timeline.selectedContentReview = report
        #expect(EditorialRenderSignature.signature(timeline) == signature)
        report.rendered = []
        #expect(!report.passes(timeline: timeline))
        report.rendered = [assessment(item, status: .uncertain, phase: "mp4")]
        #expect(!report.passes(timeline: timeline))
        report.rendered = [assessment(item, phase: "mp4")]
        report.rendered[0].editorialPurpose = nil
        #expect(!report.passes(timeline: timeline))
        report.rendered[0].editorialPurpose = "action"
        timeline.items[0].sourceStart += 1
        #expect(!report.passes(timeline: timeline))
        report.renderSignature = EditorialRenderSignature.signature(timeline)
        #expect(!report.passes(timeline: timeline))
    }

    @Test func malformedOrContradictoryModelJudgementsAreNotEvidence() {
        var answer = SelectedContentReviewer.Answer(status: .usable, confidence: 0.9,
            obstructedSamples: [], observation: "Понятная сцена рыбалки", activity: "fishing")
        #expect(SelectedContentReviewer.valid(answer))
        answer.obstructedSamples = [1, 2]
        #expect(!SelectedContentReviewer.valid(answer))
        answer.status = .obstructed
        #expect(SelectedContentReviewer.valid(answer))
        answer.obstructedSamples = [1, 1]
        #expect(!SelectedContentReviewer.valid(answer))
        answer.obstructedSamples = [1, 5]
        #expect(!SelectedContentReviewer.valid(answer))
        answer.obstructedSamples = [1, 2]
        answer.confidence = .nan
        #expect(!SelectedContentReviewer.valid(answer))
    }

    @Test func frameContentSeparatesReadableActivityFromAnInterruptedView() throws {
        var raw = SelectedContentReviewer.FrameAnswer(frames: (0..<5).map {
            .init(index: $0, content: .event, confidence: 0.95)
        }, observation: "Люди едут в багги; руки на руле и каркас видны", activity: "Поездка")
        #expect(try #require(SelectedContentReviewer.resolve(raw)).status == .usable)
        raw.observation = ""
        let factsWithoutProse = try #require(SelectedContentReviewer.resolve(raw))
        #expect(factsWithoutProse.status == .usable && factsWithoutProse.observation.contains("FRAME 0: event"))
        #expect(SelectedContentReviewer.valid(factsWithoutProse))
        raw.frames[2].content = .lensCover
        raw.frames[2].obstructionFraction = 0.8
        // A single close-up was falsely classified as a covered lens on real
        // footage of a person opening a case. Preserve the surrounding action.
        #expect(try #require(SelectedContentReviewer.resolve(raw)).status == .usable)
        raw.frames[3].content = .lensCover
        raw.frames[3].obstructionFraction = 0.8
        let blocked = try #require(SelectedContentReviewer.resolve(raw))
        #expect(blocked.status == .obstructed && blocked.obstructedSamples == [2, 3])
        #expect(SelectedContentReviewer.valid(blocked))
        #expect(try #require(SelectedContentReviewer.resolve(raw, intentionalFadeSamples: [2, 3])).status == .usable)
        raw.frames[2].content = .event
        raw.frames[2].obstructionFraction = 0
        raw.frames[3].content = .event
        raw.frames[3].obstructionFraction = 0
        raw.frames[4].content = .lensCover
        raw.frames[4].obstructionFraction = 0.8
        #expect(try #require(SelectedContentReviewer.resolve(raw)).status == .usable)
        raw.frames[4].content = .uncertain
        #expect(try #require(SelectedContentReviewer.resolve(raw)).status == .uncertain)
        raw.frames[4].index = 3
        #expect(SelectedContentReviewer.resolve(raw) == nil)
    }

    @Test func visibleFishingDetailsAndAccidentalCameraRotationHaveDifferentOutcomes() throws {
        var raw = SelectedContentReviewer.FrameAnswer(frames: (0..<5).map {
            .init(index: $0, content: .event, confidence: 1)
        }, observation: "Руки с удочкой; берег и рыбак видны", activity: "Рыбалка")
        for index in [1, 2] {
            raw.frames[index].content = .lensCover
            raw.frames[index].obstructionFraction = 0.25
        }
        #expect(try #require(SelectedContentReviewer.resolve(raw)).status == .usable)
        for index in [1, 2] {
            raw.frames[index].content = .cameraHandling
            raw.frames[index].obstructionFraction = 0
        }
        // The real false positive inferred camera handling from fishing hands.
        #expect(try #require(SelectedContentReviewer.resolve(raw)).status == .usable)
        for index in [1, 2] { raw.frames[index].handlingEvidence = .invertedScene }
        #expect(try #require(SelectedContentReviewer.resolve(raw)).status == .obstructed)
        for index in [1, 2] { raw.frames[index].handlingEvidence = .none }
        raw.frames[2].content = .event
        raw.frames[2].obstructionFraction = 0.9
        raw.frames[1].content = .event
        #expect(try #require(SelectedContentReviewer.resolve(raw)).status == .uncertain)
        raw.frames[2].obstructionFraction = .nan
        #expect(SelectedContentReviewer.resolve(raw) == nil)
    }
    @Test func cameraRotationNeedsIndependentVisibleOrientationEvidence() throws {
        let primary = SelectedContentReviewer.FrameAnswer(frames: (0..<5).map {
            .init(index: $0, content: .cameraHandling, confidence: 0.9, handlingEvidence: .invertedScene)
        }, observation: "Модель предположила переворот камеры при работе с удочкой", activity: "Рыбалка")
        var observer = SelectedContentReviewer.OrientationAnswer(frames: (0..<5).map {
            .init(index: $0, scene: "Fishing hands and an upright riverbank", orientation: .upright, opaqueCoverFraction: 0,
                orientationBasis: .worldReference)
        })
        let corrected = try #require(SelectedContentReviewer.confirmHandling(primary, observer: observer))
        #expect(try #require(SelectedContentReviewer.resolve(corrected)).status == .usable)
        observer.frames[1].orientation = .inverted
        observer.frames[2].orientation = .sideways
        observer.frames[1].orientationBasis = .worldReference
        observer.frames[2].orientationBasis = .worldReference
        let rotated = try #require(SelectedContentReviewer.confirmHandling(primary, observer: observer))
        #expect(try #require(SelectedContentReviewer.resolve(rotated)).status == .obstructed)
        observer.frames[2].orientation = .unclear
        let unknown = try #require(SelectedContentReviewer.confirmHandling(primary, observer: observer))
        #expect(try #require(SelectedContentReviewer.resolve(unknown)).status == .uncertain)
        observer.frames[2].orientation = .upright
        observer.frames[2].index = 1
        #expect(SelectedContentReviewer.confirmHandling(primary, observer: observer) == nil)
    }

    @Test(arguments: [0, 4]) func independentlyConfirmedRotationAtACutCannotHideInAUsableMajority(edge: Int) throws {
        var primary = SelectedContentReviewer.FrameAnswer(frames: (0..<5).map {
            .init(index: $0, content: .event, confidence: 0.95)
        }, observation: "Only the boundary frame is rotated during camera setup", activity: "Driving")
        primary.frames[edge].handlingEvidence = .invertedScene
        var observer = SelectedContentReviewer.OrientationAnswer(frames: (0..<5).map {
            .init(index: $0, scene: "Upright road and vehicle", orientation: .upright, opaqueCoverFraction: 0)
        })
        observer.frames[edge].orientation = .inverted
        observer.frames[edge].orientationBasis = .worldReference
        let confirmed = try #require(SelectedContentReviewer.confirmHandling(primary, observer: observer))
        let answer = try #require(SelectedContentReviewer.resolve(confirmed))
        #expect(answer.status == .obstructed)
        #expect(answer.obstructedSamples == [edge])
        #expect(answer.confirmedBoundaryRotationSamples == [edge])
        #expect(SelectedContentReviewer.valid(answer))
        let item = TimelineItem(assetID: UUID(), kind: .video, sourceDuration: 5, timelineStart: 0, timelineDuration: 5)
        var verdict = assessment(item, status: .obstructed)
        verdict.obstructedSamples = [edge]
        verdict.confirmedBoundaryRotationSamples = [edge]
        #expect(verdict.rejectsRange)
        if edge == 4 {
            let faded = try #require(SelectedContentReviewer.confirmHandling(primary, observer: observer, intentionalFadeSamples: [4]))
            #expect(try #require(SelectedContentReviewer.resolve(faded, intentionalFadeSamples: [4])).status == .usable)
        }
    }

    @Test func aSingleUnconfirmedRotationStillDoesNotOverrideUsefulWork() throws {
        var primary = SelectedContentReviewer.FrameAnswer(frames: (0..<5).map {
            .init(index: $0, content: .event, confidence: 0.95)
        }, observation: "Useful work with equipment", activity: "Fishing")
        var observer = SelectedContentReviewer.OrientationAnswer(frames: (0..<5).map {
            .init(index: $0, scene: "Fishing hands and riverbank", orientation: .upright, opaqueCoverFraction: 0)
        })
        observer.frames[0].orientation = .inverted
        observer.frames[0].orientationBasis = .worldReference
        let singleGuess = try #require(SelectedContentReviewer.confirmHandling(primary, observer: observer))
        #expect(try #require(SelectedContentReviewer.resolve(singleGuess)).status == .usable)
        primary.frames[0].handlingEvidence = .invertedScene
        observer.frames[0].orientation = .upright
        let contradicted = try #require(SelectedContentReviewer.confirmHandling(primary, observer: observer))
        #expect(try #require(SelectedContentReviewer.resolve(contradicted)).status == .usable)
    }

    @Test(arguments: [0, 4]) func independentRotationConflictAtBoundaryCannotBecomeAUsableMajority(edge: Int) throws {
        let primary = SelectedContentReviewer.FrameAnswer(frames: (0..<5).map {
            .init(index: $0, content: .landscape, confidence: 0.95)
        }, observation: "A readable landscape", activity: "unknown")
        let upright = SelectedContentReviewer.OrientationAnswer(frames: (0..<5).map {
            .init(index: $0, scene: "Trees rooted in the ground with crowns toward the sky",
                  orientation: .upright, opaqueCoverFraction: 0, orientationBasis: .worldReference)
        })
        var rotated = upright
        rotated.frames[edge].orientation = .sideways
        let disputed = try #require(SelectedContentReviewer.confirmHandling(primary, observer: rotated,
            independentPurpose: rotated))
        let answer = try #require(SelectedContentReviewer.resolve(disputed))
        #expect(answer.status == .uncertain)
        #expect(answer.confirmedBoundaryRotationSamples?.isEmpty == true)
        #expect(SelectedContentReviewer.valid(answer))
        // A lone purpose guess contradicted by the neutral physical observer
        // cannot reject an otherwise readable frame.
        let corrected = try #require(SelectedContentReviewer.confirmHandling(primary, observer: upright,
            independentPurpose: rotated))
        #expect(try #require(SelectedContentReviewer.resolve(corrected)).status == .usable)
        let neutralOnly = try #require(SelectedContentReviewer.confirmHandling(primary, observer: rotated,
            independentPurpose: upright))
        #expect(try #require(SelectedContentReviewer.resolve(neutralOnly)).status == .usable)
        if edge == 4 {
            let fade = try #require(SelectedContentReviewer.confirmHandling(primary, observer: rotated,
                intentionalFadeSamples: [4], independentPurpose: rotated))
            #expect(try #require(SelectedContentReviewer.resolve(fade, intentionalFadeSamples: [4])).status == .usable)
        }
    }

    @Test(arguments: [SelectedContentReviewer.OrientationBasis.overheadDetail, .uncertain])
    func overheadBagWorkCannotBeRotatedByObjectAngle(basis: SelectedContentReviewer.OrientationBasis) throws {
        let primary = SelectedContentReviewer.FrameAnswer(frames: (0..<5).map {
            .init(index: $0, content: .cameraHandling, confidence: 0.95, handlingEvidence: .invertedScene)
        }, observation: "An angled bag was mistaken for a rotated scene", activity: "Opening a bag")
        let observer = SelectedContentReviewer.OrientationAnswer(frames: (0..<5).map {
            .init(index: $0, scene: "Hands grip an open fabric bag viewed from above; no horizon or standing figure",
                orientation: .sideways, opaqueCoverFraction: 0, orientationBasis: basis)
        })
        let contacts: [SelectedContentReviewer.CameraInteractionFrame] = (0..<5).map {
            .init(index: $0, interaction: .equipmentWork, confidence: 0.95, evidence: "Fingers grip the bag handle and open its fabric case")
        }
        let confirmed = try #require(SelectedContentReviewer.confirmHandling(primary, observer: observer, contacts: contacts))
        let answer = try #require(SelectedContentReviewer.resolve(confirmed))
        #expect(answer.status == .usable)
        #expect(answer.obstructedSamples.isEmpty)
        #expect(answer.confirmedBoundaryRotationSamples == [])
    }

    @Test func absentWorldReferenceAndAbsentGearCannotCertifyRotationOrReadability() throws {
        let primary = SelectedContentReviewer.FrameAnswer(frames: (0..<5).map {
            .init(index: $0, content: .cameraHandling, confidence: 0.95, handlingEvidence: .invertedScene)
        }, observation: "Unclear ground", activity: "unknown")
        var observer = SelectedContentReviewer.OrientationAnswer(frames: (0..<5).map {
            .init(index: $0, scene: "Only texture of the ground is visible", orientation: .sideways,
                opaqueCoverFraction: 0, orientationBasis: .uncertain)
        })
        var unknown = try #require(SelectedContentReviewer.confirmHandling(primary, observer: observer))
        #expect(try #require(SelectedContentReviewer.resolve(unknown)).status == .uncertain)
        for i in observer.frames.indices { observer.frames[i].orientation = .upright }
        unknown = try #require(SelectedContentReviewer.confirmHandling(primary, observer: observer))
        #expect(try #require(SelectedContentReviewer.resolve(unknown)).status == .uncertain)
        for i in observer.frames.indices { observer.frames[i].orientationBasis = .overheadDetail }
        unknown = try #require(SelectedContentReviewer.confirmHandling(primary, observer: observer))
        #expect(try #require(SelectedContentReviewer.resolve(unknown)).status == .uncertain)
    }

    @Test(arguments: [[0, 2], [4], [1], []])
    func hiddenOrientationRetainsOnlyCorroboratedNegativeEvidence(contactIndices: [Int]) throws {
        let primary = SelectedContentReviewer.FrameAnswer(frames: (0..<5).map {
            .init(index: $0, content: .event, confidence: 0.95)
        }, observation: "The foreground hides orientation references", activity: "unknown")
        let orientation = SelectedContentReviewer.OrientationAnswer(frames: (0..<5).map {
            .init(index: $0, scene: "Foreground texture with no readable horizon",
                orientation: .unclear, opaqueCoverFraction: 0.4, orientationBasis: .uncertain)
        })
        var contacts = (0..<5).map { index in
            SelectedContentReviewer.CameraInteractionFrame(index: index,
                interaction: contactIndices.contains(index) ? .cameraAdjustment : .none,
                confidence: 0.9, evidence: contactIndices.contains(index)
                    ? "A near hand touches the filming lens and obscures the scene"
                    : "No visible hand contacts the filming camera")
        }
        let observed = try #require(SelectedContentReviewer.confirmHandling(primary, observer: orientation, contacts: contacts))
        let answer = try #require(SelectedContentReviewer.resolve(observed))
        let sustainedOrTail = contactIndices.count >= 2 || contactIndices.contains(4)
        #expect(answer.status == (sustainedOrTail ? .obstructed : .uncertain))
        #expect(answer.cameraAdjustmentSamples == (sustainedOrTail ? contactIndices : []))
        #expect(answer.status != .usable)
        for i in contacts.indices { contacts[i].confidence = 0.8 }
        let weak = try #require(SelectedContentReviewer.confirmHandling(primary, observer: orientation, contacts: contacts))
        #expect(try #require(SelectedContentReviewer.resolve(weak)).status == .uncertain)
        let incomplete = SelectedContentReviewer.OrientationAnswer(frames: Array(orientation.frames.dropLast()))
        #expect(SelectedContentReviewer.confirmHandling(primary, observer: incomplete, contacts: contacts) == nil)
    }

    @Test func independentGearAndOpenViewCorrectActualBagCoverClaims() throws {
        var primary = SelectedContentReviewer.FrameAnswer(frames: (0..<5).map {
            .init(index: $0, content: .event, confidence: 0.9)
        }, observation: "Bag fabric was mistaken for a lens cover", activity: "Opening a bag")
        for i in [2, 4] {
            primary.frames[i].content = .lensCover
            primary.frames[i].confidence = 0.8
            primary.frames[i].obstructionFraction = i == 2 ? 0.7 : 0.6
        }
        let observer = SelectedContentReviewer.OrientationAnswer(frames: (0..<5).map {
            .init(index: $0, scene: "Hands visibly grip and open a fabric equipment bag",
                orientation: $0 >= 2 ? .sideways : .unclear, opaqueCoverFraction: 0,
                orientationBasis: $0 >= 2 ? .worldReference : .uncertain)
        })
        var contacts: [SelectedContentReviewer.CameraInteractionFrame] = (0..<5).map {
            .init(index: $0, interaction: .equipmentWork, confidence: 0.9,
                evidence: "Fingers grip the fabric bag and its handle")
        }
        contacts[0] = .init(index: 0, interaction: .cameraAdjustment, confidence: 0.9,
            evidence: "A hand is in front of the camera beside a patterned bag")
        let corrected = try #require(SelectedContentReviewer.confirmHandling(primary, observer: observer, contacts: contacts))
        let answer = try #require(SelectedContentReviewer.resolve(corrected))
        #expect(answer.status == .usable)
        #expect(answer.obstructedSamples.isEmpty)
        // Actual opaque cover stays a rejection when the independent physical
        // observation confirms it, even if an interaction label mentions gear.
        var covered = observer
        for i in covered.frames.indices { covered.frames[i].orientation = .upright }
        for i in [2, 4] { covered.frames[i].opaqueCoverFraction = 0.8 }
        let rejected = try #require(SelectedContentReviewer.confirmHandling(primary, observer: covered, contacts: contacts))
        #expect(try #require(SelectedContentReviewer.resolve(rejected)).status == .obstructed)
    }

    @Test func uncertainOrientationCannotEraseObservedOpaqueCover() throws {
        // Actual five-frame 2B observations from IMG_4758, 0.0667–1.8 s.
        // The neutral observer could not orient the obscured scene. Previously
        // that replaced lens-cover with uncertain and the search tried another
        // overlapping interval instead of retaining the existing negative.
        let contents: [SelectedContentReviewer.FrameContent] = [.lensCover, .event, .event, .lensCover, .lensCover]
        let fractions = [0.75, 0.85, 0.85, 0.95, 0.95]
        let orientations: [SelectedContentReviewer.SceneOrientation] = [.inverted, .unclear, .unclear, .unclear, .inverted]
        let primary = SelectedContentReviewer.FrameAnswer(frames: (0..<5).map {
            .init(index: $0, content: contents[$0], confidence: $0 == 0 ? 0.99 : 0.95,
                obstructionFraction: fractions[$0], handlingEvidence: .directLensContact)
        }, observation: "A blurred foreground hand obscures the outdoor scene", activity: "unknown")
        let orientation = SelectedContentReviewer.OrientationAnswer(frames: (0..<5).map {
            .init(index: $0, scene: "A close foreground hand and partially visible grass",
                orientation: orientations[$0], opaqueCoverFraction: 0,
                orientationBasis: [0, 4].contains($0) ? .worldReference : .overheadDetail,
                purpose: .some(.none), purposeConfidence: 0, purposeEvidence: "The view has no readable subject")
        })
        let contacts = (0..<5).map {
            SelectedContentReviewer.CameraInteractionFrame(index: $0, interaction: .none,
                confidence: $0 == 3 ? 0 : 0.8, evidence: "No identifiable hand interaction is visible")
        }
        let checked = try #require(SelectedContentReviewer.confirmHandling(primary, observer: orientation,
            contacts: contacts, independentPurpose: orientation))
        #expect(checked.frames.allSatisfy { $0.orientationUnresolved == true })
        var oldAggregation = checked
        for index in oldAggregation.frames.indices where oldAggregation.frames[index].orientationUnresolved == true {
            oldAggregation.frames[index].content = .uncertain
            oldAggregation.frames[index].orientationUnresolved = nil
        }
        #expect(SelectedContentReviewer.resolve(oldAggregation)?.status == .uncertain)
        let physical = try #require(SelectedContentReviewer.resolve(checked))
        #expect(physical.status == .obstructed && physical.obstructedSamples == [0, 3, 4])
        #expect(physical.cameraAdjustmentSamples == [] && physical.confirmedBoundaryRotationSamples == [])
        let interaction = try #require(SelectedContentReviewer.applyingInteractionCertainty(contacts, to: physical))
        let purpose = try #require(SelectedContentReviewer.applyingPurpose(orientation, to: interaction))
        #expect(purpose.status == .obstructed && purpose.confidence == 0.95)
        // An aggregate negative is not a source certificate or a claim that
        // rotation/contact was confirmed. Old persisted frames remain readable.
        let oldFrame = Data(#"{"index":0,"content":"event","confidence":0.95,"obstructionFraction":0,"handlingEvidence":"none"}"#.utf8)
        #expect(try JSONDecoder().decode(SelectedContentReviewer.FrameVerdict.self, from: oldFrame).orientationUnresolved == nil)
    }

    @Test(arguments: [0, 1, 2])
    func retainingCoverStillRequiresSustainedEvidenceAndNeverCertifiesUnknownOrientation(coverCount: Int) throws {
        let primary = SelectedContentReviewer.FrameAnswer(frames: (0..<5).map {
            .init(index: $0, content: $0 < coverCount ? .lensCover : .event, confidence: 0.95,
                obstructionFraction: $0 < coverCount ? 0.8 : 0)
        }, observation: "The image lacks reliable gravity references", activity: "unknown")
        let orientation = SelectedContentReviewer.OrientationAnswer(frames: (0..<5).map {
            .init(index: $0, scene: "Foreground material without a readable horizon", orientation: .unclear,
                opaqueCoverFraction: 0.4, orientationBasis: .uncertain)
        })
        let checked = try #require(SelectedContentReviewer.confirmHandling(primary, observer: orientation))
        let answer = try #require(SelectedContentReviewer.resolve(checked))
        #expect(answer.status == (coverCount >= 2 ? .obstructed : .uncertain))
        #expect(answer.status != .usable)
        let restored = try JSONDecoder().decode(SelectedContentReviewer.FrameAnswer.self, from: JSONEncoder().encode(checked))
        #expect(SelectedContentReviewer.resolve(restored)?.status == answer.status)
    }

    @Test func repeatedUncorroboratedRotationCannotBecomeAConfidentVerdict() throws {
        let primary = SelectedContentReviewer.FrameAnswer(frames: (0..<5).map {
            .init(index: $0, content: .landscape, confidence: 0.95)
        }, observation: "Normal route", activity: "Driving")
        let observer = SelectedContentReviewer.OrientationAnswer(frames: (0..<5).map {
            .init(index: $0, scene: "Route with conflicting orientation observations",
                orientation: $0 == 1 || $0 == 3 ? .sideways : .upright, opaqueCoverFraction: 0,
                orientationBasis: .worldReference)
        })
        let corrected = try #require(SelectedContentReviewer.confirmHandling(primary, observer: observer))
        let answer = try #require(SelectedContentReviewer.resolve(corrected))
        #expect(answer.status == .uncertain)
        #expect(answer.obstructedSamples.isEmpty)
    }

    @Test func repeatedCameraHandlingAndIndependentWorldRotationStayRejected() throws {
        var primary = SelectedContentReviewer.FrameAnswer(frames: (0..<5).map {
            .init(index: $0, content: .landscape, confidence: 0.9)
        }, observation: "Repeated camera repositioning in a vehicle", activity: "Driving")
        for i in [2, 3, 4] { primary.frames[i].content = .cameraHandling }
        var observer = SelectedContentReviewer.OrientationAnswer(frames: (0..<5).map {
            .init(index: $0, scene: "Vehicle against rotated trees and a wall",
                orientation: $0 == 1 ? .upright : .sideways, opaqueCoverFraction: 0,
                orientationBasis: .worldReference)
        })
        let confirmed = try #require(SelectedContentReviewer.confirmHandling(primary, observer: observer))
        #expect(try #require(SelectedContentReviewer.resolve(confirmed)).status == .obstructed)
        // The generic technical label alone still cannot reject useful POV.
        for i in observer.frames.indices { observer.frames[i].orientation = .upright }
        let upright = try #require(SelectedContentReviewer.confirmHandling(primary, observer: observer))
        #expect(try #require(SelectedContentReviewer.resolve(upright)).status == .usable)
    }

    @Test func overheadGearCannotExcuseActualLensContactAtTheCut() throws {
        let primary = SelectedContentReviewer.FrameAnswer(frames: (0..<5).map {
            .init(index: $0, content: .event, confidence: 0.95)
        }, observation: "Gear followed by a camera reach", activity: "Packing")
        var observer = SelectedContentReviewer.OrientationAnswer(frames: (0..<5).map {
            .init(index: $0, scene: "Hands and bag, viewed from above", orientation: .upright,
                opaqueCoverFraction: 0, orientationBasis: .overheadDetail)
        })
        var contacts: [SelectedContentReviewer.CameraInteractionFrame] = (0..<5).map {
            .init(index: $0, interaction: .equipmentWork, confidence: 0.95, evidence: "Fingers grip the bag handle")
        }
        contacts[4] = .init(index: 4, interaction: .cameraAdjustment, confidence: 0.95,
            evidence: "Fingertips approach the lens directly and touch its edge")
        let confirmed = try #require(SelectedContentReviewer.confirmHandling(primary, observer: observer, contacts: contacts))
        let answer = try #require(SelectedContentReviewer.resolve(confirmed))
        #expect(answer.status == .obstructed)
        #expect(answer.cameraAdjustmentSamples == [4])
        observer.frames[4].orientation = .sideways
        observer.frames[4].orientationBasis = .worldReference
        let conflict = try #require(SelectedContentReviewer.confirmHandling(primary, observer: observer, contacts: contacts))
        #expect(try #require(SelectedContentReviewer.resolve(conflict)).cameraAdjustmentSamples == [4])
    }

    @Test func readableFramesNeedAnObservedEditorialPurpose() throws {
        let technical = SelectedContentReviewer.Answer(status: .usable, confidence: 0.95,
            obstructedSamples: [], observation: "Объектив открыт, положение камеры нормальное", activity: "unknown")
        var observer = SelectedContentReviewer.OrientationAnswer(frames: (0..<5).map {
            .init(index: $0, scene: "Ground, fence and a coat edge", orientation: .upright, opaqueCoverFraction: 0.1,
                purpose: .some(.none), purposeConfidence: 0.9, purposeEvidence: "No readable action or coherent view of a place; torso is cropped at the edge")
        })
        let rejected = try #require(SelectedContentReviewer.applyingPurpose(observer, to: technical))
        #expect(rejected.status == .unmotivated && rejected.irrelevantSamples == [0, 1, 2, 3, 4])
        #expect(SelectedContentReviewer.valid(rejected))
        let item = TimelineItem(assetID: UUID(), kind: .video, sourceDuration: 5, timelineStart: 0, timelineDuration: 5)
        var rejectedRange = assessment(item, status: rejected.status)
        rejectedRange.confidence = rejected.confidence
        #expect(rejectedRange.rejectsRange)
        // Purposeful POV, portraits and establishing views remain eligible.
        for role in [SelectedContentReviewer.EditorialPurpose.action, .portrait, .detail, .establishing] {
            for index in 0..<5 {
                observer.frames[index].purpose = role
                observer.frames[index].purposeEvidence = "Clearly readable main subject, activity, equipment or route"
            }
            #expect(try #require(SelectedContentReviewer.applyingPurpose(observer, to: technical)).status == .usable)
        }
        // An editorial observer's guessed orientation is never physical proof.
        // Actual normal equipment close-ups exposed this combined-question error.
        observer.frames[2].orientation = .sideways
        observer.frames[3].orientation = .sideways
        #expect(try #require(SelectedContentReviewer.applyingPurpose(observer, to: technical)).status == .usable)
        // A contradictory image is not proof that the whole action is bad,
        // but the majority cannot certify that unexplained interval either.
        observer.frames[0].purpose = .some(.none)
        #expect(try #require(SelectedContentReviewer.applyingPurpose(observer, to: technical)).status == .uncertain)
        observer.frames[1].purpose = .unclear
        observer.frames[2].purposeConfidence = 0.4
        #expect(try #require(SelectedContentReviewer.applyingPurpose(observer, to: technical)).status == .uncertain)
        observer.frames[2].purposeConfidence = .nan
        #expect(SelectedContentReviewer.applyingPurpose(observer, to: technical) == nil)
    }

    @Test func unresolvedPurposeCannotBorrowConfidenceFromOtherFrames() throws {
        let technical = SelectedContentReviewer.Answer(status: .usable, confidence: 0.95,
            obstructedSamples: [], observation: "The beginning shows a readable scene", activity: "unknown")
        let good = SelectedContentReviewer.OrientationAnswer(frames: (0..<5).map {
            .init(index: $0, scene: "Coherent place", orientation: .upright, opaqueCoverFraction: 0,
                purpose: .establishing, purposeConfidence: 0.95, purposeEvidence: "A readable view establishes the place")
        })
        for index in 0..<5 {
            for purpose in [SelectedContentReviewer.EditorialPurpose.none, .unclear, .establishing] {
                var observation = good
                observation.frames[index].purpose = purpose
                observation.frames[index].purposeConfidence = 0
                let result = try #require(SelectedContentReviewer.applyingPurpose(observation, to: technical))
                #expect(result.status == .uncertain)
            }
        }
        var groundTail = good
        for index in [3, 4] {
            groundTail.frames[index].purpose = .some(.none)
            groundTail.frames[index].purposeConfidence = 0
            groundTail.frames[index].purposeEvidence = "Only incidental ground, no readable subject"
        }
        #expect(try #require(SelectedContentReviewer.applyingPurpose(groundTail, to: technical)).status == .uncertain)
        #expect(try #require(SelectedContentReviewer.applyingPurpose(groundTail, to: technical,
            intentionalFadeSamples: [3, 4])).status == .usable)
        for index in [3, 4] { groundTail.frames[index].purposeConfidence = 0.95 }
        let rejected = try #require(SelectedContentReviewer.applyingPurpose(groundTail, to: technical))
        #expect(rejected.status == .unmotivated && rejected.unmotivatedEnding == true)
    }

    @Test func purposeClarificationUsesTheSameImageAndModelAndKeepsBothReplies() async throws {
        actor Observer {
            var requests: [[String: Any]] = []
            func respond(_ request: URLRequest) throws -> (Data, URLResponse) {
                let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
                requests.append(body)
                let content: [String: Any] = ["scene": "Incidental ground without a subject", "orientation": "upright",
                    "opaqueCoverFraction": 0, "purpose": "none", "purposeConfidence": requests.count == 1 ? 0 : 0.95,
                    "purposeEvidence": "No readable subject or coherent view of a place"]
                let reply = String(data: try JSONSerialization.data(withJSONObject: content), encoding: .utf8)!
                return (try JSONSerialization.data(withJSONObject: ["model": "fixture", "done": true, "done_reason": "stop",
                    "message": ["content": reply]]), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            func verify() throws {
                #expect(requests.count == 2)
                for body in requests {
                    #expect(body["model"] as? String == "fixture")
                    let messages = try #require(body["messages"] as? [[String: Any]])
                    #expect(messages.first?["images"] as? [String] == ["unchanged-rendered-pixels"])
                }
                let prompts = requests.compactMap { ($0["messages"] as? [[String: Any]])?.first?["content"] as? String }
                #expect(Set(prompts).count == 2)
            }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let observer = Observer()
        let reviewer = SelectedContentReviewer(cacheURL: root, model: "fixture", answerTransport: { try await observer.respond($0) })
        let sample = VisualFrameSample(timestamp: 0, motion: 0, exposure: 0.5, detail: 0.5, labels: [],
            labelConfidence: 1, faceCount: 0, jpegBase64: "unchanged-rendered-pixels", histogram: [], luminanceFingerprint: [])
        let response = root.appendingPathComponent("purpose.json")
        let result = try await reviewer.inspectPurpose(samples: [sample], indices: [0], responseURL: response)
        #expect(result.frames.first?.purpose == .some(.none) && result.frames.first?.purposeConfidence == 0.95)
        _ = try await reviewer.inspectPurpose(samples: [sample], indices: [0], responseURL: response)
        try await observer.verify()
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("purpose.frame-0.json").path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("purpose.frame-0-clarified.json").path))
    }

    @Test func adjustingTheCameraIsNotMadeUsefulByAnOpenView() throws {
        var primary = SelectedContentReviewer.FrameAnswer(frames: (0..<5).map {
            .init(index: $0, content: .event, confidence: 0.9)
        }, observation: "Человек на доске тянет руку к камере", activity: "Настройка камеры")
        for i in [1, 3] { primary.frames[i].handlingEvidence = .directLensContact }
        var observer = SelectedContentReviewer.OrientationAnswer(frames: (0..<5).map {
            .init(index: $0, scene: "Person on a paddleboard, scene upright", orientation: .upright, opaqueCoverFraction: 0)
        })
        var contacts = [1, 3].map { SelectedContentReviewer.CameraInteractionFrame(index: $0,
            interaction: .cameraAdjustment, confidence: 0.9, evidence: "Hand reaches toward the filming lens") }
        let confirmed = try #require(SelectedContentReviewer.confirmHandling(primary, observer: observer, contacts: contacts))
        #expect(try #require(SelectedContentReviewer.resolve(confirmed)).status == .obstructed)
        for i in contacts.indices { contacts[i].interaction = .equipmentWork; contacts[i].evidence = "Hand grips the fishing rod, not the filming camera" }
        let useful = try #require(SelectedContentReviewer.confirmHandling(primary, observer: observer, contacts: contacts))
        #expect(try #require(SelectedContentReviewer.resolve(useful)).status == .usable)
        contacts[0].interaction = .unclear
        #expect(SelectedContentReviewer.confirmHandling(primary, observer: observer, contacts: contacts) == nil)
        observer.frames[1].orientation = .unclear
        observer.frames[3].orientation = .unclear
        let faded = try #require(SelectedContentReviewer.confirmHandling(primary, observer: observer,
            intentionalFadeSamples: [1, 3]))
        #expect(try #require(SelectedContentReviewer.resolve(faded, intentionalFadeSamples: [1, 3])).status == .usable)
    }

    @Test func socialGesturesDoNotConfirmCameraHandling() throws {
        var primary = SelectedContentReviewer.FrameAnswer(frames: (0..<5).map {
            .init(index: $0, content: .event, confidence: 0.9)
        }, observation: "People greet each other while driving", activity: "Driving")
        for index in [3, 4] { primary.frames[index].handlingEvidence = .directLensContact }
        let observer = SelectedContentReviewer.OrientationAnswer(frames: (0..<5).map {
            .init(index: $0, scene: "Helmeted driver and passenger in an upright buggy", orientation: .upright, opaqueCoverFraction: 0)
        })
        let contacts = [3, 4].map { SelectedContentReviewer.CameraInteractionFrame(index: $0,
            interaction: .socialGesture, confidence: 0.95, evidence: "Passenger shows a peace sign while the driver grips the wheel") }
        let checked = try #require(SelectedContentReviewer.confirmHandling(primary, observer: observer, contacts: contacts))
        let result = try #require(SelectedContentReviewer.resolve(checked))
        #expect(result.status == .usable && result.cameraAdjustmentSamples == [])
    }

    @Test func bareContradictoryLabelCannotConfirmCameraContact() {
        let primary = SelectedContentReviewer.FrameAnswer(frames: (0..<5).map {
            .init(index: $0, content: .event, confidence: 0.9)
        }, observation: "Driver holding the wheel", activity: "Driving")
        let observer = SelectedContentReviewer.OrientationAnswer(frames: (0..<5).map {
            .init(index: $0, scene: "Driver in an upright buggy", orientation: .upright, opaqueCoverFraction: 0)
        })
        for label in ["equipment-work", " Equipment-work. ", "camera-adjustment", "social-gesture"] {
            let contact = SelectedContentReviewer.CameraInteractionFrame(index: 4,
                interaction: .cameraAdjustment, confidence: 0.99, evidence: label)
            #expect(!SelectedContentReviewer.literalInteractionEvidence(contact))
            #expect(SelectedContentReviewer.confirmHandling(primary, observer: observer, contacts: [contact]) == nil)
        }
        let literal = SelectedContentReviewer.CameraInteractionFrame(index: 4,
            interaction: .cameraAdjustment, confidence: 0.95, evidence: "Fingers reach straight toward the filming lens")
        #expect(SelectedContentReviewer.literalInteractionEvidence(literal))
    }

    @Test func purposefulBeginningCannotCertifyAnIncidentalEnding() throws {
        let technical = SelectedContentReviewer.Answer(status: .usable, confidence: 0.95,
            obstructedSamples: [], observation: "Люди в багги, затем камера уходит вверх", activity: "Поездка")
        var observer = SelectedContentReviewer.OrientationAnswer(frames: (0..<5).map {
            .init(index: $0, scene: "People in a buggy", orientation: .upright, opaqueCoverFraction: 0,
                  purpose: .action, purposeConfidence: 0.95, purposeEvidence: "Readable helmeted occupants in the vehicle")
        })
        observer.frames[4].purpose = .some(.none)
        observer.frames[4].purposeConfidence = 0.9
        observer.frames[4].purposeEvidence = "Camera points at sky through the vehicle cage; no readable subject or coherent place view"
        let rejected = try #require(SelectedContentReviewer.applyingPurpose(observer, to: technical))
        #expect(rejected.status == .unmotivated && rejected.unmotivatedEnding == true)
        #expect(rejected.irrelevantSamples == [4] && SelectedContentReviewer.valid(rejected))
        let item = TimelineItem(assetID: UUID(), kind: .video, sourceDuration: 5, timelineStart: 0, timelineDuration: 5)
        var range = assessment(item, status: .unmotivated)
        range.irrelevantSamples = rejected.irrelevantSamples
        range.unmotivatedEnding = rejected.unmotivatedEnding
        #expect(range.rejectsRange)
        range.unmotivatedEnding = nil
        #expect(!range.rejectsRange)
        let fade = try #require(SelectedContentReviewer.applyingPurpose(observer, to: technical, intentionalFadeSamples: [4]))
        #expect(fade.status == .usable && fade.unmotivatedEnding == false)
        observer.frames[4].purpose = .detail
        observer.frames[4].purposeEvidence = "Hands operate an identifiable fishing reel"
        #expect(try #require(SelectedContentReviewer.applyingPurpose(observer, to: technical)).status == .usable)
        observer.frames[0].purpose = .some(.none)
        #expect(try #require(SelectedContentReviewer.applyingPurpose(observer, to: technical)).status == .uncertain)
        var contradictory = rejected
        contradictory.status = .usable
        #expect(!SelectedContentReviewer.valid(contradictory))
        contradictory = rejected
        contradictory.irrelevantSamples = [0]
        #expect(!SelectedContentReviewer.valid(contradictory))
    }

    @Test func laterActionCannotCertifyARepeatedIncidentalEntry() throws {
        let technical = SelectedContentReviewer.Answer(status: .usable, confidence: 0.8,
            obstructedSamples: [], observation: "Cropped legs and ground followed by work with a bottle", activity: "bottle handling")
        var observer = SelectedContentReviewer.OrientationAnswer(frames: (0..<5).map {
            .init(index: $0, scene: "People near fishing equipment", orientation: .upright, opaqueCoverFraction: 0,
                purpose: $0 < 2 ? .some(.none) : .action, purposeConfidence: 0.9,
                purposeEvidence: $0 < 2 ? "Accidentally cropped legs and ground with no readable activity" : "Hands operate a visible bottle")
        })
        let answer = try #require(SelectedContentReviewer.applyingPurpose(observer, to: technical))
        #expect(answer.status == .unmotivated && answer.unmotivatedBeginning == true)
        #expect(SelectedContentReviewer.valid(answer))
        let item = TimelineItem(assetID: UUID(), kind: .video, sourceDuration: 5, timelineStart: 0, timelineDuration: 5)
        var range = assessment(item, status: answer.status)
        range.irrelevantSamples = answer.irrelevantSamples
        range.unmotivatedBeginning = answer.unmotivatedBeginning
        #expect(range.rejectsRange)
        var contradiction = answer; contradiction.status = .usable
        #expect(!SelectedContentReviewer.valid(contradiction))
        observer.frames[1].purpose = .detail
        #expect(try #require(SelectedContentReviewer.applyingPurpose(observer, to: technical)).status == .uncertain)
        observer.frames[0].purpose = .detail
        #expect(try #require(SelectedContentReviewer.applyingPurpose(observer, to: technical)).status == .usable)
    }

    @Test func headwearFittedOnlyAfterCutDoesNotBecomeContinuousPreparation() throws {
        typealias State = SelectedContentReviewer.HeadwearState
        let bare = State(observation: "Two people hold separate objects away from their heads", people: 2, worn: 0, beingPutOn: 0, confidence: 0.95)
        let fitting = State(observation: "One person holds an unfitted cloth covering over the face", people: 2, worn: 0, beingPutOn: 1, confidence: 0.95)
        let worn = State(observation: "One person has a fitted cloth covering on the head", people: 2, worn: 1, beingPutOn: 0, confidence: 0.9)
        #expect(SelectedContentReviewer.missingHeadwearOutcome([bare, bare, fitting, worn]) == 0.9)
        // The putting-on action must already be visible inside the cut.
        #expect(SelectedContentReviewer.missingHeadwearOutcome([bare, bare, bare, worn]) == nil)
        #expect(SelectedContentReviewer.missingHeadwearOutcome([bare, fitting, worn, worn]) == nil)
        // Adjusting already-worn headgear, unrelated gestures, or an obscured
        // new person cannot supply a missing physical outcome.
        #expect(SelectedContentReviewer.missingHeadwearOutcome([worn, worn, worn, worn]) == nil)
        var newPerson = worn; newPerson.people = 3
        #expect(SelectedContentReviewer.missingHeadwearOutcome([bare, bare, fitting, newPerson]) == nil)
        var weak = worn; weak.confidence = 0.7
        #expect(SelectedContentReviewer.missingHeadwearOutcome([bare, bare, fitting, weak]) == 0.7)
        var malformed = fitting; malformed.worn = 2
        #expect(!malformed.isValid)
        #expect(SelectedContentReviewer.missingHeadwearOutcome([bare, bare, malformed, worn]) == nil)
    }

    @Test func headwearObserverNeedsLiteralObjectAndHandlingEvidence() {
        #expect(SelectedContentReviewer.needsHeadwearBoundaryCheck(["The person is holding a helmet while preparing gear"]))
        #expect(SelectedContentReviewer.needsHeadwearBoundaryCheck(["Adjusting a cloth cap beside a vehicle"]))
        #expect(!SelectedContentReviewer.needsHeadwearBoundaryCheck(["A person in a hat paddles on the river"]))
        #expect(!SelectedContentReviewer.needsHeadwearBoundaryCheck(["Holding that fishing rod while standing"]))
        #expect(!SelectedContentReviewer.needsHeadwearBoundaryCheck(["Packing a chair into its bag"]))
        #expect(!SelectedContentReviewer.needsHeadwearBoundaryCheck([
            "Both are holding tablets. The person on the left is wearing a grey sweatshirt and cap, while the other wears headphones."]))
        #expect(!SelectedContentReviewer.needsHeadwearBoundaryCheck(["A person wearing a cap is holding a tablet"]))
        #expect(!SelectedContentReviewer.needsHeadwearBoundaryCheck(["Holding a tablet while wearing a hat"]))
        #expect(SelectedContentReviewer.needsHeadwearBoundaryCheck(["The helmet is being held above the person's head"]))
        #expect(SelectedContentReviewer.needsHeadwearBoundaryCheck(["Hands are pulling a balaclava over the face"]))
    }

    @Test func contradictoryPhysicalCountsAreUncertainEvidenceNotAnUnavailableProbe() throws {
        typealias State = SelectedContentReviewer.HeadwearState
        let regular = State(observation: "One person wears a cap and another holds a cloth", people: 2, worn: 1, beingPutOn: 0, confidence: 0.9)
        // Actual model response: three mutually exclusive states for two people.
        let conflict = State(observation: "One person is adjusting a cloth and the other wears a helmet", people: 2, worn: 2, beingPutOn: 1, confidence: 0.9)
        #expect(conflict.isStructurallyValid && !conflict.isValid)
        #expect(SelectedContentReviewer.uncertainHeadwearEvidence([regular, regular, regular, conflict]))
        #expect(SelectedContentReviewer.missingHeadwearOutcome([regular, regular, regular, conflict]) == nil)
        #expect(!SelectedContentReviewer.uncertainHeadwearEvidence(Array(repeating: regular, count: 4)))
        var broken = conflict; broken.confidence = .nan
        #expect(!broken.isStructurallyValid)
        broken = conflict; broken.observation = ""
        #expect(!broken.isStructurallyValid)
        let item = TimelineItem(candidateID: UUID(), assetID: UUID(), kind: .video, sourceDuration: 6, timelineStart: 0, timelineDuration: 6)
        let good = TimelineItem(candidateID: UUID(), assetID: UUID(), kind: .video, sourceDuration: 6, timelineStart: 6, timelineDuration: 6)
        var uncertain = assessment(item, status: .uncertain)
        uncertain.confidence = 0.85
        let timeline = Timeline(storyPlanID: UUID(), items: [item, good])
        #expect(SelectedContentReviewer.uncertifiedCandidateIDs([uncertain, assessment(good)], timeline: timeline) == [item.candidateID!])
        uncertain.confidence = 0
        #expect(SelectedContentReviewer.uncertifiedCandidateIDs([uncertain, assessment(good)], timeline: timeline).isEmpty)
    }

    @Test func oneIndependentlyConfirmedCameraAdjustmentAtTheCutCannotPass() throws {
        var primary = SelectedContentReviewer.FrameAnswer(frames: (0..<5).map {
            .init(index: $0, content: .event, confidence: 0.95)
        }, observation: "Человек у реки в конце тянется к камере", activity: "Рыбалка")
        primary.frames[4].handlingEvidence = .directLensContact
        let upright = SelectedContentReviewer.OrientationAnswer(frames: (0..<5).map {
            .init(index: $0, scene: "Upright fishing scene", orientation: .upright, opaqueCoverFraction: 0)
        })
        // An unconfirmed guess alone still cannot reject a useful close-up.
        #expect(try #require(SelectedContentReviewer.resolve(primary)).status == .usable)
        var contacts = [SelectedContentReviewer.CameraInteractionFrame(index: 4,
            interaction: .cameraAdjustment, confidence: 0.95, evidence: "Fingers reach directly toward the filming camera")]
        let confirmed = try #require(SelectedContentReviewer.confirmHandling(primary, observer: upright, contacts: contacts))
        let verdict = try #require(SelectedContentReviewer.resolve(confirmed))
        #expect(verdict.status == .obstructed && verdict.obstructedSamples == [4])
        #expect(verdict.cameraAdjustmentSamples == [4] && SelectedContentReviewer.valid(verdict))
        let item = TimelineItem(assetID: UUID(), kind: .video, sourceDuration: 4, timelineStart: 0, timelineDuration: 4)
        var reviewed = assessment(item, status: .obstructed)
        reviewed.obstructedSamples = [4]
        #expect(!reviewed.rejectsRange)
        reviewed.cameraAdjustmentSamples = verdict.cameraAdjustmentSamples
        #expect(reviewed.rejectsRange)
        contacts[0].interaction = .equipmentWork
        contacts[0].evidence = "Hand grips a rod, not the camera"
        let equipment = try #require(SelectedContentReviewer.confirmHandling(primary, observer: upright, contacts: contacts))
        #expect(try #require(SelectedContentReviewer.resolve(equipment)).status == .usable)
        let fade = try #require(SelectedContentReviewer.confirmHandling(primary, observer: upright,
            intentionalFadeSamples: [4]))
        #expect(try #require(SelectedContentReviewer.resolve(fade, intentionalFadeSamples: [4])).status == .usable)
    }

    @Test func literalSceneTargetsPreventFalseCameraRejectionWithoutExcusingRealReach() throws {
        let primary = SelectedContentReviewer.FrameAnswer(frames: (0..<5).map {
            .init(index: $0, content: .event, confidence: 0.95)
        }, observation: "Two people seated outdoors", activity: "Rest stop")
        let upright = SelectedContentReviewer.OrientationAnswer(frames: (0..<5).map {
            .init(index: $0, scene: "People sit upright behind their equipment", orientation: .upright, opaqueCoverFraction: 0)
        })
        let claim = SelectedContentReviewer.CameraInteractionFrame(index: 4,
            interaction: .cameraAdjustment, confidence: 0.95,
            evidence: "A hand reaches toward the filming lens")
        for observation in [
            "A distant seated person's fingers hold a game piece over the board.",
            "The seated person holds their own phone behind the chair.",
            "The passenger rests a gloved hand on their knee inside the buggy."
        ] {
            let corrected = try #require(SelectedContentReviewer.corroboratingCameraClaim(claim,
                with: .init(observation: observation, target: .filmedObject, confidence: 0.9)))
            let checked = try #require(SelectedContentReviewer.confirmHandling(primary, observer: upright, contacts: [corrected]))
            let answer = try #require(SelectedContentReviewer.resolve(checked))
            #expect(answer.status == .usable && answer.cameraAdjustmentSamples == [])
        }
        let contact = try #require(SelectedContentReviewer.corroboratingCameraClaim(claim,
            with: .init(observation: "The foreshortened forearm extends toward the recording viewpoint and fills the near edge.",
                        target: .filmingLens, confidence: 0.95)))
        let checked = try #require(SelectedContentReviewer.confirmHandling(primary, observer: upright, contacts: [contact]))
        let answer = try #require(SelectedContentReviewer.resolve(checked))
        #expect(answer.status == .obstructed && answer.cameraAdjustmentSamples == [4])
    }

    @Test func unresolvedCameraTargetCannotCertifyOrCondemnTheRange() {
        let claim = SelectedContentReviewer.CameraInteractionFrame(index: 4,
            interaction: .cameraAdjustment, confidence: 0.95, evidence: "Hand reaches toward camera")
        for target in [SelectedContentReviewer.HandTarget.filmedObject, .filmingLens, .unknown] {
            #expect(SelectedContentReviewer.corroboratingCameraClaim(claim,
                with: .init(observation: "The hand target is not physically identifiable in this view.", target: target, confidence: 0.7)) == nil)
        }
        #expect(SelectedContentReviewer.corroboratingCameraClaim(claim,
            with: .init(observation: "The hand target is not physically identifiable in this view.", target: .unknown, confidence: 0.99)) == nil)
        #expect(SelectedContentReviewer.corroboratingCameraClaim(claim,
            with: .init(observation: "filmed-object", target: .filmedObject, confidence: 0.99)) == nil)
    }

    @Test func primarySceneryLabelCannotSuppressIndependentCameraContact() throws {
        let primary = SelectedContentReviewer.FrameAnswer(frames: (0..<5).map {
            .init(index: $0, content: .landscape, confidence: 0.95)
        }, observation: "Wide campsite throughout", activity: "unknown")
        let observer = SelectedContentReviewer.OrientationAnswer(frames: (0..<5).map {
            .init(index: $0, scene: "Upright riverside campsite", orientation: .upright, opaqueCoverFraction: 0)
        })
        #expect(try #require(SelectedContentReviewer.resolve(primary)).status == .usable)
        var contacts = [SelectedContentReviewer.CameraInteractionFrame(index: 4,
            interaction: .cameraAdjustment, confidence: 0.95, evidence: "Near-camera hand reaches straight toward the filming lens")]
        let checked = try #require(SelectedContentReviewer.confirmHandling(primary, observer: observer, contacts: contacts))
        let rejected = try #require(SelectedContentReviewer.resolve(checked))
        #expect(rejected.status == .obstructed && rejected.cameraAdjustmentSamples == [4])
        contacts[0].interaction = .equipmentWork
        let equipment = try #require(SelectedContentReviewer.confirmHandling(primary, observer: observer, contacts: contacts))
        #expect(try #require(SelectedContentReviewer.resolve(equipment)).status == .usable)
        contacts[0].interaction = .cameraAdjustment
        contacts[0].confidence = 0.6
        let weak = try #require(SelectedContentReviewer.confirmHandling(primary, observer: observer, contacts: contacts))
        #expect(try #require(SelectedContentReviewer.resolve(weak)).status == .usable)
        contacts[0].confidence = 0.95
        let fade = try #require(SelectedContentReviewer.confirmHandling(primary, observer: observer,
            contacts: contacts, intentionalFadeSamples: [4]))
        #expect(try #require(SelectedContentReviewer.resolve(fade, intentionalFadeSamples: [4])).status == .usable)
    }

    @Test func openHandApproachingIdentifiedGearIsNotACameraTail() throws {
        let primary = SelectedContentReviewer.FrameAnswer(frames: (0..<5).map {
            .init(index: $0, content: .event, confidence: 0.95)
        }, observation: "Hand reaches forward then visibly grips fishing gear", activity: "Fishing")
        let upright = SelectedContentReviewer.OrientationAnswer(frames: (0..<5).map {
            .init(index: $0, scene: "Upright gear work", orientation: .upright, opaqueCoverFraction: 0)
        })
        var contacts = (0..<5).map { SelectedContentReviewer.CameraInteractionFrame(index: $0,
            interaction: $0 <= 1 ? .cameraAdjustment : .equipmentWork, confidence: 0.9,
            evidence: $0 <= 1 ? "Open hand reaches forward" : "Hand visibly grips fishing rod") }
        let gear = try #require(SelectedContentReviewer.confirmHandling(primary, observer: upright, contacts: contacts))
        #expect(try #require(SelectedContentReviewer.resolve(gear)).status == .usable)
        contacts[4].interaction = .cameraAdjustment
        contacts[4].evidence = "Hand reaches directly toward filming lens at cut"
        let tail = try #require(SelectedContentReviewer.confirmHandling(primary, observer: upright, contacts: contacts))
        #expect(try #require(SelectedContentReviewer.resolve(tail)).status == .obstructed)
        contacts = contacts.map { var value = $0; if value.index >= 2 { value.interaction = .none }; return value }
        let sustained = try #require(SelectedContentReviewer.confirmHandling(primary, observer: upright, contacts: contacts))
        #expect(try #require(SelectedContentReviewer.resolve(sustained)).status == .obstructed)
    }

    @Test func isolatedMiddleCameraGuessDoesNotOverrideReadableSequence() throws {
        let primary = SelectedContentReviewer.FrameAnswer(frames: (0..<5).map {
            .init(index: $0, content: .landscape, confidence: 0.95)
        }, observation: "Walking up readable steps", activity: "Walking")
        let upright = SelectedContentReviewer.OrientationAnswer(frames: (0..<5).map {
            .init(index: $0, scene: "Upright route", orientation: .upright, opaqueCoverFraction: 0)
        })
        let contacts = [SelectedContentReviewer.CameraInteractionFrame(index: 1,
            interaction: .cameraAdjustment, confidence: 0.9, evidence: "Possible finger by image edge")]
        let checked = try #require(SelectedContentReviewer.confirmHandling(primary, observer: upright, contacts: contacts))
        let result = try #require(SelectedContentReviewer.resolve(checked))
        #expect(result.status == .usable && result.cameraAdjustmentSamples == [] && SelectedContentReviewer.valid(result))
    }

    @Test func aSceneryReplacementCannotDriftIntoIncidentalNonContent() throws {
        let technical = SelectedContentReviewer.Answer(status: .usable, confidence: 0.9,
            obstructedSamples: [], observation: "Спуск виден в начале; затем случайный вид на склон и забор", activity: "unknown")
        var observer = SelectedContentReviewer.OrientationAnswer(frames: (0..<5).map {
            .init(index: $0, scene: "Wooded descent", orientation: .upright, opaqueCoverFraction: 0,
                purpose: .establishing, purposeConfidence: 0.9, purposeEvidence: "A readable route through the trees")
        })
        observer.frames[4].purpose = .some(.none)
        let brokenEnding = try #require(SelectedContentReviewer.applyingPurpose(observer, to: technical))
        #expect(brokenEnding.status == .unmotivated && brokenEnding.unmotivatedEnding == true)
        observer.frames[4].purpose = .establishing
        observer.frames[2].purpose = .some(.none)
        #expect(try #require(SelectedContentReviewer.applyingPurpose(observer, to: technical)).status == .uncertain)
        observer.frames[2].purpose = .establishing
        observer.frames[4].purpose = .some(.none)
        observer.frames[3].purpose = .some(.none)
        let interrupted = try #require(SelectedContentReviewer.applyingPurpose(observer, to: technical))
        #expect(interrupted.status == .unmotivated && interrupted.interruptedScenery == true)
        #expect(interrupted.irrelevantSamples == [3, 4] && SelectedContentReviewer.valid(interrupted))
        let item = TimelineItem(assetID: UUID(), kind: .video, sourceDuration: 4, timelineStart: 0, timelineDuration: 4)
        var range = assessment(item, status: interrupted.status)
        range.irrelevantSamples = interrupted.irrelevantSamples
        #expect(!range.rejectsRange)
        range.interruptedScenery = true
        #expect(range.rejectsRange)
        observer.frames[1].purpose = .action
        #expect(try #require(SelectedContentReviewer.applyingPurpose(observer, to: technical)).status == .unmotivated)
        observer.frames[1].purpose = .establishing
        let fadeExempt = try #require(SelectedContentReviewer.applyingPurpose(observer, to: technical, intentionalFadeSamples: [3, 4]))
        #expect(fadeExempt.status == .usable)
    }

    @Test func finalDeliveryCannotCertifyTruncatedConfirmedActionBoundaries() throws {
        let assetID = UUID()
        var candidate = Candidate(assetID: assetID, sourceStart: 0, sourceDuration: 10,
            scores: .init(quality: 0.9, interest: 0.9, action: 0.9, stability: 0.9))
        candidate.momentBoundary = .init(anticipationStart: 1, peakTime: 4, reactionEnd: 8,
            completionEnd: 8, confidence: 0.9, actionEvidenceConfirmed: true)
        let analyses = [AnalysisResult(assetID: assetID, analyzedContentHash: "boundary-fixture",
            sceneTags: [], candidates: [candidate])]
        let plan = StoryPlan(prompt: "Сохрани законченное действие и реакцию", preset: .story,
            constraints: .init(targetDuration: 7), chapters: [])
        let item = TimelineItem(candidateID: candidate.id, assetID: assetID, kind: .video,
            sourceStart: 1, sourceDuration: 7, timelineStart: 0, timelineDuration: 7)
        var timeline = Timeline(storyPlanID: plan.id, items: [item])
        func completion(_ timeline: Timeline) throws -> FilmRequirementResult {
            try #require(AutomaticFilmDelivery.verifiedReport(for: timeline, plan: plan,
                assets: [], analyses: analyses).requirements?.first { $0.rule == "actionCompletion" })
        }
        #expect(try completion(timeline).passed)
        #expect(try completion(timeline).mandatory)
        // Finishing changes the actual range after an earlier successful
        // review. Neither the old duration nor a cached review can certify it.
        timeline.items[0].sourceDuration = 5
        #expect(try !completion(timeline).passed)
        timeline.items[0].sourceStart = 2
        timeline.items[0].sourceDuration = 6
        #expect(try !completion(timeline).passed)
        timeline.items[0] = item
        #expect(try completion(timeline).passed)
    }

}
