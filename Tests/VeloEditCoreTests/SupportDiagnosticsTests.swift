import Foundation
import Testing
@testable import VeloEditCore

struct SupportDiagnosticsTests {
    @Test func trashMoveDoesNotWriteIntoDeletedProject() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let package = root.appendingPathComponent("Project.veloedit")
        let recovery = root.appendingPathComponent("Recovery")
        let store = try ProjectStore(createAt: package, name: "Before trash", recoveryDirectory: recovery)
        let trash = root.appendingPathComponent(".Trash", isDirectory: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        let deleted = trash.appendingPathComponent(package.lastPathComponent)
        try FileManager.default.moveItem(at: package, to: deleted)
        #expect(!store.packageIsAvailable)
        try await store.update { $0.name = "Recovered from trash" }
        #expect(try await store.verifyDurableState() == .localRecovery)
        let unchanged = try JSONDecoder.veloEdit.decode(ProjectManifest.self, from: Data(contentsOf: deleted.appendingPathComponent("project.json")))
        #expect(unchanged.name == "Before trash")
        try FileManager.default.moveItem(at: deleted, to: package)
        let restored = try ProjectStore(open: package, recoveryDirectory: recovery)
        #expect(await restored.manifest.name == "Recovered from trash")
    }

    @Test func errorChainSurvivesRelaunchWithoutProject() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("diagnostics/recent.log")
        let underlying = NSError(domain: NSPOSIXErrorDomain, code: 28, userInfo: [NSFilePathErrorKey: "/Volumes/USB/movie.mp4"])
        let error = NSError(domain: "ExportTest", code: 42, userInfo: [NSUnderlyingErrorKey: underlying])
        SupportDiagnostics(url: url).record("Экспорт 37%", error: error)
        let report = SupportDiagnostics(url: url).report()
        #expect(report.contains("ExportTest (42)"))
        #expect(report.contains("NSPOSIXErrorDomain (28)"))
        #expect(report.contains("/Volumes/USB/movie.mp4"))
        #expect(report.contains("Экспорт 37%"))
    }

    @Test func deletedManifestInsideRecreatedPackageUsesRecovery() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let package = root.appendingPathComponent("Project.veloedit")
        let recovery = root.appendingPathComponent("Recovery")
        let store = try ProjectStore(createAt: package, name: "Original", recoveryDirectory: recovery)
        // A late thumbnail/log task can recreate directories after deletion.
        try FileManager.default.removeItem(at: package)
        try FileManager.default.createDirectory(at: package.appendingPathComponent("Logs"), withIntermediateDirectories: true)
        try await store.update { $0.name = "Recovered draft" }
        #expect(try await store.verifyDurableState() == .localRecovery)
        #expect(!FileManager.default.fileExists(atPath: package.appendingPathComponent("project.json").path))
        let reopened = try ProjectStore(open: package, recoveryDirectory: recovery)
        #expect(await reopened.manifest.name == "Recovered draft")
    }

    @Test func unchangedDeletedProjectCanBeSavedForExit() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let package = root.appendingPathComponent("Project.veloedit")
        let store = try ProjectStore(createAt: package, name: "Unchanged", recoveryDirectory: root.appendingPathComponent("Recovery"))
        try FileManager.default.removeItem(at: package)
        #expect(try await store.verifyDurableState() == .localRecovery)
        #expect(!FileManager.default.fileExists(atPath: package.path))
    }

    @Test func diagnosticsIncludeExternalSourcesAndActualFailures() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ProjectStore(createAt: root.appendingPathComponent("Project.veloedit"), name: "USB")
        let source = URL(fileURLWithPath: "/Volumes/Disconnected/clip.mov")
        try await store.update { $0.assets = [MediaAsset(originalURL: source, kind: .video, byteSize: 500, contentHash: "test", metadata: MediaMetadata(duration: 10))] }
        let failure = await store.logsURL.appendingPathComponent("job-test-failure.txt")
        try "decoder failed at frame 17".write(to: failure, atomically: true, encoding: .utf8)
        let report = await VeloEditPipeline(store: store).diagnostics()
        #expect(report.contains(source.path))
        #expect(report.contains("внешний исходник (импорт без копирования)"))
        #expect(report.contains("отсутствует: 1"))
        #expect(report.contains("decoder failed at frame 17"))
        #expect(report.contains("Свободно байт:"))
    }
}
