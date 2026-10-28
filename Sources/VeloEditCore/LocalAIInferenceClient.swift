import Foundation

/// Exhausted immediate recovery is a resumable dependency wait, never evidence.
public struct LocalAIInferenceFailure: LocalizedError, Sendable {
    public let model: String
    public let reason: String
    public var errorDescription: String? {
        "Модель \(model) пока не отвечает: \(reason). Сохранённые результаты остаются в проекте; сборка продолжится автоматически."
    }
}

enum LocalAITransportFailure: Error, Sendable, Equatable {
    case noProgress, totalBudget, interrupted, startup
}

/// Detect a generation loop inside ONE JSON string, not repeated observations
/// in separate scene objects. This never supplies a shortened successful answer.
struct SceneDescriptionLoopGuard {
    private var insideString = false
    private var escaped = false
    private var bytes: [UInt8] = []
    private var lastInspection = 0

    mutating func append(_ text: String) -> Bool {
        for byte in text.utf8 {
            if !insideString {
                if byte == 34 { insideString = true; bytes.removeAll(keepingCapacity: true); lastInspection = 0 }
                continue
            }
            if escaped { escaped = false; bytes.append(byte) }
            else if byte == 92 { escaped = true; bytes.append(byte) }
            else if byte == 34 { insideString = false; continue }
            else { bytes.append(byte) }
            guard bytes.count >= 256, bytes.count - lastInspection >= 32 else { continue }
            lastInspection = bytes.count
            let end = bytes.count
            for width in 24...min(512, end / 4) {
                let pattern = bytes[(end - width)..<end]
                guard (1...3).allSatisfy({ copy in
                    bytes[(end - (copy + 1) * width)..<(end - copy * width)].elementsEqual(pattern)
                }), String(decoding: pattern, as: UTF8.self).unicodeScalars.filter({ CharacterSet.letters.contains($0) }).count >= 16 else { continue }
                return true
            }
        }
        return false
    }
}

struct LocalAIInferenceLimits: Sendable {
    var firstToken: TimeInterval
    var tokenIdle: TimeInterval
    var total: TimeInterval
    var polling: TimeInterval = 0.5

    static func resolve(request: URLRequest) throws -> Self {
        guard let data = request.httpBody,
              let body = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let model = body["model"] as? String else { throw URLError(.cannotParseResponse) }
        let images = (body["messages"] as? [[String: Any]] ?? []).reduce(0) { $0 + (($1["images"] as? [String])?.count ?? 0) }
        let floor: Double = model.contains("30b") ? 240 : model.contains("8b") ? 180 : 120
        // Prefill emits no tokens. Preserve the caller's allowance and account
        // for all attached images; healthy large-model prefill is not a stall.
        let first = max(request.timeoutInterval, floor, images == 0 ? 0 : 60 + Double(images) * 20)
        return Self(firstToken: first, tokenIdle: FilmProcessContext.current?.tokenIdleSeconds ?? 60, total: first + 600)
    }
}

