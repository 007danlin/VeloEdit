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

private struct OllamaLocalTags: Decodable {
    struct Model: Decodable { let name: String }
    let models: [Model]
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
    private var warmedModels: Set<String> = []

    public init() {}

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
                message: installed ? "\(model) загружена и готова" : "\(model) ещё не загружена"
            )
        } catch {
            return LocalModelAvailability(serviceAvailable: false, installed: false, message: error.localizedDescription)
        }
    }

    public func pull(model: String, progress: (@Sendable (LocalModelDownloadProgress) -> Void)? = nil) async throws {
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
        let result = await availability(model: model, startService: false)
        guard result.installed else { throw LocalAIModelError.downloadFailed("Ollama не подтвердил установку модели") }
    }

    public func warmUp(model: String) async throws {
        if warmedModels.contains(model) { return }
        try await ensureService()
        var request = URLRequest(url: baseURL.appendingPathComponent("api/generate"))
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(OllamaWarmRequest(model: model))
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        warmedModels.insert(model)
    }

    public func ensureService() async throws {
        if await installedModels() != nil { return }
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

    private func installedModels() async -> [String]? {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/tags"))
        request.timeoutInterval = 1
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let tags = try? JSONDecoder().decode(OllamaLocalTags.self, from: data) else { return nil }
        return tags.models.map(\.name)
    }

    private static func modelName(_ installed: String, matches requested: String) -> Bool {
        if requested.contains(":") { return installed == requested }
        return installed == requested || installed == "\(requested):latest"
    }

    private static func ollamaExecutable() -> URL? {
        let candidates = [
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

    public var errorDescription: String? {
        switch self {
        case .ollamaNotInstalled: return "Ollama не установлен. Установите бесплатный локальный runtime и повторите загрузку."
        case .serviceUnavailable: return "Не удалось запустить локальный сервис Ollama."
        case .downloadFailed(let message): return "Не удалось загрузить модель: \(message)"
        }
    }
}
