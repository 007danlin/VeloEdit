import Foundation
import Testing
@testable import VeloEditCore

@Suite struct SourceContinuationReviewTests {
    private func fixture() -> (Timeline, MediaAsset, StoryPlan, [PerceptualRenderedFrameEvidence]) {
        let asset = MediaAsset(originalURL: URL(fileURLWithPath: "/continuity.mov"), kind: .video,
            byteSize: 1, contentHash: "same-source", metadata: MediaMetadata(duration: 30, width: 3840, height: 2160))
        let first = TimelineItem(assetID: asset.id, kind: .video, sourceStart: 13.216666666666667,
            sourceDuration: 2.3, timelineStart: 0, timelineDuration: 2.3)
        let second = TimelineItem(assetID: asset.id, kind: .video, sourceStart: 15.516666666666667,
            sourceDuration: 1.866666666666667, timelineStart: 2.3, timelineDuration: 1.866666666666667,
            videoAdjustments: VideoAdjustments(crop: .fit))
        let plan = StoryPlan(prompt: "Спокойный фильм", preset: .story,
            constraints: StoryConstraints(targetDuration: 10, pacing: 0.4), chapters: [])
        let timeline = Timeline(storyPlanID: plan.id, items: [first, second])
        let frames = [0.5, 1.5, 2.6, 3.6].map { time in
            var frame = PerceptualRenderedFrameEvidence(timelineTime: time, meanLuma: 0.5,
                lumaDeviation: 0.2, perceptualHash: 17, isBlack: false)
            frame.decodeFailed = false
            frame.lumaFingerprint = [0.2, 0.5, 0.3, 0.7]
            return frame
        }
        return (timeline, asset, plan, frames)
    }

    @Test func storageSplitDoesNotDeleteContinuousSourceOrCertifyOtherDomains() throws {
        let (timeline, asset, plan, frames) = fixture()
        let before = EditorialLocalSemanticVerifier.claims(timeline: timeline, plan: plan, analyses: [], frames: frames, tracks: [])
        let after = EditorialLocalSemanticVerifier.claims(timeline: timeline, plan: plan, analyses: [], frames: frames, tracks: [], assets: [asset])
        let old = try #require(before.first { $0.domain == .visualNovelty })
        let new = try #require(after.first { $0.domain == .visualNovelty })
        #expect(old.status == .failed && old.finding?.kind == .hardDuplicate)
        #expect(new.status == .passed && new.finding == nil)
        #expect(new.itemIDs == timeline.items.map(\.id))
        #expect(new.probeTimes.count == 4)
        #expect(after.filter { $0.domain != .visualNovelty } == before.filter { $0.domain != .visualNovelty })
        #expect(after.first { $0.domain == .actionProgression }?.status == .failed)
        #expect(!EditorialQualityGate().review(timeline: timeline, plan: plan, analyses: [], renderedFrames: frames).productionEligible)
    }

    @Test(arguments: ["gap", "overlap", "repeat", "other-source", "freeze", "reverse", "speed", "duration",
                      "crop", "aspect", "stabilization", "brightness", "transition", "missing", "unknown-size"])
    func uncertainOrChangedContinuationStillGetsTheSameDuplicateCheck(_ change: String) throws {
        var (timeline, asset, plan, frames) = fixture()
        switch change {
        case "gap": timeline.items[1].sourceStart += 0.001
        case "overlap": timeline.items[1].sourceStart -= 0.001
        case "repeat": timeline.items[1].sourceStart = timeline.items[0].sourceStart
        case "other-source": timeline.items[1].assetID = UUID()
        case "freeze": timeline.items[1].freezeFrame = true
        case "reverse": timeline.items[1].reversePlayback = true
        case "speed": timeline.items[1].speed = 0.5
        case "duration": timeline.items[1].sourceDuration += 0.001
        case "crop": timeline.items[1].videoAdjustments?.rotationQuarterTurns = 1
        case "aspect": asset.metadata.width = 3839
        case "stabilization": timeline.items[1].videoAdjustments?.stabilization = 0.01
        case "brightness": timeline.items[1].videoAdjustments?.brightness = 0.00001
        case "transition": timeline.transitionItems = [TimelineTransitionItem(style: .crossDissolve,
            outgoingClipID: timeline.items[0].id, incomingClipID: timeline.items[1].id, startTime: 2.3)]
        case "missing": asset.missing = true
        case "unknown-size": asset.metadata.width = nil
        default: Issue.record("Unrecognized fixture")
        }
        #expect(!EditorialLocalSemanticVerifier.isUnchangedSourceContinuation(timeline.items[0], timeline.items[1], timeline: timeline, assets: [asset]))
        let claims = EditorialLocalSemanticVerifier.claims(timeline: timeline, plan: plan, analyses: [], frames: frames, tracks: [], assets: [asset])
        #expect(try #require(claims.first { $0.domain == .visualNovelty }).status == .failed)
    }

    @Test func continuationDoesNotHideARepeatedRangeAfterIt() throws {
        var (timeline, asset, plan, frames) = fixture()
        var repeated = timeline.items[1]
        repeated.id = UUID()
        repeated.timelineStart += repeated.timelineDuration
        timeline.items.append(repeated)
        for time in [4.5, 5.5] {
            var frame = frames[0]
            frame.timelineTime = time
            frames.append(frame)
        }
        let claims = EditorialLocalSemanticVerifier.claims(timeline: timeline, plan: plan, analyses: [], frames: frames, tracks: [], assets: [asset])
        let claim = try #require(claims.first { $0.domain == .visualNovelty })
        #expect(claim.status == .failed)
        #expect(claim.finding?.itemIDs == [repeated.id])
    }
}
