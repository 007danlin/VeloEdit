import Foundation
@preconcurrency import AVFoundation
import Accelerate

public struct EditorialAudioMasteringReport: Codable, Hashable, Sendable {
    public var integratedLUFS: Double?
    public var truePeakDBTP: Double?
    public var appliedGainDB: Double
    public var outputLUFS: Double?
    public var outputTruePeakDBTP: Double?
    public var peakLimited: Bool
    public var measuredFrames: Int
}

/// 48 kHz, mono/stereo BS.1770-5 Annexes 1 and 2. The decoder explicitly
/// downmixes to stereo before this meter, so no surround/LFE weights are needed.
/// Coefficients: https://www.itu.int/rec/R-REC-BS.1770-5-202311-I/en
public struct EditorialLoudnessMeter: Sendable {
    private struct Biquad: Sendable {
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
        mutating func filter(_ samples: [Double], coefficients: [Double]) -> [Double] {
            guard !samples.isEmpty else { return [] }
            let input = [x2, x1] + samples
            var output = [y2, y1] + Array(repeating: 0.0, count: samples.count)
            vDSP_deq22D(input, 1, coefficients, &output, 1, vDSP_Length(samples.count))
            x2 = input[input.count - 2]; x1 = input[input.count - 1]
            y2 = output[output.count - 2]; y1 = output[output.count - 1]
            return Array(output.dropFirst(2))
        }
    }
    private static let phases: [[Double]] = [
        [0.001708984375,0.010986328125,-0.0196533203125,0.033203125,-0.0594482421875,0.1373291015625,0.97216796875,-0.102294921875,0.047607421875,-0.026611328125,0.014892578125,-0.00830078125],
        [-0.0291748046875,0.029296875,-0.0517578125,0.089111328125,-0.16650390625,0.465087890625,0.77978515625,-0.2003173828125,0.1015625,-0.0582275390625,0.0330810546875,-0.0189208984375],
        [-0.0189208984375,0.0330810546875,-0.0582275390625,0.1015625,-0.2003173828125,0.77978515625,0.465087890625,-0.16650390625,0.089111328125,-0.0517578125,0.029296875,-0.0291748046875],
        [-0.00830078125,0.014892578125,-0.026611328125,0.047607421875,-0.102294921875,0.97216796875,0.1373291015625,-0.0594482421875,0.033203125,-0.0196533203125,0.010986328125,0.001708984375]
    ]
    private var shelf: [Biquad]
    private var highpass: [Biquad]
    private var history: [[Double]]
    private var energy = Array(repeating: 0.0, count: 19_200)
    private var blockEnergies: [Double] = []
    private var energySum = 0.0, peak = 0.0
    private var frameCount = 0
    private let channels: Int
    public init(channels: Int = 2) {
        self.channels = min(2, max(1, channels))
        shelf = Array(repeating: Biquad(), count: self.channels)
        highpass = shelf
        history = Array(repeating: Array(repeating: 0, count: 11), count: self.channels)
    }
    public mutating func consume(interleaved samples: [Float]) {
        let count = samples.count / channels
        guard count > 0 else { return }
        var frameEnergies = [Double](repeating: 0, count: count)
        for channel in 0..<channels {
            var raw = [Double](repeating: 0, count: count)
            samples.withUnsafeBufferPointer { buffer in
                vDSP_vspdp(buffer.baseAddress! + channel, vDSP_Stride(channels), &raw, 1, vDSP_Length(count))
            }
            var localPeak = 0.0
            vDSP_maxmgvD(raw, 1, &localPeak, vDSP_Length(count))
            peak = max(peak, localPeak)
            let padded = history[channel] + raw
            var interpolated = [Double](repeating: 0, count: count)
            for phase in Self.phases {
                // Sliding dot products use reversed coefficients: newest input
                // is the final element of each 12-sample convolution window.
                let reversed = Array(phase.reversed())
                vDSP_convD(padded, 1, reversed, 1, &interpolated, 1, vDSP_Length(count), 12)
                vDSP_maxmgvD(interpolated, 1, &localPeak, vDSP_Length(count))
                peak = max(peak, localPeak)
            }
            history[channel] = Array(padded.suffix(11))
            let weighted = shelf[channel].filter(raw, coefficients: [1.53512485958697, -2.69169618940638, 1.19839281085285, -1.69065929318241, 0.73248077421585])
            let high = highpass[channel].filter(weighted, coefficients: [1, -2, 1, -1.99004745483398, 0.99007225036621])
            var squared = [Double](repeating: 0, count: count)
            vDSP_vsqD(high, 1, &squared, 1, vDSP_Length(count))
            // vDSP supports in-place addition for equal-sized vectors.
            frameEnergies.withUnsafeMutableBufferPointer { accumulator in
                vDSP_vaddD(accumulator.baseAddress!, 1, squared, 1, accumulator.baseAddress!, 1, vDSP_Length(count))
            }
        }
        for frameEnergy in frameEnergies {
            let cursor = frameCount % 19_200
            energySum += frameEnergy - energy[cursor]
            energy[cursor] = frameEnergy
            frameCount += 1
            if frameCount >= 19_200 && (frameCount - 19_200) % 4_800 == 0 { blockEnergies.append(max(0, energySum / 19_200)) }
        }
    }
    public func report(maximumGainDB: Double = 12) -> EditorialAudioMasteringReport {
        func lufs(_ energy: Double) -> Double { -0.691 + 10 * log10(max(1e-15, energy)) }
        let absolute = blockEnergies.filter { lufs($0) > -70 }
        let relative = absolute.isEmpty ? -70 : lufs(absolute.reduce(0, +) / Double(absolute.count)) - 10
        let gated = absolute.filter { lufs($0) > relative }
        let loudness = gated.isEmpty ? nil : lufs(gated.reduce(0, +) / Double(gated.count))
        var flushed = self
        flushed.consume(interleaved: Array(repeating: Float(0), count: channels * 12))
        let truePeak = flushed.peak > 1e-12 ? 20 * log10(flushed.peak) : nil
        // 0.2 dB guard margin for finite interpolation and final encoding.
        let peakGain = truePeak.map { -1.2 - $0 } ?? 0
        let desired = loudness.map { min(maximumGainDB, -16 - $0) } ?? 0
        let gain = min(desired, peakGain)
        return .init(integratedLUFS: loudness, truePeakDBTP: truePeak, appliedGainDB: gain, outputLUFS: loudness.map { $0 + gain }, outputTruePeakDBTP: truePeak.map { $0 + gain }, peakLimited: gain + 0.01 < desired, measuredFrames: frameCount)
    }
}

