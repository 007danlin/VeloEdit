import Foundation
import AVFoundation

/// Creates a disposable PCM intermediate for adjustments AVAudioMix cannot
/// express. Originals are only read. Clip gain and fades remain non-destructive
/// AVAudioMix ramps after this processor.
public actor ProcessedAudioGenerator {
    public init() {}

    public static func needsRender(_ value: AudioAdjustments) -> Bool {
        (value.noiseReduction ?? 0) > 0.0001 || (value.eqPreset ?? .flat) != .flat ||
        (value.normalize ?? false) || (value.effect ?? AudioEffect.none) != AudioEffect.none
    }

    public func generate(
        sourceURL: URL,
        sourceStart: Double,
        sourceDuration: Double,
        adjustments: AudioAdjustments,
        destination: URL
    ) async throws -> URL {
        let trimmed = FileManager.default.temporaryDirectory
            .appendingPathComponent("veloedit-audio-source-\(UUID().uuidString)")
            .appendingPathExtension("m4a")
        defer { try? FileManager.default.removeItem(at: trimmed) }
        try await extractAudio(
            sourceURL: sourceURL,
            sourceStart: sourceStart,
            sourceDuration: sourceDuration,
            destination: trimmed
        )
        try? FileManager.default.removeItem(at: destination)

        let input = try AVAudioFile(forReading: trimmed)
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let equalizer = AVAudioUnitEQ(numberOfBands: 5)
        let reverb = AVAudioUnitReverb()
        let delay = AVAudioUnitDelay()
        let distortion = AVAudioUnitDistortion()
        let normalizationGain = adjustments.normalize == true ? try normalizationGain(for: input) : 0
        configure(
            equalizer,
            reverb: reverb,
            delay: delay,
            distortion: distortion,
            adjustments: adjustments,
            normalizationGain: normalizationGain
        )

        engine.attach(player)
        engine.attach(equalizer)
        engine.attach(reverb)
        engine.attach(delay)
        engine.attach(distortion)
        engine.connect(player, to: equalizer, format: input.processingFormat)
        engine.connect(equalizer, to: reverb, format: input.processingFormat)
        engine.connect(reverb, to: delay, format: input.processingFormat)
        engine.connect(delay, to: distortion, format: input.processingFormat)
        engine.connect(distortion, to: engine.mainMixerNode, format: input.processingFormat)
        try engine.enableManualRenderingMode(
            .offline,
            format: input.processingFormat,
            maximumFrameCount: 4_096
        )
        let output = try AVAudioFile(
            forWriting: destination,
            settings: engine.manualRenderingFormat.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: engine.manualRenderingFormat,
            frameCapacity: engine.manualRenderingMaximumFrameCount
        ) else { throw DerivedMediaError.cannotCreateDestination }

        try engine.start()
        player.scheduleFile(input, at: nil, completionHandler: nil)
        player.play()
        var stalledRenderAttempts = 0
        while engine.manualRenderingSampleTime < input.length {
            if Task.isCancelled {
                player.stop()
                engine.stop()
                throw CancellationError()
            }
            let remaining = input.length - engine.manualRenderingSampleTime
            let frames = AVAudioFrameCount(min(Int64(engine.manualRenderingMaximumFrameCount), remaining))
            switch try engine.renderOffline(frames, to: buffer) {
            case .success:
                stalledRenderAttempts = 0
                try output.write(from: buffer)
            case .cannotDoInCurrentContext, .insufficientDataFromInputNode:
                stalledRenderAttempts += 1
                guard stalledRenderAttempts < 2_000 else {
                    throw DerivedMediaError.exportFailed("Обработка звука не получает аудиоданные")
                }
                await Task.yield()
            case .error:
                throw DerivedMediaError.exportFailed("Не удалось обработать звук")
            @unknown default:
                throw DerivedMediaError.exportFailed("Неизвестная ошибка обработки звука")
            }
        }
        player.stop()
        engine.stop()
        engine.disableManualRenderingMode()
        return destination
    }

    private func extractAudio(sourceURL: URL, sourceStart: Double, sourceDuration: Double, destination: URL) async throws {
        try? FileManager.default.removeItem(at: destination)
        let asset = AVURLAsset(url: sourceURL)
        guard !(try await asset.loadTracks(withMediaType: .audio)).isEmpty,
              let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw DerivedMediaError.exportUnavailable
        }
        session.outputURL = destination
        session.outputFileType = .m4a
        session.timeRange = CMTimeRange(
            start: CMTime(seconds: max(0, sourceStart), preferredTimescale: 600),
            duration: CMTime(seconds: max(0.05, sourceDuration), preferredTimescale: 600)
        )
        await session.export()
        guard session.status == .completed else {
            throw DerivedMediaError.exportFailed(session.error?.localizedDescription ?? "Не удалось извлечь звук")
        }
    }

    private func normalizationGain(for input: AVAudioFile) throws -> Float {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 8_192) else { return 0 }
        var sumSquares = 0.0
        var peak = 0.0
        var sampleCount = 0
        input.framePosition = 0
        while input.framePosition < input.length {
            try input.read(into: buffer)
            guard let channels = buffer.floatChannelData else { break }
            for channel in 0..<Int(buffer.format.channelCount) {
                for frame in 0..<Int(buffer.frameLength) {
                    let sample = Double(channels[channel][frame])
                    sumSquares += sample * sample
                    peak = max(peak, abs(sample))
                    sampleCount += 1
                }
            }
        }
        input.framePosition = 0
        guard sampleCount > 0, peak > 0.000_001 else { return 0 }
        let rms = sqrt(sumSquares / Double(sampleCount))
        let targetRMS = pow(10.0, -18.0 / 20.0)
        let rmsGain = targetRMS / max(rms, 0.000_001)
        let peakLimitedGain = 0.95 / peak
        let linearGain = min(4, max(0.25, min(rmsGain, peakLimitedGain)))
        return Float(20 * log10(linearGain))
    }

    private func configure(
        _ equalizer: AVAudioUnitEQ,
        reverb: AVAudioUnitReverb,
        delay: AVAudioUnitDelay,
        distortion: AVAudioUnitDistortion,
        adjustments: AudioAdjustments,
        normalizationGain: Float
    ) {
        let preset = adjustments.eqPreset ?? .flat
        let noiseReduction = adjustments.noiseReduction ?? 0
        let effect = adjustments.effect ?? AudioEffect.none
        equalizer.globalGain = normalizationGain
        equalizer.bands.forEach { $0.bypass = true }
        let highPass = equalizer.bands[0]
        highPass.filterType = .highPass
        highPass.frequency = Float(55 + min(max(0, noiseReduction), 1) * 65)
        highPass.bandwidth = 0.6
        highPass.bypass = noiseReduction < 0.001 && preset != .voice

        if noiseReduction > 0.001 {
            let lowPass = equalizer.bands[4]
            lowPass.filterType = .lowPass
            lowPass.frequency = Float(18_000 - min(max(0, noiseReduction), 1) * 7_000)
            lowPass.bandwidth = 0.7
            lowPass.bypass = false
        }

        func band(_ index: Int, frequency: Float, gain: Float, bandwidth: Float = 1) {
            let value = equalizer.bands[index]
            value.filterType = .parametric
            value.frequency = frequency
            value.gain = gain
            value.bandwidth = bandwidth
            value.bypass = abs(gain) < 0.01
        }
        switch preset {
        case .flat:
            break
        case .voice:
            band(1, frequency: 220, gain: -2.5)
            band(2, frequency: 2_800, gain: 3.5, bandwidth: 0.8)
            band(3, frequency: 7_500, gain: 1.5)
        case .music:
            band(1, frequency: 120, gain: 1.8)
            band(2, frequency: 2_200, gain: 1.2)
            band(3, frequency: 9_000, gain: 1.5)
        case .bassReduction:
            band(1, frequency: 140, gain: -6, bandwidth: 0.7)
        case .presence:
            band(2, frequency: 3_200, gain: 4, bandwidth: 0.65)
        }

        reverb.bypass = true
        delay.bypass = true
        distortion.bypass = true
        switch effect {
        case .none:
            break
        case .voiceEnhance:
            band(1, frequency: 180, gain: -2)
            band(2, frequency: 2_700, gain: 4, bandwidth: 0.7)
            band(3, frequency: 8_000, gain: 2)
        case .telephone:
            let highPass = equalizer.bands[0]
            highPass.frequency = 300
            highPass.bypass = false
            let lowPass = equalizer.bands[4]
            lowPass.filterType = .lowPass
            lowPass.frequency = 3_400
            lowPass.bandwidth = 0.5
            lowPass.bypass = false
            band(2, frequency: 1_800, gain: 4, bandwidth: 0.8)
        case .muffled:
            let lowPass = equalizer.bands[4]
            lowPass.filterType = .lowPass
            lowPass.frequency = 2_200
            lowPass.bandwidth = 0.6
            lowPass.bypass = false
        case .echo:
            delay.delayTime = 0.24
            delay.feedback = 28
            delay.lowPassCutoff = 8_000
            delay.wetDryMix = 34
            delay.bypass = false
        case .room:
            reverb.loadFactoryPreset(.mediumRoom)
            reverb.wetDryMix = 28
            reverb.bypass = false
        case .robot:
            distortion.loadFactoryPreset(.speechWaves)
            distortion.wetDryMix = 48
            distortion.bypass = false
        }
    }

}
