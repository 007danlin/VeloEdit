import Foundation
import Testing
@testable import VeloEditCore

@Suite(.serialized)
struct FilmContentDeliveryGateTests {
    /// Only the content-review ordering is synthetic. Playback opens real media.
    private actor ExportProbe: EditorialRenderedProbing {
        var calls = 0
        func frames(timeline: Timeline, assets: [MediaAsset], tracks: [LocalMusicTrack], telemetry: [UUID: TelemetrySummary], cacheURL: URL) async throws -> [PerceptualRenderedFrameEvidence] {
            calls += 1
            var frames = try await FixtureEditorialProber().frames(timeline: timeline, assets: assets, tracks: tracks, telemetry: telemetry, cacheURL: cacheURL)
            let url = assets[0].originalURL
            let info = try FileManager.default.attributesOfItem(atPath: url.path)
            frames[0].exportVerification?.outputURL = url
            frames[0].exportVerification?.fileSize = (info[.size] as? NSNumber)?.int64Value
            frames[0].exportVerification?.fileModified = info[.modificationDate] as? Date
            frames[0].exportVerification?.videoDuration = timeline.duration
            return frames
        }
    }

    private actor Reviewer: SelectedContentReviewing {
        var phases: [String] = []
        var permits: Set<String> = []
        let blockedPhase: String?
        let result: ShotContentStatus
        let fails: Bool
        init(blockedPhase: String? = nil, result: ShotContentStatus = .usable, fails: Bool = false) {
            self.blockedPhase = blockedPhase; self.result = result; self.fails = fails
        }
        func release(_ phase: String) { permits.insert(phase) }
        func review(timeline: Timeline, assets: [MediaAsset], renderedURL: URL?, progress: FilmBuildProgressHandler?, pass: Int, reason: String?) async throws -> [ShotContentAssessment] {
            let phase = renderedURL == nil ? "source" : "mp4"
            phases.append(phase)
            await progress?(.init(renderedURL == nil ? .sourceContent : .renderedContent, completed: 0, total: 1))
            while blockedPhase == phase && !permits.contains(phase) {
                try await Task.sleep(for: .milliseconds(10))
            }
            try Task.checkCancellation()
            if fails { throw URLError(.timedOut) }
            return timeline.items.filter { OriginalMediaType.isVideo($0, assets: assets) }.map { item in
                .init(itemID: item.id, assetID: item.assetID!, sourceContentHash: assets.first { $0.id == item.assetID }!.contentHash,
                      sourceStart: item.sourceStart, sourceDuration: item.sourceDuration,
                      sampleTimes: [0, 0.25, 0.5, 0.75, 0.98], phase: phase, model: "orchestration-fixture", cacheKey: phase,
                      status: result, confidence: result == .uncertain ? 0 : 0.95, obstructedSamples: result == .obstructed ? [1, 2] : [],
                      observation: "Explicit orchestration fixture", activity: "landscape", editorialPurpose: "establishing",
                      actionBoundary: .init(startObservation: "Visible river", endObservation: "Visible river", followingObservation: "Continuous view", verdict: .continuous, confidence: 0.95))
            }
        }
    }

