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
