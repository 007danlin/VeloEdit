import Foundation
import AVFoundation
import Testing
@testable import VeloEditCore

@Suite(.serialized) struct FilmMusicEndingTests {
    @Test(arguments: [0.5, 1.0, 1.7])
    func loopedMusicCoversFractionalMovieEndWithoutEmptySegments(_ speed: Double) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("veloedit-music-fractional-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("tone.caf")
        try writeTone(to: source, duration: 0.744)
        let track = LocalMusicTrack(title: "Tone", author: "Fixture", bpm: 100, genres: [], moods: [], energy: 0.5,
                                   duration: 0.744, license: .userFile(), sourceProvider: .user,
                                   sourcePageURL: source, localFileURL: source, originalFileName: source.lastPathComponent)
        var music = MusicDirective(style: .calm, bpm: 100, volume: 0.4, trackID: track.id)
        music.speed = speed
        music.sourceStart = 0.1379
        // Real mixed-camera edits retain sub-millisecond precision. Their end
        // cannot be represented on the old 600 Hz soundtrack loop clock.
        let duration = 2.001134
        let item = TimelineItem(kind: .title, sourceDuration: duration, timelineStart: 0,
                                timelineDuration: duration, title: "Fractional ending")
        let timeline = Timeline(storyPlanID: UUID(), width: 160, height: 90, frameRate: 30,
                                items: [item], music: music, originalAudioVolume: 0)
        let playback = try await PlaybackEngine().build(timeline: timeline, assets: [], musicTracks: [track])
        let audio = try #require(playback.composition.tracks(withMediaType: .audio).first)
        let segments = audio.segments.filter { !$0.isEmpty }
        #expect(segments.count >= 2)
        #expect(segments.allSatisfy { $0.timeMapping.source.duration > .zero && $0.timeMapping.target.duration > .zero })
        #expect(zip(segments, segments.dropFirst()).allSatisfy { $0.timeMapping.target.end == $1.timeMapping.target.start })
        let end = try #require(segments.last).timeMapping.target.end.seconds
        #expect(abs(end - playback.duration) < 1 / 48_000.0)
        let reader = try AVAssetReader(asset: playback.composition)
        let output = AVAssetReaderTrackOutput(track: audio, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
        reader.add(output)
        try #require(reader.startReading())
        var decodedSamples = 0
        while let sample = output.copyNextSampleBuffer() { decodedSamples += CMSampleBufferGetNumSamples(sample) }
        #expect(reader.status == .completed)
        #expect(decodedSamples > 48_000)
    }

    @Test func finishPreservesDuckingAndClipFadesWithoutOverlappingRamps() throws {
        let original = AVMutableAudioMixInputParameters()
        original.trackID = 42
        original.audioTimePitchAlgorithm = .spectral
        original.setVolume(0.6, at: .zero)
        original.setVolumeRamp(fromStartVolume: 0, toEndVolume: 0.6,
                               timeRange: range(0, 0.5))
        original.setVolumeRamp(fromStartVolume: 0.6, toEndVolume: 0.2,
                               timeRange: range(4.5, 5.5))
        original.setVolumeRamp(fromStartVolume: 0.2, toEndVolume: 0.6,
                               timeRange: range(6.5, 7.5))
        let fade = try #require(FilmEndingFade(duration: 3, movieDuration: 8, frameRate: 30))
        let finished = fade.applying(to: original, movieDuration: 8)
        #expect(finished.trackID == 42)
        #expect(finished.audioTimePitchAlgorithm == .spectral)
        #expect(abs(volume(finished, at: 0.25) - 0.3) < 0.001)
        #expect(abs(volume(finished, at: 4) - 0.6) < 0.001)
        // A ducking release remains attenuated by the closing curve rather
        // than restoring the soundtrack to its normal volume at the end.
        #expect(volume(finished, at: 7) < 0.11)
        #expect(volume(finished, at: 7.9) < 0.002)
        #expect(volume(finished, at: 8) == 0)
        let envelopes = EditorialAudioMastering.envelopes(finished, duration: 8)
        #expect(zip(envelopes, envelopes.dropFirst()).allSatisfy { $0.2.end == $1.2.start })
        #expect(abs(envelopes.reduce(0) { $0 + $1.2.duration.seconds } - 8) < 0.0001)

        let muted = AVMutableAudioMixInputParameters()
        muted.setVolume(0, at: .zero)
        #expect(volume(fade.applying(to: muted, movieDuration: 8), at: 7) == 0)
    }

    @Test(arguments: [2.0, 4.0]) func shortFilmsKeepTheFullAvailableFade(_ duration: Double) throws {
        let fade = try #require(FilmEndingFade(duration: 3, movieDuration: duration, frameRate: 30))
        #expect(abs((fade.end - fade.start) - min(3, duration - 1 / 30.0)) < 0.0001)
        #expect(abs(fade.opacity(at: (fade.start + fade.end) / 2) - 0.5) < 0.0001)
        #expect(fade.opacity(at: duration - 1 / 30.0) == 0)
    }

    @Test(arguments: ["ordinary", "adaptive", "manual", "short"])
    func decodedPreviewAndExportFinishMusicGradually(_ mode: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("veloedit-music-finish-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("tone.caf")
        try writeTone(to: source)
        let track = LocalMusicTrack(title: "Tone", author: "Fixture", bpm: 100, genres: [], moods: [], energy: 0.5,
                                   duration: 10, license: .userFile(), sourceProvider: .user,
                                   sourcePageURL: source, localFileURL: source, originalFileName: source.lastPathComponent)
        var secondTrack = track
        secondTrack.id = UUID()
        secondTrack.title = "Second tone"
        let tracks = [track, secondTrack]
        let duration = mode == "short" ? 2.0 : 8.0
        let directive = MusicDirective(style: .calm, bpm: 100, volume: 0.4, trackID: track.id)
        let items = [TimelineItem(kind: .title, sourceDuration: duration, timelineStart: 0,
                                  timelineDuration: duration, title: "Music finish")]
        // nil and zero visual fades must not disable the shared music fade.
        var timeline = Timeline(storyPlanID: UUID(), width: 160, height: 90, frameRate: 30, items: items,
                                music: directive, endingFadeDuration: mode == "manual" ? 0 : nil,
                                audioDucking: .init(enabled: false))
        if mode == "adaptive" {
            let segments = [
                AdaptiveMusicSegment(timelineStart: 0, timelineDuration: 6, directive: directive,
                                     transitionDuration: 0, semanticLabel: "Body", energy: 0.5, confidence: 1),
                AdaptiveMusicSegment(timelineStart: 6, timelineDuration: 2,
                                     directive: .init(style: .calm, bpm: 100, volume: 0.4, trackID: secondTrack.id),
                                     transitionDuration: 0.8, semanticLabel: "Ending", energy: 0.5, confidence: 1)
            ]
            timeline.adaptiveSoundtrack = .init(primaryTrackID: track.id, timelineDuration: duration,
                                                timelineFingerprint: timeline.adaptiveSoundtrackFingerprint,
                                                segments: segments, confidence: 1)
            #expect(timeline.effectiveAdaptiveSoundtrack != nil)
        } else if mode == "manual" {
            timeline.music = nil
            timeline.audioClips = [TimelineAudioClip(trackID: track.id, title: "Manual music", role: .music,
                sourceDuration: duration, timelineStart: 0, timelineDuration: duration,
                adjustments: .init(volume: 0.4, fadeIn: 0.5, fadeOut: 0.5))]
        }
        let playback = try await PlaybackEngine().build(timeline: timeline, assets: [], musicTracks: tracks)
        let output = root.appendingPathComponent("finished.mp4")
        _ = try await RenderEngine().render(timeline: timeline, assets: [], musicTracks: tracks, quality: .maximum, destination: output)
        let movie = AVURLAsset(url: output)
        #expect(abs(try await movie.load(.duration).seconds - duration) < 1 / 30.0)
        let fadeStart = max(0, duration - 1 / 30.0 - 3)
        let fadeLength = duration - 1 / 30.0 - fadeStart
        let sampleTimes = [0.05, 0.25, 0.50, 0.85, 0.999].map { fadeStart + $0 * fadeLength }
        let preview = try await levels(asset: playback.composition, mix: playback.audioMix, times: sampleTimes)
        let exported = try await levels(asset: movie, mix: nil, times: sampleTimes)
        for samples in [preview, exported] {
            let first = try #require(samples.first)
            #expect(first > 0.005)
            #expect(zip(samples, samples.dropFirst()).allSatisfy { $0 > $1 })
            #expect(samples[1] / first < 0.9) // already fading well before the last second
            #expect(samples[2] / first < 0.6)
            #expect(samples[3] / first < 0.1)
            #expect(samples[4] / first < 0.005)
        }
        // Loudness mastering may change the overall gain, but not the shape.
        for index in preview.indices {
            #expect(abs(preview[index] / preview[0] - exported[index] / exported[0]) < 0.025)
        }
    }

    private func range(_ start: Double, _ end: Double) -> CMTimeRange {
        CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 48_000),
                    end: CMTime(seconds: end, preferredTimescale: 48_000))
    }

