import Foundation

/// Tracks producer activity separately from completed work. A timer alone
/// cannot prove that the model is making progress.
public struct FilmBuildActivity: Sendable {
    public private(set) var lastUpdate: TimeInterval
    public private(set) var stepStarted: TimeInterval
    private var waitingForModel = false
    private var stage: FilmBuildProgress.Stage?

    public init(now: TimeInterval) {
        lastUpdate = now
        stepStarted = now
    }

    public mutating func observe(_ update: FilmBuildProgress, now: TimeInterval) {
        lastUpdate = now
        if !update.isHeartbeat || stage != update.stage { stepStarted = now }
        waitingForModel = update.isHeartbeat
        stage = update.stage
    }

    public func notice(now: TimeInterval) -> (message: String, delayed: Bool) {
        let silence = max(0, Int(now - lastUpdate))
        let waiting = max(0, Int(now - stepStarted))
        if silence >= 30 {
            return ("Нет обновлений уже \(Self.duration(silence)). Не могу подтвердить продвижение. Можно подождать или отменить создание фильма.", true)
        }
        if waitingForModel, waiting >= 45 {
            return ("Ответ модели занимает больше времени: \(Self.duration(waiting)). Пока ожидаю результат; можно подождать или отменить создание фильма.", true)
        }
        if stage == .sourceContent || stage == .renderedContent {
            return ("Каждый фрагмент проходит несколько проверок кадров. Счётчик увеличится после завершения всех проверок фрагмента.", false)
        }
        if stage == .sourceFrames {
            return ("Проверяю кадры каждого фрагмента. Затем отдельно проверю границы действий; фильм ещё не прошёл полную проверку.", false)
        }
        if stage == .sourceBoundaries {
            return ("Кадры проверены. Сравниваю начало и конец действий с соседними кадрами, чтобы проверить склейки.", false)
        }
        return ("Здесь появляются текущий шаг и результаты обработки.", false)
    }

    private static func duration(_ seconds: Int) -> String {
        seconds < 60 ? "\(seconds) с" : "\(seconds / 60) мин \(seconds % 60) с"
    }
}
