import Foundation
import AVFoundation
import QuartzCore

/// A ready-to-play, non-exported timeline. Temporary photo and music
/// intermediates stay alive for as long as the playback object is retained.
public final class TimelinePlayback: @unchecked Sendable {
    public let composition: AVComposition
    public let videoComposition: AVVideoComposition?
    public let audioMix: AVAudioMix?
    public let duration: Double
    public let renderedItemCount: Int
    public let skippedItemIDs: [UUID]
    public let warnings: [String]
    public let derivedMediaCacheHits: Int
    public let derivedMediaCacheMisses: Int
    private let temporaryFiles: [URL]

    init(composition: AVComposition, videoComposition: AVVideoComposition?, audioMix: AVAudioMix?, duration: Double, renderedItemCount: Int, skippedItemIDs: [UUID], warnings: [String] = [], derivedMediaCacheHits: Int = 0, derivedMediaCacheMisses: Int = 0, temporaryFiles: [URL]) {
        self.composition = composition
        self.videoComposition = videoComposition
        self.audioMix = audioMix
        self.duration = duration
        self.renderedItemCount = renderedItemCount
        self.skippedItemIDs = skippedItemIDs
        self.warnings = warnings
        self.derivedMediaCacheHits = derivedMediaCacheHits
        self.derivedMediaCacheMisses = derivedMediaCacheMisses
        self.temporaryFiles = temporaryFiles
    }

    deinit { temporaryFiles.forEach { try? FileManager.default.removeItem(at: $0) } }
}

