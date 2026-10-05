import Foundation
import AVFoundation
import VideoToolbox

/// One delivery contract used by the settings UI, frame renderer and encoder.
public struct ExportVideoSettings: Sendable {
    public let width: Int
    public let height: Int
    public let frameRate: Double
    public let quality: RenderQuality
    public let targetVideoBitRate: Int

    public var codec: AVVideoCodecType { quality == .maximum || quality == .final4K ? .hevc : .h264 }
    public var codecName: String { codec == .hevc ? "HEVC" : "H.264" }
    public var summary: String {
        "\(width) × \(height) · \(Self.frameRateLabel(frameRate)) кадров/с · \(codecName) · SDR Rec.709 · ≈\(Int((Double(targetVideoBitRate) / 1_000_000).rounded())) Мбит/с"
    }

    public init(timeline: Timeline, quality: RenderQuality) {
        width = timeline.width
        height = timeline.height
        frameRate = 1 / VideoFrameTiming.duration(for: timeline.frameRate).seconds
        self.quality = quality
        let bitsPerPixel: Double
        switch quality {
        case .preview720p: bitsPerPixel = 0.10
        case .preview1080p: bitsPerPixel = 0.12
        case .final1080p: bitsPerPixel = 0.28
        case .final4K: bitsPerPixel = 0.16
        case .maximum: bitsPerPixel = 0.24
        }
        targetVideoBitRate = Int(max(1_000_000, Double(width) * Double(height) * frameRate * bitsPerPixel))
    }

    public static func frameRateLabel(_ value: Double) -> String {
        abs(value - value.rounded()) < 0.001 ? String(Int(value.rounded())) : String(format: "%.3f", value)
    }

    var writerSettings: [String: Any] {
        [
            AVVideoCodecKey: codec,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: targetVideoBitRate,
                AVVideoExpectedSourceFrameRateKey: frameRate,
                AVVideoMaxKeyFrameIntervalDurationKey: 2,
                AVVideoAllowFrameReorderingKey: false,
                AVVideoProfileLevelKey: codec == .hevc
                    ? kVTProfileLevel_HEVC_Main_AutoLevel as String
                    : AVVideoProfileLevelH264HighAutoLevel
            ]
        ]
    }
}

public enum ExportSettingsPolicy {
    public static func maximumSourceFrameRate(timeline: Timeline, assets: [MediaAsset]) -> Double {
        let used = Set(timeline.items.filter { $0.kind == .video }.compactMap(\.assetID))
        let rates = assets.filter { used.contains($0.id) }.compactMap(\.metadata.frameRate)
            .filter { $0.isFinite && $0 > 0 }
        return rates.max() ?? timeline.frameRate
    }

    public static func timeline(_ source: Timeline, assets: [MediaAsset], quality: RenderQuality, frameRate: Double? = nil) -> Timeline {
        let source = TimelineFrameRatePolicy.applying(to: source, assets: assets)
        var result = RenderGeometryPolicy.timeline(source, for: quality)
        if quality == .maximum, source.width > 0, source.height > 0 {
            let used = Set(source.items.filter { $0.overlay == nil && $0.kind != .title }.compactMap(\.assetID))
            // Preserve the edited aspect ratio. Choose the largest selected
            // original's raster that fits that canvas without stretching it.
            let scale = assets.filter { used.contains($0.id) }.compactMap(\.displayDimensions).map {
                min(Double($0.width) / Double(source.width), Double($0.height) / Double(source.height))
            }.max() ?? 1
            result.width = max(2, Int((Double(source.width) * max(1, scale) / 2).rounded()) * 2)
            result.height = max(2, Int((Double(source.height) * max(1, scale) / 2).rounded()) * 2)
        }
        // Encoding quality must not change the movie's motion cadence.
        let requested = frameRate ?? source.frameRate
        result.frameRate = requested
        if frameRate != nil { result.automaticallySelectFrameRate = false }
        return result
    }
}

/// Rational timestamps retain 23.976/29.97/59.94 instead of rounding to an
/// integer FPS or the edit clock's coarse 1/600-second tick.
enum VideoFrameTiming {
    /// An encoded film only contains frames on this grid. Sampling a native
    /// composition between them can select a camera frame absent from delivery.
    static func sampleTime(for seconds: Double, frameRate: Double, duration movieDuration: Double) -> CMTime {
        let step = duration(for: frameRate)
        let last = max(0, Int64(ceil(movieDuration / step.seconds - 0.000_001)) - 1)
        let index = min(last, max(0, Int64(floor(max(0, seconds) / step.seconds + 0.000_001))))
        return CMTime(value: index * step.value, timescale: step.timescale)
    }

    static func duration(for frameRate: Double) -> CMTime {
        guard frameRate.isFinite, frameRate > 0 else { return CMTime(value: 1, timescale: 30) }
        for numerator in [24_000, 30_000, 48_000, 60_000, 96_000, 120_000, 240_000] {
            if abs(frameRate - Double(numerator) / 1001) < 0.001 {
                return CMTime(value: 1001, timescale: CMTimeScale(numerator))
            }
        }
        if abs(frameRate - frameRate.rounded()) < 0.00001, frameRate <= 240 {
            return CMTime(value: 1, timescale: CMTimeScale(frameRate.rounded()))
        }
        return CMTime(seconds: 1 / frameRate, preferredTimescale: 6_000_000)
    }
}

