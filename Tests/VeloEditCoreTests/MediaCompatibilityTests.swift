import Foundation
import AVFoundation
import Testing
@testable import VeloEditCore

@Suite(.serialized)
struct MediaCompatibilityTests {
    @Test func newMaterialsRequireStoryRebuildRatherThanOnlyReapplyingSettings() {
        #expect(DirectorRequestContract.requiresStoryRebuild("Используй вновь добавленные материалы в фильме"))
        #expect(DirectorRequestContract.requiresStoryRebuild("Добавь новые материалы"))
        #expect(!DirectorRequestContract.requiresStoryRebuild("Громкость музыки 20%"))
    }

    @Test func legacyMovieConvertsAndReimportsWithoutDuplicates() async throws {
        let executable = try #require(MediaCompatibility.converterURL)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("veloedit-format-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("old-camera.wmv")
        let process = Process()
        process.executableURL = executable
        process.arguments = ["-nostdin", "-loglevel", "error", "-f", "lavfi", "-i", "testsrc2=size=96x64:rate=10", "-t", "2", "-c:v", "wmv2", source.path]
        try process.run(); process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        let originalHash = try MediaImporter.sha256(url: source)
        let store = try ProjectStore(createAt: root.appendingPathComponent("Film.veloedit"), name: "Old camera")
        let pipeline = VeloEditPipeline(store: store)
        let errors = try await pipeline.importMedia([source])
        #expect(errors.isEmpty)
        let imported = try #require(await store.manifest.assets.first)
        #expect(imported.displayName == "old-camera.wmv")
        #expect(imported.conversionSourceURL == source)
        #expect(imported.originalURL.pathExtension == "mp4")
        #expect(try await AVURLAsset(url: imported.originalURL).load(.isPlayable))
        #expect(try MediaImporter.sha256(url: source) == originalHash)
        _ = try await pipeline.importMedia([source])
        #expect(await store.manifest.assets.count == 1)
        let unknown = root.appendingPathComponent("notes.unknown")
        try Data("not a movie".utf8).write(to: unknown)
        let warnings = try await pipeline.importMedia([source, unknown])
        #expect(warnings.contains { $0.contains("notes.unknown") })
    }

    @Test func cancellationLeavesNoPublishedCompatibilityCopy() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("veloedit-convert-cancel-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await MediaCompatibility.convert(root.appendingPathComponent("input.avi"), directory: root)
        }
        do { _ = try await task.value; Issue.record("Cancelled conversion completed") }
        catch is CancellationError { }
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test func cancellingRunningConverterRemovesStagingAndPreservesSource() async throws {
        let executable = try #require(MediaCompatibility.converterURL)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("veloedit-convert-active-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("old-camera.avi")
        let producer = Process()
        producer.executableURL = executable
        producer.arguments = ["-nostdin", "-loglevel", "error", "-f", "lavfi", "-i", "testsrc2=size=640x360:rate=30",
                              "-t", "20", "-c:v", "mpeg4", source.path]
        try producer.run(); producer.waitUntilExit()
        #expect(producer.terminationStatus == 0)
        let originalHash = try MediaImporter.sha256(url: source)
        let converted = root.appendingPathComponent("Converted")
        let (updates, continuation) = AsyncStream<ImportProgress>.makeStream()
        let task = Task {
            defer { continuation.finish() }
            return try await MediaCompatibility.convert(source, directory: converted) { continuation.yield($0) }
        }
        var iterator = updates.makeAsyncIterator()
        let update = try #require(await iterator.next())
        #expect(update.currentName.contains("Конвертирую"))
        task.cancel()
        do { _ = try await task.value; Issue.record("Cancelled conversion completed") }
        catch is CancellationError { }
        #expect(try FileManager.default.contentsOfDirectory(atPath: converted.path).isEmpty)
        #expect(try MediaImporter.sha256(url: source) == originalHash)
    }
}
