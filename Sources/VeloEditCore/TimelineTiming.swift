import Foundation

public enum TimelineTiming {
    public static func quantized(_ time: Double, frameRate: Double) -> Double {
        let fps = max(1, frameRate.isFinite ? frameRate : 30)
        return max(0, (time * fps).rounded() / fps)
    }

    /// AVFoundation renders a transition by overlapping the incoming and
    /// outgoing clips. The editor, however, keeps magnetic clips adjacent so
    /// their visible boundaries remain easy to edit. These helpers provide the
    /// single mapping between both clocks.
    public static func transitionOverlap(incoming: TimelineItem, previous: TimelineItem?) -> Double {
        guard incoming.overlay == nil,
              incoming.transition.flatMap(TransitionStyle.init(rawValue:)) != nil,
              let previous,
              previous.overlay == nil else { return 0 }
        return max(0.12, min(0.65, incoming.timelineDuration * 0.28, previous.timelineDuration * 0.28))
    }

    public static func playbackTime(forTimelineTime requestedTime: Double, items: [TimelineItem]) -> Double {
        let primaries = retimed(items).filter { $0.overlay == nil }
        guard !primaries.isEmpty else { return max(0, requestedTime) }
        let timelineTime = min(max(0, requestedTime), primaries.last.map { $0.timelineStart + $0.timelineDuration } ?? 0)
        let starts = playbackStarts(for: primaries)
        for index in primaries.indices {
            let item = primaries[index]
            let isLast = index == primaries.index(before: primaries.endIndex)
            if timelineTime >= item.timelineStart,
               timelineTime < item.timelineStart + item.timelineDuration || isLast {
                let fraction = min(max(0, (timelineTime - item.timelineStart) / max(0.001, item.timelineDuration)), 1)
                let playbackEnd = isLast ? starts[index] + item.timelineDuration : starts[index + 1]
                return starts[index] + (playbackEnd - starts[index]) * fraction
            }
        }
        return starts.last.map { $0 + (primaries.last?.timelineDuration ?? 0) } ?? timelineTime
    }

    public static func timelineTime(forPlaybackTime requestedTime: Double, items: [TimelineItem]) -> Double {
        let primaries = retimed(items).filter { $0.overlay == nil }
        guard !primaries.isEmpty else { return max(0, requestedTime) }
        let playbackTime = max(0, requestedTime)
        let starts = playbackStarts(for: primaries)
        for index in primaries.indices {
            let item = primaries[index]
            let isLast = index == primaries.index(before: primaries.endIndex)
            let playbackEnd = isLast ? starts[index] + item.timelineDuration : starts[index + 1]
            if playbackTime < playbackEnd || isLast {
                let fraction = min(max(0, (playbackTime - starts[index]) / max(0.001, playbackEnd - starts[index])), 1)
                return item.timelineStart + item.timelineDuration * fraction
            }
        }
        return primaries.last.map { $0.timelineStart + $0.timelineDuration } ?? playbackTime
    }

    private static func playbackStarts(for primaries: [TimelineItem]) -> [Double] {
        var accumulatedOverlap = 0.0
        return primaries.indices.map { index in
            accumulatedOverlap += transitionOverlap(
                incoming: primaries[index],
                previous: index > 0 ? primaries[index - 1] : nil
            )
            return max(0, primaries[index].timelineStart - accumulatedOverlap)
        }
    }

    /// Primary clips remain sequential. Overlay clips share the base clip's
    /// connection point but may be positioned freely through `startOffset`.
    /// Connected clips never lengthen the magnetic storyline.
    public static func retimed(_ items: [TimelineItem]) -> [TimelineItem] {
        var result = items
        var cursor = 0.0
        var primaryRanges: [UUID: (start: Double, duration: Double)] = [:]

        for index in result.indices where result[index].overlay == nil {
            result[index].timelineStart = cursor
            cursor += result[index].timelineDuration
            primaryRanges[result[index].id] = (result[index].timelineStart, result[index].timelineDuration)
        }
        for index in result.indices where result[index].overlay != nil {
            let requestedBase = result[index].overlay?.baseItemID
            let oldStart = result[index].timelineStart
            let baseID = requestedBase.flatMap { primaryRanges[$0] != nil ? $0 : nil }
                ?? primaryRanges.min(by: {
                    abs($0.value.start - oldStart) < abs($1.value.start - oldStart)
                })?.key
            guard let baseID, let base = primaryRanges[baseID] else {
                result[index].overlay = nil
                result[index].timelineStart = cursor
                cursor += result[index].timelineDuration
                continue
            }
            result[index].overlay?.baseItemID = baseID
            let offset: Double
            if requestedBase == baseID {
                offset = result[index].overlay?.effectiveStartOffset ?? 0
            } else {
                offset = oldStart - base.start
                result[index].overlay?.startOffset = offset
            }
            let start = min(max(0, base.start + offset), max(0, cursor - 0.05))
            result[index].timelineStart = start
        }
        return result
    }
}
