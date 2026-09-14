import Foundation
import Testing
@testable import VeloEditCore

private func buildEstimate(calibration: [String: Double] = [:]) -> FilmBuildTimeEstimate {
    FilmBuildTimeEstimate(sourceSeconds: 600, assetCount: 10, filmSeconds: 120,
                         needsAnalysis: true, includesMusic: true, calibration: calibration, now: 0)
}

@Test func filmBuildEstimateIncludesWorkAfterAnalysis() {
    var estimate = buildEstimate()
    estimate.observe(step: .analysis, fraction: 0.5, total: 100, secondsRemaining: 30, now: 10)
    let duringAnalysis = estimate.remaining(now: 10)
    #expect(duringAnalysis > 30 + 120) // Assembly, verification and preview are still queued.
    #expect(abs(estimate.remaining(now: 15) - (duringAnalysis - 5)) < 0.01)
    estimate.observe(.init(.preparing), now: 20)
    #expect(abs(estimate.remaining(now: 20) - (duringAnalysis - 30)) < 2)
    let preparing = estimate.remaining(now: 20)
    estimate.observe(step: .analysis, fraction: 1, total: 100, secondsRemaining: 0, now: 21)
    #expect(estimate.remaining(now: 21) <= preparing) // A late callback cannot restart analysis.
}

@Test func filmBuildEstimateTracksControlExportPaceAndSlowdowns() {
    var estimate = buildEstimate()
    estimate.observe(.init(.verifying), now: 10)
    estimate.observe(.init(.controlExport, completed: 0, total: 100), now: 10)
    estimate.observe(.init(.controlExport, completed: 20, total: 100), now: 30)
    let first = estimate.remaining(now: 30)
    #expect(first > 80) // Includes delivery frames, audio, saving, commands and preview.
    #expect(abs(estimate.remaining(now: 35) - (first - 5)) < 0.01)
    estimate.observe(.init(.controlExport, completed: 40, total: 100), now: 50)
    #expect(estimate.remaining(now: 50) < first)
    let overdue = estimate.remaining(now: 250) // No callback while the encoder stalls.
    #expect(overdue > first)
    #expect(overdue.isFinite)
}

@Test func filmBuildEstimateNestedFramesDoNotSkipRemainingVariants() {
    var firstVariant = buildEstimate()
    var lastVariant = buildEstimate()
    firstVariant.observe(.init(.reviewing, completed: 0, total: 3), now: 10)
    lastVariant.observe(.init(.reviewing, completed: 2, total: 3), now: 10)
    for update in [FilmBuildProgress(.previewFrames, completed: 0, total: 100),
                   FilmBuildProgress(.previewFrames, completed: 50, total: 100)] {
        let now: Double = update.completed == 0 ? 10 : 30
        firstVariant.observe(update, now: now)
        lastVariant.observe(update, now: now)
    }
    #expect(firstVariant.remaining(now: 30) > lastVariant.remaining(now: 30) + 60)
    firstVariant.observe(.init(.reviewing, completed: 1, total: 3), now: 50)
    firstVariant.observe(.init(.previewFrames, completed: 0, total: 80), now: 50)
    #expect(firstVariant.remaining(now: 51) > lastVariant.remaining(now: 51))
}

@Test func filmBuildEstimateRevisesUnmeasuredWorkInsteadOfExpiring() {
    var estimate = buildEstimate()
    estimate.observe(.init(.findingMusic), now: 10)
    let nearDeadline = estimate.remaining(now: 50)
    let delayed = estimate.remaining(now: 300)
    #expect(delayed > nearDeadline)
    estimate.begin(.playback, now: 310)
    #expect(estimate.remaining(now: 1_000) >= 3)
    _ = estimate.finish(now: 1_001)
    #expect(estimate.remaining(now: 1_002) == 0)
}

@Test func filmBuildEstimateHandlesExportSetupAndRestartedVerification() {
    var estimate = buildEstimate()
    estimate.observe(.init(.verifying), now: 10)
    estimate.observe(.init(.controlExport, completed: 0, total: 1), now: 10)
    estimate.observe(.init(.controlExport, completed: 12, total: 12), now: 12)
    estimate.observe(.init(.controlExport, completed: 0, total: 100), now: 13)
    estimate.observe(.init(.controlExport, completed: 50, total: 100), now: 33)
    let halfway = estimate.remaining(now: 33)
    // The mux detail does not discard measured encoder progress.
    estimate.observe(.init(.controlExport, detail: "Соединяю готовое видео и звук"), now: 34)
    #expect(estimate.remaining(now: 34) < halfway + 10)
    estimate.observe(.init(.audioCheck, completed: 100, total: 100), now: 60)
    let beforeRepair = estimate.remaining(now: 60)
    estimate.observe(.init(.previewFrames, completed: 0, total: 100), now: 61)
    #expect(estimate.remaining(now: 61) > beforeRepair)
    estimate.observe(.init(.saving), now: 62)
    #expect(estimate.remaining(now: 62) > 3) // Commands and playback remain.
}

@Test func filmBuildEstimateLearnsCompletedWorkAndSupportsResume() {
    var learned = buildEstimate()
    learned.observe(.init(.verifying), now: 10)
    learned.observe(.init(.saving), now: 394) // Twice the initial verification budget.
    let calibration = learned.finish(now: 397)
    #expect(abs((calibration["verifying"] ?? 0) - 2) < 0.01)
    var next = buildEstimate(calibration: calibration)
    var fresh = buildEstimate()
    next.observe(.init(.verifying), now: 0)
    fresh.observe(.init(.verifying), now: 0)
    #expect(next.remaining(now: 0) > fresh.remaining(now: 0) + 150)
    next.begin(.finishing, now: 10)
    next.observe(.init(.resuming), now: 10)
    let resumed = next.remaining(now: 10)
    next.observe(.init(.saving), now: 20)
    #expect(next.remaining(now: 20) < resumed)
}

@Test func filmBuildEstimateColdStartUsesWorkloadAndHandlesInvalidHistory() {
    var small = FilmBuildTimeEstimate(sourceSeconds: 20, assetCount: 1, filmSeconds: 10,
                                     needsAnalysis: false, includesMusic: false, now: 0)
    var large = buildEstimate()
    #expect(large.remaining(now: 0) > small.remaining(now: 0))
    var invalid = buildEstimate(calibration: ["request": .nan, "verifying": .infinity, "saving": -1])
    #expect(invalid.remaining(now: 0).isFinite)
    #expect(ActivityTimeEstimate.label(secondsRemaining: 75, wholeFilm: true) == "Осталось ≈ 1 мин 15 с")
}
