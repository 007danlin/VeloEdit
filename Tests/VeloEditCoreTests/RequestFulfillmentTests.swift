import Foundation
import AVFoundation
import Testing
@testable import VeloEditCore

struct RequestFulfillmentTests {
    @Test(arguments: ["2 минуты", "ровно 2 минуты", "2:00", "120 секунд", "две минуты", "1 минута 60 секунд"])
    func durationSpellings(_ prompt: String) {
        let result = FilmDurationRequirement.parse(prompt: prompt)
        #expect(result.mode == .exact)
        #expect(result.target == 120)
    }
    @Test func scopedAndBoundedDurations() {
        #expect(FilmDurationRequirement.parse(prompt: "Фильм 2 минуты; титр 5 секунд").target == 120)
        #expect(FilmDurationRequirement.parse(prompt: "Фильм 2 минуты с титром 5 секунд").target == 120)
        #expect(FilmDurationRequirement.parse(prompt: "Сцена 30 секунд").mode == .automatic)
        #expect(FilmDurationRequirement.parse(prompt: "Титр на 2:00").mode == .automatic)
        #expect(FilmDurationRequirement.parse(prompt: "1 минута 30 секунд").target == 90)
        let range = FilmDurationRequirement.parse(prompt: "от 1:30 до 2:00")
        #expect(range.lowerBound == 90 && range.upperBound == 120)
        #expect(range.accepts(duration: 95, frameRate: 30))
        #expect(!range.accepts(duration: 121, frameRate: 30))
        #expect(FilmDurationRequirement.parse(prompt: "не больше 2 минут").accepts(duration: 71.77, frameRate: 30))
        #expect(!FilmDurationRequirement.parse(prompt: "не меньше 2 минут").accepts(duration: 71.77, frameRate: 30))
        #expect(FilmDurationRequirement.parse(prompt: "2 минуты", mode: .approximate).mode == .exact)
        #expect(FilmDurationRequirement.parse(prompt: "примерно 2 минуты").lowerBound == 114)
        #expect(FilmDurationRequirement.parse(prompt: "2 минуты. Теперь ровно 3 минуты").target == 180)
    }

