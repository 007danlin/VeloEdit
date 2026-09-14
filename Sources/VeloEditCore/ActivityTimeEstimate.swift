import Foundation

/// Estimates one processing stage from observed progress, independent of wall-clock changes.
public struct ActivityTimeEstimate {
    private var stage: String?
    private var startedAt: TimeInterval = 0
    private var initialFraction: Double = 0
    private var lastFraction: Double = 0
    private var completion: TimeInterval?

    public init() {}

    public mutating func observe(stage: String, fraction: Double, now: TimeInterval) -> TimeInterval? {
        guard fraction.isFinite, now.isFinite else { return nil }
        let fraction = min(1, max(0, fraction))
        if self.stage != stage || fraction < lastFraction {
            self.stage = stage
            startedAt = now
            initialFraction = fraction
            completion = nil
        }
        lastFraction = fraction
        guard fraction < 1 else {
            completion = nil
            return nil
        }
        let elapsed = now - startedAt
        let advanced = fraction - initialFraction
        guard elapsed >= 1.5, advanced >= 0.02 else { return nil }
        let measured = elapsed / advanced * (1 - fraction)
        guard measured.isFinite, measured > 0 else { return nil }
        // Smooth new observations, but allow corrections in either direction.
        let previous = completion.map { max(0, $0 - now) }
        let remaining = previous.map { $0 > 0 ? 0.65 * $0 + 0.35 * measured : measured } ?? measured
        completion = now + remaining
        return remaining
    }

    public static func label(secondsRemaining seconds: TimeInterval, wholeFilm: Bool = false) -> String {
        guard seconds.isFinite, seconds > 0 else { return "Уточняю время…" }
        let rounded = Int(min(seconds.rounded(.up), 31_536_000))
        let duration: String
        if rounded < 60 {
            duration = "\(rounded) с"
        } else {
            let minutes = rounded / 60
            let remainder = rounded % 60
            duration = minutes < 10 && remainder > 0 ? "\(minutes) мин \(remainder) с" : "\(minutes) мин"
        }
        return wholeFilm ? "Осталось ≈ \(duration)" : "До конца этапа ≈ \(duration)"
    }
}
