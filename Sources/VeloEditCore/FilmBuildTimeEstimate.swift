import Foundation

/// Estimates the work still queued, rather than extrapolating the UI's milestone percentage.
/// Initial budgets are workload heuristics; completed runs calibrate them for this Mac.
public struct FilmBuildTimeEstimate {
    public enum Step: String, CaseIterable {
        case request, analysis, preparing, evidence, moments, planning
        case findingMusic, analyzingMusic, assembling, reviewing, fallback
        case finishing, soundtrack, verifying, saving, commands, playback
    }

    private struct Work {
        var startedAt: TimeInterval
        var budget: TimeInterval
        var fraction: Double?
        var total: Int?
        var pace = ActivityTimeEstimate()
        var measuredCompletion: TimeInterval?
        var suppliedCompletion: TimeInterval?

        mutating func update(fraction: Double?, total: Int?, eta: TimeInterval?, now: TimeInterval) {
            if let fraction, fraction.isFinite {
                if self.total != total || fraction < (self.fraction ?? 0) {
                    pace = ActivityTimeEstimate()
                    startedAt = now
                    measuredCompletion = nil
                    suppliedCompletion = nil
                }
                self.fraction = min(1, max(0, fraction))
                self.total = total
                if self.fraction == 1 {
                    measuredCompletion = nil
                    suppliedCompletion = nil
                }
                if let remaining = pace.observe(stage: "work", fraction: self.fraction!, now: now) {
                    measuredCompletion = now + remaining
                }
            }
            if self.fraction != 1, let eta, eta.isFinite, eta > 0 { suppliedCompletion = now + eta }
        }

        mutating func remaining(now: TimeInterval) -> TimeInterval {
            if let completion = suppliedCompletion, completion > now { return completion - now }
            if let completion = measuredCompletion, completion - now > 2 { return completion - now }
            let elapsed = max(0, now - startedAt)
            if let fraction, fraction < 1,
               let measured = pace.observe(stage: "work", fraction: fraction, now: now) {
                measuredCompletion = now + measured
                return max(2, measured)
            }
            // An unfinished operation must not count down to zero or stay at one second.
            // Sparse/network operations retain a reserve and revise it when overdue.
            if fraction == 1 { return max(2, min(10, elapsed * 0.05)) }
            return max(3, budget - elapsed, min(budget, max(budget * 0.15, (elapsed - budget) * 0.25)))
        }
    }

    private let budgets: [Step: TimeInterval]
    private var calibration: [String: Double]
    private var step: Step = .request
    private var stepStartedAt: TimeInterval
    private var work: Work
    private var childStage: FilmBuildProgress.Stage?
    private var child: Work?
    private var isFinished = false

    public init(
        sourceSeconds: Double, assetCount: Int, filmSeconds: Double,
        needsAnalysis: Bool, includesMusic: Bool,
        calibration: [String: Double] = [:], now: TimeInterval
    ) {
        let source = sourceSeconds.isFinite ? max(0, sourceSeconds) : 0
        let film = filmSeconds.isFinite ? max(10, filmSeconds) : 120
        let assets = Double(max(1, assetCount))
        budgets = [
            .request: 8, .analysis: needsAnalysis ? max(10, source * 0.3 + assets * 4) : 0,
            .preparing: 2, .evidence: max(5, assets * 0.8), .moments: max(5, source * 0.04),
            .planning: max(3, assets * 0.3), .findingMusic: includesMusic ? 45 : 0,
            .analyzingMusic: includesMusic ? 15 : 0, .assembling: max(8, film * 0.12),
            .reviewing: max(10, film * 0.25), .fallback: 0,
            .finishing: max(10, film * 0.2), .soundtrack: includesMusic ? max(5, film * 0.05) : 0,
            .verifying: max(30, film * 1.6), .saving: 3,
            .commands: max(3, film * 0.025), .playback: max(5, film * 0.1)
        ]
        self.calibration = calibration.filter { $0.value.isFinite && $0.value > 0 }
        stepStartedAt = now
        work = Work(startedAt: now, budget: 8 * min(20, max(0.1, self.calibration[Step.request.rawValue] ?? 1)))
    }

