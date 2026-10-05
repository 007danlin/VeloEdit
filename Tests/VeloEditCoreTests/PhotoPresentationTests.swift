import CoreGraphics
import Foundation
import Testing
@testable import VeloEditCore

@Suite struct PhotoPresentationTests {
    private func fixture(width: Int = 5568, height: Int = 4872) -> (StoryPlan, Timeline, MediaAsset) {
        let plan = StoryPlan(prompt: "Фильм о поездке", preset: .cinematic,
            constraints: .init(targetDuration: 6), chapters: [])
        let asset = MediaAsset(originalURL: URL(fileURLWithPath: "/tmp/photo.jpg"), kind: .photo,
            byteSize: 1, contentHash: "photo", metadata: .init(width: width, height: height))
        let item = TimelineItem(assetID: asset.id, kind: .photo, sourceDuration: 6,
            timelineStart: 0, timelineDuration: 6, videoAdjustments: .init(crop: .fit))
        return (plan, Timeline(storyPlanID: plan.id, width: 1920, height: 1080, items: [item]), asset)
    }

    @Test func mismatchedPhotoGainsMovementWithoutChangingTimingOrAudio() {
        let (plan, source, asset) = fixture()
        let result = PhotoPresentationPolicy.applying(to: source, plan: plan, assets: [asset], analyses: [])
        #expect(result.items[0].effect == ClipEffect.kenBurns.rawValue)
        #expect(result.items[0].effectiveVideoAdjustments.crop == .fill)
        var comparison = result
        comparison.items[0].effect = source.items[0].effect
        comparison.items[0].videoAdjustments = source.items[0].videoAdjustments
        comparison.items[0].explanation = source.items[0].explanation
        #expect(comparison == source)
        #expect(PhotoPresentationPolicy.applying(to: result, plan: plan, assets: [asset], analyses: []) == result)
    }

    @Test func explicitNoEffectsAndExistingChoicesAreRespected() {
        var (plan, source, asset) = fixture()
        plan.prompt = "Без эффектов"
        #expect(PhotoPresentationPolicy.applying(to: source, plan: plan, assets: [asset], analyses: []) == source)
        plan.prompt = "Поездка"
        source.items[0].locked = true
        #expect(PhotoPresentationPolicy.applying(to: source, plan: plan, assets: [asset], analyses: []) == source)
        source.items[0].locked = false
        source.items[0].effect = ClipEffect.panLeft.rawValue
        #expect(PhotoPresentationPolicy.applying(to: source, plan: plan, assets: [asset], analyses: []) == source)
        source.items[0].effect = ClipEffect.zoomIn.rawValue
        source.items[0].videoAdjustments = .init(crop: .fill, subjectReframe: .init(
            startCenterX: 0.5, startCenterY: 0.5, endCenterX: 0.5, endCenterY: 0.5,
            startScale: 1, endScale: 1, targetAspectRatio: 16.0 / 9.0, confidence: 0.95))
        #expect(PhotoPresentationPolicy.applying(to: source, plan: plan, assets: [asset], analyses: []) == source)
        let (matchingPlan, matching, matchingAsset) = fixture(width: 1920, height: 1080)
        #expect(PhotoPresentationPolicy.applying(to: matching, plan: matchingPlan, assets: [matchingAsset], analyses: []) == matching)
    }

    @Test func aGroupThatCannotFitRetainsFullPhoto() {
        let (plan, original, asset) = fixture(width: 1920, height: 1080)
        let region = NormalizedRegion(x: 0.15, y: 0.2, width: 0.7, height: 0.6)
        let track = SubjectTrack(kind: .person, label: "group", observations: [
            .init(timestamp: 0, region: region, confidence: 0.95),
            .init(timestamp: 6, region: region, confidence: 0.95)
        ], meanConfidence: 0.95, visibility: 1, compositionQuality: 0.9)
        let tracking = SubjectTrackingSummary(tracks: [track], mainSubjectID: track.id,
            confidence: 0.95, analyzedFrameCount: 2)
        let candidate = Candidate(assetID: asset.id, sourceStart: 0, sourceDuration: 6,
            scores: .init(quality: 0.9, interest: 0.9, action: 0, stability: 1),
            insights: .init(subjectTracking: tracking))
        var source = original
        source.width = 1080
        source.height = 1920
        source.items[0].candidateID = candidate.id
        let result = PhotoPresentationPolicy.applying(to: source, plan: plan, assets: [asset],
            analyses: [.init(assetID: asset.id, analyzedContentHash: asset.contentHash, candidates: [candidate])])
        #expect(result == source)
    }

