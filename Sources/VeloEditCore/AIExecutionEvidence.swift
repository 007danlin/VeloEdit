import Foundation

/// Persisted evidence of completed work, distinct from the requested profile.
/// Missing evidence in older projects requires one fresh analysis.
public struct AIExecutionEvidence: Codable, Hashable, Sendable {
    public var visualAnalysisCompleted: Bool
    public var audioAnalysisCompleted: Bool
    public var plannedScenes: Int
    public var evaluatedScenes: Int
    public var plannedRechecks: Int
    public var evaluatedRechecks: Int
    public var modelAvailable: Bool
    public var modelQuantization: String?

    public init(visualAnalysisCompleted: Bool, audioAnalysisCompleted: Bool = true, plannedScenes: Int = 0, evaluatedScenes: Int = 0,
                plannedRechecks: Int = 0, evaluatedRechecks: Int = 0,
                modelAvailable: Bool = false, modelQuantization: String? = nil) {
        self.visualAnalysisCompleted = visualAnalysisCompleted
        self.audioAnalysisCompleted = audioAnalysisCompleted
        self.plannedScenes = plannedScenes
        self.evaluatedScenes = evaluatedScenes
        self.plannedRechecks = plannedRechecks
        self.evaluatedRechecks = evaluatedRechecks
        self.modelAvailable = modelAvailable
        self.modelQuantization = modelQuantization
    }

    public var isComplete: Bool {
        visualAnalysisCompleted && audioAnalysisCompleted && plannedScenes >= 0 && plannedRechecks >= 0
            && evaluatedScenes == plannedScenes && evaluatedRechecks == plannedRechecks
            && (plannedScenes + plannedRechecks == 0 || modelAvailable)
    }

    public var summary: String {
        guard visualAnalysisCompleted else { return "Анализ кадров не завершён; нужен повтор" }
        guard audioAnalysisCompleted else { return "Анализ звука не завершён; нужен повтор" }
        guard plannedScenes > 0 else { return "Локальный анализ кадров завершён" }
        let recheck = plannedRechecks > 0 ? " · перепроверено: \(evaluatedRechecks)/\(plannedRechecks)" : ""
        return "Нейрооценки: \(evaluatedScenes)/\(plannedScenes)\(recheck)"
            + (isComplete ? " · завершено" : " · требуется повтор")
    }
}
