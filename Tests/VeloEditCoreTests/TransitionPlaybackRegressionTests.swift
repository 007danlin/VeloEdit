import Foundation
import AVFoundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import Testing
@testable import VeloEditCore

@Suite struct TransitionPlaybackRegressionTests {
    @Test func explicitDurationsDriveBothClocksIncludingDisabledAndCutObjects() {
        let clips = TimelineTiming.retimed((0..<4).map { _ in
            TimelineItem(kind: .video, sourceDuration: 4, timelineStart: 0, timelineDuration: 4,
                         transition: TransitionStyle.crossDissolve.rawValue)
        })
        let transitions = [
            TimelineTransitionItem(style: .lensBlur, outgoingClipID: clips[0].id, incomingClipID: clips[1].id, startTime: 4, duration: 1.2),
            TimelineTransitionItem(style: .crossDissolve, outgoingClipID: clips[1].id, incomingClipID: clips[2].id, startTime: 8, duration: 1.5, enabled: false),
            TimelineTransitionItem(style: .cut, outgoingClipID: clips[2].id, incomingClipID: clips[3].id, startTime: 12, duration: 1)
        ]
        let timeline = Timeline(storyPlanID: UUID(), items: clips, transitionItems: transitions)
        #expect(abs(TimelineTiming.playbackTime(forTimelineTime: 4, timeline: timeline) - 2.8) < 0.00001)
        #expect(abs(TimelineTiming.playbackTime(forTimelineTime: 8, timeline: timeline) - 6.8) < 0.00001)
        #expect(abs(TimelineTiming.playbackTime(forTimelineTime: 16, timeline: timeline) - 14.8) < 0.00001)
        #expect(TimelineTiming.resolvedTransitions(items: clips, transitionItems: transitions).count == 1)
        for time in stride(from: 0.0, through: 16, by: 0.037) {
            let playback = TimelineTiming.playbackTime(forTimelineTime: time, timeline: timeline)
            #expect(abs(TimelineTiming.timelineTime(forPlaybackTime: playback, timeline: timeline) - time) < 0.00001)
        }
    }

    @Test func shortClipsCannotReuseATrackBeforeThePreviousClipEnds() {
        let clips = TimelineTiming.retimed((0..<4).map { _ in
            TimelineItem(kind: .video, sourceDuration: 0.15, timelineStart: 0, timelineDuration: 0.15)
        })
        let transitions = clips.indices.dropFirst().map { index in
            TimelineTransitionItem(style: .whipLeft, outgoingClipID: clips[index - 1].id,
                                   incomingClipID: clips[index].id, startTime: clips[index].timelineStart, duration: 4)
        }
        let resolved = TimelineTiming.resolvedTransitions(items: clips, transitionItems: transitions)
        #expect(resolved.allSatisfy { abs($0.duration - 0.075) < 0.00001 })
        let timeline = Timeline(storyPlanID: UUID(), items: clips, transitionItems: transitions)
        #expect(abs(TimelineTiming.playbackTime(forTimelineTime: timeline.duration, timeline: timeline) - 0.375) < 0.00001)
        for index in 2..<clips.count {
            let previousEnd = TimelineTiming.playbackTime(forTimelineTime: clips[index - 2].timelineStart, timeline: timeline) + 0.15
            let start = TimelineTiming.playbackTime(forTimelineTime: clips[index].timelineStart, timeline: timeline)
            #expect(start + 0.00001 >= previousEnd)
        }
    }

    @Test func staleObjectsDoNotOverrideAnotherBoundaryAndLegacyCutHasNoOverlap() {
        let clips = TimelineTiming.retimed((0..<3).map { _ in
            TimelineItem(kind: .video, sourceDuration: 1, timelineStart: 0, timelineDuration: 1,
                         transition: TransitionStyle.cut.rawValue)
        })
        let stale = TimelineTransitionItem(style: .spin, outgoingClipID: clips[0].id,
                                           incomingClipID: clips[2].id, startTime: 2)
        #expect(TimelineTiming.resolvedTransitions(items: clips, transitionItems: [stale]).isEmpty)
        #expect(TimelineTiming.playbackTime(forTimelineTime: 3, items: clips, transitionItems: [stale]) == 3)
    }

