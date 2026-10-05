import Foundation
import AVFoundation
import Testing
@testable import VeloEditCore

struct ProjectVideoFilesTests {
    @Test func renderedSiblingVideoSurvivesProjectReopenAndHasDecodableFrames() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let package = root.appendingPathComponent("Film.veloedit")
        let recovery = root.appendingPathComponent("Recovery")
        let store = try ProjectStore(createAt: package, name: "Film", recoveryDirectory: recovery)
        let photo = root.appendingPathComponent("source.png")
        try AutonomousOperationTests.photo(at: photo)
        let asset = try await MediaImporter().makeAsset(url: photo)
        let timeline = Timeline(storyPlanID: UUID(), width: 320, height: 180, frameRate: 15,
            items: [TimelineItem(assetID: asset.id, kind: .photo, sourceDuration: 0.6, timelineStart: 0, timelineDuration: 0.6)])
        try await store.update { $0.assets = [asset]; $0.timelines = [timeline] }
        let pipeline = VeloEditPipeline(store: store)
        let output = await pipeline.defaultVideoDestination()
        let report = try await pipeline.render(to: output, quality: .maximum)
        #expect(report.outputURL == root.appendingPathComponent("Film.mp4"))
        #expect(report.videoInfo?.width == 320)
        let movie = AVURLAsset(url: output)
        let image = try await AVAssetImageGenerator(asset: movie).image(at: .zero)
        #expect(image.image.width == 320)
        let reopened = try ProjectStore(open: package, recoveryDirectory: recovery)
        #expect(await reopened.manifest.timelines.last?.id == timeline.id)
        #expect(await reopened.manifest.renderJobs.last?.status == .completed)
        #expect(await reopened.manifest.renderJobs.last?.outputURL == output)
        #expect(try FileManager.default.contentsOfDirectory(atPath: package.appendingPathComponent("Exports").path).isEmpty)
    }

    @Test func defaultExportIsBesideProjectAndPreservesPreviousVideos() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let package = root.appendingPathComponent("Мой фильм.veloedit")
        let store = try ProjectStore(createAt: package, name: "Display name / can differ")
        let pipeline = VeloEditPipeline(store: store)
        let first = await pipeline.defaultVideoDestination()
        #expect(first.path == root.appendingPathComponent("Мой фильм.mp4").path)
        try Data("existing video".utf8).write(to: first)
        let second = await pipeline.defaultVideoDestination()
        #expect(second.path == root.appendingPathComponent("Мой фильм — 2.mp4").path)
        try Data("second video".utf8).write(to: second)
        #expect(await pipeline.defaultVideoDestination() == root.appendingPathComponent("Мой фильм — 3.mp4"))
        #expect(try Data(contentsOf: first) == Data("existing video".utf8))
        #expect(!ProjectVideoFiles.isInsideProject(first, package: package))
    }

    @Test func embeddedExportCopiesWithoutReencodingAndReopensWithExternalPath() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let package = root.appendingPathComponent("Film.veloedit")
        let recovery = root.appendingPathComponent("Recovery")
        let store = try ProjectStore(createAt: package, name: "Film", recoveryDirectory: recovery)
        let source = package.appendingPathComponent("Exports/old.mp4")
        let bytes = Data("already encoded video bytes".utf8)
        try bytes.write(to: source)
        var job = RenderJob(timelineID: UUID(), quality: .maximum, outputURL: source, status: .completed, progress: 1)
        job.artifactHash = try MediaImporter.sha256(url: source)
        try await store.update { $0.renderJobs = [job] }
        let pipeline = VeloEditPipeline(store: store)
        let output = try await pipeline.copyExportNextToProject(jobID: job.id)
        #expect(output == root.appendingPathComponent("Film.mp4"))
        #expect(try Data(contentsOf: output) == bytes)
        #expect(try Data(contentsOf: source) == bytes)
        let reopened = try ProjectStore(open: package, recoveryDirectory: recovery)
        #expect(await reopened.manifest.renderJobs.first?.outputURL == output)
        #expect(await reopened.manifest.renderJobs.first?.artifactHash == job.artifactHash)
        #expect(try await pipeline.copyExportNextToProject(jobID: job.id) == output)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Film — 2.mp4").path))
    }

    @Test func corruptEmbeddedExportIsNotPublishedOrRepointed() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let package = root.appendingPathComponent("Film.veloedit")
        let store = try ProjectStore(createAt: package, name: "Film", recoveryDirectory: root.appendingPathComponent("Recovery"))
        let source = package.appendingPathComponent("Exports/old.mp4")
        try Data("damaged".utf8).write(to: source)
        var job = RenderJob(timelineID: UUID(), quality: .maximum, outputURL: source, status: .completed)
        job.artifactHash = "different-hash"
        try await store.update { $0.renderJobs = [job] }
        await #expect(throws: (any Error).self) {
            try await VeloEditPipeline(store: store).copyExportNextToProject(jobID: job.id)
        }
        #expect(await store.manifest.renderJobs.first?.outputURL == source)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Film.mp4").path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["Film.veloedit"])
    }
}
