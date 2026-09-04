import Foundation
import Testing
@testable import VeloEditCore

@Test func newProjectsUseBundledFastAIAndSeparateMusicLibraries() async throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let firstURL = base.appendingPathComponent("Первый.veloedit")
    let secondURL = base.appendingPathComponent("Второй.veloedit")
    defer { try? FileManager.default.removeItem(at: base) }

    let firstStore = try ProjectStore(createAt: firstURL, name: "Первый")
    let secondStore = try ProjectStore(createAt: secondURL, name: "Второй")
    #expect(await firstStore.manifest.preferences.effectiveAIPowerMode == .fast)

    let track = LocalMusicTrack(
        title: "Трек первого проекта",
        author: "Автор",
        bpm: 100,
        genres: ["local"],
        moods: ["custom"],
        energy: 0.5,
        duration: 10,
        license: .userFile(),
        sourceProvider: .user,
        sourcePageURL: URL(fileURLWithPath: "/tmp/source.mp3"),
        localFileURL: firstURL.appendingPathComponent("MusicLibrary/Files/track.mp3"),
        originalFileName: "track.mp3"
    )
    try FileManager.default.createDirectory(
        at: track.localFileURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try Data("audio-placeholder".utf8).write(to: track.localFileURL)
    let catalogURL = firstURL.appendingPathComponent("MusicLibrary/tracks.json")
    try JSONEncoder.veloEdit.encode([track]).write(to: catalogURL)

    let firstPipeline = VeloEditPipeline(store: firstStore)
    let secondPipeline = VeloEditPipeline(store: secondStore)
    let firstTracks = try await firstPipeline.musicTracks()
    let secondTracks = try await secondPipeline.musicTracks()
    #expect(firstTracks.filter { $0.sourceProvider == .user }.map(\.title) == ["Трек первого проекта"])
    #expect(firstTracks.filter { $0.sourceProvider == .bundled }.count == 12)
    #expect(secondTracks.filter { $0.sourceProvider == .user }.isEmpty)
    #expect(secondTracks.filter { $0.sourceProvider == .bundled }.count == 12)
}

@Test func createFilmUsesExplicitUserTrackEvenWhenBriefDisablesAutomaticMusic() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("veloedit")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try ProjectStore(createAt: root, name: "Фильм со своим треком")
    let trackURL = root.appendingPathComponent("MusicLibrary/Files/own.mp3")
    try FileManager.default.createDirectory(at: trackURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("audio-placeholder".utf8).write(to: trackURL)
    let track = LocalMusicTrack(
        title: "Мой трек",
        author: "Пользователь",
        bpm: 124,
        genres: ["electronic"],
        moods: ["energetic"],
        energy: 0.82,
        duration: 30,
        license: .userFile(),
        sourceProvider: .user,
        sourcePageURL: trackURL,
        localFileURL: trackURL,
        originalFileName: trackURL.lastPathComponent
    )
    try JSONEncoder.veloEdit.encode([track]).write(to: root.appendingPathComponent("MusicLibrary/tracks.json"))

    let asset = MediaAsset(
        originalURL: URL(fileURLWithPath: "/tmp/user-track-film.mov"),
        kind: .video,
        byteSize: 1,
        contentHash: "user-track-film",
        metadata: MediaMetadata(duration: 8, width: 1920, height: 1080, frameRate: 30, hasAudio: true)
    )
    let candidate = Candidate(
        assetID: asset.id,
        sourceStart: 0,
        sourceDuration: 6,
        scores: ClipScores(quality: 0.9, interest: 0.9, action: 0.8, stability: 0.85, uniqueness: 0.9),
        tags: ["ride", "action"]
    )
    try await store.update { project in
        project.assets = [asset]
        project.analyses = [AnalysisResult(assetID: asset.id, analyzedContentHash: asset.contentHash, candidates: [candidate])]
    }

    let pipeline = VeloEditPipeline(store: store)
    let timeline = try await pipeline.createFilm(
        prompt: "Без музыки. Собери короткий фильм.",
        preset: .adventure,
        targetDuration: 6,
        preferredMusicTrackID: track.id
    )

    #expect(timeline.music?.trackID == track.id)
    #expect(timeline.music?.trackTitle == track.title)
}

