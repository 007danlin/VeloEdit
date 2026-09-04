import Foundation
import CoreGraphics

// MARK: - Incremental Timeline mutation

/// Shared, synchronous mutations for interactions that must update SwiftUI in
/// the same event turn. The resulting Timeline is also the exact value later
/// persisted by `VeloEditPipeline`, so optimistic UI and production state do
/// not execute two subtly different edit algorithms.
public enum TimelineMutationEngine {
    @discardableResult
    public static func updateItem(
        in timeline: inout Timeline,
        id: UUID,
        _ mutation: (inout TimelineItem) -> Void
    ) -> Bool {
        guard let index = timeline.items.firstIndex(where: { $0.id == id }) else { return false }
        let previousItems = Dictionary(uniqueKeysWithValues: timeline.items.map { ($0.id, $0) })
        let before = timeline.items[index]
        mutation(&timeline.items[index])
        guard timeline.items[index] != before else { return false }
        normalize(item: &timeline.items[index])
        timeline.items = TimelineTiming.retimed(timeline.items)
        alignTelemetry(in: &timeline, previousItems: previousItems)
        removeDanglingObjects(in: &timeline)
        return true
    }

    @discardableResult
    public static func moveItem(in timeline: inout Timeline, id: UUID, toIndex requestedIndex: Int) -> Bool {
        guard timeline.items.count > 1,
              let oldIndex = timeline.items.firstIndex(where: { $0.id == id }) else { return false }
        let newIndex = min(max(0, requestedIndex), timeline.items.count - 1)
        guard oldIndex != newIndex else { return false }
        let previousItems = Dictionary(uniqueKeysWithValues: timeline.items.map { ($0.id, $0) })
        let item = timeline.items.remove(at: oldIndex)
        timeline.items.insert(item, at: newIndex)
        timeline.items = TimelineTiming.retimed(timeline.items)
        alignTelemetry(in: &timeline, previousItems: previousItems)
        return true
    }

    @discardableResult
    public static func movePrimaryItem(
        in timeline: inout Timeline,
        id: UUID,
        toPrimaryIndex requestedIndex: Int
    ) -> Bool {
        var primaries = timeline.items.filter { $0.overlay == nil }
        let connected = timeline.items.filter { $0.overlay != nil }
        guard primaries.count > 1,
              let oldIndex = primaries.firstIndex(where: { $0.id == id }) else { return false }
        let newIndex = min(max(0, requestedIndex), primaries.count - 1)
        guard oldIndex != newIndex else { return false }
        let previousItems = Dictionary(uniqueKeysWithValues: timeline.items.map { ($0.id, $0) })
        let item = primaries.remove(at: oldIndex)
        primaries.insert(item, at: newIndex)
        timeline.items = TimelineTiming.retimed(primaries + connected)
        alignTelemetry(in: &timeline, previousItems: previousItems)
        return true
    }

    @discardableResult
    public static func moveConnectedItem(
        in timeline: inout Timeline,
        id: UUID,
        toTimelineStart requestedStart: Double
    ) -> Bool {
        timeline.items = TimelineTiming.retimed(timeline.items)
        guard let index = timeline.items.firstIndex(where: { $0.id == id && $0.overlay != nil }) else { return false }
        let primaries = timeline.items.filter { $0.overlay == nil }
        guard !primaries.isEmpty else { return false }
        let maximum = max(0, timeline.duration - timeline.items[index].timelineDuration)
        let start = TimelineTiming.quantized(
            min(max(0, requestedStart.isFinite ? requestedStart : 0), maximum),
            frameRate: timeline.frameRate
        )
        guard let base = primaries.first(where: {
            start >= $0.timelineStart && start < $0.timelineStart + $0.timelineDuration
        }) ?? primaries.min(by: {
            abs($0.timelineStart - start) < abs($1.timelineStart - start)
        }) else { return false }
        let before = timeline.items[index]
        timeline.items[index].timelineStart = start
        timeline.items[index].overlay?.baseItemID = base.id
        timeline.items[index].overlay?.startOffset = start - base.timelineStart
        timeline.items = TimelineTiming.retimed(timeline.items)
        return timeline.items[index] != before
    }

    @discardableResult
    public static func updateTelemetry(
        in timeline: inout Timeline,
        id: UUID,
        _ mutation: (inout TimelineTelemetryItem) -> Void
    ) -> Bool {
        var items = timeline.effectiveTelemetryItems
        guard let index = items.firstIndex(where: { $0.id == id }) else { return false }
        let before = items[index]
        mutation(&items[index])
        items[index].sourceStart = finiteNonNegative(items[index].sourceStart)
        items[index].timelineDuration = max(0.05, finiteNonNegative(items[index].timelineDuration))
        items[index].timelineStart = clampedStart(
            items[index].timelineStart,
            duration: items[index].timelineDuration,
            timelineDuration: timeline.duration,
            frameRate: timeline.frameRate
        )
        items[index].timelineDuration = min(items[index].timelineDuration, max(0.05, timeline.duration - items[index].timelineStart))
        guard items[index] != before else { return false }
        timeline.telemetryItems = items
        return true
    }

    @discardableResult
    public static func updateEffect(
        in timeline: inout Timeline,
        id: UUID,
        _ mutation: (inout EffectTimelineItem) -> Void
    ) -> Bool {
        var items = timeline.effectiveEffects
        guard let index = items.firstIndex(where: { $0.id == id }) else { return false }
        let before = items[index]
        mutation(&items[index])
        items[index].duration = max(0.05, finiteNonNegative(items[index].duration))
        items[index].startTime = clampedStart(
            items[index].startTime,
            duration: items[index].duration,
            timelineDuration: timeline.duration,
            frameRate: timeline.frameRate
        )
        items[index].duration = min(items[index].duration, max(0.05, timeline.duration - items[index].startTime))
        items[index].intensity = min(max(0, items[index].intensity.isFinite ? items[index].intensity : 0), 1)
        let preset = EffectPresetRegistry.preset(for: items[index].effectType)
        items[index].parameters = items[index].parameters.compactMap { parameter in
            guard let descriptor = preset.parameter(named: parameter.name), descriptor.key != "intensity" else { return nil }
            return descriptor.parameter(value: parameter.effectiveNumericValue)
        }
        items[index].keyframes = items[index].keyframes.compactMap { keyframe in
            guard let descriptor = preset.parameter(named: keyframe.parameter), descriptor.supportsKeyframes else { return nil }
            var normalized = keyframe
            normalized.time = min(max(0, keyframe.time.isFinite ? keyframe.time : 0), items[index].duration)
            let value = min(max(descriptor.range.lowerBound, keyframe.effectiveNumericValue), descriptor.range.upperBound)
            normalized.value = value
            normalized.typedValue = EffectParameterValue.scalar(value, as: descriptor.valueType)
            return normalized
        }.sorted { $0.time < $1.time }
        guard items[index] != before else { return false }
        timeline.effects = items
        return true
    }

    @discardableResult
    public static func reorderEffect(in timeline: inout Timeline, id: UUID, toIndex: Int) -> Bool {
        EffectStackEngine.reorderEffect(in: &timeline, id: id, to: toIndex)
    }

