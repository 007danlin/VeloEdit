import Foundation
import AVFoundation
import Testing
@testable import VeloEditCore

@Test func editorialLoudnessUsesKWeightingAndStereoChannelEnergy() throws {
    let tone = (0..<48_000).map { Float(0.1 * sin(2 * Double.pi * 1_000 * Double($0) / 48_000)) }
    var mono = EditorialLoudnessMeter(channels: 1)
    mono.consume(interleaved: tone)
    let monoLUFS = try #require(mono.report().integratedLUFS)
    #expect(abs(monoLUFS - (-23.0)) < 0.15)
    var stereo = EditorialLoudnessMeter(channels: 2)
    stereo.consume(interleaved: tone.flatMap { [$0, $0] })
    #expect(abs(try #require(stereo.report().integratedLUFS) - monoLUFS - 3.0103) < 0.02)
    #expect(abs(try #require(stereo.report().outputLUFS) - (-16)) < 0.02)
}

@Test func editorialLoudnessGatesSilenceAndLimitsIntersamplePeaks() throws {
    var silence = EditorialLoudnessMeter(channels: 1)
    silence.consume(interleaved: [Float](repeating: 0, count: 48_000))
    #expect(silence.report().integratedLUFS == nil)
    #expect(silence.report().appliedGainDB == 0)
    let wave = (0..<48_000).map { Float(0.8 * sin(2 * Double.pi * 12_000 * Double($0) / 48_000 + Double.pi / 4)) }
    var peak = EditorialLoudnessMeter(channels: 1)
    peak.consume(interleaved: wave)
    let report = peak.report()
    let samplePeak = 20 * log10(Double(wave.map(abs).max() ?? 0))
    #expect(try #require(report.truePeakDBTP) > samplePeak + 1.5)
    #expect(try #require(report.outputTruePeakDBTP) <= -1.19)
    var impulse = EditorialLoudnessMeter(channels: 1)
    var samples = [Float](repeating: 0, count: 48_000)
    samples[24_000] = 1
    impulse.consume(interleaved: samples)
    #expect(impulse.report().peakLimited)
    #expect(try #require(impulse.report().outputTruePeakDBTP) <= -1.19)
}

@Test func editorialMasteringPreservesVolumeStepsRampsAndTail() {
    let parameters = AVMutableAudioMixInputParameters()
    parameters.setVolume(0.5, at: .zero)
    parameters.setVolumeRamp(fromStartVolume: 0.3, toEndVolume: 0.1, timeRange: CMTimeRange(start: CMTime(seconds: 2, preferredTimescale: 600), duration: CMTime(seconds: 2, preferredTimescale: 600)))
    parameters.setVolume(0.6, at: CMTime(seconds: 5, preferredTimescale: 600))
    let envelopes = EditorialAudioMastering.envelopes(parameters, duration: 8)
    #expect(abs(envelopes.reduce(0) { $0 + $1.2.duration.seconds } - 8) < 0.0001)
    #expect(envelopes.first?.0 == 0.5)
    #expect(envelopes.contains { abs($0.0 - 0.3) < 0.0001 && abs($0.1 - 0.1) < 0.0001 && abs($0.2.duration.seconds - 2) < 0.0001 })
    #expect(envelopes.last?.1 == 0.6)
}

@Test func editorialMasteringAttenuationCeilingStillProtectsPeaks() throws {
    let composition = AVMutableComposition()
    let quiet = EditorialAudioMasteringReport(integratedLUFS: -32, truePeakDBTP: -15, appliedGainDB: 0,
        outputLUFS: -32, outputTruePeakDBTP: -15, peakLimited: false, measuredFrames: 48_000)
    #expect(EditorialAudioMastering.adjustedMix(composition: composition, mix: nil, duration: 1, measured: quiet, maximumGainDB: 0) == nil)
    let usual = try #require(EditorialAudioMastering.adjustedMix(composition: composition, mix: nil, duration: 1, measured: quiet))
    #expect(usual.1.appliedGainDB == 12)
    var overload = quiet
    overload.outputTruePeakDBTP = 1
    let limited = try #require(EditorialAudioMastering.adjustedMix(composition: composition, mix: nil, duration: 1, measured: overload, maximumGainDB: 0))
    #expect(limited.1.appliedGainDB < 0)
    #expect(try #require(limited.1.outputTruePeakDBTP) <= -1.19)
}

@Test func editorialMasteringChangesTheActualCompositionMix() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("editorial-audio-\(UUID()).caf")
    defer { try? FileManager.default.removeItem(at: url) }
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
    do {
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000))
        buffer.frameLength = 48_000
        for i in 0..<48_000 { buffer.floatChannelData![0][i] = Float(0.5 * sin(2 * Double.pi * 1_000 * Double(i) / 48_000)) }
        try file.write(from: buffer)
    }
    let asset = AVURLAsset(url: url)
    let sourceTrack = try #require(try await asset.loadTracks(withMediaType: .audio).first)
    let composition = AVMutableComposition()
    let track = try #require(composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid))
    try track.insertTimeRange(CMTimeRange(start: .zero, duration: CMTime(seconds: 1, preferredTimescale: 48_000)), of: sourceTrack, at: .zero)
    let parameter = AVMutableAudioMixInputParameters(track: track)
    parameter.setVolume(0.5, at: .zero)
    let mix = AVMutableAudioMix()
    mix.inputParameters = [parameter]
    let first = try await EditorialAudioMastering.apply(composition: composition, mix: mix, duration: 1, cacheURL: nil, signature: "test")
    let second = try await EditorialAudioMastering.apply(composition: composition, mix: first.0, duration: 1, cacheURL: nil, signature: "remeasure")
    let predicted = try #require(first.1?.outputLUFS)
    let measured = try #require(second.1?.integratedLUFS)
    #expect(abs(predicted - measured) < 0.1)
    #expect(try #require(second.1?.truePeakDBTP) <= -1)
}

@Test func editorialMasteringAcceptsTrackShorterThanMovie() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("editorial-staggered-\(UUID()).caf")
    defer { try? FileManager.default.removeItem(at: url) }
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
    do {
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000))
        buffer.frameLength = 48_000
        for i in 0..<48_000 { buffer.floatChannelData![0][i] = Float(0.15 * sin(2 * Double.pi * 440 * Double(i) / 48_000)) }
        try file.write(from: buffer)
    }
    let asset = AVURLAsset(url: url)
    let source = try #require(try await asset.loadTracks(withMediaType: .audio).first)
    let composition = AVMutableComposition()
    let first = try #require(composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid))
    let sourceRange = try await source.load(.timeRange)
    try first.insertTimeRange(sourceRange, of: source, at: .zero)
    let mastered = try await EditorialAudioMastering.apply(
        composition: composition,
        mix: nil,
        duration: 3,
        cacheURL: nil,
        signature: "staggered-tracks"
    )
    #expect(try #require(mastered.1?.measuredFrames) >= 47_000)
    #expect(mastered.0?.inputParameters.count == 1)
}
