import Foundation
@preconcurrency import AVFoundation

public struct EditorialExportProbeComparison: Codable, Hashable, Sendable {
    public var time: Double
    public var decoded: Bool
    public var hashDistance: Int?
    public var meanLumaDifference: Double?
    public var meanAbsolutePixelDifference: Double? = nil
    public var previewPTS: Double? = nil
    public var exportPTS: Double? = nil
    public var passed: Bool {
        // Same declared quality tolerances, now applied to the same displayed
        // instant. A different frame is not evidence of codec-only error.
        decoded && (meanLumaDifference ?? 1) <= 0.06 && (meanAbsolutePixelDifference ?? 1) <= 0.075
            && (previewPTS.flatMap { p in exportPTS.map { abs(p - $0) <= 1 / 600.0 } } ?? true)
    }
}

public struct EditorialExportVerification: Codable, Hashable, Sendable {
    public var renderSignature: String
    public var probes: [EditorialExportProbeComparison]
    public var durationDifference: Double
    public var aspectRatioMatches: Bool
    public var encodedAudio: EditorialAudioMasteringReport?
    public var provenance: String
    public var videoDuration: Double? = nil
    public var outputURL: URL? = nil
    public var encodedWidth: Int? = nil
    public var encodedHeight: Int? = nil
    public var fileSize: Int64? = nil
    public var fileModified: Date? = nil
    public var fileModifiedTime: Double? = nil
    public var artifactSHA256: String? = nil
    public var artifactFileIdentity: String? = nil
    public var titleEvidence: [TitleReadabilityEvidence]? = nil
    public var artifactIsCurrent: Bool {
        guard let outputURL, let fileSize, let fileModified,
              let info = try? FileManager.default.attributesOfItem(atPath: outputURL.path) else { return false }
        return (info[.size] as? NSNumber)?.int64Value == fileSize
            && (info[.modificationDate] as? Date)?.timeIntervalSince1970 == (fileModifiedTime ?? fileModified.timeIntervalSince1970)
            && (artifactFileIdentity.map { $0 == FrameCacheKey.sourceIdentity(url: outputURL, contentHash: "export") } ?? true)
    }
}

/// Independently decodes a real control export. Sharing a compositor class or
/// comparing two Timeline hashes is not sufficient to establish parity.
public enum EditorialDeliveryVerifier {
    private struct CompletedExport: Codable, Equatable {
        var signature: String
        var size: Int64
        var modified: Date
        var sha256: String