    @discardableResult
    public static func updateTransition(
        in timeline: inout Timeline,
        id: UUID,
        _ mutation: (inout TimelineTransitionItem) -> Void
    ) -> Bool {
        var items = timeline.effectiveTransitionItems
        guard let index = items.firstIndex(where: { $0.id == id }) else { return false }
        let before = items[index]
        mutation(&items[index])
        items[index].duration = min(max(0.08, finiteNonNegative(items[index].duration)), 4)
        items[index].startTime = finiteNonNegative(items[index].startTime)
        items[index].intensity = min(max(0, items[index].effectiveIntensity), 1)
        guard items[index] != before else { return false }
        timeline.transitionItems = items
        if let incomingIndex = timeline.items.firstIndex(where: { $0.id == items[index].incomingClipID }) {
            timeline.items[incomingIndex].transition = items[index].enabled ? items[index].style.rawValue : nil
        }
        return true
    }

    @discardableResult
    public static func updateTitle(
        in timeline: inout Timeline,
        id: UUID,
        _ mutation: (inout TitleTimelineItem) -> Void
    ) -> Bool {
        var items = timeline.effectiveTitleItems
        guard let index = items.firstIndex(where: { $0.id == id }) else { return false }
        let before = items[index]
        mutation(&items[index])
        items[index].duration = max(0.05, finiteNonNegative(items[index].duration))
        items[index].startTime = clampedStart(
            items[index].startTime,
            duration: items[index].duration,
            timelineDuration: timeline.duration,
            frameRate: timeline.frameRate
        )
        items[index].duration = min(items[index].duration, max(0.05, timeline.duration - items[index].startTime))
        guard items[index] != before else { return false }
        timeline.titleItems = items
        return true
    }

    @discardableResult
    public static func updateAudioClip(
        in timeline: inout Timeline,
        id: UUID,
        _ mutation: (inout TimelineAudioClip) -> Void
    ) -> Bool {
        var items = timeline.effectiveAudioClips
        guard let index = items.firstIndex(where: { $0.id == id }) else { return false }
        let before = items[index]
        mutation(&items[index])
        items[index].sourceStart = finiteNonNegative(items[index].sourceStart)
        items[index].sourceDuration = max(0.05, finiteNonNegative(items[index].sourceDuration))
        items[index].timelineDuration = max(0.05, finiteNonNegative(items[index].timelineDuration))
        items[index].timelineStart = clampedStart(
            items[index].timelineStart,
            duration: items[index].timelineDuration,
            timelineDuration: timeline.duration,
            frameRate: timeline.frameRate
        )
        items[index].timelineDuration = min(items[index].timelineDuration, max(0.05, timeline.duration - items[index].timelineStart))
        guard items[index] != before else { return false }
        timeline.audioClips = items
        return true
    }

    private static func normalize(item: inout TimelineItem) {
        item.sourceStart = finiteNonNegative(item.sourceStart)
        item.sourceDuration = max(0.05, finiteNonNegative(item.sourceDuration))
        item.timelineDuration = max(0.05, finiteNonNegative(item.timelineDuration))
        item.speed = min(max(0.1, item.speed.isFinite ? item.speed : 1), 20)
    }

    private static func clampedStart(
        _ value: Double,
        duration: Double,
        timelineDuration: Double,
        frameRate: Double
    ) -> Double {
        TimelineTiming.quantized(
            min(max(0, value.isFinite ? value : 0), max(0, timelineDuration - duration)),
            frameRate: frameRate
        )
    }

    private static func finiteNonNegative(_ value: Double) -> Double {
        max(0, value.isFinite ? value : 0)
    }

    private static func removeDanglingObjects(in timeline: inout Timeline) {
        let itemIDs = Set(timeline.items.map(\.id))
        timeline.telemetryItems = timeline.effectiveTelemetryItems.filter {
            $0.targetClipID.map(itemIDs.contains) ?? true
        }
        timeline.effects = timeline.effectiveEffects.filter {
            $0.targetClipID.map(itemIDs.contains) ?? true
        }
        timeline.titleItems = timeline.effectiveTitleItems.filter {
            $0.targetClipID.map(itemIDs.contains) ?? true
        }
        timeline.transitionItems = timeline.effectiveTransitionItems.filter {
            itemIDs.contains($0.outgoingClipID) && itemIDs.contains($0.incomingClipID)
        }
    }

    private static func alignTelemetry(in timeline: inout Timeline, previousItems: [UUID: TimelineItem]) {
        let currentItems = Dictionary(uniqueKeysWithValues: timeline.items.map { ($0.id, $0) })
        timeline.telemetryItems = timeline.effectiveTelemetryItems.compactMap { source in
            guard let targetID = source.targetClipID else { return source }
            guard let current = currentItems[targetID] else { return nil }
            var item = source
            if let previous = previousItems[targetID] {
                let coveredWholeClip = abs(item.timelineStart - previous.timelineStart) < 0.001 &&
                    abs(item.timelineDuration - previous.timelineDuration) < 0.001
                if coveredWholeClip {
                    item.timelineStart = current.timelineStart
                    item.timelineDuration = max(0.05, current.timelineDuration)
                } else {
                    let offset = item.timelineStart - previous.timelineStart
                    item.timelineStart = min(
                        max(current.timelineStart, current.timelineStart + offset),
                        max(current.timelineStart, current.timelineStart + current.timelineDuration - 0.05)
                    )
                    item.timelineDuration = min(
                        item.timelineDuration,
                        max(0.05, current.timelineStart + current.timelineDuration - item.timelineStart)
                    )
                }
            }
            item.linkedAssetID = current.assetID
            item.sourceStart = current.sourceTime(atTimelineTime: item.timelineStart)
            return item
        }
    }
}

// MARK: - Preview invalidation

public enum PreviewLayerKind: String, Codable, CaseIterable, Hashable, Sendable {
    case sourceVideo, sourceAudio, timelineStructure, effects, titles, telemetry, transitions, soundtrack
}

public struct TimelineInvalidationPlan: Hashable, Sendable {
    public var layers: Set<PreviewLayerKind>
    public var changedRanges: [ClosedRange<Double>]
    public var requiresCompositionRebuild: Bool
    public var canReuseDecodedVideo: Bool

    public init(
        layers: Set<PreviewLayerKind>,
        changedRanges: [ClosedRange<Double>],
        requiresCompositionRebuild: Bool,
        canReuseDecodedVideo: Bool
    ) {
        self.layers = layers
        self.changedRanges = changedRanges
        self.requiresCompositionRebuild = requiresCompositionRebuild
        self.canReuseDecodedVideo = canReuseDecodedVideo
    }
}

