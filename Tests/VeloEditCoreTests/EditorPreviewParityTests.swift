import Foundation
import AVFoundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import Testing
@testable import VeloEditCore

@Suite(.serialized) struct EditorPreviewParityTests {
    @Test func viewerColorFiltersStabilizationAndSlowMotionReachPreviewAndExport() async throws {
        let fixture = try await Fixture.make(duration: 1); defer { fixture.remove() }
        let settings: [(String, VideoAdjustments)] = [
            ("brightness", .init(brightness: 0.2)), ("temperature", .init(warmth: 0.8)),
            ("tint", .init(tint: 0.6)), ("exposure", .init(exposure: 1)),
            ("contrast", .init(contrast: 1.5)), ("saturation", .init(saturation: 0)),
            ("highlights", .init(highlights: -0.8)), ("shadows", .init(shadows: 0.8)),
            ("stabilization", .init(stabilization: 0.8)),
            ("rolling-shutter", .init(rollingShutterCorrection: true)),
            ("smooth-slow-motion", .init(smoothSlowMotion: true))
        ] + VideoFilter.allCases.filter { $0 != .none }.map { ($0.rawValue, .init(filter: $0)) }
        var timeline = fixture.timeline
        timeline.items = [TimelineItem(assetID: fixture.asset.id, kind: .video, sourceDuration: 0.5,
                                       timelineStart: 0, timelineDuration: 0.5)]
        for (index, setting) in settings.enumerated() {
            let slow = setting.0 == "smooth-slow-motion"
            timeline.items.append(TimelineItem(assetID: fixture.asset.id, kind: .video,
                sourceDuration: slow ? 0.25 : 0.5, timelineStart: Double(index + 1) * 0.5,
                timelineDuration: 0.5, speed: slow ? 0.5 : 1, videoAdjustments: setting.1))
        }
        let playback = try await PlaybackEngine().build(timeline: timeline, assets: [fixture.asset], preferStableRealtimePreview: true)
        let live = Self.generator(playback)
        let baseline = try Self.pixels(live, at: 0.25)
        let destination = fixture.root.appendingPathComponent("viewer-adjustments.mp4")
        let report = try await RenderEngine().render(timeline: timeline, assets: [fixture.asset], quality: .maximum, destination: destination)
        #expect(report.skippedItemIDs.isEmpty)
        let encoded = AVURLAsset(url: destination)
        #expect(abs(try await encoded.load(.duration).seconds - timeline.duration) < 0.051)
        let movie = Self.generator(asset: encoded)
        for (index, setting) in settings.enumerated() {
            let start = Double(index + 1) * 0.5
            // Supply the registration reference before sampling stabilization.
            _ = try Self.pixels(live, at: start + 0.05)
            let preview = try Self.pixels(live, at: start + 0.3)
            let exported = try Self.pixels(movie, at: start + 0.3)
            #expect(Self.difference(preview, baseline) > 0.0005, "\(setting.0) must change actual preview pixels")
            #expect(Self.difference(preview, exported) < 0.04, "\(setting.0) must match the encoded film")
            if setting.0 == "stabilization" || setting.0 == "rolling-shutter" {
                let freshSeek = try Self.pixels(Self.generator(playback), at: start + 0.3)
                #expect(Self.difference(preview, freshSeek) < 0.001,
                        "Seeking directly into \(setting.0) must use the same source anchor")
            }
        }
    }

    @Test func speechCaptionUsesAudioClockAfterTwoTransitionsInPreviewAndMP4() async throws {
        let fixture = try await Fixture.make(duration: 6); defer { fixture.remove() }
        var timeline = fixture.timeline
        timeline.items = TimelineTiming.retimed((0..<3).map { index in
            TimelineItem(assetID: fixture.asset.id, kind: .video, sourceStart: Double(index * 2), sourceDuration: 2, timelineStart: 0, timelineDuration: 2)
        })
        timeline.transitionItems = (1..<3).map { index in
            TimelineTransitionItem(style: .crossDissolve, outgoingClipID: timeline.items[index - 1].id,
                incomingClipID: timeline.items[index].id, startTime: Double(index * 2), duration: 0.8)
        }
        let phrase = TranscriptSentence(text: "Проверка речи", startTime: 4.2, endTime: 4.8, confidence: 1)
        let speech = SpeechTranscript(localeIdentifier: "ru", words: [], sentences: [phrase], confidence: 1)
        timeline = SpeechSubtitleBuilder.applying(to: timeline, records: [.init(assetID: fixture.asset.id, transcript: speech)], enabled: true, allowMuted: true)
        let title = try #require(timeline.effectiveTitleItems.first)
        let clip = timeline.items[2]
        let range = try #require(SpeechTimeMap.playbackRange(anchor: title.speechAnchor!, item: clip, timeline: timeline))
        let time = (range.lowerBound + range.upperBound) / 2
        let playback = try await PlaybackEngine().build(timeline: timeline, assets: [fixture.asset], forceVideoComposition: true)
        let preview = try Self.pixels(Self.generator(playback), at: time)
        var clean = timeline; clean.titleItems = []
        let baseline = try Self.pixels(Self.generator(try await PlaybackEngine().build(timeline: clean, assets: [fixture.asset], forceVideoComposition: true)), at: time)
        #expect(Self.difference(preview, baseline) > 0.0002)
        let destination = fixture.root.appendingPathComponent("speech-clock.mp4")
        _ = try await RenderEngine().render(timeline: timeline, assets: [fixture.asset], quality: .maximum, destination: destination)
        let exported = try Self.pixels(Self.generator(asset: AVURLAsset(url: destination)), at: time)
        #expect(Self.difference(preview, exported) < 0.04)
        let before = max(0, range.lowerBound - 0.1)
        let beforeCaption = try Self.pixels(Self.generator(playback), at: before)
        let beforeClean = try Self.pixels(Self.generator(try await PlaybackEngine().build(timeline: clean, assets: [fixture.asset], forceVideoComposition: true)), at: before)
        #expect(Self.difference(beforeCaption, beforeClean) < 0.002)
    }

    @Test func everyTitleTemplateAndInspectorEditMatchesEncodedFilm() async throws {
        var samples = TitleTemplateRegistry.all.map { template -> TitleTimelineItem in
            var item = template.previewItem()
            item.text = "ЛЕТО"
            item.animation = TitleAnimation(entrance: .none, exit: .none)
            return item
        }
        let base = try #require(samples.first { $0.templateID == "title.modern.v1" })
        for variant in 0..<6 {
            var title = base
            title.id = UUID()
            switch variant {
            case 0: title.style.fontSize *= 0.65
            case 1: title.style.textColorHex = "#FF00CC"
            case 2: title.style.opacity = 0.4
            case 3: title.style.opacity = 0
            case 4: title.text = "ЗИМА"; title.additionalText = "НОВЫЙ ТЕКСТ"
            default: title.text = "ЛЕТО\nУ МОРЯ"; title.style.fontSize = 84
            }
            samples.append(title)
        }
        for index in samples.indices {
            samples[index].startTime = Double(index + 1)
            samples[index].duration = 1
        }
        let fixture = try await Fixture.make(duration: Double(samples.count + 2))
        defer { fixture.remove() }
        var timeline = fixture.timeline
        timeline.titleItems = samples
        // Reopen persisted project data before building the actual AVPlayer
        // composition, just as a film exported after an editor restart does.
        timeline = try JSONDecoder.veloEdit.decode(Timeline.self, from: JSONEncoder.veloEdit.encode(timeline))
        let playback = try await PlaybackEngine().build(timeline: timeline, assets: [fixture.asset], preferStableRealtimePreview: true)
        let live = Self.generator(playback)
        let baseline = try Self.pixels(live, at: 0.5)
        let destination = fixture.root.appendingPathComponent("titles.mp4")
        let report = try await RenderEngine().render(timeline: timeline, assets: [fixture.asset], quality: .maximum, destination: destination)
        #expect(report.skippedItemIDs.isEmpty)
        let movie = Self.generator(asset: AVURLAsset(url: destination))
        let encodedBaseline = try Self.pixels(movie, at: 0.5)
        var previewFrames: [[UInt8]] = []
        var rows = ["template,opacity,preview_change,export_error"]
        for title in samples {
            let time = title.startTime + 0.5
            let preview = try Self.pixels(live, at: time)
            let exported = try Self.pixels(movie, at: time)
            let change = Self.difference(preview, baseline)
            let error = Self.difference(preview, exported)
            previewFrames.append(preview)
            if title.style.effectiveOpacity == 0 {
                #expect(change < 0.002, "A hidden title must leave the original video untouched")
            } else {
                #expect(change > 0.0002, "\(title.effectiveTemplateID ?? ""): title must appear in the film")
                // Check the actual title pixels too: a small date/lower third
                // must not disappear unnoticed in a whole-frame average.
                let changedPixels = stride(from: 0, to: preview.count, by: 4).filter { pixel in
                    (0..<3).contains { abs(Int(preview[pixel + $0]) - Int(baseline[pixel + $0])) > 16 }
                }
                try #require(!changedPixels.isEmpty)
                func titleDifference(_ lhs: [UInt8], _ rhs: [UInt8]) -> Double {
                    let total = changedPixels.reduce(0) { sum, pixel in
                        sum + (0..<3).reduce(0) { $0 + abs(Int(lhs[pixel + $1]) - Int(rhs[pixel + $1])) }
                    }
                    return Double(total) / Double(changedPixels.count * 3 * 255)
                }
                #expect(titleDifference(exported, encodedBaseline) > titleDifference(preview, baseline) * 0.6,
                        "\(title.effectiveTemplateID ?? ""): encoded title must retain the visible text/artwork")
                #expect(titleDifference(preview, exported) < 0.08)
            }
            #expect(error < 0.04, "\(title.effectiveTemplateID ?? ""): MP4 differs from preview by \(error)")
            rows.append("\(title.effectiveTemplateID ?? ""),\(title.style.effectiveOpacity),\(change),\(error)")
        }
        let baseIndex = try #require(samples.firstIndex { $0.templateID == base.templateID })
        for index in TitleTemplateRegistry.all.count..<samples.count {
            #expect(Self.difference(previewFrames[baseIndex], previewFrames[index]) > 0.0002,
                    "Inspector change \(index) must update the actual paused composition")
        }
        if let path = ProcessInfo.processInfo.environment["VELOEDIT_TITLE_PARITY_QA_DIR"] {
            let folder = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let output = folder.appendingPathComponent("titles.mp4")
            try? FileManager.default.removeItem(at: output)
            try FileManager.default.copyItem(at: destination, to: output)
            try rows.joined(separator: "\n").write(to: folder.appendingPathComponent("title-frame-checks.csv"), atomically: true, encoding: .utf8)
            for (label, generator) in [("preview", live), ("export", movie)] {
                let frame = try generator.copyCGImage(at: CMTime(seconds: samples[baseIndex].startTime + 0.5, preferredTimescale: 600), actualTime: nil)
                let writer = try #require(CGImageDestinationCreateWithURL(folder.appendingPathComponent("\(label).png") as CFURL, UTType.png.identifier as CFString, 1, nil))
                CGImageDestinationAddImage(writer, frame, nil)
                #expect(CGImageDestinationFinalize(writer))
            }
        }
    }

    /// Exercise the real composition and encoded movie, not library thumbnails.
    @Test func everyEffectAndStackChangesPreviewAndSurvivesVideoExport() async throws {
        let types = TimelineEffectType.allCases
        let presets = EffectStackPresetRegistry.all
        let duration = Double(types.count + presets.count + 1) * 0.5
        let fixture = try await Fixture.make(duration: duration)
        defer { fixture.remove() }
        var timeline = fixture.timeline
        var samples: [(name: String, time: Double)] = []
        timeline.effects = types.enumerated().map { index, type in
            let start = Double(index + 1) * 0.5
            samples.append((type.rawValue, start + 0.2))
            return EffectTimelineItem(effectType: type, startTime: start, duration: 0.5,
                                      parameters: EffectPresetRegistry.preset(for: type).defaultParameters)
        }
        for (index, preset) in presets.enumerated() {
            let start = Double(types.count + index + 1) * 0.5
            _ = EffectStackPresetRegistry.apply(preset, to: &timeline, targetClipID: nil,
                                                startTime: start, duration: 0.5, explanation: "Parity regression")
            samples.append(("stack-" + preset.id, start + 0.2))
        }
        let preview = try await PlaybackEngine().build(timeline: timeline, assets: [fixture.asset], preferStableRealtimePreview: true)
        #expect(preview.videoComposition?.customVideoCompositorClass != nil)
        let live = Self.generator(preview)
        let baseline = try Self.pixels(live, at: 0.2)
        let destination = fixture.root.appendingPathComponent("all-effects.mp4")
        let report = try await RenderEngine().render(timeline: timeline, assets: [fixture.asset], quality: .maximum, destination: destination)
        #expect(report.skippedItemIDs.isEmpty)
        let encoded = AVURLAsset(url: destination)
        #expect(abs(try await encoded.load(.duration).seconds - preview.duration) < 0.051)
        let movie = Self.generator(asset: encoded)
        var rows = ["effect,preview_change,export_error"]
        for sample in samples {
            let livePixels = try Self.pixels(live, at: sample.time)
            let moviePixels = try Self.pixels(movie, at: sample.time)
            let change = Self.difference(livePixels, baseline)
            let error = Self.difference(livePixels, moviePixels)
            #expect(change > 0.0002, "\(sample.name) must visibly change the actual timeline frame (difference \(change))")
            #expect(error < 0.055, "\(sample.name): encoded frame must match preview (error \(error))")
            rows.append("\(sample.name),\(change),\(error)")
        }
        if let path = ProcessInfo.processInfo.environment["VELOEDIT_EFFECT_QA_OUTPUT"] {
            let folder = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let output = folder.appendingPathComponent("all-effects.mp4")
            try? FileManager.default.removeItem(at: output)
            try FileManager.default.copyItem(at: destination, to: output)
            try rows.joined(separator: "\n").write(to: folder.appendingPathComponent("effect-frame-checks.csv"), atomically: true, encoding: .utf8)
        }
    }

    @Test func editsBypassParametersAndKeyframesChangePausedCompositionFrames() async throws {
        let fixture = try await Fixture.make(duration: 2)
        defer { fixture.remove() }
        let baseline = try Self.pixels(Self.generator(try await PlaybackEngine().build(timeline: fixture.timeline, assets: [fixture.asset])), at: 0.6)
        var timeline = fixture.timeline
        var effect = EffectTimelineItem(effectType: .brightness, startTime: 0, duration: 2, intensity: 0.8)
        timeline.effects = [effect]
        let enabled = try Self.pixels(Self.generator(try await PlaybackEngine().build(timeline: timeline, assets: [fixture.asset], preferStableRealtimePreview: true)), at: 0.6)
        #expect(Self.difference(enabled, baseline) > 0.08)
        effect.enabled = false
        timeline.effects = [effect]
        let bypassed = try Self.pixels(Self.generator(try await PlaybackEngine().build(timeline: timeline, assets: [fixture.asset], preferStableRealtimePreview: true)), at: 0.6)
        #expect(Self.difference(bypassed, baseline) < 0.002)
        effect.enabled = true
        effect.keyframes = [EffectKeyframe(parameter: "intensity", time: 0, value: 0, easing: .linear),
                            EffectKeyframe(parameter: "intensity", time: 2, value: 1, easing: .linear)]
        timeline.effects = [effect]
        let animated = Self.generator(try await PlaybackEngine().build(timeline: timeline, assets: [fixture.asset], preferStableRealtimePreview: true))
        #expect(Self.difference(try Self.pixels(animated, at: 1.6), baseline) > Self.difference(try Self.pixels(animated, at: 0.2), baseline) + 0.08)
        timeline.effects = [EffectTimelineItem(effectType: .posterize, startTime: 0, duration: 2, parameters: [EffectParameter(name: "levels", value: 2)])]
        let coarse = try Self.pixels(Self.generator(try await PlaybackEngine().build(timeline: timeline, assets: [fixture.asset], preferStableRealtimePreview: true)), at: 0.6)
        timeline.effects?[0].parameters = [EffectParameter(name: "levels", value: 12)]
        let fine = try Self.pixels(Self.generator(try await PlaybackEngine().build(timeline: timeline, assets: [fixture.asset], preferStableRealtimePreview: true)), at: 0.6)
        #expect(Self.difference(coarse, fine) > 0.02)
    }

    @Test func titlesTelemetryAndEffectsKeepEditorTimeAfterMultipleTransitions() async throws {
        let fixture = try await Fixture.make(duration: 6)
        defer { fixture.remove() }
        var timeline = fixture.timeline
        timeline.items = TimelineTiming.retimed((0..<3).map { _ in
            TimelineItem(assetID: fixture.asset.id, kind: .video, sourceDuration: 2, timelineStart: 0, timelineDuration: 2)
        })
        timeline.transitionItems = (1..<3).map { index in
            TimelineTransitionItem(style: .crossDissolve, outgoingClipID: timeline.items[index - 1].id,
                                   incomingClipID: timeline.items[index].id, startTime: Double(index * 2), duration: 0.8)
        }
        let effect = EffectTimelineItem(effectType: .brightness, startTime: 4.2, duration: 1, intensity: 0.8,
                                        keyframes: [EffectKeyframe(parameter: "intensity", time: 0, value: 0, easing: .linear),
                                                    EffectKeyframe(parameter: "intensity", time: 1, value: 1, easing: .linear)])
        let title = TitleTimelineItem(kind: .title, templateID: "title.cinematic.v1", text: "ФИНИШ", startTime: 4.2, duration: 1)
        let telemetry = TimelineTelemetryItem(linkedAssetID: fixture.asset.id, timelineStart: 4.2, timelineDuration: 1,
                                              settings: TelemetryOverlaySettings(metrics: [.speed], scale: 0.5))
        let summary = TelemetrySummary(hasGPMF: true, sampleCount: 2, maxSpeedMetersPerSecond: 12,
                                       speedSamplesMetersPerSecond: [10, 12],
                                       timedSamples: [TelemetrySample(timestamp: 0, speedMetersPerSecond: 10),
                                                      TelemetrySample(timestamp: 6, speedMetersPerSecond: 12)])
        timeline.effects = [effect]
        timeline.titleItems = [title]
        timeline.telemetryItems = [telemetry]
        for stable in [true, false] {
            let playback = try await PlaybackEngine().build(timeline: timeline, assets: [fixture.asset],
                                                            telemetry: [fixture.asset.id: summary], preferStableRealtimePreview: stable)
            let instructions = try #require(playback.videoComposition?.instructions as? [VeloVideoInstruction])
            let when = CMTime(seconds: TimelineTiming.playbackTime(forTimelineTime: 4.7, timeline: timeline), preferredTimescale: 600)
            let instruction = try #require(instructions.first { $0.timeRange.containsTime(when) })
            #expect(abs(instruction.timelineTime(at: when) - 4.7) < 0.003)
            #expect(instruction.effects.map(\.id) == [effect.id])
            #expect(instruction.titles.map(\.id) == [title.id])
            #expect(instruction.telemetryLayers.map(\.item.id) == [telemetry.id])
            #expect(abs(instruction.effects[0].parameterValue("intensity", at: instruction.timelineTime(at: when)) - 0.5) < 0.003)
            let decorated = try Self.pixels(Self.generator(playback), at: when.seconds)
            var plain = timeline
            plain.effects = []; plain.titleItems = []; plain.telemetryItems = []
            let clean = try Self.pixels(Self.generator(try await PlaybackEngine().build(timeline: plain, assets: [fixture.asset])), at: when.seconds)
            #expect(Self.difference(decorated, clean) > 0.04)
        }
    }

    @Test func allAudioEffectsAndEqualizersProcessMonoVoiceWithoutCrashingOrChangingDuration() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("veloedit-audio-parity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("mono.caf")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let input = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_800))
        input.frameLength = 4_800
        for index in 0..<4_800 {
            input.floatChannelData![0][index] = Float(sin(Double(index) * 440 * 2 * .pi / 16_000)) * 0.1
        }
        try AVAudioFile(forWriting: source, settings: format.settings).write(from: input)
        let settings = AudioEffect.allCases.map { AudioAdjustments(effect: $0) }
            + AudioEQPreset.allCases.map { AudioAdjustments(eqPreset: $0) }
            + [AudioAdjustments(noiseReduction: 0.6), AudioAdjustments(normalize: true)]
        for (index, adjustments) in settings.enumerated() {
            let output = try await ProcessedAudioGenerator().generate(sourceURL: source, sourceStart: 0, sourceDuration: 0.3,
                                                                      adjustments: adjustments, destination: root.appendingPathComponent("processed-\(index).caf"))
            let file = try AVAudioFile(forReading: output)
            #expect(abs(Double(file.length) / file.processingFormat.sampleRate - 0.3) < 0.045)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
            try file.read(into: buffer)
            let samples = UnsafeBufferPointer(start: try #require(buffer.floatChannelData)[0], count: Int(buffer.frameLength))
            #expect(samples.allSatisfy { $0.isFinite })
            let rms = sqrt(samples.reduce(0.0) { $0 + Double($1 * $1) } / Double(samples.count))
            #expect(rms > 0.003, "Audio configuration \(index) must preserve audible content")
        }
    }

    @Test func replacingPlaybackCannotDeleteNewPhotoTitleOrProcessedAudioSources() async throws {
        let fixture = try await Fixture.make(duration: 1)
        defer { fixture.remove() }
        let audioURL = fixture.root.appendingPathComponent("voice.caf")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000))
        buffer.frameLength = 16_000
        for index in 0..<16_000 { buffer.floatChannelData![0][index] = Float(sin(Double(index) * 440 * 2 * .pi / 16_000)) * 0.1 }
        try AVAudioFile(forWriting: audioURL, settings: format.settings).write(from: buffer)
        let audio = LocalMusicTrack(title: "Голос", author: "Test", bpm: 120, genres: [], moods: [], energy: 0.2, duration: 1,
                                    license: MusicLicenseRecord(name: "Test fixture", url: audioURL), sourceProvider: .user,
                                    sourcePageURL: audioURL, localFileURL: audioURL, originalFileName: "voice.caf")
        let photo = MediaAsset(originalURL: fixture.root.appendingPathComponent("pattern.png"), kind: .photo, byteSize: 1,
                               contentHash: "photo", metadata: MediaMetadata(width: 320, height: 180))
        let title = TimelineItem(kind: .title, sourceDuration: 1, timelineStart: 2, timelineDuration: 1, title: "ТИТР")
        var timeline = fixture.timeline
        timeline.items += [TimelineItem(assetID: photo.id, kind: .photo, sourceDuration: 1, timelineStart: 1, timelineDuration: 1), title]
        timeline.audioClips = [TimelineAudioClip(trackID: audio.id, title: "Голос", role: .dialogue, sourceDuration: 1,
                                                 timelineStart: 0, timelineDuration: 1, adjustments: AudioAdjustments(eqPreset: .voice))]
        let assets = [fixture.asset, photo]
        var previous: TimelinePlayback? = try await PlaybackEngine().build(timeline: timeline, assets: assets, musicTracks: [audio])
        let oldURLs = Set(try #require(previous).composition.tracks.flatMap { $0.segments.compactMap(\.sourceURL) })
        let current = try await PlaybackEngine().build(timeline: timeline, assets: assets, musicTracks: [audio])
        let currentURLs = Set(current.composition.tracks.flatMap { $0.segments.compactMap(\.sourceURL) })
        let generatedURLs = currentURLs.subtracting([fixture.asset.originalURL])
        #expect(generatedURLs.count == 3)
        #expect(generatedURLs.isDisjoint(with: oldURLs))
        previous = nil
        #expect(currentURLs.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        let generator = Self.generator(current)
        for time in [0.5, 1.5, 2.5] { _ = try Self.pixels(generator, at: time) }
    }

    @Test(arguments: [false, true]) @MainActor
    func pausedPlayerReplacementImmediatelyShowsTheEditedFrame(_ editsTitle: Bool) async throws {
        let fixture = try await Fixture.make(duration: 2)
        defer { fixture.remove() }
        let player = AVPlayer()
        player.isMuted = true
        defer { player.pause(); player.replaceCurrentItem(with: nil) }
        var frames: [[UInt8]] = []
        for intensity in [0.0, 0.8, 0.0] {
            var timeline = fixture.timeline
            if editsTitle {
                var title = try #require(TitleTemplateRegistry.template(id: "title.bold.v1")).previewItem()
                title.duration = 2
                title.animation = TitleAnimation(entrance: .none, exit: .none)
                title.style.opacity = intensity
                timeline.titleItems = [title]
            } else {
                timeline.effects = [EffectTimelineItem(effectType: .brightness, startTime: 0, duration: 2, intensity: intensity)]
            }
            let playback = try await PlaybackEngine().build(timeline: timeline, assets: [fixture.asset], preferStableRealtimePreview: true)
            let item = AVPlayerItem(asset: playback.composition)
            item.videoComposition = playback.videoComposition
            let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            item.add(output)
            player.replaceCurrentItem(with: item)
            let readyDeadline = Date().addingTimeInterval(8)
            while item.status == .unknown && Date() < readyDeadline { try await Task.sleep(for: .milliseconds(20)) }
            #expect(item.status == .readyToPlay, "\(String(describing: item.error))")
            let when = CMTime(seconds: 0.6, preferredTimescale: 600)
            await player.seek(to: when, toleranceBefore: .zero, toleranceAfter: .zero)
            var buffer: CVPixelBuffer?
            let deadline = Date().addingTimeInterval(5)
            while buffer == nil && Date() < deadline {
                buffer = output.copyPixelBuffer(forItemTime: when, itemTimeForDisplay: nil)
                if buffer == nil { try await Task.sleep(for: .milliseconds(20)) }
            }
            #expect(player.rate == 0)
            let frame = CIImage(cvPixelBuffer: try #require(buffer, "Paused AVPlayer must produce the replacement frame without pressing Play"))
            frames.append(try Self.pixels(try #require(CIContext().createCGImage(frame, from: frame.extent))))
            withExtendedLifetime(playback) {}
        }
        #expect(Self.difference(frames[0], frames[1]) > (editsTitle ? 0.005 : 0.08))
        #expect(Self.difference(frames[0], frames[2]) < 0.002)
    }

    private static func generator(_ playback: TimelinePlayback) -> AVAssetImageGenerator {
        let result = generator(asset: playback.composition)
        result.videoComposition = playback.videoComposition
        return result
    }

    private static func generator(asset: AVAsset) -> AVAssetImageGenerator {
        let result = AVAssetImageGenerator(asset: asset)
        result.appliesPreferredTrackTransform = true
        result.requestedTimeToleranceBefore = .zero
        result.requestedTimeToleranceAfter = .zero
        return result
    }

    private static func pixels(_ generator: AVAssetImageGenerator, at seconds: Double) throws -> [UInt8] {
        let image = try generator.copyCGImage(at: CMTime(seconds: seconds, preferredTimescale: 600), actualTime: nil)
        return try pixels(image)
    }

    private static func pixels(_ image: CGImage) throws -> [UInt8] {
        let context = try #require(CGContext(data: nil, width: 160, height: 90, bitsPerComponent: 8, bytesPerRow: 640,
                                           space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: 160, height: 90))
        return Array(UnsafeBufferPointer(start: try #require(context.data).assumingMemoryBound(to: UInt8.self), count: 160 * 90 * 4))
    }

    private static func difference(_ lhs: [UInt8], _ rhs: [UInt8]) -> Double {
        var total = 0
        for index in lhs.indices where index % 4 != 3 { total += abs(Int(lhs[index]) - Int(rhs[index])) }
        return Double(total) / Double(lhs.count / 4 * 3 * 255)
    }

    private struct Fixture {
        let root: URL
        let asset: MediaAsset
        let duration: Double
        var timeline: Timeline {
            Timeline(storyPlanID: UUID(), width: 320, height: 180, frameRate: 20,
                     items: [TimelineItem(assetID: asset.id, kind: .video, sourceDuration: duration, timelineStart: 0, timelineDuration: duration)])
        }
        static func make(duration: Double) async throws -> Fixture {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("veloedit-effect-parity-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            do {
                let bounds = CGRect(x: 0, y: 0, width: 320, height: 180)
                var pattern = CIImage(color: CIColor(red: 0.12, green: 0.28, blue: 0.47)).cropped(to: bounds)
                for y in 0..<12 {
                    for x in 0..<20 {
                        let color = CIColor(red: Double((x * 7 + y * 3) % 19) / 20 + 0.025,
                                            green: Double((x * 3 + y * 7) % 17) / 18 + 0.025,
                                            blue: Double((x * 11 + y * 5) % 13) / 14 + 0.025)
                        pattern = CIImage(color: color).cropped(to: CGRect(x: x * 16, y: y * 15, width: 14, height: 13)).composited(over: pattern)
                    }
                }
                let image = try #require(CIContext().createCGImage(pattern, from: bounds))
                let png = root.appendingPathComponent("pattern.png")
                let writer = try #require(CGImageDestinationCreateWithURL(png as CFURL, UTType.png.identifier as CFString, 1, nil))
                CGImageDestinationAddImage(writer, image, nil)
                #expect(CGImageDestinationFinalize(writer))
                let url = try await StillImageVideoGenerator().generate(imageURL: png, duration: duration, width: 320, height: 180,
                                                                       frameRate: 20, destination: root.appendingPathComponent("source.mov"), codec: .jpeg, motion: nil)
                let asset = MediaAsset(originalURL: url, kind: .video, byteSize: 1, contentHash: "pattern-\(UUID().uuidString)",
                                       metadata: MediaMetadata(duration: duration, width: 320, height: 180, frameRate: 20, hasAudio: false))
                return Fixture(root: root, asset: asset, duration: duration)
            } catch {
                try? FileManager.default.removeItem(at: root)
                throw error
            }
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}