    @Test func movingTransitionsDoNotDimTheIncomingPanel() throws {
        let bounds = CGRect(x: 0, y: 0, width: 160, height: 90)
        let red = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: bounds)
        let blue = CIImage(color: CIColor(red: 0, green: 0, blue: 1)).cropped(to: bounds)
        for style in [TransitionStyle.pushLeft, .pushRight, .pushUp, .pushDown, .whipLeft, .whipRight, .slideLeft, .slideRight] {
            let item = TimelineTransitionItem(style: style, outgoingClipID: UUID(), incomingClipID: UUID(), startTime: 0)
            for progress in [0.1, 0.5, 0.9] {
                let image = TransitionEffectRenderer.renderTransition(outgoing: red, incoming: blue, item: item, progress: progress, bounds: bounds)
                let pixel = try Self.average(image, bounds: bounds)
                #expect(pixel[3] > 0.98, "\(style) must cover the whole frame")
                #expect(pixel[0] + pixel[2] > 0.95, "\(style) must not fade the moving panel to black")
            }
        }
    }

    @Test func everyPresetUsesTheFullRendererInStablePreviewAndExport() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.remove() }
        for style in TransitionStyle.allCases where style != .cut {
            let timeline = fixture.timeline(style: style)
            for stable in [true, false] {
                let playback = try await PlaybackEngine().build(timeline: timeline, assets: fixture.assets,
                                                                forceVideoComposition: !stable, preferStableRealtimePreview: stable)
                #expect(playback.videoComposition?.customVideoCompositorClass != nil, "\(style), stable=\(stable)")
                #expect(abs(playback.duration - 3.2) < 0.00001)
                let instructions = try #require(playback.videoComposition?.instructions as? [VeloVideoInstruction])
                let transition = try #require(instructions.first { $0.transitionItem != nil }?.transitionItem)
                #expect(transition.style == style)
                #expect(transition.effectiveIntensity == 0.8)
                #expect(abs(transition.startTime - 1.2) < 0.00001)
                #expect(abs(transition.duration - 0.8) < 0.00001)
            }
        }
        var disabled = fixture.timeline(style: .spin)
        disabled.transitionItems?[0].enabled = false
        let cutPlayback = try await PlaybackEngine().build(timeline: disabled, assets: fixture.assets, preferStableRealtimePreview: true)
        #expect(abs(cutPlayback.duration - 4) < 0.00001)
        #expect(abs(TimelineTiming.playbackTime(forTimelineTime: 4, timeline: disabled) - cutPlayback.duration) < 0.00001)
    }

    @Test func overlayAndEffectBoundariesDoNotRestartOrDisableTheTransition() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.remove() }
        var timeline = fixture.timeline(style: .crossDissolve)
        // Editor 2.2...2.4 maps to playback 1.4...1.6 after the overlap.
        timeline.effects = [EffectTimelineItem(effectType: .vignette, startTime: 2.2, duration: 0.2)]
        let overlay = TimelineItem(assetID: fixture.assets[0].id, kind: .video, sourceDuration: 0.4,
                                   timelineStart: 2.3, timelineDuration: 0.4,
                                   overlay: OverlaySettings(style: .pictureInPicture, baseItemID: timeline.items[1].id, startOffset: 0.3))
        timeline.items.append(overlay)
        let playback = try await PlaybackEngine().build(timeline: timeline, assets: fixture.assets)
        let instructions = try #require(playback.videoComposition?.instructions as? [VeloVideoInstruction])
        let overlaps = instructions.filter { $0.transitionItem != nil }
        #expect(overlaps.count > 2)
        #expect(overlaps.contains { $0.layers.count == 3 })
        for instruction in overlaps {
            #expect(abs(instruction.transitionItem!.startTime - 1.2) < 0.00001)
            #expect(abs(instruction.transitionItem!.duration - 0.8) < 0.00001)
            #expect(abs(instruction.transitionProgress(at: CMTime(seconds: 1.6, preferredTimescale: 600)) - 0.5) < 0.00001)
        }
        let instruction = try #require(overlaps.first { $0.layers.count == 3 })
        let bounds = CGRect(x: 0, y: 0, width: 320, height: 180)
        let frames = [
            timeline.items[0].id: CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: bounds),
            timeline.items[1].id: CIImage(color: CIColor(red: 0, green: 0, blue: 1)).cropped(to: bounds),
            overlay.id: CIImage(color: CIColor(red: 0, green: 1, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: 40, height: 40))
        ]
        let result = instruction.compositeFrames(frames, at: CMTime(seconds: 1.6, preferredTimescale: 600))
        let primary = try Self.average(result, bounds: CGRect(x: 100, y: 100, width: 20, height: 20))
        let pip = try Self.average(result, bounds: CGRect(x: 5, y: 5, width: 20, height: 20))
        #expect(primary[0] > 0.3 && primary[2] > 0.3)
        #expect(pip[1] > 0.95 && pip[0] < 0.05 && pip[2] < 0.05)
    }

    @Test(arguments: [TransitionStyle.fadeThroughBlack, .glitch, .rgbSplit, .digitalDistortion, .shatter])
    func encodedTransitionMatchesPreviewFramesAndDuration(_ style: TransitionStyle) async throws {
        let fixture = try await Fixture.make()
        defer { fixture.remove() }
        let timeline = fixture.timeline(style: style)
        let playback = try await PlaybackEngine().build(timeline: timeline, assets: fixture.assets, preferStableRealtimePreview: true)
        let destination = fixture.root.appendingPathComponent("transition.mp4")
        let report = try await RenderEngine().render(timeline: timeline, assets: fixture.assets,
                                                    quality: .preview720p, destination: destination)
        #expect(report.skippedItemIDs.isEmpty)
        let encoded = AVURLAsset(url: destination)
        #expect(abs(try await encoded.load(.duration).seconds - playback.duration) <= 0.051)
        let preview = AVAssetImageGenerator(asset: playback.composition)
        preview.videoComposition = playback.videoComposition
        let exported = AVAssetImageGenerator(asset: encoded)
        for generator in [preview, exported] {
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            // Compare the entire frame in the same raster. 720p export is
            // larger than this fixture; a 320x180 crop only sees its corner.
            generator.maximumSize = CGSize(width: 320, height: 180)
        }
        let bounds = CGRect(x: 0, y: 0, width: 320, height: 180)
        for time in [0.5, 1.2, 1.4, 1.6, 1.8, 2.0, 2.7, 3.1] {
            let when = CMTime(seconds: time, preferredTimescale: 600)
            let live = try Self.average(CIImage(cgImage: preview.copyCGImage(at: when, actualTime: nil)), bounds: bounds)
            let movie = try Self.average(CIImage(cgImage: exported.copyCGImage(at: when, actualTime: nil)), bounds: bounds)
            for channel in 0..<3 { #expect(abs(live[channel] - movie[channel]) < 0.09, "at \(time)s") }
            if time == 1.6 && style == .fadeThroughBlack { #expect(movie.prefix(3).allSatisfy { $0 < 0.06 }) }
            if style != .fadeThroughBlack { #expect(movie[0] + movie[2] > 0.8, "\(style) must not generate a black frame") }
            if time == 0.5 { #expect(movie[0] > 0.8 && movie[2] < 0.1) }
            if time == 2.7 { #expect(movie[2] > 0.8 && movie[0] < 0.1) }
        }
        // Opt-in retention gives manual QA the exact encoded fixture tested.
        if style == .fadeThroughBlack, let output = ProcessInfo.processInfo.environment["VELOEDIT_TRANSITION_QA_OUTPUT"] {
            let target = URL(fileURLWithPath: output)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            for style in [TransitionStyle.fadeThroughBlack, .pushLeft, .lensBlur, .exposureFlash, .crossDissolve] {
                _ = try await RenderEngine().render(timeline: fixture.timeline(style: style), assets: fixture.assets,
                                                    quality: .preview720p, destination: target.appendingPathComponent("\(style.rawValue).mp4"))
            }
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["VELOEDIT_TRANSITION_REAL_SOURCE"] != nil))
    @MainActor func highResolutionCameraTransitionDeliversLivePlayerFrames() async throws {
        let url = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["VELOEDIT_TRANSITION_REAL_SOURCE"]))
        let source = AVURLAsset(url: url)
        let track = try #require(try await source.loadTracks(withMediaType: .video).first)
        let size = try await track.load(.naturalSize)
        let duration = try await source.load(.duration).seconds
        #expect(max(size.width, size.height) >= 3840)
        let asset = MediaAsset(originalURL: url, kind: .video, byteSize: 1, contentHash: "real-camera-transition",
                               metadata: MediaMetadata(duration: duration, width: Int(size.width), height: Int(size.height),
                                                       frameRate: Double(try await track.load(.nominalFrameRate)), hasAudio: false))
        let clips = TimelineTiming.retimed([0.0, min(10, max(0, duration - 2))].map { start in
            TimelineItem(assetID: asset.id, kind: .video, sourceStart: start, sourceDuration: 2,
                         timelineStart: 0, timelineDuration: 2)
        })
        let transition = TimelineTransitionItem(style: .pushLeft, outgoingClipID: clips[0].id, incomingClipID: clips[1].id,
                                                startTime: 2, duration: 0.8)
        let timeline = Timeline(storyPlanID: UUID(), width: 1280, height: 720, frameRate: 30, items: clips,
                                telemetryItems: [TimelineTelemetryItem(linkedAssetID: asset.id, timelineStart: 0, timelineDuration: 4,
                                                                       settings: TelemetryOverlaySettings(metrics: [.speed]))],
                                effects: [EffectTimelineItem(effectType: .saturation, startTime: 0, duration: 4)],
                                titleItems: [TitleTimelineItem(kind: .title, templateID: "title.cinematic.v1", text: "ПРОВЕРКА ПРЕВЬЮ", startTime: 0, duration: 4)],
                                transitionItems: [transition])
        let telemetry = [asset.id: TelemetrySummary(hasGPMF: true, sampleCount: 2, maxSpeedMetersPerSecond: 12,
                                                   speedSamplesMetersPerSecond: [8, 12],
                                                   timedSamples: [TelemetrySample(timestamp: 0, speedMetersPerSecond: 8),
                                                                  TelemetrySample(timestamp: duration, speedMetersPerSecond: 12)])]
        let playback = try await PlaybackEngine().build(timeline: timeline, assets: [asset], telemetry: telemetry, preferStableRealtimePreview: true)
        #expect(playback.videoComposition?.customVideoCompositorClass != nil)
        let playerItem = AVPlayerItem(asset: playback.composition)
        playerItem.videoComposition = playback.videoComposition
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        playerItem.add(output)
        let player = AVPlayer(playerItem: playerItem)
        player.isMuted = true
        defer { player.pause(); player.replaceCurrentItem(with: nil) }
        let readyDeadline = Date().addingTimeInterval(10)
        while playerItem.status == .unknown && Date() < readyDeadline {
            try await Task.sleep(for: .milliseconds(30))
        }
        #expect(playerItem.status == .readyToPlay, "\(String(describing: playerItem.error))")
        for seconds in [0.5, 1.6, 2.5] {
            await player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            player.play()
            var buffer: CVPixelBuffer?
            let deadline = Date().addingTimeInterval(5)
            while buffer == nil && Date() < deadline {
                try await Task.sleep(for: .milliseconds(20))
                let current = player.currentTime()
                guard output.hasNewPixelBuffer(forItemTime: current) else { continue }
                var displayed = CMTime.invalid
                let candidate = output.copyPixelBuffer(forItemTime: current, itemTimeForDisplay: &displayed)
                if displayed.isNumeric && abs(displayed.seconds - seconds) < 0.25 {
                    buffer = candidate
                }
            }
            player.pause()
            let frame = try #require(buffer, "Live AVPlayer must produce a frame at \(seconds)s")
            let image = CIImage(cvPixelBuffer: frame)
            let pixel = try Self.average(image, bounds: image.extent)
            #expect(pixel.prefix(3).reduce(0, +) > 0.06, "5K preview must not be black at \(seconds)s")
            if let folder = ProcessInfo.processInfo.environment["VELOEDIT_TRANSITION_QA_OUTPUT"] {
                let png = URL(fileURLWithPath: folder).appendingPathComponent("gopro-live-\(seconds).png")
                try CIContext().writePNGRepresentation(of: image, to: png, format: .RGBA8,
                                                      colorSpace: CGColorSpaceCreateDeviceRGB())
            }
        }
        if let folder = ProcessInfo.processInfo.environment["VELOEDIT_TRANSITION_QA_OUTPUT"] {
            _ = try await RenderEngine().render(timeline: timeline, assets: [asset], telemetry: telemetry, quality: .preview720p,
                                                destination: URL(fileURLWithPath: folder).appendingPathComponent("gopro-push-left.mp4"))
        }
    }

    @Test func fractionalClipDurationsUseOneCompositionClockWithoutAccumulatedDrift() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.remove() }
        // AVFoundation's seconds initializer truncates 0.156 * 600 to 93,
        // while the timeline clock used 94. Fifty-two clips lose 2.6 frames.
        for overlap in [false, true] {
            let items = TimelineTiming.retimed((0..<52).map { index in
                TimelineItem(assetID: fixture.assets[index % 2].id, kind: .video,
                             sourceDuration: 0.156, timelineStart: 0, timelineDuration: 0.156,
                             transition: overlap ? TransitionStyle.crossDissolve.rawValue : nil)
            })
            let timeline = Timeline(storyPlanID: UUID(), width: 320, height: 180, frameRate: 30, items: items)
            let playback = try await PlaybackEngine().build(timeline: timeline, assets: fixture.assets, forceVideoComposition: true)
            #expect(playback.skippedItemIDs.isEmpty)
            #expect(playback.renderedItemCount == items.count)
            #expect(abs(playback.duration - AutomaticFilmDurationPolicy.renderedDuration(of: timeline)) < 1 / 600.0,
                    "Composition \(playback.duration), expected \(AutomaticFilmDurationPolicy.renderedDuration(of: timeline))")
        }
    }

    private static func average(_ image: CIImage, bounds: CGRect) throws -> [Float] {
        let average = image.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: bounds)])
        var pixel = [Float](repeating: 0, count: 4)
        let context = CIContext(options: [.workingColorSpace: CGColorSpaceCreateDeviceRGB()])
        pixel.withUnsafeMutableBytes {
            context.render(average, toBitmap: $0.baseAddress!, rowBytes: 16,
                           bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf,
                           colorSpace: CGColorSpaceCreateDeviceRGB())
        }
        return pixel
    }

    private struct Fixture {
        let root: URL
        let assets: [MediaAsset]
        static func make() async throws -> Fixture {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("veloedit-transition-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            var assets: [MediaAsset] = []
            do {
                for (index, color) in [CIColor(red: 1, green: 0, blue: 0), CIColor(red: 0, green: 0, blue: 1)].enumerated() {
                    let bounds = CGRect(x: 0, y: 0, width: 320, height: 180)
                    let image = try #require(CIContext().createCGImage(CIImage(color: color), from: bounds))
                    let png = root.appendingPathComponent("\(index).png")
                    let writer = try #require(CGImageDestinationCreateWithURL(png as CFURL, UTType.png.identifier as CFString, 1, nil))
                    CGImageDestinationAddImage(writer, image, nil)
                    #expect(CGImageDestinationFinalize(writer))
                    let url = try await StillImageVideoGenerator().generate(imageURL: png, duration: 2, width: 320, height: 180,
                                                                           frameRate: 20, destination: root.appendingPathComponent("\(index).mov"),
                                                                           codec: .jpeg, motion: nil)
                    assets.append(MediaAsset(originalURL: url, kind: .video, byteSize: 1, contentHash: "color-\(index)",
                                             metadata: MediaMetadata(duration: 2, width: 320, height: 180, frameRate: 20, hasAudio: false)))
                }
                return Fixture(root: root, assets: assets)
            } catch {
                try? FileManager.default.removeItem(at: root)
                throw error
            }
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
        func timeline(style: TransitionStyle) -> Timeline {
            let clips = TimelineTiming.retimed(assets.map { asset in
                TimelineItem(assetID: asset.id, kind: .video, sourceDuration: 2, timelineStart: 0, timelineDuration: 2,
                             transition: style.rawValue)
            })
            let transition = TimelineTransitionItem(style: style, outgoingClipID: clips[0].id, incomingClipID: clips[1].id,
                                                    startTime: 2, duration: 0.8, intensity: 0.8)
            return Timeline(storyPlanID: UUID(), width: 320, height: 180, frameRate: 20, items: clips, transitionItems: [transition])
        }
    }
}
