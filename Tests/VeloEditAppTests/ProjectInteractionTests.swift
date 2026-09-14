import Foundation
import Testing
import VeloEditCore
@testable import VeloEdit

@Suite(.serialized)
@MainActor
struct ProjectInteractionTests {
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
        model.openRecentProject(broken)
        try await wait { model.errorMessage != nil && model.openingProjectURL == nil }
        #expect(model.projectURL == good)
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
        try await wait { model.isPreviewPosterVisible && model.previewPosterImage != nil }
        let originalPoster = model.previewPosterImage?.tiffRepresentation

        model.directorInput = "Замени текст титра на «Новый маршрут»"
        model.sendDirectorMessage()
        #expect(model.selectedTitleTimelineItem?.text == "Новый маршрут")
        #expect(model.directorInput.isEmpty)
        #expect(!model.isDirectorResponding)
        #expect(model.timeline?.items == timeline.items)
        try await wait { model.isPreviewPosterVisible && model.previewPosterImage?.tiffRepresentation != originalPoster }

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