    private func volume(_ parameters: AVAudioMixInputParameters, at seconds: Double) -> Float {
        let time = CMTime(seconds: seconds, preferredTimescale: 48_000)
        var a: Float = 0, b: Float = 0
        var range = CMTimeRange.zero
        guard parameters.getVolumeRamp(for: time, startVolume: &a, endVolume: &b, timeRange: &range) else { return 0 }
        guard range.duration.seconds.isFinite, range.duration.seconds > 0 else { return b }
        return a + (b - a) * Float(min(1, max(0, (time - range.start).seconds / range.duration.seconds)))
    }

    private func writeTone(to url: URL, duration: Double = 10) throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount((duration * 48_000).rounded())))
        buffer.frameLength = buffer.frameCapacity
        for i in 0..<Int(buffer.frameLength) {
            buffer.floatChannelData![0][i] = Float(0.2 * sin(2 * .pi * 440 * Double(i) / 48_000))
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }

    private func levels(asset: AVAsset, mix: AVAudioMix?, times: [Double]) async throws -> [Double] {
        let reader = try AVAssetReader(asset: asset)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false
        ])
        output.audioMix = mix
        reader.add(output)
        try #require(reader.startReading())
        var energy = [Double](repeating: 0, count: times.count)
        var counts = [Int](repeating: 0, count: times.count)
        while let sample = output.copyNextSampleBuffer() {
            let block = try #require(CMSampleBufferGetDataBuffer(sample))
            var values = [Float](repeating: 0, count: CMBlockBufferGetDataLength(block) / MemoryLayout<Float>.size)
            let status = values.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
            }
            try #require(status == kCMBlockBufferNoErr)
            let start = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            for (index, value) in values.enumerated() {
                let time = start + Double(index) / 48_000
                for window in times.indices where time >= times[window] && time < times[window] + 0.02 {
                    energy[window] += Double(value * value)
                    counts[window] += 1
                }
            }
        }
        try #require(reader.status == .completed)
        try #require(counts.allSatisfy { $0 > 100 })
        return zip(energy, counts).map { sqrt($0 / Double($1)) }
    }
}
