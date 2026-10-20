import AVFoundation
import Foundation
import Testing
@testable import VeloEditCore

@Suite(.serialized)
struct SpeechNoiseReductionTests {
    @Test func reducesBroadbandNoiseAndHumWhilePreservingSpeech() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let reference = try speech()
        let padding = 24_000
        let clean = [Float](repeating: 0, count: padding) + reference + [Float](repeating: 0, count: padding)
        let noise = makeNoise(count: clean.count, amplitude: rms(reference) * 0.75)
        let noisy = zip(clean, noise).map(+)
        let source = try fixture.write([noisy])
        let result = try await fixture.reduce(source, amount: 1)
        let medium = try await fixture.reduce(source, amount: 0.5)
        let mild = try await fixture.reduce(source, amount: 0.2)
        try #require(result[0].count == clean.count)
        let voice = padding..<(padding + reference.count)
        let before = signalToDistortion(clean, noisy, range: voice)
        let after = signalToDistortion(clean, result[0], range: voice)
        let pause = 9_600..<padding
        let noiseDB = 20 * log10(rms(Array(result[0][pause])) / rms(Array(noisy[pause])))
        let correlation = correlation(Array(clean[voice]), Array(result[0][voice]))
        print("RNNoise: SNR \(before) -> \(after) dB; pause noise \(noiseDB) dB; speech correlation \(correlation)")
        #expect(after - before > 4, "Suppression must improve speech/noise separation, not just turn everything down")
        #expect(correlation > 0.85)
        #expect(noiseDB < -12)
        #expect(rms(Array(medium[0][pause])) < rms(Array(mild[0][pause])))
        #expect(rms(Array(result[0][pause])) < rms(Array(medium[0][pause])))
    }

    @Test func cleanSpeechKeepsTimingLevelAndBothEnds() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let clean = try speech()
        let source = try fixture.write([clean])
        let result = try await fixture.reduce(source, amount: 1)[0]
        try #require(result.count == clean.count)
        #expect(result.allSatisfy { $0.isFinite })
        let similarity = correlation(clean, result)
        let levelDB = 20 * log10(rms(result) / rms(clean))
        print("RNNoise clean speech: correlation \(similarity); level \(levelDB) dB")
        #expect(similarity > 0.9, "The 20 ms algorithm delay must be compensated")
        #expect(abs(levelDB) < 3)
        // Include the first and last spoken parts, not just the central vowel.
        #expect(correlation(Array(clean[0..<24_000]), Array(result[0..<24_000])) > 0.8)
        let tail = (clean.count - 36_000)..<clean.count
        #expect(correlation(Array(clean[tail]), Array(result[tail])) > 0.8)
    }

    @Test func shortClipsDryMixAndStereoChannelsRemainIntact() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        for count in [1, 479, 480, 481, 959, 960, 961, 4_013] {
            let values = makeNoise(count: count, amplitude: 0.1)
            let source = try fixture.write([values, [Float](repeating: 0, count: count)])
            let dry = try await fixture.reduce(source, amount: 0)
            #expect(dry[0] == values)
            #expect(dry[1].allSatisfy { $0 == 0 })
            let wet = try await fixture.reduce(source, amount: 1)
            #expect(wet.count == 2 && wet.allSatisfy { $0.count == count && $0.allSatisfy(\.isFinite) })
            #expect(wet[1].allSatisfy { $0 == 0 }, "No voice or noise may leak into the other channel")
        }
    }

    @Test func fullProcessorUsesDenoisingAndInvalidatesOldCache() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let clean = try speech()
        let source = try fixture.write([zip(clean, makeNoise(count: clean.count, amplitude: rms(clean))).map(+)])
        let duration = Double(clean.count) / 48_000
        let cache = fixture.root.appendingPathComponent("cache")
        let off = try await ProcessedAudioGenerator().generate(sourceURL: source, sourceStart: 0,
            sourceDuration: duration, adjustments: .init(), destination: fixture.url(), cacheDirectory: cache)
        let on = try await ProcessedAudioGenerator().generate(sourceURL: source, sourceStart: 0,
            sourceDuration: duration, adjustments: .init(noiseReduction: 1), destination: fixture.url(), cacheDirectory: cache)
        let reused = try await ProcessedAudioGenerator().generate(sourceURL: source, sourceStart: 0,
            sourceDuration: duration, adjustments: .init(volume: 0.2, noiseReduction: 1), destination: fixture.url(), cacheDirectory: cache)
        #expect(off != on && reused == on)
        let dry = try read(off)[0], wet = try read(on)[0]
        try #require(dry.count == clean.count && wet.count == clean.count)
        #expect(signalToDistortion(clean, wet, range: clean.indices) > signalToDistortion(clean, dry, range: clean.indices) + 4)
        // A valid header with a short payload must not be accepted as a whole clip.
        try fixture.write([Array(clean.prefix(480))], to: on)
        _ = try await ProcessedAudioGenerator().generate(sourceURL: source, sourceStart: 0,
            sourceDuration: duration, adjustments: .init(noiseReduction: 1), destination: fixture.url(), cacheDirectory: cache)
        #expect(try AVAudioFile(forReading: on).length == clean.count)
    }

    @Test func monoResamplingAndTrimKeepSampleAccurateDuration() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100))
        buffer.frameLength = buffer.frameCapacity
        for i in 0..<44_100 { buffer.floatChannelData![0][i] = Float(sin(Double(i) * 0.04)) * 0.1 }
        let source = fixture.url()
        try AVAudioFile(forWriting: source, settings: format.settings).write(from: buffer)
        let result = try await ProcessedAudioGenerator().generate(sourceURL: source, sourceStart: 0.123,
            sourceDuration: 0.137, adjustments: .init(noiseReduction: 0.5), destination: fixture.url())
        let file = try AVAudioFile(forReading: result)
        #expect(file.processingFormat.sampleRate == 48_000 && file.processingFormat.channelCount == 2)
        #expect(abs(file.length - 6_576) <= 1)
    }

    @Test func cancelledProcessingDoesNotPublishAFile() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = try fixture.write([makeNoise(count: 48_000, amplitude: 0.1)])
        let output = fixture.url()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await SpeechNoiseReducer.render(source: source, destination: output, amount: 1)
        }
        do {
            try await task.value
            Issue.record("Expected cancellation")
        } catch is CancellationError {}
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }

    @Test func embeddedAndDetachedSpeechAreCleanedInPreviewAndExport() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let reference = try speech()
        let clean = [Float](repeating: 0, count: 24_000) + reference
            + [Float](repeating: 0, count: 240_000 - 24_000 - reference.count)
        let sourceAudio = try fixture.write([zip(clean, makeNoise(count: clean.count, amplitude: rms(reference))).map(+)])
        let card = try await TitleCardVideoGenerator().generate(text: "Speech", style: TitleStyle(), duration: 5,
            width: 160, height: 90, frameRate: 30, destination: fixture.root.appendingPathComponent("card.mov"))
        let composition = AVMutableComposition()
        for (url, type) in [(card, AVMediaType.video), (sourceAudio, AVMediaType.audio)] {
            let media = AVURLAsset(url: url)
            let track = try #require(try await media.loadTracks(withMediaType: type).first)
            let destination = try #require(composition.addMutableTrack(withMediaType: type, preferredTrackID: kCMPersistentTrackID_Invalid))
            let offset = type == .audio ? 0.25 : 0
            try withExtendedLifetime(media) {
                try destination.insertTimeRange(
                    CMTimeRange(start: .zero, duration: CMTime(seconds: 5 - offset, preferredTimescale: 48_000)),
                    of: track, at: CMTime(seconds: offset, preferredTimescale: 48_000))
            }
        }
        let movie = fixture.root.appendingPathComponent("source.mov")
        // Encode the fixture's float CAF track to AAC, as in a camera movie.
        let session = try #require(AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality))
        session.outputURL = movie
        session.outputFileType = .mov
        try await EditorialAudioMastering.export(session)
        let asset = MediaAsset(originalURL: movie, kind: .video, byteSize: 1, contentHash: "noise-fixture",
            metadata: MediaMetadata(duration: 5, width: 160, height: 90, frameRate: 30, hasAudio: true))
        // A camera mic that starts after its video must retain that offset.
        let expected = [Float](repeating: 0, count: 12_000) + clean.dropLast(12_000)
        let voice = 36_000..<(36_000 + reference.count)
        for detached in [false, true] {
            let item = TimelineItem(assetID: asset.id, kind: .video, sourceDuration: 5, timelineStart: 0,
                timelineDuration: 5, audioAdjustments: .init(volume: 0.8, muted: detached))
            var timeline = Timeline(storyPlanID: UUID(), width: 160, height: 90, frameRate: 30,
                items: [item], originalAudioVolume: 1, audioDucking: .init(enabled: false))
            if detached {
                timeline.audioClips = [TimelineAudioClip(assetID: asset.id, title: "Speech", role: .detached,
                    sourceDuration: 5, timelineStart: 0, timelineDuration: 5, adjustments: .init(volume: 0.8))]
            }
            let originalTimeline = timeline
            let before = try await PlaybackEngine().build(timeline: timeline, assets: [asset])
            let dry = try await decodedAudio(before.composition, mix: before.audioMix)
            if detached { timeline.audioClips?[0].adjustments.noiseReduction = 1 }
            else { timeline.items[0].audioAdjustments?.noiseReduction = 1 }
            #expect(before.updatedAudioMix(from: originalTimeline, to: timeline) == nil,
                    "Noise changes require processed audio, not just a mixer update")
            let preview = try await PlaybackEngine().build(timeline: timeline, assets: [asset], preferStableRealtimePreview: true)
            let live = try await decodedAudio(preview.composition, mix: preview.audioMix)
            let destination = fixture.root.appendingPathComponent("export-\(detached).mp4")
            _ = try await RenderEngine().render(timeline: timeline, assets: [asset], quality: .maximum, destination: destination)
            let exported = try await decodedAudio(AVURLAsset(url: destination), mix: nil)
            try #require(min(dry.count, live.count, exported.count) >= voice.upperBound)
            let baseline = signalToDistortion(expected, dry, range: voice)
            let previewQuality = signalToDistortion(expected, live, range: voice)
            let exportQuality = signalToDistortion(expected, exported, range: voice)
            print("RNNoise \(detached ? "detached" : "embedded"): dry \(baseline), preview \(previewQuality), MP4 \(exportQuality) dB")
            #expect(previewQuality > baseline + 4)
            #expect(exportQuality > baseline + 4)
            #expect(abs(exportQuality - previewQuality) < 1)
        }
    }

    private func decodedAudio(_ asset: AVAsset, mix: AVAudioMix?) async throws -> [Float] {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderAudioMixOutput(audioTracks: try await asset.loadTracks(withMediaType: .audio), audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false
        ])
        output.audioMix = mix
        reader.add(output)
        try #require(reader.startReading())
        defer { if reader.status == .reading { reader.cancelReading() } }
        var samples: [Float] = []
        while let sample = try await MediaSampleReader.next(from: output, reader: reader) {
            let block = try #require(CMSampleBufferGetDataBuffer(sample))
            var values = [Float](repeating: 0, count: CMBlockBufferGetDataLength(block) / 4)
            let status = values.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
            }
            try #require(status == noErr)
            samples.append(contentsOf: values)
        }
        try #require(reader.status == .completed)
        return samples
    }

    private func speech() throws -> [Float] {
        let url = try #require(Bundle.module.url(forResource: "speech", withExtension: "wav", subdirectory: "NoiseReduction"))
        return try read(url)[0]
    }

    private func read(_ url: URL) throws -> [[Float]] { try Self.read(url) }
    private static func read(_ url: URL) throws -> [[Float]] {
        let file = try AVAudioFile(forReading: url)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4_096))
        let channels = try #require(buffer.floatChannelData)
        var result = Array(repeating: [Float](), count: Int(buffer.format.channelCount))
        while file.framePosition < file.length {
            try file.read(into: buffer)
            guard buffer.frameLength > 0 else { break }
            for channel in result.indices {
                result[channel].append(contentsOf: UnsafeBufferPointer(start: channels[channel], count: Int(buffer.frameLength)))
            }
        }
        try #require(result[0].count == file.length, "Read every PCM frame from \(url.lastPathComponent)")
        return result
    }

    private func makeNoise(count: Int, amplitude: Double) -> [Float] {
        var seed: UInt64 = 0x193A_7B92
        return (0..<count).map { index in
            seed = seed &* 6_364_136_223_846_793_005 &+ 1
            let white = Double(seed >> 32) / Double(UInt32.max) * 2 - 1
            let hum = sin(Double(index) * 2 * .pi * 120 / 48_000)
            return Float(amplitude * (white + 0.35 * hum))
        }
    }

    private func rms(_ values: [Float]) -> Double {
        sqrt(values.reduce(0) { $0 + Double($1) * Double($1) } / Double(max(1, values.count)))
    }
    private func correlation(_ lhs: [Float], _ rhs: [Float]) -> Double {
        let dot = zip(lhs, rhs).reduce(0) { $0 + Double($1.0) * Double($1.1) }
        return dot / max(1e-15, rms(lhs) * rms(rhs) * Double(lhs.count))
    }
    private func signalToDistortion(_ clean: [Float], _ processed: [Float], range: Range<Int>) -> Double {
        let power = range.reduce(0) { $0 + Double(clean[$1]) * Double(clean[$1]) }
        let dot = range.reduce(0) { $0 + Double(clean[$1]) * Double(processed[$1]) }
        let gain = dot / max(1e-15, power)
        let error = range.reduce(0) { $0 + pow(Double(processed[$1]) - gain * Double(clean[$1]), 2) }
        return 10 * log10(max(1e-15, gain * gain * power) / max(1e-15, error))
    }

    private struct Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("speech-denoise-\(UUID())")
        init() throws { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
        func url() -> URL { root.appendingPathComponent("\(UUID()).caf") }
        @discardableResult
        func write(_ channels: [[Float]], to destination: URL? = nil) throws -> URL {
            let destination = destination ?? url()
            let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: AVAudioChannelCount(channels.count)))
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(channels[0].count)))
            buffer.frameLength = buffer.frameCapacity
            for channel in channels.indices {
                for index in channels[channel].indices { buffer.floatChannelData![channel][index] = channels[channel][index] }
            }
            try autoreleasepool {
                var settings = format.settings
                settings[AVLinearPCMIsNonInterleaved] = false
                try AVAudioFile(forWriting: destination, settings: settings).write(from: buffer)
            }
            try #require(AVAudioFile(forReading: destination).length == channels[0].count)
            return destination
        }
        func reduce(_ source: URL, amount: Double) async throws -> [[Float]] {
            let output = url()
            try await SpeechNoiseReducer.render(source: source, destination: output, amount: amount)
            return try SpeechNoiseReductionTests.read(output)
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}
