import Foundation
import Testing
@testable import VeloEditCore
@testable import VeloEdit

@Suite(.serialized) @MainActor
struct ReleaseReadinessInteractionTests {
    @Test func settingsWorkWithoutProjectAndMaintenanceBlocksNavigation() throws {
        let suite = "VeloEdit.SettingsNavigation.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(defaults: defaults, startBackgroundServices: false)
        model.openSection(.settings)
        #expect(model.section == .settings)
        model.storageIsCleaning = true
        model.openSection(.home)
        #expect(model.section == .settings)
        model.createProject()
        #expect(!model.isPresentingNewProject)
    }

    @Test func quittingDoesNotReactivatePreviouslyCancelledJobs() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("VeloEditQuit-\(UUID()).veloedit")
        let suite = "VeloEdit.Quit.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let store = try ProjectStore(createAt: root, name: "Quit", recoveryDirectory: root.appendingPathComponent("Recovery"))
        var job = AutonomousJob(projectID: await store.manifest.id, kind: .film, baseRevision: 0, inputSignature: "test")
        job.state = .cancelled; job.explicitCancellation = true
        try await store.update { $0.autonomousJob = job }
        let model = AppModel(defaults: defaults, startBackgroundServices: false)
        model.pipeline = VeloEditPipeline(store: store)
        model.project = await store.manifest
        #expect(await model.stopForApplicationTermination())
        #expect(await store.manifest.autonomousJob?.state == .cancelled)
        #expect(await store.manifest.autonomousJob?.explicitCancellation == true)
        try await store.update { $0.autonomousJob?.state = .running; $0.autonomousJob?.explicitCancellation = false }
        #expect(await model.stopForApplicationTermination())
        #expect(await store.manifest.autonomousJob?.state == .queued)
        #expect(await store.manifest.autonomousJob?.explicitCancellation == false)
    }
}
