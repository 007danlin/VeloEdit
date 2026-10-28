import Foundation
import Testing
import CryptoKit
import Darwin
@testable import VeloEditCore

private final class InferenceStubState: @unchecked Sendable {
    enum Mode { case silent, emptyKeepAlives, partialStall, complete, delayedComplete, thinking, endlessThinking, truncated, wrongModel, loopingDescription }
    let lock = NSLock()
    var mode: Mode
    var calls = 0
    var stops = 0
    var bodies: [Data] = []
    var recoveries = 0
    init(_ mode: Mode) { self.mode = mode }
    func recover(to mode: Mode) { lock.withLock { recoveries += 1; self.mode = mode } }
    var counts: (calls: Int, stops: Int, recoveries: Int) { lock.withLock { (calls, stops, recoveries) } }
}

private actor InferenceTestGate {
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        released = true
        continuation?.resume(); continuation = nil
    }
}

private actor InferenceWeightSequence {
    let after: String?
    var reads = 0
    var requests = 0
    init(after: String?) { self.after = after }
    func digest() -> String? {
        reads += 1
        return reads == 1 ? "saved-weights" : after
    }
    func received() { requests += 1 }
}

private final class InferenceStubProtocol: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    static var states: [String: InferenceStubState] = [:]
    private let stoppedLock = NSLock()
    private var stopped = false
    private var state: InferenceStubState?
    override class func canInit(with request: URLRequest) -> Bool { request.value(forHTTPHeaderField: "X-Inference-Test") != nil }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let id = request.value(forHTTPHeaderField: "X-Inference-Test"), let state = Self.lock.withLock({ Self.states[id] }) else { return }
        self.state = state
        var wireBody = request.httpBody ?? Data()
        if wireBody.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                wireBody.append(contentsOf: buffer.prefix(count))
            }
        }
        let mode = state.lock.withLock { () -> InferenceStubState.Mode in
            state.calls += 1; state.bodies.append(wireBody); return state.mode
        }
        if mode == .silent { return }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200,
            httpVersion: nil, headerFields: ["Content-Type": "application/x-ndjson"])!, cacheStoragePolicy: .notAllowed)
        func event(_ content: String, thinking: String = "", done: Bool = false, model: String = "fixture") -> Data {
            let data = try! JSONSerialization.data(withJSONObject: ["model": model, "done": done,
                "done_reason": done ? "stop" : "", "message": ["role": "assistant", "content": content, "thinking": thinking]])
            return data + Data([10])
        }
        switch mode {
        case .silent: break
        case .emptyKeepAlives:
            for i in 0..<15 { emit(event(""), after: Double(i) * 0.025) }
        case .partialStall: emit(event("{\"ok\":"), after: 0)
        case .complete:
            emit(event("{\"ok\":"), after: 0)
            emit(event("true}"), after: 0.04)
            // Deliberately never close the HTTP connection after a valid done.
            emit(event("", done: true), after: 0.08)
        case .delayedComplete:
            emit(event("{\"ok\":true}", done: true), after: 0.36)
        case .thinking:
            for i in 0..<6 { emit(event("", thinking: "step "), after: Double(i) * 0.04) }
            emit(event("{\"ok\":true}", done: true), after: 0.26)
        case .endlessThinking:
            for i in 0..<100 { emit(event("", thinking: "step "), after: Double(i) * 0.025) }
        case .truncated:
            emit(event("{\"ok\":"), after: 0)
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.03) { [self] in
                if !stoppedLock.withLock({ stopped }) { client?.urlProtocolDidFinishLoading(self) }
            }
        case .wrongModel: emit(event("{\"ok\":true}", done: true, model: "weaker-substitute"), after: 0)
        case .loopingDescription:
            emit(event("{\"scenes\":[{\"reason\":\""), after: 0)
            for i in 1...30 {
                emit(event("The scene is not a story, but a single unchanged moment captured in time. "), after: Double(i) * 0.01)
            }
        }
    }
    private func emit(_ data: Data, after delay: Double) {
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [self] in
            if !stoppedLock.withLock({ stopped }) { client?.urlProtocol(self, didLoad: data) }
        }
    }
    override func stopLoading() {
        stoppedLock.withLock { stopped = true }
        state?.lock.withLock { state?.stops += 1 }
    }
}