/// Serialises model work, including its recovery. Waiting in this queue does
/// not consume a model deadline and cannot restart another in-flight request.
public actor LocalAIInferenceClient {
    public static let shared = LocalAIInferenceClient()
    typealias Recovery = @Sendable (String) async throws -> Void
    typealias Transport = @Sendable (URLRequest, LocalAIInferenceLimits, FilmBuildProgressHandler?) async throws -> (Data, URLResponse)
    private let recover: Recovery
    private let transport: Transport
    private let modelDigest: @Sendable (String) async -> String?
    private var active = false
    private var waiting: [(UUID, CheckedContinuation<Void, Error>)] = []

    public init() {
        recover = { model in try await LocalAIModelManager.shared.recoverOwnedService(model: model) }
        modelDigest = { model in await LocalAIModelManager.shared.installedModelDigest(model: model) }
        transport = { request, limits, progress in
            let witness = await LocalAIModelManager.shared.inferenceProgressWitness()
            return try await LocalAIStreamingRequest(request: request, limits: limits, progress: progress,
                backendProgress: witness).run()
        }
    }
    init(recover: @escaping Recovery,
         modelDigest: @escaping @Sendable (String) async -> String? = { model in
             await LocalAIModelManager.shared.installedModelDigest(model: model)
         }, transport: @escaping Transport) {
        self.recover = recover; self.transport = transport; self.modelDigest = modelDigest
    }

    /// A scheduled recovery shares the same queue as foreground inference.
    /// It must not restart the service while a director reply is in flight.
    func recoverService(model: String) async throws {
        try await acquire()
        defer { release() }
        try Task.checkCancellation()
        try await recover(model)
    }

    public func response(for request: URLRequest, progress: FilmBuildProgressHandler? = nil,
                         maximumDuration: TimeInterval? = nil,
                         preservingRequestBody: Bool = false) async throws -> (Data, URLResponse) {
        try await response(for: request, limits: LocalAIInferenceLimits.resolve(request: request),
                           progress: progress, maximumDuration: maximumDuration,
                           preservingRequestBody: preservingRequestBody)
    }

    func response(for request: URLRequest, limits: LocalAIInferenceLimits,
                  progress: FilmBuildProgressHandler? = nil, maximumDuration: TimeInterval? = nil,
                  preservingRequestBody: Bool = false) async throws -> (Data, URLResponse) {
        let queuedAt = ProcessInfo.processInfo.systemUptime
        if active { await progress?(FilmBuildProgress(.verifying, detail: "Ожидаю освобождения локальной модели", isHeartbeat: true)) }
        try await acquire()
        defer { release() }
        try Task.checkCancellation()
        guard let data = request.httpBody,
              var body = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let model = body["model"] as? String else { throw URLError(.cannotParseResponse) }
        try FilmProcessContext.current?.validate(model: model)
        let trace = PerformanceTrace.current
        let requestID = UUID().uuidString
        let imageCount = (body["messages"] as? [[String: Any]] ?? []).reduce(0) { $0 + (($1["images"] as? [String])?.count ?? 0) }
        var requestDimensions: [String: Double] = ["images": Double(imageCount)]
        if let options = body["options"] as? [String: Any] {
            requestDimensions["contextTokens"] = (options["num_ctx"] as? Int).map(Double.init)
            requestDimensions["outputTokenLimit"] = (options["num_predict"] as? Int).map(Double.init)
        }
        trace?.event("inference.queued", fields: ["request": requestID, "model": model], values: ["seconds": ProcessInfo.processInfo.systemUptime - queuedAt])
        var streamed = request
        if preservingRequestBody {
            guard body["stream"] as? Bool == true else { throw URLError(.cannotParseResponse) }
        } else {
            body["stream"] = true
            streamed.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        }
        // Exact review receipts opt in to preserving their streaming bytes.
        // Other callers retain their prior canonical order, including director
        // advice/commands encoded with an otherwise unordered JSONEncoder.
        let end = ProcessInfo.processInfo.systemUptime + (maximumDuration ?? limits.total * 2 + 15)
        for attempt in 0..<(1 + (FilmProcessContext.current?.immediateTransportRetries ?? 1)) {
            try Task.checkCancellation()
            try await validateCurrentWeights(model: model)
            var bounded = limits
            bounded.total = min(limits.total, end - ProcessInfo.processInfo.systemUptime)
            bounded.firstToken = min(limits.firstToken, bounded.total)
            guard bounded.total > 0 else { throw LocalAIInferenceFailure(model: model, reason: "исчерпано время текущей попытки") }
            do {
                let started = ProcessInfo.processInfo.systemUptime
                trace?.resources("inference.begin", fields: ["request": requestID, "model": model, "attempt": String(attempt)],
                    values: requestDimensions)
                let result = try await transport(streamed, bounded, progress)
                // A tag can be replaced while an observation is in flight.
                // Do not return an answer to a cache under the earlier digest.
                try await validateCurrentWeights(model: model)
                var metrics = requestDimensions
                metrics["wallSeconds"] = ProcessInfo.processInfo.systemUptime - started
                let envelope = (try? JSONSerialization.jsonObject(with: result.0)) as? [String: Any]
                if envelope?["done_reason"] as? String == "repetition_guard" {
                    trace?.event("inference.repetition-stopped", fields: ["request": requestID, "model": model])
                    await progress?(FilmBuildProgress(.verifying, detail: "Ответ модели зациклился; уточняю запрос той же модели"))
                }
                for key in ["total_duration", "load_duration", "prompt_eval_duration", "eval_duration"] {
                    if let value = envelope?[key] as? Double { metrics[key + "Seconds"] = value / 1_000_000_000 }
                }
                for key in ["prompt_eval_count", "prompt_eval_cached_count", "eval_count"] {
                    if let value = envelope?[key] as? Double { metrics[key] = value }
                }
                trace?.resources("inference.end", fields: ["request": requestID, "model": model,
                    "actualModel": envelope?["model"] as? String ?? "unknown", "attempt": String(attempt),
                    "doneReason": envelope?["done_reason"] as? String ?? "unknown"], values: metrics)
                return result
            } catch {
                if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled { throw CancellationError() }
                let code = (error as? URLError)?.code
                guard error is LocalAITransportFailure || [.timedOut, .networkConnectionLost, .cannotConnectToHost].contains(code) else { throw error }
                PerformanceTrace.current?.event("inference.recovery", fields: ["model": model, "attempt": String(attempt + 1), "reason": String(describing: error)])
                guard attempt == 0 else {
                    throw LocalAIInferenceFailure(model: model, reason: "нет полного ответа после восстановления")
                }
                await progress?(FilmBuildProgress(.verifying, detail: "Восстанавливаю модель; подтверждённые проверки сохранены"))
                do { try await recover(model) }
                catch {
                    if Task.isCancelled || error is CancellationError { throw CancellationError() }
                    throw LocalAIInferenceFailure(model: model, reason: error.localizedDescription)
                }
                try Task.checkCancellation()
                await progress?(FilmBuildProgress(.verifying, detail: "Продолжаю незавершённую проверку той же моделью"))
            }
        }
        throw LocalAIInferenceFailure(model: model, reason: "восстановление не завершено")
    }

    private func validateCurrentWeights(model: String) async throws {
        guard let profile = FilmProcessContext.current, profile.modelDigest != nil else { return }
        try profile.validate(model: model, digest: await modelDigest(model))
    }

    private func acquire() async throws {
        try Task.checkCancellation()
        if !active { active = true; return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else { waiting.append((id, continuation)) }
            }
        } onCancel: { Task { await self.cancelWait(id) } }
    }
    private func cancelWait(_ id: UUID) {
        guard let index = waiting.firstIndex(where: { $0.0 == id }) else { return }
        waiting.remove(at: index).1.resume(throwing: CancellationError())
    }
    private func release() {
        if waiting.isEmpty { active = false }
        else { waiting.removeFirst().1.resume() }
    }
}

