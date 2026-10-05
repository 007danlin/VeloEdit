import Foundation
import VeloEditCore

/// Sorted timeline geometry supports mouse movement without scanning the film.
struct TimelineHorizontalGeometry {
    private let items: [TimelineItem]
    private let boundaries: [Double]
    private let snapTimes: [Double]
    let duration: Double

    init(items: [TimelineItem], duration: Double, snapTimes: [Double]) {
        self.items = items
        self.duration = duration
        boundaries = items.dropLast().map { $0.timelineStart + $0.timelineDuration }
        self.snapTimes = snapTimes.sorted()
    }

    func xPosition(for time: Double, pointsPerSecond: Double, spacing: Double) -> Double {
        let time = min(max(0, time), duration)
        let index = lowerBound(count: boundaries.count) { boundaries[$0] >= time - 0.000_001 }
        let onBoundary = index < boundaries.count && abs(boundaries[index] - time) <= 0.000_001
        return time * pointsPerSecond + Double(index) * spacing + (onBoundary ? spacing / 2 : 0)
    }

    func time(at x: Double, pointsPerSecond: Double, spacing: Double) -> Double? {
        guard !items.isEmpty else { return nil }
        let x = max(0, x)
        // Include the gap after each clip in its hit region, so a gap maps to
        // the cut instead of jumping to the next frame.
        let index = lowerBound(count: items.count) {
            let item = items[$0]
            return item.timelineStart * pointsPerSecond + Double($0) * spacing
                + max(1, item.timelineDuration * pointsPerSecond) + spacing > x
        }
        guard index < items.count else { return duration }
        let item = items[index]
        let start = item.timelineStart * pointsPerSecond + Double(index) * spacing
        return min(duration, item.timelineStart + min(item.timelineDuration, max(0, x - start) / pointsPerSecond))
    }

    func snapped(_ time: Double, threshold: Double, frameRate: Double, playhead: Double?) -> Double {
        let index = lowerBound(count: snapTimes.count) { snapTimes[$0] >= time }
        var nearest: Double?
        if index > 0 { nearest = snapTimes[index - 1] }
        if index < snapTimes.count, nearest == nil || abs(snapTimes[index] - time) < abs(nearest! - time) {
            nearest = snapTimes[index]
        }
        if let playhead, nearest == nil || abs(playhead - time) < abs(nearest! - time) { nearest = playhead }
        if let nearest, abs(nearest - time) <= threshold { return min(max(0, nearest), duration) }
        return min(TimelineTiming.quantized(time, frameRate: frameRate), duration)
    }

    private func lowerBound(count: Int, predicate: (Int) -> Bool) -> Int {
        var lower = 0
        var upper = count
        while lower < upper {
            let middle = (lower + upper) / 2
            if predicate(middle) { upper = middle } else { lower = middle + 1 }
        }
        return lower
    }
}
