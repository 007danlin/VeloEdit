import Foundation
import Testing
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import VeloEditCore

@Suite(.serialized)
struct AutonomousOperationTests {
    struct Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("autonomy-\(UUID().uuidString)")
        var package: URL { root.appendingPathComponent("project.veloedit") }
        var recovery: URL { root.appendingPathComponent("recovery") }
        func store() throws -> ProjectStore { try ProjectStore(createAt: package, name: "Autonomy", recoveryDirectory: recovery) }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    @Test func localJournalRestoresAfterPrimaryOutageAndRestart() async throws {
        let f = Fixture(); defer { f.remove() }
        let store = try f.store()
        let moved = f.root.appendingPathComponent("offline.veloedit")
        try FileManager.default.moveItem(at: f.package, to: moved)
        try await store.updateWorkspaceState(ProjectWorkspaceState(prompt: "Последняя правка", preset: .story, targetMinutes: 2))
        #expect(try await store.verifyDurableState() == .localRecovery)
        let duringOutage = try ProjectStore(open: f.package, recoveryDirectory: f.recovery)
        #expect(await duringOutage.manifest.workspaceState?.prompt == "Последняя правка")
        #expect(!FileManager.default.fileExists(atPath: f.package.path))
        try FileManager.default.moveItem(at: moved, to: f.package)
        let restored = try ProjectStore(open: f.package, recoveryDirectory: f.recovery)
        #expect(await restored.manifest.workspaceState?.prompt == "Последняя правка")
        #expect(try await restored.verifyDurableState() == .project)
        #expect(try LocalProjectRecovery.read(package: f.package, root: f.recovery) == nil)
    }

    @Test func failureOfBothStoresDoesNotClaimDurability() async throws {
        let f = Fixture(); defer { f.remove() }
        let store = try f.store()
        try Data([1]).write(to: f.recovery)
        try FileManager.default.moveItem(at: f.package, to: f.root.appendingPathComponent("offline"))
        await #expect(throws: (any Error).self) { try await store.update { $0.name = "Unsaved" } }
        #expect(await store.manifest.name == "Autonomy")
        await #expect(throws: (any Error).self) { _ = try await store.verifyDurableState() }
    }

    @Test func recoveryMergesIndependentFieldsAndRefusesOverlappingEdits() async throws {
        let f = Fixture(); defer { f.remove() }
        let store = try f.store()
        let base = await store.manifest
        var local = base; local.workspaceState = ProjectWorkspaceState(prompt: "Draft", preset: .story, targetMinutes: 1)
        try LocalProjectRecovery.stage(local, base: base, package: f.package, root: f.recovery)
        try await store.update { $0.name = "Remote rename" }
        // An external process cannot delete a recovery journal it did not own.
        try LocalProjectRecovery.stage(local, base: base, package: f.package, root: f.recovery)
        let merged = try ProjectStore(open: f.package, recoveryDirectory: f.recovery)
        #expect(await merged.manifest.name == "Remote rename")
        #expect(await merged.manifest.workspaceState?.prompt == "Draft")
        let nextBase = await merged.manifest
        var conflicting = nextBase; conflicting.name = "Local rename"
        try await merged.update { $0.name = "Second remote rename" }
        try LocalProjectRecovery.stage(conflicting, base: nextBase, package: f.package, root: f.recovery)
        #expect(throws: ProjectStoreError.self) { _ = try ProjectStore(open: f.package, recoveryDirectory: f.recovery) }
        #expect(try LocalProjectRecovery.read(package: f.package, root: f.recovery) != nil)
        #expect(try JSONDecoder.veloEdit.decode(ProjectManifest.self, from: Data(contentsOf: f.package.appendingPathComponent("project.json"))).name == "Second remote rename")
    }