    @Test func broadSaliencyUsesAnchoredZoomWhileCompactRegionKeepsApprovedMotion() {
        let (plan, original, asset) = fixture()
        // Real failure: a crouching person was only labelled salient-object;
        // the region spans more height than a landscape viewport can retain.
        for height in [0.72, 0.60] {
            let track = SubjectTrack(kind: .salientObject, label: "salient-object", observations: [
                .init(timestamp: 0, region: .init(x: 0.08, y: 0.22, width: 0.8, height: height), confidence: 0.7)
            ], meanConfidence: 0.7, visibility: 0.8, compositionQuality: 0.6)
            let tracking = SubjectTrackingSummary(tracks: [track], mainSubjectID: track.id,
                confidence: 0.7, analyzedFrameCount: 1)
            let candidate = Candidate(assetID: asset.id, sourceStart: 0, sourceDuration: 6,
                scores: .init(quality: 0.8, interest: 0.8, action: 0, stability: 1),
                insights: .init(subjectTracking: tracking))
            var source = original
            source.items[0].candidateID = candidate.id
            let result = PhotoPresentationPolicy.applying(to: source, plan: plan, assets: [asset],
                analyses: [.init(assetID: asset.id, analyzedContentHash: asset.contentHash, candidates: [candidate])])
            #expect(result.items[0].effect == ClipEffect.kenBurns.rawValue)
            #expect(result.items[0].effectiveVideoAdjustments.crop == .fill)
            if height > 0.7 {
                let framing = result.items[0].effectiveVideoAdjustments.subjectReframe
                #expect(framing != nil)
                #expect(framing?.startCenterY == framing?.endCenterY)
                #expect(framing?.safetyReport == nil) // not semantic detection
            } else { #expect(result.items[0].effectiveVideoAdjustments.subjectReframe == nil) }
        }
    }

    @Test func anchoredCropRetainsTheObservedUpperSubjectAndHasContinuousEdges() throws {
        // A geometry regression from a real photo. This region is an independently
        // observed person, not a pretend Vision result or an app-specific asset ID.
        let region = NormalizedRegion(x: 0, y: 0.227, width: 0.873, height: 0.719)
        let track = SubjectTrack(kind: .salientObject, label: "saliency", observations: [
            .init(timestamp: 0, region: region, confidence: 0.68)
        ], meanConfidence: 0.68, visibility: 0.8, compositionQuality: 0.6)
        let tracking = SubjectTrackingSummary(tracks: [track], mainSubjectID: track.id,
            confidence: 0.68, analyzedFrameCount: 1)
        let plan = try #require(PhotoPresentationPolicy.anchoredZoom(tracking: tracking,
            sourceAspect: 5568.0 / 4872, targetAspect: 16.0 / 9, duration: 149.0 / 30))
        let source = CGRect(x: 0, y: 0, width: 5568, height: 4872)
        let subject = CGRect(x: 0.35 * 5568, y: 0.60 * 4872, width: 0.11 * 5568, height: 0.16 * 4872)
        var previous: (scale: CGFloat, x: CGFloat, y: CGFloat)?
        for i in 0..<149 {
            let p = CGFloat(i) / 148
            let placement = StillImageRenderGeometry.placement(sourceExtent: source, targetSize: .init(width: 1920, height: 1080),
                motionScale: 1, horizontalTravel: 0, verticalTravel: 0, subjectReframe: plan, progress: p)
            #expect(placement.x <= 0.001 && placement.y <= 0.001)
            #expect(placement.x + source.width * placement.scale >= 1919.999)
            #expect(placement.y + source.height * placement.scale >= 1079.999)
            let visible = subject.applying(CGAffineTransform(scaleX: placement.scale, y: placement.scale))
                .offsetBy(dx: placement.x, dy: placement.y)
            #expect(CGRect(x: 0, y: 0, width: 1920, height: 1080).contains(visible))
            if let previous {
                #expect(abs(placement.x - previous.x) < 1 && abs(placement.y - previous.y) < 1)
            }
            previous = placement
        }
    }

    @Test func motionFollowsAvailableImageAxisAndNeverExposesCanvas() {
        let target = CGSize(width: 1920, height: 1080)
        for source in [CGSize(width: 5568, height: 4872), CGSize(width: 6000, height: 2000)] {
            let first = StillImageRenderGeometry.kenBurnsMotion(source: source, target: target, progress: 0, duration: 5.433333)
            let last = StillImageRenderGeometry.kenBurnsMotion(source: source, target: target, progress: 1, duration: 5.433333)
            if source.height > 4000 { #expect(first.x == 0 && last.x == 0 && first.y > last.y + 100) }
            else { #expect(first.y == 0 && last.y == 0 && first.x > last.x + 100) }
            for i in 0...163 {
                let p = CGFloat(i) / 163
                let move = StillImageRenderGeometry.kenBurnsMotion(source: source, target: target, progress: p, duration: 5.433333)
                let placement = StillImageRenderGeometry.placement(sourceExtent: CGRect(origin: .zero, size: source),
                    targetSize: target, motionScale: move.scale, horizontalTravel: move.x, verticalTravel: move.y,
                    subjectReframe: nil, progress: p)
                #expect(placement.x <= 0.001 && placement.y <= 0.001)
                #expect(placement.x + source.width * placement.scale >= target.width - 0.001)
                #expect(placement.y + source.height * placement.scale >= target.height - 0.001)
            }
            let early = StillImageRenderGeometry.kenBurnsMotion(source: source, target: target, progress: 1.0 / 163, duration: 5.433333)
            #expect(abs(early.x - first.x) + abs(early.y - first.y) < 0.1)
        }
    }
}

/// Explicit study replay uses a complete development copy, never original projects.
@Test(.enabled(if: ProcessInfo.processInfo.environment["VELOEDIT_PHOTO_PRESENTATION_STUDY"] != nil))
func replayPhotoPresentationOnSavedDevelopmentEdit() throws {
    let package = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["VELOEDIT_PHOTO_PRESENTATION_STUDY"]))
    try #require(FileManager.default.fileExists(atPath: package.appendingPathComponent("study-input.json").path))
    let file = package.appendingPathComponent("project.json")
    var project = try JSONDecoder.veloEdit.decode(ProjectManifest.self, from: Data(contentsOf: file))
    let source = try #require(project.timelines.last)
    let plan = try #require(project.storyPlans.first { $0.id == source.storyPlanID })
    var revised = PhotoPresentationPolicy.applying(to: source, plan: plan, assets: project.assets, analyses: project.analyses)
    struct Change: Codable { var itemID: UUID; var assetID: UUID?; var time: Double; var duration: Double; var effectBefore: String?; var effectAfter: String? }
    var changes: [Change] = []
    for (before, after) in zip(source.items, revised.items) where before != after {
        #expect(before.kind == .photo)
        var comparison = after
        comparison.videoAdjustments = before.videoAdjustments
        comparison.effect = before.effect
        comparison.explanation = before.explanation
        #expect(comparison == before)
        changes.append(.init(itemID: before.id, assetID: before.assetID, time: before.timelineStart,
            duration: before.timelineDuration, effectBefore: before.effect, effectAfter: after.effect))
    }
    var comparison = revised
    comparison.items = source.items
    #expect(comparison == source)
    try #require(!changes.isEmpty)
    revised.id = UUID()
    revised.versionName = "Ken Burns — непрерывный музыкальный фрагмент"
    revised.editorialReview = nil
    revised.filmDeliveryReport = nil
    project.timelines.append(revised)
    try JSONEncoder.veloEdit.encode(project).write(to: file, options: .atomic)
    try JSONEncoder.veloEdit.encode(changes).write(to: package.appendingPathComponent("photo-presentation-changes.json"), options: .atomic)
}