@Test func projectRoundTripAndCacheLookup() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("veloedit")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try ProjectStore(createAt: root, name: "Лето")
    let asset = MediaAsset(originalURL: URL(fileURLWithPath: "/tmp/a.mov"), kind: .video, byteSize: 42, contentHash: "abc", metadata: MediaMetadata(duration: 12))
    let result = AnalysisResult(
        assetID: asset.id,
        analyzedContentHash: "abc",
        candidates: [],
        deepMediaVersion: DeepAnalysisCache.version
    )
    try await store.update { project in
        project.assets.append(asset)
        project.analyses.append(result)
    }
    let reopened = try ProjectStore(open: root)
    let manifest = await reopened.manifest
    #expect(manifest.name == "Лето")
    #expect(manifest.assets.first?.contentHash == "abc")
    let cached = await reopened.cachedAnalysis(for: asset)
    #expect(cached?.assetID == asset.id)
}

@Test func projectSummaryTracksTheActualTimelineCoverAndAssetCount() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("veloedit")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try ProjectStore(createAt: root, name: "До переименования")
    let unusedFirstAsset = MediaAsset(
        originalURL: URL(fileURLWithPath: "/tmp/first.mov"),
        kind: .video,
        byteSize: 1,
        contentHash: "first-asset-hash",
        metadata: MediaMetadata(duration: 8)
    )
    let coverAsset = MediaAsset(
        originalURL: URL(fileURLWithPath: "/tmp/cover.jpg"),
        kind: .photo,
        byteSize: 1,
        contentHash: "cover-asset-hash",
        metadata: MediaMetadata(duration: 5)
    )
    let laterItem = TimelineItem(
        assetID: unusedFirstAsset.id,
        kind: .video,
        sourceStart: 0,
        sourceDuration: 4,
        timelineStart: 4,
        timelineDuration: 4
    )
    let coverItem = TimelineItem(
        assetID: coverAsset.id,
        kind: .photo,
        sourceStart: 0,
        sourceDuration: 4,
        timelineStart: 0,
        timelineDuration: 4
    )
    try await store.update { project in
        project.name = "Правильное имя"
        project.assets = [unusedFirstAsset, coverAsset]
        // Deliberately keep array order different from timeline order.
        project.timelines = [Timeline(storyPlanID: UUID(), items: [laterItem, coverItem])]
    }

    let summary = try #require(ProjectSummary.load(from: root))
    #expect(summary.name == "Правильное имя")
    #expect(summary.assetCount == 2)
    #expect(summary.previewKind == .photo)

    let paths = CachePaths(root: root.appendingPathComponent("Cache", isDirectory: true))
    let expectedTimelinePath = paths.timelineThumbnail(for: coverItem, asset: coverAsset)
        .path.replacingOccurrences(of: root.path + "/", with: "")
    let expectedSourcePath = paths.thumbnail(for: coverAsset)
        .path.replacingOccurrences(of: root.path + "/", with: "")
    #expect(summary.previewRelativePaths == [expectedTimelinePath, expectedSourcePath])
}

@Test func projectCacheRejectsAnOutdatedDeepAnalysisContract() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("veloedit")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try ProjectStore(createAt: root, name: "Versioned analysis")
    let asset = MediaAsset(
        originalURL: URL(fileURLWithPath: "/tmp/stale.mov"),
        kind: .video,
        byteSize: 42,
        contentHash: "stale",
        metadata: MediaMetadata(duration: 12)
    )
    let stale = AnalysisResult(
        assetID: asset.id,
        analyzedContentHash: asset.contentHash,
        candidates: [],
        deepMediaVersion: max(0, DeepAnalysisCache.version - 1)
    )
    try await store.update { project in
        project.assets = [asset]
        project.analyses = [stale]
    }

    let cached = await store.cachedAnalysis(for: asset)
    #expect(cached == nil)
}

@Test func builtInBackgroundBecomesReusableTimelineMedia() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("veloedit")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try ProjectStore(createAt: root, name: "Фоны")
    let planID = UUID()
    try await store.update { project in
        project.timelines = [Timeline(storyPlanID: planID, width: 1280, height: 720, items: [])]
    }
    let pipeline = VeloEditPipeline(store: store)

    let firstID = try await pipeline.insertBackgroundIntoTimeline(.underwater, at: 0)
    let secondID = try await pipeline.insertBackgroundIntoTimeline(.underwater, at: 1)
    let manifest = await pipeline.snapshot()

    let backgroundAssets = manifest.assets.filter { BackgroundPreset.preset(for: $0) == .underwater }
    #expect(backgroundAssets.count == 1)
    #expect(FileManager.default.fileExists(atPath: backgroundAssets[0].originalURL.path))
    #expect(backgroundAssets[0].originalURL.lastPathComponent.contains("-v3-"))
    #expect(manifest.timelines.last?.items.map(\.id) == [firstID, secondID])
    #expect(manifest.timelines.last?.items.allSatisfy { $0.kind == .photo && $0.timelineDuration == 4 } == true)
}

