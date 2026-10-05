import Foundation
import Testing
@testable import VeloEditCore

struct ProjectOpeningTests {
    @Test func openingPreviewSkipsHeavyStateAndRejectsStaleOrCorruptCache() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let package = root.appendingPathComponent("project.veloedit")
        let store = try ProjectStore(createAt: package, name: "Before", recoveryDirectory: root.appendingPathComponent("Recovery"))
        let asset = MediaAsset(originalURL: root.appendingPathComponent("ride.mov"), bookmarkData: Data(repeating: 1, count: 4_096),
                               kind: .video, byteSize: 1, contentHash: "ride", metadata: MediaMetadata(duration: 8))
        try await store.update { $0.assets = [asset] }
        let preview = try #require(ProjectOpeningPreview.load(from: package))
        #expect(preview.assets.map(\.id) == [asset.id])
        #expect(preview.assets.first?.bookmarkData == nil)
        let source = package.appendingPathComponent("project.json")
        let cache = package.appendingPathComponent(ProjectOpeningPreview.fileName)
        let cacheData = try Data(contentsOf: cache)
        #expect(cacheData.count < 4_096)
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: source)) as? [String: Any])
        json["name"] = "Changed externally"
        // Even intentionally undecodable analysis must be irrelevant to the
        // read-only presentation. The full store still validates it separately.
        json["analyses"] = [String(repeating: "heavy analysis ", count: 1_000_000)]
        try JSONSerialization.data(withJSONObject: json).write(to: source, options: .atomic)
        let start = Date()
        let refreshed = try #require(ProjectOpeningPreview.load(from: package))
        print("PERF legacy-opening-preview bytes=\((try Data(contentsOf: source)).count) milliseconds=\(Date().timeIntervalSince(start) * 1_000)")
        #expect(refreshed.name == "Changed externally")
        #expect(refreshed.assets.map(\.id) == [asset.id])
        #expect(try Data(contentsOf: cache) == cacheData)
        try Data("broken cache".utf8).write(to: cache)
        #expect(ProjectOpeningPreview.load(from: package)?.name == "Changed externally")
        try Data("broken project".utf8).write(to: source)
        #expect(ProjectOpeningPreview.load(from: package) == nil)
    }

    @Test(arguments: [false, true])
    func unchangedArchiveOpensWithoutRewritingAndCanStillSave(portable: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let package = root.appendingPathComponent("project.veloedit")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        var manifest = ProjectManifest(name: "Saved project")
        let media = package.appendingPathComponent("Media/clip.mov")
        let asset = MediaAsset(originalURL: media, kind: .video, byteSize: 1,
                               contentHash: "clip", metadata: MediaMetadata(duration: 8))
        manifest.assets = [asset]
        if portable {
            manifest.packagedFilePaths = [media.absoluteString: "Media/clip.mov"]
            manifest.packagedMediaPaths = [asset.id: "Media/clip.mov"]
        }
        // Noncanonical whitespace makes any unnecessary rewrite observable.
        let encoder = JSONEncoder.veloEdit
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let original = try encoder.encode(manifest)
        let url = package.appendingPathComponent("project.json")
        try original.write(to: url)
        let expected = try JSONDecoder.veloEdit.decode(ProjectManifest.self, from: original)
        let store = try ProjectStore(open: package, recoveryDirectory: root.appendingPathComponent("Recovery"))
        #expect(await store.manifest.assets == expected.assets)
        #expect(try Data(contentsOf: url) == original)
        try await store.update { $0.name = "Edited after opening" }
        #expect(try JSONDecoder.veloEdit.decode(ProjectManifest.self, from: Data(contentsOf: url)).name == "Edited after opening")
    }

    @Test func movedPortableArchiveRelocatesBeforePublishingAndCanStillSave() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let package = root.appendingPathComponent("moved.veloedit")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        var manifest = ProjectManifest(name: "Moved project")
        let oldMedia = root.appendingPathComponent("old.veloedit/Media/clip.mov")
        let asset = MediaAsset(originalURL: oldMedia, kind: .video, byteSize: 1,
                               contentHash: "clip", metadata: MediaMetadata(duration: 8))
        manifest.assets = [asset]
        manifest.packagedMediaPaths = [asset.id: "Media/clip.mov"]
        manifest.packagedFilePaths = [oldMedia.absoluteString: "Media/clip.mov"]
        let url = package.appendingPathComponent("project.json")
        try JSONEncoder.veloEdit.encode(manifest).write(to: url)
        let store = try ProjectStore(open: package, recoveryDirectory: root.appendingPathComponent("Recovery"))
        let movedMedia = package.appendingPathComponent("Media/clip.mov")
        #expect(await store.manifest.assets.first?.originalURL == movedMedia)
        #expect(await store.manifest.packagedFilePaths == [movedMedia.absoluteString: "Media/clip.mov"])
        try await store.update { $0.name = "Edited after moving" }
        let saved = try JSONDecoder.veloEdit.decode(ProjectManifest.self, from: Data(contentsOf: url))
        #expect(saved.assets.first?.originalURL == movedMedia)
        #expect(saved.name == "Edited after moving")
    }
}
