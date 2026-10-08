import Foundation
import AppKit
import AVFoundation
import Testing
@testable import VeloEditCore
@testable import VeloEdit

@Suite(.serialized)
@MainActor
struct ProjectInteractionTests {
    @Test func updateRelaunchRestoresProjectEditsDraftsAndLibraryOnce() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let url = try fixture.project("Update")
        let otherURL = try fixture.project("Other")
        let defaults = UserDefaults(suiteName: fixture.suite)!
        defaults.set([otherURL.path], forKey: "recentProjectPaths.v1")
        defaults.set("preserved", forKey: "testUserPreference")
        let store = try ProjectStore(open: url)
        let item = TimelineItem(assetID: UUID(), kind: .video, sourceDuration: 10,
                                timelineStart: 0, timelineDuration: 10)
        try await store.update { $0.timelines = [Timeline(storyPlanID: UUID(), items: [item])] }
        let model = fixture.model()
        model.openRecentProject(url)
        try await wait { model.projectURL?.path == url.path && model.openingProjectURL == nil }
        model.section = .timeline
        model.directorInput = "Продолжить с крупного плана"
        model.feedback = "Сохранённый черновик"
        model.trimTimelineItem(id: item.id, sourceStart: 0, timelineDuration: 7)
        #expect(await model.stopForApplicationTermination())
        #expect(await model.saveProjectForUpdateRelaunch())

        let relaunched = fixture.model()
        relaunched.restoreProjectAfterUpdateIfNeeded()
        try await wait { relaunched.projectURL?.path == url.path && relaunched.openingProjectURL == nil }
        #expect(relaunched.section == .timeline)
        #expect(relaunched.directorInput == "Продолжить с крупного плана")
        #expect(relaunched.feedback == "Сохранённый черновик")
        #expect(relaunched.timeline?.items.first?.timelineDuration == 7)
        #expect(relaunched.recentProjectURLs.contains { $0.path == otherURL.path })
        #expect(defaults.string(forKey: "testUserPreference") == "preserved")
        #expect(await relaunched.flushAutosave())

