import Foundation
import AVFoundation
import QuartzCore
import CoreImage

/// A ready-to-play, non-exported timeline. Temporary photo and music
/// intermediates stay alive for as long as the playback object is retained.
public final class TimelinePlayback: @unchecked Sendable {
    public let composition: AVComposition
    public let videoComposition: AVVideoComposition?
    public let audioMix: AVAudioMix?
    public let audioMasteringReport: EditorialAudioMasteringReport?
    public let duration: Double
    public let renderedItemCount: Int
    public let skippedItemIDs: [UUID]
    public let warnings: [String]
    public let derivedMediaCacheHits: Int
    public let derivedMediaCacheMisses: Int
    private let temporaryFiles: [URL]

    init(composition: AVComposition, videoComposition: AVVideoComposition?, audioMix: AVAudioMix?, audioMasteringReport: EditorialAudioMasteringReport? = nil, duration: Double, renderedItemCount: Int, skippedItemIDs: [UUID], warnings: [String] = [], derivedMediaCacheHits: Int = 0, derivedMediaCacheMisses: Int = 0, temporaryFiles: [URL]) {
        self.composition = composition
        self.videoComposition = videoComposition
        self.audioMix = audioMix
        self.audioMasteringReport = audioMasteringReport
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
        var duckingEnabled: Bool? = nil
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
        outputColorProfile: VideoColorProfile? = nil,
        derivedMediaCacheURL: URL? = nil,
        forceVideoComposition: Bool = false,
        preferStableRealtimePreview: Bool = false,
        progress: (@Sendable (ImportProgress) -> Void)? = nil
    ) async throws -> TimelinePlayback {
        let timeline = TimelineFrameRatePolicy.applying(to: timeline, assets: assets)
        let assetByID = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) })
        let colorProfile = outputColorProfile ?? VideoColorPipeline.profile(timeline: timeline, assets: assets)
        let composition = AVMutableComposition()
        let videoTracks = (0..<4).compactMap { _ in composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) }
        guard videoTracks.count == 4 else { throw DerivedMediaError.noVideoTrack }
        // Reusing a track for a camera with a different clock must not inherit
        // the first camera's coarse timebase and round subsequent edit points.
        videoTracks.forEach { $0.naturalTimeScale = TimelineTiming.compositionTimescale }
        let originalAudioVolume = min(max(0, timeline.effectiveOriginalAudioVolume), 1)
        let originalAudioTracks: [AVMutableCompositionTrack?] = originalAudioVolume > 0.0001
            ? (0..<4).map { _ in composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) }
            : [nil, nil, nil, nil]
        let timescale = TimelineTiming.compositionTimescale
        let transitions = TimelineTiming.resolvedTransitions(items: timeline.items, transitionItems: timeline.effectiveTransitionItems)
        var resolvedItems = timeline.items
        for index in resolvedItems.indices where resolvedItems[index].overlay == nil {
            resolvedItems[index].transition = transitions.first { $0.incomingClipID == resolvedItems[index].id }?.style.rawValue
        }
        let retimedItems = TimelineTiming.retimed(resolvedItems)
        // Build the complete magnetic storyline before connected media. This
        // guarantees that every overlay can resolve its base even when project
        // JSON stores connected clips between primary items.
        let playableItems = (
            retimedItems.filter { $0.overlay == nil } +
            retimedItems.filter { $0.overlay != nil }.sorted { $0.timelineStart < $1.timelineStart }
        ).filter { $0.kind == .title || $0.assetID != nil }
        // Preview quality may change resolution, never the edit. Every visible
        // layer uses the same compositor in AVPlayer, paused posters and export.
        // Keep the stable-preview argument compatible with older callers;
        // only undecorated cuts qualify for native playback.
        let realtimeTitles = timeline.effectiveTitleItems.filter(\.enabled)
        let realtimeTelemetryItems = timeline.effectiveTelemetryItems
        let realtimeEffects = timeline.effectiveEffects.filter(\.enabled)
        let realtimeTransitionItems = transitions
        let targetAspectRatio = Double(max(1, timeline.width)) / Double(max(1, timeline.height))
        let hasEndingFade = (timeline.endingFadeDuration ?? 0) > 0
        let usesNativeCameraPath = !hasEndingFade && realtimeTelemetryItems.isEmpty && realtimeEffects.isEmpty && realtimeTitles.isEmpty && realtimeTransitionItems.isEmpty && !forceVideoComposition && Self.shouldUseNativeCameraPath(
            items: playableItems,
            assets: assetByID,
            targetAspectRatio: targetAspectRatio,
            frameRate: timeline.frameRate
        )
        let usesSafeFitBackground = playableItems.contains { item in
            guard item.kind == .video,
                  item.overlay == nil,
                  item.effectiveVideoAdjustments.crop == .fit,
                  let assetID = item.assetID,
                  let sourceAspectRatio = assetByID[assetID]?.displayAspectRatio,
                  sourceAspectRatio > 0 else { return false }
            return abs(log(sourceAspectRatio / targetAspectRatio)) > 0.015
        }
        // AVFoundation's neutral layer compositor may elide repeated frames:
        // frameDuration is a maximum cadence, not a CFR guarantee. Our tweening
        // compositor requests every delivery frame for mixed/retimed footage.
        let requiresFrameSampling = playableItems.contains { item in
            guard item.kind == .video else { return false }
            let rate = item.assetID.flatMap { assetByID[$0]?.metadata.frameRate }
            return (rate.map { abs($0 - timeline.frameRate) >= 0.001 } ?? true)
                || item.isFreezeFrame || item.isReversed || item.speedRamp != nil
                || abs(item.sourceDuration - item.timelineDuration) >= 0.000_001
        }
        let usesColorCompositor = requiresFrameSampling || playableItems.contains {
            Self.requiresPixelProcessing($0.effectiveVideoAdjustments) ||
            $0.overlay?.style == .greenScreen || $0.telemetryOverlay != nil
        } || hasEndingFade || usesSafeFitBackground || !realtimeTelemetryItems.isEmpty || !realtimeEffects.isEmpty || !realtimeTitles.isEmpty || !realtimeTransitionItems.isEmpty
        var temporaryFiles: [URL] = []
        var placements: [Placement] = []
        var skippedItemIDs: [UUID] = []
        var derivedMediaCacheHits = 0
        var derivedMediaCacheMisses = 0
        var cursor = CMTime.zero
        var resourcePacer = ResourceWorkPacer()
        // Many cuts reference one camera file. Reuse loaded AVFoundation
        // metadata within this build; never retain stale files across builds.
        var sourceAssets: [URL: AVURLAsset] = [:]
        var videoMetadata: [URL: (track: AVAssetTrack, size: CGSize, transform: CGAffineTransform)] = [:]

        for (index, item) in playableItems.enumerated() {
            try await resourcePacer.checkpoint()
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
                    ?? FileManager.default.temporaryDirectory.appendingPathComponent("veloedit-title-\(UUID().uuidString).mov")
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
                            frameRate: timeline.frameRate,
                            destination: temporary,
                            codec: forceVideoComposition && derivedMediaCacheURL == nil ? .proRes4444 : .h264
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
                let bakedMotion = item.effect.flatMap(ClipEffect.init(rawValue:))
                    ?? backgroundPreset?.animationMotion
                    ?? .zoomIn
                let identity = Self.photoCacheIdentity(item: item, asset: media, timeline: timeline, preset: backgroundPreset)
                let isPersistent = derivedMediaCacheURL != nil
                let destination = derivedMediaCacheURL?.appendingPathComponent("photo-\(identity).mov")
                    ?? FileManager.default.temporaryDirectory.appendingPathComponent("veloedit-playback-\(UUID().uuidString).mov")
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
                            frameRate: timeline.frameRate,
                            destination: temporary,
                            codec: forceVideoComposition && derivedMediaCacheURL == nil ? .proRes4444 : .h264,
                            motion: bakedMotion,
                            subjectReframe: item.effectiveVideoAdjustments.subjectReframe,
                            cropStyle: item.effectiveVideoAdjustments.crop,
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

            let metadata: (track: AVAssetTrack, size: CGSize, transform: CGAffineTransform)
            if let cached = videoMetadata[sourceURL] {
                metadata = cached
            } else {
                let source = sourceAssets[sourceURL] ?? AVURLAsset(url: sourceURL)
                sourceAssets[sourceURL] = source
                guard let track = try await source.loadTracks(withMediaType: .video).first else {
                    skippedItemIDs.append(item.id)
                    continue
                }
                metadata = (track, try await track.load(.naturalSize), try await track.load(.preferredTransform))
                videoMetadata[sourceURL] = metadata
            }
            let sourceVideo = metadata.track
            let sourceRange = CMTimeRange(
                start: TimelineTiming.compositionTime(sourceStart),
                duration: TimelineTiming.compositionTime(insertedSourceDuration)
            )
            let requestedDuration = TimelineTiming.compositionTime(item.timelineDuration)
            let overlayStart = item.overlay == nil ? 0 : TimelineTiming.playbackTime(forTimelineTime: item.timelineStart, timeline: timeline)
            let overlayEnd = item.overlay == nil ? 0 : TimelineTiming.playbackTime(forTimelineTime: item.timelineStart + item.timelineDuration, timeline: timeline)
            let targetDuration = item.overlay == nil
                ? requestedDuration
                : CMTime(seconds: max(1.0 / timeline.frameRate, overlayEnd - overlayStart), preferredTimescale: timescale)
            let previousPrimary = placements.last(where: { $0.item.overlay == nil })
            let overlap = item.overlay == nil && !usesNativeCameraPath
                ? TimelineTiming.compositionTime(TimelineTiming.transitionOverlap(incoming: item, previous: previousPrimary?.item, transitionItems: transitions))
                : .zero
            let at = item.overlay == nil
                ? max(.zero, cursor - overlap)
                : CMTime(seconds: overlayStart, preferredTimescale: timescale)
            let trackIndex: Int
            if usesNativeCameraPath {
                trackIndex = 0
            } else if item.overlay != nil {
                // Primaries own tracks 0/1. Inserting a connected clip into
                // either track shifts already assembled primary segments and
                // leaves the compositor's placement ranges pointing at gaps.
                guard let available = [2, 3].first(where: { index in
                    !placements.contains { $0.track.trackID == videoTracks[index].trackID && $0.start < at + targetDuration && $0.end > at }
                }) else { throw DerivedMediaError.noVideoTrack }
                trackIndex = available
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
            var insertedAudioTrack: AVMutableCompositionTrack?
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
                        .appendingPathComponent("veloedit-processed-audio-\(UUID().uuidString)")
                        .appendingPathExtension("caf")
                    audioSourceURL = try await audioProcessor.generate(
                        sourceURL: media.originalURL,
                        sourceStart: item.sourceStart,
                        sourceDuration: item.sourceDuration,
                        adjustments: audioAdjustments,
                        destination: temporary,
                        cacheDirectory: derivedMediaCacheURL
                    )
                    audioSourceStart = 0
                    if derivedMediaCacheURL == nil { temporaryFiles.append(temporary) }
                } else {
                    audioSourceURL = media.originalURL
                    audioSourceStart = item.sourceStart
                }
                let audioSource = sourceAssets[audioSourceURL] ?? AVURLAsset(url: audioSourceURL)
                sourceAssets[audioSourceURL] = audioSource
                if let sourceAudio = try await audioSource.loadTracks(withMediaType: .audio).first {
                    let audioRange = CMTimeRange(
                        start: CMTime(seconds: audioSourceStart, preferredTimescale: timescale),
                        duration: CMTime(seconds: item.sourceDuration, preferredTimescale: timescale)
                    )
                    if let audioTrack {
                        do {
                            if let ramp = item.speedRamp {
                                _ = try insert(ramp: ramp, sourceRange: audioRange, sourceTrack: sourceAudio,
                                    destinationTrack: audioTrack, at: at)
                            } else {
                                try audioTrack.insertTimeRange(audioRange, of: sourceAudio, at: at)
                            }
                            insertedAudioTrack = audioTrack
                        } catch { /* A missing audio segment must not duck the soundtrack. */ }
                    }
                }
            }
            if insertedTimelineDuration != targetDuration {
                let insertedRange = CMTimeRange(start: at, duration: insertedTimelineDuration)
                videoTrack.scaleTimeRange(insertedRange, toDuration: targetDuration)
                insertedAudioTrack?.scaleTimeRange(insertedRange, toDuration: targetDuration)
            }

            var placedItem = item
            if placedItem.kind == .photo {
                // Photo framing is baked from the full EXIF-oriented image.
                // Applying the same normalized camera move again to the
                // generated target-sized movie would double-crop it.
                var adjustments = placedItem.effectiveVideoAdjustments
                adjustments.subjectReframe = nil
                placedItem.videoAdjustments = adjustments.isNeutral ? nil : adjustments
                let backgroundPreset = media.flatMap { BackgroundPreset.preset(for: $0) }
                if backgroundPreset?.animationStyle == nil,
                   placedItem.effect != ClipEffect.mirror.rawValue {
                    placedItem.effect = nil
                }
            }
            placements.append(Placement(
                index: placements.count,
                item: placedItem,
                track: videoTrack,
                audioTrack: insertedAudioTrack,
                start: at,
                duration: targetDuration,
                naturalSize: metadata.size,
                preferredTransform: metadata.transform
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
                timeline: timeline,
                telemetryItems: realtimeTelemetryItems,
                effects: realtimeEffects,
                titles: realtimeTitles,
                transitionItems: realtimeTransitionItems,
                telemetry: telemetry,
                renderSize: renderSize,
                frameRate: timeline.frameRate,
                colorProfile: colorProfile,
                endingFade: FilmEndingFade(duration: timeline.endingFadeDuration, movieDuration: cursor.seconds, frameRate: timeline.frameRate)
            )
        } else {
            videoComposition = makeVideoComposition(placements: placements, renderSize: renderSize, frameRate: timeline.frameRate, colorProfile: colorProfile)
        }
        if !usesColorCompositor {
            addTitleOverlays(
                to: videoComposition,
                titles: realtimeTitles,
                telemetryItems: realtimeTelemetryItems,
                placements: placements,
                telemetry: telemetry,
                renderSize: renderSize,
                duration: cursor
            )
        }
        if timeline.music != nil {
            progress?(ImportProgress(completed: playableItems.count, total: playableItems.count, currentName: "Добавляю локальный саундтрек"))
        }
        let adaptivePlan = timeline.effectiveAdaptiveSoundtrack
        let adaptiveWarning = Self.adaptiveSoundtrackWarning(for: adaptivePlan, tracks: musicTracks)
        let usesAdaptiveSoundtrack = adaptivePlan != nil && adaptiveWarning == nil
        let unavailableSoundtrack = Self.soundtrackWarning(for: timeline.music, tracks: musicTracks)
        let musicResult = !usesAdaptiveSoundtrack && unavailableSoundtrack == nil
            ? try await addMusic(timeline.music, tracks: musicTracks, to: composition, duration: cursor)
            : nil
        let adaptiveMusic = usesAdaptiveSoundtrack
            ? try await addAdaptiveMusic(adaptivePlan, master: timeline.music, tracks: musicTracks, timeline: timeline, to: composition, movieDuration: cursor)
            : []
        let renderAudioClips = timeline.effectiveAudioClips.map { clip -> TimelineAudioClip in
            var result = clip
            if let attachedID = clip.attachedToItemID,
               let placement = placements.first(where: { $0.item.id == attachedID }) {
                // Detached source audio must retain its owner's media clock,
                // including the full portion participating in a transition.
                result.timelineStart = max(0, placement.start.seconds + clip.timelineStart - placement.item.timelineStart)
            } else {
                result.timelineStart = TimelineTiming.playbackTime(forTimelineTime: clip.timelineStart, timeline: timeline)
                let end = TimelineTiming.playbackTime(forTimelineTime: clip.timelineEnd, timeline: timeline)
                result.timelineDuration = max(0.05, end - result.timelineStart)
            }
            return result
        }
        let audioResult = try await addAudioClips(
            renderAudioClips,
            assets: assetByID,
            musicTracks: musicTracks,
            to: composition,
            movieDuration: cursor,
            derivedMediaCacheURL: derivedMediaCacheURL
        )
        temporaryFiles.append(contentsOf: audioResult.temporaryFiles)
        let soundtrackWarning = (adaptiveWarning != nil && musicResult != nil
            ? "Один из адаптивных музыкальных фрагментов недоступен — использован цельный основной трек."
            : unavailableSoundtrack) ?? (timeline.music != nil && musicResult == nil && adaptiveMusic.isEmpty
            ? "Саундтрек недоступен — просмотр собран без музыки. Видео и звук исходников сохранены."
            : nil)
        // Reserved tracks are useful while assigning alternating clips, but
        // AVAssetExportSession rejects empty tracks with OSStatus -12123.
        // Preview frame extraction tolerates them, hiding the export failure.
        for track in composition.tracks where track.segments.isEmpty {
            composition.removeTrack(track)
        }
        let audioMix: AVAudioMix? = makeAudioMix(
            placements: placements,
            originalTracks: originalAudioTracks.compactMap { $0 }.filter { !$0.segments.isEmpty },
            originalAudioVolume: Float(originalAudioVolume),
            music: musicResult,
            additionalAudio: audioResult.placements + adaptiveMusic,
            ducking: SourceAudioMixPolicy.musicDucking(in: timeline),
            movieDuration: cursor.seconds,
            frameRate: timeline.frameRate,
            speechRanges: timeline.speechRecords == nil ? nil : timeline.items.flatMap { item -> [ClosedRange<Double>] in
                guard item.overlay == nil, item.effectiveAudioAdjustments.effectiveVolume > 0, originalAudioVolume > 0,
                      let id = item.assetID, let record = timeline.speechRecords?.first(where: { $0.assetID == id }) else { return [] }
                return (record.transcript.speechRanges ?? record.transcript.sentences.map { $0.startTime...$0.endTime }).compactMap { range in
                    let a = max(item.sourceStart, range.lowerBound); let b = min(item.sourceStart + item.sourceDuration, range.upperBound)
                    guard b > a else { return nil }
                    return SpeechTimeMap.playbackRange(anchor: SpeechCaptionAnchor(key: "mix", assetID: id, sourceStart: a, sourceEnd: b, words: []), item: item, timeline: timeline)
                }
            }
        )

        // Exact loudness mastering happens against an encoded first pass in
        // RenderEngine. Playback stays immediate and cannot fail because an
        // optional audio-only transcode rejects a heterogeneous source mix.
        let audioMasteringReport: EditorialAudioMasteringReport? = nil
        progress?(ImportProgress(completed: playableItems.count, total: playableItems.count, currentName: "Просмотр готов"))
        if let derivedMediaCacheURL {
            let inUse = Set(composition.tracks.flatMap { $0.segments.compactMap(\.sourceURL) }.map { $0.resolvingSymlinksInPath() })
            Self.pruneDerivedMediaCache(derivedMediaCacheURL, maximumFiles: 128, maximumBytes: 2_000_000_000, protectedURLs: inUse)
        }
        return TimelinePlayback(
            composition: composition,
            videoComposition: videoComposition,
            audioMix: audioMix,
            audioMasteringReport: audioMasteringReport,
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
            "title-v4-rational-fps", item.title ?? "", style,
            String(Int((item.timelineDuration * 1_000).rounded())),
            "\(timeline.width)x\(timeline.height)@\(timeline.frameRate)"
        ])
    }

    private static func photoCacheIdentity(
        item: TimelineItem,
        asset: MediaAsset,
        timeline: Timeline,
        preset: BackgroundPreset?
    ) -> String {
        ProductionCacheIdentity.hash([
            "photo-v8-rational-fps", asset.contentHash, item.effect ?? "zoom-in",
            item.effectiveVideoAdjustments.crop.rawValue,
            preset?.rawValue ?? "photo", preset?.animationStyle?.rawValue ?? "none",
            item.effectiveVideoAdjustments.subjectReframe.map {
                (try? JSONEncoder().encode($0).base64EncodedString()) ?? "invalid-reframe"
            } ?? "no-reframe",
            String(Int((item.timelineDuration * 1_000).rounded())),
            "\(timeline.width)x\(timeline.height)@\(timeline.frameRate)"
        ])
    }

    private static func pruneDerivedMediaCache(_ directory: URL, maximumFiles: Int, maximumBytes: Int64, protectedURLs: Set<URL>) {
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
            guard let index = records.lastIndex(where: { !protectedURLs.contains($0.url.resolvingSymlinksInPath()) }) else { break }
            let record = records.remove(at: index)
            if (try? FileManager.default.removeItem(at: record.url)) != nil { total -= record.size }
        }
    }

    private static func shouldUseNativeCameraPath(
        items: [TimelineItem],
        assets: [UUID: MediaAsset],
        targetAspectRatio: Double,
        frameRate: Double
    ) -> Bool {
        guard !items.isEmpty, items.allSatisfy({
            $0.kind == .video && $0.effect == nil &&
            $0.transition == nil && $0.overlay == nil &&
            $0.telemetryOverlay == nil && $0.effectiveVideoAdjustments.isNeutral &&
            !$0.isFreezeFrame && !$0.isReversed && $0.speedRamp == nil &&
            abs($0.sourceDuration - $0.timelineDuration) < 0.000_001 &&
            $0.assetID.flatMap { assets[$0]?.metadata.frameRate }.map { abs($0 - frameRate) < 0.001 } == true
        }) else { return false }
        let descriptors = items.compactMap { item -> String? in
            guard let id = item.assetID, let metadata = assets[id]?.metadata,
                  let width = metadata.width, let height = metadata.height else { return nil }
            return "\(width)x\(height)@\(metadata.orientationDegrees)"
        }
        guard descriptors.count == items.count, Set(descriptors).count == 1,
              let firstID = items.first?.assetID, let asset = assets[firstID],
              let sourceAspectRatio = asset.displayAspectRatio,
              sourceAspectRatio > 0, targetAspectRatio > 0,
              abs(log(sourceAspectRatio / targetAspectRatio)) <= 0.015,
              let metadata = assets[firstID]?.metadata,
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

    public nonisolated static func adaptiveSoundtrackWarning(for plan: AdaptiveSoundtrackPlan?, tracks: [LocalMusicTrack]) -> String? {
        guard let plan else { return nil }
        let available = Set(tracks.filter(\.isPlayable).map(\.id))
        return plan.segments.allSatisfy { segment in
            (plan.userEdited == true && segment.directive.volume <= 0.001)
                || segment.directive.trackID.map(available.contains) == true
        } ? nil : "Один или несколько адаптивных музыкальных фрагментов недоступны."
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

    private func makeVideoComposition(placements: [Placement], renderSize: CGSize, frameRate: Double, colorProfile: VideoColorProfile) -> AVMutableVideoComposition {
        let result = AVMutableVideoComposition()
        result.renderSize = renderSize
        result.frameDuration = VideoFrameTiming.duration(for: frameRate)
        Self.apply(colorProfile, to: result)
        let boundaries = Set(placements.flatMap { [$0.start, $0.end] }.map(Self.instructionBoundary)).sorted()
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
        timeline: Timeline,
        telemetryItems: [TimelineTelemetryItem],
        effects: [EffectTimelineItem],
        titles: [TitleTimelineItem],
        transitionItems: [TimelineTransitionItem],
        telemetry: [UUID: TelemetrySummary],
        renderSize: CGSize,
        frameRate: Double,
        colorProfile: VideoColorProfile,
        endingFade: FilmEndingFade? = nil
    ) -> AVMutableVideoComposition {
        let result = AVMutableVideoComposition()
        result.customVideoCompositorClass = colorProfile.dynamicRange == .hdr
            ? VeloHDRVideoCompositor.self
            : VeloVideoCompositor.self
        result.renderSize = renderSize
        result.frameDuration = VideoFrameTiming.duration(for: frameRate)
        Self.apply(colorProfile, to: result)
        let placementByClipID = Dictionary(uniqueKeysWithValues: placements.map { ($0.item.id, $0) })
        // Speech captions follow the audio placement, including the portion of
        // an outgoing voice that continues through a transition overlap.
        let titles = titles.map { title -> TitleTimelineItem in
            guard let anchor = title.speechAnchor, let id = title.targetClipID,
                  let placement = placementByClipID[id],
                  let a = SpeechTimeMap.timelineTime(sourceTime: anchor.sourceStart, item: placement.item),
                  let b = SpeechTimeMap.timelineTime(sourceTime: anchor.sourceEnd, item: placement.item) else { return title }
            var value = title
            value.startTime = a
            value.duration = b - a
            value.words = SpeechSubtitleBuilder.measuredCaptionWords(for: value, item: placement.item)
            value.startTime = placement.start.seconds + a - placement.item.timelineStart
            return value
        }

        func playbackTime(_ time: Double) -> CMTime {
            TimelineTiming.compositionTime(TimelineTiming.playbackTime(forTimelineTime: time, timeline: timeline))
        }
        func editorTime(_ time: CMTime) -> CMTime {
            TimelineTiming.compositionTime(TimelineTiming.timelineTime(forPlaybackTime: time.seconds, timeline: timeline))
        }
        let telemetryRanges = Dictionary(uniqueKeysWithValues: telemetryItems.map {
            ($0.id, CMTimeRange(start: playbackTime($0.timelineStart), end: playbackTime($0.timelineEnd)))
        })
        let telemetryBoundaries = telemetryRanges.values.flatMap { [$0.start, $0.end] }
        let effectBoundaries = effects.filter(\.enabled).flatMap {
            [playbackTime($0.startTime), playbackTime($0.endTime)]
        }
        let titleBoundaries = titles.filter(\.enabled).flatMap { title in
            title.speechAnchor == nil ? [playbackTime(title.startTime), playbackTime(title.endTime)] : [TimelineTiming.compositionTime(title.startTime), TimelineTiming.compositionTime(title.endTime)]
        }
        // Boundaries arrive from both media timebases and JSON seconds. Two
        // mathematically identical instants can therefore differ by a tiny
        // fraction (for example 129.366666667 vs 129.36666666666667). Leaving
        // both in the set creates overlapping instructions, which AVFoundation
        // rejects with -11841/-17390 before invoking the custom compositor.
        let boundaries = Set(
            (placements.flatMap { [$0.start, $0.end] } + telemetryBoundaries + effectBoundaries + titleBoundaries)
                .map(Self.instructionBoundary)
        ).sorted()
        result.instructions = zip(boundaries, boundaries.dropFirst()).compactMap { start, end in
            guard start < end else { return nil }
            let range = CMTimeRange(start: start, end: end)
            let timelineRange = CMTimeRange(start: editorTime(start), end: editorTime(end))
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
                    naturalSize: placement.naturalSize,
                    transform: Self.displayTransform(for: placement, active: active, renderSize: renderSize),
                    telemetry: placement.item.assetID.flatMap { telemetry[$0] }
                )
            }
            let primaries = active.filter { $0.item.overlay == nil }
            let explicitTransition = primaries.count == 2
                ? transitionItems.first(where: {
                    $0.enabled && $0.incomingClipID == primaries[0].item.id && $0.outgoingClipID == primaries[1].item.id
                })
                : nil
            let transitionItem = explicitTransition.map { transition -> TimelineTransitionItem in
                var result = transition
                // Effect/title/overlay boundaries may split this overlap into
                // several instructions. All must share one animation clock.
                result.startTime = primaries[0].start.seconds
                result.duration = (min(primaries[0].end, primaries[1].end) - primaries[0].start).seconds
                return result
            }
            let activeTelemetry = telemetryItems.compactMap { item -> VeloTelemetryLayer? in
                guard let itemRange = telemetryRanges[item.id], itemRange.start < range.end, itemRange.end > range.start,
                      let summary = item.sourceID.flatMap({ telemetry[$0] }) ?? item.linkedAssetID.flatMap({ telemetry[$0] }) else { return nil }
                let targetClip = item.targetClipID.flatMap { placementByClipID[$0]?.item }
                return VeloTelemetryLayer(item: item, telemetry: summary, targetClip: targetClip, start: itemRange.start, duration: itemRange.duration)
            }
            let activeEffects = effects.filter { $0.enabled && $0.startTime < timelineRange.end.seconds && $0.endTime > timelineRange.start.seconds }
            let activeClipIDs = Set(active.map(\.item.id))
            let activeTitles = titles.filter {
                $0.enabled && $0.startTime < ($0.speechAnchor == nil ? timelineRange.end.seconds : range.end.seconds) && $0.endTime > ($0.speechAnchor == nil ? timelineRange.start.seconds : range.start.seconds) &&
                ($0.targetClipID.map { activeClipIDs.contains($0) } ?? true)
            }
            return VeloVideoInstruction(timeRange: range, layers: layers, telemetryLayers: activeTelemetry, effects: activeEffects, titles: activeTitles, transition: transitionItem?.style, transitionItem: transitionItem, renderSize: renderSize, colorProfile: colorProfile, endingFade: endingFade, timelineTimeRange: timelineRange)
        }
        return result
    }

    private static func instructionBoundary(_ time: CMTime) -> CMTime {
        CMTimeConvertScale(time, timescale: TimelineTiming.compositionTimescale, method: .roundHalfAwayFromZero)
    }

    private static func apply(_ profile: VideoColorProfile, to composition: AVMutableVideoComposition) {
        if profile.dynamicRange == .hdr {
            composition.colorPrimaries = AVVideoColorPrimaries_ITU_R_2020
            composition.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_2020
            composition.colorTransferFunction = profile.transferFunction == .pq
                ? AVVideoTransferFunction_SMPTE_ST_2084_PQ
                : AVVideoTransferFunction_ITU_R_2100_HLG
        } else {
            composition.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
            composition.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
            composition.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
        }
    }

    private func addTitleOverlays(
        to composition: AVMutableVideoComposition?,
        titles: [TitleTimelineItem],
        telemetryItems: [TimelineTelemetryItem],
        placements: [Placement],
        telemetry: [UUID: TelemetrySummary],
        renderSize: CGSize,
        duration: CMTime
    ) {
        let placementByID = Dictionary(uniqueKeysWithValues: placements.map { ($0.item.id, $0) })
        let explicitTelemetry: [(TimelineTelemetryItem, Placement, TelemetrySummary)] = telemetryItems.compactMap { item in
            guard let placement = item.targetClipID.flatMap({ placementByID[$0] }),
                  let summary = item.sourceID.flatMap({ telemetry[$0] })
                    ?? item.linkedAssetID.flatMap({ telemetry[$0] })
                    ?? placement.item.assetID.flatMap({ telemetry[$0] }) else { return nil }
            return (item, placement, summary)
        }
        let embeddedTelemetry: [(TimelineTelemetryItem, Placement, TelemetrySummary)] = telemetryItems.isEmpty ? placements.compactMap { placement in
            guard let settings = placement.item.telemetryOverlay,
                  let assetID = placement.item.assetID,
                  let summary = telemetry[assetID] else { return nil }
            return (
                TimelineTelemetryItem(
                    targetClipID: placement.item.id,
                    sourceID: assetID,
                    sourceStart: placement.item.sourceStart,
                    timelineStart: placement.start.seconds,
                    timelineDuration: placement.duration.seconds,
                    settings: settings
                ),
                placement,
                summary
            )
        } : []
        let telemetryLayers = explicitTelemetry + embeddedTelemetry
        guard let composition, !titles.isEmpty || !telemetryLayers.isEmpty else { return }
        let videoLayer = CALayer()
        videoLayer.frame = CGRect(origin: .zero, size: renderSize)
        let parentLayer = CALayer()
        parentLayer.frame = videoLayer.frame
        parentLayer.addSublayer(videoLayer)

        for title in titles where title.enabled {
            let sampleTime = title.startTime + min(title.duration * 0.5, 0.4)
            guard let image = TitleOverlayRenderer.cgImage(
                item: title,
                timelineTime: sampleTime,
                renderSize: renderSize
            ) else { continue }
            let layer = CALayer()
            layer.frame = videoLayer.frame
            layer.contents = image
            layer.contentsGravity = .resize
            layer.opacity = 0
            layer.add(
                Self.visibilityAnimation(
                    start: title.startTime,
                    visibleDuration: title.duration,
                    totalDuration: duration.seconds
                ),
                forKey: "veloedit-visibility"
            )
            parentLayer.addSublayer(layer)
        }
        let ciContext = CIContext(options: [.cacheIntermediates: true])
        let fullBounds = CGRect(origin: .zero, size: renderSize)
        for (item, placement, summary) in telemetryLayers {
            let start = placement.start.seconds
            let visibleDuration = placement.duration.seconds
            let sampleCount = min(30, max(2, Int(ceil(visibleDuration * 4))))
            let images: [CGImage] = (0..<sampleCount).compactMap { index -> CGImage? in
                let progress = sampleCount == 1 ? 0 : Double(index) / Double(sampleCount - 1)
                let sourceTime = item.sourceStart + item.syncOffset + placement.item.sourceDuration * progress
                guard let image = TelemetryOverlayRenderer.image(
                    settings: item.settings,
                    telemetry: summary,
                    progress: progress,
                    sourceTime: sourceTime,
                    renderSize: renderSize
                ) else { return nil }
                return ciContext.createCGImage(image, from: fullBounds)
            }
            guard let first = images.first else { continue }
            let layer = CALayer()
            layer.frame = videoLayer.frame
            layer.contents = first
            layer.contentsGravity = .resize
            layer.opacity = 0
            if images.count > 1 {
                let animation = CAKeyframeAnimation(keyPath: "contents")
                animation.values = images
                animation.keyTimes = images.indices.map { NSNumber(value: Double($0) / Double(images.count - 1)) }
                animation.calculationMode = .discrete
                animation.beginTime = AVCoreAnimationBeginTimeAtZero + start
                animation.duration = max(0.1, visibleDuration)
                animation.fillMode = .both
                animation.isRemovedOnCompletion = false
                layer.add(animation, forKey: "veloedit-telemetry-frames")
            }
            layer.add(
                Self.visibilityAnimation(start: start, visibleDuration: visibleDuration, totalDuration: duration.seconds),
                forKey: "veloedit-visibility"
            )
            parentLayer.addSublayer(layer)
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
        let range = CMTimeRange(start: placement.start, duration: placement.duration)
        let startBase = Self.nativeReframeTransform(base, placement: placement, progress: 0, renderSize: renderSize)
        let endBase = Self.nativeReframeTransform(base, placement: placement, progress: 1, renderSize: renderSize)
        guard let effect else {
            if startBase != endBase {
                layer.setTransformRamp(fromStart: startBase, toEnd: endBase, timeRange: range)
            } else {
                layer.setTransform(startBase, at: placement.start)
            }
            return
        }
        switch effect {
        case .kenBurns:
            layer.setTransformRamp(fromStart: startBase, toEnd: zoomed(endBase, scale: 1.08, renderSize: renderSize), timeRange: range)
        case .zoomIn:
            layer.setTransformRamp(fromStart: startBase, toEnd: zoomed(endBase, scale: 1.12, renderSize: renderSize), timeRange: range)
        case .zoomOut:
            layer.setTransformRamp(fromStart: zoomed(startBase, scale: 1.12, renderSize: renderSize), toEnd: endBase, timeRange: range)
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
        guard sourceDuration.seconds.isFinite, sourceDuration.seconds > 0 else { return nil }
        let sourceEnd = CMTimeConvertScale(sourceDuration, timescale: TimelineTiming.compositionTimescale, method: .roundTowardZero)
        var sourceCursor = TimelineTiming.compositionTime(min(max(0, directive.sourceStart ?? 0), max(0, sourceEnd.seconds - 0.05)))
        var cursor = CMTime.zero
        while cursor < duration {
            let remaining = duration - cursor
            let availableSource = sourceEnd - sourceCursor
            let outputPart = min(availableSource.seconds / directive.effectiveSpeed, remaining.seconds)
            // Use the video composition's clock throughout. A 600 Hz loop
            // leaves a sub-tick remainder on mixed-camera timelines and then
            // inserts an empty range, failing the entire preview/export with
            // AVFoundation -11800 / OSStatus -12780.
            let inserted = min(availableSource, TimelineTiming.compositionTime(outputPart * directive.effectiveSpeed))
            let output = min(remaining, TimelineTiming.compositionTime(outputPart))
            guard inserted > .zero, output > .zero else { break }
            try track.insertTimeRange(CMTimeRange(start: sourceCursor, duration: inserted), of: sourceTrack, at: cursor)
            if inserted != output {
                track.scaleTimeRange(CMTimeRange(start: cursor, duration: inserted), toDuration: output)
            }
            cursor = cursor + output
            sourceCursor = .zero
        }
        return (track, directive)
    }

    /// Places every semantic music region on its own composition track. The
    /// overlap is centered on the exact rendered position of the visual cut,
    /// so a transition overlap cannot make the soundtrack switch drift late.
    private func addAdaptiveMusic(
        _ plan: AdaptiveSoundtrackPlan?,
        master: MusicDirective?,
        tracks: [LocalMusicTrack],
        timeline: Timeline,
        to composition: AVMutableComposition,
        movieDuration: CMTime
    ) async throws -> [AudioPlacement] {
        guard let plan, let master, movieDuration > .zero else { return [] }
        var placements: [AudioPlacement] = []
        for index in plan.segments.indices {
            let segment = plan.segments[index]
            if plan.userEdited == true && segment.directive.volume <= 0.001 { continue }
            guard let trackID = segment.directive.trackID,
                  let localTrack = tracks.first(where: { $0.id == trackID }),
                  localTrack.isPlayable,
                  let destinationTrack = composition.addMutableTrack(
                    withMediaType: .audio,
                    preferredTrackID: kCMPersistentTrackID_Invalid
                  ) else { continue }
            let source = AVURLAsset(url: localTrack.localFileURL)
            guard let sourceTrack = try await source.loadTracks(withMediaType: .audio).first else { continue }
            let sourceDuration = try await source.load(.duration).seconds
            guard sourceDuration > 0.05 else { continue }
            // Quantizing a floating-point asset duration to the composition's
            // 600 Hz clock can otherwise round the final loop a fraction past
            // the source and make AVFoundation reject the whole soundtrack.
            let safeSourceDuration = max(0.05, sourceDuration - 1.0 / 600.0)

            let coreStartSeconds = TimelineTiming.playbackTime(
                forTimelineTime: segment.timelineStart,
                timeline: timeline
            )
            let coreEndSeconds = TimelineTiming.playbackTime(
                forTimelineTime: segment.timelineEnd,
                timeline: timeline
            )
            let incomingTransition = index == plan.segments.startIndex ? 0 : segment.transitionDuration
            let outgoingTransition = index < plan.segments.index(before: plan.segments.endIndex)
                ? plan.segments[index + 1].transitionDuration
                : 0
            let renderedStartSeconds = max(0, coreStartSeconds - incomingTransition * 0.5)
            let renderedEndSeconds = min(movieDuration.seconds, coreEndSeconds + outgoingTransition * 0.5)
            guard renderedEndSeconds - renderedStartSeconds > 0.05 else { continue }

            let renderedStart = CMTime(seconds: renderedStartSeconds, preferredTimescale: 600)
            let renderedEnd = CMTime(seconds: renderedEndSeconds, preferredTimescale: 600)
            let speed = segment.directive.effectiveSpeed
            var destinationCursor = renderedStart
            var sourceCursor = max(0, segment.sourceStart).truncatingRemainder(dividingBy: safeSourceDuration)
            while destinationCursor < renderedEnd {
                let remainingOutput = (renderedEnd - destinationCursor).seconds
                let availableSource = max(0.05, safeSourceDuration - sourceCursor)
                let sourcePart = min(availableSource, remainingOutput * speed)
                let outputPart = min(remainingOutput, sourcePart / speed)
                let inserted = CMTime(seconds: sourcePart, preferredTimescale: 600)
                let output = CMTime(seconds: outputPart, preferredTimescale: 600)
                try destinationTrack.insertTimeRange(
                    CMTimeRange(
                        start: CMTime(seconds: sourceCursor, preferredTimescale: 600),
                        duration: inserted
                    ),
                    of: sourceTrack,
                    at: destinationCursor
                )
                if abs(sourcePart - outputPart) > 0.000_1 {
                    destinationTrack.scaleTimeRange(
                        CMTimeRange(start: destinationCursor, duration: inserted),
                        toDuration: output
                    )
                }
                destinationCursor = destinationCursor + output
                sourceCursor = 0
            }

            let renderedDuration = max(0.05, (renderedEnd - renderedStart).seconds)
            let fadeIn = index == plan.segments.startIndex
                ? min(0.9, renderedDuration * 0.20)
                : min(incomingTransition, renderedDuration * 0.45)
            // The shared movie-level fade handles the final region, even
            // when it is shorter than the finish and spans a music change.
            let fadeOut = min(outgoingTransition, renderedDuration * 0.45)
            let energyGain = 0.92 + segment.energy * 0.12
            let clip = TimelineAudioClip(
                trackID: trackID,
                title: "Adaptive · \(segment.semanticLabel) · \(localTrack.title)",
                role: .music,
                sourceStart: segment.sourceStart,
                sourceDuration: min(safeSourceDuration, max(0.05, renderedDuration * speed)),
                timelineStart: renderedStartSeconds,
                timelineDuration: renderedDuration,
                speed: speed,
                adjustments: AudioAdjustments(
                    volume: plan.userEdited == true ? segment.directive.volume : min(1, master.volume * energyGain),
                    fadeIn: fadeIn,
                    fadeOut: fadeOut,
                    eqPreset: .music,
                    preservePitch: true
                )
            )
            placements.append(AudioPlacement(
                clip: clip,
                track: destinationTrack,
                start: renderedStart,
                duration: renderedEnd - renderedStart,
                duckingEnabled: segment.duckingEnabled
            ))
        }
        return placements
    }

    private func addAudioClips(
        _ clips: [TimelineAudioClip],
        assets: [UUID: MediaAsset],
        musicTracks: [LocalMusicTrack],
        to composition: AVMutableComposition,
        movieDuration: CMTime,
        derivedMediaCacheURL: URL?
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
                    .appendingPathComponent("veloedit-timeline-audio-\(UUID().uuidString)")
                    .appendingPathExtension("caf")
                inputURL = try await audioProcessor.generate(
                    sourceURL: sourceURL,
                    sourceStart: clip.sourceStart,
                    sourceDuration: clip.sourceDuration,
                    adjustments: clip.adjustments,
                    destination: temporary,
                    cacheDirectory: derivedMediaCacheURL
                )
                sourceStart = 0
                if derivedMediaCacheURL == nil { temporaryFiles.append(temporary) }
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

    private func makeAudioMix(placements: [Placement], originalTracks: [AVMutableCompositionTrack], originalAudioVolume: Float, music: MusicTrack?, additionalAudio: [AudioPlacement], ducking: AudioDuckingSettings, movieDuration: Double, frameRate: Double, speechRanges: [ClosedRange<Double>]? = nil) -> AVMutableAudioMix? {
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
            // Each connected clip has its own track. Initialize its gain before
            // preroll too; AVFoundation otherwise starts a later region at unity.
            value.setVolume(volume, at: .zero)
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
        if ducking.enabled || additionalAudio.contains(where: { $0.duckingEnabled == true }) {
            let audibleStoryRanges = (speechRanges?.map { (start: $0.lowerBound, end: $0.upperBound) } ?? (placements
                .filter { $0.audioTrack != nil && clipVolume($0) > 0.001 }
                .map { (start: $0.start.seconds, end: $0.end.seconds) }
                + additionalAudio
                .filter { $0.clip.role != .music && $0.clip.adjustments.effectiveVolume > 0.001 }
                .map { (start: $0.start.seconds, end: $0.end.seconds) })
                .sorted { $0.start < $1.start })
            var mergedStoryRanges: [(start: Double, end: Double)] = []
            for range in audibleStoryRanges {
                if let last = mergedStoryRanges.last,
                   range.start <= last.end + max(ducking.attack, ducking.release) {
                    mergedStoryRanges[mergedStoryRanges.count - 1].end = max(last.end, range.end)
                } else {
                    mergedStoryRanges.append(range)
                }
            }
            for background in additionalAudio where background.clip.role == .music {
                guard background.duckingEnabled ?? ducking.enabled else { continue }
                guard let value = parameters.first(where: {
                    $0.trackID == background.track.trackID
                }) as? AVMutableAudioMixInputParameters else { continue }
                let normal = Float(background.clip.adjustments.effectiveVolume)
                let reduced = normal * Float(ducking.attenuation)
                for story in mergedStoryRanges {
                    let start = max(story.start, background.start.seconds)
                    let end = min(story.end, background.end.seconds)
                    guard end > start else { continue }
                    let attack = min(ducking.attack, max(0, (end - start) * 0.45))
                    let release = min(
                        ducking.release,
                        max(0, (end - start) * 0.45),
                        max(0, background.end.seconds - end)
                    )
                    let attackStart = max(background.start.seconds, start - attack)
                    if start > attackStart + 0.001 {
                        scheduleVolumeRamp(
                            on: value,
                            from: normal,
                            to: reduced,
                            timeRange: CMTimeRange(
                                start: CMTime(seconds: attackStart, preferredTimescale: 600),
                                end: CMTime(seconds: start, preferredTimescale: 600)
                            )
                        )
                    } else {
                        value.setVolume(reduced, at: CMTime(seconds: start, preferredTimescale: 600))
                    }
                    if release > 0.001 {
                        scheduleVolumeRamp(
                            on: value,
                            from: reduced,
                            to: normal,
                            timeRange: CMTimeRange(
                                start: CMTime(seconds: end, preferredTimescale: 600),
                                duration: CMTime(seconds: release, preferredTimescale: 600)
                            )
                        )
                    }
                }
            }
        }
        if let music {
            let value = AVMutableAudioMixInputParameters(track: music.track)
            let normal = Float(music.directive.volume)
            value.setVolume(normal, at: .zero)
            if ducking.enabled {
                let reduced = normal * Float(ducking.attenuation)
                let sourceRanges = (speechRanges?.map { (start: $0.lowerBound, end: $0.upperBound) } ?? (placements
                    .filter { $0.audioTrack != nil && clipVolume($0) > 0.001 }
                    .map { (start: $0.start.seconds, end: $0.end.seconds) }
                    + additionalAudio
                    .filter { $0.clip.role != .music && $0.clip.adjustments.effectiveVolume > 0.001 }
                    .map { (start: $0.start.seconds, end: $0.end.seconds) })
                    .sorted { $0.start < $1.start })
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
        // Apply to ordinary, adaptive and manually placed music alike, after
        // clip fades and speech ducking. Legacy projects also get the finish;
        // disabling the visual fade does not disable the musical ending.
        if let ending = FilmEndingFade(duration: FilmEndingFade.defaultDuration, movieDuration: movieDuration, frameRate: frameRate) {
            var musicTrackIDs = Set(additionalAudio.filter { $0.clip.role == .music }.map { $0.track.trackID })
            if let music { musicTrackIDs.insert(music.track.trackID) }
            parameters = parameters.map { value in
                musicTrackIDs.contains(value.trackID) ? ending.applying(to: value, movieDuration: movieDuration) : value
            }
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

    private static func requiresPixelProcessing(_ adjustments: VideoAdjustments) -> Bool {
        var value = adjustments
        // Subject tracking is geometry and is represented by native transform
        // ramps below. It must not force the fragile custom pixel compositor.
        value.subjectReframe = nil
        return AdjustedClipGenerator.needsRender(value)
    }

    private static func nativeReframeTransform(
        _ base: CGAffineTransform,
        placement: Placement,
        progress: Double,
        renderSize: CGSize
    ) -> CGAffineTransform {
        guard let plan = placement.item.effectiveVideoAdjustments.subjectReframe,
              plan.confidence >= 0.24 else { return base }
        return SubjectReframeGeometry.transform(
            base: base,
            sourceExtent: CGRect(origin: .zero, size: placement.naturalSize),
            plan: plan,
            progress: progress,
            renderSize: renderSize,
            sourceTime: nil
        )
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
