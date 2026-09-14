import Foundation
import AVFoundation
import AudioToolbox
import CoreMedia

actor LocalAudioAnalyzer {
    static func sampleRate(for level: AudioAnalysisLevel) -> Double? {
        switch level {
        case .none: return nil
        case .basic: return 8_000
        case .deep: return 16_000
        }
    }

    func analyze(url: URL, level: AudioAnalysisLevel) async throws -> AudioAnalysisSummary? {
        guard level != .none else { return nil }
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return nil }
        let reader = try AVAssetReader(asset: asset)
        guard let sampleRate = Self.sampleRate(for: level) else { return nil }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? URLError(.cannotDecodeContentData) }

        var sampleCount = 0
        var squaredSum = 0.0
        var peak = 0.0
        var silentSamples = 0
        var zeroCrossings = 0
        var previousSample: Float = 0
        var previousEnvelope = 0.0
        var onsetCount = 0
        var envelopes: [Double] = []
        var onsetEnvelope: [Double] = []
        var featureWindows: [AudioFeatureWindow] = []
        var audioCursor = 0.0
        var resourcePacer = ResourceWorkPacer()
        defer { if reader.status == .reading { reader.cancelReading() } }

        while reader.status == .reading {
            try await resourcePacer.checkpoint()
            guard let buffer = try await MediaSampleReader.next(from: output, reader: reader) else { break }
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let byteCount = CMBlockBufferGetDataLength(block)
            guard byteCount >= MemoryLayout<Float>.size else { continue }
            var data = Data(count: byteCount)
            let copyStatus = data.withUnsafeMutableBytes { bytes in
                guard let destination = bytes.baseAddress else { return kCMBlockBufferBadLengthParameterErr }
                return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: byteCount, destination: destination)
            }
            guard copyStatus == kCMBlockBufferNoErr else { continue }
            var localPeakResult = 0.0
            var localZeroCrossings = 0
            var localSampleCount = 0
            let envelope: Double = data.withUnsafeBytes { bytes in
                let samples = bytes.bindMemory(to: Float.self)
                guard !samples.isEmpty else { return 0 }
                var localPeak = 0.0
                var localSquared = 0.0
                for value in samples {
                    let normalized = min(1, abs(Double(value)))
                    localPeak = max(localPeak, normalized)
                    localSquared += normalized * normalized
                    if normalized < 0.012 { silentSamples += 1 }
                    if (value >= 0) != (previousSample >= 0), abs(value - previousSample) > 0.01 {
                        zeroCrossings += 1
                        localZeroCrossings += 1
                    }
                    previousSample = value
                }
                localPeakResult = localPeak
                localSampleCount = samples.count
                sampleCount += samples.count
                squaredSum += localSquared
                peak = max(peak, localPeak)
                return sqrt(localSquared / Double(samples.count))
            }
            let rise = max(0, envelope - previousEnvelope)
            if rise > 0.075 { onsetCount += 1 }
            let windowDuration = Double(localSampleCount) / sampleRate
            let zcr = localSampleCount == 0 ? 0 : Double(localZeroCrossings) / Double(localSampleCount)
            let onsetStrength = min(1, rise * 4.2 + max(0, localPeakResult - envelope) * 0.32)
            featureWindows.append(AudioFeatureWindow(
                startTime: audioCursor,
                duration: windowDuration,
                rms: envelope,
                peak: localPeakResult,
                zeroCrossingRate: zcr,
                onsetStrength: onsetStrength,
                spectralFlux: min(1, abs(envelope - previousEnvelope) * 3.6)
            ))
            audioCursor += windowDuration
            onsetEnvelope.append(onsetStrength)
            previousEnvelope = 0.82 * previousEnvelope + 0.18 * envelope
            envelopes.append(envelope)
        }
        if reader.status == .failed { throw reader.error ?? URLError(.cannotDecodeContentData) }
        guard sampleCount > 0 else { return nil }

        let duration = Double(sampleCount) / sampleRate
        let rms = min(1, sqrt(squaredSum / Double(sampleCount)))
        let silence = Double(silentSamples) / Double(sampleCount)
        let zeroCrossingRate = Double(zeroCrossings) / Double(sampleCount)
        let onsetRate = duration > 0 ? Double(onsetCount) / duration : 0
        let speech = min(1, max(0,
            (1 - abs(zeroCrossingRate - 0.085) / 0.085) * 0.48
            + (1 - silence) * 0.28
            + min(1, onsetRate / 3) * 0.24
        ))
        let music = min(1, max(0,
            (1 - silence) * 0.38
            + min(1, onsetRate / 5) * 0.34
            + min(1, rms / 0.22) * 0.28
        ))
        let clippingPenalty = max(0, (peak - 0.96) / 0.04)
        let quality = min(1, max(0, (1 - silence) * 0.42 + min(1, rms / 0.18) * 0.38 + (1 - clippingPenalty) * 0.20))
        let compactWindows = Self.resampleWindows(featureWindows, count: level == .deep ? 512 : 96)
        let events = level == .deep
            ? DSPAudioEventClassifier().classify(windows: compactWindows, speechProbability: speech, musicProbability: music)
            : []
        let tempoOnsets = Self.resample(onsetEnvelope, count: min(2_048, max(1, onsetEnvelope.count)))
        let tempoWindows = Self.resampleWindows(featureWindows, count: tempoOnsets.count)
        let tempo = level == .deep ? Self.estimateTempo(onsets: tempoOnsets, windows: tempoWindows, fallback: nil) : nil

        return AudioAnalysisSummary(
            analyzedDuration: duration,
            meanVolume: rms,
            peakVolume: peak,
            silenceRatio: silence,
            speechProbability: level == .deep ? speech : 0,
            musicProbability: level == .deep ? music : 0,
            onsetRate: level == .deep ? onsetRate : 0,
            originalSoundQuality: quality,
            waveform: Self.resample(envelopes, count: level == .deep ? 256 : 24),
            onsetEnvelope: Self.resample(onsetEnvelope, count: level == .deep ? 256 : 24),
            featureWindows: compactWindows,
            events: events,
            estimatedBPM: tempo?.bpm,
            tempoConfidence: tempo?.confidence
        )
    }

    private static func resample(_ values: [Double], count: Int) -> [Double] {
        guard !values.isEmpty, count > 0 else { return [] }
        if values.count <= count { return values.map { min(1, max(0, $0)) } }
        return (0..<count).map { index in
            let lower = index * values.count / count
            let upper = max(lower + 1, (index + 1) * values.count / count)
            return min(1, values[lower..<min(values.count, upper)].reduce(0, +) / Double(max(1, upper - lower)))
        }
    }

    private static func resampleWindows(_ values: [AudioFeatureWindow], count: Int) -> [AudioFeatureWindow] {
        guard values.count > count, count > 0 else { return values }
        return (0..<count).map { index in
            let lower = index * values.count / count
            let upper = max(lower + 1, (index + 1) * values.count / count)
            let slice = values[lower..<min(values.count, upper)]
            let divisor = Double(max(1, slice.count))
            return AudioFeatureWindow(
                startTime: slice.first?.startTime ?? 0,
                duration: slice.reduce(0) { $0 + $1.duration },
                rms: slice.reduce(0) { $0 + $1.rms } / divisor,
                peak: slice.map(\.peak).max() ?? 0,
                zeroCrossingRate: slice.reduce(0) { $0 + $1.zeroCrossingRate } / divisor,
                onsetStrength: slice.map(\.onsetStrength).max() ?? 0,
                spectralFlux: slice.reduce(0) { $0 + $1.spectralFlux } / divisor
            )
        }
    }

    private static func estimateTempo(onsets: [Double], windows: [AudioFeatureWindow], fallback: Double?) -> (bpm: Double, confidence: Double)? {
        guard onsets.count >= 12 else { return fallback.map { ($0, 0.16) } }
        let step = windows.reduce(0) { $0 + $1.duration } / Double(max(1, windows.count))
        guard step > 0.001 else { return fallback.map { ($0, 0.16) } }
        let mean = onsets.reduce(0, +) / Double(onsets.count)
        let centered = onsets.map { $0 - mean }
        var best: (bpm: Double, correlation: Double)?
        for bpm in stride(from: 55.0, through: 190.0, by: 0.5) {
            let lag = max(1, Int(((60 / bpm) / step).rounded()))
            guard lag < centered.count - 2 else { continue }
            var correlation = 0.0
            var energy = 0.0
            for index in lag..<centered.count {
                correlation += centered[index] * centered[index - lag]
                energy += centered[index] * centered[index]
            }
            let normalized = energy > 0.000_001 ? correlation / energy : 0
            if best.map({ normalized > $0.correlation }) ?? true { best = (bpm, normalized) }
        }
        guard var best else { return fallback.map { ($0, 0.16) } }
        if best.bpm < 72, best.correlation > 0.20 { best.bpm *= 2 }
        return (min(240, max(40, best.bpm)), min(1, max(0.08, best.correlation)))
    }
}