public enum EditorialAudioMastering {
    private final class ExportCompletion: @unchecked Sendable {
        private let lock = NSLock()
        private var completed = false
        private let continuation: CheckedContinuation<Void, Error>

        init(_ continuation: CheckedContinuation<Void, Error>) { self.continuation = continuation }

        func resume(_ result: Result<Void, Error>) {
            lock.lock()
            guard !completed else { lock.unlock(); return }
            completed = true
            lock.unlock()
            continuation.resume(with: result)
        }
    }

    private final class ExportSessionBox: @unchecked Sendable {
        let value: AVAssetExportSession
        init(_ value: AVAssetExportSession) { self.value = value }
    }

    /// Some MediaToolbox versions can leave an export continuation suspended
    /// forever after the encoder has stopped making progress. Bound the wait;
    /// a timed-out variant is rejected and can never block the whole director.
    static func export(_ session: AVAssetExportSession, timeout: TimeInterval = 45) async throws {
        // Cooling precedes the encoder timeout. AVAssetExportSession cannot
        // be paused once submitted; defer new passes at their safe boundary.
        var resourcePacer = ResourceWorkPacer()
        try await resourcePacer.checkpoint()
        try await withCheckedThrowingContinuation { continuation in
            let completion = ExportCompletion(continuation)
            let box = ExportSessionBox(session)
            box.value.exportAsynchronously {
                if box.value.status == .completed {
                    completion.resume(.success(()))
                } else {
                    completion.resume(.failure(box.value.error ?? URLError(.cannotDecodeContentData)))
                }
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                box.value.cancelExport()
                completion.resume(.failure(URLError(.timedOut)))
            }
        }
    }

