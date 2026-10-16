import Foundation

/// Persisted separately from the working edit: a failed experiment cannot
/// overwrite the last technically verified movie, including across restart.
public final class FilmVerifiedAlternative: Codable, Sendable {
    let timeline: Timeline
    let plan: StoryPlan
    let concreteDefects: Int
    init(timeline: Timeline, plan: StoryPlan, concreteDefects: Int) {
        self.timeline = timeline; self.plan = plan; self.concreteDefects = concreteDefects
    }
}
public struct FilmContentRepairState: Codable, Sendable {
    var attempts = 0
    var semanticSecondsRemaining: Double = 180
    var visited: Set<String> = []
    var best: FilmVerifiedAlternative?
    var reason: String? = nil
    static let maximumAttempts = 2

    mutating func retain(timeline: Timeline, plan: StoryPlan, defects: Int) -> Bool {
        visited.insert(EditorialRenderSignature.signature(timeline))
        guard best == nil || defects < best!.concreteDefects else { return false }
        best = .init(timeline: timeline, plan: plan, concreteDefects: defects)
        return true
    }
    mutating func permit(signature: String, improved: Bool, defects: Int) -> Bool {
        guard defects > 0 else { reason = nil; return false }
        guard improved else { reason = "Повторная проверка не показала улучшения; сохранён лучший проверенный вариант"; return false }
        guard attempts < Self.maximumAttempts else { reason = "Лимит улучшений исчерпан; сохранён лучший проверенный вариант"; return false }
        guard visited.insert(signature).inserted else { reason = "Этот вариант уже проверен; повторная пересборка остановлена"; return false }
        attempts += 1
        reason = "Исправляю подтверждённое перекрытие кадра или обрезанное действие"
        return true
    }
}
