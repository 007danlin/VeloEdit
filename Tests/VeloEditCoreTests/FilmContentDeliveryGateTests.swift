import Foundation
import Testing
@testable import VeloEditCore

@Suite(.serialized)
struct FilmContentDeliveryGateTests {
    private static let fixtureDigest = "content-gate-fixture-weights"
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
        let uncertainAsset: UUID?
        let uncertainPhase: String?
        let partialRendered: Bool
        var reviewedAssets: [[UUID]] = []
        init(blockedPhase: String? = nil, result: ShotContentStatus = .usable, fails: Bool = false, uncertainAsset: UUID? = nil, uncertainPhase: String? = nil, partialRendered: Bool = false) {
            self.blockedPhase = blockedPhase; self.result = result; self.fails = fails
            self.uncertainAsset = uncertainAsset
            self.uncertainPhase = uncertainPhase
            self.partialRendered = partialRendered
        }
        func release(_ phase: String) { permits.insert(phase) }
        func review(timeline: Timeline, assets: [MediaAsset], renderedURL: URL?, progress: FilmBuildProgressHandler?, pass: Int, reason: String?) async throws -> [ShotContentAssessment] {
            let phase = renderedURL == nil ? "source" : "mp4"
            phases.append(phase)
            reviewedAssets.append(timeline.items.compactMap(\.assetID))
            await progress?(.init(renderedURL == nil ? .sourceContent : .renderedContent, completed: 0, total: 1))
            while blockedPhase == phase && !permits.contains(phase) {
                try await Task.sleep(for: .milliseconds(10))
            }
            try Task.checkCancellation()
            if fails { throw URLError(.timedOut) }
            let reviewed = timeline.items.filter { OriginalMediaType.isVideo($0, assets: assets) }
            let selected = partialRendered && phase == "mp4" && reviewed.contains(where: { $0.assetID == uncertainAsset })
                ? reviewed.filter { $0.assetID == uncertainAsset } : reviewed
            return selected.map { item in
                let status = item.assetID == uncertainAsset && (uncertainPhase == nil || uncertainPhase == phase)
                    ? ShotContentStatus.uncertain : result
                return .init(itemID: item.id, assetID: item.assetID!, sourceContentHash: assets.first { $0.id == item.assetID }!.contentHash,
                      sourceStart: item.sourceStart, sourceDuration: item.sourceDuration,
                      sampleTimes: [0, 0.25, 0.5, 0.75, 0.98], phase: phase, model: "orchestration-fixture", cacheKey: phase,
                      status: status, confidence: result == .uncertain ? 0 : 0.95, obstructedSamples: status == .obstructed ? [1, 2] : [],
                      observation: "Explicit orchestration fixture", activity: "landscape", editorialPurpose: "establishing",
                      actionBoundary: .init(startObservation: "Visible river", endObservation: "Visible river", followingObservation: "Continuous view", verdict: .continuous, confidence: 0.95))
            }
        }
    }

    private func fixture(boundProfile: Bool = false) async throws -> (ProjectStore, FilmBuildDraft) {
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
        var draft = FilmBuildDraft(phase: .checkingContent, timeline: timeline, plan: plan, analyses: [], tracks: [], sourceMap: .empty,
            events: [], personalTaste: PersonalTasteProfile(), checkpointReason: "Pending content check")
        if boundProfile {
            let analysis = FilmProcessContext.analysis(preferences: await store.manifest.preferences)
            let profile = FilmProcessProfile(analysis: analysis, modelDigest: Self.fixtureDigest)
            _ = try await store.beginAutonomousJob(kind: .film)
            try await store.updateAutonomousJob { $0.processProfile = profile }
            draft.processProfile = profile
        }
        try await store.checkpointFilmBuild(draft, ifRevision: await store.snapshot().revision)
        return (store, draft)
    }

    private func pipeline(store: ProjectStore, prober: ExportProbe = ExportProbe(), reviewer: Reviewer = Reviewer()) -> VeloEditPipeline {
        VeloEditPipeline(store: store, renderedProber: prober, contentReviewer: reviewer,
            modelDigestProvider: { _ in Self.fixtureDigest })
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
        let pipeline = pipeline(store: store, prober: prober, reviewer: reviewer)
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
        let phases = await reviewer.phases
        // This fixture is an old draft without a frozen profile. Migration
        // first obtains the selected model's source evidence for titles;
        // final delivery then checks source and the actual MP4 separately.
        // The real reviewer reuses exact completed receipts at the second
        // source stage; this ordering fake deliberately has no evidence cache.
        #expect(phases == ["source", "source", "mp4"])
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
        let prober = ExportProbe()
        let reviewer = Reviewer(result: status)
        let pipeline = pipeline(store: store, prober: prober, reviewer: reviewer)
        await #expect(throws: (any Error).self) { _ = try await pipeline.resumeFilmBuild() }
        if status == .uncertain {
            // The rendered image may supply concrete evidence for a repair
            // even when the source observer was uncertain. Keep that path.
            #expect(await prober.calls == 1)
            let phases = await reviewer.phases
            #expect(phases == ["source", "source", "mp4"])
        }
        #expect(await store.manifest.timelines.isEmpty)
        let saved = try #require(await store.recoverableFilmBuild()?.draft)
        #expect(saved.phase == .checkingContent)
        #expect(saved.timeline.items == draft.timeline.items)
        #expect(saved.timeline.selectedContentReview?.source.first?.status == status)
        let reopened = try ProjectStore(open: root)
        let retried = try await self.pipeline(store: reopened).resumeFilmBuild()
        #expect(retried.id == draft.timeline.id)
        #expect(retried.selectedContentReview?.passes(timeline: retried, assets: await reopened.manifest.assets) == true)
    }

    @Test func matchingSavedModeStillRefreshesSourceReceiptsBeforeTitleChecks() async throws {
        let (store, draft) = try await fixture(boundProfile: true)
        let root = await store.packageURL
        defer { try? FileManager.default.removeItem(at: root) }
        let reviewer = Reviewer(blockedPhase: "source"), progress = FilmBuildProgressRecorder()
        let pipeline = pipeline(store: store, reviewer: reviewer)
        let task = Task { try await pipeline.resumeFilmBuild { await progress.record($0) } }
        defer { task.cancel() }
        try await waitFor("source", reviewer: reviewer)
        #expect(await store.recoverableFilmBuild()?.draft?.processProfile == draft.processProfile)
        #expect(await progress.updates.contains { $0.detail == "Проверяю названия частей по выбранному материалу" } == false)
        await reviewer.release("source")
        let finished = try await task.value
        #expect(await reviewer.phases == ["source", "source", "mp4"])
        #expect(finished.items == draft.timeline.items)
    }

    @Test func cancelledContentReviewNeverPublishesTheDraft() async throws {
        let (store, draft) = try await fixture()
        let root = await store.packageURL
        defer { try? FileManager.default.removeItem(at: root) }
        let reviewer = Reviewer(blockedPhase: "mp4")
        let pipeline = pipeline(store: store, reviewer: reviewer)
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
        let pipeline = pipeline(store: store, reviewer: Reviewer(fails: true))
        await #expect(throws: (any Error).self) { _ = try await pipeline.resumeFilmBuild() }
        #expect(await store.manifest.timelines.isEmpty)
        #expect(await store.recoverableFilmBuild()?.draft?.timeline.items == draft.timeline.items)
    }

    @Test(arguments: ["source", "mp4", "partial-mp4"])
    func uncertifiedAutomaticSelectionIsReplacedAndStillChecksEachMP4(scenario: String) async throws {
        let failurePhase = scenario == "source" ? "source" : "mp4"
        let (store, original) = try await fixture(boundProfile: true)
        let root = await store.packageURL
        defer { try? FileManager.default.removeItem(at: root) }
        let base = try #require(await store.manifest.assets.first)
        var second = base; second.id = UUID(); second.displayName = "Second"
        var third = base; third.id = UUID(); third.displayName = "Third"
        let assets = [base, second, third]
        let analyses = assets.enumerated().map { index, asset in
            var insights = CandidateInsights(sceneSummary: "Different moment \(index)", dynamics: 0.5, sharpness: 0.9, exposureQuality: 0.9)
            insights.editorialEvidence = .init(usableRange: .init(start: 0, end: 2),
                informationGain: 0.9, entryQuality: 0.9, exitQuality: 0.9, atmosphereValue: 0.8, confidence: 0.9)
            return AnalysisResult(assetID: asset.id, analyzedContentHash: asset.contentHash, sceneTags: [], candidates: [
                Candidate(assetID: asset.id, sourceStart: 0, sourceDuration: 2,
                    scores: .init(quality: 0.9, interest: 0.9, action: 0.5, stability: 0.9), tags: ["moment-\(index)"], insights: insights)])
        }
        var draft = original
        draft.phase = .verifying
        draft.plan.prompt = "Собери фильм длительностью 4 секунды. Без музыки. Без титров."
        draft.plan.constraints.targetDuration = 4
        draft.plan.narrativeBeatPlan = .init(pattern: .minimalMontage, beats: [], reasons: [])
        draft.analyses = analyses
        draft.timeline.items = analyses.prefix(2).enumerated().map { index, analysis in
            TimelineItem(candidateID: analysis.directorCandidates[0].id, assetID: analysis.assetID, kind: .video,
                sourceDuration: 2, timelineStart: Double(index) * 2, timelineDuration: 2)
        }
        try await store.update { $0.assets = assets }
        _ = try await store.beginFilmBuildRecovery(original.plan.directorBrief.map {
            FilmBuildRequest(kind: .create, prompt: original.plan.prompt, preset: original.plan.preset, directorBrief: $0)
        } ?? FilmBuildRequest(kind: .create, prompt: original.plan.prompt, preset: original.plan.preset))
        try await store.checkpointFilmBuild(draft, ifRevision: await store.snapshot().revision)
        let reviewer = Reviewer(uncertainAsset: second.id, uncertainPhase: failurePhase,
            partialRendered: scenario == "partial-mp4"), prober = ExportProbe()
        let completed = try await pipeline(store: store, prober: prober, reviewer: reviewer).resumeFilmBuild()
        let reviewed = await reviewer.reviewedAssets
        let failedIndex = try #require(await reviewer.phases.firstIndex(of: failurePhase))
        #expect(reviewed[failedIndex].contains(second.id))
        #expect(reviewed.dropFirst(failedIndex + 1).allSatisfy { !$0.contains(second.id) })
        #expect(completed.items.contains { $0.assetID == base.id && $0.sourceStart == 0 && $0.sourceDuration == 2 })
        #expect(completed.items.contains { $0.assetID == third.id })
        #expect(await prober.calls == (failurePhase == "source" ? 1 : 2))
        #expect(await reviewer.phases.last == "mp4")
        #expect(completed.selectedContentReview?.passes(timeline: completed, assets: assets) == true)
    }

    @Test(arguments: [false, true], [nil, ""] as [String?])
    func unknownWeightsNeverReachReviewOrPublishAndCanResume(boundProfile: Bool, missing: String?) async throws {
        let (store, draft) = try await fixture(boundProfile: boundProfile)
        let root = await store.packageURL
        defer { try? FileManager.default.removeItem(at: root) }
        let reviewer = Reviewer(), prober = ExportProbe()
        let unavailable = VeloEditPipeline(store: store, renderedProber: prober, contentReviewer: reviewer,
            modelDigestProvider: { _ in missing })
        await #expect(throws: LocalAIInferenceFailure.self) { _ = try await unavailable.resumeFilmBuild() }
        #expect(await reviewer.phases.isEmpty)
        #expect(await prober.calls == 0)
        #expect(await store.manifest.timelines.isEmpty)
        #expect(await store.manifest.autonomousJob?.state == .waitingForExternalResource)
        #expect(await store.manifest.autonomousJob?.inferenceRetryModel == "qwen3-vl:2b-instruct")
        #expect(await store.manifest.autonomousJob?.inferenceRetryAt != nil)
        #expect(await store.manifest.autonomousJob?.processProfile?.modelDigest == (boundProfile ? Self.fixtureDigest : nil))
        #expect(await store.recoverableFilmBuild()?.draft?.timeline.items == draft.timeline.items)
        let reopened = try ProjectStore(open: root)
        let finished = try await pipeline(store: reopened).resumeFilmBuild()
        #expect(finished.id == draft.timeline.id)
        #expect(finished.selectedContentReview?.passes(timeline: finished, assets: await reopened.manifest.assets) == true)
    }
}