public enum TimelineInvalidationPlanner {
    public static func plan(from old: Timeline, to new: Timeline) -> TimelineInvalidationPlan {
        var layers = Set<PreviewLayerKind>()
        var ranges: [ClosedRange<Double>] = []
        let oldItems = Dictionary(uniqueKeysWithValues: old.items.map { ($0.id, $0) })
        let newItems = Dictionary(uniqueKeysWithValues: new.items.map { ($0.id, $0) })
        let allItemIDs = Set(oldItems.keys).union(newItems.keys)

        if old.items.map(\.id) != new.items.map(\.id) {
            layers.formUnion([.timelineStructure, .sourceVideo, .sourceAudio])
        }
        for id in allItemIDs {
            guard let before = oldItems[id], let after = newItems[id] else {
                if let item = oldItems[id] ?? newItems[id] {
                    ranges.append(item.timelineStart...(item.timelineStart + item.timelineDuration))
                }
                layers.formUnion([.timelineStructure, .sourceVideo, .sourceAudio])
                continue
            }
            let sourceChanged = before.assetID != after.assetID || before.kind != after.kind ||
                abs(before.sourceStart - after.sourceStart) > 0.000_1 ||
                abs(before.sourceDuration - after.sourceDuration) > 0.000_1 ||
                abs(before.timelineStart - after.timelineStart) > 0.000_1 ||
                abs(before.timelineDuration - after.timelineDuration) > 0.000_1 ||
                abs(before.speed - after.speed) > 0.000_1 || before.speedRamp != after.speedRamp ||
                before.reversePlayback != after.reversePlayback || before.freezeFrame != after.freezeFrame ||
                before.overlay != after.overlay
            if sourceChanged {
                layers.formUnion([.timelineStructure, .sourceVideo, .sourceAudio])
            }
            if before.videoAdjustments != after.videoAdjustments || before.effect != after.effect {
                layers.insert(.effects)
            }
            if before.audioAdjustments != after.audioAdjustments { layers.insert(.sourceAudio) }
            if before.transition != after.transition { layers.insert(.transitions) }
            if before.telemetryOverlay != after.telemetryOverlay { layers.insert(.telemetry) }
            if before.title != after.title || before.titleStyle != after.titleStyle {
                layers.insert(before.kind == .title ? .sourceVideo : .titles)
            }
            if before != after {
                let lower = min(before.timelineStart, after.timelineStart)
                let upper = max(before.timelineStart + before.timelineDuration, after.timelineStart + after.timelineDuration)
                ranges.append(lower...max(lower, upper))
            }
        }

        if old.effectiveEffects != new.effectiveEffects { layers.insert(.effects) }
        if old.effectiveTitleItems != new.effectiveTitleItems { layers.insert(.titles) }
        if old.effectiveTelemetryItems != new.effectiveTelemetryItems { layers.insert(.telemetry) }
        if old.effectiveTransitionItems != new.effectiveTransitionItems { layers.insert(.transitions) }
        if old.effectiveAudioClips != new.effectiveAudioClips || old.audioDucking != new.audioDucking ||
            abs(old.effectiveOriginalAudioVolume - new.effectiveOriginalAudioVolume) > 0.000_1 {
            layers.insert(.sourceAudio)
        }
        if old.music != new.music { layers.insert(.soundtrack) }

        let requiresComposition = !layers.intersection([.timelineStructure, .sourceVideo, .transitions]).isEmpty
        let decodedVideoReusable = layers.isDisjoint(with: [.timelineStructure, .sourceVideo])
        return TimelineInvalidationPlan(
            layers: layers,
            changedRanges: merged(ranges),
            requiresCompositionRebuild: requiresComposition,
            canReuseDecodedVideo: decodedVideoReusable
        )
    }

    private static func merged(_ ranges: [ClosedRange<Double>]) -> [ClosedRange<Double>] {
        let sorted = ranges.sorted { $0.lowerBound < $1.lowerBound }
        var result: [ClosedRange<Double>] = []
        for range in sorted {
            if let last = result.last, range.lowerBound <= last.upperBound + 0.001 {
                result[result.count - 1] = last.lowerBound...max(last.upperBound, range.upperBound)
            } else {
                result.append(range)
            }
        }
        return result
    }
}

// MARK: - Black-frame and latency diagnostics

public struct FrameQualityAssessment: Hashable, Sendable {
    public var isBlack: Bool
    public var isUniform: Bool
    public var meanLuma: Double
    public var lumaDeviation: Double
}

public enum FrameQualityInspector {
    /// Evaluates an 8-bit luma plane. A dark but textured night scene is not a
    /// black frame; both very low mean luma and very low variation are required.
    public static func assess(luma: [UInt8]) -> FrameQualityAssessment {
        guard !luma.isEmpty else {
            return FrameQualityAssessment(isBlack: true, isUniform: true, meanLuma: 0, lumaDeviation: 0)
        }
        let mean = Double(luma.reduce(0) { $0 + UInt64($1) }) / Double(luma.count)
        let variance = luma.reduce(0.0) { partial, value in
            let delta = Double(value) - mean
            return partial + delta * delta
        } / Double(luma.count)
        let deviation = sqrt(variance)
        return FrameQualityAssessment(
            isBlack: mean < 7 && deviation < 3.5,
            isUniform: deviation < 2,
            meanLuma: mean,
            lumaDeviation: deviation
        )
    }

    /// Samples a decoded production frame through a small grayscale buffer so
    /// viewer/export checks do not retain another full-resolution image.
    public static func assess(image: CGImage, sampleEdge: Int = 32) -> FrameQualityAssessment {
        let width = max(1, min(sampleEdge, image.width))
        let height = max(1, min(sampleEdge, image.height))
        var bytes = [UInt8](repeating: 0, count: width * height)
        guard let context = CGContext(
            data: &bytes,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return assess(luma: []) }
        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return assess(luma: bytes)
    }
}

public struct InteractionLatencySample: Hashable, Sendable {
    public var name: String
    public var stateUpdateMilliseconds: Double
    public var visualFeedbackMilliseconds: Double

    public init(name: String, stateUpdateMilliseconds: Double, visualFeedbackMilliseconds: Double) {
        self.name = name
        self.stateUpdateMilliseconds = max(0, stateUpdateMilliseconds)
        self.visualFeedbackMilliseconds = max(0, visualFeedbackMilliseconds)
    }
}

public struct InteractionLatencySummary: Hashable, Sendable {
    public var sampleCount: Int
    public var p95StateUpdateMilliseconds: Double
    public var p95VisualFeedbackMilliseconds: Double
    public var stateUpdateBudgetPass: Bool
    public var visualFeedbackBudgetPass: Bool
}

public actor InteractionLatencyRecorder {
    public static let stateUpdateTargetMilliseconds = 16.0
    public static let visualFeedbackTargetMilliseconds = 50.0
    private let maximumSamples: Int
    private var samples: [InteractionLatencySample] = []

    public init(maximumSamples: Int = 1_000) {
        self.maximumSamples = max(1, maximumSamples)
    }

    public func record(_ sample: InteractionLatencySample) {
        samples.append(sample)
        if samples.count > maximumSamples {
            samples.removeFirst(samples.count - maximumSamples)
        }
    }

    public func summary() -> InteractionLatencySummary {
        let state = samples.map(\.stateUpdateMilliseconds).sorted()
        let visual = samples.map(\.visualFeedbackMilliseconds).sorted()
        let stateP95 = percentile95(state)
        let visualP95 = percentile95(visual)
        return InteractionLatencySummary(
            sampleCount: samples.count,
            p95StateUpdateMilliseconds: stateP95,
            p95VisualFeedbackMilliseconds: visualP95,
            stateUpdateBudgetPass: stateP95 < Self.stateUpdateTargetMilliseconds,
            visualFeedbackBudgetPass: visualP95 < Self.visualFeedbackTargetMilliseconds
        )
    }

    private func percentile95(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let index = min(values.count - 1, Int((Double(values.count - 1) * 0.95).rounded(.up)))
        return values[index]
    }
}