    private func fixture() async throws -> (ProjectStore, FilmBuildDraft) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = try ProjectStore(createAt: root, name: "Content gate")
        let url = try await TitleCardVideoGenerator().generate(text: "River", style: TitleStyle(), duration: 2,
            width: 160, height: 90, frameRate: 15, destination: root.appendingPathComponent("source.mov"))
        let asset = try await MediaImporter().makeAsset(url: url)
        let request = FilmBuildRequest(kind: .create, prompt: "Собери фильм. Без музыки. Без титров.", preset: .memories)
        try await store.update { $0.assets = [asset] }
        _ = try await store.beginEditorialGeneration(prompt: request.prompt, brief: nil)
        _ = try await store.beginFilmBuildRecovery(request)
        let plan = StoryPlan(prompt: request.prompt, preset: .memories, constraints: StoryConstraints(targetDuration: 2), chapters: [])
        let timeline = Timeline(storyPlanID: plan.id, width: 160, height: 90, frameRate: 15,
            items: [TimelineItem(assetID: asset.id, kind: .video, sourceDuration: 2, timelineStart: 0, timelineDuration: 2)])
        let draft = FilmBuildDraft(phase: .checkingContent, timeline: timeline, plan: plan, analyses: [], tracks: [], sourceMap: .empty,
            events: [], personalTaste: PersonalTasteProfile(), checkpointReason: "Pending content check")
        try await store.checkpointFilmBuild(draft, ifRevision: await store.snapshot().revision)
        return (store, draft)
    }

    private func waitFor(_ phase: String, reviewer: Reviewer) async throws {
        for _ in 0..<1000 {
            if await reviewer.phases.contains(phase) { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Review did not reach \(phase)")
        throw URLError(.timedOut)
    }

    @Test(arguments: ["source", "mp4"])
    func filmIsNotPublishedWhileEitherContentPhaseIsPending(phase: String) async throws {
        let (store, draft) = try await fixture()
        let root = await store.packageURL
        defer { try? FileManager.default.removeItem(at: root) }
        let reviewer = Reviewer(blockedPhase: phase), prober = ExportProbe(), progress = FilmBuildProgressRecorder()
        let pipeline = VeloEditPipeline(store: store, renderedProber: prober, contentReviewer: reviewer)
        let task = Task { try await pipeline.resumeFilmBuild { await progress.record($0) } }
        defer { task.cancel() }
        try await waitFor(phase, reviewer: reviewer)
        #expect(await store.manifest.timelines.isEmpty)
        #expect(await store.manifest.autonomousJob?.state != .completed)
        #expect(await store.recoverableFilmBuild()?.draft?.phase == .checkingContent)
        #expect(await progress.updates.contains { $0.stage == .saving } == false)
        await reviewer.release(phase)
        let finished = try await task.value
        #expect(finished.items == draft.timeline.items)
        #expect(finished.selectedContentReview?.passes(timeline: finished, assets: await store.manifest.assets) == true)
        #expect(await reviewer.phases == ["source", "mp4"])
        #expect(await prober.calls == 1)
        #expect(await store.manifest.timelines.count == 1)
        #expect(await progress.updates.last?.stage == .saving)
        let reopened = try ProjectStore(open: root)
        #expect(await reopened.manifest.timelines.last?.selectedContentReview == finished.selectedContentReview)
        #expect(finished.filmDeliveryReport?.requirements?.first { $0.rule == "selectedContent" }?.mandatory == true)
    }

    @Test(arguments: [ShotContentStatus.uncertain, .obstructed])
    func unsuccessfulContentReviewKeepsDraftAndCanBeRetried(status: ShotContentStatus) async throws {
        let (store, draft) = try await fixture()
        let root = await store.packageURL
        defer { try? FileManager.default.removeItem(at: root) }
        let pipeline = VeloEditPipeline(store: store, renderedProber: ExportProbe(), contentReviewer: Reviewer(result: status))
        await #expect(throws: (any Error).self) { _ = try await pipeline.resumeFilmBuild() }
        #expect(await store.manifest.timelines.isEmpty)
        let saved = try #require(await store.recoverableFilmBuild()?.draft)
        #expect(saved.phase == .checkingContent)
        #expect(saved.timeline.items == draft.timeline.items)
        #expect(saved.timeline.selectedContentReview?.source.first?.status == status)
        let reopened = try ProjectStore(open: root)
        let retried = try await VeloEditPipeline(store: reopened, renderedProber: ExportProbe(), contentReviewer: Reviewer()).resumeFilmBuild()
        #expect(retried.id == draft.timeline.id)
        #expect(retried.selectedContentReview?.passes(timeline: retried, assets: await reopened.manifest.assets) == true)
    }

    @Test func cancelledContentReviewNeverPublishesTheDraft() async throws {
        let (store, draft) = try await fixture()
        let root = await store.packageURL
        defer { try? FileManager.default.removeItem(at: root) }
        let reviewer = Reviewer(blockedPhase: "mp4")
        let pipeline = VeloEditPipeline(store: store, renderedProber: ExportProbe(), contentReviewer: reviewer)
        let task = Task { try await pipeline.resumeFilmBuild() }
        try await waitFor("mp4", reviewer: reviewer)
        task.cancel()
        await #expect(throws: (any Error).self) { _ = try await task.value }
        #expect(await store.manifest.timelines.isEmpty)
        #expect(await store.recoverableFilmBuild()?.draft?.timeline.items == draft.timeline.items)
    }

    @Test func technicalReviewErrorDoesNotFallBackToAnUncheckedFilm() async throws {
        let (store, draft) = try await fixture()
        let root = await store.packageURL
        defer { try? FileManager.default.removeItem(at: root) }
        let pipeline = VeloEditPipeline(store: store, renderedProber: ExportProbe(), contentReviewer: Reviewer(fails: true))
        await #expect(throws: (any Error).self) { _ = try await pipeline.resumeFilmBuild() }
        #expect(await store.manifest.timelines.isEmpty)
        #expect(await store.recoverableFilmBuild()?.draft?.timeline.items == draft.timeline.items)
    }
}
