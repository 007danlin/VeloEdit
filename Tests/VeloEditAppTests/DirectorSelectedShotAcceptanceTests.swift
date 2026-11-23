import Foundation
import Testing
@testable import VeloEdit
@testable import VeloEditCore

/// Opt-in integration check against a local film. Only the temporary copy is edited.
@MainActor @Test(.enabled(if: ProcessInfo.processInfo.environment["VELOEDIT_SELECTED_SHOT_PROJECT"] != nil))
func realDirectorDescribesAndTrimsOneSelectedShot() async throws {
    let env = ProcessInfo.processInfo.environment
    let source = URL(fileURLWithPath: try #require(env["VELOEDIT_SELECTED_SHOT_PROJECT"]))
    let report = URL(fileURLWithPath: try #require(env["VELOEDIT_SELECTED_SHOT_REPORT"]))
    let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: scratch) }
    let copy = scratch.appendingPathComponent(source.lastPathComponent)
    try FileManager.default.copyItem(at: source, to: copy)
    let store = try ProjectStore(open: copy)
    let manifest = await store.manifest
    let original = try #require(manifest.timelines.last)
    let shots = original.items.filter { $0.kind == .video && $0.overlay == nil }
    let index = Int(env["VELOEDIT_SELECTED_SHOT_INDEX"] ?? "1") ?? 1
    try #require(shots.indices.contains(index))
    let selected = shots[index]
    let model = AppModel(defaults: UserDefaults(suiteName: scratch.lastPathComponent)!, startBackgroundServices: false)
    model.pipeline = VeloEditPipeline(store: store)
    model.projectURL = copy
    model.project = manifest
    model.aiPowerMode = manifest.preferences.effectiveAIPowerMode
    model.selectTimelineItem(selected.id)
    model.seekTimeline(to: selected.timelineStart + selected.timelineDuration / 2)
    func send(_ prompt: String) async throws -> DirectorMessage {
        let count = model.directorMessages.count
        model.directorInput = prompt
        model.sendDirectorMessage()
        let timeout = Date().addingTimeInterval(510)
        repeat {
            try await Task.sleep(for: .milliseconds(200))
            if !model.hasActiveWork, model.directorMessages.count > count,
               let reply = model.directorMessages.last, reply.role == .assistant { return reply }
        } while Date() < timeout
        throw URLError(.timedOut)
    }
    let answer = try await send("Опиши, что видно в выбранном плане")
    let runtime = model.directorRuntimeStatus
    let edit = try await send("Сократи повторяющийся план")
    let edited = try #require(model.timeline)
    let changed = edited.items.filter { item in
        original.items.first(where: { $0.id == item.id })?.timelineDuration != item.timelineDuration
    }.map(\.id)
    struct Result: Encodable {
        let model: String, runtime: String, description: String, edit: String
        let selection: UUID, changed: [UUID]
        let fallback: Bool?
        let before: [TimelineItem], after: [TimelineItem]
    }
    let result = Result(model: AIAnalysisProfile.resolve(mode: model.aiPowerMode).modelID,
        runtime: runtime, description: answer.text, edit: edit.text, selection: selected.id,
        changed: changed, fallback: answer.response?.fallback, before: original.items, after: edited.items)
    try JSONEncoder().encode(result).write(to: report, options: .atomic)
    #expect(answer.response?.fallback == false)
    #expect(answer.response?.itemIDs.contains(selected.id) == true)
    let moment = DirectorMomentIndex(project: manifest, revision: 1).resolve(prompt: "Опиши, что видно в выбранном плане",
        selectedID: selected.id, playhead: selected.timelineStart + selected.timelineDuration / 2)
    let descriptions = DirectorResponseComposer.pictureDescriptions(prompt: "Опиши, что видно в выбранном плане", moment: moment)
    #expect(descriptions?.contains(answer.text) == true)
    #expect(changed == [selected.id])
    model.undoTimelineEdit()
    await model.waitForCurrentWork()
    #expect(model.timeline?.items.map(\.timelineDuration) == original.items.map(\.timelineDuration))
}