    @Test func recoveryBudgetSurvivesRestartAndCancellationIsExplicit() async throws {
        let f = Fixture(); defer { f.remove() }
        let store = try f.store()
        let first = try await store.beginAutonomousJob(kind: .film)
        #expect(try await store.beginAutonomousJob(kind: .film).id == first.id)
        #expect(try await store.reserveRecovery(error: URLError(.timedOut), strategy: "retry") == 1)
        let reopened = try ProjectStore(open: f.package, recoveryDirectory: f.recovery)
        #expect(try await reopened.reserveRecovery(error: URLError(.timedOut), strategy: "retry") == 3)
        #expect(try await reopened.reserveRecovery(error: URLError(.timedOut), strategy: "retry") == nil)
        #expect(try await reopened.reserveRecovery(error: DerivedMediaError.exportFailed("encoder"), strategy: "software") == 0)
        #expect(try await reopened.reserveRecovery(error: DerivedMediaError.exportFailed("encoder"), strategy: "software") == nil)
        try await reopened.cancelAutonomousJob()
        let cancelled = try ProjectStore(open: f.package, recoveryDirectory: f.recovery)
        #expect(await cancelled.manifest.autonomousJob?.explicitCancellation == true)
        #expect(await cancelled.manifest.autonomousJob?.state.resumesAutomatically == false)
    }

    @Test func operationLeasePreventsConcurrentWritersAndReleases() throws {
        let f = Fixture(); defer { f.remove() }
        _ = try f.store()
        var lease: ProjectOperationLease? = try ProjectOperationLease(package: f.package)
        #expect(throws: AutonomousOperationError.self) { _ = try ProjectOperationLease(package: f.package) }
        withExtendedLifetime(lease) {}
        lease = nil
        _ = try ProjectOperationLease(package: f.package)
    }

    @Test func exactApproximateRangeAndAutomaticDurationContracts() {
        #expect(FilmDurationRequirement.parse(prompt: "пять минут").target == 300)
        let exact = FilmDurationRequirement.parse(prompt: "5 минут")
        #expect(exact.accepts(duration: 300 - 1 / 30.0, frameRate: 30))
        #expect(!exact.accepts(duration: 43, frameRate: 30))
        #expect(!exact.accepts(duration: 299.9, frameRate: 30))
        let approximate = FilmDurationRequirement.parse(prompt: "около 5 минут")
        #expect(approximate.accepts(duration: 285, frameRate: 30))
        #expect(!approximate.accepts(duration: 284, frameRate: 30))
        let range = FilmDurationRequirement.parse(prompt: "от 3 до 5 минут")
        #expect(range.mode == .range && range.accepts(duration: 230, frameRate: 30))
        #expect(!range.accepts(duration: 301, frameRate: 30))
        #expect(FilmDurationRequirement.parse(prompt: "Собери поездку").accepts(duration: 28, frameRate: 30))
        #expect(DirectorBrief.legacyDefault.explicitRequestedDuration == nil)
    }

    @Test func relinkingVerifiesContentAndRejectsAmbiguousCopies() async throws {
        let f = Fixture(); defer { f.remove() }
        _ = try f.store()
        let original = f.root.appendingPathComponent("source.png")
        try Self.photo(at: original)
        var asset = try await MediaImporter().makeAsset(url: original)
        asset.bookmarkData = nil // Exercise search; a valid bookmark has stronger file identity.
        let folder = f.root.appendingPathComponent("allowed")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let moved = folder.appendingPathComponent("renamed.png")
        try FileManager.default.moveItem(at: original, to: moved)
        #expect(try MediaSourceRecovery.resolve(asset, folders: [folder])?.resolvingSymlinksInPath() == moved.resolvingSymlinksInPath())
        try FileManager.default.copyItem(at: moved, to: folder.appendingPathComponent("duplicate.png"))
        #expect(try MediaSourceRecovery.resolve(asset, folders: [folder]) == nil)
    }

    @Test func duplicateImportDoesNotInvalidateFilmOrSourceMap() async throws {
        let f = Fixture(); defer { f.remove() }
        let store = try f.store()
        let original = f.root.appendingPathComponent("source.png")
        try Self.photo(at: original)
        let pipeline = VeloEditPipeline(store: store)
        _ = try await pipeline.importMedia([original])
        try await store.update { $0.sourceMap = .empty }
        let revision = await store.currentRevision()
        _ = try await pipeline.importMedia([original])
        #expect(await store.manifest.assets.count == 1)
        #expect(await store.manifest.sourceMap != nil)
        #expect(await store.currentRevision() == revision)
    }

