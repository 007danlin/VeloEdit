import Foundation
import Testing
@testable import VeloEditCore

@Test func keyTitlePolicyKeepsEveryPartWithoutCountOrSpacingLimits() {
    let opening = TitleTimelineItem(kind: .cinematicTitle, text: "Активный день", startTime: 0, duration: 2)
    let chapters = ["Велопрогулка", "Сплав", "Рыбалка", "Велопрогулка"].enumerated().map {
        TitleTimelineItem(kind: .chapter, text: $0.element, startTime: 3 + Double($0.offset) * 4, duration: 2)
    }
    let caption = TitleTimelineItem(kind: .automaticSubtitles, text: "Поехали!", startTime: 4, duration: 1.5)
    let decoration = TitleTimelineItem(kind: .keywordOverlay, text: "Вперёд!", startTime: 8, duration: 2)
    let placeholder = TitleTimelineItem(kind: .chapter, text: "Кульминация", startTime: 12, duration: 2)
    let source = [opening] + chapters + [caption, decoration, placeholder]
    let result = DirectorTitlePolicyEngine.applying(.keyOnly, to: source, timelineDuration: 20)

    #expect(result.filter { $0.kind == .chapter }.map(\.id) == chapters.map(\.id))
    #expect(result.contains(opening))
    #expect(result.contains(caption))
    #expect(!result.contains(decoration))
    #expect(!result.contains(placeholder))
    #expect(DirectorTitlePolicyEngine.applying(.keyOnly, to: result, timelineDuration: 20) == result)
    #expect(DirectorTitlePolicyEngine.applying(.minimal, to: source, timelineDuration: 20).map(\.id) == [opening.id, caption.id])
    #expect(DirectorTitlePolicyEngine.applying(.none, to: source, timelineDuration: 20).isEmpty)
}

@Test func directorBriefRoundTripsEveryOpeningChoice() throws {
    let trackID = UUID()
    let brief = DirectorBrief(
        canvasFormat: .portrait9x16,
        requestedDuration: 300,
        mood: .calm,
        musicPolicy: .specificTrack,
        musicTrackID: trackID,
        sourceAudioPolicy: .mute,
        titlePolicy: .keyOnly
    )
    let state = ProjectWorkspaceState(
        prompt: "Семейная поездка",
        preset: .cinematic,
        targetMinutes: 5,
        directorMusicTrackID: trackID,
        directorBrief: brief
    )

    let decoded = try JSONDecoder().decode(
        ProjectWorkspaceState.self,
        from: JSONEncoder().encode(state)
    )

    #expect(decoded.directorBrief == brief)
    #expect(decoded.directorBrief?.canvasFormat.width == 1080)
    #expect(decoded.directorBrief?.canvasFormat.height == 1920)
}

@Test func legacyStoryPlanWithoutDirectorBriefStillDecodes() throws {
    let json = """
    {
      "id": "00000000-0000-0000-0000-000000000001",
      "version": 1,
      "prompt": "legacy",
      "preset": "story",
      "constraints": {
        "targetDuration": 30,
        "targetClipCount": null,
        "includeTags": [],
        "excludeTags": [],
        "maximumTagShares": {},
        "preferPhotos": false,
        "allowSlowMotion": true,
        "transitionFrequency": 0.1,
        "pacing": 0.5,
        "preferredIntroTags": null,
        "preferredClimaxTags": null,
        "preferredOutroTags": null
      },
      "chapters": [],
      "createdAt": 0
    }
    """.data(using: .utf8)!

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .secondsSince1970
    let plan = try decoder.decode(StoryPlan.self, from: json)
    #expect(plan.directorBrief == nil)
}

