import Foundation
import Testing
@testable import VeloEditCore

actor FilmBuildProgressRecorder {
    private(set) var updates: [FilmBuildProgress] = []
    func record(_ update: FilmBuildProgress) { updates.append(update) }
}

@Test(arguments: [false, true])
func filmBuildFailureReportsActualStageWithoutClaimingCompletion(regenerate: Bool) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try ProjectStore(createAt: root, name: "Build progress")
    let pipeline = VeloEditPipeline(store: store)
    let events = FilmBuildProgressRecorder()
    let callback: FilmBuildProgressHandler = { update in
        await Task.yield()
        await events.record(update)
    }
    do {
        if regenerate {
            _ = try await pipeline.regenerate(feedback: "Без музыки", progress: callback)
        } else {
            _ = try await pipeline.createFilm(prompt: "Без музыки", preset: .story, progress: callback)
        }
        Issue.record("Empty source material should fail")
    } catch DirectorBriefFulfillmentError.noUsableSourceMaterial {
        let updates = await events.updates
        #expect(updates.first?.stage == .analysis && updates.last?.stage == .preparing)
        #expect(!updates.contains { $0.stage == .saving })
    }
}