struct LocalAIInferenceRecoveryTests {
    private var limits: LocalAIInferenceLimits { .init(firstToken: 0.13, tokenIdle: 0.11, total: 1, polling: 0.01) }
    private func fixture(_ mode: InferenceStubState.Mode) throws -> (URLRequest, URLSessionConfiguration, InferenceStubState) {
        let state = InferenceStubState(mode), id = UUID().uuidString
        InferenceStubProtocol.lock.withLock { InferenceStubProtocol.states[id] = state }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:11435/api/chat")!)
        request.httpMethod = "POST"; request.setValue(id, forHTTPHeaderField: "X-Inference-Test")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model": "fixture", "stream": true,
            "messages": [["role": "user", "content": "same evidence", "images": ["same-frame"]]],
            "options": ["num_ctx": 8192, "num_predict": 320]])
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [InferenceStubProtocol.self]
        return (request, configuration, state)
    }
    private func client(_ configuration: URLSessionConfiguration, _ state: InferenceStubState,
                        repairedMode: InferenceStubState.Mode) -> LocalAIInferenceClient {
        LocalAIInferenceClient(recover: { _ in state.recover(to: repairedMode) }, transport: { request, limits, progress in
            try await LocalAIStreamingRequest(request: request, limits: limits, progress: progress, configuration: configuration).run()
        })
    }

    private func awaitTransportCleanup(_ state: InferenceStubState) async throws {
        // URLSession dispatches stopLoading asynchronously after task.cancel().
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        while state.counts.stops == 0 && ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test func realPrefillProgressCanOutliveFirstResponseDeadline() async throws {
        let (request, config, _) = try fixture(.delayedComplete)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data().write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let witness = try #require(LocalAIBackendProgress(url: url))
        let writer = Task {
            let file = try FileHandle(forWritingTo: url)
            defer { try? file.close() }
            for i in 1...4 {
                try await Task.sleep(for: .milliseconds(70))
                try file.write(contentsOf: Data("slot print_timing: id 0 | task 0 | prompt processing, n_tokens = \(i * 100), progress = 0.\(i)\n".utf8))
            }
        }
        defer { writer.cancel() }
        let (data, _) = try await LocalAIStreamingRequest(request: request, limits: limits,
            configuration: config, backendProgress: witness).run()
        #expect(String(decoding: data, as: UTF8.self).contains("true"))
        try await writer.value
    }

    @Test(arguments: [false, true]) func backendWorkCannotExtendTotalOrGeneratedTokenIdle(generationStarted: Bool) async throws {
        let (request, config, _) = try fixture(generationStarted ? .partialStall : .silent)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data().write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let witness = try #require(LocalAIBackendProgress(url: url))
        let writer = Task {
            let file = try FileHandle(forWritingTo: url)
            defer { try? file.close() }
            for i in 1...30 {
                try await Task.sleep(for: .milliseconds(25))
                try file.write(contentsOf: Data("slot print_timing: id 0 | task 0 | prompt processing, n_tokens = \(i * 100), progress = 0.5\n".utf8))
            }
        }
        defer { writer.cancel() }
        let bounded = LocalAIInferenceLimits(firstToken: 0.13, tokenIdle: 0.11, total: 0.23, polling: 0.01)
        await #expect(throws: generationStarted ? LocalAITransportFailure.noProgress : .totalBudget) {
            _ = try await LocalAIStreamingRequest(request: request, limits: bounded,
                configuration: config, backendProgress: witness).run()
        }
    }

    @Test func descriptionLoopReturnsIncompleteEvidenceWithoutRestartingTheModel() async throws {
        var (request, config, state) = try fixture(.loopingDescription)
        var body = try #require(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
        body["format"] = ["type": "object", "properties": ["scenes": ["type": "array"]]]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await client(config, state, repairedMode: .complete).response(for: request, limits: limits)
        let result = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(result["done"] as? Bool == false)
        #expect(result["done_reason"] as? String == "repetition_guard")
        var parser = OllamaVisionStream(expectedModel: "fixture")
        try parser.append(String(decoding: data, as: UTF8.self))
        #expect(throws: (any Error).self) { _ = try parser.completedContent() }
        try await awaitTransportCleanup(state)
        #expect(state.counts.calls == 1 && state.counts.recoveries == 0 && state.counts.stops == 1)
    }

    @Test func sameObservationInSeparateScenesIsNotAGenerationLoop() throws {
        let description = "A person is fishing beside the river with a rod in their hands. "
        let scene = ["scene": description, "reason": description]
        let data = try JSONSerialization.data(withJSONObject: ["scenes": Array(repeating: scene, count: 20)])
        var detector = SceneDescriptionLoopGuard()
        for byte in data {
            let loop = detector.append(String(decoding: [byte], as: UTF8.self))
            #expect(!loop)
        }
        var repeated = SceneDescriptionLoopGuard()
        let detected = repeated.append("{\"reason\":\"" + String(repeating: description, count: 8))
        #expect(detected)
    }

    @Test func silenceAndEmptyKeepAlivesCannotExtendTheWatchdog() async throws {
        for mode in [InferenceStubState.Mode.silent, .emptyKeepAlives, .partialStall] {
            let (request, config, state) = try fixture(mode)
            let started = ProcessInfo.processInfo.systemUptime
            await #expect(throws: LocalAITransportFailure.self) {
                _ = try await LocalAIStreamingRequest(request: request, limits: limits, configuration: config).run()
            }
            #expect(ProcessInfo.processInfo.systemUptime - started < 1)
            try await awaitTransportCleanup(state)
            #expect(state.counts.stops == 1)
        }
    }
    @Test func reasoningIsProgressAndCompletedStreamDoesNotWaitForSocketClose() async throws {
        for mode in [InferenceStubState.Mode.thinking, .complete] {
            let (request, config, state) = try fixture(mode)
            let (data, _) = try await LocalAIStreamingRequest(request: request, limits: limits, configuration: config).run()
            let value = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect((value["message"] as? [String: Any])?["content"] as? String == #"{"ok":true}"#)
            #expect(value["done"] as? Bool == true)
            try await awaitTransportCleanup(state)
            #expect(state.counts.stops == 1)
        }
    }
    @Test func continuousReasoningCannotExceedTheTotalAttemptBudget() async throws {
        let (request, config, _) = try fixture(.endlessThinking)
        var bounded = limits; bounded.total = 0.3
        let started = ProcessInfo.processInfo.systemUptime
        await #expect(throws: LocalAITransportFailure.totalBudget) {
            _ = try await LocalAIStreamingRequest(request: request, limits: bounded, configuration: config).run()
        }
        #expect(ProcessInfo.processInfo.systemUptime - started < 0.8)
    }
    @Test func truncatedAndWrongModelRepliesNeverBecomeEvidence() async throws {
        for mode in [InferenceStubState.Mode.truncated, .wrongModel] {
            let (request, config, _) = try fixture(mode)
            await #expect(throws: (any Error).self) {
                _ = try await LocalAIStreamingRequest(request: request, limits: limits, configuration: config).run()
            }
        }
    }
    @Test func stalledRequestRestartsOnceAndRepeatsExactlyTheSameInputs() async throws {
        let (request, config, state) = try fixture(.partialStall)
        let (data, _) = try await client(config, state, repairedMode: .complete).response(for: request, limits: limits)
        #expect(state.counts.calls == 2 && state.counts.recoveries == 1)
        let bodies = state.lock.withLock { state.bodies }
        #expect(bodies.count == 2 && !bodies[0].isEmpty && bodies[0] == bodies[1])
        #expect(String(decoding: data, as: UTF8.self).contains("true"))
    }
    @Test func repeatedStallYieldsDurableWaitInsteadOfMovingToOtherShots() async throws {
        let (request, config, state) = try fixture(.silent)
        await #expect(throws: LocalAIInferenceFailure.self) {
            _ = try await client(config, state, repairedMode: .silent).response(for: request, limits: limits)
        }
        #expect(state.counts.calls == 2 && state.counts.recoveries == 1)
    }
    @Test func userCancellationDoesNotRestartTheModel() async throws {
        let (request, config, state) = try fixture(.silent)
        let client = client(config, state, repairedMode: .complete)
        let task = Task { try await client.response(for: request, limits: limits) }
        try await Task.sleep(for: .milliseconds(30)); task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        try await awaitTransportCleanup(state)
        #expect(state.counts.calls == 1 && state.counts.recoveries == 0 && state.counts.stops == 1)
    }
    @Test func cancelledQueuedRequestCannotInterruptTheActiveOne() async throws {
        let (request, config, state) = try fixture(.thinking)
        let client = client(config, state, repairedMode: .complete)
        let first = Task { try await client.response(for: request, limits: limits) }
        try await Task.sleep(for: .milliseconds(30))
        let queued = Task { try await client.response(for: request, limits: limits) }
        try await Task.sleep(for: .milliseconds(20)); queued.cancel()
        await #expect(throws: CancellationError.self) { _ = try await queued.value }
        _ = try await first.value
        #expect(state.counts.calls == 1 && state.counts.recoveries == 0)
    }
    @Test func automaticWaitSurvivesReopenAndDoesNotExhaustTheGenericRetryLimit() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ProjectStore(createAt: root, name: "Model recovery")
        _ = try await store.beginAutonomousJob(kind: .film)
        _ = try await store.beginFilmBuildRecovery(.init(kind: .create, prompt: "Same film", preset: .story))
        try await store.updateAutonomousJob { $0.maximumRecoveries = 0 }
        for _ in 0..<10 {
            try await store.waitForLocalInference(.init(model: "original-model", reason: "test"), now: .distantPast)
            #expect(try await store.activateAfterExternalWait())
            #expect(await store.manifest.autonomousJob?.state == .queued)
        }
        try await store.waitForLocalInference(.init(model: "original-model", reason: "test"))
        #expect(!(try await store.activateAfterExternalWait()))
        try await store.prepareAutonomousJobForRestart()
        let reopened = try ProjectStore(open: root)
        #expect(await reopened.manifest.autonomousJob?.state == .waitingForExternalResource)
        #expect(await reopened.manifest.autonomousJob?.inferenceRetryModel == "original-model")
        #expect(await reopened.recoverableFilmBuild()?.request.prompt == "Same film")
        try await reopened.recordInferenceProgress()
        #expect(await reopened.manifest.autonomousJob?.inferenceRecoveryCount == nil)
        try await reopened.cancelAutonomousJob()
        #expect(!(try await reopened.activateAfterExternalWait()))
    }

    @Test func scheduledRecoveryWaitsForActiveInferenceAndCanBeCancelledInTheQueue() async throws {
        for cancelRecovery in [false, true] {
            let (request, _, state) = try fixture(.complete)
            let gate = InferenceTestGate()
            let client = LocalAIInferenceClient(recover: { _ in state.recover(to: .complete) }, transport: { request, _, _ in
                state.lock.withLock { state.calls += 1 }
                await gate.wait()
                return (Data(), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            })
            let first = Task { try await client.response(for: request, limits: limits) }
            let deadline = ProcessInfo.processInfo.systemUptime + 1
            while state.counts.calls == 0 && ProcessInfo.processInfo.systemUptime < deadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            #expect(state.counts.calls == 1)
            let recovery = Task { try await client.recoverService(model: "fixture") }
            try await Task.sleep(for: .milliseconds(20))
            #expect(state.counts.recoveries == 0)
            if cancelRecovery {
                recovery.cancel()
                await #expect(throws: CancellationError.self) { try await recovery.value }
                await gate.release()
            } else {
                await gate.release()
                try await recovery.value
            }
            _ = try await first.value
            #expect(state.counts.calls == 1)
            #expect(state.counts.recoveries == (cancelRecovery ? 0 : 1))
        }
    }

    @Test func prefillAllowancePreservesEveryModesOriginalBudgetAndAllFrames() throws {
        for mode in AIPowerMode.allCases {
            let profile = AIAnalysisProfile.resolve(mode: mode, advanced: .init())
            var request = URLRequest(url: URL(string: "http://127.0.0.1:11435/api/chat")!)
            request.timeoutInterval = profile.vlmPrefillTimeout(imageCount: profile.framesPerCandidate)
            request.httpBody = try JSONSerialization.data(withJSONObject: ["model": profile.ollamaModelID,
                "messages": [["images": Array(repeating: "frame", count: profile.framesPerCandidate)]]])
            let limits = try LocalAIInferenceLimits.resolve(request: request)
            #expect(limits.firstToken >= request.timeoutInterval)
            #expect(limits.total >= request.timeoutInterval + 600)
        }
    }

    @Test(arguments: AIPowerMode.allCases)
    func answersCannotEscapeWhenWeightsBecomeUnknownOrChangeDuringInference(mode: AIPowerMode) async throws {
        let profile = FilmProcessProfile(analysis: .resolve(mode: mode), modelDigest: "saved-weights")
        for after in [nil, "different-weights", "saved-weights"] as [String?] {
            let state = InferenceWeightSequence(after: after)
            let client = LocalAIInferenceClient(recover: { _ in Issue.record("No transport failure to recover") },
                modelDigest: { _ in await state.digest() }, transport: { request, _, _ in
                    await state.received()
                    return (Data(#"{"done":true,"message":{"content":"{}"}}"#.utf8),
                        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
                })
            var request = URLRequest(url: URL(string: "http://127.0.0.1:11435/api/chat")!)
            request.httpBody = try JSONSerialization.data(withJSONObject: ["model": profile.modelID])
            try await FilmProcessContext.$current.withValue(profile) {
                if after == nil {
                    await #expect(throws: LocalAIInferenceFailure.self) { _ = try await client.response(for: request) }
                } else if after != "saved-weights" {
                    await #expect(throws: FilmProcessProfileError.self) { _ = try await client.response(for: request) }
                } else {
                    _ = try await client.response(for: request)
                }
            }
            #expect(await state.reads == 2)
            #expect(await state.requests == 1)
        }
    }
    @Test func resumeReusesOldCompleteRepliesAndRepeatsOnlyTheInterruptedObservation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (request, config, state) = try fixture(.partialStall)
        var body = try #require(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
        body["stream"] = false; body["keep_alive"] = "10m"
        // Legacy transport can be reused only when the actual model input
        // (including image labels) matches the current observation exactly.
        body = LocalVisionMessageEncoding.separatingImages(in: body)
        let legacy = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        // A genuine older observation remains reusable after the aggregate
        // verdict rules change. Its old certificate is not reused.
        let legacyObservationVersion = "selected-content-v72-probability-scale-recovery"
        #expect(SelectedContentReviewer.version != legacyObservationVersion)
        let digest = SHA256.hash(data: Data((legacyObservationVersion + "|exact-request|fixture-digest").utf8) + legacy).map { String(format: "%02x", $0) }.joined()
        let cache = root.appendingPathComponent("ByExactRequestV3")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try legacy.write(to: cache.appendingPathComponent(digest + ".request.json"))
        let answer = Data(#"{"model":"fixture","done":true,"done_reason":"stop","message":{"content":"{\"ok\":true}"}}"#.utf8)
        try answer.write(to: cache.appendingPathComponent(digest + ".json"))
        let client = LocalAIInferenceClient(recover: { _ in state.recover(to: .complete) }, transport: { wire, _, progress in
            var wire = wire
            wire.setValue(request.value(forHTTPHeaderField: "X-Inference-Test"), forHTTPHeaderField: "X-Inference-Test")
            return try await LocalAIStreamingRequest(request: wire, limits: limits, progress: progress, configuration: config).run()
        })
        let reviewer = SelectedContentReviewer(cacheURL: root, model: "fixture", inferenceClient: client, modelDigestOverride: "fixture-digest")
        #expect(try await reviewer.modelAnswer(body: body, responseURL: root.appendingPathComponent("old.json")) == #"{"ok":true}"#)
        #expect(state.counts.calls == 0)
        #expect(try Data(contentsOf: root.appendingPathComponent("old.request.json")) == legacy)
        body["messages"] = [["role": "user", "content": "next independent observation", "images": ["same-frame"]]]
        #expect(try await reviewer.modelAnswer(body: body, responseURL: root.appendingPathComponent("new.json")) == #"{"ok":true}"#)
        #expect(state.counts.calls == 2 && state.counts.recoveries == 1)
        let reopened = SelectedContentReviewer(cacheURL: root, model: "fixture", inferenceClient: client, modelDigestOverride: "fixture-digest")
        _ = try await reopened.modelAnswer(body: body, responseURL: root.appendingPathComponent("resumed.json"))
        #expect(state.counts.calls == 2)
        let sent = state.lock.withLock { state.bodies }
        #expect(sent.count == 2 && !sent[0].isEmpty && sent[0] == sent[1])
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["VELOEDIT_LIVE_RECOVERY_RUNTIME"] != nil))
    func liveOwnedRuntimeRestartsWithoutTouchingForeignServiceOrModelWeights() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["VELOEDIT_LIVE_RECOVERY_RUNTIME"])
        let url = URL(string: "http://127.0.0.1:11436")!
        let manager = LocalAIModelManager(baseURL: url, executable: URL(fileURLWithPath: path))
        do {
            try await manager.ensureService()
            let oldPID = try #require(await manager.ownedProcessIdentifier)
            let digest = try #require(await manager.installedModelDigest(model: "qwen3-vl:2b-instruct"))
            var request = URLRequest(url: url.appendingPathComponent("api/chat")); request.httpMethod = "POST"
            request.httpBody = try JSONSerialization.data(withJSONObject: ["model": "qwen3-vl:2b-instruct", "stream": true,
                "think": false, "format": "json", "options": ["temperature": 0, "num_predict": 80],
                "messages": [["role": "user", "content": "Return exactly the JSON object {\"ok\":true}."]]])
            let limits = LocalAIInferenceLimits(firstToken: 120, tokenIdle: 60, total: 240)
            _ = try await LocalAIStreamingRequest(request: request, limits: limits).run()
            let unowned = LocalAIModelManager(baseURL: url, executable: URL(fileURLWithPath: path))
            try await unowned.recoverOwnedService(model: "qwen3-vl:2b-instruct")
            await unowned.shutdownOwnedService()
            #expect(kill(oldPID, 0) == 0)
            let state = InferenceStubState(.silent)
            let client = LocalAIInferenceClient(recover: { model in
                state.recover(to: .complete)
                try await manager.recoverOwnedService(model: model)
            }, transport: { request, limits, progress in
                let fail = state.lock.withLock { state.calls += 1; return state.calls == 1 }
                if fail { throw LocalAITransportFailure.noProgress }
                return try await LocalAIStreamingRequest(request: request, limits: limits, progress: progress).run()
            })
            let (data, _) = try await client.response(for: request, limits: limits)
            let value = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(value["done"] as? Bool == true && value["done_reason"] as? String == "stop")
            #expect(await manager.ownedProcessIdentifier != oldPID)
            #expect(kill(oldPID, 0) != 0)
            #expect(await manager.installedModelDigest(model: "qwen3-vl:2b-instruct") == digest)
            #expect(state.counts.calls == 2 && state.counts.recoveries == 1)
            print("LIVE OWNED RECOVERY: original model digest preserved; only owned server replaced; completed same request")
            await manager.shutdownOwnedService()
        } catch {
            await manager.shutdownOwnedService()
            throw error
        }
    }

}