    public static func apply(composition: AVComposition, mix: AVAudioMix?, videoComposition: AVVideoComposition? = nil, duration: Double, cacheURL: URL?, signature: String) async throws -> (AVAudioMix?, EditorialAudioMasteringReport?) {
        guard !composition.tracks(withMediaType: .audio).isEmpty else { return (mix, nil) }
        try Task.checkCancellation()
        let effectiveMix: AVAudioMix = mix ?? {
            let unity = AVMutableAudioMix()
            unity.inputParameters = composition.tracks(withMediaType: .audio).map {
                AVMutableAudioMixInputParameters(track: $0)
            }
            return unity
        }()
        let cache = cacheURL?.appendingPathComponent("Mastering-" + EditorialIdentity.hash("bs1770-v4-rendered-audio|" + signature) + ".json")
        let report: EditorialAudioMasteringReport
        if let cache, let data = try? Data(contentsOf: cache), let cached = try? JSONDecoder().decode(EditorialAudioMasteringReport.self, from: data) {
            report = cached
        } else {
            // AVAssetReaderAudioMixOutput can trap inside AudioToolbox when it
            // directly decodes a multi-track AVComposition. A video project
            // therefore gets a real encoded MP4 measurement pass; audio-only
            // callers use the cheaper M4A path.
            let directory = cacheURL?.appendingPathComponent("MasteringAudio")
                ?? FileManager.default.temporaryDirectory.appendingPathComponent("VeloEdit-MasteringAudio")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let hasVideo = !composition.tracks(withMediaType: .video).isEmpty
            let audioURL = directory.appendingPathComponent(EditorialIdentity.hash("mix-v4|" + signature) + (hasVideo ? ".mp4" : ".m4a"))
            if !FileManager.default.fileExists(atPath: audioURL.path) {
                let range = CMTimeRange(start: .zero, duration: CMTime(seconds: max(0.05, duration), preferredTimescale: 48_000))
                let exportAsset: AVAsset
                let exportMix: AVAudioMix
                let preset: String
                let fileType: AVFileType
                if hasVideo {
                    exportAsset = composition
                    exportMix = effectiveMix
                    preset = AVAssetExportPresetHighestQuality
                    fileType = .mp4
                } else {
                    let audioComposition = AVMutableComposition()
                    var remappedTrackIDs: [CMPersistentTrackID: CMPersistentTrackID] = [:]
                    for source in composition.tracks(withMediaType: .audio) {
                        let available = CMTimeRangeGetIntersection(source.timeRange, otherRange: range)
                        guard available.duration.isNumeric, available.duration > .zero,
                              let destination = audioComposition.addMutableTrack(withMediaType: .audio, preferredTrackID: source.trackID) else { continue }
                        do {
                            try destination.insertTimeRange(available, of: source, at: available.start)
                        } catch {
                            let value = error as NSError
                            throw EditorialGenerationError.unsatisfiedIntent(
                                "Audio mastering copy track \(source.trackID) range \(available.start.seconds)...\(available.end.seconds): \(value.domain) \(value.code): \(value.localizedDescription)"
                            )
                        }
                        remappedTrackIDs[source.trackID] = destination.trackID
                    }
                    guard !audioComposition.tracks(withMediaType: .audio).isEmpty else { throw URLError(.cannotDecodeContentData) }
                    let sourceParameters = Dictionary(uniqueKeysWithValues: effectiveMix.inputParameters.map { ($0.trackID, $0) })
                    let remappedMix = AVMutableAudioMix()
                    remappedMix.inputParameters = remappedTrackIDs.map { oldID, newID in
                        let parameters = AVMutableAudioMixInputParameters()
                        parameters.trackID = newID
                        if let original = sourceParameters[oldID] {
                            parameters.audioTimePitchAlgorithm = original.audioTimePitchAlgorithm
                            for envelope in envelopes(original, duration: duration) {
                                parameters.setVolumeRamp(fromStartVolume: envelope.0, toEndVolume: envelope.1, timeRange: envelope.2)
                            }
                        }
                        return parameters
                    }
                    exportAsset = audioComposition
                    exportMix = remappedMix
                    preset = AVAssetExportPresetAppleM4A
                    fileType = .m4a
                }
                guard let session = AVAssetExportSession(asset: exportAsset, presetName: preset) else { throw URLError(.cannotDecodeContentData) }
                try? FileManager.default.removeItem(at: audioURL)
                session.outputURL = audioURL
                session.outputFileType = fileType
                session.audioMix = exportMix
                if hasVideo { session.videoComposition = videoComposition }
                session.timeRange = range
                do {
                    try await export(session)
                } catch {
                    try? FileManager.default.removeItem(at: audioURL)
                    let value = error as NSError
                    let reason = value.userInfo[NSLocalizedFailureReasonErrorKey] as? String ?? ""
                    let underlying = value.userInfo[NSUnderlyingErrorKey] as? NSError
                    throw EditorialGenerationError.unsatisfiedIntent(
                        "Audio mastering export: \(value.domain) \(value.code): \(value.localizedDescription) \(reason)" +
                        (underlying.map { " [\($0.domain) \($0.code)]" } ?? "")
                    )
                }
            }
            guard let measured = try await EditorialDeliveryVerifier.measureEncodedAudio(asset: AVURLAsset(url: audioURL)),
                  let loudness = measured.outputLUFS, let peak = measured.outputTruePeakDBTP else {
                throw URLError(.cannotDecodeContentData)
            }
            let maximum = maximumEnvelopeVolume(mix: effectiveMix, duration: duration)
            let maximumGain = min(12, -20 * log10(max(0.001, maximum)))
            let desired = min(maximumGain, EditorialLoudnessPolicy.targetLUFS - loudness)
            let peakGain = -1.2 - peak
            let gain = min(desired, peakGain)
            report = .init(integratedLUFS: loudness, truePeakDBTP: peak, appliedGainDB: gain, outputLUFS: loudness + gain, outputTruePeakDBTP: peak + gain, peakLimited: gain + 0.01 < desired, measuredFrames: measured.measuredFrames)
            if let cache { try? JSONEncoder().encode(report).write(to: cache, options: .atomic) }
        }
        try Task.checkCancellation()
        let mastered = AVMutableAudioMix()
        let factor = Float(pow(10, report.appliedGainDB / 20))
        let originals = effectiveMix.inputParameters
        mastered.inputParameters = originals.map { original in
            let parameters = AVMutableAudioMixInputParameters()
            parameters.trackID = original.trackID
            parameters.audioTimePitchAlgorithm = original.audioTimePitchAlgorithm
            for envelope in envelopes(original, duration: duration) {
                parameters.setVolumeRamp(fromStartVolume: envelope.0 * factor, toEndVolume: envelope.1 * factor, timeRange: envelope.2)
            }
            return parameters
        }
        return (mastered, report)
    }
    static func envelopes(_ parameters: AVAudioMixInputParameters, duration: Double) -> [(Float, Float, CMTimeRange)] {
        var result: [(Float, Float, CMTimeRange)] = []
        var cursor = 0.0, query = 0.0
        var held: Float = 1
        func append(_ a: Float, _ b: Float, from: Double, to: Double) {
            guard to > from else { return }
            result.append((a, b, CMTimeRange(start: CMTime(seconds: from, preferredTimescale: 48_000), end: CMTime(seconds: to, preferredTimescale: 48_000))))
        }
        for _ in 0..<10_000 {
            guard cursor < duration else { break }
            var a: Float = held, b: Float = held
            var range = CMTimeRange.zero
            let found = parameters.getVolumeRamp(for: CMTime(seconds: query, preferredTimescale: 48_000), startVolume: &a, endVolume: &b, timeRange: &range)
            guard found else { append(held, held, from: cursor, to: duration); break }
            let start = max(cursor, min(duration, range.start.seconds))
            append(held, held, from: cursor, to: start)
            let rawEnd = range.end.seconds
            let end = rawEnd.isFinite ? min(duration, rawEnd) : duration
            if end > start {
                let rampLength = max(0.000001, range.duration.seconds)
                let startFraction = ((start - range.start.seconds) / rampLength).clamped01
                let endFraction = ((end - range.start.seconds) / rampLength).clamped01
                append(a + (b - a) * Float(startFraction), a + (b - a) * Float(endFraction), from: start, to: end)
            }
            held = b
            cursor = max(start, end)
            query = max(query + 1 / 48_000, cursor)
        }
        return result
    }
    private static func maximumEnvelopeVolume(mix: AVAudioMix?, duration: Double) -> Double {
        guard let mix else { return 1 }
        return Double(mix.inputParameters.flatMap { envelopes($0, duration: duration) }.reduce(Float(0)) { max($0, $1.0, $1.1) })
    }

