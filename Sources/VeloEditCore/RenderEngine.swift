import Foundation
import AVFoundation

public struct RenderReport: Sendable {
    public var outputURL: URL
    public var renderedItemCount: Int
    public var skippedItemIDs: [UUID]
    public var warnings: [String]
    public init(outputURL: URL, renderedItemCount: Int, skippedItemIDs: [UUID], warnings: [String] = []) {
        self.outputURL = outputURL
        self.renderedItemCount = renderedItemCount
        self.skippedItemIDs = skippedItemIDs
        self.warnings = warnings
    }
}

/// Resolves delivery dimensions without changing the canvas aspect ratio.
/// Landscape-named AVFoundation presets are deliberately not used as geometry:
/// a 9:16 timeline must become 1080x1920, never a 1920x1080 surface containing
/// a squeezed or tiny portrait image.
enum RenderGeometryPolicy {
    static func timeline(_ source: Timeline, for quality: RenderQuality) -> Timeline {
        guard source.width > 0, source.height > 0 else { return source }
        let landscapeBounds: (width: Int, height: Int)?
        switch quality {
        case .preview720p:
            landscapeBounds = (1_280, 720)
        case .preview1080p, .final1080p:
            landscapeBounds = (1_920, 1_080)
        case .final4K:
            landscapeBounds = (3_840, 2_160)
        case .maximum:
            landscapeBounds = nil
        }
        guard let landscapeBounds else { return source }

        let bounds: (width: Int, height: Int) = source.width >= source.height
            ? landscapeBounds
            : (width: landscapeBounds.height, height: landscapeBounds.width)
        let scale = min(
            Double(bounds.width) / Double(source.width),
            Double(bounds.height) / Double(source.height)
        )
        var result = source
        result.width = evenPixelSize(Double(source.width) * scale)
        result.height = evenPixelSize(Double(source.height) * scale)
        return result
    }

    private static func evenPixelSize(_ value: Double) -> Int {
        max(2, Int((value / 2).rounded()) * 2)
    }
}

public actor RenderEngine {
    public init() {}

    public func render(
        timeline: Timeline,
        assets: [MediaAsset],
        musicTracks: [LocalMusicTrack] = [],
        telemetry: [UUID: TelemetrySummary] = [:],
        quality: RenderQuality,
        destination: URL,
        progress: (@Sendable (ImportProgress) -> Void)? = nil
    ) async throws -> RenderReport {
        // Preview and export intentionally share one builder. This guarantees
        // that transitions, motion effects and soundtrack look/sound the same.
        let renderTimeline = RenderGeometryPolicy.timeline(timeline, for: quality)
        let playback = try await PlaybackEngine().build(
            timeline: renderTimeline,
            assets: assets,
            musicTracks: musicTracks,
            telemetry: telemetry,
            forceVideoComposition: true,
            progress: progress
        )
        progress?(ImportProgress(completed: timeline.items.count, total: timeline.items.count, currentName: "Монтаж собран"))
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        // The video composition above already has the exact requested size.
        // Fixed 1280x720/1920x1080/3840x2160 presets are landscape presets and
        // may reinterpret a portrait composition. HighestQuality encodes the
        // composition's own geometry instead of silently changing its shape.
        guard let session = AVAssetExportSession(asset: playback.composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw DerivedMediaError.exportUnavailable
        }
        session.outputURL = destination
        session.outputFileType = .mp4
        session.videoComposition = playback.videoComposition
        session.audioMix = playback.audioMix
        session.shouldOptimizeForNetworkUse = quality == .preview720p || quality == .preview1080p
        progress?(ImportProgress(completed: 0, total: 100, currentName: "Кодирую готовый фильм"))
        let monitor = Task {
            while !Task.isCancelled {
                let percent = Int((Double(session.progress) * 100).rounded())
                progress?(ImportProgress(completed: percent, total: 100, currentName: "Сохраняю видео: \(percent) из 100"))
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
        }
        await session.export()
        monitor.cancel()
        guard session.status == .completed else {
            throw DerivedMediaError.exportFailed(session.error?.localizedDescription ?? String(describing: session.status))
        }
        progress?(ImportProgress(completed: 100, total: 100, currentName: "Экспорт готов"))
        return RenderReport(
            outputURL: destination,
            renderedItemCount: playback.renderedItemCount,
            skippedItemIDs: playback.skippedItemIDs,
            warnings: playback.warnings
        )
    }
}
