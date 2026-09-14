import Foundation

/// Product-wide minimum for generated films, independent of a source's
/// measured capacity or the editable durations of individual clips.
public enum AutomaticFilmDurationPolicy {
    public static let minimumDuration = 10.0

    public static func normalizedRequest(_ seconds: Double) -> Double {
        seconds.isFinite ? max(minimumDuration, seconds) : minimumDuration
    }

    public static func renderedDuration(of timeline: Timeline) -> Double {
        TimelineTiming.playbackTime(forTimelineTime: timeline.duration, timeline: timeline)
    }

    public static func meetsMinimum(_ timeline: Timeline) -> Bool {
        let duration = renderedDuration(of: timeline)
        // Floating-point tolerance only; a whole missing frame is not a pass.
        return duration.isFinite && duration + 0.000_001 >= minimumDuration
    }

    public static func failureMessage(for timeline: Timeline) -> String {
        let actual = renderedDuration(of: timeline)
        let detail = actual.isFinite ? String(format: "%.2f с", actual) : "не определена"
        return "Минимальная длительность фильма — 10 секунд. После переходов получилось \(detail). Добавьте материал или увеличьте длительность монтажа."
    }

    public static func validate(_ timeline: Timeline) throws {
        guard meetsMinimum(timeline) else {
            throw EditorialGenerationError.unsatisfiedIntent(failureMessage(for: timeline))
        }
    }
}