    private func fixture(count: Int = 12) -> (Timeline, StoryPlan, [AnalysisResult], [MediaAsset]) {
        let assets = (0..<count).map { i in MediaAsset(originalURL: URL(fileURLWithPath: "/tmp/request-source-\(i).mov"), kind: .video, byteSize: 1, contentHash: "source-\(i)", metadata: .init(duration: 12, width: 1920, height: 1080)) }
        let analyses = assets.enumerated().map { index, asset in
            var insights = CandidateInsights(sceneSummary: "scene-\(index)")
            insights.editorialEvidence = .init(usableRange: .init(start: 0, end: 12), informationGain: 0.6, entryQuality: 0.9, exitQuality: 0.9, atmosphereValue: 0.8, background: "scene-\(index)", confidence: 0.9)
            let candidate = Candidate(assetID: asset.id, sourceStart: 0, sourceDuration: 12, scores: .init(quality: 0.9, interest: 0.9, action: 0.8, stability: 0.9), tags: ["scene-\(index)"], insights: insights)
            return AnalysisResult(assetID: asset.id, analyzedContentHash: asset.contentHash, candidates: [candidate])
        }
        var plan = StoryPlan(prompt: "Фильм ровно 120 секунд, без музыки и без титров", preset: .story, constraints: .init(targetDuration: 120), chapters: [], directorBrief: .init(requestedDuration: 120, musicPolicy: .none, titlePolicy: .none))
        plan.narrativeBeatPlan = .init(pattern: .minimalMontage, beats: [], reasons: [])
        let items = analyses.prefix(8).enumerated().map { index, analysis in
            TimelineItem(candidateID: analysis.candidates[0].id, assetID: analysis.assetID, kind: .video, sourceDuration: 71.77 / 8, timelineStart: Double(index) * 71.77 / 8, timelineDuration: 71.77 / 8)
        }
        return (Timeline(storyPlanID: plan.id, items: items), plan, analyses, assets)
    }
    @Test func firstSeventyOneSecondAssemblyExpandsToRequestedTwoMinutes() {
        let (first, plan, analyses, assets) = fixture()
        let result = AutomaticEditorialAssembly.prepare(timeline: first, plan: plan, analyses: analyses, events: [], assets: assets)
        #expect(abs(first.duration - 71.77) < 0.001)
        #expect(result.timeline.duration == 120)
        #expect(result.plan.constraints.targetDuration == 120)
        #expect(result.timeline.items.allSatisfy { !$0.isFreezeFrame && $0.speed == 1 && $0.sourceDuration <= 12 })
        var late = result.timeline
        late.items.removeLast()
        let repaired = AutomaticEditorialAssembly.prepare(timeline: late, plan: result.plan, analyses: analyses, events: [], assets: assets)
        #expect(repaired.timeline.duration == 120)
    }
    @Test func excludedSourceCannotSupplyMissingDuration() throws {
        let (first, plan, analyses, originalAssets) = fixture()
        var assets = originalAssets
        for i in assets.indices.dropFirst(4) { assets[i].excluded = true }
        let result = AutomaticEditorialAssembly.prepare(timeline: first, plan: plan, analyses: analyses, events: [], assets: assets)
        #expect(result.timeline.duration == 48)
        #expect(result.plan.constraints.targetDuration == 120)
        #expect(Set(result.timeline.items.compactMap(\.assetID)).isDisjoint(with: Set(assets.filter(\.excluded).map(\.id))))
        let report = AutomaticFilmDelivery.verifiedReport(for: result.timeline, plan: result.plan, assets: assets, analyses: analyses)
        #expect(report.status == .savedWithUnmetRequirements)
        #expect(report.requirements?.first { $0.rule == "duration" }?.passed == false)
        #expect(!report.completionMessage.contains("Готово"))
        let reopened = try JSONDecoder.veloEdit.decode(FilmDeliveryReport.self, from: JSONEncoder.veloEdit.encode(report))
        #expect(reopened == report)
        var changedPlan = result.plan
        changedPlan.prompt = "Фильм 3 минуты"
        #expect(!report.isCurrent(for: result.timeline, plan: changedPlan))
    }
    @Test func unexaminedSourceWindowsAreMinedBeforeCompletion() async throws {
        let (first, plan, analyses, assets) = fixture()
        var pending = analyses
        for i in pending.indices { pending[i].candidates[0].sourceDuration = 1 }
        let analyzer = RequestMiningProbe()
        let expanded = try await EditorialCandidateMiner().expandIfNeeded(analyses: pending, assets: assets, requestedDuration: 120, force: true, analyzer: analyzer)
        #expect(await analyzer.calls > 0)
        #expect(expanded.allSatisfy { $0.warnings.contains(EditorialCandidateMiner.completionMarker) })
        let rebuilt = AutomaticEditorialAssembly.prepare(timeline: first, plan: plan, analyses: expanded, events: [], assets: assets)
        #expect(rebuilt.timeline.duration == 120)
        let calls = await analyzer.calls
        _ = try await EditorialCandidateMiner().expandIfNeeded(analyses: expanded, assets: assets, requestedDuration: 120, force: true, analyzer: analyzer)
        #expect(await analyzer.calls == calls)
    }
    @Test func exportMismatchAndLaterRequestInvalidateFulfillment() throws {
        let (first, plan, analyses, assets) = fixture()
        var timeline = AutomaticEditorialAssembly.prepare(timeline: first, plan: plan, analyses: analyses, events: [], assets: assets).timeline
        timeline.editorialReview = EditorialQualityGate().review(timeline: timeline, plan: plan, analyses: analyses)
        let renderSignature = EditorialRenderSignature.signature(timeline)
        timeline.editorialReview?.exportVerification = .init(renderSignature: renderSignature, probes: [.init(time: 1, decoded: true, hashDistance: 0, meanLumaDifference: 0, meanAbsolutePixelDifference: 0)], durationDifference: 0, aspectRatioMatches: true, provenance: "Synthetic fixture", videoDuration: 71.77)
        let report = AutomaticFilmDelivery.verifiedReport(for: timeline, plan: plan, assets: assets, analyses: analyses)
        #expect(report.requirements?.first { $0.rule == "duration" }?.passed == true)
        #expect(report.requirements?.first { $0.rule == "export" }?.passed == false)
        #expect(report.status != .verified)
        var candidates = analyses.flatMap(\.candidates)
        let revised = FeedbackEngine().apply(feedback: "Поменяй музыку", to: plan, candidates: &candidates)
        #expect(revised.exactDurationRequirement == 120)
        #expect(revised.directorBrief?.canvasFormat == plan.directorBrief?.canvasFormat)
        #expect(revised.directorBrief?.titlePolicy == plan.directorBrief?.titlePolicy)
        #expect(revised.constraints.excludeTags == plan.constraints.excludeTags)
        #expect(!report.isCurrent(for: timeline, plan: revised))
    }
    @Test func renderedTitleUncertaintyKeepsTheMovieButNotVerifiedStatus() {
        let (timeline, original, analyses, assets) = fixture()
        var plan = original
        plan.prompt = "Фильм 120 секунд, титры каждой части"
        var result = AutomaticEditorialAssembly.prepare(timeline: timeline, plan: plan, analyses: analyses, events: [], assets: assets).timeline
        result.editorialReview = EditorialQualityGate().review(timeline: result, plan: plan, analyses: analyses)
        result.editorialReview?.findings.append(.init(kind: .unreadableTitle, severity: 2, itemIDs: [], repair: .decoration, reason: "Synthetic unreadable title"))
        let report = AutomaticFilmDelivery.verifiedReport(for: result, plan: plan, assets: assets, analyses: analyses)
        #expect(report.requirements?.first { $0.rule == "titleVisibility" }?.passed == false)
        #expect(report.status == .savedWithUnmetRequirements)
        #expect(report.isCurrent(for: result))
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["VELOEDIT_REQUEST_QA_RECEIPT"] != nil))
    func finalRealExportRequirementReceipt() async throws {
        let root = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["VELOEDIT_REQUEST_QA_RECEIPT"]))
        #expect(root.path.contains("Build/RequestFulfillment"))
        let store = try ProjectStore(open: root)
        let project = await store.manifest
        let timeline = try #require(project.timelines.last)
        let plan = try #require(project.storyPlans.last { $0.id == timeline.storyPlanID })
        let report = AutomaticFilmDelivery.verifiedReport(for: timeline, plan: plan, assets: project.assets, analyses: project.analyses)
        #expect(report.requirements?.first { $0.rule == "duration" }?.passed == true)
        #expect(report.requirements?.first { $0.rule == "export" }?.passed == true)
        #expect(report.exportVerification?.artifactIsCurrent == true)
        #expect(report.requirements?.first { $0.rule == "titleVisibility" }?.passed == false)
        #expect(report.status == .savedWithUnmetRequirements)
        try await store.update { $0.timelines[$0.timelines.count - 1].filmDeliveryReport = report }
        try JSONEncoder.veloEdit.encode(report).write(to: root.deletingLastPathComponent().appendingPathComponent("test9-report.json"))
        let reopened = try ProjectStore(open: root)
        #expect(await reopened.manifest.timelines.last?.filmDeliveryReport == report)
        print("REQUEST QA receipt: \(report.status); movie available; duration and export pass")
    }
    @Test func replacedExportInvalidatesSavedVerification() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("artifact-receipt-\(UUID())")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("synthetic receipt fixture".utf8).write(to: file)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        var export = EditorialExportVerification(renderSignature: "test", probes: [], durationDifference: 0, aspectRatioMatches: true, provenance: "Synthetic receipt fixture")
        export.outputURL = file
        export.fileSize = (attributes[.size] as? NSNumber)?.int64Value
        export.fileModified = attributes[.modificationDate] as? Date
        export.fileModifiedTime = export.fileModified?.timeIntervalSince1970
        var report = FilmDeliveryReport(renderSignature: "test", warnings: [])
        report.exportVerification = export
        report.requirements = [.init(sourcePhrase: "fixture", rule: "receipt", verificationMethod: "fixture", passed: true, evidence: "fixture")]
        #expect(report.status == .verified)
        let reopened = try JSONDecoder.veloEdit.decode(FilmDeliveryReport.self, from: JSONEncoder.veloEdit.encode(report))
        #expect(reopened.status == .verified)
        try Data("replaced".utf8).write(to: file)
        #expect(report.status == .savedWithUnmetRequirements)
    }
    @Test func renderSignatureSurvivesReopeningMusicAndTelemetry() throws {
        var (timeline, _, _, _) = fixture()
        timeline.music = .init(style: .energetic, bpm: 120, autonomousIntent: .init(
            style: .energetic, desiredEnergy: 0.8, desiredBPM: 120, desiredDuration: 120,
            narrativeEnergyCurve: [0.3, 0.8, 0.4], needsBuildAndDrop: true,
            beatSyncIntensity: 0.8, confidence: 0.8, moodTokens: ["upbeat", "energetic", "dynamic"], reasons: []))
        timeline.items[0].telemetryOverlay = .init(metrics: [.speed, .route, .altitude, .distance])
        let expected = EditorialRenderSignature.signature(timeline)
        for _ in 0..<20 {
            timeline = try JSONDecoder.veloEdit.decode(Timeline.self, from: JSONEncoder.veloEdit.encode(timeline))
            #expect(EditorialRenderSignature.signature(timeline) == expected)
        }
        timeline.music?.volume = 0.5
        #expect(EditorialRenderSignature.signature(timeline) != expected)
    }
    @Test func legacyCachedExportReceiptSurvivesProjectDateEncoding() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("legacy-receipt-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("receipt-fixture")
        try Data("synthetic legacy receipt".utf8).write(to: file)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        let (timeline, _, _, _) = fixture()
        var export = EditorialExportVerification(renderSignature: EditorialRenderSignature.signature(timeline), probes: [], durationDifference: 0, aspectRatioMatches: true, provenance: "Synthetic legacy receipt")
        export.outputURL = file
        export.videoDuration = timeline.duration
        export.fileSize = (attributes[.size] as? NSNumber)?.int64Value
        export.fileModified = attributes[.modificationDate] as? Date
        #expect(export.fileModifiedTime == nil && export.artifactIsCurrent)
        var frames = try await FixtureEditorialProber().frames(timeline: timeline, assets: [], tracks: [], telemetry: [:], cacheURL: root)
        frames[0].exportVerification = export
        let cache = RenderedProbeCache(directory: root.appendingPathComponent("cache"))
        try await cache.store(frames, timeline: timeline, assets: [])
        let restored = try #require(await cache.load(timeline: timeline, assets: [])?.first?.exportVerification)
        let reopened = try JSONDecoder.veloEdit.decode(EditorialExportVerification.self, from: JSONEncoder.veloEdit.encode(restored))
        #expect(reopened.fileModifiedTime != nil && reopened.artifactIsCurrent)
        try Data("changed file".utf8).write(to: file)
        #expect(await cache.load(timeline: timeline, assets: []) == nil)
    }
    @Test func unavailableChosenMusicFailsExplicitlyWithoutPublishingSubstituteFilm() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("request-fallback-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ProjectStore(createAt: root, name: "Fallback")
        let image = root.appendingPathComponent("source.png")
        try AutonomousOperationTests.photo(at: image)
        let asset = try await MediaImporter().makeAsset(url: image)
        // This test isolates missing music, with a fully verified visual range.
        // Duration recovery must not invent unmeasured handles to reach 12 s.
        var insights = CandidateInsights(sceneSummary: "verified still")
        insights.editorialEvidence = .init(usableRange: .init(start: 0, end: 12), atmosphereValue: 0.8, confidence: 0.9)
        let candidate = Candidate(assetID: asset.id, sourceStart: 0, sourceDuration: 12,
            scores: .init(quality: 0.9, interest: 0.9, action: 0.6, stability: 0.9), insights: insights)
        let analyses = preparedFixtureAnalyses([.init(assetID: asset.id, analyzedContentHash: asset.contentHash, candidates: [candidate])], preferences: await store.manifest.preferences)
        try await store.update { $0.assets = [asset]; $0.analyses = analyses }
        let pipeline = VeloEditPipeline(store: store, renderedProber: FixtureEditorialProber(), analyzer: FixtureEditorialAnalyzer(analyses: analyses), musicLibrary: LocalMusicLibrary(rootURL: root.appendingPathComponent("music")), personalTasteStore: LocalPersonalTasteStore(url: root.appendingPathComponent("taste.json")))
        let originalPhotoBytes = try Data(contentsOf: image)
        let unavailableID = UUID()
        do {
            _ = try await pipeline.createFilm(prompt: "Фильм 12 секунд без титров", preset: .story,
                preferredMusicTrackID: unavailableID, directorBrief: .init(requestedDuration: 12, musicPolicy: .specificTrack, titlePolicy: .none))
            Issue.record("Missing requested music must not publish a substitute film")
        } catch {
            guard case DirectorBriefFulfillmentError.unavailableMusicTrack(let id) = error else { throw error }
            #expect(id == unavailableID)
        }
        #expect(await store.manifest.timelines.isEmpty)
        #expect(await store.manifest.autonomousJob?.state == .waitingForExternalResource)
        #expect(await store.manifest.autonomousJob?.externalFailureCause == .missingMusic)
        #expect(await store.manifest.autonomousJob?.externalResource?.isEmpty == false)
        let reopened = try ProjectStore(open: root)
        #expect(await reopened.manifest.timelines.isEmpty)
        #expect(await reopened.manifest.assets.map(\.id) == [asset.id])
        #expect(await reopened.manifest.assets.first?.originalURL == asset.originalURL)
        #expect(try Data(contentsOf: image) == originalPhotoBytes)
        #expect(await reopened.manifest.filmBuildRecovery?.request.preferredMusicTrackID == unavailableID)

    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["VELOEDIT_REQUEST_QA_COPY"] != nil))
    func realTest9Assembly() throws {
        let root = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["VELOEDIT_REQUEST_QA_COPY"]))
        let project = try JSONDecoder.veloEdit.decode(ProjectManifest.self, from: Data(contentsOf: root.appendingPathComponent("project.json")))
        let before = try #require(project.timelines.last)
        let plan = try #require(project.storyPlans.last)
        let result = AutomaticEditorialAssembly.prepare(timeline: before, plan: plan, analyses: project.analyses, events: project.events, assets: project.assets)
        print("REQUEST QA assembly: \(before.duration) -> \(result.timeline.duration), target \(result.plan.constraints.targetDuration)")
        for item in result.timeline.items { print("REQUEST QA range: \(item.assetID!) \(item.sourceStart)...\(item.sourceStart + item.sourceDuration)") }
        #expect(abs(result.timeline.duration - 120) <= 1 / result.timeline.frameRate)
        #expect(result.plan.constraints.targetDuration == 120)
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["VELOEDIT_REQUEST_QA_EXPORT"] != nil))
    func realTest9VerifiedExport() async throws {
        let root = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["VELOEDIT_REQUEST_QA_EXPORT"]))
        #expect(root.path.contains("Build/RequestFulfillment"))
        let store = try ProjectStore(open: root)
        let before = await store.manifest
        let plan = try #require(before.storyPlans.last)
        let timeline = try #require(before.timelines.last)
        let library = LocalMusicLibrary(rootURL: root.deletingLastPathComponent().appendingPathComponent("MusicLibrary"))
        let tracks = try await library.tracks()
        let request = FilmBuildRequest(kind: .create, prompt: plan.prompt, preset: plan.preset,
            targetDuration: plan.directorBrief?.explicitRequestedDuration, directorBrief: plan.directorBrief)
        _ = try await store.beginFilmBuildRecovery(request)
        let draft = FilmBuildDraft(phase: .finishing, timeline: timeline, plan: plan, analyses: before.analyses,
            tracks: tracks, sourceMap: before.sourceMap ?? .empty, events: before.events,
            personalTaste: before.personalTasteProfile ?? .init(), directorBrief: plan.directorBrief, checkpointReason: "Request fulfillment QA")
        try await store.checkpointFilmBuild(draft, ifRevision: await store.snapshot().revision)
        let pipeline = VeloEditPipeline(store: store, musicLibrary: library,
            musicSelectionHistory: LocalMusicSelectionHistoryStore(url: root.appendingPathComponent("qa-music.json")),
            personalTasteStore: LocalPersonalTasteStore(url: root.appendingPathComponent("qa-taste.json")))
        let result = try await pipeline.resumeFilmBuild { print("REQUEST QA: \($0.stage) \($0.detail ?? "")") }
        #expect(abs(AutomaticFilmDurationPolicy.renderedDuration(of: result) - 120) <= 1 / result.frameRate)
        let evidence = try #require(result.filmDeliveryReport?.exportVerification)
        let exportURL = try #require(evidence.outputURL)
        let output = root.deletingLastPathComponent().appendingPathComponent("test9-120s.mp4")
        if FileManager.default.fileExists(atPath: output.path) { try FileManager.default.removeItem(at: output) }
        try FileManager.default.copyItem(at: exportURL, to: output)
        let video = try #require(try await AVURLAsset(url: output).loadTracks(withMediaType: .video).first)
        let measured = try await video.load(.timeRange).duration.seconds
        #expect(abs(measured - 120) <= 1 / result.frameRate)
        #expect(evidence.probes.allSatisfy { $0.passed })
        let report = try #require(result.filmDeliveryReport)
        try JSONEncoder.veloEdit.encode(report).write(to: root.deletingLastPathComponent().appendingPathComponent("test9-report.json"))
        print("REQUEST QA EXPORT: \(output.path), video duration \(measured), status \(report.status), warnings \(report.warnings)")
    }

}

private actor RequestMiningProbe: EditorialEvidenceAnalyzing {
    var calls = 0
    func analyze(candidate: Candidate, asset: MediaAsset) async throws -> EditorialEvidence {
        calls += 1
        return .init(usableRange: .init(start: candidate.sourceStart, end: candidate.sourceStart + candidate.sourceDuration), informationGain: 0.7, entryQuality: 0.9, exitQuality: 0.9, atmosphereValue: 0.8, background: asset.contentHash, confidence: 0.9)
    }
}