@Test func legacyBackgroundAssetMigratesWithoutBreakingTimelineReference() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("veloedit")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try ProjectStore(createAt: root, name: "Старый фон")
    let legacy = MediaAsset(
        originalURL: root.appendingPathComponent("old-curtain.png"),
        displayName: "Занавес",
        kind: .photo,
        byteSize: 0,
        contentHash: "veloedit-background-v2-curtain-640x360",
        metadata: MediaMetadata(width: 640, height: 360, codec: "png")
    )
    let item = TimelineItem(assetID: legacy.id, kind: .photo, sourceDuration: 4, timelineStart: 0, timelineDuration: 4)
    try await store.update { project in
        project.assets = [legacy]
        project.timelines = [Timeline(storyPlanID: UUID(), width: 640, height: 360, items: [item])]
    }

    let pipeline = VeloEditPipeline(store: store)
    try await pipeline.migrateLegacyBuiltInBackgroundAssets()
    let manifest = await pipeline.snapshot()
    let migrated = try #require(manifest.assets.first)

    #expect(migrated.id == legacy.id)
    #expect(migrated.contentHash == "veloedit-background-v3-curtain-640x360")
    #expect(FileManager.default.fileExists(atPath: migrated.originalURL.path))
    #expect(manifest.timelines.last?.items.first?.assetID == legacy.id)
}

@Test func everyNonSolidBackgroundHasMotionAndCategory() {
    let nonSolid = BackgroundPreset.allCases.filter { !$0.isSolid }
    let solid = BackgroundPreset.allCases.filter(\.isSolid)

    #expect(!nonSolid.isEmpty)
    #expect(nonSolid.allSatisfy { $0.animationMotion != nil })
    #expect(nonSolid.allSatisfy { $0.animationStyle != nil })
    #expect(solid.allSatisfy { $0.animationMotion == nil })
    #expect(solid.allSatisfy { $0.animationStyle == nil })
    #expect(Set(BackgroundPreset.allCases.map(\.category)) == Set(BackgroundCategory.allCases))
    #expect(BackgroundPreset.catalogPresets.allSatisfy { $0.isVisibleInCatalog })
    #expect(BackgroundPreset.catalogPresets.contains(.curtain))
    #expect(BackgroundPreset.catalogPresets.contains(.underwater))
    #expect(!BackgroundPreset.catalogPresets.contains(.checkerboard))
    #expect(!BackgroundPreset.catalogPresets.contains(.energy))
    #expect(!BackgroundPreset.catalogPresets.contains(.glowingLines))
    #expect(!BackgroundPreset.catalogPresets.contains(.bubbles))
    #expect(!BackgroundPreset.catalogPresets.contains(.fire))
    #expect(!BackgroundPreset.catalogPresets.contains(.smoke))
    #expect(!BackgroundPreset.catalogPresets.contains(.bokeh))
}

@Test func projectRoundTripPreservesDirectorConversation() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("veloedit")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try ProjectStore(createAt: root, name: "Диалог")
    let userMessage = ProjectDirectorMessage(role: .user, text: "Сделай начало спокойнее")
    let assistantMessage = ProjectDirectorMessage(role: .assistant, text: "Понял, начну с плавных кадров.")
    let state = ProjectWorkspaceState(
        prompt: "Спокойное начало",
        preset: .story,
        targetMinutes: 2,
        directorMessages: [userMessage, assistantMessage]
    )

    try await store.update { $0.workspaceState = state }

    let reopened = try ProjectStore(open: root)
    let messages = await reopened.manifest.workspaceState?.directorMessages
    #expect(messages == [userMessage, assistantMessage])
}

@Test func projectRoundTripPreservesDirectorMusicChoice() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("veloedit")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try ProjectStore(createAt: root, name: "Свой саундтрек")
    let trackID = UUID()
    let state = ProjectWorkspaceState(
        prompt: "Динамичный фильм",
        preset: .adventure,
        targetMinutes: 2,
        directorMusicTrackID: trackID
    )

    try await store.update { $0.workspaceState = state }

    let reopened = try ProjectStore(open: root)
    #expect(await reopened.manifest.workspaceState?.directorMusicTrackID == trackID)
}

