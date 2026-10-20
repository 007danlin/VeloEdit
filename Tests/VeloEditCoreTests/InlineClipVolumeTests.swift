import Foundation
import AVFoundation
import Testing
@testable import VeloEditCore

struct InlineClipVolumeTests {
    @Test(arguments: [Float(0), 0.25, 0.5])
    func closingFadePreservesMiddleClipGainOnReusedTrack(_ volume: Float) throws {
        let input = AVMutableAudioMixInputParameters()
        input.setVolume(0, at: .zero)
        for index in stride(from: 1, through: 25, by: 2) {
            let start = Double(index) * 3
            let gain: Float = index == 21 ? volume : 1
            if index == 7 {
                input.setVolume(gain, at: time(start))
                continue
            }
            input.setVolumeRamp(fromStartVolume: 0, toEndVolume: gain,
                timeRange: CMTimeRange(start: time(start), duration: time(0.12)))
            input.setVolumeRamp(fromStartVolume: gain, toEndVolume: 0,
                timeRange: CMTimeRange(start: time(start + 3 - 0.18), duration: time(0.18)))
        }
        let finished = try #require(FilmEndingFade(duration: 3, movieDuration: 78, frameRate: 30))
            .applying(to: input, movieDuration: 78)
        #expect(gain(finished, at: 64) == volume)
        #expect(abs(gain(finished, at: 58) - 1) < 0.001)
        #expect(abs(gain(finished, at: 70) - 1) < 0.001)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["VELOEDIT_VOLUME_PROJECT"] != nil))
    func savedZeroVolumeReachesActualProjectMix() async throws {
        let url = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["VELOEDIT_VOLUME_PROJECT"]))
        let manifest = try JSONDecoder.veloEdit.decode(ProjectManifest.self, from: Data(contentsOf: url.appendingPathComponent("project.json")))
        var timeline = try #require(manifest.timelines.last)
        timeline.width = 160; timeline.height = 90
        timeline.music = nil; timeline.adaptiveSoundtrack = nil
        let playback = try await PlaybackEngine().build(timeline: timeline, assets: manifest.assets,
            derivedMediaCacheURL: URL(fileURLWithPath: "/tmp/veloedit-volume-project-audit"))
        let target = try #require(timeline.items.first { $0.timelineStart <= 65.5 && $0.timelineStart + $0.timelineDuration > 65.5 })
        let start = try #require(SpeechTimeMap.playbackStart(itemID: target.id, timeline: timeline))
        let position = start + 1
        for track in playback.composition.tracks(withMediaType: .audio) {
            guard track.segments.contains(where: { !$0.isEmpty && $0.timeMapping.target.containsTime(time(position)) }) else { continue }
            let params = try #require(playback.audioMix?.inputParameters.first { $0.trackID == track.trackID })
            print("VOLUME AUDIT", target.id, target.effectiveAudioAdjustments.volume, "playback", position, "track", track.trackID, "gain", gain(params, at: position))
            #expect(abs(gain(params, at: position) - Float(target.effectiveAudioAdjustments.effectiveVolume)) < 0.001)
        }
        // Exercise the same in-place mixer update used by the inline button.
        let targetIndex = try #require(timeline.items.firstIndex { $0.id == target.id })
        var previous = timeline
        for volume in [1.0, 0.25, 0.0] {
            var next = previous
            next.items[targetIndex].audioAdjustments?.volume = volume
            let mix = try #require(playback.updatedAudioMix(from: previous, to: next))
            let track = try #require(playback.composition.tracks(withMediaType: .audio).first {
                $0.segments.contains { !$0.isEmpty && $0.timeMapping.target.containsTime(time(position)) }
            })
            let params = try #require(mix.inputParameters.first { $0.trackID == track.trackID })
            #expect(abs(gain(params, at: position) - Float(volume)) < 0.001)
            previous = next
        }
        // Verify decoded sound too, independently of the queried envelope.
        // Only camera audio is included; the separate music must remain audible.
        try #require(target.effectiveAudioAdjustments.effectiveVolume == 0)
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("veloedit-muted-clip-\(UUID()).m4a")
        defer { try? FileManager.default.removeItem(at: output) }
        let export = try #require(AVAssetExportSession(asset: playback.composition, presetName: AVAssetExportPresetAppleM4A))
        export.audioMix = playback.audioMix
        export.outputURL = output; export.outputFileType = .m4a
        export.timeRange = CMTimeRange(start: time(start + 0.4), duration: time(2))
        try await EditorialAudioMastering.export(export)
        let encoded = AVURLAsset(url: output)
        let reader = try AVAssetReader(asset: encoded)
        let audio = AVAssetReaderAudioMixOutput(audioTracks: try await encoded.loadTracks(withMediaType: .audio),
            audioSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true])
        reader.add(audio)
        try #require(reader.startReading())
        var peak: Float = 0, count = 0
        while let sample = audio.copyNextSampleBuffer(), let buffer = CMSampleBufferGetDataBuffer(sample) {
            let size = CMBlockBufferGetDataLength(buffer) / MemoryLayout<Float>.size
            var values = [Float](repeating: 0, count: size)
            let status = values.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(buffer, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
            }
            try #require(status == kCMBlockBufferNoErr)
            peak = max(peak, values.map(abs).max() ?? 0); count += size
        }
        #expect(reader.status == .completed && count > 48_000)
        #expect(peak < 0.00001)
        print("MUTED CLIP DECODED PEAK", peak, "samples", count)
    }

    private func time(_ value: Double) -> CMTime { CMTime(seconds: value, preferredTimescale: 48_000) }
    private func gain(_ parameters: AVAudioMixInputParameters, at seconds: Double) -> Float {
        var start: Float = 0, end: Float = 0
        var range = CMTimeRange.zero
        guard parameters.getVolumeRamp(for: time(seconds), startVolume: &start, endVolume: &end, timeRange: &range) else { return 1 }
        guard range.duration.seconds > 0 else { return end }
        return start + (end - start) * Float(min(1, max(0, (seconds - range.start.seconds) / range.duration.seconds)))
    }
}
