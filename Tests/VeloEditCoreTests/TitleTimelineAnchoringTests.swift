import Foundation
import Testing
import CoreMedia
@testable import VeloEditCore

@Suite struct TitleTimelineAnchoringTests {
    @Test func generatedHeadingFollowsItsClipAndKeepsReadingDurationAcrossSceneCuts() throws {
        let scene = UUID()
        let clips = TimelineTiming.retimed((0..<3).map { _ in
            TimelineItem(assetID: UUID(), kind: .video, sourceDuration: 4, timelineStart: 0,
                         timelineDuration: 4, eventSceneID: scene)
        })
        let title = TitleTimelineItem(kind: .chapter, text: "День 4 — Велопрогулка — 20 июля 2026",
            startTime: 9, duration: 6, targetClipID: clips[1].id,
            explanation: ["Автоматическая глава события"])
        let original = Timeline(storyPlanID: UUID(), items: clips, titleItems: [title])
        let repaired = TitleTimelineAnchoring.reconcile(original)
        let fixed = try #require(repaired.titleItems?.first)
        #expect(fixed.startTime == 4 && fixed.duration == 6)
        #expect(fixed.targetClipID == nil && fixed.anchorClipID == clips[1].id)
        #expect(repaired.items == original.items)
        #expect(TitleTimelineAnchoring.reconcile(repaired) == repaired)
        var moved = repaired
        #expect(TimelineMutationEngine.updateItem(in: &moved, id: clips[0].id) { $0.timelineDuration = 2; $0.sourceDuration = 2 })
        #expect(moved.titleItems?.first?.startTime == 2)
        #expect(moved.titleItems?.first?.duration == 6)
        let reopened = try JSONDecoder.veloEdit.decode(Timeline.self, from: JSONEncoder.veloEdit.encode(moved))
        #expect(reopened.titleItems?.first?.effectiveAnchorClipID == clips[1].id)
    }

    @Test func generatedHeadingDoesNotCrossIntoDifferentSceneAndManualTextIsNotRewritten() throws {
        let first = TimelineItem(assetID: UUID(), kind: .video, sourceDuration: 4, timelineStart: 0,
            timelineDuration: 4, eventSceneID: UUID())
        let second = TimelineItem(assetID: UUID(), kind: .video, sourceDuration: 4, timelineStart: 4,
            timelineDuration: 4, eventSceneID: UUID())
        let automatic = TitleTimelineItem(kind: .chapter, text: "Лесная дорога", startTime: 2, duration: 6,
            targetClipID: first.id, explanation: ["Автоматическая глава события"])
        var manual = automatic; manual.id = UUID(); manual.userEdited = true
        let source = Timeline(storyPlanID: UUID(), items: [first, second], titleItems: [automatic, manual])
        let fixed = TitleTimelineAnchoring.reconcile(source)
        #expect(fixed.titleItems?.first?.startTime == 0)
        #expect(fixed.titleItems?.first?.duration == 4)
        #expect(fixed.titleItems?.last == manual)
    }
}

@Test func paritySamplesStayOnTheDeliveryCadenceIncludingFractionalRates() {
    for fps in [24.0, 30, 60, 30_000.0 / 1001] {
        let step = VideoFrameTiming.duration(for: fps)
        for frame in [0, 1, 20_030, 50_000] {
            let exact = CMTime(value: Int64(frame) * step.value, timescale: step.timescale)
            let sampled = VideoFrameTiming.sampleTime(for: exact.seconds + step.seconds * 0.5, frameRate: fps, duration: 10_000)
            #expect(sampled == exact)
        }
    }
    #expect(VideoFrameTiming.sampleTime(for: 667.7166666667, frameRate: 30, duration: 1_000) == CMTime(value: 20_031, timescale: 30))
    let mismatched = EditorialExportProbeComparison(time: 2, decoded: true, hashDistance: 0,
        meanLumaDifference: 0, meanAbsolutePixelDifference: 0, previewPTS: 2, exportPTS: 2 + 1 / 30.0)
    #expect(!mismatched.passed)
}