@Test func legacyWorkspaceStateDecodesWithoutDirectorConversation() throws {
    let state = ProjectWorkspaceState(prompt: "Старый проект", preset: .adventure, targetMinutes: 2)
    var object = try JSONSerialization.jsonObject(with: JSONEncoder.veloEdit.encode(state)) as! [String: Any]
    object.removeValue(forKey: "directorMessages")
    object.removeValue(forKey: "directorMusicTrackID")

    let decoded = try JSONDecoder.veloEdit.decode(
        ProjectWorkspaceState.self,
        from: JSONSerialization.data(withJSONObject: object)
    )

    #expect(decoded.directorMessages == nil)
    #expect(decoded.directorMusicTrackID == nil)
}

@Test func cacheKeyChangesWithSchema() {
    let asset = MediaAsset(originalURL: URL(fileURLWithPath: "/tmp/a.mov"), kind: .video, byteSize: 1, contentHash: "hash", metadata: MediaMetadata())
    let paths = CachePaths(root: URL(fileURLWithPath: "/tmp/cache"))
    #expect(paths.analysisKey(for: asset, schemaVersion: 1) != paths.analysisKey(for: asset, schemaVersion: 2))
}

@Test func expansionFiltersSupportedFiles() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    _ = FileManager.default.createFile(atPath: root.appendingPathComponent("clip.MOV").path, contents: Data("video".utf8))
    _ = FileManager.default.createFile(atPath: root.appendingPathComponent("photo.HEIC").path, contents: Data("photo".utf8))
    _ = FileManager.default.createFile(atPath: root.appendingPathComponent("music.MP3").path, contents: Data("audio".utf8))
    _ = FileManager.default.createFile(atPath: root.appendingPathComponent("note.txt").path, contents: Data())
    let importer = MediaImporter()
    let files = importer.expand([root])
    #expect(files.map(\.lastPathComponent) == ["clip.MOV", "photo.HEIC"])
    #expect(importer.expandAudio([root]).map(\.lastPathComponent) == ["music.MP3"])
}

@Test func streamingHashIsStable() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try Data("VeloEdit".utf8).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(try MediaImporter.sha256(url: url) == MediaImporter.sha256(url: url))
    #expect(try MediaImporter.sha256(url: url).count == 64)
}

@Test func quickFingerprintIsStableAndDetectsChangedTail() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    var data = Data(repeating: 7, count: 200_000)
    try data.write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    let first = try MediaImporter.quickFingerprint(url: url, byteSize: Int64(data.count), modificationDate: nil)
    let second = try MediaImporter.quickFingerprint(url: url, byteSize: Int64(data.count), modificationDate: nil)
    #expect(first == second)
    data[data.count - 1] = 8
    try data.write(to: url)
    let changed = try MediaImporter.quickFingerprint(url: url, byteSize: Int64(data.count), modificationDate: nil)
    #expect(changed != first)
}

@Test func legacyAssetJSONDecodesWithoutFullHash() throws {
    let asset = MediaAsset(originalURL: URL(fileURLWithPath: "/tmp/legacy.mov"), kind: .video, byteSize: 1, contentHash: "fast", metadata: MediaMetadata())
    var object = try JSONSerialization.jsonObject(with: JSONEncoder.veloEdit.encode(asset)) as! [String: Any]
    object.removeValue(forKey: "fullContentHash")
    let decoded = try JSONDecoder.veloEdit.decode(MediaAsset.self, from: JSONSerialization.data(withJSONObject: object))
    #expect(decoded.fullContentHash == nil)
}

