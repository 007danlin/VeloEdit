import Foundation
import CoreMedia

public enum TimelineTiming {
    // Exactly represents 1/30, 1/60 and 1001/30000, 1001/60000.
    static let compositionTimescale: CMTimeScale = 6_000_000
    /// Prepare once per edit; pointer events and playback ticks only do a
    /// binary search, without retiming/copying the entire film each time.
    public struct PlaybackMap: Sendable {
        private struct Segment: Sendable {
            let timelineStart: Double
            let timelineDuration: Double
            let playbackStart: Double
            let playbackDuration: Double
        }
        private let segments: [Segment]
        public let duration: Double

        public init(timeline: Timeline) {
            let primaries = TimelineTiming.retimed(timeline.items).filter { $0.overlay == nil }
            let starts = TimelineTiming.playbackStarts(for: primaries, transitionItems: timeline.effectiveTransitionItems)
            duration = timeline.duration
            segments = primaries.indices.map { index in
                let item = primaries[index]
                let end = index + 1 < primaries.count ? starts[index + 1]
                    : starts[index] + TimelineTiming.compositionSeconds(item.timelineDuration)
                return Segment(timelineStart: item.timelineStart, timelineDuration: item.timelineDuration,
                               playbackStart: starts[index], playbackDuration: end - starts[index])
            }
        }

        public func playbackTime(forTimelineTime time: Double) -> Double {
            guard let last = segments.last else { return max(0, time) }
            let time = min(max(0, time), last.timelineStart + last.timelineDuration)
            let index = segmentIndex { $0.timelineStart + $0.timelineDuration > time }
            let segment = segments[index]
            let fraction = min(max(0, (time - segment.timelineStart) / max(0.001, segment.timelineDuration)), 1)
            return segment.playbackStart + segment.playbackDuration * fraction
        }

        public func timelineTime(forPlaybackTime time: Double) -> Double {
            guard !segments.isEmpty else { return max(0, time) }
            let time = max(0, time)
            let index = segmentIndex { $0.playbackStart + $0.playbackDuration > time }
            let segment = segments[index]
            let fraction = min(max(0, (time - segment.playbackStart) / max(0.001, segment.playbackDuration)), 1)
            return segment.timelineStart + segment.timelineDuration * fraction
        }

        private func segmentIndex(where endsAfter: (Segment) -> Bool) -> Int {
            var lower = 0
            var upper = segments.count
            while lower < upper {
                let middle = (lower + upper) / 2
                if endsAfter(segments[middle]) { upper = middle } else { lower = middle + 1 }
            }
            return min(lower, segments.count - 1)
        }
    }

    public static func quantized(_ time: Double, frameRate: Double) -> Double {
        let fps = max(1, frameRate.isFinite ? frameRate : 30)
        return max(0, (time * fps).rounded() / fps)
    }

    /// AVFoundation renders a transition by overlapping the incoming and
    /// outgoing clips. The editor, however, keeps magnetic clips adjacent so
    /// their visible boundaries remain easy to edit. These helpers provide the
    /// single mapping between both clocks.
    public static func transitionOverlap(incoming: TimelineItem, previous: TimelineItem?, transitionItems: [TimelineTransitionItem] = []) -> Double {
        guard incoming.overlay == nil,
              let previous,
              previous.overlay == nil else { return 0 }
        let explicit = transitionItems.first { $0.incomingClipID == incoming.id && $0.outgoingClipID == previous.id }
        let style = explicit?.style ?? incoming.transition.flatMap(TransitionStyle.init(rawValue:))
        guard explicit?.enabled != false, let style, style != .cut else { return 0 }
        let requested = explicit?.duration ?? max(0.12, min(0.65, incoming.timelineDuration * 0.28, previous.timelineDuration * 0.28))
        guard requested.isFinite, requested > 0,
              incoming.timelineDuration.isFinite, previous.timelineDuration.isFinite else { return 0 }
        // Two alternating video tracks must never contain three primary clips
        // at once. Reserve at most half of each neighbor for this boundary.
        // Use the same precise clock as AVComposition, rounding the cap down.
        let ticks = Double(compositionTimescale)
        let limit = (min(compositionSeconds(incoming.timelineDuration), compositionSeconds(previous.timelineDuration)) * 0.5 * ticks).rounded(.down) / ticks
        return max(0, min(compositionSeconds(requested), limit))
    }