        static func read(_ url: URL, signature: String) throws -> Self {
            let info = try FileManager.default.attributesOfItem(atPath: url.path)
            return Self(signature: signature, size: (info[.size] as? NSNumber)?.int64Value ?? 0,
                        modified: info[.modificationDate] as? Date ?? .distantPast,
                        sha256: MusicStructureCache.contentIdentity(url))
        }
    }
    public static func verify(timeline: Timeline, assets: [MediaAsset], tracks: [LocalMusicTrack], telemetry: [UUID: TelemetrySummary], preview: [PerceptualRenderedFrameEvidence], cacheURL: URL, preferredVideoSources: [UUID: URL] = [:], sourceWarnings: [String] = []) async throws -> EditorialExportVerification {
        try Task.checkCancellation()
        let key = EditorialRenderDependencies.signature(timeline: timeline, assets: assets, tracks: tracks, telemetry: telemetry, preferredVideoSources: preferredVideoSources)
        let directory = cacheURL.appendingPathComponent("EditorialControlExports")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let output = directory.appendingPathComponent(key + ".mp4")
        let receiptURL = directory.appendingPathComponent(key + ".completed-export.json")
        let receipt = (try? Data(contentsOf: receiptURL)).flatMap { try? JSONDecoder().decode(CompletedExport.self, from: $0) }
        // Reuse only a successfully completed render whose receipt still
        // matches this exact output. Partial or replaced files are regenerated;
        // the receipt itself never counts as independent verification.
        // A control render verifies the composition, not the source camera's
        // maximum raster. Full HD keeps the verifier deterministic on systems
        // where 5K H.264 delivery is not a supported hardware encode profile.
        if let receipt, receipt.size > 0, receipt == (try? CompletedExport.read(output, signature: key)) {
            PerformanceTrace.current?.event("cache.result", fields: ["cache": "control-export", "result": "hit", "signature": key])
            await FilmBuildReporting.report(FilmBuildProgress(.controlExport, detail: "Контрольное видео сохранено — продолжаю проверку"))
        } else {
            PerformanceTrace.current?.event("cache.result", fields: ["cache": "control-export", "result": "miss", "reason": receipt == nil ? "missing-or-incompatible-receipt" : "artifact-changed", "signature": key])
            _ = try await PerformanceTrace.measure(name: "control.export", fields: ["signature": key, "contract": "final1080p"]) {
              try await FilmBuildReporting.forwarding { report in
                try await RenderEngine().render(timeline: timeline, assets: assets, musicTracks: tracks, telemetry: telemetry, preferredVideoSources: preferredVideoSources, sourceWarnings: sourceWarnings, quality: .final1080p, destination: output) { update in
                    report(FilmBuildProgress(.controlExport, completed: update.completed, total: update.total, detail: update.currentName))
                }
            }
            }
            try Task.checkCancellation()
            try JSONEncoder().encode(CompletedExport.read(output, signature: key)).write(to: receiptURL, options: .atomic)
        }
        try Task.checkCancellation()
        let asset = AVURLAsset(url: output)
        let duration = try await asset.load(.duration).seconds
        let video = try await asset.loadTracks(withMediaType: .video).first
        let size = try await video?.load(.naturalSize)
        let videoDuration = try await video?.load(.timeRange).duration.seconds
        let expectedRatio = Double(timeline.width) / Double(max(1, timeline.height))
        let actualRatio = size.map { Double($0.width) / Double(max(1, $0.height)) }
        func makeGenerator() -> AVAssetImageGenerator {
            let generator = AVAssetImageGenerator(asset: asset)
            generator.maximumSize = CGSize(width: 640, height: 640)
            generator.appliesPreferredTrackTransform = true
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            return generator
        }
        // Seeking one generator through a long H.264 delivery can retain its
        // complete decoder history. Rotate it in small chunks so parity proof
        // remains bounded even for dozens of exact probes.
        let decodeChunkSize = 8
        var generator = makeGenerator()
        var decodeRequests = 0
        var comparisons: [EditorialExportProbeComparison] = []
        let trace = PerformanceTrace.current
        let decodeSpan = trace?.begin("delivery.decode", fields: ["artifact": output.path, "signature": key])
        await FilmBuildReporting.report(FilmBuildProgress(.deliveryFrames, completed: 0, total: preview.count))
        for frame in preview {
            try Task.checkCancellation()
            let requested = frame.actualPTS ?? TimelineTiming.playbackTime(forTimelineTime: frame.timelineTime, timeline: timeline)
            let sample = VideoFrameTiming.sampleTime(for: requested, frameRate: timeline.frameRate, duration: videoDuration ?? duration)
            let sampleTimes = [sample.seconds]
            var best: EditorialExportProbeComparison?
            for sampleTime in sampleTimes {
                try Task.checkCancellation()
                if decodeRequests > 0, decodeRequests.isMultiple(of: decodeChunkSize) {
                    generator.cancelAllCGImageGeneration()
                    generator = makeGenerator()
                }
                decodeRequests += 1
                do {
                    let decoded = try await generator.image(at: sample)
                    let image = decoded.image
                    trace?.event("frame.pts", fields: ["purpose": "independent-mp4-parity", "artifact": output.path, "maximumSize": "640", "tolerance": "0/600"], values: ["requested": sampleTime, "actual": decoded.actualTime.seconds])
                    let comparison: EditorialExportProbeComparison = autoreleasepool {
                        let quality = FrameQualityInspector.assess(image: image)
                        let hash = PerceptualRenderInspector.perceptualHash(image)
                        let pixels = PerceptualRenderInspector.lumaFingerprint(image)
                        let delta = frame.lumaFingerprint.flatMap { previous -> Double? in
                            guard !previous.isEmpty, previous.count == pixels.count else { return nil }
                            return zip(previous, pixels).reduce(0) { $0 + abs(Double($1.0 - $1.1)) } / Double(pixels.count)
                        }
                        return .init(time: frame.timelineTime, decoded: true, hashDistance: frame.perceptualHash.map { ($0 ^ hash).nonzeroBitCount }, meanLumaDifference: abs(quality.meanLuma - frame.meanLuma) / 255, meanAbsolutePixelDifference: delta, previewPTS: frame.actualPTS, exportPTS: decoded.actualTime.seconds)
                    }
                    let metric = comparison.meanAbsolutePixelDifference ?? comparison.meanLumaDifference ?? 1
                    let bestMetric = best?.meanAbsolutePixelDifference ?? best?.meanLumaDifference ?? 1
                    if best == nil || metric < bestMetric { best = comparison }
                } catch {
                    continue
                }
            }
            comparisons.append(best ?? .init(time: frame.timelineTime, decoded: false, hashDistance: nil, meanLumaDifference: nil))
            await FilmBuildReporting.report(FilmBuildProgress(.deliveryFrames, completed: comparisons.count, total: preview.count))
        }
        generator.cancelAllCGImageGeneration()
        trace?.end(decodeSpan, stage: "delivery.decode")
        let titleGenerator = makeGenerator()
        titleGenerator.maximumSize = TitleReadabilityInspector.maximumSize
        defer { titleGenerator.cancelAllCGImageGeneration() }
        var titleEvidence: [TitleReadabilityEvidence] = []
        let titleSpan = trace?.begin("delivery.titles", fields: ["artifact": output.path, "signature": key])
        for title in timeline.effectiveTitleItems where title.enabled {
            for time in TitleReadabilityInspector.times(title, frameRate: timeline.frameRate) {
                try Task.checkCancellation()
                let requested = TimelineTiming.playbackTime(forTimelineTime: time, timeline: timeline)
                let decoded = try? await titleGenerator.image(at: VideoFrameTiming.sampleTime(for: requested, frameRate: timeline.frameRate, duration: videoDuration ?? duration))
                let evidence = TitleReadabilityInspector.inspect(image: decoded?.image, title: title, timeline: timeline,
                    time: time, actualPTS: decoded?.actualTime.seconds, source: "mp4")
                titleEvidence.append(evidence)
                trace?.event("title.ocr", fields: ["titleID": title.id.uuidString, "source": "mp4", "artifact": output.path,
                    "signature": evidence.renderSignature, "recognized": evidence.recognizedText, "failure": evidence.failure ?? ""],
                    values: ["requested": requested, "actualPTS": evidence.actualPTS ?? -1, "score": evidence.score])
            }
        }
        trace?.end(titleSpan, stage: "delivery.titles", status: titleEvidence.allSatisfy(\.passed) ? "success" : "failed")
        await FilmBuildReporting.report(FilmBuildProgress(.audioCheck))
        let audio = try await PerformanceTrace.measure(name: "delivery.audio", fields: ["artifact": output.path]) {
            try await measureEncodedAudio(asset: asset)
        }
        var report = EditorialExportVerification(renderSignature: EditorialRenderSignature.signature(timeline), probes: comparisons, durationDifference: abs((videoDuration ?? duration) - AutomaticFilmDurationPolicy.renderedDuration(of: timeline)), aspectRatioMatches: actualRatio.map { abs($0 - expectedRatio) < 0.005 } ?? false, encodedAudio: audio, provenance: "RenderEngine control MP4; independent AVAssetImageGenerator decode and AAC PCM measurement")
        let file = try CompletedExport.read(output, signature: key)
        report.titleEvidence = titleEvidence
        report.artifactSHA256 = file.sha256
        report.artifactFileIdentity = FrameCacheKey.sourceIdentity(url: output, contentHash: "export")
        report.fileSize = file.size
        report.fileModified = file.modified
        report.fileModifiedTime = file.modified.timeIntervalSince1970
        report.videoDuration = videoDuration
        report.outputURL = output
        report.encodedWidth = size.map { Int($0.width) }
        report.encodedHeight = size.map { Int($0.height) }
        try JSONEncoder.veloEdit.encode(report).write(to: directory.appendingPathComponent(key + ".json"), options: .atomic)
        return report
    }

