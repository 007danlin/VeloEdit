import Foundation
import Testing
@testable import VeloEditCore

private func migrationCandidate() async throws -> (Timeline, StoryPlan, [AnalysisResult]) {
    let shotDuration = 3.0
    let candidates = (0..<4).map { index in
        Candidate(assetID: UUID(), sourceStart: 0, sourceDuration: shotDuration,
                  scores: ClipScores(quality: 0.9, interest: 0.9, action: 0.8, stability: 0.9),
                  tags: ["outdoor", "scene-\(index)"])
    }
    let duration = shotDuration * Double(candidates.count)
    let analyses = candidates.map { AnalysisResult(assetID: $0.assetID, analyzedContentHash: "fixture-\($0.id)", sceneTags: [], candidates: [$0]) }
    let context = EditorialAnalysisContext(analyses: analyses)
    var plan = StoryPlan(prompt: "Без исходного звука", preset: .story, constraints: .init(targetDuration: duration, pacing: 0.4), chapters: [])
    plan.contentBudget = ContentBudgetEngine().budget(units: context.units, families: context.families, requestedDuration: duration, requestIsExplicit: true, style: .init())
    let items = candidates.enumerated().map { index, candidate in
        TimelineItem(candidateID: candidate.id, assetID: candidate.assetID, kind: .video,
                     sourceDuration: shotDuration, timelineStart: Double(index) * shotDuration, timelineDuration: shotDuration)
    }
    var timeline = EditorialIntentEnforcer.enforce(Timeline(storyPlanID: plan.id, items: items, originalAudioVolume: 0), plan: plan)
    let frames = try await FixtureEditorialProber().frames(timeline: timeline, assets: [], tracks: [], telemetry: [:], cacheURL: FileManager.default.temporaryDirectory)
    timeline.editorialReview = EditorialQualityGate().review(timeline: timeline, plan: plan, analyses: analyses, renderedFrames: frames, requireRenderedEvidence: true)
    var project = ProjectManifest(name: "synthetic commit")
    let entry = IntentLedgerEntry(id: UUID(), projectRevision: 0, normalizedIntent: .createFilm, source: .prompt, status: .running, evidence: [])
    project.intentLedger = .init(entries: [entry])
    timeline = try ProjectStore.verifyAndFulfillEditorialGeneration(in: &project, ids: [entry.id], timeline: timeline, analyses: analyses)
    return (timeline, plan, analyses)
}

@Test func migrationRequiresExactHumanReviewAndPreservesPreviousTimeline() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let package = root.appendingPathComponent("project.veloedit")
    let store = try ProjectStore(createAt: package, name: "migration fixture")
    let old = Timeline(storyPlanID: UUID(), items: [])
    try await store.update { $0.timelines = [old] }
    let data = try Data(contentsOf: package.appendingPathComponent("project.json"))
    let backup = try EditorialProjectMigration.prepare(packageURL: package, backupRoot: root.appendingPathComponent("backups"))
    #expect(try Data(contentsOf: package.appendingPathComponent("project.json")) == data)
    let restored = try ProjectStore(open: backup.backupURL)
    #expect(await restored.manifest.timelines.last?.id == old.id)
    let (candidate, plan, analyses) = try await migrationCandidate()
    var human = EditorialFullPlaybackReview(timelineSignature: "stale", reviewerID: "synthetic test record", watchedWholeFilm: true, watchedWithoutSound: true, checkedTitlesInMotion: true, checkedAudioByEar: true, criticalOrHighTimecodes: [], reviewedAt: Date())
    #expect(throws: (any Error).self) { try EditorialProjectMigration.activate(candidate: candidate, plan: plan, analyses: analyses, backup: backup, humanReview: human) }
    #expect(try Data(contentsOf: package.appendingPathComponent("project.json")) == data)
    human.timelineSignature = EditorialRenderSignature.signature(candidate)
    try EditorialProjectMigration.activate(candidate: candidate, plan: plan, analyses: analyses, backup: backup, humanReview: human)
    let result = try JSONDecoder.veloEdit.decode(ProjectManifest.self, from: Data(contentsOf: package.appendingPathComponent("project.json")))
    #expect(result.timelines.map(\.id) == [old.id, candidate.id])
    #expect(result.timelines.last?.editorialRegeneration?.previousTimelineID == old.id)
    #expect(result.timelineCheckpoints?.contains { $0.timeline.id == old.id } == true)
    #expect(result.timelines.last.map(EditorialRenderSignature.signature) == human.timelineSignature)
    #expect(FileManager.default.fileExists(atPath: backup.backupURL.path))
}