    @Test func corruptedThumbnailIsRegeneratedFromOriginal() async throws {
        let f = Fixture(); defer { f.remove() }
        _ = try f.store()
        let source = f.root.appendingPathComponent("source.png"), thumbnail = f.root.appendingPathComponent("thumb.jpg")
        try Self.photo(at: source)
        let asset = try await MediaImporter().makeAsset(url: source)
        try Data("partial".utf8).write(to: thumbnail)
        _ = try await ThumbnailGenerator().generate(for: asset, destination: thumbnail)
        let decoded = try #require(CGImageSourceCreateWithURL(thumbnail as CFURL, nil))
        #expect(CGImageSourceCreateImageAtIndex(decoded, 0, nil) != nil)
    }

    #if DEBUG
    // Fault injection deliberately does not exist in production binaries.
    // Release still runs the non-injected export/recovery tests in this suite.
    @Test func encoderFailureRecoversAndVerifiedExportSurvivesRestart() async throws {
        let f = Fixture(); defer { f.remove() }
        let store = try f.store()
        let source = f.root.appendingPathComponent("source.png")
        try Self.photo(at: source)
        let asset = try await MediaImporter().makeAsset(url: source)
        let timeline = Timeline(storyPlanID: UUID(), width: 320, height: 180, frameRate: 15,
            items: [TimelineItem(assetID: asset.id, kind: .photo, sourceDuration: 1, timelineStart: 0, timelineDuration: 1)], originalAudioVolume: 0)
        try await store.update { $0.assets = [asset]; $0.timelines = [timeline] }
        let pipeline = VeloEditPipeline(store: store)
        let destination = f.root.appendingPathComponent("film.mp4")
        let originalHash = try MediaImporter.sha256(url: source)
        let report = try await AutonomyFaultInjection.$handler.withValue({ stage, attempt in
            if stage == .export && attempt == 1 { throw DerivedMediaError.exportFailed("injected hardware failure") }
        }) {
            try await pipeline.render(to: destination, quality: .preview720p, frameRate: 15)
        }
        #expect(report.videoInfo?.frameRate == 15)
        #expect(report.videoInfo?.width == 1280)
        #expect(await store.manifest.autonomousJob?.attempts.count == 1)
        #expect(try MediaImporter.sha256(url: source) == originalHash)
        let outputHash = try MediaImporter.sha256(url: destination)
        let date = try destination.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        // Crash boundary: the verified file was published, completion commit
        // was not delivered. Resume must validate/reuse it, never duplicate it.
        try await store.persistOperationalState {
            $0.renderJobs[0].status = .running
            $0.autonomousJob?.state = .queued
        }
        let reopened = try ProjectStore(open: f.package, recoveryDirectory: f.recovery)
        let resumed = try await VeloEditPipeline(store: reopened).resumeExport()
        #expect(resumed?.outputURL == destination)
        #expect(try MediaImporter.sha256(url: destination) == outputHash)
        #expect(try destination.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == date)
        #expect(await reopened.manifest.renderJobs.count == 1)
        #expect(await reopened.manifest.renderJobs[0].status == .completed)
        #expect(await reopened.manifest.renderJobs[0].timelineID == timeline.id)
    }
    #endif

    @Test func removalUndoRestoresAnalysisClipsAndOriginal() async throws {
        let f = Fixture(); defer { f.remove() }
        let store = try f.store()
        let source = f.root.appendingPathComponent("source.png")
        try Self.photo(at: source)
        let asset = try await MediaImporter().makeAsset(url: source)
        let analysis = AnalysisResult(assetID: asset.id, analyzedContentHash: asset.contentHash, sceneTags: ["blue"], candidates: [])
        let timeline = Timeline(storyPlanID: UUID(), items: [TimelineItem(assetID: asset.id, kind: .photo, sourceDuration: 3, timelineStart: 0, timelineDuration: 3)])
        try await store.update { $0.assets = [asset]; $0.analyses = [analysis]; $0.timelines = [timeline] }
        let pipeline = VeloEditPipeline(store: store)
        try await pipeline.removeAsset(id: asset.id)
        #expect(await store.manifest.assets.isEmpty)
        let removal = try #require(await store.manifest.removedMedia?.last)
        try await pipeline.restoreRemovedMedia(id: removal.id)
        #expect(await store.manifest.assets == [asset])
        #expect(await store.manifest.analyses == [analysis])
        #expect(await store.manifest.timelines == [timeline])
        #expect(FileManager.default.fileExists(atPath: source.path))
    }

