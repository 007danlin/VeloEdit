import Foundation
import Testing
@testable import VeloEditCore

@Suite struct SelectedSourceEvidenceRefreshTests {
    private static func observation(_ item: TimelineItem, asset: MediaAsset,
        status: ShotContentStatus = .usable) -> ShotContentAssessment {
        .init(itemID: item.id, assetID: asset.id, sourceContentHash: asset.contentHash,
            sourceStart: item.sourceStart, sourceDuration: item.sourceDuration,
            sampleTimes: [0.02, 0.25, 0.5, 0.75, 0.98].map { item.sourceStart + item.sourceDuration * $0 },
            phase: "source", model: "explicit-ordering-fixture", cacheKey: UUID().uuidString,
            status: status, confidence: 0.95, obstructedSamples: [],
            observation: "Visible person walking beside a river", activity: "continuous walking",
            editorialPurpose: "action", actionBoundary: .init(startObservation: "Person already walking",
                endObservation: "Person continues walking", followingObservation: "Person still walking",
                verdict: .continuous, confidence: 0.95))
    }

    private actor Reviewer: SelectedContentReviewing {
        private(set) var calls = 0
        private(set) var renderedCalls = 0
        func review(timeline: Timeline, assets: [MediaAsset], renderedURL: URL?,
            progress: FilmBuildProgressHandler?, pass: Int, reason: String?) async throws -> [ShotContentAssessment] {
            calls += 1
            if renderedURL != nil { renderedCalls += 1 }
            return timeline.items.map { item in
                SelectedSourceEvidenceRefreshTests.observation(item, asset: assets.first { $0.id == item.assetID }!)
            }
        }
    }

    private func fixture() -> (Timeline, MediaAsset, [ShotContentAssessment]) {
        let asset = MediaAsset(originalURL: URL(fileURLWithPath: "/tmp/source-refresh-synthetic.mov"),
            kind: .video, byteSize: 1, contentHash: "source-a", metadata: .init(duration: 20))
        let item = TimelineItem(assetID: asset.id, kind: .video, sourceStart: 2,
            sourceDuration: 4, timelineStart: 0, timelineDuration: 4)
        let timeline = Timeline(storyPlanID: UUID(), items: [item])
        return (timeline, asset, [Self.observation(item, asset: asset)])
    }

    @Test(arguments: ["start", "duration", "new-item", "source-hash", "incomplete", "wrong-phase"])
    func changedCutCannotFeedOldEvidenceToTitlesOrBecomeAnMP4Certificate(change: String) async throws {
        var (timeline, asset, saved) = fixture()
        switch change {
        case "start": timeline.items[0].sourceStart += 0.1
        case "duration": timeline.items[0].sourceDuration += 1; timeline.items[0].timelineDuration += 1
        case "new-item": timeline.items[0].id = UUID()
        case "source-hash": asset.contentHash = "source-b"
        case "incomplete": saved[0].sampleTimes = Array(saved[0].sampleTimes.prefix(3))
        case "wrong-phase": saved[0].phase = "mp4"
        default: Issue.record("Unknown scenario")
        }
        let reviewer = Reviewer()
        let refreshed = try await SelectedSourceEvidenceRefresh.reviewIfChanged(timeline: timeline,
            assets: [asset], observations: saved, reviewer: reviewer, progress: nil, pass: 1)
        #expect(await reviewer.calls == 1)
        #expect(await reviewer.renderedCalls == 0)
        #expect(refreshed.first?.certifies(item: timeline.items[0], phase: "source", assets: [asset]) == true)
        #expect(refreshed.first?.certifies(item: timeline.items[0], phase: "mp4", assets: [asset]) == false)
        let report = SelectedContentReviewReport(renderSignature: EditorialRenderSignature.signature(timeline),
            source: refreshed, rendered: [])
        #expect(!report.passes(timeline: timeline, assets: [asset]))
    }

    @Test(arguments: [ShotContentStatus.usable, .uncertain, .obstructed])
    func unchangedSourceIsNotQueriedAgainOrPromotedToSuccess(status: ShotContentStatus) async throws {
        var (timeline, asset, saved) = fixture()
        saved[0].status = status
        // Moving a cut on the output timeline does not change original pixels.
        timeline.items[0].timelineStart = 5
        let reviewer = Reviewer()
        let retained = try await SelectedSourceEvidenceRefresh.reviewIfChanged(timeline: timeline,
            assets: [asset], observations: saved, reviewer: reviewer, progress: nil, pass: 1)
        #expect(await reviewer.calls == 0)
        #expect(retained == saved)
        #expect(retained[0].certifies(item: timeline.items[0], phase: "source", assets: [asset]) == (status == .usable))
    }
}
