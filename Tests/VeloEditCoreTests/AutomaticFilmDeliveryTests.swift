import Foundation
import Testing
@testable import VeloEditCore

private struct PersistentQualityProber: EditorialRenderedProbing {
    var kind: EditorialFindingKind
    func frames(timeline: Timeline, assets: [MediaAsset], tracks: [LocalMusicTrack], telemetry: [UUID: TelemetrySummary], cacheURL: URL) async throws -> [PerceptualRenderedFrameEvidence] {
        var frames = try await FixtureEditorialProber().frames(timeline: timeline, assets: assets, tracks: tracks, telemetry: telemetry, cacheURL: cacheURL)
        let domain: EditorialEvidenceDomain = kind == .hardDuplicate ? .visualNovelty : kind == .foregroundOcclusion ? .foregroundOcclusion : .bodySafety
        frames[0].editorialClaims = frames[0].editorialClaims?.map { claim in
            var result = claim
            if claim.domain == domain {
                result.status = .failed
                result.finding = .init(kind: kind, severity: 3, itemIDs: claim.itemIDs, repair: .framing, reason: "Persistent fixture quality finding")
            }
            return result
        }
        return frames
    }
}

@Suite(.serialized)
struct AutomaticFilmDeliveryTests {
    @Test func failedAnalysisStillDeliversBeyondAnOldShortlist() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("veloedit-fallback-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ProjectStore(createAt: root, name: "Recovery")
        let source = root.appendingPathComponent("photo.png")
        try AutonomousOperationTests.photo(at: source)
        let asset = try await MediaImporter().makeAsset(url: source)
        let old = AnalysisResult(assetID: asset.id, analyzedContentHash: asset.contentHash,
            candidates: [Candidate(assetID: asset.id, sourceStart: 0, sourceDuration: 1,
                scores: .init(quality: 0.5, interest: 0.5, action: 0, stability: 0.5))])
        try await store.update { $0.assets = [asset]; $0.analyses = [old] }
        let pipeline = VeloEditPipeline(store: store, renderedProber: FixtureEditorialProber(), analyzer: UnavailableVision())
        let timeline = try await pipeline.createFilm(prompt: "Фильм 4 секунды без музыки и титров", preset: .memories,
            targetDuration: 4, directorBrief: DirectorBrief(requestedDuration: 4, musicPolicy: .none, titlePolicy: .none))
        #expect(abs(timeline.duration - 4) <= 1 / timeline.frameRate)
        #expect(timeline.filmDeliveryReport?.isCurrent(for: timeline) == true)
        #expect(await store.manifest.autonomousJob?.state == .completed)
        #expect(await store.manifest.timelines.last?.id == timeline.id)
    }

    @Test func freshCreationSelectsAndSavesDespiteEveryVariantHavingAQualityFinding() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("fresh-delivery-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ProjectStore(createAt: root, name: "Fresh automatic film")
        let source = root.appendingPathComponent("source.png")
        try AutonomousOperationTests.photo(at: source)
        let asset = try await MediaImporter().makeAsset(url: source)
        let candidate = Candidate(assetID: asset.id, sourceStart: 0, sourceDuration: 12,
            scores: .init(quality: 0.9, interest: 0.9, action: 0.8, stability: 0.9), tags: ["person"])
        let analyses = preparedFixtureAnalyses([AnalysisResult(assetID: asset.id,
            analyzedContentHash: asset.contentHash, candidates: [candidate])], preferences: await store.manifest.preferences)
        try await store.update { $0.assets = [asset]; $0.analyses = analyses }
        let pipeline = VeloEditPipeline(store: store, renderedProber: PersistentQualityProber(kind: .foregroundOcclusion),
            analyzer: FixtureEditorialAnalyzer(analyses: analyses),
            personalTasteStore: LocalPersonalTasteStore(url: root.appendingPathComponent("taste.json")))
        let timeline = try await pipeline.createFilm(prompt: "Фильм без музыки и без титров", preset: .memories,
            directorBrief: DirectorBrief(requestedDuration: 12, musicPolicy: .none, titlePolicy: .none))
        #expect(timeline.editorialReview?.findings.contains { $0.kind == .foregroundOcclusion } == true)
        #expect(timeline.filmDeliveryReport?.isCurrent(for: timeline) == true)
        #expect(await store.manifest.timelines.last?.id == timeline.id)
        #expect(await store.manifest.autonomousJob?.state == .completed)
    }

