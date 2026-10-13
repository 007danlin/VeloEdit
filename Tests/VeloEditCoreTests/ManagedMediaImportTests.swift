import Foundation
import Testing
@testable import VeloEditCore

@Suite(.serialized)
struct ManagedMediaImportTests {
    @Test func unrelatedOfflineSourceDoesNotBlockNewImport() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ProjectStore(createAt: root.appendingPathComponent("Project.veloedit"), name: "Mixed")
        let missing = MediaAsset(originalURL: root.appendingPathComponent("offline/old.mp4"), kind: .video,
            byteSize: 500, contentHash: "missing", metadata: MediaMetadata(duration: 1))
        try await store.update { $0.assets = [missing] }
        let source = root.appendingPathComponent("new.png")
        try AutonomousOperationTests.photo(at: source)
        let pipeline = VeloEditPipeline(store: store, shouldCopyImportedMedia: { _ in true })
        #expect(try await pipeline.importMedia([source]).isEmpty)
        let project = await store.manifest
        #expect(project.assets.count == 2)
        #expect(project.assets.first(where: { $0.id == missing.id })?.missing == true)
        let added = try #require(project.assets.first(where: { $0.id != missing.id }))
        #expect(added.importSourceURL == source)
        #expect(added.originalURL != source)
    }

    @Test func externalImportSurvivesDisconnectionMoveAndExport() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let external = root.appendingPathComponent("USB")
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        let source = external.appendingPathComponent("camera.mp4")
        let producer = Process()
        producer.executableURL = MediaCompatibility.converterURL
        producer.arguments = ["-nostdin", "-loglevel", "error", "-f", "lavfi", "-i", "testsrc2=size=320x180:rate=15",
            "-t", "0.6", "-c:v", "libx264", "-pix_fmt", "yuv420p", source.path]
        try producer.run(); producer.waitUntilExit()
        #expect(producer.terminationStatus == 0)
        let originalHash = try MediaImporter.sha256(url: source)
        let package = root.appendingPathComponent("Project.veloedit")
        let store = try ProjectStore(createAt: package, name: "USB import")
        let pipeline = VeloEditPipeline(store: store, shouldCopyImportedMedia: { $0.path.hasPrefix(external.path + "/") })
        #expect(try await pipeline.importMedia([source]).isEmpty)
        let asset = try #require(await store.manifest.assets.first)
        #expect(asset.originalURL.path.hasPrefix(package.path + "/Media/Originals/"))
        #expect(asset.importSourceURL == source)
        #expect(asset.fullContentHash == originalHash)
        #expect(try MediaImporter.sha256(url: asset.originalURL) == originalHash)
        #expect(try await pipeline.importMedia([source]).isEmpty)
        #expect(await store.manifest.assets.count == 1)
        #expect(await store.manifest.assets.first?.originalURL == asset.originalURL)
        let timeline = Timeline(storyPlanID: UUID(), width: 320, height: 180, frameRate: 15,
            items: [TimelineItem(assetID: asset.id, kind: .video, sourceDuration: 0.6, timelineStart: 0, timelineDuration: 0.6)])
        try await store.update { $0.timelines = [timeline] }
        try FileManager.default.removeItem(at: external)
        let moved = root.appendingPathComponent("Moved.veloedit")
        try FileManager.default.moveItem(at: package, to: moved)
        let reopened = try ProjectStore(open: moved)
        let saved = try #require(await reopened.manifest.assets.first)
        #expect(saved.id == asset.id)
        #expect(saved.originalURL.path.hasPrefix(moved.path + "/Media/"))
        #expect(try MediaImporter.sha256(url: saved.originalURL) == originalHash)
        let report = try await VeloEditPipeline(store: reopened).render(to: root.appendingPathComponent("offline.mp4"), quality: .maximum)
        #expect(report.videoInfo?.width == 320)
        #expect(report.skippedItemIDs.isEmpty)
    }

    @Test func olderExternalReferencesAreCopiedWithoutChangingTimelineIDs() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ProjectStore(createAt: root.appendingPathComponent("Project.veloedit"), name: "Legacy")
        let source = root.appendingPathComponent("old.png")
        try AutonomousOperationTests.photo(at: source)
        let asset = try await MediaImporter().makeAsset(url: source)
        let item = TimelineItem(assetID: asset.id, kind: .photo, sourceDuration: 1, timelineStart: 0, timelineDuration: 1)
        try await store.update { $0.assets = [asset]; $0.timelines = [Timeline(storyPlanID: UUID(), items: [item])] }
        try await VeloEditPipeline(store: store, shouldCopyImportedMedia: { _ in true }).secureExternalMedia()
        let after = await store.manifest
        #expect(after.assets.first?.id == asset.id)
        #expect(after.assets.first?.originalURL != source)
        #expect(after.timelines.first?.items == [item])
        #expect(try MediaImporter.sha256(url: source) == after.assets.first?.fullContentHash)
    }

    @Test func failedCopyKeepsOriginalReferenceAndNoPartialAsset() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let package = root.appendingPathComponent("Project.veloedit")
        let store = try ProjectStore(createAt: package, name: "Failure")
        let source = root.appendingPathComponent("source.png")
        try AutonomousOperationTests.photo(at: source)
        let asset = try await MediaImporter().makeAsset(url: source)
        try await store.update { $0.assets = [asset] }
        try Data([1]).write(to: package.appendingPathComponent("Media"))
        let pipeline = VeloEditPipeline(store: store, shouldCopyImportedMedia: { _ in true })
        await #expect(throws: (any Error).self) { try await pipeline.secureExternalMedia() }
        #expect(await store.manifest.assets.first?.originalURL == source)
        #expect(await store.manifest.packagedMediaPaths == nil)
    }

    @Test func cancellationNeverPublishesPartialCopy() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source.mov")
        try Data(repeating: 9, count: 8 * 1024 * 1024).write(to: source)
        let destination = root.appendingPathComponent("copy.mov")
        let task = Task { try await ManagedMediaImport.copy(source, to: destination, progress: nil) }
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["source.mov"])
    }
}