    /// Explicit app boundaries also cover initial analysis, editor commands and preview setup.
    public mutating func begin(_ next: Step, now: TimeInterval) {
        guard !isFinished, now.isFinite, next != step else { return }
        recordCompletedStep(now: now)
        step = next
        stepStartedAt = now
        work = Work(startedAt: now, budget: max(3, budget(for: next)))
        child = nil
        childStage = nil
    }

    public mutating func observe(_ update: FilmBuildProgress, now: TimeInterval) {
        guard !isFinished, now.isFinite else { return }
        if let next = Step(rawValue: update.stage.rawValue) {
            begin(next, now: now)
            child = nil
            childStage = nil
            work.update(fraction: update.fraction, total: update.total, eta: nil, now: now)
        } else if Self.verificationStages.contains(update.stage) {
            // Render callbacks are nested inside a variant review, finishing or verification.
            // They must not mark all preceding variants/parent operations as finished.
            if childStage != update.stage {
                childStage = update.stage
                child = Work(startedAt: now, budget: childBudget(for: update.stage))
            }
            child?.update(fraction: update.fraction, total: update.total, eta: nil, now: now)
        }
    }

    public mutating func observe(
        step: Step, fraction: Double, total: Int, secondsRemaining: TimeInterval?, now: TimeInterval
    ) {
        // Import/playback callbacks may already be queued on the UI actor when
        // the awaited operation advances. Do not resurrect a finished phase.
        guard let incoming = Step.allCases.firstIndex(of: step),
              let current = Step.allCases.firstIndex(of: self.step), incoming >= current else { return }
        begin(step, now: now)
        guard !isFinished, now.isFinite else { return }
        work.update(fraction: fraction, total: total, eta: secondsRemaining, now: now)
    }

    public mutating func remaining(now: TimeInterval) -> TimeInterval {
        guard !isFinished, now.isFinite else { return 0 }
        var current = work.remaining(now: now)
        if let stage = childStage, var nested = child {
            let nestedRemaining = nested.remaining(now: now)
            child = nested
            if step == .verifying, let index = Self.verificationStages.firstIndex(of: stage) {
                current = nestedRemaining + Self.verificationStages.dropFirst(index + 1)
                    .reduce(0) { $0 + childBudget(for: $1) }
            } else if (step == .reviewing || step == .fallback),
                      let total = work.total, total > 0, let fraction = work.fraction {
                let queued = max(0, Double(total) * (1 - fraction) - 1)
                let perVariant = max(work.budget / Double(total), now - nested.startedAt + nestedRemaining)
                current = nestedRemaining + queued * perVariant
            } else {
                current = max(current, nestedRemaining)
            }
        }
        let later = Step.allCases.drop { $0 != step }.dropFirst()
        return current + later.reduce(0) { $0 + budget(for: $1) }
    }

    /// Only persist these measurements after the entire operation succeeds.
    public mutating func finish(now: TimeInterval) -> [String: Double] {
        guard !isFinished else { return calibration }
        recordCompletedStep(now: now)
        isFinished = true
        return calibration
    }

    private func budget(for step: Step) -> TimeInterval {
        let base = step == .fallback ? (self.step == .fallback ? budgets[.reviewing, default: 10] : 0)
            : budgets[step, default: 0]
        return base * min(20, max(0.1, calibration[step.rawValue] ?? 1))
    }

    private mutating func recordCompletedStep(now: TimeInterval) {
        let base = budgets[step, default: 0]
        let elapsed = now - stepStartedAt
        guard base > 0, elapsed.isFinite, elapsed >= 1 else { return }
        let sample = min(20, max(0.1, elapsed / base))
        calibration[step.rawValue] = calibration[step.rawValue].map { 0.65 * $0 + 0.35 * sample } ?? sample
    }

    private static let verificationStages: [FilmBuildProgress.Stage] = [
        .previewFrames, .controlExport, .deliveryFrames, .audioCheck
    ]

    private func childBudget(for stage: FilmBuildProgress.Stage) -> TimeInterval {
        let share: Double
        switch stage {
        case .analysis: share = 1
        case .previewFrames: share = 0.20
        case .controlExport: share = 0.60
        case .deliveryFrames: share = 0.15
        case .audioCheck: share = 0.05
        default: share = 1
        }
        return max(3, budget(for: .verifying) * share)
    }
}
