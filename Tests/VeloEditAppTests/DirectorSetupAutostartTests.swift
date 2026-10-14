import AppKit
import Foundation
import Testing
import VeloEditCore
@testable import VeloEdit

@Suite(.serialized) @MainActor
struct DirectorSetupAutostartTests {
    @Test func finalAnswerStartsAndSavesFilmWithoutCallingTheLanguageModel() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("director-setup-\(UUID())")
        let suite = "VeloEdit.setup-tests.\(UUID())"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let store = try ProjectStore(createAt: root.appendingPathComponent("test.veloedit"), name: "Questionnaire")
        let image = NSImage(size: NSSize(width: 128, height: 72), flipped: false) { rect in
            NSColor.systemBlue.setFill(); rect.fill(); return true
        }
        let tiff = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: tiff))
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        let photoURL = root.appendingPathComponent("photo.png")
        try png.write(to: photoURL)
        let asset = try await MediaImporter().makeAsset(url: photoURL)
        try await store.update { $0.assets = [asset] }
        var modelCalls = 0
        let agent = LocalDirectorAgent { _, _, _, _ in
            modelCalls += 1
            return DirectorAIReply(text: "Не требуется", runtimeLabel: "fixture", normalizedBrief: nil)
        }
        let taste = LocalPersonalTasteStore(url: root.appendingPathComponent("taste.json"))
        let model = AppModel(defaults: UserDefaults(suiteName: suite)!, startBackgroundServices: false,
            personalTasteStore: taste, directorAgent: agent)
        model.project = await store.manifest
        model.projectURL = await store.packageURL
        model.pipeline = VeloEditPipeline(store: store, personalTasteStore: taste)
        // Vlog with a photo has no audio/model analysis preflight and exercises
        // the complete real create/save/playback path from a typed brief.
        model.preset = .vlog
        model.directorBrief = .init(requestedDuration: 6, mood: .cinematic, musicPolicy: .none,
            titlePolicy: .none, durationMode: .automatic, effectsPolicy: DirectorEffectsPolicy.none)
        let summary = "Стиль: Влог. Длительность — по материалам. Музыка: без музыки. Без титров."
        #expect(model.finishDirectorSetup(summary: summary))
        #expect(model.isCreatingFilm && model.isWorking)
        #expect(model.directorInput.isEmpty)
        #expect(model.directorMessages.filter { $0.role == .user }.map(\.text) == [summary])
        #expect(!model.finishDirectorSetup(summary: summary), "A duplicate last-answer event must not start another run")
        let deadline = Date().addingTimeInterval(45)
        while model.isWorking && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        if model.isWorking { model.cancelOperation() }
        #expect(model.timeline != nil, "\(model.status)")
        #expect(model.previewPlayer?.currentItem != nil)
        #expect(modelCalls == 0)
        #expect(await store.manifest.timelines.count == 1)
        #expect(model.directorMessages.filter { $0.role == .user }.count == 1)
        #expect(await model.flushAutosave())
    }

    @Test func missingMediaKeepsTheBriefAndBusyOrExistingFilmCannotAutostart() {
        let suite = "VeloEdit.setup-guards.\(UUID())"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let model = AppModel(defaults: UserDefaults(suiteName: suite)!, startBackgroundServices: false)
        model.project = ProjectManifest(name: "No media yet")
        model.directorInput = "Сохрани прогулку в конце"
        let summary = "Настроение: киношное. Эффекты: нормально."
        #expect(!model.finishDirectorSetup(summary: summary))
        #expect(model.directorInput == summary + "\nСохрани прогулку в конце")
        #expect(!model.finishDirectorSetup(summary: summary))
        #expect(model.directorInput == summary + "\nСохрани прогулку в конце")
        #expect(!model.directorMessages.contains { $0.role == .user } && !model.isWorking)
        model.project?.timelines = [Timeline(storyPlanID: UUID(), items: [])]
        let previousDraft = model.directorInput
        #expect(!model.finishDirectorSetup(summary: "Другой бриф"))
        #expect(model.directorInput == previousDraft)
    }
}
