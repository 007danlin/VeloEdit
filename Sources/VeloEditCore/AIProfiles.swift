import Foundation

public enum AIPowerMode: String, Codable, CaseIterable, Identifiable, Sendable, Hashable {
    case fast
    case balanced
    case quality
    case maximum

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .fast: return "⚡ Быстро"
        case .balanced: return "⚖️ Баланс"
        case .quality: return "🧠 Качество"
        case .maximum: return "🎬 Максимум"
        }
    }

    public var shortDescription: String {
        switch self {
        case .fast: return "2B · короткая выборка сцен · без proxy и анализа звука"
        case .balanced: return "4B · ключевые сцены и пейзажи · анализ звука"
        case .quality: return "8B · все кандидаты · подробный анализ · речь при доступности Speech"
        case .maximum: return "Больше контекста кадров · независимая перепроверка важных сцен"
        }
    }
}

public enum LocalAIRuntime: String, Codable, CaseIterable, Identifiable, Sendable {
    case automatic
    case mlx
    case ollama

    // Keep decoding legacy MLX settings, but never offer a backend that is not shipped.
    public static var allCases: [Self] { [.automatic, .ollama] }

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .automatic: return "Автоматически"
        case .mlx: return "MLX (недоступен в этой сборке)"
        case .ollama: return "Ollama"
        }
    }
}

public enum AIQuantization: String, Codable, CaseIterable, Identifiable, Sendable {
    case modelProvided = "Из установленной модели"
    case q4 = "4-bit"
    case q8 = "8-bit"
    case fp16 = "16-bit"

    public static var allCases: [Self] { [.modelProvided] }

    public var id: String { rawValue }
}

public enum AnalysisDepth: Int, Codable, CaseIterable, Comparable, Sendable, Hashable {
    case imported = 0
    case metadata = 1
    case quick = 2
    case scene = 3
    case deep = 4
    case maximum = 5

    public static func < (lhs: AnalysisDepth, rhs: AnalysisDepth) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public enum AnalysisProxyPolicy: String, Codable, Sendable, Hashable {
    case avoidFullEncode
    case whenNeeded
    case required
    case highQuality
}

public enum AudioAnalysisLevel: String, Codable, Sendable, Hashable {
    case none
    case basic
    case deep
}

public enum VLMCandidatePolicy: String, Codable, Sendable, Hashable {
    case ambiguityOnly
    case keyScenes
    case broadScenes
    case temporalRecheck
}

public struct AdvancedAISettings: Codable, Hashable, Sendable {
    public var enabled: Bool
    public var runtime: LocalAIRuntime
    public var modelID: String
    public var quantization: AIQuantization

    public init(enabled: Bool = false, runtime: LocalAIRuntime = .automatic, modelID: String = "", quantization: AIQuantization = .q4) {
        self.enabled = enabled
        self.runtime = runtime
        self.modelID = modelID
        self.quantization = quantization
    }
}

public struct AIAnalysisProfile: Hashable, Sendable {
    public let mode: AIPowerMode
    public let runtime: LocalAIRuntime
    public let ollamaModelID: String
    public let mlxModelID: String
    public let quantization: AIQuantization
    public let proxyLongEdge: Int
    public let coarseInterval: Double
    public let denseInterval: Double
    public let maximumCoarseFrames: Int
    public let maximumDeepCandidates: Int
    public let framesPerCandidate: Int
    public let mediaConcurrency: Int
    public let aiConcurrency: Int
    public let thinkingEnabled: Bool

    public var modelID: String { ollamaModelID }
    public static let cacheVersion = "pipeline-v8-ai-evidence"
    public var cacheKey: String {
        [Self.cacheVersion, mode.rawValue, "ollama", modelID].joined(separator: ":")
    }

    /// Modes differ by work performed, not only by frame density.
    public var targetDepth: AnalysisDepth {
        switch mode {
        case .fast: return .quick
        case .balanced: return .scene
        case .quality: return .deep
        case .maximum: return .maximum
        }
    }

    public var proxyPolicy: AnalysisProxyPolicy {
        switch mode {
        case .fast: return .avoidFullEncode
        case .balanced: return .whenNeeded
        case .quality: return .required
        case .maximum: return .highQuality
        }
    }

    public var audioAnalysisLevel: AudioAnalysisLevel {
        switch mode {
        case .fast: return .none
        case .balanced: return .basic
        case .quality, .maximum: return .deep
        }
    }

    public var vlmCandidatePolicy: VLMCandidatePolicy {
        switch mode {
        case .fast: return .ambiguityOnly
        case .balanced: return .keyScenes
        case .quality: return .broadScenes
        case .maximum: return .temporalRecheck
        }
    }

    public var scenesPerVLMRequest: Int {
        switch mode {
        case .fast: return 2
        case .balanced: return 3
        // Preserve 8/12 images per scene by making smaller batches, not by
        // silently discarding half the scheduled images.
        case .quality: return 2
        case .maximum: return 1
        }
    }

    public var maximumVLMScenes: Int {
        switch mode {
        // Keep Fast to one compact VLM batch. It still benefits from semantic
        // visual judgement without turning the lightweight mode into a broad
        // scene-by-scene pass.
        case .fast: return min(2, maximumDeepCandidates)
        case .balanced: return min(6, maximumDeepCandidates)
        case .quality: return maximumDeepCandidates
        case .maximum: return maximumDeepCandidates
        }
    }

    public var vlmTimeout: TimeInterval {
        switch mode {
        case .fast: return 45
        case .balanced: return 90
        case .quality: return 180
        case .maximum: return 240
        }
    }

