import Foundation
import Testing
import VeloEditCore
@testable import VeloEdit

@Suite(.serialized) @MainActor
struct SettingsPersistenceTests {
    @Test func statisticsCountUniqueSourcesAcrossProjectsWithoutDuplicatingAProject() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let firstURL = fixture.root.appendingPathComponent("first.veloedit")
        let secondURL = fixture.root.appendingPathComponent("second.veloedit")
        let first = try ProjectStore(createAt: firstURL, name: "First")
        let second = try ProjectStore(createAt: secondURL, name: "Second")
        let asset = MediaAsset(originalURL: fixture.root.appendingPathComponent("video.mov"), kind: .video,
            byteSize: 100, contentHash: "same-content", metadata: MediaMetadata(duration: 60))
        let result = AnalysisResult(assetID: asset.id, analyzedContentHash: asset.contentHash, candidates: [])
        for store in [first, second] {
            try await store.update { project in
                project.assets = [asset]
                // Repeated analysis must not count the same asset twice.
                project.analyses = [result, result]
            }
        }
        let copy = fixture.root.appendingPathComponent("copy.veloedit")
        try FileManager.default.copyItem(at: firstURL, to: copy)
        let paths = [firstURL, firstURL, copy, secondURL, fixture.root.appendingPathComponent("missing.veloedit")]
        UserDefaults(suiteName: fixture.suite)!.set(paths.map(\.path), forKey: "recentProjectPaths.v1")
        let model = fixture.model()
        model.refreshUsageStatistics()
        try await wait { model.usageStatistics.projectCount == 2 }
        #expect(model.usageStatistics.projectCount == 2)
        #expect(model.usageStatistics.sourceAssetCount == 1)
        #expect(model.usageStatistics.sourceContentDuration == 60)
    }

    @Test func statisticsRecoverOlderProjectsAndPersistBeyondRecentHistory() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var urls: [URL] = []
        for index in 0..<14 {
            let url = fixture.root.appendingPathComponent("project-\(index).veloedit")
            let store = try ProjectStore(createAt: url, name: "Project \(index)")
            let asset = MediaAsset(originalURL: fixture.root.appendingPathComponent("video.mov"), kind: .video,
                byteSize: 100, contentHash: "video-\(index)", metadata: MediaMetadata(duration: 60))
            try await store.update {
                $0.assets = [asset]
                $0.analyses = [AnalysisResult(assetID: asset.id, analyzedContentHash: asset.contentHash, candidates: [])]
            }
            urls.append(url)
        }
        let defaults = UserDefaults(suiteName: fixture.suite)!
        defaults.set(urls.suffix(12).map(\.path), forKey: "recentProjectPaths.v1")
        let model = fixture.model()
        model.refreshUsageStatistics()
        try await wait { model.usageStatistics.projectCount == 14 }
        #expect(model.recentProjectURLs.count == 12)
        #expect(model.usageStatistics.sourceContentDuration == 840)
        #expect(model.usageStatistics.sourceAssetCount == 14)
        #expect(Set(defaults.stringArray(forKey: "projectLibraryPaths.v1") ?? []) == Set(urls.map(\.path)))

        // Clearing the recent cards must not erase the statistics library.
        for url in model.recentProjectURLs { model.forgetRecentProject(url) }
        #expect(model.recentProjectURLs.isEmpty)
        let reopened = fixture.model()
        reopened.refreshUsageStatistics()
        try await wait { reopened.usageStatistics.projectCount == 14 }
        #expect(reopened.recentProjectURLs.isEmpty)
        #expect(reopened.usageStatistics.sourceContentDuration == 840)

        try FileManager.default.removeItem(at: urls[0])
        reopened.refreshUsageStatistics()
        try await wait { reopened.usageStatistics.projectCount == 13 }
        #expect(reopened.usageStatistics.sourceContentDuration == 780)
        #expect(reopened.usageStatistics.sourceAssetCount == 13)
    }

    @Test func openingThirteenthProjectKeepsTheEvictedProjectInStatistics() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var urls: [URL] = []
        // Separate folders ensure the library, rather than sibling discovery,
        // keeps the project that falls out of the recent cards.
        for index in 0..<13 {
            let url = fixture.root.appendingPathComponent("folder-\(index)/project.veloedit")
            _ = try ProjectStore(createAt: url, name: "Project \(index)")
            urls.append(url)
        }
        let defaults = UserDefaults(suiteName: fixture.suite)!
        defaults.set(urls.prefix(12).map(\.path), forKey: "recentProjectPaths.v1")
        let model = fixture.model()
        model.openRecentProject(urls[12])
        try await wait { model.projectURL == urls[12] && model.usageStatistics.projectCount == 13 }
        #expect(model.recentProjectURLs.count == 12)
        #expect(!model.recentProjectURLs.contains(urls[11]))
        #expect(Set(defaults.stringArray(forKey: "projectLibraryPaths.v1") ?? []) == Set(urls.map(\.path)))
        #expect(await model.flushAutosave())
    }

    @Test func statisticsDiscoverLegacyProjectsInTheCreationFolder() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let url = fixture.root.appendingPathComponent("legacy.veloedit")
        let store = try ProjectStore(createAt: url, name: "Legacy")
        let asset = MediaAsset(originalURL: fixture.root.appendingPathComponent("clip.mov"), kind: .video,
            byteSize: 100, contentHash: "clip", metadata: MediaMetadata(duration: 90))
        try await store.update {
            $0.assets = [asset]
            $0.analyses = [AnalysisResult(assetID: asset.id, analyzedContentHash: asset.contentHash, candidates: [])]
        }
        try FileManager.default.removeItem(at: url.appendingPathComponent(ProjectSummary.fileName))
        try FileManager.default.createDirectory(at: fixture.root.appendingPathComponent("invalid.veloedit"),
                                                withIntermediateDirectories: true)
        UserDefaults(suiteName: fixture.suite)!.set(fixture.root, forKey: "newProjectDirectory.v1")
        let model = fixture.model()
        model.refreshUsageStatistics()
        try await wait { model.usageStatistics.projectCount == 1 }
        #expect(model.usageStatistics.sourceContentDuration == 90)
        #expect(model.usageStatistics.sourceAssetCount == 1)
        #expect(ProjectSummary.load(from: url)?.statisticsVersion == ProjectSummary.currentStatisticsVersion)
    }

    @Test func directorPhrasesSurviveReopeningOnlyInTheirOwnProject() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let url = fixture.root.appendingPathComponent("conversation.veloedit")
        let store = try ProjectStore(createAt: url, name: "Conversation")
        let model = fixture.model()
        model.pipeline = VeloEditPipeline(store: store, personalTasteStore: fixture.tasteStore())
        model.project = await store.manifest
        let phrases = (1...14).map { "Пожелание \($0): сохранить этот момент" }
        model.prompt = phrases.joined(separator: "\n")
        model.directorMessages = phrases.map { DirectorMessage(role: .user, text: $0) }
        model.directorInput = "Неотправленный черновик"
        #expect(await model.flushAutosave())

        let reopened = fixture.model()
        reopened.openRecentProject(url)
        let deadline = Date().addingTimeInterval(8)
        repeat {
            try await Task.sleep(for: .milliseconds(10))
        } while reopened.projectURL != url && Date() < deadline
        #expect(reopened.projectURL == url)
        #expect(reopened.directorMessages.filter { $0.role == .user }.map(\.text) == phrases)
        #expect(reopened.prompt == phrases.joined(separator: "\n"))
        #expect(reopened.directorInput == "Неотправленный черновик")
        #expect(await reopened.flushAutosave())

        let fresh = try ProjectStore(createAt: fixture.root.appendingPathComponent("new.veloedit"), name: "New")
        #expect(await fresh.manifest.workspaceState?.directorMessages == nil)
        #expect(await fixture.tasteStore().profile().totalSignalCount == 0)
        let exportURL = fixture.root.appendingPathComponent("profile-export.json")
        try await fixture.tasteStore().export(to: exportURL)
        let exported = try String(contentsOf: exportURL, encoding: .utf8)
        #expect(!exported.contains("Пожелание"))
        #expect(!exported.contains("Неотправленный"))
    }

    @Test func portableCopyIncludesChatBeforeAutosaveDebounceAndRestoresOnFreshInstallation() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = fixture.root.appendingPathComponent("source.veloedit")
        let store = try ProjectStore(createAt: source, name: "Portable conversation")
        let model = fixture.model()
        model.pipeline = VeloEditPipeline(store: store, personalTasteStore: fixture.tasteStore())
        model.project = await store.manifest
        let messages = (1...20).flatMap { index in
            [DirectorMessage(role: .user, text: "Сохрани момент \(index)"),
             DirectorMessage(role: .assistant, text: "Момент \(index) отмечен")]
        }
        model.directorMessages = messages
        model.directorInput = "Продолжим с горной сцены"
        model.feedback = "Сделать финал спокойнее"
        model.prompt = "Поездка в горы с друзьями"
        let copy = fixture.root.appendingPathComponent("copy.veloedit")
        // Deliberately do not wait for the 500 ms chat autosave.
        _ = try await model.collectProjectCopy(to: copy)
        let moved = fixture.root.appendingPathComponent("another-computer/film.veloedit")
        try FileManager.default.createDirectory(at: moved.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: copy, to: moved)
        try FileManager.default.removeItem(at: source)

        let secondInstallation = try Fixture()
        defer { secondInstallation.remove() }
        let reopened = secondInstallation.model()
        reopened.openRecentProject(moved)
        try await wait { reopened.projectURL == moved && reopened.openingProjectURL == nil }
        #expect(reopened.directorMessages.map(\.id) == messages.map(\.id))
        #expect(reopened.directorMessages.map(\.text) == messages.map(\.text))
        #expect(reopened.directorInput == "Продолжим с горной сцены")
        #expect(reopened.feedback == "Сделать финал спокойнее")
        #expect(reopened.prompt == "Поездка в горы с друзьями")
        #expect(await reopened.flushAutosave())

        let agent = LocalDirectorAgent()
        agent.restoreConversation(reopened.directorMessages)
        #expect(agent.recentConversationContext.contains("Пользователь: Сохрани момент 20"))
        #expect(agent.recentConversationContext.contains("Режиссёр: Момент 20 отмечен"))
        agent.restoreConversation(DirectorMessage.initial)
        #expect(agent.recentConversationContext.isEmpty)
    }

    private func wait(until condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(condition())
    }

    private struct Fixture {
        let root: URL
        let suite = "VeloEdit.Settings.\(UUID())"
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
        func tasteStore() -> LocalPersonalTasteStore {
            LocalPersonalTasteStore(url: root.appendingPathComponent("taste.json"))
        }
        @MainActor func model(startBackgroundServices: Bool = false) -> AppModel {
            AppModel(defaults: UserDefaults(suiteName: suite)!, startBackgroundServices: startBackgroundServices,
                personalTasteStore: tasteStore())
        }
        func remove() {
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
    }
}
