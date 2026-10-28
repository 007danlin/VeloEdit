import Foundation

/// Immutable contract saved before the first film stage. Installed models and
/// later UI changes cannot change a running or recovered job's semantics.
public struct FilmProcessProfile: Codable, Hashable, Sendable {
    public static let currentVersion = 1
    public struct SemanticSampling: Codable, Hashable, Sendable {
        public let temperature: Double
        public let seed: Int
    }
    public static let defaultSemanticSampling = SemanticSampling(temperature: 0, seed: 42)
    // Optional for saved v1 jobs; absence migrates to the explicit default,
    // never to mutable model-tag defaults. The cache identity includes it.
    public let semanticSampling: SemanticSampling?
    public var effectiveSemanticSampling: SemanticSampling { semanticSampling ?? Self.defaultSemanticSampling }
    public let version: Int
    public let analysis: AIAnalysisProfile
    public private(set) var modelDigest: String?
    public let contextTokens: Int
    // New jobs group the independent one-image observers before temporal
    // comparisons. Their complete inputs fit this allocation; larger requests
    // retain contextTokens. Absence preserves saved jobs' original policy.
    public let singleImageReviewContextTokens: Int?
    // Saved jobs retain their original decoder order. This changes only new
    // 2B technical observations, never the model or the independent observers.
    public let technicalObservationFirst: Bool?
    public let reviewFractions: [Double]
    public let reviewLongEdge: Int
    public let boundaryLongEdge: Int
    public let boundaryLeadSeconds: Double
    public let boundaryNearSeconds: Double
    public let boundaryFollowingSeconds: Double
    public let responseRepairAttempts: Int
    public let immediateTransportRetries: Int
    public let tokenIdleSeconds: Double
    public let shotBudgetSeconds: Double
    public let recoveryBackoffSeconds: [Double]

    public init(analysis: AIAnalysisProfile, modelDigest: String? = nil) {
        version = Self.currentVersion
        semanticSampling = Self.defaultSemanticSampling
        self.analysis = analysis
        self.modelDigest = modelDigest
        // One sufficiently large context across analysis, boundaries and text
        // avoids repeatedly unloading/reloading the same weights at each stage.
        // Balanced can send fifteen distinct images; at the runtime's minimum
        // 1024 visual tokens each, 16K leaves insufficient room for labels,
        // instructions and the answer. Quality sends sixteen, Maximum twelve
        // larger samples. Reuse is an optimization, never a context guarantee.
        contextTokens = analysis.mode == .fast ? 16384 : 32768
        // Counterbalanced 2B replays preserve complete inputs/answers while
        // reducing resident KV state. Other modes keep their existing policy:
        // a single mixed-load timing pair does not establish a speed benefit.
        singleImageReviewContextTokens = analysis.mode == .fast ? 4096 : nil
        technicalObservationFirst = analysis.mode == .fast ? true : nil
        reviewFractions = [0.02, 0.25, 0.5, 0.75, 0.98]
        // The runtime expands small images to its minimum visual-token budget.
        // Keep the actual detail instead, and share exact decoded pixels with
        // the boundary observers rather than decoding both 384 and 1280 copies.
        reviewLongEdge = 1280
        boundaryLongEdge = 1280
        boundaryLeadSeconds = 1
        boundaryNearSeconds = 0.25
        boundaryFollowingSeconds = 4
        responseRepairAttempts = 1
        immediateTransportRetries = 1
        tokenIdleSeconds = 60
        shotBudgetSeconds = 600
        recoveryBackoffSeconds = [30, 60, 120, 240, 300]
    }

    public var modelID: String { analysis.modelID }
    public var mode: AIPowerMode { analysis.mode }
    public var reviewFrameCount: Int { reviewFractions.count }

    /// Confirm the weights without recreating the policy of a saved job using
    /// today's defaults. Legacy optional fields and custom sampling stay frozen.
    func bindingModelDigest(_ digest: String?) throws -> Self {
        try validate(model: modelID, digest: digest)
        if let digest, digest.isEmpty {
            throw LocalAIInferenceFailure(model: modelID,
                reason: "не удалось подтвердить файлы выбранной модели перед запуском задания")
        }
        var bound = self
        bound.modelDigest = digest
        return bound
    }

    // Raw replies are additionally keyed by the exact request, including its
    // actual context. Preserve unchanged temporal observations when only the
    // one-image allocation/scheduling policy changes.
    var observationIdentity: String {
        [String(version), String(contextTokens), String(reviewLongEdge), String(boundaryLongEdge),
         reviewFractions.map { String($0.bitPattern) }.joined(separator: ","),
         String(boundaryLeadSeconds.bitPattern), String(boundaryNearSeconds.bitPattern),
         String(boundaryFollowingSeconds.bitPattern), String(effectiveSemanticSampling.temperature.bitPattern),
         String(effectiveSemanticSampling.seed)].joined(separator: "|")
    }

