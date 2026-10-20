import Foundation
import AVFoundation
import SoundAnalysis
import CryptoKit

/// Apple's bundled sound classifier distinguishes speech from music, wind and
/// other camera sounds. It runs locally, without transcription or a download.
actor SpeechActivityDetector {
    static let shared = SpeechActivityDetector()
    private var memory: [String: [ClosedRange<Double>]] = [:]
    private static let version = "apple-speech-v1-window1-threshold055"

    struct Resolution: Sendable {
        var records: [SpeechActivityRecord]
        var unavailable: Bool
    }

    func resolve(timeline: Timeline, assets: [MediaAsset], cacheDirectory: URL?) async throws -> Resolution {
        let settings = SourceAudioMixPolicy.musicDucking(in: timeline)
        guard settings.enabled || timeline.effectiveAdaptiveSoundtrack?.segments.contains(where: { $0.duckingEnabled == true }) == true,
              timeline.music != nil || timeline.effectiveAudioClips.contains(where: { $0.role == .music }) else {
            return Resolution(records: [], unavailable: false)
        }
        var requested: [UUID: [ClosedRange<Double>]] = [:]
        if timeline.effectiveOriginalAudioVolume > 0 {
            for item in timeline.items where item.kind == .video && !item.isReversed && !item.isFreezeFrame
                && item.effectiveAudioAdjustments.effectiveVolume > 0 {
                if let id = item.assetID { requested[id, default: []].append(item.sourceStart...(item.sourceStart + item.sourceDuration)) }
            }
        }
        for clip in timeline.effectiveAudioClips where clip.role != .music && clip.adjustments.effectiveVolume > 0 {
            if let id = clip.assetID { requested[id, default: []].append(clip.sourceStart...(clip.sourceStart + clip.sourceDuration)) }
        }
        var records: [SpeechActivityRecord] = []
        var unavailable = false
        for asset in assets where requested[asset.id] != nil && asset.metadata.hasAudio {
            try Task.checkCancellation()
            if let transcript = timeline.speechRecords?.first(where: { $0.assetID == asset.id }),
               let ranges = MusicSpeechDucking.transcriptRanges(transcript) {
                records.append(.init(assetID: asset.id, ranges: ranges))
                continue
            }
            var ranges: [ClosedRange<Double>] = []
            // Only inspect material used in the edit, with context at its cuts.
            // Quantized windows keep the cache useful during small trims.
            let windows = Self.merged((requested[asset.id] ?? []).compactMap {
                let start = max(0, floor($0.lowerBound) - 1)
                let end = min(asset.metadata.duration ?? $0.upperBound + 1, ceil($0.upperBound) + 1)
                return end > start ? start...end : nil
            })
            for window in windows {
                do {
                    let attributes = try asset.originalURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                    let identity = "\(Self.version)|\(asset.contentHash)|\(asset.originalURL.path)|\(attributes.fileSize ?? 0)|\(attributes.contentModificationDate?.timeIntervalSince1970 ?? 0)|\(window)"
                    let key = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
                    let url = cacheDirectory?.appendingPathComponent("SpeechActivity/\(key).json")
                    let found = memory[key] ?? url.flatMap { try? JSONDecoder().decode([ClosedRange<Double>].self, from: Data(contentsOf: $0)) }
                    let measured: [ClosedRange<Double>]
                    if let found { measured = found }
                    else {
                        measured = try await classify(url: asset.originalURL, range: window)
                        if let url {
                            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                            try? JSONEncoder().encode(measured).write(to: url, options: .atomic)
                        }
                    }
                    memory[key] = measured
                    ranges += measured
                } catch is CancellationError { throw CancellationError() }
                catch {
                    // Never substitute track presence or energy for speech.
                    unavailable = true
                }
            }
            records.append(.init(assetID: asset.id, ranges: Self.merged(ranges)))
        }
        if memory.count > 512 { memory.removeAll(keepingCapacity: true) }
        return Resolution(records: records, unavailable: unavailable)
    }

    private func classify(url: URL, range: ClosedRange<Double>) async throws -> [ClosedRange<Double>] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return [] }
        let rate = 16_000.0
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        let analyzer = SNAudioStreamAnalyzer(format: format)
        let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
        request.windowDuration = CMTime(seconds: 1, preferredTimescale: 16_000)
        request.overlapFactor = 0.5
        let observer = SpeechActivityObserver(offset: range.lowerBound, end: range.upperBound)
        try analyzer.add(request, withObserver: observer)
        defer { analyzer.removeAllRequests() }
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: range.lowerBound, preferredTimescale: 16_000),
            end: CMTime(seconds: range.upperBound, preferredTimescale: 16_000))
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false
        ])
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? URLError(.cannotDecodeContentData) }
        defer { if reader.status == .reading { reader.cancelReading() } }
        var position: AVAudioFramePosition = 0
        while let sample = try await MediaSampleReader.next(from: output, reader: reader) {
            try Task.checkCancellation()
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let count = CMBlockBufferGetDataLength(block) / MemoryLayout<Float>.size
            guard count > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
                  let data = buffer.floatChannelData?[0] else { continue }
            buffer.frameLength = AVAudioFrameCount(count)
            guard CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count * MemoryLayout<Float>.size,
                destination: data) == kCMBlockBufferNoErr else { throw URLError(.cannotDecodeContentData) }
            analyzer.analyze(buffer, atAudioFramePosition: position)
            position += AVAudioFramePosition(count)
        }
        if reader.status == .failed { throw reader.error ?? URLError(.cannotDecodeContentData) }
        analyzer.completeAnalysis()
        try Task.checkCancellation()
        return try observer.result()
    }

    static func merged(_ ranges: [ClosedRange<Double>]) -> [ClosedRange<Double>] {
        var result: [ClosedRange<Double>] = []
        for range in ranges.filter({ $0.lowerBound.isFinite && $0.upperBound.isFinite && $0.upperBound > $0.lowerBound })
            .sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = result.last, range.lowerBound <= last.upperBound + 0.15 {
                result[result.count - 1] = last.lowerBound...max(last.upperBound, range.upperBound)
            } else { result.append(range) }
        }
        return result
    }
}

private final class SpeechActivityObserver: NSObject, SNResultsObserving {
    private let lock = NSLock()
    private let offset: Double
    private let end: Double
    private var ranges: [ClosedRange<Double>] = []
    private var failure: Error?
    init(offset: Double, end: Double) { self.offset = offset; self.end = end }

    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let result = result as? SNClassificationResult else { return }
        // Do not count singing, laughter, instruments or generic human noise.
        let speech = result.classifications.first { $0.identifier == "speech" }?.confidence ?? 0
        guard speech >= 0.55 else { return }
        let start = max(offset, offset + result.timeRange.start.seconds)
        let finish = min(end, offset + result.timeRange.end.seconds)
        guard finish > start else { return }
        lock.lock(); defer { lock.unlock() }
        ranges.append(start...finish)
    }
    func request(_ request: SNRequest, didFailWithError error: Error) {
        lock.lock(); defer { lock.unlock() }; failure = error
    }
    func requestDidComplete(_ request: SNRequest) {}
    func result() throws -> [ClosedRange<Double>] {
        lock.lock(); defer { lock.unlock() }
        if let failure { throw failure }
        return SpeechActivityDetector.merged(ranges)
    }
}