    /// Image encoding happens before the first token. It needs its own budget;
    /// the old 45/90-second total budget discarded healthy cold inference.
    public func vlmPrefillTimeout(imageCount: Int) -> TimeInterval {
        max(vlmTimeout, 60 + Double(max(1, imageCount)) * 20)
    }

    public var sceneSensitivity: Double {
        switch mode {
        case .fast: return 0.58
        case .balanced: return 0.49
        case .quality: return 0.42
        case .maximum: return 0.36
        }
    }

    public var rechecksImportantScenes: Bool { mode == .maximum }
    public var comparesAcrossVideos: Bool { true }

    public var summary: String {
        "Ollama · \(modelID) · битность из установленной модели"
    }

    public var estimatedDownloadSize: String {
        if ollamaModelID.contains(":2b") { return "около 1,9 ГБ" }
        if ollamaModelID.contains(":4b") { return "около 3,3 ГБ" }
        if ollamaModelID.contains(":8b") { return "около 6,1 ГБ" }
        if ollamaModelID.contains(":30b") { return "около 20 ГБ" }
        return "размер определит выбранная модель"
    }

    public static func resolve(
        mode: AIPowerMode,
        advanced: AdvancedAISettings = AdvancedAISettings(),
        physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory,
        thermalState: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState,
        lowPowerMode: Bool = ProcessInfo.processInfo.isLowPowerModeEnabled
    ) -> AIAnalysisProfile {
        let base: AIAnalysisProfile
        switch mode {
        case .fast:
            base = AIAnalysisProfile(mode: mode, runtime: .automatic, ollamaModelID: "qwen3-vl:2b-instruct", mlxModelID: "mlx-community/Qwen3-VL-2B-Instruct-4bit", quantization: .q4, proxyLongEdge: 720, coarseInterval: 12, denseInterval: 2, maximumCoarseFrames: 40, maximumDeepCandidates: 4, framesPerCandidate: 3, mediaConcurrency: 2, aiConcurrency: 1, thinkingEnabled: false)
        case .balanced:
            base = AIAnalysisProfile(mode: mode, runtime: .automatic, ollamaModelID: "qwen3-vl:4b-instruct", mlxModelID: "lmstudio-community/Qwen3-VL-4B-Instruct-MLX-4bit", quantization: .q4, proxyLongEdge: 960, coarseInterval: 7, denseInterval: 1, maximumCoarseFrames: 70, maximumDeepCandidates: 8, framesPerCandidate: 5, mediaConcurrency: 2, aiConcurrency: 1, thinkingEnabled: false)
        case .quality:
            base = AIAnalysisProfile(mode: mode, runtime: .automatic, ollamaModelID: "qwen3-vl:8b-instruct", mlxModelID: "mlx-community/Qwen3-VL-8B-Instruct-4bit", quantization: .q4, proxyLongEdge: 1080, coarseInterval: 4, denseInterval: 0.67, maximumCoarseFrames: 110, maximumDeepCandidates: 12, framesPerCandidate: 8, mediaConcurrency: 1, aiConcurrency: 1, thinkingEnabled: false)
        case .maximum:
            // A 30B quantized VLM needs substantially more unified memory than
            // a base MacBook Air. Falling back here prevents memory pressure
            // and swap from making the nominally "maximum" mode worse.
            let canUse30B = physicalMemory >= 32 * 1_073_741_824
            base = AIAnalysisProfile(mode: mode, runtime: .automatic, ollamaModelID: canUse30B ? "qwen3-vl:30b-a3b-instruct" : "qwen3-vl:8b-instruct", mlxModelID: "", quantization: .q4, proxyLongEdge: 1440, coarseInterval: 2.5, denseInterval: 0.4, maximumCoarseFrames: 180, maximumDeepCandidates: 18, framesPerCandidate: 12, mediaConcurrency: 1, aiConcurrency: 1, thinkingEnabled: false)
        }

        var result = base
        if advanced.enabled {
            result = AIAnalysisProfile(
                mode: mode,
                runtime: advanced.runtime == .mlx ? .ollama : advanced.runtime,
                ollamaModelID: advanced.modelID.isEmpty || (advanced.runtime == .mlx && advanced.modelID.contains("/")) ? base.ollamaModelID : advanced.modelID,
                mlxModelID: "",
                quantization: .modelProvided,
                proxyLongEdge: base.proxyLongEdge,
                coarseInterval: base.coarseInterval,
                denseInterval: base.denseInterval,
                maximumCoarseFrames: base.maximumCoarseFrames,
                maximumDeepCandidates: base.maximumDeepCandidates,
                framesPerCandidate: base.framesPerCandidate,
                mediaConcurrency: base.mediaConcurrency,
                aiConcurrency: base.aiConcurrency,
                thinkingEnabled: base.thinkingEnabled
            )
        }

        if lowPowerMode || thermalState == .serious || thermalState == .critical {
            result = AIAnalysisProfile(
                mode: result.mode, runtime: result.runtime,
                ollamaModelID: result.ollamaModelID, mlxModelID: result.mlxModelID,
                quantization: result.quantization, proxyLongEdge: result.proxyLongEdge,
                coarseInterval: result.coarseInterval, denseInterval: result.denseInterval,
                maximumCoarseFrames: result.maximumCoarseFrames,
                maximumDeepCandidates: result.maximumDeepCandidates,
                framesPerCandidate: result.framesPerCandidate,
                mediaConcurrency: 1, aiConcurrency: 1, thinkingEnabled: result.thinkingEnabled
            )
        }
        return result
    }
}