    static func measureEncodedAudio(asset: AVAsset) async throws -> EditorialAudioMasteringReport? {
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { return nil }
        let duration = try await asset.load(.duration).seconds
        var lastPercent = -1
        await FilmBuildReporting.report(FilmBuildProgress(.audioCheck, completed: 0, total: 100))
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false
        ])
        guard reader.canAdd(output) else { throw URLError(.cannotDecodeContentData) }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? URLError(.cannotDecodeContentData) }
        var meter = EditorialLoudnessMeter()
        var resourcePacer = ResourceWorkPacer()
        defer { if reader.status == .reading { reader.cancelReading() } }
        while true {
            try await resourcePacer.checkpoint()
            guard let buffer = try await MediaSampleReader.next(from: output, reader: reader) else { break }
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { throw URLError(.cannotDecodeContentData) }
            let count = CMBlockBufferGetDataLength(block) / MemoryLayout<Float>.size
            var samples = [Float](repeating: 0, count: count)
            let status = samples.withUnsafeMutableBytes { bytes in CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes.count, destination: bytes.baseAddress!) }
            guard status == kCMBlockBufferNoErr else { throw URLError(.cannotDecodeContentData) }
            meter.consume(interleaved: samples)
            let seconds = CMSampleBufferGetPresentationTimeStamp(buffer).seconds
            if duration.isFinite, duration > 0, seconds.isFinite {
                let percent = min(99, max(0, Int(seconds / duration * 100)))
                if percent != lastPercent {
                    lastPercent = percent
                    await FilmBuildReporting.report(FilmBuildProgress(.audioCheck, completed: percent, total: 100))
                }
            }
        }
        guard reader.status == .completed else { throw reader.error ?? URLError(.cannotDecodeContentData) }
        await FilmBuildReporting.report(FilmBuildProgress(.audioCheck, completed: 100, total: 100))
        var report = meter.report(maximumGainDB: 0)
        // We measured encoded output; a proposed gain must not change the
        // reported result without another actual render and measurement.
        report.appliedGainDB = 0
        report.outputLUFS = report.integratedLUFS
        report.outputTruePeakDBTP = report.truePeakDBTP
        return report
    }
}