// MARK: - Stable cache identities

public enum ProductionCacheIdentity {
    public static func hash(_ values: [String]) -> String {
        let joined = values.joined(separator: "|")
        let value = joined.utf8.reduce(UInt64(14_695_981_039_346_656_037)) { partial, byte in
            (partial ^ UInt64(byte)) &* 1_099_511_628_211
        }
        return String(value, radix: 16)
    }
}

// MARK: - Generated-film delivery contract

/// Preview surfaces that promise to show the complete camera frame must use
/// aspect-fit. Keeping this policy in VeloEditCore makes a future UI change
/// independently testable instead of relying on visual inspection alone.
public enum PreviewContentMode: String, Codable, CaseIterable, Hashable, Sendable {
    case aspectFit = "aspect-fit"
    case aspectFill = "aspect-fill"
}

public struct PreviewGeometryAssessment: Hashable, Sendable {
    public var contentMode: PreviewContentMode
    public var displayedWidth: Double
    public var displayedHeight: Double
    public var visibleSourceFraction: Double
    public var cropFraction: Double
    public var preservesCompleteSource: Bool

    public init(
        contentMode: PreviewContentMode,
        displayedWidth: Double,
        displayedHeight: Double,
        visibleSourceFraction: Double
    ) {
        self.contentMode = contentMode
        self.displayedWidth = max(0, displayedWidth)
        self.displayedHeight = max(0, displayedHeight)
        self.visibleSourceFraction = min(max(0, visibleSourceFraction), 1)
        cropFraction = 1 - self.visibleSourceFraction
        preservesCompleteSource = cropFraction < 0.000_1
    }
}

public enum PreviewGeometryContract {
    public static func assess(
        sourceWidth: Double,
        sourceHeight: Double,
        viewportWidth: Double,
        viewportHeight: Double,
        contentMode: PreviewContentMode
    ) -> PreviewGeometryAssessment {
        guard sourceWidth > 0, sourceHeight > 0, viewportWidth > 0, viewportHeight > 0 else {
            return PreviewGeometryAssessment(
                contentMode: contentMode,
                displayedWidth: 0,
                displayedHeight: 0,
                visibleSourceFraction: 0
            )
        }
        let widthScale = viewportWidth / sourceWidth
        let heightScale = viewportHeight / sourceHeight
        let scale = contentMode == .aspectFit
            ? min(widthScale, heightScale)
            : max(widthScale, heightScale)
        let displayedWidth = sourceWidth * scale
        let displayedHeight = sourceHeight * scale
        let visibleWidth = min(sourceWidth, viewportWidth / scale)
        let visibleHeight = min(sourceHeight, viewportHeight / scale)
        let visibleFraction = (visibleWidth * visibleHeight) / (sourceWidth * sourceHeight)
        return PreviewGeometryAssessment(
            contentMode: contentMode,
            displayedWidth: displayedWidth,
            displayedHeight: displayedHeight,
            visibleSourceFraction: visibleFraction
        )
    }
}

public struct PreviewDeliveryProfile: Hashable, Sendable {
    public var sourcePreviewContentMode: PreviewContentMode
    public var timelinePreviewContentMode: PreviewContentMode
    /// The stable realtime path is allowed to render titles in the SwiftUI
    /// overlay while leaving homogeneous high-resolution camera media native.
    public var usesStableRealtimePlayback: Bool

    public init(
        sourcePreviewContentMode: PreviewContentMode,
        timelinePreviewContentMode: PreviewContentMode,
        usesStableRealtimePlayback: Bool
    ) {
        self.sourcePreviewContentMode = sourcePreviewContentMode
        self.timelinePreviewContentMode = timelinePreviewContentMode
        self.usesStableRealtimePlayback = usesStableRealtimePlayback
    }

    public static let production = PreviewDeliveryProfile(
        sourcePreviewContentMode: .aspectFit,
        timelinePreviewContentMode: .aspectFit,
        usesStableRealtimePlayback: true
    )
}

public struct ExplicitDeliveryRequirements: Hashable, Sendable {
    public var forbidsMusic: Bool
    public var forbidsTitles: Bool
    public var keyTitlesOnly: Bool
    public var originalAudioVolume: Double?
    public var requiresExactDuration: Bool
    public var exactDuration: Double?
    public var exactClipCount: Int?
    public var canvasFormat: DirectorCanvasFormat?
    public var musicPolicy: DirectorMusicPolicy?
    public var musicTrackID: UUID?
    public var titlePolicy: DirectorTitlePolicy?

    public init(plan: StoryPlan) {
        if let brief = plan.directorBrief {
            forbidsMusic = brief.musicPolicy == .none
            forbidsTitles = brief.titlePolicy == .none
            keyTitlesOnly = brief.titlePolicy == .keyOnly
            originalAudioVolume = brief.sourceAudioPolicy.volume
            requiresExactDuration = true
            exactDuration = brief.requestedDuration
            exactClipCount = plan.constraints.targetClipCount
            canvasFormat = brief.canvasFormat
            musicPolicy = brief.musicPolicy
            musicTrackID = brief.musicTrackID
            titlePolicy = brief.titlePolicy
            return
        }
        let prompt = plan.prompt.lowercased()
        forbidsMusic = Self.containsAny(prompt, [
            "без музы", "убери музыку", "убрать музыку", "не добавляй музыку",
            "музыка не нужна", "no music", "without music", "remove music"
        ])
        forbidsTitles = Self.containsAny(prompt, [
            "без титр", "убери титр", "убрать титр", "не добавляй титр",
            "титры не нужны", "без надпис", "no titles", "without titles", "remove titles"
        ])
        keyTitlesOnly = !forbidsTitles && Self.containsAny(prompt, [
            "только ключевые титр", "только важные титр", "лишь ключевые титр",
            "key titles only", "only key titles"
        ])
        originalAudioVolume = OriginalAudioPromptInterpreter().volume(prompt: plan.prompt)
        requiresExactDuration = plan.requiresExactDuration
        exactDuration = requiresExactDuration ? plan.constraints.targetDuration : nil
        exactClipCount = plan.constraints.targetClipCount
        canvasFormat = nil
        musicPolicy = nil
        musicTrackID = nil
        titlePolicy = nil
    }

    private static func containsAny(_ value: String, _ needles: [String]) -> Bool {
        needles.contains(where: value.contains)
    }
}

public enum TimelineDeliveryIssueKind: String, Codable, CaseIterable, Hashable, Sendable {
    case canvasFormat
    case musicPolicy
    case titlePolicy
    case forbiddenMusic
    case forbiddenTitles
    case originalAudioVolume
    case generatedTitleQuality
    case titleOverlap
    case exactDuration
    case exactClipCount
    case missingRequiredTag
    case excludedTagPresent
    case maximumTagShare
    case preferredRoleTag
    case sourcePreviewCrop
    case timelinePreviewCrop
    case unstableHighResolutionPreview
    case renderedBlackFrame
}

