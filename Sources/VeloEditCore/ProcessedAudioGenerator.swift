import Foundation
import AVFoundation
import Darwin

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
        destination: URL,
        cacheDirectory: URL? = nil
    ) async throws -> URL {
        try Task.checkCancellation()
        if let cacheDirectory {
            let identity = try Self.cacheIdentity(sourceURL: sourceURL, sourceStart: sourceStart,
                                                 sourceDuration: sourceDuration, adjustments: adjustments)
            let cached = cacheDirectory.appendingPathComponent("audio-\(identity).caf")
            if Self.isUsableCachedAudio(cached, duration: sourceDuration) { return cached }
            try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            let temporary = cacheDirectory.appendingPathComponent(".audio-\(UUID().uuidString).partial.caf")
            defer { try? FileManager.default.removeItem(at: temporary) }
            _ = try await generate(sourceURL: sourceURL, sourceStart: sourceStart, sourceDuration: sourceDuration,
                                   adjustments: adjustments, destination: temporary)
            try Task.checkCancellation()
            guard Self.isUsableCachedAudio(temporary, duration: sourceDuration) else {
                throw DerivedMediaError.exportFailed("Обработанный звук неполный или повреждён")
            }
            // Atomic replacement also handles two overlapping preview builds.
            // Existing players retain the old inode until they release it.
            guard rename(temporary.path, cached.path) == 0 else {
                throw DerivedMediaError.exportFailed("Не удалось сохранить кэш обработанного звука")
            }
            return cached
        }
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
        let sourceMixer = AVAudioMixerNode()
        // Audio Units do not all accept a camera/voice recording's native
        // layout (for example mono 16 kHz). AVAudioEngine.connect raises an
        // Objective-C exception for unsupported formats, bypassing Swift error
        // handling. Convert at a mixer before entering the effect chain.
        guard let renderFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2) else {
            throw DerivedMediaError.cannotCreateDestination
        }
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
        engine.attach(sourceMixer)
        engine.attach(equalizer)
        engine.attach(reverb)
        engine.attach(delay)
        engine.attach(distortion)
        engine.connect(player, to: sourceMixer, format: input.processingFormat)
        engine.connect(sourceMixer, to: equalizer, format: renderFormat)
        engine.connect(equalizer, to: reverb, format: renderFormat)
        engine.connect(reverb, to: delay, format: renderFormat)
        engine.connect(delay, to: distortion, format: renderFormat)
        engine.connect(distortion, to: engine.mainMixerNode, format: renderFormat)
        try engine.enableManualRenderingMode(
            .offline,
            format: renderFormat,
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
        scheduleForOfflineRendering(input, on: player)
        player.play()
        var stalledRenderAttempts = 0
        let outputLength = AVAudioFramePosition((Double(input.length) * renderFormat.sampleRate / input.processingFormat.sampleRate).rounded())
        while engine.manualRenderingSampleTime < outputLength {
            if Task.isCancelled {
                player.stop()
                engine.stop()
                throw CancellationError()
            }
            let remaining = outputLength - engine.manualRenderingSampleTime
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

    static func cacheIdentity(sourceURL: URL, sourceStart: Double, sourceDuration: Double,
                              adjustments: AudioAdjustments) throws -> String {
        let resolvedURL = sourceURL.resolvingSymlinksInPath()
        let values = try FileManager.default.attributesOfItem(atPath: resolvedURL.path)
        return ProductionCacheIdentity.hash([
            "processed-audio-v1-48k-stereo", resolvedURL.path,
            String((values[.size] as? NSNumber)?.int64Value ?? 0),
            String(((values[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0).bitPattern),
            String(sourceStart.bitPattern), String(sourceDuration.bitPattern),
            String((adjustments.noiseReduction ?? 0).bitPattern), (adjustments.eqPreset ?? .flat).rawValue,
            String(adjustments.normalize ?? false), (adjustments.effect ?? .none).rawValue
        ])
    }

    private static func isUsableCachedAudio(_ url: URL, duration: Double) -> Bool {
        guard let file = try? AVAudioFile(forReading: url), file.length > 0,
              Double(file.length) / file.processingFormat.sampleRate <= max(0.05, duration) + 0.15,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 32) else { return false }
        // Read the tail too: a valid CAF header can outlive a truncated payload.
        file.framePosition = max(0, file.length - 32)
        do { try file.read(into: buffer); return buffer.frameLength > 0 }
        catch { return false }
    }

    /// The async AVAudioPlayerNode overload completes only after playback.
    /// Offline rendering must schedule synchronously before `play()` and then
    /// drive the engine with `renderOffline` below.
    private func scheduleForOfflineRendering(_ file: AVAudioFile, on player: AVAudioPlayerNode) {
        player.scheduleFile(file, at: nil, completionHandler: nil)
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
            try Task.checkCancellation()
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
