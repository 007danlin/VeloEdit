import AppKit
import AVFoundation
import Testing
import UniformTypeIdentifiers
import VeloEditCore
@testable import VeloEdit

@Suite(.serialized)
@MainActor
struct TimelineFileImportTests {
    @Test func fileProvidersPreserveOrderAndRejectWebURLs() async throws {
        let urls = [URL(fileURLWithPath: "/tmp/Второй кадр.png"), URL(fileURLWithPath: "/tmp/Первый кадр.png")]
        let providers = (urls + [URL(string: "https://example.com/photo.png")!]).map { url in
            let provider = NSItemProvider()
            provider.registerDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier, visibility: .all) { completion in
                completion(url.dataRepresentation, nil)
                return nil
            }
            return provider
        }
        #expect(await FileDropLoader.load(providers) == urls)
    }

    @Test func filesInsertAtTheDropPositionWithDuplicatesFailuresUndoAndReopen() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let first = try fixture.photo("A", red: 40)
        let second = try fixture.photo("B", red: 160)
        let copy = fixture.root.appendingPathComponent("Copy.png")
        try FileManager.default.copyItem(at: first, to: copy)
        let invalid = fixture.root.appendingPathComponent("unsupported.txt")
        try Data("Unsupported media".utf8).write(to: invalid)
        let model = fixture.model

        model.importMediaOntoTimeline([second, first], at: 0, audioStart: 0)
        try await wait { !model.isWorking }
        #expect(model.errorMessage == nil)
        let original = try #require(model.timeline)
        #expect(original.items.count == 2)
        let firstID = try #require(model.project?.assets.first(where: { $0.originalURL == first })?.id)
        let secondID = try #require(model.project?.assets.first(where: { $0.originalURL == second })?.id)
        #expect(original.items.map(\.assetID) == [secondID, firstID])
        #expect(model.section == .timeline)

        model.importMediaOntoTimeline([copy, invalid], at: 1, audioStart: 0)
        try await wait { !model.isWorking }
        let inserted = try #require(model.timeline)
        #expect(inserted.items.map(\.assetID) == [secondID, firstID, firstID])
        #expect(inserted.items.map(\.timelineStart) == [0, 4, 8])
        #expect(model.project?.assets.count == 2)
        #expect(model.project?.lastImportReport?.failures.count == 1)
        #expect(model.selectedTimelineItem?.id == inserted.items[1].id)
        #expect(model.errorMessage == nil)
        model.undoTimelineEdit()
        #expect(model.timeline == original)
        model.redoTimelineEdit()
        #expect(model.timeline == inserted)
        #expect(await model.flushAutosave())
        let reopened = try ProjectStore(open: fixture.url)
        // Dates use the project's ISO-8601 on-disk precision.
        let saved = try JSONDecoder.veloEdit.decode(Timeline.self, from: JSONEncoder.veloEdit.encode(inserted))
        #expect(await reopened.manifest.timelines.last == saved)
    }

    @Test func droppingAudioPlacesAClipAndReusesTheImportedTrack() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let photo = try fixture.photo("Image", red: 100)
        let audio = try fixture.audio()
        let pipeline = try #require(fixture.model.pipeline)
        _ = try await pipeline.importMediaIntoTimeline([photo, audio], atPrimaryIndex: 0, audioStart: 1)
        _ = try await pipeline.importMediaIntoTimeline([audio], atPrimaryIndex: 0, audioStart: 2)
        let snapshot = await pipeline.snapshot()
        let clips = try #require(snapshot.timelines.last?.effectiveAudioClips)
        #expect(clips.count == 2)
        #expect(clips.map(\.timelineStart) == [1, 2])
        #expect(clips[0].trackID == clips[1].trackID)
        #expect(clips.allSatisfy { abs($0.timelineDuration - 1) < 0.01 })
        #expect(snapshot.lastImportReport?.entries.first?.outcome == .duplicate)
        #expect(try await pipeline.store.verifyDurableState() == .project)
    }

    @Test func finderRenameFollowsTheOriginalPackageAndRelocatesEmbeddedMedia() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let source = try fixture.photo("Embedded", red: 80)
        let embedded = fixture.url.appendingPathComponent("Media/Embedded.png")
        try FileManager.default.createDirectory(at: embedded.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: embedded)
        let model = fixture.model
        let audio = try fixture.audio()
        model.importMediaOntoTimeline([embedded, audio], at: 0, audioStart: 0)
        try await wait { !model.isWorking }
        #expect(await model.flushAutosave())
        let moved = fixture.root.appendingPathComponent("Новое имя.veloedit")
        try FileManager.default.moveItem(at: fixture.url, to: moved)
        // Reusing the original name must never redirect saves to a different project.
        let replacement = try ProjectStore(createAt: fixture.url, name: "Unrelated")
        let unrelated = await replacement.manifest
        model.renameProject(to: "После Finder")
        try await wait { !model.isWorking }
        #expect(await model.flushAutosave())
        #expect(model.errorMessage == nil)
        #expect(model.projectURL?.resolvingSymlinksInPath().path == moved.resolvingSymlinksInPath().path)
        #expect(model.project?.assets.first?.originalURL.resolvingSymlinksInPath() == moved.appendingPathComponent("Media/Embedded.png").resolvingSymlinksInPath())
        let reopened = try ProjectStore(open: moved)
        #expect(await reopened.manifest.name == "После Finder")
        let originalPath = try ProjectStore(open: fixture.url)
        #expect(await originalPath.manifest.id == unrelated.id)
        #expect(await originalPath.manifest.name == "Unrelated")
        let pipeline = try #require(model.pipeline)
        let userTracks = try await pipeline.musicTracks().filter { $0.sourceProvider == .user }
        #expect(userTracks.count == 1)
        #expect(userTracks.allSatisfy { $0.isPlayable })
        #expect(userTracks.allSatisfy { $0.localFileURL.resolvingSymlinksInPath().path.hasPrefix(moved.resolvingSymlinksInPath().path + "/") })

        let movedAgain = fixture.root.appendingPathComponent("Ещё одно имя.veloedit")
        try FileManager.default.moveItem(at: moved, to: movedAgain)
        #expect(await model.flushAutosave())
        #expect(!FileManager.default.fileExists(atPath: moved.path))
        #expect(model.projectURL?.resolvingSymlinksInPath().path == movedAgain.resolvingSymlinksInPath().path)
        #expect(model.project?.assets.first?.originalURL.resolvingSymlinksInPath().path == movedAgain.appendingPathComponent("Media/Embedded.png").resolvingSymlinksInPath().path)
        let reopenedAgain = try ProjectStore(open: movedAgain)
        #expect(await reopenedAgain.manifest.name == "После Finder")
    }

    private func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<1_000 {
            try await Task.sleep(for: .milliseconds(20))
            if predicate() { return }
        }
        Issue.record("Import did not finish")
        throw CancellationError()
    }

    private struct Fixture {
        let root: URL
        let url: URL
        let suite = "VeloEdit.file-drop.\(UUID())"
        let model: AppModel

        @MainActor init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(suite).resolvingSymlinksInPath()
            url = root.appendingPathComponent("Original.veloedit")
            let store = try ProjectStore(createAt: url, name: "Drop test")
            model = AppModel(defaults: UserDefaults(suiteName: suite)!, startBackgroundServices: false,
                personalTasteStore: LocalPersonalTasteStore(url: root.appendingPathComponent("taste.json")))
            model.pipeline = VeloEditPipeline(store: store)
            model.projectURL = url
            model.project = ProjectManifest(name: "Drop test")
        }

        func photo(_ name: String, red: UInt8) throws -> URL {
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 24,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 128, bitsPerPixel: 32)!
            for i in 0..<(32 * 24) {
                bitmap.bitmapData![i * 4] = red
                bitmap.bitmapData![i * 4 + 1] = 60
                bitmap.bitmapData![i * 4 + 2] = 120
                bitmap.bitmapData![i * 4 + 3] = 255
            }
            let url = root.appendingPathComponent(name).appendingPathExtension("png")
            try bitmap.representation(using: .png, properties: [:])!.write(to: url)
            return url
        }

        func audio() throws -> URL {
            let url = root.appendingPathComponent("Tone.wav")
            let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100))
            buffer.frameLength = buffer.frameCapacity
            for i in 0..<Int(buffer.frameLength) { buffer.floatChannelData![0][i] = Float(sin(Double(i) * 0.04) * 0.1) }
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
            return url
        }

        func remove() {
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
    }
}