@Test func migrationRejectsExternalManifestChangeEvenWithPassingReview() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let package = root.appendingPathComponent("project.veloedit")
    let store = try ProjectStore(createAt: package, name: "CAS fixture")
    let backup = try EditorialProjectMigration.prepare(packageURL: package, backupRoot: root.appendingPathComponent("backups"))
    try await store.update { $0.name = "newer user edit" }
    let newer = try Data(contentsOf: package.appendingPathComponent("project.json"))
    let (candidate, plan, analyses) = try await migrationCandidate()
    let review = EditorialFullPlaybackReview(timelineSignature: EditorialRenderSignature.signature(candidate), reviewerID: "synthetic", watchedWholeFilm: true, watchedWithoutSound: true, checkedTitlesInMotion: true, checkedAudioByEar: true, criticalOrHighTimecodes: [], reviewedAt: Date())
    #expect(throws: (any Error).self) { try EditorialProjectMigration.activate(candidate: candidate, plan: plan, analyses: analyses, backup: backup, humanReview: review) }
    #expect(try Data(contentsOf: package.appendingPathComponent("project.json")) == newer)
}

@Test func migrationCanActivateExactProductionCandidateWithoutFabricatingHumanReview() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let package = root.appendingPathComponent("project.veloedit")
    let store = try ProjectStore(createAt: package, name: "automatic migration fixture")
    let old = Timeline(storyPlanID: UUID(), items: [])
    try await store.update { $0.timelines = [old] }
    let backup = try EditorialProjectMigration.prepare(packageURL: package, backupRoot: root.appendingPathComponent("backups"))
    let (candidate, plan, analyses) = try await migrationCandidate()

    try EditorialProjectMigration.activateAutomatically(candidate: candidate, plan: plan, analyses: analyses, backup: backup)

    let result = try JSONDecoder.veloEdit.decode(ProjectManifest.self, from: Data(contentsOf: package.appendingPathComponent("project.json")))
    let activated = try #require(result.timelines.last)
    #expect(result.timelines.map(\.id) == [old.id, candidate.id])
    #expect(activated.editorialRegeneration?.activationMethod == "automated-rendered-verifier")
    #expect(activated.editorialRegeneration?.humanReview == nil)
    #expect(activated.editorialRegeneration?.backupManifestSHA256 == backup.manifestSHA256)
    #expect(result.timelineCheckpoints?.contains { $0.timeline.id == old.id } == true)
    #expect(EditorialRenderSignature.signature(activated) == EditorialRenderSignature.signature(candidate))
}

@Test func migrationLiveStoreCannotOverwriteAnotherStoreOrOfflineActivation() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("veloedit")
    defer { try? FileManager.default.removeItem(at: root) }
    let first = try ProjectStore(createAt: root, name: "initial")
    let second = try ProjectStore(open: root)
    try await first.update { $0.name = "newer edit" }
    do {
        try await second.update { $0.name = "stale overwrite" }
        Issue.record("An old in-memory store overwrote a newer manifest")
    } catch ProjectStoreError.externalModification {}
    #expect(await second.manifest.name == "initial")
    let onDisk = try JSONDecoder.veloEdit.decode(ProjectManifest.self, from: Data(contentsOf: root.appendingPathComponent("project.json")))
    #expect(onDisk.name == "newer edit")
    // Conflicting edits stay in the durable recovery journal; opening must
    // never silently overwrite either writer's value.
    #expect(throws: ProjectStoreError.self) { _ = try ProjectStore(open: root) }
}

@Test func openingHealthyProjectWithTerminalIntentLedgerIsReadOnlyAndParallelSafe() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("veloedit")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try ProjectStore(createAt: root, name: "parallel open")
    let terminal = IntentLedgerEntry(
        id: UUID(),
        projectRevision: 0,
        normalizedIntent: .createFilm,
        source: .prompt,
        status: .fulfilled,
        evidence: []
    )
    try await store.update { $0.intentLedger = IntentLedger(entries: [terminal]) }
    let manifestURL = root.appendingPathComponent("project.json")
    let before = try Data(contentsOf: manifestURL)

    try await withThrowingTaskGroup(of: Void.self) { group in
        for _ in 0..<8 {
            group.addTask {
                _ = try ProjectStore(open: root)
            }
        }
        try await group.waitForAll()
    }

    #expect(try Data(contentsOf: manifestURL) == before)
}

@Test func reloadRefreshesManifestFingerprintBeforeTheNextWrite() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("veloedit")
    defer { try? FileManager.default.removeItem(at: root) }
    let first = try ProjectStore(createAt: root, name: "initial")
    let external = try ProjectStore(open: root)
    try await external.update { $0.name = "external edit" }

    try await first.reload()
    #expect(await first.manifest.name == "external edit")
    try await first.update { $0.name = "local edit after reload" }

    let reopened = try ProjectStore(open: root)
    #expect(await reopened.manifest.name == "local edit after reload")
}