@Test func pipelinePersistsAssetAndTimelineEdits() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("veloedit")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try ProjectStore(createAt: root, name: "Монтаж")
    let first = MediaAsset(originalURL: URL(fileURLWithPath: "/tmp/first.mov"), kind: .video, byteSize: 1, contentHash: "first", metadata: MediaMetadata(duration: 30))
    let second = MediaAsset(originalURL: URL(fileURLWithPath: "/tmp/second.mov"), kind: .video, byteSize: 1, contentHash: "second", metadata: MediaMetadata(duration: 30))
    let candidate = Candidate(assetID: first.id, sourceStart: 0, sourceDuration: 5, scores: ClipScores(quality: 1, interest: 1, action: 1, stability: 1))
    let firstItem = TimelineItem(candidateID: candidate.id, assetID: first.id, kind: .video, sourceDuration: 5, timelineStart: 0, timelineDuration: 5)
    let secondItem = TimelineItem(assetID: second.id, kind: .video, sourceDuration: 4, timelineStart: 5, timelineDuration: 4)
    let plan = StoryPlan(prompt: "Фильм", preset: .story, constraints: .init(), chapters: [StoryChapter(title: "Фильм", candidateIDs: [candidate.id])])
    try await store.update { project in
        project.assets = [first, second]
        project.analyses = [AnalysisResult(assetID: first.id, analyzedContentHash: first.contentHash, candidates: [candidate])]
        project.storyPlans = [plan]
        project.timelines = [Timeline(storyPlanID: plan.id, items: [firstItem, secondItem])]
    }
    let pipeline = VeloEditPipeline(store: store)

    try await pipeline.updateAsset(id: first.id, favorite: true, excluded: true)
    try await pipeline.moveTimelineItem(id: secondItem.id, offset: -1)
    try await pipeline.updateTimelineItem(id: firstItem.id, sourceStart: 2, timelineDuration: 7, locked: true, transition: "cross-dissolve", updateTransition: true)

    let edited = await pipeline.snapshot()
    #expect(edited.assets.first?.favorite == true)
    #expect(edited.assets.first?.excluded == true)
    #expect(edited.timelines.last?.items.map(\.id) == [secondItem.id, firstItem.id])
    #expect(edited.timelines.last?.items[1].timelineStart == 4)
    #expect(edited.timelines.last?.items[1].sourceStart == 2)
    #expect(edited.timelines.last?.items[1].timelineDuration == 7)
    #expect(edited.timelines.last?.items[1].transition == "cross-dissolve")
    #expect(edited.analyses.first?.candidates.first?.locked == true)

    try await pipeline.updateAsset(id: first.id, excluded: false)
    let returnedToSelection = await pipeline.snapshot()
    #expect(returnedToSelection.assets.first?.excluded == false)
}

@Test func timelineSupportsDirectReorderingAndSpeedAwareEdgeTrimming() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("veloedit")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try ProjectStore(createAt: root, name: "Ручной монтаж")
    let asset = MediaAsset(
        originalURL: URL(fileURLWithPath: "/tmp/source.mov"),
        kind: .video,
        byteSize: 1,
        contentHash: "source",
        metadata: MediaMetadata(duration: 10)
    )
    let first = TimelineItem(assetID: asset.id, kind: .video, sourceStart: 2, sourceDuration: 6, timelineStart: 0, timelineDuration: 3, speed: 2)
    let second = TimelineItem(assetID: asset.id, kind: .video, sourceDuration: 1, timelineStart: 3, timelineDuration: 1)
    let third = TimelineItem(assetID: asset.id, kind: .video, sourceDuration: 2, timelineStart: 4, timelineDuration: 2)
    let plan = StoryPlan(prompt: "Фильм", preset: .story, constraints: .init(), chapters: [])
    try await store.update { project in
        project.assets = [asset]
        project.storyPlans = [plan]
        project.timelines = [Timeline(storyPlanID: plan.id, items: [first, second, third])]
    }
    let pipeline = VeloEditPipeline(store: store)

    try await pipeline.moveTimelineItem(id: first.id, toIndex: 2)
    try await pipeline.updateTimelineItem(id: first.id, sourceStart: 4, timelineDuration: 2)
    try await pipeline.updateTimelineItem(id: first.id, timelineDuration: 20)

    let edited = await pipeline.snapshot()
    #expect(edited.timelines.last?.items.map(\.id) == [second.id, third.id, first.id])
    #expect(edited.timelines.last?.items.map(\.timelineStart) == [0, 1, 3])
    #expect(edited.timelines.last?.items[2].sourceStart == 4)
    #expect(edited.timelines.last?.items[2].timelineDuration == 3)
    #expect(edited.timelines.last?.items[2].sourceDuration == 6)
}

@Test func connectedClipKeepsItsOffsetWhenPrimaryStorylineReorders() {
    let first = TimelineItem(kind: .video, sourceDuration: 4, timelineStart: 0, timelineDuration: 4)
    let second = TimelineItem(kind: .video, sourceDuration: 5, timelineStart: 4, timelineDuration: 5)
    let connected = TimelineItem(
        kind: .video,
        sourceDuration: 1,
        timelineStart: 2,
        timelineDuration: 1,
        overlay: OverlaySettings(style: .pictureInPicture, baseItemID: first.id, startOffset: 2)
    )

    let original = TimelineTiming.retimed([first, second, connected])
    #expect(original[2].timelineStart == 2)

    let reordered = TimelineTiming.retimed([second, first, connected])
    #expect(reordered[0].timelineStart == 0)
    #expect(reordered[1].timelineStart == 5)
    #expect(reordered[2].timelineStart == 7)
    #expect(reordered[2].overlay?.baseItemID == first.id)
}