    @Test(arguments: [EditorialFindingKind.unsafeReframe, .foregroundOcclusion, .hardDuplicate])
    func persistentQualityFindingStillCompletesAndReopens(_ kind: EditorialFindingKind) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("automatic-delivery-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ProjectStore(createAt: root, name: "Quality warning")
        let source = root.appendingPathComponent("source.png")
        try AutonomousOperationTests.photo(at: source)
        let asset = try await MediaImporter().makeAsset(url: source)
        let candidate = Candidate(assetID: asset.id, sourceStart: 0, sourceDuration: 12,
            scores: .init(quality: 0.9, interest: 0.9, action: 0.8, stability: 0.9), tags: ["person"])
        let analyses = [AnalysisResult(assetID: asset.id, analyzedContentHash: asset.contentHash, candidates: [candidate])]
        try await store.update { $0.assets = [asset]; $0.analyses = analyses }
        let request = FilmBuildRequest(kind: .create, prompt: "Без музыки, без титров", preset: .memories)
        _ = try await store.beginFilmBuildRecovery(request)
        var plan = StoryPlan(prompt: request.prompt, preset: .memories, constraints: .init(targetDuration: 12), chapters: [])
        plan.narrativeBeatPlan = .init(pattern: .minimalMontage, beats: [], reasons: [])
        let item = TimelineItem(candidateID: candidate.id, assetID: asset.id, kind: .photo,
            sourceDuration: 12, timelineStart: 0, timelineDuration: 12, videoAdjustments: .init(crop: .fit))
        let timeline = Timeline(storyPlanID: plan.id, width: 320, height: 180, frameRate: 15, items: [item])
        let draft = FilmBuildDraft(phase: .verifying, timeline: timeline, plan: plan, analyses: analyses,
            tracks: [], sourceMap: .empty, events: [], personalTaste: .init(), checkpointReason: "Interrupted quality check")
        try await store.checkpointFilmBuild(draft, ifRevision: await store.snapshot().revision)
        let pipeline = VeloEditPipeline(store: store, renderedProber: PersistentQualityProber(kind: kind),
            personalTasteStore: LocalPersonalTasteStore(url: root.appendingPathComponent("taste.json")))
        let result = try await pipeline.resumeFilmBuild()
        #expect(result.items.contains { $0.id == item.id })
        #expect(result.duration == 12)
        #expect(result.editorialReview?.findings.contains { $0.kind == kind && $0.severity == 3 } == true)
        #expect(result.editorialReview?.productionEligible == false)
        #expect(result.filmDeliveryReport?.isCurrent(for: result) == true)
        #expect(result.filmDeliveryReport?.warnings.isEmpty == false)
        let reopened = try ProjectStore(open: root)
        let saved = await reopened.manifest
        #expect(saved.timelines.count == 1)
        #expect(saved.timelines.last?.filmDeliveryReport == result.filmDeliveryReport)
        #expect(saved.autonomousJob?.state == .completed)
        #expect(saved.filmBuildRecovery == nil)
        #expect(saved.intentLedger?.entries.last { $0.normalizedIntent == .createFilm }?.status == .fulfilled)
        let playback = try await PlaybackEngine().build(timeline: result, assets: saved.assets, forceVideoComposition: true)
        #expect(playback.renderedItemCount == 1 && playback.skippedItemIDs.isEmpty)
    }

    @Test func selectorKeepsBestAvailableAndPrefersPassingQuality() throws {
        let plan = StoryPlan(prompt: "Фильм", preset: .story, constraints: .init(targetDuration: 12), chapters: [])
        let item = TimelineItem(assetID: UUID(), kind: .video, sourceDuration: 12, timelineStart: 0, timelineDuration: 12)
        var flawed = Timeline(storyPlanID: plan.id, items: [item])
        flawed.editorialReview = EditorialQualityGate().review(timeline: flawed, plan: plan, analyses: [])
        flawed.editorialReview?.findings = [.init(kind: .unsafeReframe, severity: 3, itemIDs: [item.id], repair: .framing, reason: "edge")]
        let story = StoryPlanVariant(plan: plan, strategy: "flawed", seedScore: 1)
        let selector = MontageVariantSelector()
        #expect(selector.select(stories: [story], timelines: [flawed], assets: [], analyses: []) == nil)
        let best = try #require(selector.select(stories: [story], timelines: [flawed], assets: [], analyses: [], allowsQualityWarnings: true))
        #expect(best.timeline.items == flawed.items)
        #expect(best.timeline.editorialReview?.findings == flawed.editorialReview?.findings)
        var clean = flawed
        clean.id = UUID()
        clean.editorialReview?.findings = []
        let cleanStory = StoryPlanVariant(plan: plan, strategy: "clean", seedScore: 0.5)
        let preferred = selector.select(stories: [story, cleanStory], timelines: [flawed, clean], assets: [], analyses: [], allowsQualityWarnings: true)
        #expect(preferred?.story.strategy == "clean")
        var empty = flawed
        empty.items = []
        #expect(selector.select(stories: [story], timelines: [empty], assets: [], analyses: [], allowsQualityWarnings: true) == nil)
    }

