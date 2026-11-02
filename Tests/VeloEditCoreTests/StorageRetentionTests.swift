import Foundation
import Testing
@testable import VeloEditCore

@Suite struct StorageRetentionTests {
    @Test func largeLibraryDoesNotMultiplyTheAutomaticDiskAllowance() {
        for count in [1, 4, 5, 100, 10_000] {
            let perProject = StorageMaintenance.automaticBudget(projectCount: count)
            #expect(perProject <= 2 * 1_024 * 1_024 * 1_024)
            #expect(perProject * Int64(count) <= 8 * 1_024 * 1_024 * 1_024)
        }
    }

    @Test func automaticRetentionPreservesReferencesRecentFilesAndExternalSymlinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let package = root.appendingPathComponent("Test.veloedit")
        let store = try ProjectStore(createAt: package, name: "Test", recoveryDirectory: root.appendingPathComponent("Recovery"))
        let cache = package.appendingPathComponent("Cache/EditorialControlExports")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let old = cache.appendingPathComponent("old.mp4")
        let fresh = cache.appendingPathComponent("fresh.mp4")
        let referenced = cache.appendingPathComponent("referenced.mp4")
        let outside = root.appendingPathComponent("original.mov")
        for f in [old, fresh, referenced, outside] { try Data(repeating: 1, count: 32).write(to: f) }
        for f in [old, referenced] { try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-40 * 86_400)], ofItemAtPath: f.path) }
        // Unknown metadata is tolerated by Codable; URL collection must still protect it.
        let manifest = package.appendingPathComponent("project.json")
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any])
        json["retainedArtifact"] = referenced.absoluteString
        try JSONSerialization.data(withJSONObject: json).write(to: manifest)
        try FileManager.default.createSymbolicLink(at: cache.appendingPathComponent("external.mp4"), withDestinationURL: outside)
        let freed = try StorageMaintenance.trimInactiveCache(package: package, maximumBytes: 0)
        #expect(freed == 32)
        #expect(!FileManager.default.fileExists(atPath: old.path))
        for f in [fresh, referenced, outside] { #expect(FileManager.default.fileExists(atPath: f.path)) }
        withExtendedLifetime(store) {}
    }

    @Test func otherProjectReferencesAndUnreadableManifestsStopDeletion() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("A.veloedit")
        let b = root.appendingPathComponent("B.veloedit")
        let storeA = try ProjectStore(createAt: a, name: "A", recoveryDirectory: root.appendingPathComponent("Recovery"))
        let storeB = try ProjectStore(createAt: b, name: "B", recoveryDirectory: root.appendingPathComponent("Recovery"))
        let directory = a.appendingPathComponent("Cache/EditorialControlExports")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let media = directory.appendingPathComponent("shared.mp4")
        try Data(repeating: 1, count: 32).write(to: media)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-40 * 86_400)], ofItemAtPath: media.path)
        let manifest = b.appendingPathComponent("project.json")
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any])
        json["sharedSource"] = media.absoluteString
        try JSONSerialization.data(withJSONObject: json).write(to: manifest)
        #expect(try StorageMaintenance.trimInactiveCache(package: a, protectingProjects: [b], maximumBytes: 0) == 0)
        try Data("corrupt".utf8).write(to: manifest)
        #expect(throws: (any Error).self) { try StorageMaintenance.trimInactiveCache(package: a, protectingProjects: [b], maximumBytes: 0) }
        #expect(FileManager.default.fileExists(atPath: media.path))
        withExtendedLifetime((storeA, storeB)) {}
    }

    @Test func activeOperationPreventsAutomaticDeletion() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ProjectStore(createAt: root, name: "Busy", recoveryDirectory: root.appendingPathComponent("Recovery"))
        let lease = try ProjectOperationLease(package: root)
        #expect(throws: (any Error).self) { try StorageMaintenance.trimInactiveCache(package: root, maximumBytes: 0) }
        withExtendedLifetime((store, lease)) {}
    }

    @Test func newCacheCategoriesAreVisibleAndClearable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ProjectStore(createAt: root, name: "Cache", recoveryDirectory: root.appendingPathComponent("Recovery"))
        for name in ["SelectedContentFrames", "ExpressiveFrames", "SelectedContentReview", "SelectedContentResponses", "ExpressiveResponses", "EditorialPreviewFrames-17"] {
            let dir = root.appendingPathComponent("Cache/" + name)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data(repeating: 1, count: 32).write(to: dir.appendingPathComponent("record"))
        }
        #expect(StorageMaintenance.usage(of: root).reclaimableBytes == 192)
        #expect(try StorageMaintenance.clear([.previews, .analysis], package: root) == 192)
        withExtendedLifetime(store) {}
    }

    @Test func legacyCleanupPreservesUnknownRecentAndSymlinkedFiles() throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("VeloEdit-FrameCache-v2")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let old = dir.appendingPathComponent(String(repeating: "a", count: 64) + ".frame-v2.bin")
        let fresh = dir.appendingPathComponent(String(repeating: "b", count: 64) + ".frame-v2.bin")
        let unknown = dir.appendingPathComponent("original.mov")
        for f in [old, fresh, unknown] { try Data(repeating: 1, count: 32).write(to: f) }
        for f in [old, unknown] { try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-40 * 86_400)], ofItemAtPath: f.path) }
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent(String(repeating: "c", count: 64) + ".frame-v2.bin"), withDestinationURL: unknown)
        #expect(TemporaryMediaMaintenance.removeLegacyFrameCaches(in: root) == 32)
        #expect(FileManager.default.fileExists(atPath: fresh.path))
        #expect(FileManager.default.fileExists(atPath: unknown.path))
    }
}