public enum TimelineDeliveryIssueResolution: String, Codable, CaseIterable, Hashable, Sendable {
    case repaired
    case blocking
}

public struct TimelineDeliveryIssue: Codable, Hashable, Sendable {
    public var kind: TimelineDeliveryIssueKind
    public var resolution: TimelineDeliveryIssueResolution
    public var message: String

    public init(
        kind: TimelineDeliveryIssueKind,
        resolution: TimelineDeliveryIssueResolution,
        message: String
    ) {
        self.kind = kind
        self.resolution = resolution
        self.message = message
    }
}

public struct TimelineDeliveryValidation: Sendable {
    public var timeline: Timeline
    public var issues: [TimelineDeliveryIssue]

    public init(timeline: Timeline, issues: [TimelineDeliveryIssue]) {
        self.timeline = timeline
        self.issues = issues
    }

    public var blockingIssues: [TimelineDeliveryIssue] {
        issues.filter { $0.resolution == .blocking }
    }

    public var canPersist: Bool { blockingIssues.isEmpty }
}

public enum TimelineDeliveryContractError: LocalizedError, Sendable {
    case blocked([TimelineDeliveryIssue])

    public var errorDescription: String? {
        switch self {
        case .blocked(let issues):
            let details = issues.map(\.message).joined(separator: " ")
            return "Фильм не сохранён: обязательные требования не прошли проверку. \(details)"
        }
    }
}

/// Last deterministic gate before an automatically generated film is stored.
/// It intentionally validates only explicit, machine-verifiable requirements;
/// subjective requests remain the responsibility of story scoring/review.
public struct TimelineDeliveryContract: Sendable {
    public init() {}

    public func enforce(
        timeline: Timeline,
        plan: StoryPlan,
        assets: [MediaAsset],
        analyses: [AnalysisResult] = [],
        previewProfile: PreviewDeliveryProfile = .production
    ) throws -> Timeline {
        let validation = validateAndRepair(
            timeline: timeline,
            plan: plan,
            assets: assets,
            analyses: analyses,
            previewProfile: previewProfile
        )
        guard validation.canPersist else {
            throw TimelineDeliveryContractError.blocked(validation.blockingIssues)
        }
        return validation.timeline
    }

