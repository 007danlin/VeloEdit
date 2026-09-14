import Foundation
import AVFoundation

public struct RenderReport: Sendable {
    public var outputURL: URL
    public var renderedItemCount: Int
    public var skippedItemIDs: [UUID]
    public var warnings: [String]
    public var videoInfo: EncodedVideoInfo?
    public init(outputURL: URL, renderedItemCount: Int, skippedItemIDs: [UUID], warnings: [String] = [], videoInfo: EncodedVideoInfo? = nil) {
        self.outputURL = outputURL
        self.renderedItemCount = renderedItemCount
        self.skippedItemIDs = skippedItemIDs
        self.warnings = warnings
        self.videoInfo = videoInfo
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
        analyses: [AnalysisResult] = [],
        musicTracks: [LocalMusicTrack] = [],
        telemetry: [UUID: TelemetrySummary] = [:],
        preferredVideoSources: [UUID: URL] = [:],
        sourceWarnings: [String] = [],
        quality: RenderQuality,
        frameRate: Double? = nil,
        destination: URL,
        softwareEncoder: Bool = false,
        progress: (@Sendable (ImportProgress) -> Void)? = nil
    ) async throws -> RenderReport {
        // Preview and export intentionally share one builder. This guarantees
        // that transitions, motion effects and soundtrack look/sound the same.
        let framedTimeline = AutomaticFramingPolicy.applying(to: timeline, assets: assets, analyses: analyses)
        let renderTimeline = ExportSettingsPolicy.timeline(framedTimeline, assets: assets, quality: quality, frameRate: frameRate)
        progress?(ImportProgress(completed: 0, total: 1, currentName: "Проверяю проект перед экспортом"))
        let preflight = await ExportPreflight().inspect(
            timeline: renderTimeline,
            assets: assets,
            analyses: analyses,
            destination: destination,
            quality: quality
        )
        guard preflight.canExport else { throw ExportPreflightError.blocked(preflight) }
        let playback = try await PlaybackEngine().build(
            timeline: renderTimeline,
            assets: assets,
            musicTracks: musicTracks,
            telemetry: telemetry,
            // Delivery always decodes originals. Preview/analysis caches are
            // deliberately ineligible, even when supplied by an older caller.
            preferredVideoSources: [:],
            sourceWarnings: [],
            outputColorProfile: .rec709,
            forceVideoComposition: true,
            progress: progress
        )
        progress?(ImportProgress(completed: timeline.items.count, total: timeline.items.count, currentName: "Монтаж собран"))
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let settings = ExportVideoSettings(timeline: renderTimeline, quality: quality)
        return try await renderComposition(
            playback: playback,
            maximumAudioGainDB: SourceAudioMixPolicy.preservesAttenuation(in: renderTimeline) ? 0 : 12,
            settings: settings,
            destination: destination,
            softwareEncoder: softwareEncoder,
            preflightWarnings: preflight.warnings.map(\.message),
            progress: progress
        )
    }

    private func renderComposition(
        playback: TimelinePlayback,
        maximumAudioGainDB: Double,
        settings: ExportVideoSettings,
        destination: URL,
        softwareEncoder: Bool,
        preflightWarnings: [String],
        progress: (@Sendable (ImportProgress) -> Void)?
    ) async throws -> RenderReport {
        let staged = destination.deletingLastPathComponent()
            .appendingPathComponent(".veloedit-export-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: staged) }
        do {
            try await SoftwareCompositionExporter.export(
                asset: playback.composition,
                videoComposition: playback.videoComposition,
                audioMix: playback.audioMix,
                settings: settings,
                duration: playback.duration,
                destination: staged,
                softwareEncoder: softwareEncoder
            ) { fraction in
                progress?(ImportProgress(completed: Int((fraction * 85).rounded()), total: 100,
                                         currentName: "Кодирую фильм: \(settings.summary)"))
            }
            let firstPassAsset = AVURLAsset(url: staged)
            if let measured = try await EditorialDeliveryVerifier.measureEncodedAudio(asset: firstPassAsset),
               let mastered = EditorialAudioMastering.adjustedMix(composition: firstPassAsset, mix: nil,
                                                                  duration: playback.duration, measured: measured,
                                                                  maximumGainDB: maximumAudioGainDB) {
                let firstPass = destination.deletingLastPathComponent()
                    .appendingPathComponent(".veloedit-first-pass-\(UUID().uuidString).mp4")
                try FileManager.default.moveItem(at: staged, to: firstPass)
                defer { try? FileManager.default.removeItem(at: firstPass) }
                // Audio mastering stream-copies the already encoded video.
                try await SoftwareCompositionExporter.remaster(source: firstPass, gainDB: mastered.1.appliedGainDB,
                                                                duration: playback.duration, destination: staged)
            }
            progress?(ImportProgress(completed: 95, total: 100, currentName: "Проверяю параметры записанного MP4"))
            let expectsAudio = !(try await playback.composition.loadTracks(withMediaType: .audio)).isEmpty
            let info = try await ExportVideoVerifier.verify(url: staged, settings: settings, duration: playback.duration, expectsAudio: expectsAudio)
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: staged)
            } else {
                try FileManager.default.moveItem(at: staged, to: destination)
            }
            progress?(ImportProgress(completed: 100, total: 100, currentName: "Экспорт проверен: \(info.summary)"))
            return RenderReport(outputURL: destination, renderedItemCount: playback.renderedItemCount,
                                skippedItemIDs: playback.skippedItemIDs, warnings: playback.warnings + preflightWarnings,
                                videoInfo: info)
        } catch {
            if error is CancellationError { throw error }
            throw DerivedMediaError.exportFailed(Self.diagnostic(error, stage: "delivery"))
        }
    }

    private static func diagnostic(_ error: Error, stage: String) -> String {
        let value = error as NSError
        let reason = value.userInfo[NSLocalizedFailureReasonErrorKey] as? String
        let underlying = value.userInfo[NSUnderlyingErrorKey] as? NSError
        return "\(stage): \(value.domain) \(value.code): \(reason ?? value.localizedDescription)" +
            (underlying.map { " [\($0.domain) \($0.code): \($0.localizedDescription)]" } ?? "")
    }

}
