import Foundation
import Testing
@testable import VeloEditCore

@Test func activityEstimateRevisesSlowerProgress() {
    var estimate = ActivityTimeEstimate()
    #expect(estimate.observe(stage: "export", fraction: 0, now: 0) == nil)
    let first = estimate.observe(stage: "export", fraction: 0.2, now: 10)
    #expect(abs((first ?? 0) - 40) < 0.001)
    let slower = estimate.observe(stage: "export", fraction: 0.3, now: 50)
    #expect((slower ?? 0) > 100)
}

@Test func activityEstimateDoesNotCarryTimingAcrossStages() {
    var estimate = ActivityTimeEstimate()
    _ = estimate.observe(stage: "import", fraction: 0, now: 0)
    _ = estimate.observe(stage: "import", fraction: 0.9, now: 90)
    #expect(estimate.observe(stage: "preview", fraction: 0.1, now: 100) == nil)
    let preview = estimate.observe(stage: "preview", fraction: 0.3, now: 102)
    #expect(abs((preview ?? 0) - 7) < 0.001)
    #expect(estimate.observe(stage: "preview", fraction: 1, now: 110) == nil)
}

@Test func activityEstimateWaitsForMeasuredWorkAndResetsOnRestart() {
    var estimate = ActivityTimeEstimate()
    #expect(estimate.observe(stage: "export", fraction: 0.5, now: 0) == nil)
    #expect(estimate.observe(stage: "export", fraction: 0.5, now: 50) == nil)
    #expect(estimate.observe(stage: "export", fraction: 0.7, now: 51) != nil)
    #expect(estimate.observe(stage: "export", fraction: 0.1, now: 52) == nil)
}

@Test func activityEstimateLabelsExpiredForecastWithoutFalseOneSecond() {
    #expect(ActivityTimeEstimate.label(secondsRemaining: 0) == "Уточняю время…")
    #expect(ActivityTimeEstimate.label(secondsRemaining: -30) == "Уточняю время…")
    #expect(ActivityTimeEstimate.label(secondsRemaining: .infinity) == "Уточняю время…")
    #expect(ActivityTimeEstimate.label(secondsRemaining: 60.1) == "До конца этапа ≈ 1 мин 1 с")
}

@Test func analysisEstimateRecoversAfterForecastExpires() async {
    let eta = AnalysisETAEngine()
    let start = Date(timeIntervalSinceReferenceDate: 1_000)
    await eta.startFile(now: start)
    _ = await eta.estimate(fileFraction: 0.4, fileIndex: 0, totalFiles: 2,
                           fallbackSecondsPerFile: 10, now: start.addingTimeInterval(4))
    let overdue = await eta.estimate(fileFraction: 0.5, fileIndex: 0, totalFiles: 2,
                                     fallbackSecondsPerFile: 10, now: start.addingTimeInterval(100))
    #expect((overdue ?? 0) > 10)
    let finished = await eta.estimate(fileFraction: 1, fileIndex: 1, totalFiles: 2,
                                      fallbackSecondsPerFile: 10, now: start.addingTimeInterval(110))
    #expect(finished == 0)
}

@Test func analysisEstimateCorrectsOptimisticCountdownBeforeExpiry() async {
    let eta = AnalysisETAEngine()
    let start = Date(timeIntervalSinceReferenceDate: 2_000)
    await eta.startFile(now: start)
    let first = await eta.estimate(fileFraction: 0.4, fileIndex: 0, totalFiles: 1,
                                   fallbackSecondsPerFile: 100, now: start.addingTimeInterval(10))
    let slower = await eta.estimate(fileFraction: 0.4, fileIndex: 0, totalFiles: 1,
                                    fallbackSecondsPerFile: 100, now: start.addingTimeInterval(40))
    #expect((slower ?? 0) > (first ?? 0) - 30)
}
