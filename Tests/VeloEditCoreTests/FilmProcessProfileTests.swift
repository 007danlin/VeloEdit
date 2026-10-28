import Foundation
import Testing
@testable import VeloEditCore

@Suite struct FilmProcessProfileTests {
    @Test(arguments: AIPowerMode.allCases)
    func confirmingWeightsPreservesEverySavedPolicyField(mode: AIPowerMode) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let initial = FilmProcessProfile(analysis: .resolve(mode: mode))
        var saved = try #require(try JSONSerialization.jsonObject(with: encoder.encode(initial)) as? [String: Any])
        saved.removeValue(forKey: "singleImageReviewContextTokens")
        saved["semanticSampling"] = ["temperature": 0.125, "seed": 91]
        saved["reviewFractions"] = [0.01, 0.2, 0.45, 0.7, 0.99]
        saved["boundaryFollowingSeconds"] = 5.0
        saved["recoveryBackoffSeconds"] = [12, 34, 56]
        let restored = try JSONDecoder().decode(FilmProcessProfile.self,
            from: JSONSerialization.data(withJSONObject: saved))
        let bound = try restored.bindingModelDigest("confirmed-weights")
        #expect(bound.singleImageReviewContextTokens == nil)
        #expect(bound.reviewIdentity == restored.reviewIdentity)
        var actual = try #require(try JSONSerialization.jsonObject(with: encoder.encode(bound)) as? [String: Any])
        actual.removeValue(forKey: "modelDigest")
        #expect(try JSONSerialization.data(withJSONObject: actual, options: [.sortedKeys]) ==
                JSONSerialization.data(withJSONObject: saved, options: [.sortedKeys]))
        #expect(try bound.bindingModelDigest("confirmed-weights") == bound)
        #expect(throws: FilmProcessProfileError.self) { try bound.bindingModelDigest("other-weights") }
        #expect(throws: LocalAIInferenceFailure.self) { try bound.bindingModelDigest(nil) }
        #expect(throws: LocalAIInferenceFailure.self) { try restored.bindingModelDigest("") }
    }

    @Test func sceneryClarificationCannotOverwriteHiddenOrContradictoryTaskEvidence() {
        typealias R = SelectedContentReviewer
        let task = R.SmallTaskClassification(a_reason: "Only continuous scenery is visible", b_finiteTask: false, c_confidence: 0.95)
        let original = R.SmallTaskOutcome(a_evidence: "The task ending cannot be determined here", b_location: .unclear, c_confidence: 0.5)
        let clear = R.SmallBoundaryClarification(a_endState: "Water continues flowing over rocks with no finite task visible",
            b_state: .noFiniteTask, c_confidence: 0.9)
        let resolved = R.clarifiedSmallOutcome(original, task: task, clarification: clear)
        #expect(resolved.b_location == .none && resolved.c_confidence == 0.9)
        for state in [R.SmallBoundaryClarification.State.hidden, .unfinished, .finished] {
            var observation = clear; observation.b_state = state
            #expect(R.clarifiedSmallOutcome(original, task: task, clarification: observation).b_location == .unclear)
        }
        for probability in [0.79, 1.1, Double.nan] {
            var observation = clear; observation.c_confidence = probability
            #expect(R.clarifiedSmallOutcome(original, task: task, clarification: observation).b_location == .unclear)
        }
        var finite = task; finite.b_finiteTask = true
        #expect(R.clarifiedSmallOutcome(original, task: finite, clarification: clear).b_location == .unclear)
        var doubtful = task; doubtful.c_confidence = 0.79
        #expect(R.clarifiedSmallOutcome(original, task: doubtful, clarification: clear).b_location == .unclear)
        for location in [R.SmallTaskOutcome.Location.inside, .after, .none] {
            var established = original; established.b_location = location
            #expect(R.clarifiedSmallOutcome(established, task: task, clarification: clear).b_location == location)
        }
        var labelOnly = clear; labelOnly.a_endState = "no finite task"
        #expect(R.clarifiedSmallOutcome(original, task: task, clarification: labelOnly).b_location == .unclear)
    }
    @Test func smallBoundaryCannotTurnAnUnknownResultIntoCompletion() throws {
        for (location, expected) in [("inside", "complete"), ("after", "interrupted"), ("unclear", "uncertain")] {
            let data = try JSONSerialization.data(withJSONObject: ["a_evidence": "Visible physical comparison", "b_location": location, "c_confidence": 0.95])
            let outcome = try JSONDecoder().decode(SelectedContentReviewer.SmallTaskOutcome.self, from: data)
            #expect(outcome.verdict.rawValue == expected)
        }
        #expect(SelectedContentReviewer.smallBoundaryVerdict(finite: false, location: .after) == .uncertain)
        #expect(SelectedContentReviewer.smallBoundaryVerdict(finite: false, location: .inside) == .uncertain)
        #expect(SelectedContentReviewer.smallBoundaryVerdict(finite: true, location: .none) == .uncertain)
        #expect(SelectedContentReviewer.smallBoundaryVerdict(finite: false, location: .none) == .continuous)
    }

    @Test func largerModesRetainTheirFullImageContext() {
        for mode in [AIPowerMode.balanced, .quality, .maximum] {
            let profile = FilmProcessProfile(analysis: .resolve(mode: mode))
            #expect(profile.contextTokens >= 32768)
            #expect(profile.reviewFrameCount == 5 && profile.boundaryLongEdge == 1280)
            #expect(profile.reviewLongEdge == profile.boundaryLongEdge)
        }
    }
    @Test func contextDoesNotDependOnIdenticalImagesBeingShared() {
        for mode in AIPowerMode.allCases {
            let profile = FilmProcessProfile(analysis: .resolve(mode: mode))
            let images = profile.analysis.framesPerCandidate * profile.analysis.scenesPerVLMRequest
            // Conservatively reserve per-image labels and ordinary landscape
            // visual tokens plus instructions and the complete structured reply.
            let tokens = images * 1280 + 2048
            #expect(profile.contextTokens >= tokens)
        }
    }
    @Test func savedProfileSurvivesPreferenceChangesAndChecksWeights() async throws {
        let initial = FilmProcessProfile(analysis: .resolve(mode: .fast), modelDigest: "weights-a")
        let restored = try JSONDecoder().decode(FilmProcessProfile.self, from: JSONEncoder().encode(initial))
        var preferences = UserPreferences()
        preferences.aiPowerMode = .maximum
        await FilmProcessContext.$current.withValue(restored) {
            #expect(FilmProcessContext.analysis(preferences: preferences).mode == .fast)
            #expect(FilmProcessContext.analysis(preferences: preferences).modelID == "qwen3-vl:2b-instruct")
        }
        #expect(throws: FilmProcessProfileError.self) { try restored.validate(model: restored.modelID, digest: "weights-b") }
    }

    @Test(arguments: AIPowerMode.allCases)
    func missingWeightIdentityWaitsForRecoveryInsteadOfCertifyingOrRequestingDownload(mode: AIPowerMode) throws {
        let profile = FilmProcessProfile(analysis: .resolve(mode: mode), modelDigest: "saved-weights")
        try profile.validate(model: profile.modelID)
        try profile.validate(model: profile.modelID, digest: "saved-weights")
        for missing in [nil, ""] as [String?] {
            #expect(throws: LocalAIInferenceFailure.self) {
                try profile.validate(model: profile.modelID, digest: missing)
            }
        }
        #expect(throws: FilmProcessProfileError.self) {
            try profile.validate(model: profile.modelID, digest: "different-weights")
        }
        #expect(throws: FilmProcessProfileError.self) {
            try profile.validate(model: "a-different-mode", digest: nil)
        }
    }

    @Test func savedSamplingRemovesImplicitTagRandomnessWithoutChangingEvidence() throws {
        for mode in AIPowerMode.allCases {
            let profile = FilmProcessProfile(analysis: .resolve(mode: mode))
            var legacy = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(profile)) as? [String: Any])
            legacy.removeValue(forKey: "semanticSampling")
            let restored = try JSONDecoder().decode(FilmProcessProfile.self, from: JSONSerialization.data(withJSONObject: legacy))
            #expect(restored.effectiveSemanticSampling == profile.effectiveSemanticSampling)
            #expect(restored.reviewIdentity == profile.reviewIdentity)
            try FilmProcessContext.$current.withValue(restored) {
                for options in [[String: Any](), ["temperature": 1, "seed": -1]] {
                    let body = try FilmProcessContext.requestBody(["model": profile.modelID, "options": options,
                        "messages": [["role": "user", "content": "Independent observation", "images": ["frame-a", "frame-b"]]]])
                    let sent = try #require(body["options"] as? [String: Any])
                    #expect(sent["temperature"] as? Double == 0)
                    #expect(sent["seed"] as? Int == 42)
                    #expect(sent["num_ctx"] as? Int == profile.contextTokens)
                    #expect(body["model"] as? String == profile.modelID)
                    #expect((body["messages"] as? [[String: Any]])?.first?["images"] as? [String] == ["frame-a", "frame-b"])
                }
            }
        }
    }

    @Test func transportRejectsAnotherModesModelBeforeSending() async throws {
        let client = LocalAIInferenceClient(recover: { _ in Issue.record("Must not recover a profile violation") },
            transport: { _, _, _ in Issue.record("Must not send another model's request"); throw URLError(.badServerResponse) })
        let profile = FilmProcessProfile(analysis: .resolve(mode: .fast))
        var request = URLRequest(url: URL(string: "http://127.0.0.1:1/api/chat")!)
        request.httpBody = Data(#"{"model":"qwen3-vl:30b-a3b-instruct","messages":[]}"#.utf8)
        try await FilmProcessContext.$current.withValue(profile) {
            do { _ = try await client.response(for: request); Issue.record("Wrong model accepted") }
            catch is FilmProcessProfileError {} catch { throw error }
        }
    }

    @Test func everyModePreservesItsInputAndModelDuringRecovery() async throws {
        actor Transport {
            var bodies: [Data] = []
            var recovered: [String] = []
            func send(_ request: URLRequest) throws -> (Data, URLResponse) {
                bodies.append(request.httpBody!)
                if bodies.count == 1 { throw LocalAITransportFailure.noProgress }
                return (Data(), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            func recover(_ model: String) { recovered.append(model) }
        }
        for mode in AIPowerMode.allCases {
            let profile = FilmProcessProfile(analysis: .resolve(mode: mode))
            let transport = Transport()
            let client = LocalAIInferenceClient(recover: { await transport.recover($0) }, transport: { request, _, _ in try await transport.send(request) })
            try await FilmProcessContext.$current.withValue(profile) {
                let body = try FilmProcessContext.requestBody(["model": profile.modelID,
                    "messages": [["role": "user", "content": "All evidence", "images": ["image-1", "image-2"]]],
                    "options": ["num_ctx": 8192, "num_predict": 1000]])
                var request = URLRequest(url: URL(string: "http://127.0.0.1:1/api/chat")!)
                request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
                _ = try await client.response(for: request)
                let bodies = await transport.bodies
                #expect(bodies.count == 2 && bodies[0] == bodies[1])
                #expect(await transport.recovered == [profile.modelID])
                let sent = try #require(try JSONSerialization.jsonObject(with: bodies[0]) as? [String: Any])
                #expect(sent["model"] as? String == profile.modelID)
                #expect((sent["options"] as? [String: Int])?["num_ctx"] == profile.contextTokens)
                #expect((sent["messages"] as? [[String: Any]])?.first?["images"] as? [String] == ["image-1", "image-2"])
            }
        }
    }

    @Test func sourceAndRenderedAnswersHaveSeparateProvenance() async throws {
        actor Calls {
            var count = 0
            func send(_ request: URLRequest) -> (Data, URLResponse) {
                count += 1
                return (Data(#"{"model":"fixture","done":true,"done_reason":"stop","message":{"content":"{\"observation\":\"literal evidence\"}"}}"#.utf8),
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let calls = Calls()
        var reviewer = SelectedContentReviewer(cacheURL: root, model: "fixture", answerTransport: { await calls.send($0) })
        let body: [String: Any] = ["model": "fixture", "messages": [["role": "user", "content": "Same decoded pixels"]]]
        reviewer.evidenceContext = "source-exact-interval"
        _ = try await reviewer.modelAnswer(body: body, responseURL: root.appendingPathComponent("source.json"))
        _ = try await reviewer.modelAnswer(body: body, responseURL: root.appendingPathComponent("source.json"))
        #expect(await calls.count == 1)
        reviewer.evidenceContext = "rendered-exact-interval"
        _ = try await reviewer.modelAnswer(body: body, responseURL: root.appendingPathComponent("rendered.json"))
        #expect(await calls.count == 2)
    }

    @Test func regeneratedMP4RepliesRequireExactPixelsIntervalAndWeights() async throws {
        actor Calls {
            var count = 0
            func send(_ request: URLRequest) -> (Data, URLResponse) {
                count += 1
                return (Data(#"{"model":"fixture","done":true,"done_reason":"stop","message":{"content":"{\"observation\":\"literal rendered evidence\"}"}}"#.utf8),
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let calls = Calls()
        var reviewer = SelectedContentReviewer(cacheURL: root, model: "fixture", answerTransport: { await calls.send($0) })
        reviewer.modelDigestOverride = "weights-a"
        var asset = MediaAsset(originalURL: root.appendingPathComponent("source.mov"), kind: .video,
            byteSize: 100, contentHash: "source-a", metadata: MediaMetadata())
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("stable source identity; decoded pixels are injected below".utf8).write(to: asset.originalURL)
        var item = TimelineItem(assetID: asset.id, kind: .video, sourceStart: 8, sourceDuration: 5,
            timelineStart: 0, timelineDuration: 5)
        var times = [0.1, 1.25, 2.5, 3.75, 4.9]
        let profile = FilmProcessProfile(analysis: .resolve(mode: .fast))
        let originalScope = SelectedContentReviewer.renderedResponseContext(asset: asset, item: item, times: times, profile: profile)
        reviewer.evidenceContext = originalScope
        func body(_ pixels: String) -> [String: Any] {
            ["model": "fixture", "messages": [["role": "user", "content": "Inspect this rendered image", "images": [pixels]]]]
        }
        _ = try await reviewer.modelAnswer(body: body("decoded-mp4-pixels"), responseURL: root.appendingPathComponent("export-a.json"))
        item.id = UUID()
        reviewer.evidenceContext = SelectedContentReviewer.renderedResponseContext(asset: asset, item: item, times: times, profile: profile)
        _ = try await reviewer.modelAnswer(body: body("decoded-mp4-pixels"), responseURL: root.appendingPathComponent("export-b.json"))
        #expect(await calls.count == 1)
        _ = try await reviewer.modelAnswer(body: body("different-decoded-pixels"), responseURL: root.appendingPathComponent("export-c.json"))
        #expect(await calls.count == 2)
        times[0] += 0.01
        reviewer.evidenceContext = SelectedContentReviewer.renderedResponseContext(asset: asset, item: item, times: times, profile: profile)
        _ = try await reviewer.modelAnswer(body: body("decoded-mp4-pixels"), responseURL: root.appendingPathComponent("export-d.json"))
        #expect(await calls.count == 3)
        item.sourceStart += 1
        reviewer.evidenceContext = SelectedContentReviewer.renderedResponseContext(asset: asset, item: item, times: times, profile: profile)
        _ = try await reviewer.modelAnswer(body: body("decoded-mp4-pixels"), responseURL: root.appendingPathComponent("export-e.json"))
        #expect(await calls.count == 4)
        asset.contentHash = "different-source"
        reviewer.evidenceContext = SelectedContentReviewer.renderedResponseContext(asset: asset, item: item, times: times, profile: profile)
        _ = try await reviewer.modelAnswer(body: body("decoded-mp4-pixels"), responseURL: root.appendingPathComponent("export-f.json"))
        #expect(await calls.count == 5)
        reviewer.evidenceContext = originalScope
        reviewer.modelDigestOverride = "weights-b"
        _ = try await reviewer.modelAnswer(body: body("decoded-mp4-pixels"), responseURL: root.appendingPathComponent("export-g.json"))
        #expect(await calls.count == 6)
    }
}