    /// Builds the second-pass mix from an actual encoded first-pass meter.
    /// The returned report is predictive only; delivery verification measures
    /// the second encoded file again before it can pass production.
    static func adjustedMix(composition: AVAsset, mix: AVAudioMix?, duration: Double, measured: EditorialAudioMasteringReport, maximumGainDB: Double = 12) -> (AVAudioMix, EditorialAudioMasteringReport)? {
        guard let loudness = measured.outputLUFS ?? measured.integratedLUFS,
              let peak = measured.outputTruePeakDBTP ?? measured.truePeakDBTP else { return nil }
        let effectiveMix: AVAudioMix = mix ?? {
            let unity = AVMutableAudioMix()
            unity.inputParameters = composition.tracks(withMediaType: .audio).map { AVMutableAudioMixInputParameters(track: $0) }
            return unity
        }()
        let desired = min(maximumGainDB, EditorialLoudnessPolicy.targetLUFS - loudness)
        let gain = min(desired, -1.2 - peak)
        guard gain.isFinite, abs(gain) >= 0.05 else { return nil }
        let factor = Float(pow(10, gain / 20))
        let mastered = AVMutableAudioMix()
        mastered.inputParameters = effectiveMix.inputParameters.map { original in
            let parameters = AVMutableAudioMixInputParameters()
            parameters.trackID = original.trackID
            parameters.audioTimePitchAlgorithm = original.audioTimePitchAlgorithm
            for envelope in envelopes(original, duration: duration) {
                parameters.setVolumeRamp(fromStartVolume: envelope.0 * factor, toEndVolume: envelope.1 * factor, timeRange: envelope.2)
            }
            return parameters
        }
        let report = EditorialAudioMasteringReport(
            integratedLUFS: loudness,
            truePeakDBTP: peak,
            appliedGainDB: gain,
            outputLUFS: loudness + gain,
            outputTruePeakDBTP: peak + gain,
            peakLimited: gain + 0.01 < desired,
            measuredFrames: measured.measuredFrames
        )
        return (mastered, report)
    }
}