    public func validateAndRepair(
        timeline source: Timeline,
        plan: StoryPlan,
        assets: [MediaAsset],
        analyses: [AnalysisResult] = [],
        previewProfile: PreviewDeliveryProfile = .production
    ) -> TimelineDeliveryValidation {
        let requirements = ExplicitDeliveryRequirements(plan: plan)
        var timeline = source
        var issues: [TimelineDeliveryIssue] = []

        if let format = requirements.canvasFormat,
           timeline.width != format.width || timeline.height != format.height {
            timeline.width = format.width
            timeline.height = format.height
            issues.append(.init(
                kind: .canvasFormat,
                resolution: .repaired,
                message: "Canvas приведён к обязательному формату \(format.localizedTitle) (\(format.width)×\(format.height))."
            ))
        }

        func automaticMusicDirective() -> MusicDirective {
            if let decision = plan.autonomousDecision {
                return MusicDirective(
                    style: decision.music.style,
                    bpm: decision.music.desiredBPM,
                    volume: 0.12 + decision.finalStyle.musicIntensity * 0.13,
                    autonomousIntent: decision.music
                )
            }
            let contentTags = analyses.flatMap(\.directorCandidates).reduce(into: Set<String>()) {
                $0.formUnion($1.tags)
            }.sorted().joined(separator: " ")
            let contentPrompt = contentTags.isEmpty
                ? plan.prompt
                : "\(plan.prompt)\nРаспознано в кадре: \(contentTags)"
            return MusicPromptInterpreter().interpret(
                prompt: contentPrompt,
                preset: plan.preset,
                automaticDefault: true
            ) ?? MusicDirective(style: .cinematic, bpm: 82)
        }

        if let musicPolicy = requirements.musicPolicy {
            switch musicPolicy {
            case .none:
                let hadMusic = timeline.music != nil || timeline.effectiveAudioClips.contains { $0.role == .music }
                timeline.music = nil
                timeline.audioClips = timeline.effectiveAudioClips.filter { $0.role != .music }
                if hadMusic {
                    issues.append(.init(
                        kind: .forbiddenMusic,
                        resolution: .repaired,
                        message: "Выбор AI Director «без музыки» выполнен: саундтрек и музыкальные аудиоклипы удалены."
                    ))
                }
            case .soft:
                var directive = timeline.music ?? MusicDirective(style: .calm, bpm: 68, volume: 0.12)
                let changed = timeline.music == nil || directive.style != .calm
                    || directive.volume > 0.14 + 0.000_1 || directive.autonomousIntent != nil
                directive.style = .calm
                directive.volume = min(directive.volume, 0.14)
                directive.autonomousIntent = nil
                directive.preferDifferentTrack = nil
                timeline.music = directive
                if changed {
                    issues.append(.init(
                        kind: .musicPolicy,
                        resolution: .repaired,
                        message: "Музыка приведена к мягкой ненавязчивой подаче с ограниченной громкостью."
                    ))
                }
            case .matchVideo:
                if timeline.music == nil {
                    timeline.music = automaticMusicDirective()
                    issues.append(.init(
                        kind: .musicPolicy,
                        resolution: .repaired,
                        message: "Восстановлен content-aware саундтрек, подобранный по анализу видео."
                    ))
                }
            case .specificTrack:
                guard let requestedTrackID = requirements.musicTrackID else {
                    issues.append(.init(
                        kind: .musicPolicy,
                        resolution: .blocking,
                        message: "Выбран режим конкретного трека, но идентификатор трека отсутствует."
                    ))
                    break
                }
                var directive = timeline.music ?? automaticMusicDirective()
                var repaired = directive.trackID != requestedTrackID
                directive.trackID = requestedTrackID
                directive.trackTitle = directive.trackID == timeline.music?.trackID ? directive.trackTitle : nil
                directive.structure = directive.trackID == timeline.music?.trackID ? directive.structure : nil
                directive.preferDifferentTrack = nil
                timeline.music = directive
                let filteredClips = timeline.effectiveAudioClips.filter {
                    $0.role != .music || $0.trackID == requestedTrackID
                }
                if filteredClips.count != timeline.effectiveAudioClips.count { repaired = true }
                timeline.audioClips = filteredClips
                if repaired {
                    issues.append(.init(
                        kind: .musicPolicy,
                        resolution: .repaired,
                        message: "Восстановлен конкретный музыкальный трек, выбранный в AI Director."
                    ))
                }
            }
        } else if requirements.forbidsMusic {
            let hadMusic = timeline.music != nil || timeline.effectiveAudioClips.contains { $0.role == .music }
            timeline.music = nil
            timeline.audioClips = timeline.effectiveAudioClips.filter { $0.role != .music }
            if hadMusic {
                issues.append(.init(
                    kind: .forbiddenMusic,
                    resolution: .repaired,
                    message: "Явное требование «без музыки» выполнено: саундтрек и музыкальные аудиоклипы удалены."
                ))
            }
        }

        if requirements.forbidsTitles {
            let hadTitles = !timeline.effectiveTitleItems.isEmpty || timeline.items.contains { $0.kind == .title }
            timeline.titleItems = []
            if timeline.items.contains(where: { $0.kind == .title }) {
                timeline.items.removeAll { $0.kind == .title }
                timeline.items = TimelineTiming.retimed(timeline.items)
            }
            if hadTitles {
                issues.append(.init(
                    kind: .forbiddenTitles,
                    resolution: .repaired,
                    message: "Явное требование «без титров» выполнено: все автоматически созданные титры удалены."
                ))
            }
        } else {
            let reviewed = AutomatedTitlePolicy.reviewed(
                timeline.effectiveTitleItems,
                timelineDuration: timeline.duration,
                containmentByTitleID: AutomatedTitlePolicy.inferredContainmentByTitleID(
                    timeline.effectiveTitleItems,
                    timeline: timeline
                )
            )
            if reviewed.titles != timeline.effectiveTitleItems {
                timeline.titleItems = reviewed.titles
                let details = reviewed.diagnostics.map(\.message).joined(separator: " ")
                issues.append(.init(
                    kind: .generatedTitleQuality,
                    resolution: .repaired,
                    message: details.isEmpty
                        ? "Автотитры очищены от placeholder-текста, повторов и наложений."
                        : details
                ))
            }
            let invalidLegacyIDs = Set(timeline.items.compactMap { item -> UUID? in
                guard item.kind == .title, let text = item.title,
                      SmartTitleEngine.isMeaningless(text) || SmartTitleEngine.isStructuralPlaceholder(text) else { return nil }
                return item.id
            })
            if !invalidLegacyIDs.isEmpty {
                timeline.items.removeAll { invalidLegacyIDs.contains($0.id) }
                timeline.items = TimelineTiming.retimed(timeline.items)
                issues.append(.init(
                    kind: .generatedTitleQuality,
                    resolution: .repaired,
                    message: "Устаревшие автотитры с внутренними названиями монтажных beat-ов удалены."
                ))
            }
            if let titlePolicy = requirements.titlePolicy {
                let before = timeline.effectiveTitleItems
                let filtered = DirectorTitlePolicyEngine.applying(
                    titlePolicy,
                    to: before,
                    timelineDuration: timeline.duration
                )
                timeline.titleItems = filtered
                if filtered != before {
                    issues.append(.init(
                        kind: .titlePolicy,
                        resolution: .repaired,
                        message: titlePolicy == .keyOnly
                            ? "Оставлены только редкие ключевые титры, подтверждённые содержанием."
                            : "Количество титров ограничено выбранным минимальным режимом."
                    ))
                }
            }
        }

        if let requestedVolume = requirements.originalAudioVolume {
            let clamped = min(max(0, requestedVolume), 1)
            var repaired = abs(timeline.effectiveOriginalAudioVolume - clamped) > 0.000_1
            timeline.originalAudioVolume = clamped
            if plan.directorBrief != nil {
                timeline.items = timeline.items.map { item in
                    guard item.kind == .video else { return item }
                    var copy = item
                    var adjustments = copy.effectiveAudioAdjustments
                    let shouldMute = clamped < 0.000_1
                    if abs(adjustments.volume - 1) > 0.000_1 || adjustments.muted != shouldMute {
                        repaired = true
                    }
                    // Primary source audio is mixed through the global brief
                    // level. A neutral per-clip gain makes 1/.28/0 exact.
                    adjustments.volume = 1
                    adjustments.muted = shouldMute
                    copy.audioAdjustments = adjustments
                    return copy
                }
                timeline.audioClips = timeline.effectiveAudioClips.map { clip in
                    guard clip.assetID != nil,
                          [.detached, .dialogue, .naturalSound].contains(clip.role) else { return clip }
                    var copy = clip
                    let shouldMute = clamped < 0.000_1
                    if abs(copy.adjustments.volume - clamped) > 0.000_1 || copy.adjustments.muted != shouldMute {
                        repaired = true
                    }
                    copy.adjustments.volume = clamped
                    copy.adjustments.muted = shouldMute
                    return copy
                }
            } else {
                timeline.audioClips = timeline.effectiveAudioClips.map { clip in
                    guard clip.assetID != nil,
                          [.detached, .dialogue, .naturalSound].contains(clip.role),
                          clip.adjustments.effectiveVolume > clamped + 0.000_1 else { return clip }
                    var copy = clip
                    copy.adjustments.volume = clamped
                    copy.adjustments.muted = clamped < 0.000_1
                    repaired = true
                    return copy
                }
            }
            if repaired {
                issues.append(.init(
                    kind: .originalAudioVolume,
                    resolution: .repaired,
                    message: "Уровень исходного звука приведён к явно заданному значению \(Int((clamped * 100).rounded()))%."
                ))
            }
        }

        if requirements.requiresExactDuration {
            let tolerance = max(0.001, 1 / max(1, timeline.frameRate))
            let exactDuration = requirements.exactDuration ?? plan.constraints.targetDuration
            let difference = abs(timeline.duration - exactDuration)
            if difference > tolerance {
                issues.append(.init(
                    kind: .exactDuration,
                    resolution: .blocking,
                    message: String(
                        format: "Запрошена точная длительность %.3f с, но монтаж длится %.3f с.",
                        exactDuration,
                        timeline.duration
                    )
                ))
            }
        }

        if let requestedCount = requirements.exactClipCount {
            let actualCount = timeline.items.filter { $0.kind != .title && $0.overlay == nil }.count
            if actualCount != requestedCount {
                issues.append(.init(
                    kind: .exactClipCount,
                    resolution: .blocking,
                    message: "Запрошено ровно \(requestedCount) моментов, но в основном монтаже \(actualCount)."
                ))
            }
        }

        let hasTagRequirements = !plan.constraints.includeTags.isEmpty ||
            !plan.constraints.excludeTags.isEmpty ||
            !plan.constraints.maximumTagShares.isEmpty ||
            plan.constraints.preferredIntroTags?.isEmpty == false ||
            plan.constraints.preferredClimaxTags?.isEmpty == false ||
            plan.constraints.preferredOutroTags?.isEmpty == false
        if hasTagRequirements {
            let evidence = Self.deliveryTagEvidence(plan: plan, analyses: analyses)
            let primary = timeline.items.filter { $0.kind != .title && $0.overlay == nil }

            for requested in Self.canonicalIdentifiers(plan.constraints.includeTags).sorted() {
                let covered = primary.contains {
                    Self.allTags(for: $0, evidence: evidence).contains(requested)
                }
                if !covered {
                    issues.append(.init(
                        kind: .missingRequiredTag,
                        resolution: .blocking,
                        message: "Обязательная тема «\(requested)» не подтверждена ни одним primary-фрагментом."
                    ))
                }
            }

            for excluded in Self.canonicalIdentifiers(plan.constraints.excludeTags).sorted() {
                let violatingCount = primary.filter {
                    Self.contentTags(for: $0, evidence: evidence).contains(excluded)
                }.count
                if violatingCount > 0 {
                    issues.append(.init(
                        kind: .excludedTagPresent,
                        resolution: .blocking,
                        message: "Запрещённая тема «\(excluded)» подтверждена в \(violatingCount) primary-фрагмент(ах)."
                    ))
                }
            }

            let totalPrimaryDuration = primary.reduce(0.0) { $0 + $1.timelineDuration }
            let oneFrame = 1 / max(1, timeline.frameRate)
            var canonicalMaximums: [String: Double] = [:]
            for (tag, maximum) in plan.constraints.maximumTagShares {
                let canonical = Self.canonicalIdentifier(tag)
                canonicalMaximums[canonical] = min(canonicalMaximums[canonical] ?? 1, maximum)
            }
            for (tag, maximum) in canonicalMaximums.sorted(by: { $0.key < $1.key }) where totalPrimaryDuration > 0 {
                let taggedDuration = primary.reduce(0.0) { partial, item in
                    partial + (Self.contentTags(for: item, evidence: evidence).contains(tag) ? item.timelineDuration : 0)
                }
                if taggedDuration > maximum * totalPrimaryDuration + oneFrame {
                    issues.append(.init(
                        kind: .maximumTagShare,
                        resolution: .blocking,
                        message: String(
                            format: "Тема «%@» занимает %.1f%% монтажа при явно заданном максимуме %.1f%%.",
                            tag,
                            taggedDuration / totalPrimaryDuration * 100,
                            maximum * 100
                        )
                    ))
                }
            }

            Self.validatePreferredRole(
                .intro,
                requestedTags: plan.constraints.preferredIntroTags,
                primary: primary,
                evidence: evidence,
                issues: &issues
            )
            Self.validatePreferredRole(
                .climax,
                requestedTags: plan.constraints.preferredClimaxTags,
                primary: primary,
                evidence: evidence,
                issues: &issues
            )
            Self.validatePreferredRole(
                .outro,
                requestedTags: plan.constraints.preferredOutroTags,
                primary: primary,
                evidence: evidence,
                issues: &issues
            )
        }

        let generatedTitles = timeline.effectiveTitleItems.filter(Self.looksAutomaticallyGenerated)
        let overlappingGeneratedIDs = Self.overlappingTitleIDs(in: generatedTitles)
        if !overlappingGeneratedIDs.isEmpty {
            issues.append(.init(
                kind: .titleOverlap,
                resolution: .blocking,
                message: "Автотитры пересекаются на одной дорожке; безопасное размещение без изменения режиссуры не найдено."
            ))
        }
        if requirements.keyTitlesOnly {
            let unconfirmed = generatedTitles.contains {
                SmartTitleEngine.isMeaningless($0.text) || SmartTitleEngine.isStructuralPlaceholder($0.text)
            }
            if unconfirmed {
                issues.append(.init(
                    kind: .generatedTitleQuality,
                    resolution: .blocking,
                    message: "Требование «только ключевые титры» нарушено: остался неподтверждённый содержанием текст."
                ))
            }
        }

        if previewProfile.sourcePreviewContentMode != .aspectFit {
            let crop = Self.maximumSquarePreviewCrop(assets: assets)
            issues.append(.init(
                kind: .sourcePreviewCrop,
                resolution: .blocking,
                message: "Preview исходника настроен на aspect-fill и может скрыть до \(Int((crop * 100).rounded()))% кадра камеры."
            ))
        }
        if previewProfile.timelinePreviewContentMode != .aspectFit {
            issues.append(.init(
                kind: .timelinePreviewCrop,
                resolution: .blocking,
                message: "Preview фильма должен показывать полный монтажный кадр в режиме aspect-fit."
            ))
        }

        if Self.needsStableHighResolutionPreview(timeline: timeline, assets: assets) {
            issues.append(.init(
                kind: .unstableHighResolutionPreview,
                resolution: previewProfile.usesStableRealtimePlayback ? .repaired : .blocking,
                message: previewProfile.usesStableRealtimePlayback
                    ? "Для декорированного 4K/5K camera timeline закреплён стабильный native realtime preview."
                    : "Декорированный 4K/5K camera timeline отправлен в нестабильный custom compositor и может показать чёрный preview."
            ))
        }

        if let review = timeline.directorRun?.perceptualReview,
           review.renderedFrameSampleCount > 0 {
            let failed = review.findings.filter {
                ($0.severity == .high || $0.severity == .critical) &&
                [.blackFrame, .missingRenderContent, .technicalFailure].contains($0.type)
            }
            if !failed.isEmpty {
                issues.append(.init(
                    kind: .renderedBlackFrame,
                    resolution: .blocking,
                    message: "В декодированных контрольных кадрах остались чёрные или отсутствующие изображения."
                ))
            }
        }

        if var run = timeline.directorRun {
            for issue in issues {
                let diagnostic = "Delivery contract: \(issue.message)"
                switch issue.resolution {
                case .repaired:
                    if !run.decisionReasons.contains(diagnostic) { run.decisionReasons.append(diagnostic) }
                case .blocking:
                    if !run.rejectedOperations.contains(diagnostic) { run.rejectedOperations.append(diagnostic) }
                }
            }
            timeline.directorRun = run
        }

        return TimelineDeliveryValidation(timeline: timeline, issues: issues)
    }

