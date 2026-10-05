import Foundation

/// Work milestones, not elapsed-time percentages. These stages have different
/// costs, so their ordinal position must never be extrapolated into an ETA.
public struct FilmBuildProgress: Sendable, Equatable {
    public enum Stage: String, Sendable {
        case speech, speechWarmup, narrative, subtitles
        case analysis, preparing, evidence, moments, planning, findingMusic, analyzingMusic
        case assembling, reviewing, fallback, finishing, soundtrack, verifying, saving
        case previewFrames, controlExport, deliveryFrames, audioCheck, resuming

        public var title: String {
            switch self {
            case .speech: return "Распознаю речь"
            case .speechWarmup: return "Подготавливаю локальную речь"
            case .narrative: return "Собираю рассказ"
            case .subtitles: return "Добавляю субтитры"
            case .analysis: return "Готовлю материалы"
            case .preparing: return "Готовлю сборку фильма"
            case .evidence: return "Проверяю исходные кадры"
            case .moments: return "Уточняю границы интересных моментов"
            case .planning: return "Планирую историю фильма"
            case .findingMusic: return "Подбираю и загружаю музыку"
            case .analyzingMusic: return "Изучаю ритм музыкальных треков"
            case .assembling: return "Собираю варианты монтажа"
            case .reviewing: return "Проверяю кадры вариантов монтажа"
            case .fallback: return "Проверяю дополнительные варианты монтажа"
            case .finishing: return "Дорабатываю выбранный вариант"
            case .soundtrack: return "Подгоняю музыку к фильму"
            case .verifying: return "Проверяю готовый фильм и звук"
            case .saving: return "Сохраняю монтаж"
            case .previewFrames: return "Проверяю кадры монтажа"
            case .controlExport: return "Создаю контрольное видео"
            case .deliveryFrames: return "Сравниваю готовое видео с монтажом"
            case .audioCheck: return "Проверяю звук готового видео"
            case .resuming: return "Продолжаю сохранённую сборку"
            }
        }
    }

    public var stage: Stage
    public var completed: Int?
    public var total: Int?
    public var detail: String?

    public init(_ stage: Stage, completed: Int? = nil, total: Int? = nil, detail: String? = nil) {
        self.stage = stage
        self.completed = completed
        self.total = total
        self.detail = detail
    }

    /// This fraction describes only the named operation, never the entire build.
    public var fraction: Double? {
        guard let completed, let total, total > 0 else { return nil }
        return Double(min(total, max(0, completed))) / Double(total)
    }

    public var countLabel: String {
        guard let completed, let total, total > 0 else { return "" }
        return "\(min(total, max(0, completed))) из \(total)"
    }
}

/// Await delivery so a finished stage cannot overwrite a later UI stage.
public typealias FilmBuildProgressHandler = @Sendable (FilmBuildProgress) async -> Void

/// Carries the UI observer through nested rendering/repair calls without
/// changing the injectable prober protocol. Detached decode queues bridge
/// their updates through a bounded stream and drain it before returning.
public enum FilmBuildReporting {
    @TaskLocal public static var handler: FilmBuildProgressHandler?

    public static func report(_ update: FilmBuildProgress) async {
        await handler?(update)
    }

    static func forwarding<T: Sendable>(
        _ operation: (@escaping @Sendable (FilmBuildProgress) -> Void) async throws -> T
    ) async rethrows -> T {
        let (stream, continuation) = AsyncStream<FilmBuildProgress>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let observer = handler
        let consumer = Task {
            for await update in stream { await observer?(update) }
        }
        do {
            let result = try await operation { continuation.yield($0) }
            continuation.finish()
            await consumer.value
            return result
        } catch {
            continuation.finish()
            await consumer.value
            throw error
        }
    }
}

/// Counts every producer update while limiting UI delivery to 10 Hz. Stage
/// changes and terminal counts are never suppressed.
actor FilmBuildProgressRelay {
    private var stage: FilmBuildProgress.Stage?
    private var lastDelivery = -Double.infinity
    private var span: String?
    private let trace: PerformanceTrace?
    private let observer: FilmBuildProgressHandler?
    init(trace: PerformanceTrace?, observer: FilmBuildProgressHandler?) {
        self.trace = trace; self.observer = observer
    }
    func report(_ update: FilmBuildProgress) async {
        trace?.event("film.progress.requested", fields: ["stage": update.stage.rawValue])
        let changed = stage != update.stage
        if changed {
            if let stage { trace?.end(span, stage: "film.stage.\(stage.rawValue)") }
            stage = update.stage
            span = trace?.begin("film.stage.\(update.stage.rawValue)")
        }
        let now = ProcessInfo.processInfo.systemUptime
        let terminal = update.total.map { $0 > 0 && (update.completed ?? -1) >= $0 } ?? false
        guard changed || terminal || now - lastDelivery >= 0.1 else { return }
        lastDelivery = now
        trace?.event("film.progress.delivered", fields: ["stage": update.stage.rawValue])
        await observer?(update)
    }
    func finish(status: String) {
        if let stage { trace?.end(span, stage: "film.stage.\(stage.rawValue)", status: status) }
        stage = nil; span = nil
    }
}
