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
        let playback = try await PlaybackEngine().build(
            timeline: timeline,
            assets: assets,
            musicTracks: musicTracks,
            telemetry: telemetry,
            forceVideoComposition: true,
            progress: progress
        )
        progress?(ImportProgress(completed: timeline.items.count, total: timeline.items.count, currentName: "Монтаж собран"))
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let preset: String
        switch quality {
        case .preview720p: preset = AVAssetExportPreset1280x720
        case .preview1080p, .final1080p: preset = AVAssetExportPreset1920x1080
        case .final4K: preset = AVAssetExportPreset3840x2160
        case .maximum: preset = AVAssetExportPresetHighestQuality
        }
        guard let session = AVAssetExportSession(asset: playback.composition, presetName: preset) else {
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
