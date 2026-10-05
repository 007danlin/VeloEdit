import Foundation
import Testing
import VeloEditCore
@testable import VeloEdit

@Suite(.serialized) @MainActor
struct ReliabilityInteractionTests {
    @Test func workPreventsIdleSleepAndReleasesItsAssertion() throws {
        func assertions() throws -> String {
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
            process.arguments = ["-g", "assertions"]
            process.standardOutput = pipe
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(decoding: data, as: UTF8.self)
        }
        let reason = "VeloEdit reliability assertion \(UUID())"
        var activity: WorkActivity? = WorkActivity(reason: reason)
        let active = try assertions()
        #expect(active.contains(reason))
        #expect(active.contains("PreventUserIdleSystemSleep"))
        withExtendedLifetime(activity) {}
        activity = nil
        #expect(try !assertions().contains(reason))
    }

    @Test func sendRemainsAvailableWhileReplyingAndCancellationReleasesComposer() throws {
        let suite = "VeloEdit.Reliability.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(defaults: defaults, startBackgroundServices: false)
        model.isDirectorResponding = true
        model.directorInput = "Новое пожелание"
        #expect(model.canSendDirectorMessage)
        model.sendDirectorMessage()
        #expect(model.directorInput.isEmpty)
        model.directorInput = "После отмены"
        model.cancelOperation()
        #expect(!model.isDirectorResponding)
        #expect(model.canSendDirectorMessage)
        #expect(model.directorInput.contains("После отмены"))
        #expect(model.directorInput.contains("Новое пожелание"))
        model.directorInput = "  \n "
        #expect(!model.canSendDirectorMessage)
    }

    @Test func cancellingFilmRemovesPendingBubblesAndObsoleteStatus() throws {
        let suite = "VeloEdit.CancelFilm.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(defaults: defaults, startBackgroundServices: false)
        model.isCreatingFilm = true
        model.isDirectorResponding = true
        model.directorStatus = "Ответ готов · начинаю собирать фильм"
        model.directorMessages = [
            .init(role: .user, text: "Собери фильм на 30 секунд"),
            .init(role: .assistant, text: ""),
            .init(role: .assistant, text: "Описание сохранено")
        ]
        model.cancelOperation()
        #expect(!model.isDirectorResponding)
        #expect(model.directorMessages.count == 2)
        #expect(model.directorMessages.allSatisfy { !$0.text.isEmpty })
        #expect(model.directorStatus.contains("отменено"))
        #expect(!model.directorStatus.contains("начинаю"))
        model.openSection(.media)
        model.openSection(.director)
        #expect(model.directorStatus.contains("отменено"))
    }

    @Test func manualWorkspaceStartsWithoutAIAndPersists() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("veloedit-manual-\(UUID()).veloedit")
        let suite = "VeloEdit.Manual.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let store = try ProjectStore(createAt: root, name: "Manual")
        let model = AppModel(defaults: defaults, startBackgroundServices: false)
        model.pipeline = VeloEditPipeline(store: store)
        model.project = await store.manifest
        model.startManualEditing()
        for _ in 0..<200 where model.isWorking { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!model.isWorking)
        #expect(model.errorMessage == nil)
        #expect(model.section == .timeline)
        #expect(model.timeline != nil)
        #expect(model.project?.analyses.isEmpty == true)
        let reopened = try ProjectStore(open: root)
        #expect(await reopened.manifest.timelines.count == 1)
        model.startManualEditing()
        #expect(await store.manifest.timelines.count == 1)
    }
}
