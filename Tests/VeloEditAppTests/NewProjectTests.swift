import Foundation
import Testing
import VeloEditCore
@testable import VeloEdit

@Suite(.serialized)
@MainActor
struct NewProjectTests {
    @Test func cancelReturnsToPreviousWorkspaceWithoutChangingProject() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let model = fixture.model()
        model.project = ProjectManifest(name: "Текущий фильм")
        model.section = .director
        model.directorInput = "Несохранённый замысел"
        model.createProject()
        try await waitForForm(model)
        #expect(model.section == .home)
        #expect(model.project?.name == "Текущий фильм")
        model.newProjectDraft.name = "Новый фильм"
        model.cancelProjectCreation()
        #expect(!model.isPresentingNewProject)
        #expect(model.section == .director)
        #expect(model.project?.name == "Текущий фильм")
        #expect(model.directorInput == "Несохранённый замысел")
        #expect(!model.shouldHandleTimelineShortcuts)
    }

    @Test func creationWritesProjectAndFinderTagsThenOpensMedia() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let model = fixture.model()
        model.createProject()
        try await waitForForm(model)
        model.newProjectDraft = NewProjectDraft(name: "  Летний фильм.veloedit  ", directoryURL: fixture.root,
                                               tags: "лето, семья, лето, ")
        let url = model.newProjectDraft.packageURL
        await model.confirmProjectCreation()
        #expect(model.newProjectError == nil)
        #expect(!model.isPresentingNewProject)
        #expect(!model.isCreatingProject)
        #expect(model.section == .media)
        #expect(model.project?.name == "Летний фильм")
        #expect(model.projectURL == url)
        #expect(model.recentProjectURLs.first == url)
        #expect(url.lastPathComponent == "Летний фильм.veloedit")
        let store = try ProjectStore(open: url)
        #expect(await store.manifest.name == "Летний фильм")
        #expect(Set(try url.resourceValues(forKeys: [.tagNamesKey]).tagNames ?? []) == Set(["лето", "семья"]))
        #expect(UserDefaults(suiteName: fixture.suite)?.url(forKey: "newProjectDirectory.v1")?.path == fixture.root.path)
        await model.flushAutosave()
    }

    @Test func existingPackageIsUntouchedAndFormCanBeRetried() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let draft = NewProjectDraft(name: "Уже существует", directoryURL: fixture.root)
        _ = try draft.makeStore()
        let manifestURL = draft.packageURL.appendingPathComponent("project.json")
        let original = try Data(contentsOf: manifestURL)
        let model = fixture.model()
        model.createProject()
        try await waitForForm(model)
        model.newProjectDraft = draft
        await model.confirmProjectCreation()
        #expect(model.isPresentingNewProject)
        #expect(!model.isCreatingProject)
        #expect(model.newProjectError?.contains("уже существует") == true)
        #expect(model.project == nil)
        #expect(try Data(contentsOf: manifestURL) == original)
        model.newProjectDraft.name = "Другое название"
        await model.confirmProjectCreation()
        #expect(model.newProjectError == nil)
        #expect(model.project?.name == "Другое название")
        #expect(try Data(contentsOf: manifestURL) == original)
        await model.flushAutosave()
    }

    @Test func directNavigationClosesDraftAndAllowsOpeningItAgain() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let model = fixture.model()
        model.project = ProjectManifest(name: "Текущий фильм")
        model.createProject()
        try await waitForForm(model)
        model.section = .media
        #expect(!model.isPresentingNewProject)
        #expect(model.section == .media)
        model.createProject()
        try await waitForForm(model)
        #expect(model.section == .home)
        model.cancelProjectCreation()
        #expect(model.section == .media)
    }

    @Test func invalidNameAndMissingDirectoryLeaveFormOpen() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let model = fixture.model()
        model.createProject()
        try await waitForForm(model)
        for name in [" ", ".", "..", "../другой", "имя:фильма", ".veloedit", "два\nимени"] {
            model.newProjectDraft = NewProjectDraft(name: name, directoryURL: fixture.root)
            await model.confirmProjectCreation()
            #expect(model.newProjectError != nil)
            #expect(model.isPresentingNewProject)
            #expect(model.project == nil)
        }
        model.newProjectDraft = NewProjectDraft(directoryURL: fixture.root.appendingPathComponent("missing"))
        await model.confirmProjectCreation()
        #expect(model.newProjectError != nil)
        #expect(model.isPresentingNewProject)
        #expect(!model.isCreatingProject)
        #expect(model.project == nil)
    }

    private func waitForForm(_ model: AppModel) async throws {
        for _ in 0..<100 {
            if model.isPresentingNewProject { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw CocoaError(.coderInvalidValue)
    }

    private struct Fixture {
        let root: URL
        let suite = "VeloEdit.new-project-tests.\(UUID().uuidString)"
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
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
