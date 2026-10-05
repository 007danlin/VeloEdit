import Foundation
import AVFoundation
import AppKit
import ImageIO
import Combine
import Testing
import VeloEditCore
@testable import VeloEdit

@Suite(.serialized)
@MainActor
struct TimelineResponsivenessTests {
    @Test func backgroundThumbnailsPreserveOrientationAndShareDecodedImages() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("thumbnail-\(UUID()).jpg")
        defer { try? FileManager.default.removeItem(at: url) }
        let context = try #require(CGContext(data: nil, width: 30, height: 20, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 30, height: 20))
        let cgImage = try #require(context.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, cgImage, [kCGImagePropertyOrientation: 6] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        async let first = ThumbnailImageCache.shared.image(for: url)
        async let second = ThumbnailImageCache.shared.image(for: url)
        let images = await (first, second)
        let image = try #require(images.0)
        #expect(image === images.1)
        #expect(image.size == NSSize(width: 20, height: 30))
    }

    @Test func pausedVideoScrubbingDoesNotRepublishTheEditorAndLandsOnFinalFrame() async throws {
        let suite = "VeloEdit.scrub-video.\(UUID())"
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let source = try await TitleCardVideoGenerator().generate(text: "Seek", style: TitleStyle(),
            duration: 3, width: 320, height: 180, frameRate: 30,
            destination: root.appendingPathComponent("source.mov"), codec: .jpeg)
        let asset = MediaAsset(originalURL: source, kind: .video, byteSize: 1, contentHash: UUID().uuidString,
            metadata: MediaMetadata(duration: 3, width: 320, height: 180, frameRate: 30, hasAudio: false))
        let timeline = Timeline(storyPlanID: UUID(), width: 320, height: 180, items: [
            TimelineItem(assetID: asset.id, kind: .video, sourceDuration: 3, timelineStart: 0, timelineDuration: 3)
        ])
        let url = root.appendingPathComponent("test.veloedit")
        let store = try ProjectStore(createAt: url, name: "Seek test")
        try await store.update { $0.assets = [asset]; $0.timelines = [timeline] }
        let model = AppModel(defaults: UserDefaults(suiteName: suite)!, startBackgroundServices: false,
                             personalTasteStore: LocalPersonalTasteStore(url: root.appendingPathComponent("taste.json")))
        model.openRecentProject(url)
        try await waitUntil(timeout: 15) { model.isPreviewPosterVisible && model.previewPlayer?.currentItem?.status == .readyToPlay }
        model.previewPlayer?.pause()
        var publications = 0
        let subscription = model.objectWillChange.sink { publications += 1 }
        for frame in 1...75 { model.seekTimeline(to: Double(frame) / 30) }
        #expect(model.timelinePlayheadTime == 2.5)
        // Only hiding the previously visible poster may publish to the editor.
        #expect(publications <= 1)
        subscription.cancel()
        try await waitUntil(timeout: 8) {
            abs((model.previewPlayer?.currentTime().seconds ?? -1) - 2.5) < 0.001 && model.isPreviewPosterVisible
        }
        #expect(abs(model.timelinePlayheadTime - 2.5) < 0.001)
        await model.stopForApplicationTermination()
        #expect(await model.flushAutosave())
    }

    @Test func slowDecoderOnlyReceivesNewestPositionAndFinishesExactly() async throws {
        var requests: [TimelinePreviewSeeker.Request] = []
        var completions: [@MainActor () -> Void] = []
        let seeker = TimelinePreviewSeeker(cadence: 0, settleDelay: 0.01) { request, done in
            requests.append(request)
            completions.append(done)
        }
        defer { seeker.reset() }
        seeker.submit(time: 1, frameRate: 30)
        try await waitUntil { requests.count == 1 }
        for time in 2...1_000 { seeker.submit(time: Double(time), frameRate: 30) }
        try await Task.sleep(for: .milliseconds(40))
        #expect(requests.count == 1) // A deliberately blocked decoder.
        #expect(seeker.isSeeking)
        completions[0]()
        try await waitUntil { requests.count == 2 }
        #expect(requests[1] == .init(time: 1_000, frameRate: 30, exact: true))
        completions[1]()
        #expect(!seeker.isSeeking)
    }

    @Test func replacingPlayerRejectsOldCompletionAndQueuedSeeks() async throws {
        var requests: [TimelinePreviewSeeker.Request] = []
        var completions: [@MainActor () -> Void] = []
        let seeker = TimelinePreviewSeeker(cadence: 0, settleDelay: 0.01) { request, done in
            requests.append(request)
            completions.append(done)
        }
        defer { seeker.reset() }
        seeker.submit(time: 10, frameRate: 30)
        try await waitUntil { requests.count == 1 }
        seeker.submit(time: 20, frameRate: 30)
        seeker.reset()
        seeker.submit(time: 30, frameRate: 30)
        try await waitUntil { requests.count == 2 }
        completions[0]()
        try await Task.sleep(for: .milliseconds(40))
        #expect(requests.count == 2)
        completions[1]()
        try await waitUntil { requests.count == 3 }
        #expect(requests.map(\.time) == [10, 30, 30])
        #expect(requests.last?.exact == true)
        completions[2]()
        #expect(!seeker.isSeeking)
    }

    @Test func longTimelinePointerUpdatesStayLocalAndInvalidateTimingAfterEdit() throws {
        let suite = "VeloEdit.responsiveness.\(UUID())"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let model = AppModel(defaults: UserDefaults(suiteName: suite)!, startBackgroundServices: false)
        var manifest = ProjectManifest(name: "Pointer performance")
        manifest.timelines = [makeTimeline(count: 1_000)]
        model.project = manifest
        model.seekTimeline(to: 1) // Prepare the immutable clock map once.
        var publications = 0
        let subscription = model.objectWillChange.sink { publications += 1 }
        var samples: [Double] = []
        for index in 0..<2_000 {
            let time = Double((index * 17) % 9_999)
            let start = ProcessInfo.processInfo.systemUptime
            model.seekTimeline(to: time)
            samples.append((ProcessInfo.processInfo.systemUptime - start) * 1_000)
            #expect(model.timelinePlayheadTime == time)
        }
        withExtendedLifetime(subscription) { #expect(publications == 0) }
        samples.sort()
        let p95 = samples[Int(Double(samples.count) * 0.95)]
        #expect(p95 < 16.7)
        print("PERF pointer clips=1000 samples=2000 p95_ms=\(p95) max_ms=\(samples.last!)")
        model.project?.timelines[0].items = Array(manifest.timelines[0].items.prefix(1))
        model.seekTimeline(to: 100)
        #expect(model.timelinePlayheadTime == 10)
        model.seekTimeline(to: .nan)
        #expect(model.timelinePlayheadTime == 10)
    }

    @Test func layoutPreservesCutGapsSnappingAndOverlappingLanes() {
        var timeline = makeTimeline(count: 3)
        let first = TimelineAudioClip(title: "A", role: .detached, sourceDuration: 4, timelineStart: 1, timelineDuration: 4)
        let overlap = TimelineAudioClip(title: "B", role: .detached, sourceDuration: 4, timelineStart: 2, timelineDuration: 4)
        let following = TimelineAudioClip(title: "C", role: .detached, sourceDuration: 4, timelineStart: 5, timelineDuration: 4)
        timeline.audioClips = [first, overlap, following]
        let layout = TimelineLayoutSnapshot(timeline: timeline)
        #expect(layout.audioLaneCount == 2)
        #expect(layout.audioLaneAssignments[first.id] == layout.audioLaneAssignments[following.id])
        #expect(layout.audioLaneAssignments[first.id] != layout.audioLaneAssignments[overlap.id])
        let geometry = layout.geometry
        #expect(geometry.xPosition(for: 10, pointsPerSecond: 18, spacing: 8) == 184)
        #expect(geometry.time(at: 184, pointsPerSecond: 18, spacing: 8) == 10)
        #expect(geometry.time(at: 0, pointsPerSecond: 18, spacing: 8) == 0)
        #expect(geometry.time(at: 10_000, pointsPerSecond: 18, spacing: 8) == 30)
        for time in stride(from: 0.0, through: 30.0, by: 0.25) {
            let x = geometry.xPosition(for: time, pointsPerSecond: 18, spacing: 8)
            #expect(abs((geometry.time(at: x, pointsPerSecond: 18, spacing: 8) ?? -1) - time) < 0.00001)
        }
        // Scrubbing must not stick to its own previous playhead position.
        #expect(geometry.snapped(7.1, threshold: 0.4, frameRate: 30, playhead: nil) == 7.1)
        #expect(geometry.snapped(7.1, threshold: 0.4, frameRate: 30, playhead: 7) == 7)
        #expect(geometry.snapped(9.9, threshold: 0.4, frameRate: 30, playhead: nil) == 10)
    }

    private func makeTimeline(count: Int) -> Timeline {
        Timeline(storyPlanID: UUID(), items: (0..<count).map {
            TimelineItem(kind: .video, sourceDuration: 10, timelineStart: Double($0) * 10, timelineDuration: 10)
        })
    }

    private func waitUntil(timeout: Double = 2, _ predicate: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while !predicate() {
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                Issue.record("Decoder scheduling did not complete")
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(1))
        }
    }
}