public actor PlaybackEngine {
    private let titleCardGenerator = TitleCardVideoGenerator()
    private let audioProcessor = ProcessedAudioGenerator()

    private struct Placement {
        var index: Int
        var item: TimelineItem
        var track: AVMutableCompositionTrack
        var audioTrack: AVMutableCompositionTrack?
        var start: CMTime
        var duration: CMTime
        var end: CMTime { start + duration }
        var naturalSize: CGSize
        var preferredTransform: CGAffineTransform
    }

    private struct AudioPlacement {
        var clip: TimelineAudioClip
        var track: AVMutableCompositionTrack
        var start: CMTime
        var duration: CMTime
        var end: CMTime { start + duration }
    }

    public init() {}

    public func build(
        timeline: Timeline,
        assets: [MediaAsset],
        musicTracks: [LocalMusicTrack] = [],
        telemetry: [UUID: TelemetrySummary] = [:],
        preferredVideoSources: [UUID: URL] = [:],
        sourceWarnings: [String] = [],
        derivedMediaCacheURL: URL? = nil,
        forceVideoComposition: Bool = false,
        progress: (@Sendable (ImportProgress) -> Void)? = nil
    ) async throws -> TimelinePlayback {
        let assetByID = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) })
        let composition = AVMutableComposition()
        let videoTracks = (0..<4).compactMap { _ in composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) }
        guard videoTracks.count == 4 else { throw DerivedMediaError.noVideoTrack }
        let originalAudioVolume = min(max(0, timeline.effectiveOriginalAudioVolume), 1)
        let originalAudioTracks: [AVMutableCompositionTrack?] = originalAudioVolume > 0.0001
            ? (0..<4).map { _ in composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) }
            : [nil, nil, nil, nil]
        let timescale: CMTimeScale = 600
        var resolvedItems = timeline.items
        for transition in timeline.effectiveTransitionItems {
            if let index = resolvedItems.firstIndex(where: { $0.id == transition.incomingClipID }) {
                resolvedItems[index].transition = transition.enabled ? transition.style.rawValue : nil
            }
        }
        let retimedItems = TimelineTiming.retimed(resolvedItems)
        // Build the complete magnetic storyline before connected media. This
        // guarantees that every overlay can resolve its base even when project
        // JSON stores connected clips between primary items.
        let playableItems = (
            retimedItems.filter { $0.overlay == nil } +
            retimedItems.filter { $0.overlay != nil }.sorted { $0.timelineStart < $1.timelineStart }
        ).filter { $0.kind == .title || $0.assetID != nil }
        // Large homogeneous HEVC camera files are substantially more reliable
        // in AVPlayer when they keep their native track geometry. Some macOS
        // MediaToolbox versions return black frames when a custom per-clip
        // compositor is attached to a 5K composition. Timeline transition
        // intents remain stored and exported, but live playback favors a
        // stable image unless the user explicitly adds a motion effect.
        let usesNativeCameraPath = timeline.effectiveTelemetryItems.isEmpty && timeline.effectiveEffects.isEmpty && timeline.effectiveTitleItems.isEmpty && timeline.effectiveTransitionItems.isEmpty && !forceVideoComposition && Self.shouldUseNativeCameraPath(items: playableItems, assets: assetByID)
        let usesColorCompositor = playableItems.contains {
            AdjustedClipGenerator.needsRender($0.effectiveVideoAdjustments) ||
            $0.overlay?.style == .greenScreen ||
            $0.telemetryOverlay != nil ||
            $0.transition != nil
        } || !timeline.effectiveTelemetryItems.isEmpty || !timeline.effectiveEffects.isEmpty || !timeline.effectiveTitleItems.isEmpty || !timeline.effectiveTransitionItems.isEmpty
        var temporaryFiles: [URL] = []
        var placements: [Placement] = []
        var skippedItemIDs: [UUID] = []
        var derivedMediaCacheHits = 0
        var derivedMediaCacheMisses = 0
        var cursor = CMTime.zero

        for (index, item) in playableItems.enumerated() {
            if Task.isCancelled { throw CancellationError() }
            let media = item.assetID.flatMap { assetByID[$0] }
            guard item.kind == .title || media != nil else {
                skippedItemIDs.append(item.id)
                continue
            }
            progress?(ImportProgress(
                completed: index,
                total: playableItems.count,
                currentName: item.kind == .title ? "Готовлю титр: \(item.title ?? "Без названия")" : "Готовлю: \(media?.displayName ?? "фрагмент")"
            ))

            var sourceURL: URL
            var sourceStart: Double
            var insertedSourceDuration: Double
            if item.kind == .title {
                // A title must be part of the actual video composition. A
                // previous implementation borrowed an arbitrary background
                // clip and depended on a Core Animation overlay that the live
                // player intentionally strips on affected macOS versions.
                // Baking the card makes titles identical in viewer and export.
                let identity = Self.titleCacheIdentity(item: item, timeline: timeline)
                let isPersistent = derivedMediaCacheURL != nil
                let destination = derivedMediaCacheURL?.appendingPathComponent("title-\(identity).mov")
                    ?? FileManager.default.temporaryDirectory.appendingPathComponent("veloedit-title-\(item.id.uuidString).mov")
                let cacheHit = isPersistent ? await Self.usableGeneratedVideo(destination) : false
                if cacheHit {
                    sourceURL = destination
                } else {
                    sourceURL = try await cachedGeneratedVideo(destination: destination, isPersistent: isPersistent) { temporary in
                        try await self.titleCardGenerator.generate(
                            text: item.title ?? "Мой фильм",
                            style: item.effectiveTitleStyle,
                            duration: item.timelineDuration,
                            width: timeline.width,
                            height: timeline.height,
                            frameRate: Int32(timeline.frameRate.rounded()),
                            destination: temporary
                        )
                    }
                }
                if derivedMediaCacheURL != nil {
                    if cacheHit { derivedMediaCacheHits += 1 } else { derivedMediaCacheMisses += 1 }
                }
                sourceStart = 0
                insertedSourceDuration = item.timelineDuration
                if derivedMediaCacheURL == nil { temporaryFiles.append(sourceURL) }
            } else if item.kind == .photo, let media {
                let backgroundPreset = BackgroundPreset.preset(for: media)
                let identity = Self.photoCacheIdentity(item: item, asset: media, timeline: timeline, preset: backgroundPreset)
                let isPersistent = derivedMediaCacheURL != nil
                let destination = derivedMediaCacheURL?.appendingPathComponent("photo-\(identity).mov")
                    ?? FileManager.default.temporaryDirectory.appendingPathComponent("veloedit-playback-\(item.id.uuidString).mov")
                let cacheHit = isPersistent ? await Self.usableGeneratedVideo(destination) : false
                if cacheHit {
                    sourceURL = destination
                } else {
                    sourceURL = try await cachedGeneratedVideo(destination: destination, isPersistent: isPersistent) { temporary in
                        try await StillImageVideoGenerator().generate(
                            imageURL: media.originalURL,
                            duration: item.timelineDuration,
                            width: timeline.width,
                            height: timeline.height,
                            frameRate: Int32(timeline.frameRate.rounded()),
                            destination: temporary,
                            motion: backgroundPreset?.animationMotion,
                            backgroundAnimationStyle: backgroundPreset?.animationStyle
                        )
                    }
                }
                if derivedMediaCacheURL != nil {
                    if cacheHit { derivedMediaCacheHits += 1 } else { derivedMediaCacheMisses += 1 }
                }
                sourceStart = 0
                insertedSourceDuration = item.timelineDuration
                if derivedMediaCacheURL == nil { temporaryFiles.append(sourceURL) }
            } else if let media {
                sourceURL = preferredVideoSources[media.id] ?? media.originalURL
                sourceStart = item.sourceStart
                insertedSourceDuration = item.sourceDuration
            } else {
                skippedItemIDs.append(item.id)
                continue
            }

            let source = AVURLAsset(url: sourceURL)
            guard let sourceVideo = try await source.loadTracks(withMediaType: .video).first else {
                skippedItemIDs.append(item.id)
                continue
            }
            let sourceRange = CMTimeRange(
                start: CMTime(seconds: sourceStart, preferredTimescale: timescale),
                duration: CMTime(seconds: insertedSourceDuration, preferredTimescale: timescale)
            )
            let overlayBase = item.overlay?.baseItemID.flatMap { baseID in
                placements.first(where: { $0.item.id == baseID })
            }
            let requestedDuration = CMTime(seconds: item.timelineDuration, preferredTimescale: timescale)
            let targetDuration = item.overlay == nil
                ? requestedDuration
                : min(requestedDuration, CMTime(seconds: max(0.05, timeline.duration - item.timelineStart), preferredTimescale: timescale))
            let previousPrimary = placements.last(where: { $0.item.overlay == nil })
            let overlap = item.overlay == nil && !usesNativeCameraPath
                ? transitionDuration(for: item, previous: previousPrimary?.item, transitionItems: timeline.effectiveTransitionItems, timescale: timescale)
                : .zero
            let at = item.overlay == nil
                ? max(.zero, cursor - overlap)
                : CMTime(seconds: item.timelineStart, preferredTimescale: timescale)
            let trackIndex: Int
            if usesNativeCameraPath {
                trackIndex = 0
            } else if let overlayBase {
                let baseTrackIndex = videoTracks.firstIndex(where: { $0.trackID == overlayBase.track.trackID }) ?? 0
                trackIndex = (baseTrackIndex + 1) % videoTracks.count
            } else {
                trackIndex = placements.filter { $0.item.overlay == nil }.count % 2
            }
            let videoTrack = videoTracks[trackIndex]
            var insertedTimelineDuration = sourceRange.duration
            if item.isReversed && item.kind == .video {
                let requestedFrames = max(1, Int((sourceRange.duration.seconds * timeline.frameRate).rounded()))
                let frameCount = min(600, requestedFrames)
                let frameDuration = CMTimeMultiplyByRatio(sourceRange.duration, multiplier: 1, divisor: Int32(frameCount))
                var destinationCursor = at
                for frameIndex in stride(from: frameCount - 1, through: 0, by: -1) {
                    let frameStart = sourceRange.start + CMTimeMultiply(frameDuration, multiplier: Int32(frameIndex))
                    try videoTrack.insertTimeRange(
                        CMTimeRange(start: frameStart, duration: frameDuration),
                        of: sourceVideo,
                        at: destinationCursor
                    )
                    destinationCursor = destinationCursor + frameDuration
                }
            } else if let ramp = item.speedRamp, item.kind == .video {
                insertedTimelineDuration = try insert(
                    ramp: ramp,
                    sourceRange: sourceRange,
                    sourceTrack: sourceVideo,
                    destinationTrack: videoTrack,
                    at: at
                )
            } else {
                try videoTrack.insertTimeRange(sourceRange, of: sourceVideo, at: at)
            }

            let audioTrack = originalAudioTracks[trackIndex]
            if originalAudioVolume > 0.0001,
               item.kind == .video,
               !item.isReversed,
               !item.isFreezeFrame,
               let media,
               media.metadata.hasAudio {
                let audioAdjustments = item.effectiveAudioAdjustments
                let audioSourceURL: URL
                let audioSourceStart: Double
                if ProcessedAudioGenerator.needsRender(audioAdjustments) {
                    let temporary = FileManager.default.temporaryDirectory
                        .appendingPathComponent("veloedit-processed-audio-\(item.id.uuidString)")
                        .appendingPathExtension("caf")
                    audioSourceURL = try await audioProcessor.generate(
                        sourceURL: media.originalURL,
                        sourceStart: item.sourceStart,
                        sourceDuration: item.sourceDuration,
                        adjustments: audioAdjustments,
                        destination: temporary
                    )
                    audioSourceStart = 0
                    temporaryFiles.append(temporary)
                } else {
                    audioSourceURL = media.originalURL
                    audioSourceStart = item.sourceStart
                }
                let audioSource = AVURLAsset(url: audioSourceURL)
                if let sourceAudio = try await audioSource.loadTracks(withMediaType: .audio).first {
                    let audioRange = CMTimeRange(
                        start: CMTime(seconds: audioSourceStart, preferredTimescale: timescale),
                        duration: CMTime(seconds: item.sourceDuration, preferredTimescale: timescale)
                    )
                    if let audioTrack, let ramp = item.speedRamp {
                        _ = try? insert(
                            ramp: ramp,
                            sourceRange: audioRange,
                            sourceTrack: sourceAudio,
                            destinationTrack: audioTrack,
                            at: at
                        )
                    } else {
                        try? audioTrack?.insertTimeRange(audioRange, of: sourceAudio, at: at)
                    }
                }
            }
            if insertedTimelineDuration != targetDuration {
                let insertedRange = CMTimeRange(start: at, duration: insertedTimelineDuration)
                videoTrack.scaleTimeRange(insertedRange, toDuration: targetDuration)
                audioTrack?.scaleTimeRange(insertedRange, toDuration: targetDuration)
            }

            var placedItem = item
            if placedItem.kind == .photo && placedItem.effect == nil {
                placedItem.effect = ClipEffect.kenBurns.rawValue
            }
            placements.append(Placement(
                index: placements.count,
                item: placedItem,
                track: videoTrack,
                audioTrack: audioTrack,
                start: at,
                duration: targetDuration,
                naturalSize: try await sourceVideo.load(.naturalSize),
                preferredTransform: try await sourceVideo.load(.preferredTransform)
            ))
            if item.overlay == nil { cursor = at + targetDuration }
        }

        guard !placements.isEmpty else {
            temporaryFiles.forEach { try? FileManager.default.removeItem(at: $0) }
            throw DerivedMediaError.noVideoTrack
        }

        let renderSize = CGSize(width: timeline.width, height: timeline.height)
        let videoComposition: AVMutableVideoComposition?
        if usesNativeCameraPath {
            placements.first?.track.preferredTransform = placements.first?.preferredTransform ?? .identity
            videoComposition = nil
        } else if usesColorCompositor {
            videoComposition = makeColorVideoComposition(
                placements: placements,
                telemetryItems: timeline.effectiveTelemetryItems,
                effects: timeline.effectiveEffects,
                titles: timeline.effectiveTitleItems,
                transitionItems: timeline.effectiveTransitionItems,
                telemetry: telemetry,
                renderSize: renderSize,
                frameRate: timeline.frameRate
            )
        } else {
            videoComposition = makeVideoComposition(placements: placements, renderSize: renderSize, frameRate: timeline.frameRate)
        }
        if timeline.music != nil {
            progress?(ImportProgress(completed: playableItems.count, total: playableItems.count, currentName: "Добавляю локальный саундтрек"))
        }
        let unavailableSoundtrack = Self.soundtrackWarning(for: timeline.music, tracks: musicTracks)
        let musicResult = unavailableSoundtrack == nil
            ? try await addMusic(timeline.music, tracks: musicTracks, to: composition, duration: cursor)
            : nil
        let audioResult = try await addAudioClips(
            timeline.effectiveAudioClips,
            assets: assetByID,
            musicTracks: musicTracks,
            to: composition,
            movieDuration: cursor
        )
        temporaryFiles.append(contentsOf: audioResult.temporaryFiles)
        let soundtrackWarning = unavailableSoundtrack ?? (timeline.music != nil && musicResult == nil
            ? "Саундтрек недоступен — просмотр собран без музыки. Видео и звук исходников сохранены."
            : nil)
        let audioMix = makeAudioMix(
            placements: placements,
            originalTracks: originalAudioTracks.compactMap { $0 },
            originalAudioVolume: Float(originalAudioVolume),
            music: musicResult,
            additionalAudio: audioResult.placements,
            ducking: timeline.audioDucking ?? AudioDuckingSettings()
        )

        progress?(ImportProgress(completed: playableItems.count, total: playableItems.count, currentName: "Просмотр готов"))
        if let derivedMediaCacheURL {
            Self.pruneDerivedMediaCache(derivedMediaCacheURL, maximumFiles: 128, maximumBytes: 2_000_000_000)
        }
        return TimelinePlayback(
            composition: composition,
            videoComposition: videoComposition,
            audioMix: audioMix,
            duration: cursor.seconds,
            renderedItemCount: placements.count,
            skippedItemIDs: skippedItemIDs,
            warnings: sourceWarnings + [soundtrackWarning].compactMap { $0 },
            derivedMediaCacheHits: derivedMediaCacheHits,
            derivedMediaCacheMisses: derivedMediaCacheMisses,
            temporaryFiles: temporaryFiles
        )
    }

    private func cachedGeneratedVideo(
        destination: URL,
        isPersistent: Bool,
        generator: (URL) async throws -> URL
    ) async throws -> URL {
        guard isPersistent else { return try await generator(destination) }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.deletingPathExtension().lastPathComponent)-\(UUID().uuidString).partial.mov")
        defer { try? FileManager.default.removeItem(at: temporary) }
        _ = try await generator(temporary)
        guard await Self.usableGeneratedVideo(temporary) else {
            throw DerivedMediaError.exportFailed("кэшированный источник preview не содержит декодируемого видео")
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporary, to: destination)
        return destination
    }

    private static func usableGeneratedVideo(_ url: URL) async -> Bool {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 1_024 else { return false }
        guard let tracks = try? await AVURLAsset(url: url).loadTracks(withMediaType: .video) else { return false }
        return !tracks.isEmpty
    }

    private static func titleCacheIdentity(item: TimelineItem, timeline: Timeline) -> String {
        let style = (try? JSONEncoder.veloEdit.encode(item.effectiveTitleStyle)).map { $0.base64EncodedString() } ?? "style"
        return ProductionCacheIdentity.hash([
            "title-v2", item.title ?? "", style,
            String(Int((item.timelineDuration * 1_000).rounded())),
            "\(timeline.width)x\(timeline.height)@\(Int(timeline.frameRate.rounded()))"
        ])
    }

    private static func photoCacheIdentity(
        item: TimelineItem,
        asset: MediaAsset,
        timeline: Timeline,
        preset: BackgroundPreset?
    ) -> String {
        ProductionCacheIdentity.hash([
            "photo-v2", asset.contentHash, item.effect ?? "ken-burns",
            preset?.rawValue ?? "photo", preset?.animationStyle?.rawValue ?? "none",
            String(Int((item.timelineDuration * 1_000).rounded())),
            "\(timeline.width)x\(timeline.height)@\(Int(timeline.frameRate.rounded()))"
        ])
    }

    private static func pruneDerivedMediaCache(_ directory: URL, maximumFiles: Int, maximumBytes: Int64) {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else { return }
        var records = urls.compactMap { url -> (url: URL, size: Int64, date: Date)? in
            guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true else { return nil }
            return (url, Int64(values.fileSize ?? 0), values.contentModificationDate ?? .distantPast)
        }.sorted { $0.date > $1.date }
        var total = records.reduce(Int64(0)) { $0 + $1.size }
        while records.count > max(1, maximumFiles) || total > max(1, maximumBytes) {
            let record = records.removeLast()
            if (try? FileManager.default.removeItem(at: record.url)) != nil { total -= record.size }
        }
    }

    private static func shouldUseNativeCameraPath(items: [TimelineItem], assets: [UUID: MediaAsset]) -> Bool {
        guard !items.isEmpty, items.allSatisfy({
            $0.kind == .video && $0.effect == nil && $0.transition == nil && $0.overlay == nil &&
            $0.telemetryOverlay == nil && $0.effectiveVideoAdjustments.isNeutral
        }) else { return false }
        let descriptors = items.compactMap { item -> String? in
            guard let id = item.assetID, let metadata = assets[id]?.metadata,
                  let width = metadata.width, let height = metadata.height else { return nil }
            return "\(width)x\(height)@\(metadata.orientationDegrees)"
        }
        guard descriptors.count == items.count, Set(descriptors).count == 1,
              let firstID = items.first?.assetID, let metadata = assets[firstID]?.metadata,
              let width = metadata.width, let height = metadata.height else { return false }
        return max(width, height) >= 3840
    }

    public nonisolated static func soundtrackWarning(for directive: MusicDirective?, tracks: [LocalMusicTrack]) -> String? {
        guard let directive else { return nil }
        guard let trackID = directive.trackID,
              let localTrack = tracks.first(where: { $0.id == trackID }),
              FileManager.default.fileExists(atPath: localTrack.localFileURL.path) else {
            return "Саундтрек недоступен — просмотр собран без музыки. Видео и звук исходников сохранены."
        }
        return nil
    }

    private func transitionDuration(for item: TimelineItem, previous: TimelineItem?, transitionItems: [TimelineTransitionItem], timescale: CMTimeScale) -> CMTime {
        let explicit = transitionItems.first { $0.enabled && $0.incomingClipID == item.id && $0.outgoingClipID == previous?.id }
        return CMTime(
            seconds: explicit?.duration ?? TimelineTiming.transitionOverlap(incoming: item, previous: previous),
            preferredTimescale: timescale
        )
    }

    /// Inserts a variable-rate clip as adjacent source ranges. AVFoundation
    /// then carries the same retiming into live playback and final export.
    private func insert(
        ramp: SpeedRamp,
        sourceRange: CMTimeRange,
        sourceTrack: AVAssetTrack,
        destinationTrack: AVMutableCompositionTrack,
        at start: CMTime
    ) throws -> CMTime {
        var cursor = start
        let points = ramp.normalizedPoints
        for (from, to) in zip(points, points.dropFirst()) where to.position > from.position {
            let sourceOffset = CMTimeMultiplyByFloat64(sourceRange.duration, multiplier: from.position)
            let sourceDuration = CMTimeMultiplyByFloat64(sourceRange.duration, multiplier: to.position - from.position)
            let averageRate = max(0.1, (from.rate + to.rate) * 0.5)
            let outputDuration = CMTimeMultiplyByFloat64(sourceDuration, multiplier: 1 / averageRate)
            let destinationRange = CMTimeRange(start: cursor, duration: sourceDuration)
            try destinationTrack.insertTimeRange(
                CMTimeRange(start: sourceRange.start + sourceOffset, duration: sourceDuration),
                of: sourceTrack,
                at: cursor
            )
            destinationTrack.scaleTimeRange(destinationRange, toDuration: outputDuration)
            cursor = cursor + outputDuration
        }
        return cursor - start
    }

    private func makeVideoComposition(placements: [Placement], renderSize: CGSize, frameRate: Double) -> AVMutableVideoComposition {
        let result = AVMutableVideoComposition()
        result.renderSize = renderSize
        result.frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(1, frameRate.rounded())))
        let boundaries = Set(placements.flatMap { [$0.start, $0.end] }).sorted()
        var instructions: [AVMutableVideoCompositionInstruction] = []

        for pair in zip(boundaries, boundaries.dropFirst()) where pair.0 < pair.1 {
            let range = CMTimeRange(start: pair.0, end: pair.1)
            let active = placements.filter { $0.start < range.end && $0.end > range.start }.sorted { $0.index > $1.index }
            guard !active.isEmpty else { continue }
            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = range
            let layers = active.map { placement -> AVMutableVideoCompositionLayerInstruction in
                let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: placement.track)
                let base = Self.displayTransform(for: placement, active: active, renderSize: renderSize)
                applyEffect(placement.item.effect.flatMap(ClipEffect.init(rawValue:)), to: layer, base: base, placement: placement, renderSize: renderSize)
                return layer
            }
            if active.count > 1, let incoming = active.first, let outgoing = active.dropFirst().first,
               let style = incoming.item.transition.flatMap(TransitionStyle.init(rawValue:)) {
                applyTransition(style, incoming: layers[0], outgoing: layers[1], range: range, incomingPlacement: incoming, outgoingPlacement: outgoing, renderSize: renderSize)
            }
            instruction.layerInstructions = layers
            instructions.append(instruction)
        }
        result.instructions = instructions
        return result
    }

    private func makeColorVideoComposition(
        placements: [Placement],
        telemetryItems: [TimelineTelemetryItem],
        effects: [EffectTimelineItem],
        titles: [TitleTimelineItem],
        transitionItems: [TimelineTransitionItem],
        telemetry: [UUID: TelemetrySummary],
        renderSize: CGSize,
        frameRate: Double
    ) -> AVMutableVideoComposition {
        let result = AVMutableVideoComposition()
        result.customVideoCompositorClass = VeloVideoCompositor.self
        result.renderSize = renderSize
        result.frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(1, frameRate.rounded())))
        result.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
        result.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
        result.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
        let placementByClipID = Dictionary(uniqueKeysWithValues: placements.map { ($0.item.id, $0) })
        func telemetryRange(for item: TimelineTelemetryItem) -> CMTimeRange {
            guard let clipID = item.targetClipID,
                  let placement = placementByClipID[clipID] else {
                return CMTimeRange(
                    start: CMTime(seconds: item.timelineStart, preferredTimescale: 600),
                    duration: CMTime(seconds: item.timelineDuration, preferredTimescale: 600)
                )
            }
            let clip = placement.item
            let startFraction = min(max(0, (item.timelineStart - clip.timelineStart) / max(0.05, clip.timelineDuration)), 1)
            let endFraction = min(max(startFraction, (item.timelineEnd - clip.timelineStart) / max(0.05, clip.timelineDuration)), 1)
            let start = placement.start + CMTimeMultiplyByFloat64(placement.duration, multiplier: startFraction)
            let duration = CMTimeMultiplyByFloat64(placement.duration, multiplier: max(0, endFraction - startFraction))
            return CMTimeRange(start: start, duration: max(duration, CMTime(value: 1, timescale: 600)))
        }
        let telemetryRanges = Dictionary(uniqueKeysWithValues: telemetryItems.map { ($0.id, telemetryRange(for: $0)) })
        let telemetryBoundaries = telemetryRanges.values.flatMap { [$0.start, $0.end] }
        let effectBoundaries = effects.filter(\.enabled).flatMap {
            [CMTime(seconds: $0.startTime, preferredTimescale: 600), CMTime(seconds: $0.endTime, preferredTimescale: 600)]
        }
        let titleBoundaries = titles.filter(\.enabled).flatMap {
            [CMTime(seconds: $0.startTime, preferredTimescale: 600), CMTime(seconds: $0.endTime, preferredTimescale: 600)]
        }
        let boundaries = Set(placements.flatMap { [$0.start, $0.end] } + telemetryBoundaries + effectBoundaries + titleBoundaries).sorted()
        result.instructions = zip(boundaries, boundaries.dropFirst()).compactMap { start, end in
            guard start < end else { return nil }
            let range = CMTimeRange(start: start, end: end)
            let active = placements
                .filter { $0.start < range.end && $0.end > range.start }
                .sorted { $0.index > $1.index }
            guard !active.isEmpty else { return nil }
            let layers = active.map { placement in
                VeloCompositorLayer(
                    trackID: placement.track.trackID,
                    item: placement.item,
                    start: placement.start,
                    duration: placement.duration,
                    transform: Self.displayTransform(for: placement, active: active, renderSize: renderSize),
                    telemetry: placement.item.assetID.flatMap { telemetry[$0] }
                )
            }
            let explicitTransition = active.count > 1 && active.allSatisfy({ $0.item.overlay == nil })
                ? transitionItems.first(where: {
                    $0.enabled && $0.incomingClipID == active[0].item.id && $0.outgoingClipID == active[1].item.id
                })
                : nil
            let transition = explicitTransition?.style ?? (active.count > 1 && active.allSatisfy({ $0.item.overlay == nil })
                ? active.first?.item.transition.flatMap(TransitionStyle.init(rawValue:))
                : nil)
            let transitionItem = explicitTransition ?? transition.map {
                TimelineTransitionItem(
                    style: $0,
                    outgoingClipID: active[1].item.id,
                    incomingClipID: active[0].item.id,
                    startTime: range.start.seconds,
                    duration: range.duration.seconds,
                    explanation: ["Совместимый переход из Timeline"]
                )
            }
            let activeTelemetry = telemetryItems.compactMap { item -> VeloTelemetryLayer? in
                guard let itemRange = telemetryRanges[item.id], itemRange.start < range.end, itemRange.end > range.start,
                      let summary = item.sourceID.flatMap({ telemetry[$0] }) ?? item.linkedAssetID.flatMap({ telemetry[$0] }) else { return nil }
                let targetClip = item.targetClipID.flatMap { placementByClipID[$0]?.item }
                return VeloTelemetryLayer(item: item, telemetry: summary, targetClip: targetClip, start: itemRange.start, duration: itemRange.duration)
            }
            let activeEffects = effects.filter { $0.enabled && $0.startTime < range.end.seconds && $0.endTime > range.start.seconds }
            let activeClipIDs = Set(active.map(\.item.id))
            let activeTitles = titles.filter {
                $0.enabled && $0.startTime < range.end.seconds && $0.endTime > range.start.seconds &&
                ($0.targetClipID.map { activeClipIDs.contains($0) } ?? true)
            }
            return VeloVideoInstruction(timeRange: range, layers: layers, telemetryLayers: activeTelemetry, effects: activeEffects, titles: activeTitles, transition: transition, transitionItem: transitionItem, renderSize: renderSize)
        }
        return result
    }

    private func addTitleOverlays(
        to composition: AVMutableVideoComposition?,
        placements: [Placement],
        renderSize: CGSize,
        duration: CMTime
    ) {
        guard let composition, placements.contains(where: { $0.item.kind == .title }) else { return }
        let videoLayer = CALayer()
        videoLayer.frame = CGRect(origin: .zero, size: renderSize)
        let parentLayer = CALayer()
        parentLayer.frame = videoLayer.frame
        parentLayer.addSublayer(videoLayer)

        for placement in placements where placement.item.kind == .title {
            let style = placement.item.effectiveTitleStyle
            let background = CALayer()
            background.frame = videoLayer.frame
            background.backgroundColor = Self.cgColor(style.backgroundColorHex, fallback: CGColor(gray: 0.04, alpha: 1))
            background.opacity = 0
            background.add(Self.visibilityAnimation(start: placement.start.seconds, visibleDuration: placement.duration.seconds, totalDuration: duration.seconds), forKey: "veloedit-visibility")
            parentLayer.addSublayer(background)

            let text = CATextLayer()
            text.frame = CGRect(
                x: renderSize.width * 0.08,
                y: renderSize.height * 0.26,
                width: renderSize.width * 0.84,
                height: renderSize.height * 0.48
            )
            text.string = placement.item.title ?? "Мой фильм"
            text.font = "Helvetica Neue Bold" as CFTypeRef
            text.fontSize = CGFloat(style.fontSize)
            text.foregroundColor = Self.cgColor(style.textColorHex, fallback: CGColor(gray: 1, alpha: 1))
            text.alignmentMode = style.alignment == .left ? .left : style.alignment == .right ? .right : .center
            text.isWrapped = true
            text.contentsScale = 2
            text.opacity = 0
            text.add(Self.visibilityAnimation(start: placement.start.seconds, visibleDuration: placement.duration.seconds, totalDuration: duration.seconds), forKey: "veloedit-visibility")
            parentLayer.addSublayer(text)
        }
        composition.animationTool = AVVideoCompositionCoreAnimationTool(
            postProcessingAsVideoLayer: videoLayer,
            in: parentLayer
        )
    }

    private static func visibilityAnimation(start: Double, visibleDuration: Double, totalDuration: Double) -> CAKeyframeAnimation {
        let animation = CAKeyframeAnimation(keyPath: "opacity")
        animation.values = [0, 1, 1, 0]
        animation.keyTimes = [0, 0.04, 0.92, 1]
        animation.beginTime = AVCoreAnimationBeginTimeAtZero + max(0, start)
        animation.duration = min(max(0.1, visibleDuration), max(0.1, totalDuration))
        animation.fillMode = .both
        animation.isRemovedOnCompletion = false
        return animation
    }

    private static func cgColor(_ hex: String, fallback: CGColor) -> CGColor {
        let value = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard value.count == 6, let number = Int(value, radix: 16) else { return fallback }
        return CGColor(
            red: CGFloat((number >> 16) & 0xFF) / 255,
            green: CGFloat((number >> 8) & 0xFF) / 255,
            blue: CGFloat(number & 0xFF) / 255,
            alpha: 1
        )
    }

    private func applyEffect(_ effect: ClipEffect?, to layer: AVMutableVideoCompositionLayerInstruction, base: CGAffineTransform, placement: Placement, renderSize: CGSize) {
        let opacity = Float(placement.item.effectiveVideoAdjustments.opacity)
        if opacity < 0.999 { layer.setOpacity(opacity, at: placement.start) }
        guard let effect else { layer.setTransform(base, at: placement.start); return }
        let range = CMTimeRange(start: placement.start, duration: placement.duration)
        switch effect {
        case .kenBurns:
            layer.setTransformRamp(fromStart: base, toEnd: zoomed(base, scale: 1.08, renderSize: renderSize), timeRange: range)
        case .zoomIn:
            layer.setTransformRamp(fromStart: base, toEnd: zoomed(base, scale: 1.12, renderSize: renderSize), timeRange: range)
        case .zoomOut:
            layer.setTransformRamp(fromStart: zoomed(base, scale: 1.12, renderSize: renderSize), toEnd: base, timeRange: range)
        case .pushIn:
            layer.setTransformRamp(fromStart: base, toEnd: zoomed(base, scale: 1.20, renderSize: renderSize), timeRange: range)
        case .pullOut:
            layer.setTransformRamp(fromStart: zoomed(base, scale: 1.20, renderSize: renderSize), toEnd: base, timeRange: range)
        case .panLeft:
            layer.setTransformRamp(fromStart: translated(base, x: renderSize.width * 0.04), toEnd: translated(base, x: -renderSize.width * 0.04), timeRange: range)
        case .panRight:
            layer.setTransformRamp(fromStart: translated(base, x: -renderSize.width * 0.04), toEnd: translated(base, x: renderSize.width * 0.04), timeRange: range)
        case .mirror:
            layer.setTransform(base.concatenating(CGAffineTransform(translationX: renderSize.width, y: 0).scaledBy(x: -1, y: 1)), at: placement.start)
        }
    }

    private func applyTransition(_ style: TransitionStyle, incoming: AVMutableVideoCompositionLayerInstruction, outgoing: AVMutableVideoCompositionLayerInstruction, range: CMTimeRange, incomingPlacement: Placement, outgoingPlacement: Placement, renderSize: CGSize) {
        let incomingBase = Self.baseTransform(for: incomingPlacement.item, naturalSize: incomingPlacement.naturalSize, preferredTransform: incomingPlacement.preferredTransform, target: renderSize)
        let outgoingBase = Self.baseTransform(for: outgoingPlacement.item, naturalSize: outgoingPlacement.naturalSize, preferredTransform: outgoingPlacement.preferredTransform, target: renderSize)
        switch style {
        case .cut:
            break
        case .crossDissolve, .fade, .blurDissolve, .lightFlash, .zoom:
            incoming.setOpacityRamp(fromStartOpacity: 0, toEndOpacity: 1, timeRange: range)
            outgoing.setOpacityRamp(fromStartOpacity: 1, toEndOpacity: 0, timeRange: range)
            if style == .zoom {
                incoming.setTransformRamp(fromStart: zoomed(incomingBase, scale: 1.16, renderSize: renderSize), toEnd: incomingBase, timeRange: range)
                outgoing.setTransformRamp(fromStart: outgoingBase, toEnd: zoomed(outgoingBase, scale: 0.94, renderSize: renderSize), timeRange: range)
            }
        case .fadeThroughBlack:
            let half = CMTimeMultiplyByFloat64(range.duration, multiplier: 0.5)
            outgoing.setOpacityRamp(fromStartOpacity: 1, toEndOpacity: 0, timeRange: CMTimeRange(start: range.start, duration: half))
            incoming.setOpacity(0, at: range.start)
            incoming.setOpacityRamp(fromStartOpacity: 0, toEndOpacity: 1, timeRange: CMTimeRange(start: range.start + half, end: range.end))
        case .slideLeft:
            incoming.setTransformRamp(fromStart: translated(incomingBase, x: renderSize.width), toEnd: incomingBase, timeRange: range)
            outgoing.setTransformRamp(fromStart: outgoingBase, toEnd: translated(outgoingBase, x: -renderSize.width), timeRange: range)
        case .slideRight:
            incoming.setTransformRamp(fromStart: translated(incomingBase, x: -renderSize.width), toEnd: incomingBase, timeRange: range)
            outgoing.setTransformRamp(fromStart: outgoingBase, toEnd: translated(outgoingBase, x: renderSize.width), timeRange: range)
        case .push:
            incoming.setTransformRamp(fromStart: translated(incomingBase, x: renderSize.width), toEnd: incomingBase, timeRange: range)
            outgoing.setTransformRamp(fromStart: outgoingBase, toEnd: translated(outgoingBase, x: -renderSize.width), timeRange: range)
        case .wipeLeft:
            incoming.setCropRectangleRamp(fromStartCropRectangle: CGRect(x: renderSize.width, y: 0, width: 0, height: renderSize.height), toEndCropRectangle: CGRect(origin: .zero, size: renderSize), timeRange: range)
        case .wipeRight:
            incoming.setCropRectangleRamp(fromStartCropRectangle: CGRect(x: 0, y: 0, width: 0, height: renderSize.height), toEndCropRectangle: CGRect(origin: .zero, size: renderSize), timeRange: range)
        default:
            // Rich presets are routed through VeloVideoCompositor. This
            // fallback keeps old/native compositions readable if one reaches
            // this compatibility path.
            incoming.setOpacityRamp(fromStartOpacity: 0, toEndOpacity: 1, timeRange: range)
            outgoing.setOpacityRamp(fromStartOpacity: 1, toEndOpacity: 0, timeRange: range)
        }
    }

    private typealias MusicTrack = (track: AVMutableCompositionTrack, directive: MusicDirective)

    private func addMusic(_ directive: MusicDirective?, tracks: [LocalMusicTrack], to composition: AVMutableComposition, duration: CMTime) async throws -> MusicTrack? {
        guard let directive, duration > .zero else { return nil }
        guard let trackID = directive.trackID,
              let localTrack = tracks.first(where: { $0.id == trackID }),
              FileManager.default.fileExists(atPath: localTrack.localFileURL.path) else {
            return nil
        }
        let url = localTrack.localFileURL
        let source = AVURLAsset(url: url)
        guard let sourceTrack = try await source.loadTracks(withMediaType: .audio).first,
              let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { return nil }
        let sourceDuration = try await source.load(.duration)
        var cursor = CMTime.zero
        while cursor < duration {
            let remaining = duration - cursor
            let part = min(sourceDuration, remaining)
            try track.insertTimeRange(CMTimeRange(start: .zero, duration: part), of: sourceTrack, at: cursor)
            cursor = cursor + part
        }
        return (track, directive)
    }

    private func addAudioClips(
        _ clips: [TimelineAudioClip],
        assets: [UUID: MediaAsset],
        musicTracks: [LocalMusicTrack],
        to composition: AVMutableComposition,
        movieDuration: CMTime
    ) async throws -> (placements: [AudioPlacement], temporaryFiles: [URL]) {
        var placements: [AudioPlacement] = []
        var temporaryFiles: [URL] = []
        for clip in clips.sorted(by: { $0.timelineStart < $1.timelineStart }) {
            guard clip.timelineStart < movieDuration.seconds else { continue }
            let sourceURL: URL?
            if let assetID = clip.assetID {
                sourceURL = assets[assetID]?.originalURL
            } else if let trackID = clip.trackID {
                sourceURL = musicTracks.first(where: { $0.id == trackID })?.localFileURL
            } else {
                sourceURL = nil
            }
            guard let sourceURL, FileManager.default.fileExists(atPath: sourceURL.path),
                  let destinationTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }

            let inputURL: URL
            let sourceStart: Double
            if ProcessedAudioGenerator.needsRender(clip.adjustments) {
                let temporary = FileManager.default.temporaryDirectory
                    .appendingPathComponent("veloedit-timeline-audio-\(clip.id.uuidString)")
                    .appendingPathExtension("caf")
                inputURL = try await audioProcessor.generate(
                    sourceURL: sourceURL,
                    sourceStart: clip.sourceStart,
                    sourceDuration: clip.sourceDuration,
                    adjustments: clip.adjustments,
                    destination: temporary
                )
                sourceStart = 0
                temporaryFiles.append(temporary)
            } else {
                inputURL = sourceURL
                sourceStart = clip.sourceStart
            }

            let sourceAsset = AVURLAsset(url: inputURL)
            guard let sourceTrack = try await sourceAsset.loadTracks(withMediaType: .audio).first else { continue }
            let loadedDuration = try await sourceAsset.load(.duration).seconds
            let availableSource = max(0.05, loadedDuration - sourceStart)
            let sourceDuration = min(clip.sourceDuration, availableSource)
            let start = CMTime(seconds: clip.timelineStart, preferredTimescale: 600)
            let maximumDuration = max(0.05, (movieDuration - start).seconds)
            let targetDuration = CMTime(seconds: min(clip.timelineDuration, maximumDuration), preferredTimescale: 600)
            let insertedDuration = CMTime(seconds: sourceDuration, preferredTimescale: 600)
            try destinationTrack.insertTimeRange(
                CMTimeRange(start: CMTime(seconds: sourceStart, preferredTimescale: 600), duration: insertedDuration),
                of: sourceTrack,
                at: start
            )
            if insertedDuration != targetDuration {
                destinationTrack.scaleTimeRange(CMTimeRange(start: start, duration: insertedDuration), toDuration: targetDuration)
            }
            placements.append(AudioPlacement(clip: clip, track: destinationTrack, start: start, duration: targetDuration))
        }
        return (placements, temporaryFiles)
    }

    private func makeAudioMix(placements: [Placement], originalTracks: [AVMutableCompositionTrack], originalAudioVolume: Float, music: MusicTrack?, additionalAudio: [AudioPlacement], ducking: AudioDuckingSettings) -> AVMutableAudioMix? {
        guard !originalTracks.isEmpty || music != nil || !additionalAudio.isEmpty else { return nil }
        func clipVolume(_ placement: Placement) -> Float {
            originalAudioVolume * Float(placement.item.effectiveAudioAdjustments.effectiveVolume)
        }
        // AVFoundation raises an Objective-C exception (and aborts the app)
        // when two volume ramps overlap on the same composition track. A
        // track can receive ramps from clip fades, transitions and ducking,
        // so every source of automation must share one reservation table.
        var scheduledRampRanges: [CMPersistentTrackID: [CMTimeRange]] = [:]
        func scheduleVolumeRamp(
            on value: AVMutableAudioMixInputParameters,
            from startVolume: Float,
            to endVolume: Float,
            timeRange: CMTimeRange
        ) {
            guard timeRange.duration > .zero else { return }
            let trackID = value.trackID
            let overlapsExisting = scheduledRampRanges[trackID, default: []].contains { existing in
                timeRange.start < existing.end && existing.start < timeRange.end
            }
            guard !overlapsExisting else { return }
            value.setVolumeRamp(
                fromStartVolume: startVolume,
                toEndVolume: endVolume,
                timeRange: timeRange
            )
            scheduledRampRanges[trackID, default: []].append(timeRange)
        }
        var parameters: [AVAudioMixInputParameters] = originalTracks.map { track in
            let value = AVMutableAudioMixInputParameters(track: track)
            value.setVolume(0, at: .zero)
            let clips = placements.filter { $0.audioTrack?.trackID == track.trackID }
            value.audioTimePitchAlgorithm = clips.contains {
                ($0.item.effectiveAudioAdjustments.preservePitch ?? true) &&
                (abs($0.item.speed - 1) > 0.001 || $0.item.speedRamp != nil)
            } ? .spectral : .varispeed
            return value
        }
        // Alternating composition tracks are reused by non-adjacent clips.
        // Restore their level at every clip start; otherwise a previous
        // crossfade could leave a later clip muted.
        for placement in placements {
            guard let track = placement.audioTrack,
                  let value = parameters.first(where: { $0.trackID == track.trackID }) as? AVMutableAudioMixInputParameters else { continue }
            let volume = clipVolume(placement)
            let audio = placement.item.effectiveAudioAdjustments
            let fadeIn = min(audio.fadeIn, placement.duration.seconds * 0.45)
            let fadeOut = min(audio.fadeOut, placement.duration.seconds * 0.45)
            let previous = placements.last(where: { $0.index < placement.index })
            let hasIncomingCrossfade = placement.item.transition != nil &&
                previous.map { $0.end > placement.start } == true
            let next = placements.first(where: { $0.index > placement.index })
            let hasOutgoingCrossfade = next?.item.transition != nil &&
                next.map { placement.end > $0.start } == true
            if fadeIn > 0.001 && !hasIncomingCrossfade {
                let range = CMTimeRange(
                    start: placement.start,
                    duration: CMTime(seconds: fadeIn, preferredTimescale: 600)
                )
                scheduleVolumeRamp(on: value, from: 0, to: volume, timeRange: range)
            } else {
                value.setVolume(volume, at: placement.start)
            }
            if fadeOut > 0.001 && !hasOutgoingCrossfade {
                let duration = CMTime(seconds: fadeOut, preferredTimescale: 600)
                let range = CMTimeRange(start: max(placement.start, placement.end - duration), end: placement.end)
                scheduleVolumeRamp(on: value, from: volume, to: 0, timeRange: range)
            }
        }
        for placement in placements.dropFirst() {
            guard placement.item.transition != nil,
                  let incomingTrack = placement.audioTrack,
                  let previous = placements.last(where: { $0.index < placement.index }),
                  let outgoingTrack = previous.audioTrack else { continue }
            let duration = min(CMTime(seconds: 0.65, preferredTimescale: 600), previous.end - placement.start)
            guard duration > .zero else { continue }
            let range = CMTimeRange(start: placement.start, duration: duration)
            if let incoming = parameters.first(where: { $0.trackID == incomingTrack.trackID }) as? AVMutableAudioMixInputParameters {
                scheduleVolumeRamp(on: incoming, from: 0, to: clipVolume(placement), timeRange: range)
            }
            if let outgoing = parameters.first(where: { $0.trackID == outgoingTrack.trackID }) as? AVMutableAudioMixInputParameters {
                scheduleVolumeRamp(on: outgoing, from: clipVolume(previous), to: 0, timeRange: range)
            }
        }
        for placement in additionalAudio {
            let value = AVMutableAudioMixInputParameters(track: placement.track)
            let audio = placement.clip.adjustments
            let volume = Float(audio.effectiveVolume)
            let fadeIn = min(audio.fadeIn, placement.duration.seconds * 0.45)
            let fadeOut = min(audio.fadeOut, placement.duration.seconds * 0.45)
            if fadeIn > 0.001 {
                scheduleVolumeRamp(
                    on: value,
                    from: 0,
                    to: volume,
                    timeRange: CMTimeRange(start: placement.start, duration: CMTime(seconds: fadeIn, preferredTimescale: 600))
                )
            } else {
                value.setVolume(volume, at: placement.start)
            }
            if fadeOut > 0.001 {
                let fadeDuration = CMTime(seconds: fadeOut, preferredTimescale: 600)
                scheduleVolumeRamp(
                    on: value,
                    from: volume,
                    to: 0,
                    timeRange: CMTimeRange(start: max(placement.start, placement.end - fadeDuration), end: placement.end)
                )
            }
            parameters.append(value)
        }
        // A selected foreground/overlay clip may lower any other clip that is
        // audible underneath it. The ramps are baked into AVAudioMix, so the
        // behavior is identical in the viewer and final export.
        for foreground in placements where foreground.item.effectiveAudioAdjustments.duckOthers == true {
            let amount = Float(min(max(0, foreground.item.effectiveAudioAdjustments.duckingAmount ?? 0.5), 1))
            for background in placements where background.item.id != foreground.item.id {
                guard let track = background.audioTrack,
                      let value = parameters.first(where: { $0.trackID == track.trackID }) as? AVMutableAudioMixInputParameters else { continue }
                let start = max(foreground.start, background.start)
                let end = min(foreground.end, background.end)
                guard end > start else { continue }
                let normal = clipVolume(background)
                let reduced = normal * (1 - amount)
                let rampDuration = min(
                    CMTime(seconds: 0.18, preferredTimescale: 600),
                    CMTimeMultiplyByFloat64(end - start, multiplier: 0.5)
                )
                if rampDuration > .zero {
                    scheduleVolumeRamp(on: value, from: normal, to: reduced, timeRange: CMTimeRange(start: start, duration: rampDuration))
                    scheduleVolumeRamp(on: value, from: reduced, to: normal, timeRange: CMTimeRange(start: end - rampDuration, duration: rampDuration))
                } else {
                    value.setVolume(reduced, at: start)
                    value.setVolume(normal, at: end)
                }
            }
        }
        for foreground in additionalAudio where foreground.clip.adjustments.duckOthers == true {
            let amount = Float(min(max(0, foreground.clip.adjustments.duckingAmount ?? 0.5), 1))
            for background in additionalAudio where background.clip.id != foreground.clip.id {
                guard let value = parameters.first(where: { $0.trackID == background.track.trackID }) as? AVMutableAudioMixInputParameters else { continue }
                let start = max(foreground.start, background.start)
                let end = min(foreground.end, background.end)
                guard end > start else { continue }
                let normal = Float(background.clip.adjustments.effectiveVolume)
                let reduced = normal * (1 - amount)
                let ramp = min(CMTime(seconds: 0.18, preferredTimescale: 600), CMTimeMultiplyByFloat64(end - start, multiplier: 0.5))
                scheduleVolumeRamp(on: value, from: normal, to: reduced, timeRange: CMTimeRange(start: start, duration: ramp))
                scheduleVolumeRamp(on: value, from: reduced, to: normal, timeRange: CMTimeRange(start: end - ramp, duration: ramp))
            }
            for background in placements {
                guard let track = background.audioTrack,
                      let value = parameters.first(where: { $0.trackID == track.trackID }) as? AVMutableAudioMixInputParameters else { continue }
                let start = max(foreground.start, background.start)
                let end = min(foreground.end, background.end)
                guard end > start else { continue }
                let normal = clipVolume(background)
                let reduced = normal * (1 - amount)
                let ramp = min(CMTime(seconds: 0.18, preferredTimescale: 600), CMTimeMultiplyByFloat64(end - start, multiplier: 0.5))
                scheduleVolumeRamp(on: value, from: normal, to: reduced, timeRange: CMTimeRange(start: start, duration: ramp))
                scheduleVolumeRamp(on: value, from: reduced, to: normal, timeRange: CMTimeRange(start: end - ramp, duration: ramp))
            }
        }
        if let music {
            let value = AVMutableAudioMixInputParameters(track: music.track)
            let normal = Float(music.directive.volume)
            value.setVolume(normal, at: .zero)
            if ducking.enabled {
                let reduced = normal * Float(ducking.attenuation)
                let sourceRanges = (placements
                    .filter { $0.audioTrack != nil && clipVolume($0) > 0.001 }
                    .map { (start: $0.start.seconds, end: $0.end.seconds) }
                    + additionalAudio
                    .filter { $0.clip.role != .music && $0.clip.adjustments.effectiveVolume > 0.001 }
                    .map { (start: $0.start.seconds, end: $0.end.seconds) })
                    .sorted { $0.start < $1.start }
                var merged: [(start: Double, end: Double)] = []
                for range in sourceRanges {
                    if let last = merged.last, range.start <= last.end + max(ducking.attack, ducking.release) {
                        merged[merged.count - 1].end = max(last.end, range.end)
                    } else {
                        merged.append(range)
                    }
                }
                for range in merged {
                    let attack = CMTime(seconds: ducking.attack, preferredTimescale: 600)
                    let release = CMTime(seconds: ducking.release, preferredTimescale: 600)
                    let start = CMTime(seconds: range.start, preferredTimescale: 600)
                    let end = CMTime(seconds: range.end, preferredTimescale: 600)
                    let attackStart = max(.zero, start - attack)
                    if attackStart < start {
                        scheduleVolumeRamp(
                            on: value,
                            from: normal,
                            to: reduced,
                            timeRange: CMTimeRange(start: attackStart, end: start)
                        )
                    } else {
                        value.setVolume(reduced, at: start)
                    }
                    scheduleVolumeRamp(
                        on: value,
                        from: reduced,
                        to: normal,
                        timeRange: CMTimeRange(start: end, duration: release)
                    )
                }
            }
            parameters.append(value)
        }
        let mix = AVMutableAudioMix()
        mix.inputParameters = parameters
        return mix
    }

    private func zoomed(_ base: CGAffineTransform, scale: CGFloat, renderSize: CGSize) -> CGAffineTransform {
        base.concatenating(CGAffineTransform(translationX: renderSize.width / 2, y: renderSize.height / 2).scaledBy(x: scale, y: scale).translatedBy(x: -renderSize.width / 2, y: -renderSize.height / 2))
    }

    private func translated(_ base: CGAffineTransform, x: CGFloat) -> CGAffineTransform {
        base.concatenating(CGAffineTransform(translationX: x, y: 0))
    }

    private static func aspectFillTransform(naturalSize: CGSize, preferredTransform: CGAffineTransform, target: CGSize) -> CGAffineTransform {
        aspectTransform(naturalSize: naturalSize, preferredTransform: preferredTransform, target: target, fill: true)
    }

    private static func baseTransform(for item: TimelineItem, naturalSize: CGSize, preferredTransform: CGAffineTransform, target: CGSize) -> CGAffineTransform {
        let adjustments = item.effectiveVideoAdjustments
        let angle = CGFloat(adjustments.rotationQuarterTurns) * .pi / 2
        let transform = angle == 0 ? preferredTransform : preferredTransform.concatenating(CGAffineTransform(rotationAngle: angle))
        return aspectTransform(
            naturalSize: naturalSize,
            preferredTransform: transform,
            target: target,
            fill: adjustments.crop == .fill
        )
    }

    private static func displayTransform(for placement: Placement, active: [Placement], renderSize: CGSize) -> CGAffineTransform {
        var base = baseTransform(
            for: placement.item,
            naturalSize: placement.naturalSize,
            preferredTransform: placement.preferredTransform,
            target: renderSize
        )
        if let overlay = placement.item.overlay {
            switch overlay.style {
            case .pictureInPicture:
                let scale = CGFloat(overlay.scale)
                let margin = renderSize.height * 0.04
                let x: CGFloat = overlay.corner == .topLeft || overlay.corner == .bottomLeft
                    ? margin
                    : renderSize.width * (1 - scale) - margin
                let y: CGFloat = overlay.corner == .bottomLeft || overlay.corner == .bottomRight
                    ? margin
                    : renderSize.height * (1 - scale) - margin
                base = base.concatenating(CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: x, ty: y))
            case .splitScreen:
                base = base.concatenating(CGAffineTransform(a: 0.5, b: 0, c: 0, d: 1, tx: renderSize.width * 0.5, ty: 0))
            case .cutaway, .greenScreen:
                break
            }
        } else if active.contains(where: {
            $0.item.overlay?.style == .splitScreen && $0.item.overlay?.baseItemID == placement.item.id
        }) {
            base = base.concatenating(CGAffineTransform(a: 0.5, b: 0, c: 0, d: 1, tx: 0, ty: 0))
        }
        return base
    }

    private static func aspectTransform(naturalSize: CGSize, preferredTransform: CGAffineTransform, target: CGSize, fill: Bool) -> CGAffineTransform {
        let sourceRect = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
        let orientedSize = CGSize(width: abs(sourceRect.width), height: abs(sourceRect.height))
        guard orientedSize.width > 0, orientedSize.height > 0 else { return preferredTransform }
        let scale = fill
            ? max(target.width / orientedSize.width, target.height / orientedSize.height)
            : min(target.width / orientedSize.width, target.height / orientedSize.height)
        let x = (target.width - orientedSize.width * scale) / 2
        let y = (target.height - orientedSize.height * scale) / 2
        return preferredTransform
            .concatenating(CGAffineTransform(translationX: -sourceRect.minX, y: -sourceRect.minY))
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: x, y: y))
    }
}