    @Test func deliveryReportDoesNotTransferToAnEditedOrEmptyTimeline() throws {
        var timeline = Timeline(storyPlanID: UUID(), items: [TimelineItem(assetID: UUID(), kind: .photo, sourceDuration: 12, timelineStart: 0, timelineDuration: 12)])
        timeline.filmDeliveryReport = AutomaticFilmDelivery.report(for: timeline, additionalWarnings: ["warning"])
        let decoded = try JSONDecoder.veloEdit.decode(Timeline.self, from: JSONEncoder.veloEdit.encode(timeline))
        #expect(decoded.filmDeliveryReport?.isCurrent(for: decoded) == true)
        timeline.items[0].sourceStart = 1
        #expect(timeline.filmDeliveryReport?.isCurrent(for: timeline) == false)
        timeline.items = []
        #expect(timeline.filmDeliveryReport?.isCurrent(for: timeline) == false)
    }

    @Test func qualityRepairKeepsLastShotAndRequestedDuration() {
        let plan = StoryPlan(prompt: "Ровно 12 секунд", preset: .story, constraints: .init(targetDuration: 12), chapters: [])
        let timeline = Timeline(storyPlanID: plan.id, items: [TimelineItem(assetID: UUID(), kind: .video, sourceDuration: 12, timelineStart: 0, timelineDuration: 12)])
        var repaired = timeline
        repaired.items[0].timelineDuration = 11
        #expect(!AutomaticFilmDelivery.preservesDelivery(repaired, original: timeline, plan: plan))
        repaired.items = []
        #expect(!AutomaticFilmDelivery.preservesDelivery(repaired, original: timeline, plan: plan))
        repaired = timeline
        repaired.items[0].videoAdjustments = .init(crop: .fit)
        #expect(AutomaticFilmDelivery.preservesDelivery(repaired, original: timeline, plan: plan))
    }

    @Test func unmetTitleRequestIsRecordedWithoutDiscardingTheFilm() throws {
        var project = ProjectManifest(name: "Best available")
        let ids = [UUID(), UUID()]
        project.intentLedger = IntentLedger(entries: [
            .init(id: ids[0], projectRevision: 0, normalizedIntent: .createFilm, source: .prompt, status: .running, evidence: []),
            .init(id: ids[1], projectRevision: 0, normalizedIntent: .addTitles, source: .prompt, status: .running, evidence: [])
        ])
        let plan = StoryPlan(prompt: "Добавь титры", preset: .story, constraints: .init(targetDuration: 12), chapters: [])
        var timeline = Timeline(storyPlanID: plan.id, items: [TimelineItem(assetID: UUID(), kind: .photo, sourceDuration: 12, timelineStart: 0, timelineDuration: 12)])
        timeline.editorialReview = EditorialQualityGate().review(timeline: timeline, plan: plan, analyses: [])
        timeline.filmDeliveryReport = AutomaticFilmDelivery.report(for: timeline)
        let result = try ProjectStore.verifyAndFulfillEditorialGeneration(in: &project, ids: ids, timeline: timeline, analyses: [])
        #expect(project.intentLedger?.entries[0].status == .fulfilled)
        #expect(project.intentLedger?.entries[1].status == .rejected)
        #expect(result.filmDeliveryReport?.warnings.contains { $0.contains("титр") } == true)
        #expect(result.filmDeliveryReport?.isCurrent(for: result) == true)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["VELOEDIT_AUTOMATIC_DELIVERY_QA_COPY"] != nil))
    func realSavedTest7DraftCompletesWithOriginalEvidence() async throws {
        let root = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["VELOEDIT_AUTOMATIC_DELIVERY_QA_COPY"]))
        let store = try ProjectStore(open: root)
        let before = await store.manifest
        let draft = try #require(before.filmBuildRecovery?.draft)
        #expect(draft.timeline.editorialReview?.findings.contains { $0.kind == .unsafeReframe } == true)
        let pipeline = VeloEditPipeline(store: store,
            musicLibrary: LocalMusicLibrary(rootURL: root.appendingPathComponent("MusicLibrary")),
            musicSelectionHistory: LocalMusicSelectionHistoryStore(url: root.appendingPathComponent("qa-music.json")),
            personalTasteStore: LocalPersonalTasteStore(url: root.appendingPathComponent("qa-taste.json")))
        let result = try await pipeline.resumeFilmBuild { print("QA: \($0.stage)") }
        #expect(abs(AutomaticFilmDurationPolicy.renderedDuration(of: result) - 300) <= 1 / result.frameRate)
        #expect(result.filmDeliveryReport?.isCurrent(for: result) == true)
        #expect(await store.manifest.timelines.last?.id == result.id)
        #expect(await store.manifest.autonomousJob?.state == .completed)
        let reopened = try ProjectStore(open: root)
        #expect(await reopened.manifest.timelines.count == before.timelines.count + 1)
        let playback = try await pipeline.makePlayback(interactiveQuality: .preview720p)
        #expect(playback.renderedItemCount > 0 && playback.skippedItemIDs.isEmpty)
        print("QA: completed \(result.duration) seconds; warnings: \(result.filmDeliveryReport?.warnings ?? [])")
    }
}

private struct UnavailableVision: VisionModelProtocol {
    func analyze(asset: MediaAsset) async throws -> AnalysisResult {
        throw URLError(.cannotDecodeContentData)
    }
}
