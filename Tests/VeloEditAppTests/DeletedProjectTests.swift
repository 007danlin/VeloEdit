import Foundation
import Testing
@testable import VeloEditCore
@testable import VeloEdit

@Suite(.serialized) @MainActor
struct DeletedProjectTests {
    @Test func deletingOpenProjectPreservesDraftAndAllowsQuit() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "DeletedProjectTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let package = root.appendingPathComponent("Project.veloedit")
        let recovery = root.appendingPathComponent("Recovery")
        let store = try ProjectStore(createAt: package, name: "Deleted", recoveryDirectory: recovery)
        let model = AppModel(defaults: defaults, startBackgroundServices: false)
        model.pipeline = VeloEditPipeline(store: store)
        model.project = await store.manifest
        model.projectURL = package
        model.directorInput = "Сохранить мой черновик"
        #expect(await model.flushAutosave())
        try FileManager.default.removeItem(at: package)
        try FileManager.default.createDirectory(at: package.appendingPathComponent("Cache"), withIntermediateDirectories: true)
        await model.checkProjectAvailability()
        #expect(model.errorMessage?.contains("Файл проекта удалён") == true)
        model.importMedia([root.appendingPathComponent("missing.mov")])
        for _ in 0..<100 where model.isWorking { try await Task.sleep(for: .milliseconds(20)) }
        #expect(!model.isWorking)
        #expect(!model.isImporting)
        #expect(await model.stopForApplicationTermination())
        #expect(await model.flushAutosave())
        let reopened = try ProjectStore(open: package, recoveryDirectory: recovery)
        #expect(await reopened.manifest.workspaceState?.directorDraft == "Сохранить мой черновик")
        let report = await model.diagnosticsReport()
        #expect(report.contains("localRecovery"))
        #expect(report.contains(package.path))
    }

    @Test func diagnosticsWithoutProjectIncludeErrors() async throws {
        let suite = "DiagnosticsTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(defaults: defaults, startBackgroundServices: false)
        model.errorMessage = "Test export failure"
        let report = await model.diagnosticsReport()
        #expect(report.contains("Test export failure"))
        #expect(report.contains("Журнал приложения:"))
        #expect(report.contains("Проект: не открыт"))
    }
}
