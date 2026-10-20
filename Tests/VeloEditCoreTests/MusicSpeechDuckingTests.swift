import Foundation
import AVFoundation
import Testing
@testable import VeloEditCore

struct MusicSpeechDuckingTests {
    private func fixture() -> (Timeline, UUID) {
        let asset = UUID()
        let item = TimelineItem(assetID: asset, kind: .video, sourceStart: 10, sourceDuration: 10,
            timelineStart: 0, timelineDuration: 10)
        let timeline = Timeline(storyPlanID: UUID(), items: [item],
            music: MusicDirective(style: .calm, bpm: 100, volume: 0.5), originalAudioVolume: 1,
            audioDucking: .init(enabled: true, attenuation: 0.34, attack: 0.16, release: 0.34))
        return (timeline, asset)
    }

    @Test func noEvidenceNeverDucksWholeAudioTrack() {
        let (timeline, _) = fixture()
        #expect(MusicSpeechDucking.regions(in: timeline).isEmpty)
        var failed = SpeechTranscript(localeIdentifier: "ru", words: [], sentences: [], confidence: 0)
        failed.status = .failed
        var copy = timeline
        copy.speechRecords = [.init(assetID: timeline.items[0].assetID!, transcript: failed)]
        #expect(MusicSpeechDucking.regions(in: copy).isEmpty)
    }

    @Test func speechPausesAndMutedSourcesHaveNoDucking() throws {
        var (timeline, asset) = fixture()
        let activity = [SpeechActivityRecord(assetID: asset, ranges: [12...13, 16...17])]
        let zones = MusicSpeechDucking.regions(in: timeline, activity: activity)
        #expect(zones.count == 2)
        let first = try #require(zones.first)
        #expect(abs(first.speechRange.lowerBound - 2) < 0.001)
        #expect(abs(first.gain(at: 2.5) - 0.34) < 0.001)
        #expect(first.gain(at: 4) == 1)
        timeline.items[0].audioAdjustments = .init(muted: true)
        #expect(MusicSpeechDucking.regions(in: timeline, activity: activity).isEmpty)
        timeline.items[0].audioAdjustments = .init(volume: 0)
        #expect(MusicSpeechDucking.regions(in: timeline, activity: activity).isEmpty)
        timeline.items[0].audioAdjustments = .init(volume: 1)
        #expect(MusicSpeechDucking.regions(in: timeline, activity: activity) == zones)
        timeline.items[0].audioAdjustments = nil
        timeline.originalAudioVolume = 0
        #expect(MusicSpeechDucking.regions(in: timeline, activity: activity).isEmpty)
    }

    @Test func explicitNoSpeechBeatsStaleClassification() {
        var (timeline, asset) = fixture()
        var transcript = SpeechTranscript(localeIdentifier: "ru", words: [], sentences: [], confidence: 1)
        transcript.status = .noSpeech
        timeline.speechRecords = [.init(assetID: asset, transcript: transcript)]
        #expect(MusicSpeechDucking.regions(in: timeline, activity: [.init(assetID: asset, ranges: [10...20])]).isEmpty)
    }

    @Test func deletionSurvivesMoveTrimSplitAndSerialization() throws {
        var (timeline, asset) = fixture()
        let activity = [SpeechActivityRecord(assetID: asset, ranges: [12...13, 16...17])]
        let region = try #require(MusicSpeechDucking.regions(in: timeline, activity: activity).first)
        MusicSpeechDucking.removing(region, from: &timeline)
        #expect(MusicSpeechDucking.regions(in: timeline, activity: activity).count == 1)
        let data = try JSONEncoder().encode(timeline)
        timeline = try JSONDecoder().decode(Timeline.self, from: data)
        // The source-time edit travels with copied adjustments on either half.
        var first = timeline.items[0]
        var second = first
        first.sourceDuration = 5; first.timelineDuration = 5
        second.id = UUID(); second.sourceStart = 15; second.sourceDuration = 5
        second.timelineStart = 5; second.timelineDuration = 5
        timeline.items = [first, second]
        #expect(MusicSpeechDucking.regions(in: timeline, activity: activity).count == 1)
        timeline.items[0].sourceStart = 11
        timeline.items[0].sourceDuration = 4
        timeline.items[0].timelineDuration = 4
        timeline.items = TimelineTiming.retimed([second, timeline.items[0]])
        let remaining = MusicSpeechDucking.regions(in: timeline, activity: activity)
        #expect(remaining.count == 1)
        #expect(remaining[0].anchors[0].sourceRange == 16...17)
    }