    var reviewIdentity: String {
        observationIdentity + (singleImageReviewContextTokens.map { "|single-image-context=\($0)" } ?? "")
            + (technicalObservationFirst == true ? "|technical-observation-first=1" : "")
    }

    public func validateDevice(physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) throws {
        let expected = AIAnalysisProfile.resolve(mode: mode).modelID
        guard modelID == expected else { throw FilmProcessProfileError.wrongModel(expected: expected, actual: modelID) }
        if mode == .maximum && physicalMemory < 32 * 1_073_741_824 {
            throw FilmProcessProfileError.unsupportedDevice
        }
        guard version == Self.currentVersion else { throw FilmProcessProfileError.unsupportedVersion }
        if let singleImageReviewContextTokens {
            guard singleImageReviewContextTokens == 4096, contextTokens >= singleImageReviewContextTokens else {
                throw FilmProcessProfileError.unsupportedVersion
            }
        }
    }

    func validate(model: String) throws {
        guard model == modelID else { throw FilmProcessProfileError.wrongModel(expected: modelID, actual: model) }
    }

    /// Missing runtime metadata is not evidence that the saved weights still
    /// match. Keep the job resumable, but neither reuse nor create a certificate
    /// under an unverifiable weight identity.
    func validate(model: String, digest: String?) throws {
        try validate(model: model)
        guard let modelDigest else { return }
        guard let digest, !digest.isEmpty else {
            throw LocalAIInferenceFailure(model: modelID, reason: "не удалось подтвердить файлы выбранной модели; повторю проверку её состояния")
        }
        guard modelDigest == digest else { throw FilmProcessProfileError.changedWeights(modelID) }
    }
}

public enum FilmProcessProfileError: LocalizedError, Sendable {
    case unsupportedDevice, unsupportedVersion
    case wrongModel(expected: String, actual: String)
    case changedWeights(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedDevice:
            return "Для режима «Максимально» с Qwen3-VL 30B-A3B требуется не менее 32 ГБ памяти. Выберите другой режим; модель автоматически не заменяется."
        case .unsupportedVersion:
            return "Версия профиля сохранённого задания не поддерживается этой сборкой VeloEdit."
        case .wrongModel(let expected, let actual):
            return "Профиль задания требует \(expected), но этап запросил \(actual). Проверка не выполнена; результаты сохранены."
        case .changedWeights(let model):
            return "Файлы модели \(model) изменились после запуска задания. Сохранённые проверки нельзя выдавать за результаты новых весов."
        }
    }
}

enum FilmProcessContext {
    @TaskLocal static var current: FilmProcessProfile?
    // Only the independent per-image review stage enters this scope. Explicit
    // larger requirements (including format repairs) still take precedence.
    @TaskLocal static var minimumReviewContextTokens: Int?

    static func analysis(preferences: UserPreferences) -> AIAnalysisProfile {
        current?.analysis ?? AIAnalysisProfile.resolve(mode: preferences.effectiveAIPowerMode,
            advanced: preferences.effectiveAdvancedAISettings, thermalState: .nominal)
    }

    static func minimumContextTokens(for input: [String: Any]) -> Int? {
        guard let profile = current else { return nil }
        let imageCount = (input["messages"] as? [[String: Any]] ?? []).reduce(0) {
            $0 + (($1["images"] as? [String])?.count ?? 0)
        }
        if let configured = profile.singleImageReviewContextTokens,
           minimumReviewContextTokens == configured, imageCount == 1 {
            return configured
        }
        // Long text and temporal/multi-image calls cannot inherit the smaller
        // allocation accidentally, even from a nested review helper.
        return profile.contextTokens
    }

    /// Applied before hashing a request, so cache receipts describe the actual
    /// input. The transport validates again to catch newly added helper paths.
    static func requestBody(_ input: [String: Any]) throws -> [String: Any] {
        guard let profile = current else { return input }
        guard let model = input["model"] as? String else { throw URLError(.cannotParseResponse) }
        try profile.validate(model: model)
        var body = input
        var options = body["options"] as? [String: Any] ?? [:]
        options["num_ctx"] = max(minimumContextTokens(for: input) ?? profile.contextTokens,
                                 options["num_ctx"] as? Int ?? 0)
        options["temperature"] = profile.effectiveSemanticSampling.temperature
        options["seed"] = profile.effectiveSemanticSampling.seed
        body["options"] = options
        body["keep_alive"] = "10m"
        return body
    }
}