@Test func pipelineSplitsSelectedClipAtAnExactTimelineFrame() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("veloedit")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try ProjectStore(createAt: root, name: "Split по playhead")
    let asset = MediaAsset(
        originalURL: URL(fileURLWithPath: "/tmp/split.mov"),
        kind: .video,
        byteSize: 1,
        contentHash: "split",
        metadata: MediaMetadata(duration: 10)
    )
    let item = TimelineItem(assetID: asset.id, kind: .video, sourceStart: 1, sourceDuration: 8, timelineStart: 0, timelineDuration: 8)
    let plan = StoryPlan(prompt: "Фильм", preset: .story, constraints: .init(), chapters: [])
    try await store.update { project in
        project.assets = [asset]
        project.storyPlans = [plan]
        project.timelines = [Timeline(storyPlanID: plan.id, frameRate: 30, items: [item])]
    }
    let pipeline = VeloEditPipeline(store: store)

    let createdRightID = try await pipeline.splitTimelineItem(id: item.id, atTimelineTime: 2.5)
    let rightID = try #require(createdRightID)
    let edited = try #require((await pipeline.snapshot()).timelines.last)
    #expect(edited.items.map(\.timelineDuration) == [2.5, 5.5])
    #expect(edited.items.map(\.sourceStart) == [1, 3.5])
    #expect(edited.items.map(\.sourceDuration) == [2.5, 5.5])
    #expect(edited.items[1].id == rightID)
    #expect(edited.items[1].timelineStart == 2.5)
}

@Test func detachedAudioMovesIndependentlyAndSurvivesMagneticVideoReorder() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("veloedit")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try ProjectStore(createAt: root, name: "Отделённый звук")
    let asset = MediaAsset(
        originalURL: URL(fileURLWithPath: "/tmp/audio.mov"),
        kind: .video,
        byteSize: 1,
        contentHash: "audio",
        metadata: MediaMetadata(duration: 12, hasAudio: true)
    )
    let first = TimelineItem(assetID: asset.id, kind: .video, sourceStart: 1, sourceDuration: 5, timelineStart: 0, timelineDuration: 5)
    let second = TimelineItem(assetID: asset.id, kind: .video, sourceStart: 6, sourceDuration: 4, timelineStart: 5, timelineDuration: 4)
    let plan = StoryPlan(prompt: "Фильм", preset: .story, constraints: .init(), chapters: [])
    try await store.update { project in
        project.assets = [asset]
        project.storyPlans = [plan]
        project.timelines = [Timeline(storyPlanID: plan.id, items: [first, second])]
    }
    let pipeline = VeloEditPipeline(store: store)

    let createdAudioID = try await pipeline.detachAudio(from: first.id)
    let audioID = try #require(createdAudioID)
    try await pipeline.updateAudioClip(id: audioID, timelineStart: 3)
    try await pipeline.updateAudioClip(id: audioID, timelineDuration: 2)
    try await pipeline.movePrimaryTimelineItem(id: first.id, toPrimaryIndex: 1)

    let edited = try #require((await pipeline.snapshot()).timelines.last)
    let audio = try #require(edited.effectiveAudioClips.first(where: { $0.id == audioID }))
    #expect(edited.items.map(\.id) == [second.id, first.id])
    #expect(edited.items[1].effectiveAudioAdjustments.muted)
    #expect(audio.timelineStart == 3)
    #expect(audio.sourceDuration == 2)
    #expect(audio.timelineDuration == 2)
    #expect(audio.assetID == asset.id)
    #expect(audio.role == .detached)
}

