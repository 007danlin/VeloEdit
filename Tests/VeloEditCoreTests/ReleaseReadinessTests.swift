import Foundation
import Testing
@testable import VeloEditCore

private struct MaintenanceFixture {
    let root: URL
    let store: ProjectStore
    var package: URL { root.appendingPathComponent("test.veloedit") }
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("VeloEditMaintenance-\(UUID().uuidString)")
        store = try ProjectStore(createAt: root.appendingPathComponent("test.veloedit"), name: "Storage test", recoveryDirectory: root.appendingPathComponent("Recovery"))
    }
    func file(_ path: String, bytes: [UInt8] = [1, 2, 3, 4]) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(bytes).write(to: url)
        return url
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}

@Test func cacheCleanupPreservesSourcesAnalysisExportsAndOtherCategories() async throws {
    let fixture = try MaintenanceFixture(); defer { fixture.remove() }
    let source = try fixture.file("test.veloedit/Cache/Proxies/used-as-source.mov")
    let unused = try fixture.file("test.veloedit/Cache/Proxies/disposable.mp4")
    let preview = try fixture.file("test.veloedit/Cache/Preview/preview.mov")
    let analysis = try fixture.file("test.veloedit/Cache/Analysis/result.json")
    let export = try fixture.file("test.veloedit/Cache/Proxies/user-export.mp4")
    try await fixture.store.update {
        $0.assets = [MediaAsset(originalURL: source, kind: .video, byteSize: 4, contentHash: "original", metadata: MediaMetadata(duration: 1))]
        $0.renderJobs = [RenderJob(timelineID: UUID(), quality: .final1080p, outputURL: export, status: .completed)]
    }
    let manifestBefore = try Data(contentsOf: fixture.package.appendingPathComponent("project.json"))
    let usage = StorageMaintenance.usage(of: fixture.package)
    #expect(usage.cacheBytes[.proxies] == 4)
    let freed = try StorageMaintenance.clear(.proxies, package: fixture.package)
    #expect(freed == 4)
    #expect(!FileManager.default.fileExists(atPath: unused.path))
    for url in [source, preview, analysis, export] { #expect(FileManager.default.fileExists(atPath: url.path)) }
    #expect(try Data(contentsOf: fixture.package.appendingPathComponent("project.json")) == manifestBefore)
    #expect(StorageMaintenance.usage(of: fixture.package).cacheBytes[.proxies] == 0)
}

@Test func cacheCleanupDoesNotFollowSymlinksOrDeleteOtherProjectsSources() async throws {
    let fixture = try MaintenanceFixture(); defer { fixture.remove() }
    let external = try fixture.file("outside/precious.mov")
    let cache = fixture.package.appendingPathComponent("Cache")
    try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
    try FileManager.default.removeItem(at: cache.appendingPathComponent("Preview"))
    try FileManager.default.createSymbolicLink(at: cache.appendingPathComponent("Preview"), withDestinationURL: external.deletingLastPathComponent())
    #expect(try StorageMaintenance.clear(.previews, package: fixture.package) == 0)
    #expect(FileManager.default.fileExists(atPath: external.path))
    let shared = try fixture.file("test.veloedit/Cache/Proxies/shared.mp4")
    let other = try ProjectStore(createAt: fixture.root.appendingPathComponent("other.veloedit"), name: "Other", recoveryDirectory: fixture.root.appendingPathComponent("Recovery"))
    try await other.update { $0.assets = [MediaAsset(originalURL: shared, kind: .video, byteSize: 4, contentHash: "shared", metadata: MediaMetadata(duration: 1))] }
    #expect(try StorageMaintenance.clear(.proxies, package: fixture.package, protectingProjects: [fixture.root.appendingPathComponent("other.veloedit")]) == 0)
    #expect(FileManager.default.fileExists(atPath: shared.path))
    #expect(try StorageMaintenance.projectsDepending(on: [fixture.package], among: [fixture.package, fixture.root.appendingPathComponent("other.veloedit")]) == [fixture.root.appendingPathComponent("other.veloedit")])
}

@Test func cacheCleanupRefusesBusyOrUnreadableProjects() async throws {
    let fixture = try MaintenanceFixture(); defer { fixture.remove() }
    let file = try fixture.file("test.veloedit/Cache/Thumbnails/thumb.jpg")
    let lease = try ProjectOperationLease(package: fixture.package)
    #expect(throws: (any Error).self) { try StorageMaintenance.clear(.thumbnails, package: fixture.package) }
    withExtendedLifetime(lease) {}
    #expect(FileManager.default.fileExists(atPath: file.path))
    let invalid = try fixture.file("invalid.veloedit/project.json", bytes: [0])
    _ = try fixture.file("invalid.veloedit/Cache/Thumbnails/thumb.jpg")
    #expect(throws: (any Error).self) { try StorageMaintenance.clear(.thumbnails, package: invalid.deletingLastPathComponent()) }
}

@Test func missingMediaRelinksOnlyMatchingContentsAndKeepsAnalysis() async throws {
    let fixture = try MaintenanceFixture(); defer { fixture.remove() }
    let source = try fixture.file("before/source.mov")
    var asset = MediaAsset(originalURL: source, kind: .video, byteSize: 4, contentHash: "source", metadata: MediaMetadata(duration: 1))
    asset.fullContentHash = try MediaImporter.sha256(url: source)
    var analysis = AnalysisResult(assetID: asset.id, analyzedContentHash: asset.contentHash, sceneTags: ["retained"], candidates: [])
    analysis.analyzedSourceIdentity = FrameCacheKey.sourceIdentity(url: source, contentHash: asset.contentHash)
    try await fixture.store.update { $0.assets = [asset]; $0.analyses = [analysis] }
    try FileManager.default.removeItem(at: source)
    let pipeline = VeloEditPipeline(store: fixture.store)
    try await pipeline.refreshMediaAvailability()
    #expect(await fixture.store.manifest.assets.first?.missing == true)
    let wrong = try fixture.file("wrong.mov", bytes: [5, 6, 7, 8])
    await #expect(throws: MediaRelinkError.self) { try await pipeline.relinkMedia(assetID: asset.id, to: wrong) }
    #expect(await fixture.store.manifest.assets.first?.originalURL == source)
    let recovered = try fixture.file("after/source.mov")
    #expect(try await pipeline.relinkMedia(in: recovered.deletingLastPathComponent()) == 1)
    let updated = await fixture.store.manifest
    #expect(updated.assets.first?.originalURL.standardizedFileURL == recovered.standardizedFileURL)
    #expect(updated.assets.first?.missing == false)
    #expect(updated.analyses.first?.sceneTags == ["retained"])
    #expect(updated.analyses.first?.analyzedSourceIdentity == FrameCacheKey.sourceIdentity(url: recovered, contentHash: asset.contentHash))
}

@Test func missingExportHistoryDoesNotPreventPortableCopy() async throws {
    let fixture = try MaintenanceFixture(); defer { fixture.remove() }
    try await fixture.store.update { $0.renderJobs = [RenderJob(timelineID: UUID(), quality: .final1080p, outputURL: fixture.root.appendingPathComponent("deleted.mp4"), status: .completed)] }
    let destination = fixture.root.appendingPathComponent("chosen-folder/copy.veloedit")
    try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
    _ = try await VeloEditPipeline(store: fixture.store).collectProjectCopy(to: destination)
    #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent("project.json").path))
}

@Test func gracefulExitRestoresInterruptedJobButDoesNotRestartCompletedJob() async throws {
    let fixture = try MaintenanceFixture(); defer { fixture.remove() }
    _ = try await fixture.store.beginAutonomousJob(kind: .film)
    try await fixture.store.cancelAutonomousJob()
    try await fixture.store.prepareAutonomousJobForRestart()
    #expect(await fixture.store.manifest.autonomousJob?.state == .queued)
    #expect(await fixture.store.manifest.autonomousJob?.explicitCancellation == false)
    try await fixture.store.updateAutonomousJob { $0.state = .completed }
    try await fixture.store.prepareAutonomousJobForRestart()
    #expect(await fixture.store.manifest.autonomousJob?.state == .completed)
}

@Test func modelDownloadChecksSpaceBeforeProceeding() throws {
    #expect(throws: LocalAIModelError.self) { try LocalAIModelManager.checkDownloadCapacity(requiredBytes: 2_500_000_000, availableBytes: 100_000_000) }
    try LocalAIModelManager.checkDownloadCapacity(requiredBytes: 2_500_000_000, availableBytes: 3_000_000_000)
}

@Test func storageRecognizesProjectAliasesAndIncludesAbandonedPartialFiles() throws {
    let fixture = try MaintenanceFixture(); defer { fixture.remove() }
    let link = fixture.root.appendingPathComponent("alias.veloedit")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.package)
    #expect(StorageMaintenance.sameProject(link, fixture.package))
    #expect(StorageMaintenance.sameProject(URL(fileURLWithPath: fixture.package.path, isDirectory: false), URL(fileURLWithPath: fixture.package.path, isDirectory: true)))
    let partial = try fixture.file("test.veloedit/Cache/Preview/.unfinished.mov", bytes: [1, 2, 3])
    #expect(StorageMaintenance.usage(of: fixture.package).cacheBytes[.previews] == 3)
    #expect(try StorageMaintenance.clear(.previews, package: fixture.package) == 3)
    #expect(!FileManager.default.fileExists(atPath: partial.path))
}
