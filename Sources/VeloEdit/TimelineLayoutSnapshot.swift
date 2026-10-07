import Foundation
import VeloEditCore

enum EffectTimelineGroupingKey: Hashable {
    case presetInstance(UUID)
    case legacyPreset(String, UUID?, Int64, Int64)
    case standalone(UUID)
}

struct EffectTimelineBlock: Identifiable {
    let id: UUID
    var items: [EffectTimelineItem]
    let presetID: String?

    var primary: EffectTimelineItem { items[0] }
    var itemIDs: [UUID] { items.map(\.id) }
    var startTime: Double { items.map(\.startTime).min() ?? primary.startTime }
    var endTime: Double { items.map(\.endTime).max() ?? primary.endTime }
    var duration: Double { max(0.05, endTime - startTime) }
    var isEnabled: Bool { items.allSatisfy(\.enabled) }
    var hasKeyframes: Bool { items.contains { !$0.keyframes.isEmpty } }
    var title: String {
        presetID.flatMap { EffectStackPresetRegistry.preset(id: $0)?.name }
            ?? primary.effectType.localizedTitle
    }
    var category: TimelineEffectCategory { primary.effectType.category }
}

/// Immutable layout derived when the timeline input changes, never during a drag tick.
struct TimelineLayoutSnapshot {
    let primaryItems: [TimelineItem]
    let primaryIndices: [UUID: Int]
    let connectedItems: [TimelineItem]
    let audioClips: [TimelineAudioClip]
    let telemetryItems: [TimelineTelemetryItem]
    let effectItems: [EffectTimelineItem]
    let titleItems: [TitleTimelineItem]
    let effectBlocks: [EffectTimelineBlock]
    let connectedLaneAssignments: [UUID: Int]
    let audioLaneAssignments: [UUID: Int]
    let telemetryLaneAssignments: [UUID: Int]
    let effectLaneAssignments: [UUID: Int]
    let titleLaneAssignments: [UUID: Int]
    let connectedLaneCount: Int
    let audioLaneCount: Int
    let telemetryLaneCount: Int
    let effectLaneCount: Int
    let titleLaneCount: Int
    let geometry: TimelineHorizontalGeometry

    init(timeline: Timeline) {
        primaryItems = timeline.items.filter { $0.overlay == nil }
        primaryIndices = Dictionary(primaryItems.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
        connectedItems = timeline.items.filter { $0.overlay != nil }
        audioClips = timeline.effectiveAudioClips
        telemetryItems = timeline.effectiveTelemetryItems
        effectItems = timeline.effectiveEffects
        titleItems = timeline.effectiveTitleItems
        var blocks: [EffectTimelineBlock] = []
        var indices: [EffectTimelineGroupingKey: Int] = [:]
        for item in effectItems {
            let presetID = Self.resolvedEffectStackPresetID(for: item)
            let key: EffectTimelineGroupingKey
            if let instanceID = item.effectStackPresetInstanceID {
                key = .presetInstance(instanceID)
            } else if let presetID {
                key = .legacyPreset(
                    presetID,
                    item.targetClipID,
                    Int64((item.startTime * 1_000).rounded()),
                    Int64((item.duration * 1_000).rounded())
                )
            } else {
                key = .standalone(item.id)
            }

            if let index = indices[key] {
                blocks[index].items.append(item)
            } else {
                indices[key] = blocks.count
                blocks.append(EffectTimelineBlock(
                    id: item.effectStackPresetInstanceID ?? item.id,
                    items: [item],
                    presetID: presetID
                ))
            }
        }
        effectBlocks = blocks

        connectedLaneAssignments = Self.laneAssignments(connectedItems.map { ($0.id, $0.timelineStart, $0.timelineStart + $0.timelineDuration) })
        audioLaneAssignments = Self.laneAssignments(audioClips.map { ($0.id, $0.timelineStart, $0.timelineEnd) })
        telemetryLaneAssignments = Self.laneAssignments(telemetryItems.map { ($0.id, $0.timelineStart, $0.timelineEnd) })
        effectLaneAssignments = Self.laneAssignments(effectBlocks.map { ($0.id, $0.startTime, $0.endTime) })
        titleLaneAssignments = Self.laneAssignments(titleItems.map { ($0.id, $0.startTime, $0.endTime) })
        connectedLaneCount = max(1, (connectedLaneAssignments.values.max() ?? 0) + 1)
        audioLaneCount = max(1, (audioLaneAssignments.values.max() ?? 0) + 1)
        telemetryLaneCount = max(1, (telemetryLaneAssignments.values.max() ?? 0) + 1)
        effectLaneCount = max(1, (effectLaneAssignments.values.max() ?? 0) + 1)
        titleLaneCount = max(1, (titleLaneAssignments.values.max() ?? 0) + 1)
        var snapTimes = primaryItems.flatMap { [$0.timelineStart, $0.timelineStart + $0.timelineDuration] }
        snapTimes += connectedItems.flatMap { [$0.timelineStart, $0.timelineStart + $0.timelineDuration] }
        snapTimes += telemetryItems.flatMap { [$0.timelineStart, $0.timelineEnd] }
        snapTimes += audioClips.flatMap { [$0.timelineStart, $0.timelineEnd] }
        snapTimes += titleItems.flatMap { [$0.startTime, $0.endTime] }
        snapTimes += effectBlocks.flatMap { [$0.startTime, $0.endTime] }
        geometry = TimelineHorizontalGeometry(items: primaryItems, duration: timeline.duration, snapTimes: snapTimes)
    }

    private static func resolvedEffectStackPresetID(for item: EffectTimelineItem) -> String? {
        if let presetID = item.effectStackPresetID,
           EffectStackPresetRegistry.preset(id: presetID) != nil {
            return presetID
        }
        return EffectStackPresetRegistry.all.first { preset in
            item.explanation.contains { $0.contains("Data-driven preset \(preset.name);") }
        }?.id
    }

    private static func laneAssignments(_ regions: [(id: UUID, start: Double, end: Double)]) -> [UUID: Int] {
        var laneEnds: [Double] = []
        var result: [UUID: Int] = [:]
        for region in regions.sorted(by: { $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start }) {
            if let lane = laneEnds.firstIndex(where: { $0 <= region.start + 0.0001 }) {
                laneEnds[lane] = region.end
                result[region.id] = lane
            } else {
                result[region.id] = laneEnds.count
                laneEnds.append(region.end)
            }
        }
        return result
    }

}