public struct EncodedVideoInfo: Sendable {
    public let width: Int
    public let height: Int
    public let frameRate: Double
    public let codec: String
    public let videoBitRate: Double
    public let duration: Double
    /// Container average may differ slightly when its last frame is clipped
    /// to an audio/edit timescale. Keep it alongside the measured cadence.
    public var nominalFrameRate: Double? = nil
    public var cadenceVerified = false
    public var summary: String {
        "\(width) × \(height) · \(ExportVideoSettings.frameRateLabel(frameRate)) кадров/с · \(codec) · \(String(format: "%.1f", videoBitRate / 1_000_000)) Мбит/с"
    }
}

enum ExportVideoVerifier {
    static func verify(url: URL, settings: ExportVideoSettings, duration: Double, expectsAudio: Bool = false) async throws -> EncodedVideoInfo {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw DerivedMediaError.noVideoTrack }
        let size = try await track.load(.naturalSize)
        let nominalFPS = Double(try await track.load(.nominalFrameRate))
        var fps = nominalFPS
        var cadenceVerified = false
        let actualDuration = try await asset.load(.duration).seconds
        let formats = try await track.load(.formatDescriptions)
        let primaries = formats.first.flatMap {
            CMFormatDescriptionGetExtension($0, extensionKey: kCMFormatDescriptionExtension_ColorPrimaries) as? String
        }
        let transfer = formats.first.flatMap {
            CMFormatDescriptionGetExtension($0, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String
        }
        let subtype = formats.first.map { CMFormatDescriptionGetMediaSubType($0) }
        let expected: FourCharCode = settings.codec == .hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264
        if abs(nominalFPS - settings.frameRate) >= 0.005 || !nominalFPS.isFinite {
            // Do not loosen the FPS tolerance. A short, otherwise CFR MP4 can
            // report 30.006 after a sub-frame end trim. Check every compressed
            // sample's presentation time instead; gaps and wrong cadence fail.
            if let measured = try await measuredCadence(asset: asset, track: track,
                expectedRate: settings.frameRate, duration: duration) {
                fps = measured
                cadenceVerified = true
            }
        }
        guard Int(size.width) == settings.width, Int(size.height) == settings.height,
              abs(fps - settings.frameRate) < 0.005, subtype == expected,
              primaries == AVVideoColorPrimaries_ITU_R_709_2, transfer == AVVideoTransferFunction_ITU_R_709_2,
              abs(actualDuration - duration) <= 1 / settings.frameRate + 0.01 else {
            throw DerivedMediaError.exportFailed("Проверка MP4: файл не соответствует выбранным разрешению, FPS, кодеку, цветовому профилю или длительности. Ожидалось \(settings.summary); получено \(Int(size.width)) × \(Int(size.height)), \(fps) кадров/с, \(actualDuration) с.")
        }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.maximumSize = CGSize(width: 640, height: 640)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(seconds: 1 / settings.frameRate, preferredTimescale: 600_000)
        generator.requestedTimeToleranceAfter = generator.requestedTimeToleranceBefore
        defer { generator.cancelAllCGImageGeneration() }
        for fraction in [0.0, 0.25, 0.5, 0.75, 0.99] {
            try Task.checkCancellation()
            let time = max(0, min(actualDuration - 1 / settings.frameRate, actualDuration * fraction))
            _ = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600_000))
        }
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        if expectsAudio && audioTracks.isEmpty { throw DerivedMediaError.exportFailed("В записанном файле отсутствует ожидаемая звуковая дорожка") }
        if !audioTracks.isEmpty {
            guard try await EditorialDeliveryVerifier.measureEncodedAudio(asset: asset) != nil else {
                throw DerivedMediaError.exportFailed("Звуковая дорожка записанного файла не декодируется")
            }
        }
        // The average bitrate is content-dependent (VBR), not a promised
        // minimum. Check the real stream and display its measured value.
        return EncodedVideoInfo(width: Int(size.width), height: Int(size.height), frameRate: fps,
                                codec: settings.codecName, videoBitRate: Double(try await track.load(.estimatedDataRate)), duration: actualDuration,
                                nominalFrameRate: nominalFPS, cadenceVerified: cadenceVerified)
    }

    static func measuredCadence(asset: AVAsset, track: AVAssetTrack, expectedRate: Double, duration: Double) async throws -> Double? {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { return nil }
        defer { if reader.status == .reading { reader.cancelReading() } }
        var times: [Double] = []
        while let sample = try await MediaSampleReader.next(from: output, reader: reader) {
            // AVAssetReader also emits zero-sample boundary/format markers,
            // including NaN timestamps at the end of a passthrough edit.
            // They contain no video frame and must not count as a gap/duplicate.
            if CMSampleBufferGetNumSamples(sample) == 0 { continue }
            guard CMSampleBufferGetNumSamples(sample) == 1 else { return nil }
            times.append(CMSampleBufferGetPresentationTimeStamp(sample).seconds)
        }
        guard reader.status == .completed else { return nil }
        return regularCadence(times: times, expectedRate: expectedRate, duration: duration)
    }

    static func regularCadence(times: [Double], expectedRate: Double, duration: Double) -> Double? {
        guard expectedRate.isFinite, expectedRate > 0, duration.isFinite, duration > 0,
              times.count >= 2, times.allSatisfy(\.isFinite) else { return nil }
        // Compressed H.264 can arrive in decode order. Presentation order is
        // authoritative; duplicates and missing frames still fail below.
        let ordered = times.sorted()
        let tolerance = 0.000_001
        guard abs(ordered[0]) <= tolerance,
              abs(Double(ordered.count) - ceil(duration * expectedRate - tolerance)) <= 1,
              zip(ordered, ordered.dropFirst()).allSatisfy({ abs($1 - $0 - 1 / expectedRate) <= tolerance }) else { return nil }
        return Double(ordered.count - 1) / (ordered.last! - ordered[0])
    }
}