/// Delegate cancellation completes the continuation directly. A stuck socket
/// or a non-cooperative stream reader cannot keep a structured task group alive.
final class LocalAIStreamingRequest: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let request: URLRequest
    private let limits: LocalAIInferenceLimits
    private let progress: FilmBuildProgressHandler?
    private let configuration: URLSessionConfiguration
    private let backendProgress: LocalAIBackendProgress?
    private let trace = PerformanceTrace.current
    private let expectedModel: String
    private let guardsSceneDescriptions: Bool
    private var descriptionLoop = SceneDescriptionLoopGuard()
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var timer: DispatchSourceTimer?
    private var continuation: CheckedContinuation<(Data, URLResponse), Error>?
    private var finished = false
    private var response: HTTPURLResponse?
    private var pending = Data()
    private var content = ""
    private var thinking = ""
    private var generated = ""
    private var message: [String: Any] = [:]
    private var toolCalls: [[String: Any]] = []
    private var started: TimeInterval = 0
    private var lastToken: TimeInterval?
    private var lastBackendProgress: TimeInterval?
    private var backendUpdate: LocalAIBackendProgress.Update?
    private var lastUI: TimeInterval = 0
    private var tokenEvents = 0
    private var receivedBytes = 0
    private var finalEvent: [String: Any]?

    init(request: URLRequest, limits: LocalAIInferenceLimits, progress: FilmBuildProgressHandler? = nil,
         configuration: URLSessionConfiguration = .ephemeral, backendProgress: LocalAIBackendProgress? = nil) throws {
        self.request = request; self.limits = limits; self.progress = progress; self.configuration = configuration
        self.backendProgress = backendProgress
        guard let data = request.httpBody,
              let body = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let model = body["model"] as? String else { throw URLError(.cannotParseResponse) }
        expectedModel = model
        let schema = body["format"] as? [String: Any]
        guardsSceneDescriptions = (schema?["properties"] as? [String: Any])?["scenes"] != nil
    }

    func run() async throws -> (Data, URLResponse) {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { c in
                lock.withLock {
                    guard !finished else { c.resume(throwing: CancellationError()); return }
                    continuation = c
                    configuration.timeoutIntervalForRequest = max(limits.total, 1)
                    configuration.timeoutIntervalForResource = max(limits.total + 1, 2)
                    let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
                    let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
                    self.session = session
                    var request = self.request; request.timeoutInterval = max(limits.total, 1)
                    task = session.dataTask(with: request)
                    started = ProcessInfo.processInfo.systemUptime; lastUI = started
                    let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
                    timer.schedule(deadline: .now() + limits.polling, repeating: limits.polling)
                    timer.setEventHandler { [weak self] in self?.tick() }
                    self.timer = timer; timer.resume()
                    task?.resume()
                }
            }
        } onCancel: { self.finish(.failure(CancellationError())) }
    }

    private func tick() {
        var failure: LocalAITransportFailure?
        var update: String?
        let advancement = backendProgress?.next()
        lock.withLock {
            guard !finished else { return }
            let now = ProcessInfo.processInfo.systemUptime
            if lastToken == nil, let advancement {
                lastBackendProgress = now; backendUpdate = advancement
                trace?.event("inference.backend-progress", fields: ["model": expectedModel, "phase": advancement.phase],
                    values: ["processedTokens": Double(advancement.tokens ?? 0), "fraction": advancement.fraction ?? 0])
            }
            if now - started >= limits.total { failure = .totalBudget }
            else if let lastToken {
                if now - lastToken >= limits.tokenIdle { failure = .noProgress }
            } else if now - (lastBackendProgress ?? started) >= limits.firstToken { failure = .noProgress }
            if now - lastUI >= 5 {
                lastUI = now
                update = lastToken == nil ? "Модель обрабатывает входные данные · \(Int(now - started)) с"
                    : "Модель формирует ответ · \(tokenEvents) частей ответа · \(Int(now - started)) с"
                if lastToken == nil, let backendUpdate {
                    update = backendUpdate.phase == "loading"
                        ? "Загружаю модель в память · \(Int(now - started)) с"
                        : "Модель изучает кадры · \(Int((backendUpdate.fraction ?? 0) * 100))% · \(Int(now - started)) с"
                }
            }
        }
        if let failure { finish(.failure(failure)); return }
        if let update, let progress { Task { await progress(FilmBuildProgress(.verifying, detail: update, isHeartbeat: true)) } }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let accepted = lock.withLock { () -> Bool in
            guard !finished, let response = response as? HTTPURLResponse else { return false }
            self.response = response; return true
        }
        completionHandler(accepted ? .allow : .cancel)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil) // Model input never follows a redirect off the private service.
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        var result: Result<(Data, URLResponse), Error>?
        lock.withLock {
            guard !finished else { return }
            do {
                receivedBytes += data.count
                guard receivedBytes <= 8_000_000 else { throw URLError(.dataLengthExceedsMaximum) }
                pending.append(data)
                guard let response, (200..<300).contains(response.statusCode) else { return }
                while let newline = pending.firstIndex(of: 10) {
                    let line = pending.prefix(upTo: newline); pending.removeSubrange(...newline)
                    if line.allSatisfy({ $0 == 13 || $0 == 32 || $0 == 9 }) { continue }
                    try append(Data(line))
                    if finalEvent != nil { result = .success(try completed(response: response)); break }
                }
            } catch { result = .failure(error) }
        }
        if let result { finish(result) }
    }

    private func append(_ data: Data) throws {
        guard finalEvent == nil, let event = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw URLError(.cannotParseResponse) }
        if event["error"] is String { throw LocalAITransportFailure.startup }
        guard let model = event["model"] as? String, model == expectedModel || model == expectedModel + ":latest" else { throw URLError(.cannotParseResponse) }
        let next = event["message"] as? [String: Any] ?? [:]
        let newContent = next["content"] as? String ?? ""
        let newThinking = next["thinking"] as? String ?? event["thinking"] as? String ?? ""
        let newGenerated = event["response"] as? String ?? ""
        let calls = next["tool_calls"] as? [[String: Any]] ?? []
        // Empty keep-alives/headers are not model progress. Hidden reasoning is.
        if !newContent.isEmpty || !newThinking.isEmpty || !newGenerated.isEmpty || !calls.isEmpty {
            lastToken = ProcessInfo.processInfo.systemUptime; tokenEvents += 1
        }
        content += newContent; thinking += newThinking; generated += newGenerated; toolCalls += calls
        for (key, value) in next where !["content", "thinking", "tool_calls"].contains(key) { message[key] = value }
        guard content.utf8.count + thinking.utf8.count + generated.utf8.count <= 2_000_000 else { throw URLError(.dataLengthExceedsMaximum) }
        if guardsSceneDescriptions, descriptionLoop.append(newContent) {
            // Explicitly incomplete. The analysis caller takes its existing
            // targeted format-repair path on the same model; transport recovery
            // must not restart the model and resend the unchanged looping input.
            finalEvent = ["model": expectedModel, "done": false, "done_reason": "repetition_guard", "client_interrupted": true]
            return
        }
        if event["done"] as? Bool == true { finalEvent = event }
    }
    private func completed(response: HTTPURLResponse) throws -> (Data, URLResponse) {
        guard var final = finalEvent else { throw LocalAITransportFailure.interrupted }
        if request.url?.path == "/api/chat" {
            guard !content.isEmpty || !toolCalls.isEmpty else { throw URLError(.cannotParseResponse) }
            message["content"] = content
            if !thinking.isEmpty { message["thinking"] = thinking }
            if !toolCalls.isEmpty { message["tool_calls"] = toolCalls }
            final["message"] = message
        } else { final["response"] = generated }
        return (try JSONSerialization.data(withJSONObject: final, options: [.sortedKeys]), response)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        var result: Result<(Data, URLResponse), Error>?
        lock.withLock {
            guard !finished else { return }
            do {
                if let error { throw error }
                guard let response else { throw LocalAITransportFailure.interrupted }
                guard (200..<300).contains(response.statusCode) else {
                    if response.statusCode >= 500 { throw LocalAITransportFailure.startup }
                    result = .success((pending, response)); return
                }
                if !pending.isEmpty { try append(pending); pending.removeAll() }
                result = .success(try completed(response: response))
            } catch { result = .failure(error) }
        }
        if let result { finish(result) }
    }
    private func finish(_ result: Result<(Data, URLResponse), Error>) {
        let cleanup = lock.withLock { () -> (CheckedContinuation<(Data, URLResponse), Error>?, URLSession?, URLSessionDataTask?, DispatchSourceTimer?) in
            guard !finished else { return (nil, nil, nil, nil) }
            finished = true
            let values = (continuation, session, task, timer)
            continuation = nil; session = nil; task = nil; timer = nil
            return values
        }
        cleanup.3?.cancel(); cleanup.2?.cancel(); cleanup.1?.invalidateAndCancel()
        cleanup.0?.resume(with: result)
    }
}