@Test func unreadableMetadataFallbackLeavesRecoverableIntentWithoutFakeTimeline() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("veloedit")
    let tasteURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("duration-fallback-\(UUID().uuidString).json")
    defer {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: tasteURL)
    }

    let store = try ProjectStore(createAt: root, name: "Duration fallback")
    let asset = MediaAsset(
        originalURL: URL(fileURLWithPath: "/tmp/duration-fallback.mov"),
        kind: .video,
        byteSize: 1,
        contentHash: "duration-fallback",
        metadata: MediaMetadata(duration: 12, width: 1920, height: 1080, frameRate: 30)
    )
    try await store.update { project in
        project.assets = [asset]
        project.analyses = [AnalysisResult(
            assetID: asset.id,
            schemaVersion: project.analysisSchemaVersion,
            analyzedContentHash: asset.contentHash,
            candidates: []
        )]
    }

    try await store.update { $0.editorialDevelopmentEnabled = true }
    let pipeline = VeloEditPipeline(
        store: store,
        // Exercise unavailable-media recovery, independently of a running
        // Ollama server. No fixture supplies readable frames or candidates.
        analyzer: FixtureEditorialAnalyzer(analyses: await store.manifest.analyses),
        personalTasteStore: LocalPersonalTasteStore(url: tasteURL)
    )
    let brief = DirectorBrief(
        requestedDuration: 300,
        musicPolicy: .none,
        titlePolicy: .none
    )
    do {
        _ = try await pipeline.createFilm(prompt: "Собери фильм из доступного материала", preset: .story, targetDuration: brief.requestedDuration, directorBrief: brief)
        Issue.record("Expected an unavailable-source error")
    } catch DirectorBriefFulfillmentError.noUsableSourceMaterial {
        // Source validation precedes editorial generation for missing files.
    } catch { Issue.record("Unexpected error: \(error)") }
    let snapshot = await pipeline.snapshot()
    #expect(snapshot.timelines.isEmpty)
    #expect(snapshot.intentLedger?.hasRecoverableGeneration == true)
    #expect(snapshot.intentLedger?.entries.contains { $0.status == .recoverableFailure && $0.failureReason != nil } == true)
}

@Test func directorReportsMissingReadableMediaInsteadOfZeroDurationContractFailure() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("veloedit")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try ProjectStore(createAt: root, name: "Unreadable source")
    let asset = MediaAsset(
        originalURL: URL(fileURLWithPath: "/tmp/unreadable.mov"),
        kind: .video,
        byteSize: 1,
        contentHash: "unreadable",
        metadata: MediaMetadata()
    )
    try await store.update { project in
        project.assets = [asset]
        project.analyses = []
    }

    let pipeline = VeloEditPipeline(store: store, analyzer: FixtureEditorialAnalyzer(analyses: [
        AnalysisResult(assetID: asset.id, analyzedContentHash: asset.contentHash, candidates: [])
    ]))
    do {
        _ = try await pipeline.createFilm(
            prompt: "Собери фильм",
            preset: .story,
            directorBrief: DirectorBrief(requestedDuration: 300, musicPolicy: .none)
        )
        Issue.record("Expected a readable-source error")
    } catch {
        guard case DirectorBriefFulfillmentError.noUsableSourceMaterial = error else {
            Issue.record("Expected an unavailable-source error, got \(error)")
            return
        }
        #expect(error.localizedDescription.contains("исходники"))
        #expect(!error.localizedDescription.contains("монтаж длится 0.000"))
    }
}

@Test func displayAspectUsesVideoPreferredTransformOnlyOnceAndPhotoEXIFOnce() {
    let video = MediaAsset(
        originalURL: URL(fileURLWithPath: "/tmp/oriented.mov"),
        kind: .video,
        byteSize: 1,
        contentHash: "video-oriented",
        metadata: MediaMetadata(width: 1080, height: 1920, orientationDegrees: 90)
    )
    let photo = MediaAsset(
        originalURL: URL(fileURLWithPath: "/tmp/oriented.jpg"),
        kind: .photo,
        byteSize: 1,
        contentHash: "photo-oriented",
        metadata: MediaMetadata(width: 1920, height: 1080, orientationDegrees: 90)
    )

    #expect(video.displayDimensions?.width == 1080)
    #expect(video.displayDimensions?.height == 1920)
    #expect(photo.displayDimensions?.width == 1080)
    #expect(photo.displayDimensions?.height == 1920)
}