    /// Resolves legacy clip flags and explicit objects against actual adjacent
    /// clips. Disabled objects override legacy flags; stale pairs are ignored.
    public static func resolvedTransitions(items: [TimelineItem], transitionItems: [TimelineTransitionItem]) -> [TimelineTransitionItem] {
        let primaries = retimed(items).filter { $0.overlay == nil }
        return primaries.indices.dropFirst().compactMap { index in
            let incoming = primaries[index]
            let previous = primaries[index - 1]
            let overlap = transitionOverlap(incoming: incoming, previous: previous, transitionItems: transitionItems)
            guard overlap > 0 else { return nil }
            var item = transitionItems.first { $0.incomingClipID == incoming.id && $0.outgoingClipID == previous.id }
                ?? TimelineTransitionItem(style: incoming.transition.flatMap(TransitionStyle.init(rawValue:)) ?? .cut,
                                          outgoingClipID: previous.id, incomingClipID: incoming.id,
                                          startTime: incoming.timelineStart, duration: overlap)
            item.startTime = incoming.timelineStart
            item.duration = overlap
            return item
        }
    }

    public static func playbackTime(forTimelineTime time: Double, timeline: Timeline) -> Double {
        playbackTime(forTimelineTime: time, items: timeline.items, transitionItems: timeline.effectiveTransitionItems)
    }

    public static func timelineTime(forPlaybackTime time: Double, timeline: Timeline) -> Double {
        timelineTime(forPlaybackTime: time, items: timeline.items, transitionItems: timeline.effectiveTransitionItems)
    }

    public static func playbackTime(forTimelineTime requestedTime: Double, items: [TimelineItem], transitionItems: [TimelineTransitionItem] = []) -> Double {
        let primaries = retimed(items).filter { $0.overlay == nil }
        guard !primaries.isEmpty else { return max(0, requestedTime) }
        let timelineTime = min(max(0, requestedTime), primaries.last.map { $0.timelineStart + $0.timelineDuration } ?? 0)
        let starts = playbackStarts(for: primaries, transitionItems: transitionItems)
        for index in primaries.indices {
            let item = primaries[index]
            let isLast = index == primaries.index(before: primaries.endIndex)
            if timelineTime >= item.timelineStart,
               timelineTime < item.timelineStart + item.timelineDuration || isLast {
                let fraction = min(max(0, (timelineTime - item.timelineStart) / max(0.001, item.timelineDuration)), 1)
                let playbackEnd = isLast ? starts[index] + compositionSeconds(item.timelineDuration) : starts[index + 1]
                return starts[index] + (playbackEnd - starts[index]) * fraction
            }
        }
        return starts.last.map { $0 + (primaries.last?.timelineDuration ?? 0) } ?? timelineTime
    }

    public static func timelineTime(forPlaybackTime requestedTime: Double, items: [TimelineItem], transitionItems: [TimelineTransitionItem] = []) -> Double {
        let primaries = retimed(items).filter { $0.overlay == nil }
        guard !primaries.isEmpty else { return max(0, requestedTime) }
        let playbackTime = max(0, requestedTime)
        let starts = playbackStarts(for: primaries, transitionItems: transitionItems)
        for index in primaries.indices {
            let item = primaries[index]
            let isLast = index == primaries.index(before: primaries.endIndex)
            let playbackEnd = isLast ? starts[index] + compositionSeconds(item.timelineDuration) : starts[index + 1]
            if playbackTime < playbackEnd || isLast {
                let fraction = min(max(0, (playbackTime - starts[index]) / max(0.001, playbackEnd - starts[index])), 1)
                return item.timelineStart + item.timelineDuration * fraction
            }
        }
        return primaries.last.map { $0.timelineStart + $0.timelineDuration } ?? playbackTime
    }

    /// Construct the same integer ticks used by both clocks. CMTime(seconds:)
    /// truncates fractional ticks; repeating that conversion loses frames on
    /// long edits even when every individual clip differs by less than 2 ms.
    static func compositionTime(_ time: Double) -> CMTime {
        CMTime(value: Int64((time * Double(compositionTimescale)).rounded()), timescale: compositionTimescale)
    }

    private static func compositionSeconds(_ time: Double) -> Double {
        compositionTime(time).seconds
    }

    private struct TransitionPair: Hashable {
        let outgoing: UUID
        let incoming: UUID
    }

    private static func playbackStarts(for primaries: [TimelineItem], transitionItems: [TimelineTransitionItem]) -> [Double] {
        let transitions = Dictionary(transitionItems.map {
            (TransitionPair(outgoing: $0.outgoingClipID, incoming: $0.incomingClipID), $0)
        }, uniquingKeysWith: { first, _ in first })
        var cursor = 0.0
        return primaries.indices.map { index in
            let explicit = index > 0 ? transitions[TransitionPair(outgoing: primaries[index - 1].id,
                                                                 incoming: primaries[index].id)] : nil
            let overlap = transitionOverlap(
                incoming: primaries[index],
                previous: index > 0 ? primaries[index - 1] : nil,
                transitionItems: explicit.map { [$0] } ?? []
            )
            let start = max(0, cursor - overlap)
            cursor = start + compositionSeconds(primaries[index].timelineDuration)
            return start
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