    @Test func independentMusicTargetsAndDetachedSpeech() throws {
        var (timeline, asset) = fixture()
        timeline.items[0].audioAdjustments = .init(muted: true)
        let voice = TimelineAudioClip(assetID: asset, title: "Speech", role: .detached,
            sourceStart: 10, sourceDuration: 10, timelineStart: 0, timelineDuration: 10)
        let music = TimelineAudioClip(title: "Extra music", role: .music,
            sourceDuration: 10, timelineStart: 0, timelineDuration: 10)
        timeline.audioClips = [voice, music]
        let activity = [SpeechActivityRecord(assetID: asset, ranges: [12...13])]
        let regions = MusicSpeechDucking.regions(in: timeline, activity: activity)
        #expect(regions.count == 2)
        MusicSpeechDucking.removing(try #require(regions.first { $0.target == MusicSpeechDucking.soundtrack }), from: &timeline)
        #expect(MusicSpeechDucking.regions(in: timeline, activity: activity).map(\.target) == [music.id.uuidString])
    }

    @Test func retimingUsesTheActualSourceClock() throws {
        var (timeline, asset) = fixture()
        timeline.items[0].speed = 2
        timeline.items[0].timelineDuration = 5
        let region = try #require(MusicSpeechDucking.regions(in: timeline, activity: [.init(assetID: asset, ranges: [12...14])]).first)
        #expect(abs(region.speechRange.lowerBound - 1) < 0.001)
        #expect(abs(region.speechRange.upperBound - 2) < 0.001)
    }

    @Test func splittingMusicPreservesRemovedZonesOnBothHalves() throws {
        var (timeline, asset) = fixture()
        timeline.music = nil
        let music = TimelineAudioClip(title: "Music", role: .music, sourceDuration: 10, timelineStart: 0, timelineDuration: 10)
        timeline.audioClips = [music]
        let activity = [SpeechActivityRecord(assetID: asset, ranges: [16...17])]
        MusicSpeechDucking.removing(try #require(MusicSpeechDucking.regions(in: timeline, activity: activity).first), from: &timeline)
        _ = try #require(TimelineMutationEngine.splitAudioClip(in: &timeline, id: music.id, atTimelineTime: 5))
        #expect(MusicSpeechDucking.regions(in: timeline, activity: activity).isEmpty)
    }

    @Test func removingAdaptiveZonePreservesAdjacentMusicSegment() throws {
        var (timeline, asset) = fixture()
        let trackID = UUID()
        timeline.music?.trackID = trackID
        let directive = try #require(timeline.music)
        timeline.adaptiveSoundtrack = .init(primaryTrackID: trackID, timelineDuration: 10,
            segments: [0.0, 5.0].map {
                .init(timelineStart: $0, timelineDuration: 5, directive: directive,
                    semanticLabel: "Music", energy: 0.5, confidence: 1)
            }, confidence: 1, userEdited: true)
        let activity = [SpeechActivityRecord(assetID: asset, ranges: [12...18])]
        let regions = MusicSpeechDucking.regions(in: timeline, activity: activity)
        #expect(regions.count == 2)
        MusicSpeechDucking.removing(try #require(regions.first), from: &timeline)
        let remaining = MusicSpeechDucking.regions(in: timeline, activity: activity)
        #expect(remaining.count == 1)
        #expect(remaining.first?.speechRange == 5...8)
    }

    @Test func fadeAndSpeechMultiplyWithNoOverlappingRamps() throws {
        let (timeline, asset) = fixture()
        let regions = MusicSpeechDucking.regions(in: timeline, activity: [.init(assetID: asset, ranges: [12...13])])
        let parameters = AVMutableAudioMixInputParameters()
        parameters.setVolumeRamp(fromStartVolume: 0, toEndVolume: 0.5,
            timeRange: CMTimeRange(start: .zero, duration: CMTime(seconds: 5, preferredTimescale: 600)))
        let mix = MusicSpeechDucking.applying(regions, to: parameters, duration: 10)
        #expect(abs(volume(mix, at: 2.5) - 0.085) < 0.002)
        #expect(abs(volume(mix, at: 4) - 0.4) < 0.002)
        let envelopes = EditorialAudioMastering.envelopes(mix, duration: 10)
        #expect(zip(envelopes, envelopes.dropFirst()).allSatisfy { $0.2.end == $1.2.start })
    }

    @Test func speechAtClipStartIsAlreadyDucked() throws {
        let (timeline, asset) = fixture()
        let zones = MusicSpeechDucking.regions(in: timeline, activity: [.init(assetID: asset, ranges: [10...12])])
        let parameters = AVMutableAudioMixInputParameters()
        parameters.setVolume(0.5, at: .zero)
        let mix = MusicSpeechDucking.applying(zones, to: parameters, duration: 10)
        #expect(abs(volume(mix, at: 0.1) - 0.17) < 0.001)
        #expect(abs(volume(mix, at: 3) - 0.5) < 0.001)
    }

    @Test func actualPlaybackUsesSpeechOnlyAndRemovalRestoresGain() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("speech-ducking-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let musicURL = root.appendingPathComponent("music.caf")
        let voiceURL = root.appendingPathComponent("voice.caf")
        try writeTone(musicURL, frequency: 880); try writeTone(voiceURL)
        let asset = MediaAsset(originalURL: voiceURL, kind: .video, byteSize: 1, contentHash: UUID().uuidString,
            metadata: .init(duration: 10, hasAudio: true))
        let track = LocalMusicTrack(title: "Music", author: "Test", bpm: 100, genres: [], moods: [], energy: 0.5,
            duration: 10, license: .userFile(), sourceProvider: .user, sourcePageURL: musicURL,
            localFileURL: musicURL, originalFileName: "music.caf")
        let item = TimelineItem(kind: .title, sourceDuration: 10, timelineStart: 0, timelineDuration: 10, title: "Speech")
        var timeline = Timeline(storyPlanID: UUID(), width: 160, height: 90, frameRate: 30, items: [item],
            audioClips: [.init(assetID: asset.id, title: "Voice", role: .detached,
                sourceDuration: 10, timelineStart: 0, timelineDuration: 10)],
            music: .init(style: .calm, bpm: 100, volume: 0.5, trackID: track.id),
            audioDucking: .init(enabled: true, attenuation: 0.34))
        var transcript = SpeechTranscript(localeIdentifier: "ru", words: [], sentences: [], confidence: 1)
        transcript.status = .ready; transcript.speechRanges = [3...4]
        timeline.speechRecords = [.init(assetID: asset.id, transcript: transcript)]
        let playback = try await PlaybackEngine().build(timeline: timeline, assets: [asset], musicTracks: [track])
        let musicTrack = try #require(playback.composition.tracks(withMediaType: .audio).first {
            $0.segments.contains { $0.sourceURL == musicURL }
        })
        let parameters = try #require(playback.audioMix?.inputParameters.first { $0.trackID == musicTrack.trackID })
        #expect(abs(volume(parameters, at: 2) - 0.5) < 0.001)
        #expect(abs(volume(parameters, at: 3.5) - 0.17) < 0.001)
        #expect(abs(volume(parameters, at: 5) - 0.5) < 0.001)
        // Independently decode an encoded AAC mix, so a correct-looking volume
        // envelope alone cannot make this acceptance test pass.
        let exporter = try #require(AVAssetExportSession(asset: playback.composition, presetName: AVAssetExportPresetAppleM4A))
        let encoded = root.appendingPathComponent("mix.m4a")
        exporter.outputURL = encoded; exporter.outputFileType = .m4a
        exporter.audioMix = playback.audioMix
        await exporter.export()
        try #require(exporter.status == .completed)
        let levels = try await musicLevels(AVURLAsset(url: encoded))
        #expect(abs(levels[1] / levels[0] - 0.34) < 0.04)
        #expect(abs(levels[2] / levels[0] - 1) < 0.04)
        let zone = try #require(MusicSpeechDucking.regions(in: timeline).first)
        MusicSpeechDucking.removing(zone, from: &timeline)
        let updated = try await PlaybackEngine().build(timeline: timeline, assets: [asset], musicTracks: [track])
        let updatedTrack = try #require(updated.composition.tracks(withMediaType: .audio).first { $0.segments.contains { $0.sourceURL == musicURL } })
        let restored = try #require(updated.audioMix?.inputParameters.first { $0.trackID == updatedTrack.trackID })
        #expect(abs(volume(restored, at: 3.5) - 0.5) < 0.001)
    }

    @Test func zeroVideoVolumeRestoresMusicInLiveMixAndEncodedAudio() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("video-volume-ducking-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let musicURL = root.appendingPathComponent("music.caf")
        let voiceURL = root.appendingPathComponent("voice.caf")
        try writeTone(musicURL, frequency: 880); try writeTone(voiceURL)
        let picture = try await TitleCardVideoGenerator().generate(text: "", style: TitleStyle(),
            duration: 10, width: 160, height: 90, frameRate: 30, destination: root.appendingPathComponent("picture.mov"))
        let source = AVMutableComposition()
        let range = CMTimeRange(start: .zero, duration: CMTime(seconds: 10, preferredTimescale: 48_000))
        for (url, type) in [(picture, AVMediaType.video), (voiceURL, AVMediaType.audio)] {
            let sourceAsset = AVURLAsset(url: url)
            let input = try #require(try await sourceAsset.loadTracks(withMediaType: type).first)
            let output = try #require(source.addMutableTrack(withMediaType: type, preferredTrackID: kCMPersistentTrackID_Invalid))
            try output.insertTimeRange(range, of: input, at: .zero)
        }
        let sourceURL = root.appendingPathComponent("video-with-audio.mov")
        let mux = try #require(AVAssetExportSession(asset: source, presetName: AVAssetExportPresetHighestQuality))
        mux.outputURL = sourceURL; mux.outputFileType = .mov
        try await EditorialAudioMastering.export(mux)
        let asset = MediaAsset(originalURL: sourceURL, kind: .video, byteSize: 1, contentHash: UUID().uuidString,
            metadata: .init(duration: 10, width: 160, height: 90, frameRate: 30, hasAudio: true))
        let track = LocalMusicTrack(title: "Music", author: "Test", bpm: 100, genres: [], moods: [], energy: 0.5,
            duration: 10, license: .userFile(), sourceProvider: .user, sourcePageURL: musicURL,
            localFileURL: musicURL, originalFileName: "music.caf")
        let item = TimelineItem(assetID: asset.id, kind: .video, sourceDuration: 10, timelineStart: 0, timelineDuration: 10)
        var timeline = Timeline(storyPlanID: UUID(), width: 160, height: 90, frameRate: 30, items: [item],
            music: .init(style: .calm, bpm: 100, volume: 0.5, trackID: track.id), originalAudioVolume: 1,
            audioDucking: .init(enabled: true, attenuation: 0.34))
        var transcript = SpeechTranscript(localeIdentifier: "ru", words: [], sentences: [], confidence: 1)
        transcript.status = .ready; transcript.speechRanges = [3...4]
        timeline.speechRecords = [.init(assetID: asset.id, transcript: transcript)]
        let playback = try await PlaybackEngine().build(timeline: timeline, assets: [asset], musicTracks: [track])
        let musicTrack = try #require(playback.composition.tracks(withMediaType: .audio).first {
            $0.segments.contains { $0.sourceURL == musicURL }
        })
        let originalZones = MusicSpeechDucking.regions(in: timeline)
        #expect(originalZones.count == 1)
        let originalParameters = try #require(playback.audioMix?.inputParameters.first { $0.trackID == musicTrack.trackID })
        #expect(abs(volume(originalParameters, at: 3.5) - 0.17) < 0.001)