    private struct DeliveryTagEvidence {
        var candidateContent: [UUID: Set<String>] = [:]
        var candidateProvenance: [UUID: Set<String>] = [:]
        var assetContent: [UUID: Set<String>] = [:]
    }

    private static let canonicalTagAliases: [(canonical: String, aliases: [String])] = [
        ("cycling", ["cycling", "cyclist", "bicycle", "mountain bike", "mtb", "bike", "велосип*", "велопрогул*"]),
        ("buggy", ["buggy", "utv", "atv", "quadbike", "quad bike", "side by side", "багги", "квадроцикл*"]),
        ("fishing", ["fishing", "angler", "рыбал*", "рыбак*"]),
        ("nature", ["nature", "natural landscape", "landscape", "природ*", "пейзаж*"]),
        ("sunset", ["sunset", "закат*"]),
        ("people", ["people", "person", "family", "люд*", "семь*"]),
        ("high-speed", ["high speed", "high-speed", "speeding", "скорост*", "разгон*"]),
        ("g-force", ["g force", "g-force", "перегруз*"]),
        ("elevation-change", ["elevation change", "elevation-change", "jump", "descent", "ascent", "прыж*", "перепад*", "спуск*", "подъем*", "подъём*"]),
        ("turn", ["turn", "cornering", "поворот*", "вираж*"]),
        ("telemetry-event", ["telemetry event", "telemetry-event", "телеметри*"]),
        ("action", ["action", "stunt", "экшен", "трюк*"])
    ]

