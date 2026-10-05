import Foundation

/// Shared source-clock and attachment-preserving cuts for brush and editor commands.
enum TimelineRangeSlicer {
    struct Slice {
        var timeline: Timeline
        var itemIDs: [UUID]
        var audioClipIDs: [UUID]
        var telemetryItemIDs: [UUID]
        var effectItemIDs: [UUID]
        var titleItemIDs: [UUID]
    }

    private static func slicedSpeedRamp(_ ramp: SpeedRamp, from lower: Double, to upper: Double) -> SpeedRamp {
        let low = min(max(0, lower), 1)
        let high = min(max(low + 0.000_001, upper), 1)
        let points = ramp.normalizedPoints

        func rate(at position: Double) -> Double {
            guard let rightIndex = points.firstIndex(where: { $0.position >= position }) else {
                return points.last?.rate ?? 1
            }
            guard rightIndex > 0 else { return points[rightIndex].rate }
            let left = points[rightIndex - 1]
            let right = points[rightIndex]
            let fraction = (position - left.position) / max(0.000_001, right.position - left.position)
            return left.rate + (right.rate - left.rate) * fraction
        }

        var selected = [SpeedRampPoint(position: 0, rate: rate(at: low))]
        selected.append(contentsOf: points.compactMap { point in
            guard point.position > low, point.position < high else { return nil }
            return SpeedRampPoint(position: (point.position - low) / (high - low), rate: point.rate)
        })
        selected.append(SpeedRampPoint(position: 1, rate: rate(at: high)))
        return SpeedRamp(points: selected)
    }