        for gain in [0.0, 1.0, 0.0] {
            let previous = timeline
            timeline.items[0].audioAdjustments = .init(volume: gain)
            let mix = try #require(playback.updatedAudioMix(from: previous, to: timeline))
            let parameters = try #require(mix.inputParameters.first { $0.trackID == musicTrack.trackID })
            #expect(abs(volume(parameters, at: 3.5) - (gain == 0 ? 0.5 : 0.17)) < 0.001)
            #expect(MusicSpeechDucking.regions(in: timeline) == (gain == 0 ? [] : originalZones))
        }

        let encoded = root.appendingPathComponent("muted-video-with-music.m4a")
        let exporter = try #require(AVAssetExportSession(asset: playback.composition, presetName: AVAssetExportPresetAppleM4A))
        exporter.outputURL = encoded; exporter.outputFileType = .m4a; exporter.audioMix = playback.audioMix
        try await EditorialAudioMastering.export(exporter)
        let levels = try await musicLevels(AVURLAsset(url: encoded))
        #expect(levels[0] > 0.01)
        #expect(abs(levels[1] / levels[0] - 1) < 0.04)
        #expect(abs(levels[2] / levels[0] - 1) < 0.04)
        let reopened = try JSONDecoder().decode(Timeline.self, from: JSONEncoder().encode(timeline))
        let rebuilt = try await PlaybackEngine().build(timeline: reopened, assets: [asset], musicTracks: [track])
        let rebuiltMusic = try #require(rebuilt.composition.tracks(withMediaType: .audio).first {
            $0.segments.contains { $0.sourceURL == musicURL }
        })
        let rebuiltParameters = try #require(rebuilt.audioMix?.inputParameters.first { $0.trackID == rebuiltMusic.trackID })
        #expect(MusicSpeechDucking.regions(in: reopened, activity: rebuilt.speechActivity).isEmpty)
        #expect(abs(volume(rebuiltParameters, at: 3.5) - 0.5) < 0.001)
    }

    @Test func localDetectorDoesNotTreatInstrumentalToneAsSpeech() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("speech-detector-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("tone.caf")
        try writeTone(url)
        let asset = MediaAsset(originalURL: url, kind: .video, byteSize: 1, contentHash: UUID().uuidString,
            metadata: .init(duration: 10, hasAudio: true))
        let timeline = detectorTimeline(asset)
        let result = try await SpeechActivityDetector.shared.resolve(timeline: timeline, assets: [asset], cacheDirectory: root)
        #expect(!result.unavailable)
        #expect(result.records.count == 1)
        #expect(result.records[0].ranges.isEmpty)
        #expect(MusicSpeechDucking.regions(in: timeline, activity: result.records).isEmpty)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["VELOEDIT_SPEECH_FIXTURE"] != nil))
    func localDetectorFindsSpokenWords() async throws {
        let url = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["VELOEDIT_SPEECH_FIXTURE"]))
        let duration = try await AVURLAsset(url: url).load(.duration).seconds
        let asset = MediaAsset(originalURL: url, kind: .video, byteSize: 1, contentHash: UUID().uuidString,
            metadata: .init(duration: duration, hasAudio: true))
        let result = try await SpeechActivityDetector.shared.resolve(timeline: detectorTimeline(asset), assets: [asset], cacheDirectory: nil)
        #expect(!result.unavailable)
        #expect(result.records.first?.ranges.isEmpty == false)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["VELOEDIT_DUCKING_PROJECT"] != nil))
    func inspectExistingProjectSpeech() async throws {
        let url = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["VELOEDIT_DUCKING_PROJECT"]))
        let manifest = try JSONDecoder.veloEdit.decode(ProjectManifest.self, from: Data(contentsOf: url.appendingPathComponent("project.json")))
        let timeline = try #require(manifest.timelines.last)
        let result = try await SpeechActivityDetector.shared.resolve(timeline: timeline, assets: manifest.assets,
            cacheDirectory: URL(fileURLWithPath: "/tmp/veloedit-ducking-project-audit"))
        #expect(!result.unavailable)
        let regions = MusicSpeechDucking.regions(in: timeline, activity: result.records)
        let silentItems = Set(timeline.items.filter { $0.effectiveAudioAdjustments.effectiveVolume == 0 }.map(\.id))
        #expect(regions.allSatisfy { $0.anchors.allSatisfy { $0.isAudioClip || !silentItems.contains($0.itemID) } })
        print("SPEECH DUCKING AUDIT: \(regions.map { [($0.timelineRange.lowerBound * 100).rounded() / 100, ($0.timelineRange.upperBound * 100).rounded() / 100] })")
        let data = try JSONEncoder().encode(result.records)
        try data.write(to: URL(fileURLWithPath: "/tmp/veloedit-ducking-project-activity.json"))
    }

    private func detectorTimeline(_ asset: MediaAsset) -> Timeline {
        let duration = asset.metadata.duration ?? 10
        return Timeline(storyPlanID: UUID(),
            items: [.init(kind: .title, sourceDuration: duration, timelineStart: 0, timelineDuration: duration, title: "Detector")],
            audioClips: [.init(assetID: asset.id, title: "Source", role: .dialogue,
                sourceDuration: duration, timelineStart: 0, timelineDuration: duration)],
            music: .init(style: .calm, bpm: 100, volume: 0.5), audioDucking: .init(enabled: true))
    }

    private func volume(_ mix: AVAudioMixInputParameters, at seconds: Double) -> Float {
        var a: Float = 0, b: Float = 0
        var range = CMTimeRange.zero
        guard mix.getVolumeRamp(for: CMTime(seconds: seconds, preferredTimescale: 48_000),
            startVolume: &a, endVolume: &b, timeRange: &range) else { return 1 }
        guard range.duration.seconds > 0 else { return b }
        return a + (b - a) * Float(min(1, max(0, (seconds - range.start.seconds) / range.duration.seconds)))
    }

    private func musicLevels(_ asset: AVAsset) async throws -> [Double] {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderAudioMixOutput(audioTracks: try await asset.loadTracks(withMediaType: .audio),
            audioSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false])
        reader.add(output)
        try #require(reader.startReading())
        let times = [2.0, 3.25, 5.0]
        var sine = [Double](repeating: 0, count: 3), cosine = sine, counts = sine
        while let sample = output.copyNextSampleBuffer() {
            let block = try #require(CMSampleBufferGetDataBuffer(sample))
            var values = [Float](repeating: 0, count: CMBlockBufferGetDataLength(block) / 4)
            let status = values.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
            }
            try #require(status == kCMBlockBufferNoErr)
            let start = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            for (index, value) in values.enumerated() {
                let time = start + Double(index) / 48_000
                for w in times.indices where time >= times[w] && time < times[w] + 0.5 {
                    sine[w] += Double(value) * sin(2 * .pi * 880 * time)
                    cosine[w] += Double(value) * cos(2 * .pi * 880 * time)
                    counts[w] += 1
                }
            }
        }
        try #require(reader.status == .completed)
        try #require(counts.allSatisfy { $0 > 23_000 })
        return times.indices.map { 2 * hypot(sine[$0], cosine[$0]) / counts[$0] }
    }

    private func writeTone(_ url: URL, frequency: Double = 440) throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480_000))
        buffer.frameLength = buffer.frameCapacity
        for i in 0..<Int(buffer.frameLength) { buffer.floatChannelData![0][i] = Float(0.1 * sin(Double(i) * 2 * .pi * frequency / 48_000)) }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }
}