    private static func deliveryTagEvidence(
        plan: StoryPlan,
        analyses: [AnalysisResult]
    ) -> DeliveryTagEvidence {
        var result = DeliveryTagEvidence()
        for analysis in analyses {
            result.assetContent[analysis.assetID, default: []].formUnion(
                canonicalIdentifiers(analysis.sceneTags)
            )
            for candidate in analysis.directorCandidates {
                var tags = canonicalIdentifiers(candidate.tags)
                var semanticText = candidate.explanation
                if let summary = candidate.insights?.sceneSummary { semanticText.append(summary) }
                if let emotion = candidate.insights?.emotion { semanticText.append(emotion) }
                tags.formUnion(knownCanonicalTags(in: semanticText))
                result.candidateContent[candidate.id, default: []].formUnion(tags)
            }
        }

        if let sourceMap = plan.eventStory?.diagnostics?.sourceMap {
            for group in sourceMap.activityGroups where group.confidence >= 0.50 {
                let tags = knownCanonicalTags(in: [group.title])
                for assetID in group.assetIDs {
                    result.assetContent[assetID, default: []].formUnion(tags)
                }
            }
            for entry in sourceMap.entries where entry.activityConfidence >= 0.50 {
                result.assetContent[entry.assetID, default: []].formUnion(
                    knownCanonicalTags(in: [entry.activityTitle])
                )
            }
        }

        for chapter in plan.chapters {
            let chapterText = [chapter.title, chapter.purpose, chapter.chapterCardTitle].compactMap { $0 }
            let tags = knownCanonicalTags(in: chapterText)
            for candidateID in chapter.candidateIDs {
                result.candidateProvenance[candidateID, default: []].formUnion(tags)
            }
        }
        return result
    }

    private static func contentTags(
        for item: TimelineItem,
        evidence: DeliveryTagEvidence
    ) -> Set<String> {
        var tags = item.candidateID.flatMap { evidence.candidateContent[$0] } ?? []
        if let assetID = item.assetID { tags.formUnion(evidence.assetContent[assetID] ?? []) }
        return tags
    }

    private static func allTags(
        for item: TimelineItem,
        evidence: DeliveryTagEvidence
    ) -> Set<String> {
        var tags = contentTags(for: item, evidence: evidence)
        if let candidateID = item.candidateID {
            tags.formUnion(evidence.candidateProvenance[candidateID] ?? [])
        }
        return tags
    }

    private static func validatePreferredRole(
        _ role: StoryRole,
        requestedTags: Set<String>?,
        primary: [TimelineItem],
        evidence: DeliveryTagEvidence,
        issues: inout [TimelineDeliveryIssue]
    ) {
        guard let requestedTags, !requestedTags.isEmpty else { return }
        let requested = canonicalIdentifiers(requestedTags)
        let covered = primary.lazy.filter { $0.storyRole == role }.contains { item in
            !allTags(for: item, evidence: evidence).isDisjoint(with: requested)
        }
        guard !covered else { return }
        issues.append(.init(
            kind: .preferredRoleTag,
            resolution: .blocking,
            message: "Роль «\(role.localizedTitle)» не содержит ни одной из явно заданных тем: \(requested.sorted().joined(separator: ", "))."
        ))
    }

    private static func canonicalIdentifiers(_ tags: Set<String>) -> Set<String> {
        Set(tags.map(canonicalIdentifier))
    }

    private static func canonicalIdentifier(_ value: String) -> String {
        if let known = knownCanonicalTags(in: [value]).sorted().first { return known }
        return normalizedSemanticText(value).replacingOccurrences(of: " ", with: "-")
    }

    private static func knownCanonicalTags(in values: [String]) -> Set<String> {
        let normalized = values.map(normalizedSemanticText)
        var result = Set<String>()
        for group in canonicalTagAliases where normalized.contains(where: { text in
            group.aliases.contains { alias in semanticText(text, matches: alias) }
        }) {
            result.insert(group.canonical)
        }
        return result
    }

    private static func normalizedSemanticText(_ value: String) -> String {
        let folded = value.lowercased()
            .folding(options: [.diacriticInsensitive], locale: Locale(identifier: "ru_RU"))
            .replacingOccurrences(of: "ё", with: "е")
        let scalars = folded.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(String(scalar)) : " "
        }
        return String(scalars).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func semanticText(_ text: String, matches rawAlias: String) -> Bool {
        let isPrefix = rawAlias.hasSuffix("*")
        let alias = normalizedSemanticText(isPrefix ? String(rawAlias.dropLast()) : rawAlias)
        guard !alias.isEmpty else { return false }
        if isPrefix { return text.split(separator: " ").contains { $0.hasPrefix(alias) } }
        if alias.contains(" ") { return " \(text) ".contains(" \(alias) ") }
        return text.split(separator: " ").contains(Substring(alias))
    }

    private static func looksAutomaticallyGenerated(_ title: TitleTimelineItem) -> Bool {
        title.explanation.contains { reason in
            let value = reason.lowercased()
            return value.contains("режисс") || value.contains("автомат") || value.contains("event hierarchy")
        }
    }

    private static func overlappingTitleIDs(in titles: [TitleTimelineItem]) -> Set<UUID> {
        let enabled = titles.filter(\.enabled).sorted {
            $0.track == $1.track ? $0.startTime < $1.startTime : $0.track < $1.track
        }
        var result = Set<UUID>()
        for (left, right) in zip(enabled, enabled.dropFirst())
            where left.track == right.track && left.startTime < right.endTime && right.startTime < left.endTime {
            result.insert(left.id)
            result.insert(right.id)
        }
        return result
    }

    private static func maximumSquarePreviewCrop(assets: [MediaAsset]) -> Double {
        assets.compactMap { asset -> Double? in
            guard let width = asset.metadata.width, let height = asset.metadata.height else { return nil }
            return PreviewGeometryContract.assess(
                sourceWidth: Double(width),
                sourceHeight: Double(height),
                viewportWidth: 1,
                viewportHeight: 1,
                contentMode: .aspectFill
            ).cropFraction
        }.max() ?? 1
    }

    private static func needsStableHighResolutionPreview(
        timeline: Timeline,
        assets: [MediaAsset]
    ) -> Bool {
        let assetsByID = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) })
        let primary = timeline.items.filter { $0.overlay == nil && $0.kind != .title }
        guard !primary.isEmpty, primary.allSatisfy({ item in
            item.kind == .video && item.effect == nil && item.overlay == nil && item.effectiveVideoAdjustments.isNeutral
        }) else { return false }
        let descriptors = primary.compactMap { item -> String? in
            guard let id = item.assetID, let metadata = assetsByID[id]?.metadata,
                  let width = metadata.width, let height = metadata.height else { return nil }
            return "\(width)x\(height)@\(metadata.orientationDegrees)"
        }
        guard descriptors.count == primary.count, Set(descriptors).count == 1,
              let firstID = primary.first?.assetID,
              let metadata = assetsByID[firstID]?.metadata,
              max(metadata.width ?? 0, metadata.height ?? 0) >= 3_840 else { return false }
        return !timeline.effectiveTitleItems.isEmpty || !timeline.effectiveTelemetryItems.isEmpty ||
            timeline.effectiveEffects.contains(where: \.enabled) ||
            timeline.effectiveTransitionItems.contains(where: \.enabled) ||
            primary.contains { $0.transition != nil || $0.telemetryOverlay != nil }
    }
}