@Test func productionTimelineSequenceStaysGapFreeAndPersistsAfterManyEdits() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("veloedit")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try ProjectStore(createAt: root, name: "12 клипов")
    let asset = MediaAsset(
        originalURL: URL(fileURLWithPath: "/tmp/twelve.mov"),
        kind: .video,
        byteSize: 1,
        contentHash: "twelve",
        metadata: MediaMetadata(duration: 60, frameRate: 30, hasAudio: true)
    )
    let items = (0..<12).map { index in
        TimelineItem(
            assetID: asset.id,
            kind: .video,
            sourceStart: Double(index * 2),
            sourceDuration: 2,
            timelineStart: Double(index * 2),
            timelineDuration: 2
        )
    }
    let initialTimeline = Timeline(storyPlanID: UUID(), frameRate: 30, items: items)
    try await store.update { project in
        project.assets = [asset]
        project.timelines = [initialTimeline]
    }
    let pipeline = VeloEditPipeline(store: store)

    try await pipeline.movePrimaryTimelineItem(id: items[0].id, toPrimaryIndex: 10)
    _ = try await pipeline.insertAssetIntoTimeline(assetID: asset.id, at: 4)
    try await pipeline.deleteTimelineItem(id: items[5].id)
    let beforeSplit = try #require((await pipeline.snapshot()).timelines.last)
    let splitTarget = try #require(beforeSplit.items.first(where: { $0.overlay == nil && $0.timelineDuration == 2 }))
    _ = try await pipeline.splitTimelineItem(id: splitTarget.id, atTimelineTime: splitTarget.timelineStart + 0.5)
    let overlayID = try await pipeline.insertAssetAsOverlay(assetID: asset.id, atTime: 3.25, style: .pictureInPicture)
    try await pipeline.moveConnectedTimelineItem(id: overlayID, toTimelineStart: 6.5)
    let createdAudioID = try await pipeline.detachAudio(from: items[1].id)
    let audioID = try #require(createdAudioID)
    try await pipeline.updateAudioClip(id: audioID, timelineStart: 7)

    let edited = try #require((await pipeline.snapshot()).timelines.last)
    var cursor = 0.0
    for item in edited.items.filter({ $0.overlay == nil }) {
        #expect(abs(item.timelineStart - cursor) < 0.000_001)
        cursor += item.timelineDuration
    }
    #expect(abs(cursor - edited.duration) < 0.000_001)
    #expect(edited.items.first(where: { $0.id == overlayID })?.timelineStart == 6.5)
    #expect(edited.effectiveAudioClips.first(where: { $0.id == audioID })?.timelineStart == 7)

    try await pipeline.replaceLatestTimeline(with: initialTimeline)
    #expect((await pipeline.snapshot()).timelines.last?.items.count == 12)
    try await pipeline.replaceLatestTimeline(with: edited)
    let reopened = try ProjectStore(open: root)
    let reopenedManifest = await reopened.manifest
    let persisted = try #require(reopenedManifest.timelines.last)
    #expect(persisted.id == edited.id)
    #expect(persisted.items == edited.items)
    #expect(persisted.effectiveAudioClips == edited.effectiveAudioClips)
    #expect(persisted.duration == edited.duration)
}

@Test func magicBrushSlicesBoundariesAndChangesOnlyTheRequestedRange() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("veloedit")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try ProjectStore(createAt: root, name: "Локальная кисть")
    let asset = MediaAsset(
        originalURL: URL(fileURLWithPath: "/tmp/brush.mov"),
        kind: .video,
        byteSize: 1,
        contentHash: "brush",
        metadata: MediaMetadata(duration: 10)
    )
    let source = TimelineItem(assetID: asset.id, kind: .video, sourceDuration: 10, timelineStart: 0, timelineDuration: 10)
    let plan = StoryPlan(prompt: "Фильм", preset: .story, constraints: .init(), chapters: [])
    try await store.update { project in
        project.assets = [asset]
        project.storyPlans = [plan]
        project.timelines = [Timeline(storyPlanID: plan.id, items: [source])]
    }
    let pipeline = VeloEditPipeline(store: store)

    let report = try await pipeline.applyEditorCommands("Замедли этот момент", timelineRange: 2...4)
    let snapshot = await pipeline.snapshot()
    let edited = try #require(snapshot.timelines.last)

    #expect(report.hasChanges)
    #expect(edited.items.count == 3)
    #expect(edited.items.map(\.sourceStart) == [0, 2, 4])
    #expect(edited.items.map(\.sourceDuration) == [2, 2, 6])
    #expect(edited.items.map(\.speed) == [1, 0.5, 1])
    #expect(edited.items.map(\.timelineStart) == [0, 2, 6])
    #expect(edited.items.map(\.timelineDuration) == [2, 4, 6])
}