    @Test func orphanCacheCleanupRetainsSourceHistoryAndExports() async throws {
        let f = Fixture(); defer { f.remove() }
        let store = try f.store()
        let source = f.root.appendingPathComponent("source.png")
        try Self.photo(at: source)
        let asset = try await MediaImporter().makeAsset(url: source)
        try await store.update { $0.assets = [asset] }
        let cache = CachePaths(root: f.package.appendingPathComponent("Cache"))
        let protected = cache.proxy(for: asset)
        let orphan = protected.deletingLastPathComponent().appendingPathComponent("00000000000000000000-analysis-720p.mp4")
        let export = f.package.appendingPathComponent("Exports/keep.mp4")
        for file in [protected, orphan, export] { try Data([1, 2, 3]).write(to: file) }
        #expect(try ProjectCacheMaintenance.removeOrphanedArtifacts(package: f.package, manifest: await store.manifest) == 3)
        #expect(FileManager.default.fileExists(atPath: protected.path))
        #expect(FileManager.default.fileExists(atPath: export.path))
        #expect(!FileManager.default.fileExists(atPath: orphan.path))
    }

    @Test func collectedProjectExportsAfterMovingAndRemovingOriginals() async throws {
        let f = Fixture(); defer { f.remove() }
        let store = try f.store()
        let source = f.root.appendingPathComponent("portable-source.png")
        try Self.photo(at: source)
        let asset = try await MediaImporter().makeAsset(url: source)
        let timeline = Timeline(storyPlanID: UUID(), width: 320, height: 180, frameRate: 15,
            items: [TimelineItem(assetID: asset.id, kind: .photo, sourceDuration: 0.6, timelineStart: 0, timelineDuration: 0.6)])
        try await store.update { $0.assets = [asset]; $0.timelines = [timeline] }
        let copy = f.root.appendingPathComponent("copy.veloedit")
        _ = try await VeloEditPipeline(store: store).collectProjectCopy(to: copy)
        let moved = f.root.appendingPathComponent("moved.veloedit")
        try FileManager.default.moveItem(at: copy, to: moved)
        try FileManager.default.removeItem(at: source)
        try FileManager.default.removeItem(at: f.package)
        let reopened = try ProjectStore(open: moved, recoveryDirectory: f.recovery)
        let embedded = try #require(await reopened.manifest.assets.first)
        #expect(embedded.originalURL.path.hasPrefix(moved.path + "/Media/"))
        #expect(FileManager.default.isReadableFile(atPath: embedded.originalURL.path))
        let output = moved.appendingPathComponent("Exports/portable.mp4")
        let report = try await VeloEditPipeline(store: reopened).render(to: output, quality: .maximum)
        #expect(report.videoInfo?.width == 320)
        #expect(report.skippedItemIDs.isEmpty)
        let again = try ProjectStore(open: moved, recoveryDirectory: f.recovery)
        #expect(await again.manifest.renderJobs.last?.status == .completed)
        let movedAgain = f.root.appendingPathComponent("moved-again.veloedit")
        try FileManager.default.moveItem(at: moved, to: movedAgain)
        let final = try ProjectStore(open: movedAgain, recoveryDirectory: f.recovery)
        let saved = try #require(await final.manifest.renderJobs.last)
        #expect(saved.outputURL.path.hasPrefix(movedAgain.path))
        #expect(FileManager.default.isReadableFile(atPath: saved.outputURL.path))
        #expect(saved.artifactHash == (try MediaImporter.sha256(url: saved.outputURL)))
    }

    static func photo(at url: URL) throws {
        let context = try #require(CGContext(data: nil, width: 96, height: 64, bitsPerComponent: 8, bytesPerRow: 384, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.1, green: 0.4, blue: 0.8, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 96, height: 64))
        let image = try #require(context.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }
}