    /// Cuts primary-storyline clips on both brush boundaries and returns only
    /// the IDs fully contained by the brushed interval.
    static func slice(_ source: Timeline, for requestedRange: ClosedRange<Double>, onlyAttachedTo: UUID? = nil) -> Slice {
        var timeline = source
        let originalItems = TimelineTiming.retimed(source.items)
        let lower = min(max(0, requestedRange.lowerBound), source.duration)
        let upperCandidate = min(max(lower, requestedRange.upperBound), source.duration)
        let upper = upperCandidate > lower ? upperCandidate : min(source.duration, lower + 1 / max(1, source.frameRate))
        var items: [TimelineItem] = []
        var selectedIDs: [UUID] = []
        var primarySegments: [UUID: [(id: UUID, start: Double, end: Double, selected: Bool)]] = [:]
        let epsilon = 0.0001

        for original in originalItems {
            let itemStart = original.timelineStart
            let itemEnd = itemStart + original.timelineDuration
            guard original.timelineDuration > epsilon,
                  itemEnd > lower + epsilon,
                  itemStart < upper - epsilon else {
                items.append(original)
                if original.overlay == nil {
                    primarySegments[original.id] = [(original.id, itemStart, itemEnd, false)]
                }
                continue
            }

            var cuts = [itemStart, itemEnd]
            if lower > itemStart + epsilon, lower < itemEnd - epsilon { cuts.append(lower) }
            if upper > itemStart + epsilon, upper < itemEnd - epsilon { cuts.append(upper) }
            cuts.sort()

            for segmentIndex in 0..<(cuts.count - 1) {
                let segmentStart = cuts[segmentIndex]
                let segmentEnd = cuts[segmentIndex + 1]
                var segment = original
                if segmentIndex > 0 {
                    segment.id = UUID()
                    segment.transition = nil
                }
                if original.isFreezeFrame {
                    segment.sourceStart = original.sourceStart
                    segment.sourceDuration = original.sourceDuration
                } else {
                    let mappedStart = original.sourceTime(atTimelineTime: segmentStart)
                    let mappedEnd = original.sourceTime(atTimelineTime: segmentEnd)
                    segment.sourceStart = min(mappedStart, mappedEnd)
                    segment.sourceDuration = max(epsilon, abs(mappedEnd - mappedStart))
                    if let ramp = original.speedRamp {
                        let actualStart = (mappedStart - original.sourceStart) / max(epsilon, original.sourceDuration)
                        let actualEnd = (mappedEnd - original.sourceStart) / max(epsilon, original.sourceDuration)
                        let progressStart = original.isReversed ? 1 - actualStart : actualStart
                        let progressEnd = original.isReversed ? 1 - actualEnd : actualEnd
                        segment.speedRamp = slicedSpeedRamp(
                            ramp,
                            from: min(progressStart, progressEnd),
                            to: max(progressStart, progressEnd)
                        )
                    }
                }
                segment.timelineStart = segmentStart
                segment.timelineDuration = max(epsilon, segmentEnd - segmentStart)
                if segment.overlay != nil {
                    segment.overlay?.startOffset = segmentStart - itemStart + original.overlay!.effectiveStartOffset
                }
                items.append(segment)
                let selected = segmentStart >= lower - epsilon && segmentEnd <= upper + epsilon
                if original.overlay == nil {
                    primarySegments[original.id, default: []].append((segment.id, segmentStart, segmentEnd, selected))
                }
                if selected {
                    selectedIDs.append(segment.id)
                }
            }
        }

        func mappedClipID(_ originalID: UUID?, at time: Double) -> UUID? {
            guard let originalID, let segments = primarySegments[originalID], !segments.isEmpty else {
                return originalID
            }
            if let containing = segments.first(where: { time >= $0.start - epsilon && time <= $0.end + epsilon }) {
                return containing.id
            }
            return segments.min {
                min(abs(time - $0.start), abs(time - $0.end))
                    < min(abs(time - $1.start), abs(time - $1.end))
            }?.id
        }

        // Connected media keep their absolute position while their base clip
        // may now be one of several derived segments.
        for index in items.indices where items[index].overlay != nil {
            let itemStart = items[index].timelineStart
            let time = itemStart + items[index].timelineDuration * 0.5
            guard let oldBaseID = items[index].overlay?.baseItemID,
                  let newBaseID = mappedClipID(oldBaseID, at: time),
                  let base = items.first(where: { $0.id == newBaseID }) else { continue }
            items[index].overlay?.baseItemID = newBaseID
            items[index].overlay?.startOffset = itemStart - base.timelineStart
        }
        timeline.items = TimelineTiming.retimed(items)
        if var plan = source.effectiveAdaptiveSoundtrack {
            if plan.timelineFingerprint != nil { plan.timelineFingerprint = timeline.adaptiveSoundtrackFingerprint }
            timeline.adaptiveSoundtrack = plan
        }
        let retimedByID = Dictionary(uniqueKeysWithValues: timeline.items.map { ($0.id, $0) })
        timeline.transitionItems = source.effectiveTransitionItems.compactMap { original in
            guard let outgoing = primarySegments[original.outgoingClipID]?.last?.id
                    ?? mappedClipID(original.outgoingClipID, at: original.startTime - epsilon),
                  let incoming = primarySegments[original.incomingClipID]?.first?.id
                    ?? mappedClipID(original.incomingClipID, at: original.startTime + epsilon),
                  let incomingItem = retimedByID[incoming] else { return nil }
            var copy = original
            copy.outgoingClipID = outgoing
            copy.incomingClipID = incoming
            copy.startTime = incomingItem.timelineStart
            return copy
        }

        func segmentBounds(start: Double, end: Double, ownerID: UUID?) -> [(start: Double, end: Double, selected: Bool)] {
            guard onlyAttachedTo == nil || ownerID == onlyAttachedTo,
                  end > lower + epsilon, start < upper - epsilon else {
                return [(start, end, false)]
            }
            var cuts = [start, end]
            if lower > start + epsilon, lower < end - epsilon { cuts.append(lower) }
            if upper > start + epsilon, upper < end - epsilon { cuts.append(upper) }
            cuts.sort()
            return zip(cuts, cuts.dropFirst()).map { left, right in
                (left, right, left >= lower - epsilon && right <= upper + epsilon)
            }
        }

        var audioIDs: [UUID] = []
        timeline.audioClips = source.effectiveAudioClips.flatMap { original in
            segmentBounds(start: original.timelineStart, end: original.timelineEnd, ownerID: original.attachedToItemID).enumerated().map { index, bounds in
                var segment = original
                if index > 0 { segment.id = UUID() }
                let offset = bounds.start - original.timelineStart
                segment.timelineStart = bounds.start
                segment.timelineDuration = max(epsilon, bounds.end - bounds.start)
                segment.sourceStart = original.sourceStart + offset * original.effectiveSpeed
                segment.sourceDuration = segment.timelineDuration * original.effectiveSpeed
                segment.attachedToItemID = mappedClipID(
                    original.attachedToItemID,
                    at: (bounds.start + bounds.end) * 0.5
                )
                if bounds.selected { audioIDs.append(segment.id) }
                return segment
            }
        }

        var telemetryIDs: [UUID] = []
        timeline.telemetryItems = source.effectiveTelemetryItems.flatMap { original in
            segmentBounds(start: original.timelineStart, end: original.timelineEnd, ownerID: original.targetClipID).enumerated().map { index, bounds in
                var segment = original
                if index > 0 { segment.id = UUID() }
                let offset = bounds.start - original.timelineStart
                segment.timelineStart = bounds.start
                segment.timelineDuration = max(epsilon, bounds.end - bounds.start)
                segment.sourceStart = original.sourceStart + offset
                segment.targetClipID = mappedClipID(
                    original.targetClipID,
                    at: (bounds.start + bounds.end) * 0.5
                )
                if bounds.selected { telemetryIDs.append(segment.id) }
                return segment
            }
        }

        var effectIDs: [UUID] = []
        timeline.effects = source.effectiveEffects.flatMap { original in
            segmentBounds(start: original.startTime, end: original.endTime, ownerID: original.targetClipID).enumerated().map { index, bounds in
                var segment = original
                if index > 0 { segment.id = UUID() }
                let offset = bounds.start - original.startTime
                segment.startTime = bounds.start
                segment.duration = max(epsilon, bounds.end - bounds.start)
                segment.targetClipID = mappedClipID(
                    original.targetClipID,
                    at: (bounds.start + bounds.end) * 0.5
                )
                segment.keyframes = original.keyframes.compactMap { keyframe in
                    let absolute = original.startTime + keyframe.time
                    guard absolute >= bounds.start - epsilon, absolute <= bounds.end + epsilon else { return nil }
                    var copy = keyframe
                    copy.time = max(0, absolute - bounds.start)
                    return copy
                }
                if offset > 0, segment.keyframes.isEmpty { segment.keyframes = [] }
                if bounds.selected { effectIDs.append(segment.id) }
                return segment
            }
        }

        var titleIDs: [UUID] = []
        timeline.titleItems = source.effectiveTitleItems.flatMap { original in
            segmentBounds(start: original.startTime, end: original.endTime, ownerID: original.targetClipID).enumerated().map { index, bounds in
                var segment = original
                if index > 0 { segment.id = UUID() }
                segment.startTime = bounds.start
                segment.duration = max(epsilon, bounds.end - bounds.start)
                segment.targetClipID = mappedClipID(
                    original.targetClipID,
                    at: (bounds.start + bounds.end) * 0.5
                )
                segment.words = original.words.compactMap { word in
                    let absoluteStart = original.startTime + word.start
                    let absoluteEnd = original.startTime + word.end
                    guard absoluteEnd > bounds.start, absoluteStart < bounds.end else { return nil }
                    var copy = word
                    copy.start = max(0, absoluteStart - bounds.start)
                    copy.end = min(segment.duration, absoluteEnd - bounds.start)
                    return copy
                }
                if bounds.selected { titleIDs.append(segment.id) }
                return segment
            }
        }

        return Slice(
            timeline: timeline,
            itemIDs: selectedIDs,
            audioClipIDs: audioIDs,
            telemetryItemIDs: telemetryIDs,
            effectItemIDs: effectIDs,
            titleItemIDs: titleIDs
        )
    }

}