@Test func magicBrushRejectsCommandsThatWouldLeakAcrossTheWholeFilm() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("veloedit")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try ProjectStore(createAt: root, name: "Без утечек")
    let item = TimelineItem(kind: .photo, sourceDuration: 5, timelineStart: 0, timelineDuration: 5)
    let plan = StoryPlan(prompt: "Фильм", preset: .story, constraints: .init(), chapters: [])
    try await store.update { project in
        project.storyPlans = [plan]
        project.timelines = [Timeline(storyPlanID: plan.id, items: [item])]
    }
    let pipeline = VeloEditPipeline(store: store)

    let report = try await pipeline.applyEditorCommands("Добавь энергичную музыку", timelineRange: 1...3)
    let snapshot = await pipeline.snapshot()
    let edited = try #require(snapshot.timelines.last)

    #expect(!report.hasChanges)
    #expect(!report.ignored.isEmpty)
    #expect(edited.items == [item])
    #expect(edited.music == nil)
}

@Test func magicBrushSlicesAndUpdatesEveryStandaloneTrack() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("veloedit")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try ProjectStore(createAt: root, name: "Кисть на всех дорожках")
    let plan = StoryPlan(prompt: "Фильм", preset: .story, constraints: .init(), chapters: [])
    let base = TimelineItem(kind: .photo, sourceDuration: 10, timelineStart: 0, timelineDuration: 10)
    let audio = TimelineAudioClip(title: "Музыка", role: .music, sourceDuration: 10, timelineStart: 0, timelineDuration: 10)
    let telemetry = TimelineTelemetryItem(sourceStart: 0, timelineStart: 0, timelineDuration: 10)
    let effect = EffectTimelineItem(effectType: .glow, startTime: 0, duration: 10)
    let title = TitleTimelineItem(kind: .title, text: "Текст", startTime: 0, duration: 10)
    try await store.update { project in
        project.storyPlans = [plan]
        project.timelines = [Timeline(
            storyPlanID: plan.id,
            items: [base],
            audioClips: [audio],
            telemetryItems: [telemetry],
            effects: [effect],
            titleItems: [title]
        )]
    }
    let pipeline = VeloEditPipeline(store: store)

    let report = try await pipeline.applyEditorCommands(
        [.setClipVolume(0.25, .selected), .setOpacity(0.4, .selected)],
        timelineRange: 2...4
    )
    let edited = try #require((await pipeline.snapshot()).timelines.last)

    #expect(report.hasChanges)
    #expect(edited.effectiveAudioClips.count == 3)
    #expect(edited.effectiveTelemetryItems.count == 3)
    #expect(edited.effectiveEffects.count == 3)
    #expect(edited.effectiveTitleItems.count == 3)
    #expect(edited.effectiveAudioClips.first(where: { $0.timelineStart == 2 })?.adjustments.volume == 0.25)
    #expect(edited.effectiveTelemetryItems.first(where: { $0.timelineStart == 2 })?.settings.effectiveOpacity == 0.4)
    #expect(edited.effectiveEffects.first(where: { $0.startTime == 2 })?.intensity == 0.4)
    #expect(edited.effectiveTitleItems.first(where: { $0.startTime == 2 })?.style.effectiveOpacity == 0.4)
}

@Test func removingAssetCleansDependentProjectData() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("veloedit")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try ProjectStore(createAt: root, name: "Удаление")
    let asset = MediaAsset(originalURL: URL(fileURLWithPath: "/tmp/remove.mov"), kind: .video, byteSize: 1, contentHash: "remove", metadata: MediaMetadata(duration: 10))
    let candidate = Candidate(assetID: asset.id, sourceStart: 0, sourceDuration: 5, scores: ClipScores(quality: 1, interest: 1, action: 1, stability: 1))
    let plan = StoryPlan(prompt: "Фильм", preset: .story, constraints: .init(), chapters: [StoryChapter(title: "Фильм", candidateIDs: [candidate.id])])
    try await store.update { project in
        project.assets = [asset]
        project.analyses = [AnalysisResult(assetID: asset.id, analyzedContentHash: asset.contentHash, candidates: [candidate])]
        project.events = [Event(title: "Событие", assetIDs: [asset.id])]
        project.storyPlans = [plan]
        project.timelines = [Timeline(storyPlanID: plan.id, items: [TimelineItem(candidateID: candidate.id, assetID: asset.id, kind: .video, sourceDuration: 5, timelineStart: 0, timelineDuration: 5)])]
    }
    let pipeline = VeloEditPipeline(store: store)
    try await pipeline.removeAsset(id: asset.id)
    let project = await pipeline.snapshot()
    #expect(project.assets.isEmpty)
    #expect(project.analyses.isEmpty)
    #expect(project.events.isEmpty)
    #expect(project.storyPlans.first?.chapters.isEmpty == true)
    #expect(project.timelines.first?.items.isEmpty == true)
}
