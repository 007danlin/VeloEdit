import Foundation
import Testing
import AVFoundation
@testable import VeloEditCore

@Suite(.serialized)
struct EditorPerformanceTests {
    /// Set to a directory of disposable project copies. Original user projects
    /// must not be used: opening can migrate recovery state and cached media.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["VELOEDIT_PERFORMANCE_COPIES"] != nil))
    func largeProjectOpenPlaybackAndFirstFrame() async throws {
        let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["VELOEDIT_PERFORMANCE_COPIES"]))
        let projects = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "veloedit" }.sorted { $0.path < $1.path }
        #expect(!projects.isEmpty)
        for url in projects {
            let started = Date()
            let store = try await Task.detached(priority: .userInitiated) { try ProjectStore(open: url) }.value
            let openSeconds = Date().timeIntervalSince(started)
            let snapshot = await store.manifest
            let timeline = try #require(snapshot.timelines.last)
            let pipeline = VeloEditPipeline(store: store)
            let buildStart = Date()
            let playback = try await pipeline.makePlayback(interactiveQuality: .preview1080p)
            let buildSeconds = Date().timeIntervalSince(buildStart)
            let generator = AVAssetImageGenerator(asset: playback.composition)
            generator.videoComposition = playback.videoComposition
            generator.maximumSize = CGSize(width: 960, height: 540)
            let frameStart = Date()
            for time in [1.0, playback.duration * 0.5, max(1, playback.duration - 2)] {
                let frame = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image
                #expect(!FrameQualityInspector.assess(image: frame).isBlack)
            }
            let frameSeconds = Date().timeIntervalSince(frameStart)
            #expect(playback.skippedItemIDs.isEmpty)
            #expect(playback.renderedItemCount == timeline.items.count)
            #expect(openSeconds < 20)
            #expect(buildSeconds < 20)
            var edited = timeline
            let index = try #require(edited.items.firstIndex { $0.kind == .video })
            edited.items[index].timelineDuration -= 0.1
            edited.items[index].sourceDuration -= 0.1 * edited.items[index].speed
            edited.items = TimelineTiming.retimed(edited.items)
            let editStart = Date()
            let editedPlayback = try await pipeline.makePlayback(timeline: edited, projectSnapshot: snapshot, interactiveQuality: .preview1080p)
            let editSeconds = Date().timeIntervalSince(editStart)
            let editedGenerator = AVAssetImageGenerator(asset: editedPlayback.composition)
            editedGenerator.videoComposition = editedPlayback.videoComposition
            editedGenerator.maximumSize = CGSize(width: 960, height: 540)
            let editedFrame = try await editedGenerator.image(at: CMTime(seconds: 1, preferredTimescale: 600)).image
            let editFrameSeconds = Date().timeIntervalSince(editStart)
            #expect(!FrameQualityInspector.assess(image: editedFrame).isBlack)
            #expect(editedPlayback.skippedItemIDs.isEmpty)
            #expect(editedPlayback.duration < playback.duration)
            #expect(editSeconds < 3)
            print("PERF real-project=\(url.lastPathComponent) bytes=\(try Data(contentsOf: url.appendingPathComponent("project.json")).count) clips=\(timeline.items.count) open_ms=\(openSeconds * 1000) build_ms=\(buildSeconds * 1000) edit_preview_ms=\(editSeconds * 1000) edited_frame_total_ms=\(editFrameSeconds * 1000) three_frames_ms=\(frameSeconds * 1000) warnings=\(playback.warnings.count)")
        }
    }
}
