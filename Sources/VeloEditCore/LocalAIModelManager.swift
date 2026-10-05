import Foundation

public struct LocalModelAvailability: Sendable {
    public let serviceAvailable: Bool
    public let installed: Bool
    public let message: String
}

public struct LocalModelDownloadProgress: Sendable {
    public let status: String
    public let fraction: Double
}

private struct OllamaPullRequest: Encodable {
    let model: String
    let stream = true
}

private struct OllamaPullEvent: Decodable {
    let status: String?
    let total: Int64?
    let completed: Int64?
    let error: String?
}

public struct InstalledAIModel: Codable, Sendable, Hashable {
    public struct Details: Codable, Sendable, Hashable {
        public let quantization_level: String?
        public let parameter_size: String?
    }
    public let name: String
    public let digest: String?
    public let details: Details?
    public var quantization: String? { details?.quantization_level }
}

private struct OllamaLocalTags: Decodable {
    let models: [InstalledAIModel]
}

private struct OllamaWarmRequest: Encodable {
    let model: String
    let prompt = ""
    let stream = false
    let keepAlive = "15m"

    enum CodingKeys: String, CodingKey {
        case model, prompt, stream
        case keepAlive = "keep_alive"
    }
}

public actor LocalAIModelManager {
    public static let shared = LocalAIModelManager()

    private let baseURL = URL(string: "http://127.0.0.1:11434")!
    private var serverProcess: Process?
    private var warmedModels: [String: TimeInterval] = [:]
    private var warming: [String: Task<Void, Error>] = [:]
    private var serviceStart: Task<Void, Error>?
    private var tagsRequest: Task<[String]?, Never>?
    private var tagsSnapshot: (names: [String], time: TimeInterval)?
    private let availabilityLifetime: TimeInterval = 2
    private var modelDigests: [String: String] = [:]
    private var modelDetails: [String: InstalledAIModel] = [:]

    public init() {}

    public nonisolated func authorizeDownload(model: String) {
        UserDefaults.standard.set(true, forKey: "VeloEdit.ModelDownloadConsent.\(model)")
    }

    public func prepareAuthorizedModel(model: String, progress: (@Sendable (LocalModelDownloadProgress) -> Void)? = nil) async throws {
        let status = await availability(model: model)
        if !status.installed {
            guard UserDefaults.standard.bool(forKey: "VeloEdit.ModelDownloadConsent.\(model)") else {
                throw LocalAIModelError.downloadApprovalRequired(model)
            }
            try await pull(model: model, progress: progress)
        }
        try await Self.recoveringRequest { try await self.warmUp(model: model) }
    }

    static func recoveringRequest<T: Sendable>(retryTimeouts: Bool = true, _ operation: @Sendable () async throws -> T) async throws -> T {
        var attempts = 0
        while true {
            try Task.checkCancellation()
            do { return try await operation() }
            catch {
                if !retryTimeouts, (error as? URLError)?.code == .timedOut { throw error }
                let cause = AutonomousFailureCause.classify(error)
                guard cause == .transientNetwork || cause == .localService else { throw error }
                let delay: TimeInterval
                if let store = AutonomousJobContext.store {
                    guard let reserved = try await store.reserveRecovery(error: error, strategy: "reopen-local-model-session") else { throw error }
                    delay = reserved
                } else {
                    guard attempts < 2 else { throw error }
                    delay = attempts == 0 ? 1 : 3
                }
                attempts += 1
                try await Task.sleep(for: .seconds(delay))
                await Self.shared.invalidateReadiness()
                try await Self.shared.ensureService()
            }
        }
    }

    public func availability(model: String, startService: Bool = true) async -> LocalModelAvailability {
        do {
            if startService { try await ensureService() }
            guard let models = await installedModels() else {
                return LocalModelAvailability(serviceAvailable: false, installed: false, message: "Ollama не запущен")
            }
            let installed = models.contains { Self.modelName($0, matches: model) }
            return LocalModelAvailability(
                serviceAvailable: true,
                installed: installed,
                message: installed
                    ? "Установлена: \(model) · \(modelDetails[model]?.quantization ?? modelDetails[model + ":latest"]?.quantization ?? "битность неизвестна")"
                    : "\(model) не установлена — полный нейроанализ этого режима недоступен"
            )
        } catch {
            return LocalModelAvailability(serviceAvailable: false, installed: false, message: error.localizedDescription)
        }
    }

    public func pull(model: String, progress: (@Sendable (LocalModelDownloadProgress) -> Void)? = nil) async throws {
        try await Self.recoveringRequest { try await self.pullAttempt(model: model, progress: progress) }
    }

    private func pullAttempt(model: String, progress: (@Sendable (LocalModelDownloadProgress) -> Void)?) async throws {
        try await ensureService()
        var request = URLRequest(url: baseURL.appendingPathComponent("api/pull"))
        request.httpMethod = "POST"
        request.timeoutInterval = 24 * 60 * 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(OllamaPullRequest(model: model))
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw URLError(.badServerResponse) }
        for try await line in bytes.lines {
            if Task.isCancelled { throw CancellationError() }
            guard let event = try? JSONDecoder().decode(OllamaPullEvent.self, from: Data(line.utf8)) else { continue }
            if let error = event.error, !error.isEmpty { throw LocalAIModelError.downloadFailed(error) }
            let fraction: Double
            if let total = event.total, total > 0, let completed = event.completed {
                fraction = min(1, max(0, Double(completed) / Double(total)))
            } else {
                fraction = event.status == "success" ? 1 : 0
            }
            progress?(LocalModelDownloadProgress(status: event.status ?? "Загружаю модель", fraction: fraction))
        }
        tagsSnapshot = nil
        let result = await availability(model: model, startService: false)
        guard result.installed else { throw LocalAIModelError.downloadFailed("Ollama не подтвердил установку модели") }
    }

    public func warmUp(model: String) async throws {
        try await ensureService()
        if let time = warmedModels[model], ProcessInfo.processInfo.systemUptime - time < 60 { return }
        if let task = warming[model] { return try await task.value }
        let task = Task { try await self.performWarmUp(model: model) }
        warming[model] = task
        defer { warming.removeValue(forKey: model) }
        try await task.value
        try Task.checkCancellation()
    }

    private func performWarmUp(model: String) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/generate"))
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(OllamaWarmRequest(model: model))
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        warmedModels[model] = ProcessInfo.processInfo.systemUptime
    }

    public func invalidateReadiness() {
        tagsSnapshot = nil
        warmedModels.removeAll()
    }

    public func ensureService() async throws {
        if await installedModels() != nil { return }
        if let task = serviceStart { return try await task.value }
        let task = Task { try await self.startService() }
        serviceStart = task
        defer { serviceStart = nil }
        try await task.value
    }

    private func startService() async throws {
        // Only a Process instance launched by this manager may be stopped.
        // A foreign service on the same port is never a termination target.
        if let process = serverProcess, process.isRunning {
            process.terminate()
            for _ in 0..<20 where process.isRunning { try await Task.sleep(for: .milliseconds(100)) }
            guard !process.isRunning else { throw LocalAIModelError.serviceUnavailable }
        }
        warmedModels.removeAll()
        if serverProcess?.isRunning != true {
            guard let executable = Self.ollamaExecutable() else { throw LocalAIModelError.ollamaNotInstalled }
            let process = Process()
            process.executableURL = executable
            process.arguments = ["serve"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            serverProcess = process
        }
        for _ in 0..<16 {
            if await installedModels() != nil { return }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw LocalAIModelError.serviceUnavailable
    }

    public func installedModelDigest(model: String) async -> String? {
        // A same-name model replacement must never validate an older answer.
        guard await installedModels(forceRefresh: true) != nil else { return nil }
        return modelDigests[model] ?? modelDigests["\(model):latest"]
    }

    public func installedModelInfo(model: String) async -> InstalledAIModel? {
        guard await installedModels(forceRefresh: true) != nil else { return nil }
        return modelDetails[model] ?? modelDetails["\(model):latest"]
    }

    private func installedModels(forceRefresh: Bool = false) async -> [String]? {
        if !forceRefresh, let snapshot = tagsSnapshot,
           ProcessInfo.processInfo.systemUptime - snapshot.time < availabilityLifetime { return snapshot.names }
        if let task = tagsRequest { return await task.value }
        let task = Task { await self.fetchInstalledModels() }
        tagsRequest = task
        let names = await task.value
        tagsRequest = nil
        if let names { tagsSnapshot = (names, ProcessInfo.processInfo.systemUptime) }
        else { tagsSnapshot = nil }
        return names
    }

    private func fetchInstalledModels() async -> [String]? {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/tags"))
        request.timeoutInterval = 1
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let tags = try? JSONDecoder().decode(OllamaLocalTags.self, from: data) else { return nil }
        modelDigests = Dictionary(tags.models.compactMap { model in model.digest.map { (model.name, $0) } }, uniquingKeysWith: { _, new in new })
        modelDetails = Dictionary(tags.models.map { ($0.name, $0) }, uniquingKeysWith: { _, new in new })
        return tags.models.map(\.name)
    }

    private static func modelName(_ installed: String, matches requested: String) -> Bool {
        if requested.contains(":") { return installed == requested }
        return installed == requested || installed == "\(requested):latest"
    }

    private static func ollamaExecutable() -> URL? {
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("Ollama/ollama").path
        let candidates = [bundled].compactMap { $0 } + [
            "/Applications/Ollama.app/Contents/Resources/ollama",
            "/opt/homebrew/bin/ollama",
            "/usr/local/bin/ollama"
        ] + (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map { "\($0)/ollama" }
        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }).map(URL.init(fileURLWithPath:))
    }
}

public enum LocalAIModelError: LocalizedError {
    case ollamaNotInstalled
    case serviceUnavailable
    case downloadFailed(String)
    case downloadApprovalRequired(String)

    public var errorDescription: String? {
        switch self {
        case .ollamaNotInstalled: return "В этой копии приложения отсутствует локальный runtime. Нужен полный пакет VeloEdit.app."
        case .serviceUnavailable: return "Не удалось запустить локальный сервис Ollama."
        case .downloadFailed(let message): return "Не удалось загрузить модель: \(message)"
        case .downloadApprovalRequired: return "Для подготовки локального анализа требуется разрешить загрузку модели."
        }
    }
}