        let ordinaryLaunch = fixture.model()
        ordinaryLaunch.restoreProjectAfterUpdateIfNeeded()
        try await Task.sleep(for: .milliseconds(30))
        #expect(ordinaryLaunch.projectURL == nil)
        #expect(ordinaryLaunch.openingProjectURL == nil)
    }

    @Test func updateRelaunchRetriesFailedProjectOpen() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let url = try fixture.project("Retry")
        let model = fixture.model()
        model.openRecentProject(url)
        try await wait { model.projectURL?.path == url.path && model.openingProjectURL == nil }
        model.directorInput = "Сохранить этот черновик"
        #expect(await model.saveProjectForUpdateRelaunch())
        let failed = AppModel(defaults: UserDefaults(suiteName: fixture.suite)!, startBackgroundServices: false,
                              loadProject: { _ in throw CocoaError(.fileReadNoPermission) })
        failed.restoreProjectAfterUpdateIfNeeded()
        try await wait { failed.errorMessage != nil && failed.openingProjectURL == nil }

        let retry = fixture.model()
        retry.restoreProjectAfterUpdateIfNeeded()
        try await wait { retry.projectURL?.path == url.path && retry.openingProjectURL == nil }
        #expect(retry.directorInput == "Сохранить этот черновик")
        #expect(await retry.flushAutosave())
    }

    @Test func updateRelaunchWaitsForStorageAndNonResumableWork() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let model = fixture.model()
        model.storageIsCleaning = true
        model.isWorking = true
        var ready = false
        let task = Task { await model.waitForUpdateSafePoint(); ready = true }
        defer { task.cancel() }
        try await Task.sleep(for: .milliseconds(150))
        #expect(!ready)
        model.storageIsCleaning = false
        try await Task.sleep(for: .milliseconds(150))
        #expect(!ready)
        model.isWorking = false
        try await wait { ready }
        await task.value
    }

    @Test func updateRelaunchPreservesResumableJobInsteadOfCancellingIt() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let url = try fixture.project("Checkpoint")
        let store = try ProjectStore(open: url)
        let job = try await store.beginAutonomousJob(kind: .film)
        let model = fixture.model()
        model.pipeline = VeloEditPipeline(store: store)
        model.projectURL = url
        model.project = await store.manifest
        model.isWorking = true
        model.isCreatingFilm = true
        var ready = false
        let task = Task { await model.waitForUpdateSafePoint(); ready = true }
        defer { task.cancel() }
        try await wait { ready }
        #expect(await model.stopForApplicationTermination(preserveProgress: true))
        #expect(await model.saveProjectForUpdateRelaunch())
        let reopened = try ProjectStore(open: url)
        #expect(await reopened.manifest.autonomousJob?.id == job.id)
        #expect(await reopened.manifest.autonomousJob?.explicitCancellation == false)
        #expect(await reopened.manifest.autonomousJob?.state.resumesAutomatically == true)
    }

    @Test func updateRelaunchDoesNotProceedWhenSavingFails() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let url = fixture.root.appendingPathComponent("Failure.veloedit")
        let recovery = fixture.root.appendingPathComponent("recovery")
        let store = try ProjectStore(createAt: url, name: "Failure", recoveryDirectory: recovery)
        let model = fixture.model()
        model.pipeline = VeloEditPipeline(store: store)
        model.projectURL = url
        model.project = await store.manifest
        model.directorInput = "Несохранённый черновик"
        // Simulate both the project volume and its fallback becoming unwritable.
        try Data([1]).write(to: recovery)
        try FileManager.default.removeItem(at: url)
        #expect(await model.saveProjectForUpdateRelaunch() == false)
        #expect(model.errorMessage != nil)
        let relaunched = fixture.model()
        relaunched.restoreProjectAfterUpdateIfNeeded()
        try await Task.sleep(for: .milliseconds(30))
        #expect(relaunched.projectURL == nil)
        #expect(relaunched.openingProjectURL == nil)
    }

    @Test func renamingTheOpenProjectFromItsHomeCardKeepsAutosaveAndReopeningHealthy() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let url = try fixture.project("Original")
        let model = fixture.model()
        let store = try ProjectStore(open: url)
        model.pipeline = VeloEditPipeline(store: store)
        model.projectURL = url
        model.project = await store.manifest
        model.section = .home

        model.renameRecentProject(url, to: "  Поездка 🚲  ")
        try await wait { !model.isWorking && model.project?.name == "Поездка 🚲" }
        #expect(model.projectURL == url)
        #expect(await model.flushAutosave())
        #expect(model.errorMessage == nil)
        #expect(ProjectSummary.load(from: url)?.name == "Поездка 🚲")
        let reopened = try ProjectStore(open: url)
        #expect(await reopened.manifest.name == "Поездка 🚲")

        model.renameProject(to: "Следующее имя")
        try await wait { !model.isWorking && model.project?.name == "Следующее имя" }
        #expect(await model.flushAutosave())
        #expect(try await store.verifyDurableState() == .project)
    }

    @Test func renamingAnInactiveCardDoesNotChangeTheOpenProject() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let activeURL = try fixture.project("Active")
        let otherURL = try fixture.project("Other")
        let model = fixture.model()
        let store = try ProjectStore(open: activeURL)
        model.pipeline = VeloEditPipeline(store: store)
        model.projectURL = activeURL
        model.project = await store.manifest
        model.renameRecentProject(otherURL, to: "Новое название")
        try await wait { ProjectSummary.load(from: otherURL)?.name == "Новое название" }
        #expect(model.project?.name == "Active")
        #expect(model.projectURL == activeURL)
        #expect(await model.flushAutosave())
        #expect(model.errorMessage == nil)
        let reopened = try ProjectStore(open: otherURL)
        #expect(await reopened.manifest.name == "Новое название")
    }

    @Test(arguments: [60.0, 120.0, 120_000.0 / 1001])
    func maximumExportUsesOriginalsInLegacyThirtyFPSProjects(high: Double) throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let model = fixture.model()
        let assets = [30.0, high, 240.0].enumerated().map { index, fps in
            MediaAsset(originalURL: fixture.root.appendingPathComponent("source-\(index).mov"), kind: .video,
                byteSize: 1, contentHash: "\(index)", metadata: MediaMetadata(duration: 10, frameRate: fps))
        }
        let timeline = Timeline(storyPlanID: UUID(), frameRate: 30, items: assets.prefix(2).enumerated().map { index, asset in
            TimelineItem(assetID: asset.id, kind: .video, sourceDuration: 10,
                timelineStart: Double(index) * 10, timelineDuration: 10)
        })
        model.project = ProjectManifest(name: "Legacy mixed rates", assets: assets, timelines: [timeline])
        #expect(model.maximumSourceFrameRate == high)
        #expect(model.exportFrameRateOptions.contains(high))
        #expect(!model.exportFrameRateOptions.contains(240))
        #expect(model.exportSettingsSummary(quality: .maximum).contains("\(ExportVideoSettings.frameRateLabel(high)) кадров/с"))
        #expect(model.exportSettingsSummary(quality: .maximum, frameRate: 30).contains("30 кадров/с"))
        #expect(model.timeline?.frameRate == 30)
        #expect(model.project?.timelines.first?.frameRate == 30)
    }

    @Test func deletingMissingRecentProjectRemovesAndPersistsCard() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let missingURL = try fixture.project("тест в универе")
        let existingURL = try fixture.project("keep")
        let defaults = UserDefaults(suiteName: fixture.suite)!
        defaults.set([missingURL.path, existingURL.path], forKey: "recentProjectPaths.v1")
        let model = fixture.model()
        try FileManager.default.removeItem(at: missingURL)

        model.deleteRecentProject(missingURL)

        let expectedPaths = [existingURL.standardizedFileURL.path]
        try await wait { model.recentProjectURLs.map(\.path) == expectedPaths }
        #expect(model.errorMessage == nil)
        #expect(model.status == "Проект удалён из списка")
        #expect(defaults.stringArray(forKey: "recentProjectPaths.v1") == expectedPaths)
        #expect(fixture.model().recentProjectURLs.map(\.path) == expectedPaths)
        #expect(FileManager.default.fileExists(atPath: existingURL.path))
    }

    @Test func openPanelSelectsProjectPackagesInsteadOfOrdinaryFolders() {
        let panel = AppModel.makeProjectOpenPanel()
        #expect(panel.canChooseFiles)
        #expect(!panel.canChooseDirectories)
        #expect(!panel.treatsFilePackagesAsDirectories)
        #expect(!panel.allowsMultipleSelection)
        #expect(panel.allowedContentTypes.map(\.identifier) == ["app.veloedit.project"])
        let directory = FileManager.default.temporaryDirectory
        let savePanel = AppModel.makeVideoSavePanel(directory: directory, suggestedName: "Film.mp4")
        #expect(savePanel.directoryURL?.standardizedFileURL.path == directory.standardizedFileURL.path)
        #expect(savePanel.nameFieldStringValue == "Film.mp4")
        #expect(savePanel.allowedContentTypes.map(\.identifier) == ["public.mpeg-4"])
        #expect(!savePanel.isExtensionHidden)
    }

    @Test func finderOpenBeforeWindowAppearsLoadsSavedProject() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let url = try fixture.project("finder-open")
        let delegate = VeloEditAppDelegate()
        delegate.application(NSApplication.shared, open: [url])
        let model = fixture.model()
        delegate.model = model
        try await wait { model.projectURL == url && model.openingProjectURL == nil }
        #expect(model.project?.name == "finder-open")
        #expect(model.errorMessage == nil)
        #expect(model.videoExportDirectoryURL == url.deletingLastPathComponent())
        await model.flushAutosave()
    }

    @Test func vlogStylePreservesExplicitPreferencesAndRestoresPreviousPresetAfterReopen() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let url = try fixture.project("vlog-preferences")
        let model = fixture.model()
        model.openRecentProject(url)
        try await wait { model.projectURL == url && model.openingProjectURL == nil }
        model.selectPreset(.story)
        model.setDirectorMusicPolicy(.none)
        model.setDirectorSourceAudioPolicy(.mute)
        model.setDirectorTitlePolicy(.none)
        model.setDirectorEffectsPolicy(.none)
        model.setDirectorNarrativeMood(.dynamic)
        model.setDirectorSubtitleStyle(.travel)
        model.selectPreset(.vlog)
        #expect(model.directorBrief.mood == .dynamic)
        #expect(model.directorBrief.previousStandardPreset == .story)
        #expect(model.directorBrief.musicPolicy == .none)
        #expect(model.directorBrief.sourceAudioPolicy == .mute)
        #expect(model.directorBrief.titlePolicy == .none)
        #expect(model.directorBrief.subtitlePolicy == .off)
        await model.flushAutosave()
        let reopened = fixture.model()
        reopened.openRecentProject(url)
        try await wait { reopened.projectURL == url && reopened.openingProjectURL == nil }
        #expect(reopened.preset == .vlog)
        #expect(reopened.directorBrief.subtitlePolicy == .off)
        #expect(reopened.directorBrief.subtitleStyle == .travel)
        reopened.selectStandardDirectorMood(.calm)
        #expect(reopened.preset == .story)
        #expect(reopened.directorBrief.mood == .calm)
        #expect(reopened.directorBrief.musicPolicy == .none)
        #expect(reopened.directorBrief.subtitleStyle == .travel)
        await reopened.flushAutosave()
        let otherURL = try fixture.project("separate-subtitle-choice")
        let other = fixture.model()
        other.openRecentProject(otherURL)
        try await wait { other.projectURL == otherURL && other.openingProjectURL == nil }
        #expect(other.directorBrief.subtitleStyle == nil)
    }

    @Test func projectWorkspaceAppearsBeforeManifestLoadsAndKeepsNavigation() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let url = try fixture.project("instant-workspace")
        let gate = ProjectLoadGate()
        let model = AppModel(defaults: UserDefaults(suiteName: fixture.suite)!, startBackgroundServices: false,
            personalTasteStore: LocalPersonalTasteStore(url: fixture.root.appendingPathComponent("taste.json")),
            loadProject: { url in
                await gate.wait()
                return try await Task.detached { try ProjectStore(open: url) }.value
            })

        model.openRecentProject(url, name: "Мой фильм")
        try await wait { model.openingProjectURL == url }
        #expect(model.hasProjectWorkspace)
        #expect(model.section == .media)
        #expect(model.openingProjectName == "Мой фильм")
        #expect(model.project == nil)
        #expect(model.pipeline == nil)
        #expect(!model.isWorking)
        #expect(!model.status.contains("Открываю"))

        model.openSection(.export)
        #expect(model.section == .export)
        await gate.release()
        try await wait { model.projectURL == url && model.openingProjectURL == nil }
        #expect(model.section == .export)
        #expect(model.openingProjectName == nil)
        #expect(model.project?.name == "instant-workspace")
        await model.flushAutosave()
    }

    @Test func recentCardShowsRealMaterialsBeforeFullLoadAndPreservesSelection() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let url = try fixture.project("instant-materials")
        let store = try ProjectStore(open: url)
        let asset = MediaAsset(originalURL: fixture.root.appendingPathComponent("ride.mov"), kind: .video,
                               byteSize: 1, contentHash: "ride", metadata: MediaMetadata(duration: 12))
        try await store.update { $0.assets = [asset] }
        let gate = ProjectLoadGate()
        let model = AppModel(defaults: UserDefaults(suiteName: fixture.suite)!, startBackgroundServices: false,
            personalTasteStore: LocalPersonalTasteStore(url: fixture.root.appendingPathComponent("taste.json")),
            loadProject: { _ in await gate.wait(); return store })
        // This is the same preload performed by a card on the home screen.
        await model.prepareProjectPresentation(at: url)
        let started = Date()
        model.openRecentProject(url)
        try await wait { model.openingProjectURL == url }
        print("PERF recent-card-first-materials milliseconds=\(Date().timeIntervalSince(started) * 1_000)")
        #expect(model.project == nil)
        #expect(model.pipeline == nil)
        #expect(model.mediaLibraryAssets.map(\.id) == [asset.id])
        let thumbnail = model.mediaLibraryThumbnailURLs[asset.id]
        #expect(thumbnail?.lastPathComponent == "ride.jpg")
        model.selectAssetForMediaInspector(asset.id)
        #expect(model.mediaLibrarySelectedAssetID == asset.id)
        await gate.release()
        try await wait { model.openingProjectURL == nil && model.projectURL == url }
        #expect(model.mediaLibraryAssets.map(\.id) == [asset.id])
        #expect(model.selectedAssetID == asset.id)
        #expect(model.openingPresentation == nil)
        await model.flushAutosave()
    }

    @Test func coldOpenLoadsPresentationWithoutWaitingForTheStore() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let url = try fixture.project("cold-open")
        let gate = ProjectLoadGate()
        let model = AppModel(defaults: UserDefaults(suiteName: fixture.suite)!, startBackgroundServices: false,
            personalTasteStore: LocalPersonalTasteStore(url: fixture.root.appendingPathComponent("taste.json")),
            loadProject: { url in
                await gate.wait()
                return try await Task.detached { try ProjectStore(open: url) }.value
            })
        model.openRecentProject(url)
        try await wait { model.openingPresentation?.preview.name == "cold-open" }
        #expect(model.pipeline == nil)
        #expect(model.openingProjectURL == url)
        await gate.release()
        try await wait { model.openingProjectURL == nil && model.projectURL == url }
        await model.flushAutosave()
    }

    @Test func soundtrackMoveKeepsSourceWindowAndUndoWorksOutsideMontage() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let url = try fixture.project("soundtrack-undo")
        let trackID = UUID()
        let audioURL = fixture.root.appendingPathComponent("window.caf")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480_000))
        buffer.frameLength = buffer.frameCapacity
        buffer.floatChannelData![0].initialize(repeating: 0, count: Int(buffer.frameLength))
        try AVAudioFile(forWriting: audioURL, settings: format.settings).write(from: buffer)
        let track = LocalMusicTrack(id: trackID, title: "Window", author: "Fixture", bpm: 110, genres: [], moods: [], energy: 0.5,
            duration: 60, license: .userFile(), sourceProvider: .user, sourcePageURL: audioURL, localFileURL: audioURL, originalFileName: "window.caf")
        var music = MusicDirective(style: .energetic, bpm: 110, speed: 1.25, trackID: trackID)
        music.sourceStart = 12
        let timeline = Timeline(storyPlanID: UUID(), items: [.init(kind: .title, sourceDuration: 15, timelineStart: 0, timelineDuration: 15, title: "Window")], music: music)
        let store = try ProjectStore(open: url)
        try await store.update { $0.timelines = [timeline] }
        try JSONEncoder.veloEdit.encode([track]).write(to: store.musicLibraryURL.appendingPathComponent("tracks.json"))
        let model = fixture.model()
        model.openRecentProject(url)
        try await wait { model.projectURL == url && model.openingProjectURL == nil }
        await model.refreshMusicLibrary()
        try await wait { model.musicTracks.contains { $0.id == trackID } }
        #expect(model.section != .timeline)
        #expect(model.shouldHandleTimelineUndo)
        let original = model.timeline
        model.moveSoundtrack(toTimelineStart: 2)
        #expect(model.timeline?.effectiveAudioClips.first?.sourceStart == 12)
        #expect(model.timeline?.effectiveAudioClips.first?.effectiveSpeed == 1.25)
        #expect(model.canUndoTimelineEdit)
        model.undoTimelineEdit()
        #expect(model.timeline == original)
        await model.flushAutosave()
    }

    @Test func rapidProjectClicksKeepTheLastProjectAndRemainResponsive() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let first = try fixture.project("first")
        let last = try fixture.project("last")
        let model = fixture.model()
        let started = Date()
        model.openRecentProject(first)
        model.openRecentProject(first)
        model.openRecentProject(last)
        // Click handling only schedules work; it must not parse a manifest.
        #expect(Date().timeIntervalSince(started) < 0.1)
        try await wait { model.projectURL == last && model.openingProjectURL == nil }
        #expect(model.project?.name == "last")
        #expect(model.errorMessage == nil)
        #expect(model.recentProjectURLs.first?.path == last.path)
        #expect(model.recentProjectURLs.filter { $0.path == last.path }.count == 1)
        await model.flushAutosave()
    }

    @Test func invalidProjectDoesNotDiscardTheOpenProjectAndCanBeRetried() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let good = try fixture.project("good")
        let broken = try fixture.project("broken")
        try Data("not JSON".utf8).write(to: broken.appendingPathComponent("project.json"))
        let model = fixture.model()
        model.openRecentProject(good)
        try await wait { model.projectURL == good && model.openingProjectURL == nil }
        model.section = .director
        model.directorInput = "Сохранить мой черновик"
        model.openRecentProject(broken)
        try await wait { model.errorMessage != nil && model.openingProjectURL == nil }
        #expect(model.projectURL == good)
        #expect(model.openingPresentation == nil)
        #expect(model.section == .director)
        #expect(model.directorInput == "Сохранить мой черновик")
        model.openRecentProject(good)
        try await wait { model.errorMessage == nil && model.openingProjectURL == nil }
        #expect(model.project?.name == "good")
        await model.flushAutosave()
    }

    @Test func repeatedFlushDoesNotRewriteManifestOrInvalidateWork() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let url = try fixture.project("flush")
        let model = fixture.model()
        model.openRecentProject(url)
        try await wait { model.projectURL == url && model.openingProjectURL == nil }
        await model.flushAutosave()
        let pipeline = try #require(model.pipeline)
        let store = await pipeline.store
        let before = await store.snapshot()
        let data = try Data(contentsOf: url.appendingPathComponent("project.json"))
        for _ in 0..<5 { await model.flushAutosave() }
        #expect(await store.currentRevision() == before.revision)
        #expect(await store.manifest.updatedAt == before.manifest.updatedAt)
        #expect(try Data(contentsOf: url.appendingPathComponent("project.json")) == data)
    }

    @Test func rapidTrimsAppearSynchronouslyAndTheFinalEditSurvivesReopen() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let url = try fixture.project("trim")
        let store = try ProjectStore(open: url)
        let item = TimelineItem(assetID: UUID(), kind: .video, sourceDuration: 10,
                                timelineStart: 0, timelineDuration: 10)
        try await store.update {
            $0.timelines = [Timeline(storyPlanID: UUID(), items: [item], originalAudioVolume: 0)]
        }
        let model = fixture.model()
        model.openRecentProject(url)
        try await wait { model.projectURL == url && model.openingProjectURL == nil }
        var maximumLatency = 0.0
        for index in 1...30 {
            let duration = 10 - Double(index) * 0.1
            let started = Date()
            model.trimTimelineItem(id: item.id, sourceStart: 0, timelineDuration: duration)
            maximumLatency = max(maximumLatency, Date().timeIntervalSince(started))
            #expect(abs((model.timeline?.items.first?.timelineDuration ?? 0) - duration) < 0.001)
        }
        #expect(maximumLatency < 0.1)
        print("PERF optimistic-trim maximum_ms=\(maximumLatency * 1000)")
        await model.flushAutosave()
        let reopened = try ProjectStore(open: url)
        #expect(abs((await reopened.manifest.timelines.last?.items.first?.timelineDuration ?? 0) - 7) < 0.001)
    }

    @Test func selectedTitleCommandsUpdatePausedPreviewAndPersistWithoutRebuildingFilm() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let url = try fixture.project("titles")
        let source = try await TitleCardVideoGenerator().generate(
            text: "", style: TitleStyle(), duration: 6, width: 640, height: 360, frameRate: 20,
            destination: fixture.root.appendingPathComponent("source.mov"), codec: .jpeg)
        let asset = MediaAsset(originalURL: source, kind: .video, byteSize: 1, contentHash: UUID().uuidString,
                               metadata: MediaMetadata(duration: 6, width: 640, height: 360, frameRate: 20, hasAudio: false))
        var title = try #require(TitleTemplateRegistry.template(id: "title.chapter.v1")).previewItem(startTime: 2)
        title.duration = 3
        let timeline = Timeline(storyPlanID: UUID(), width: 640, height: 360, frameRate: 20,
            items: [TimelineItem(assetID: asset.id, kind: .video, sourceDuration: 6, timelineStart: 0, timelineDuration: 6)],
            titleItems: [title])
        let store = try ProjectStore(open: url)
        try await store.update { $0.assets = [asset]; $0.timelines = [timeline] }
        let model = fixture.model()
        model.openRecentProject(url)
        try await wait { model.projectURL == url && model.openingProjectURL == nil }
        model.selectTitleTimelineItem(title.id)
        #expect(model.timelinePlayheadTime > title.startTime + 0.5)
        #expect(model.timelinePlayheadTime < title.endTime - 0.5)
        model.setSelectedModernTitleChapterNumber(12)
        try await wait { model.previewPosterImage != nil }
        let originalPoster = model.previewPosterImage?.tiffRepresentation

        model.directorInput = "Замени текст титра на «Новый маршрут»"
        model.sendDirectorMessage()
        #expect(model.selectedTitleTimelineItem?.text == "Новый маршрут")
        #expect(model.directorInput.isEmpty)
        #expect(!model.isDirectorResponding)
        #expect(model.timeline?.items == timeline.items)
        try await wait { model.previewPosterImage != nil && model.previewPosterImage?.tiffRepresentation != originalPoster }

        model.submitTimelineAIEdit("Сделай титр красным и крупнее")
        #expect(model.selectedTitleTimelineItem?.style.textColorHex == "#FF453A")
        #expect(model.selectedTitleTimelineItem?.templateID == title.templateID)
        #expect(model.selectedTitleTimelineItem?.chapterNumber == 12)
        let expected = model.selectedTitleTimelineItem
        #expect(!model.editSelectedTitleWithAI("Сделай как в том примере"))
        #expect(model.selectedTitleTimelineItem == expected)
        #expect(model.titleEditStatus?.contains("Не удалось") == true)
        await model.flushAutosave()
        let reopened = try ProjectStore(open: url)
        #expect(await reopened.manifest.timelines.last?.effectiveTitleItems.first == expected)
        #expect(model.canUndoTimelineEdit)
    }

    private func wait(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(8)
        // Yield at least once because card actions dispatch on the next turn.
        repeat {
            try await Task.sleep(for: .milliseconds(10))
            if predicate() { return }
        } while Date() < deadline
        Issue.record("Project interaction did not finish within eight seconds")
        throw WaitFailure.timeout
    }
    private enum WaitFailure: Error { case timeout }

    private actor ProjectLoadGate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var isReleased = false

        func wait() async {
            guard !isReleased else { return }
            await withCheckedContinuation { continuation = $0 }
        }

        func release() {
            isReleased = true
            continuation?.resume()
            continuation = nil
        }
    }

    private struct Fixture {
        let root: URL
        let suite: String
        init() throws {
            suite = "VeloEdit.interaction-tests.\(UUID().uuidString)"
            root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
        func project(_ name: String) throws -> URL {
            let url = root.appendingPathComponent(name).appendingPathExtension("veloedit")
            _ = try ProjectStore(createAt: url, name: name)
            return url
        }
        @MainActor func model() -> AppModel {
            AppModel(defaults: UserDefaults(suiteName: suite)!, startBackgroundServices: false,
                     personalTasteStore: LocalPersonalTasteStore(url: root.appendingPathComponent("taste.json")))
        }
        func remove() {
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
    }
}
