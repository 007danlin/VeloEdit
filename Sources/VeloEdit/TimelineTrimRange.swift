import Foundation

enum TimelineTrimEdge {
    case leading
    case trailing
}

/// A drag edits one boundary while keeping the opposite boundary stationary.
/// Magnetic reflow belongs to the committed edit, not to this preview.
struct TimelineTrimRange: Equatable {
    let start: Double
    let duration: Double

    var end: Double { start + duration }

    func trimming(
        _ edge: TimelineTrimEdge, by delta: Double,
        minimumStart: Double = 0, maximumEnd: Double = .greatestFiniteMagnitude,
        minimumDuration: Double = 0.05
    ) -> Self {
        switch edge {
        case .leading:
            let nextStart = min(max(start + delta, minimumStart), end - minimumDuration)
            return Self(start: nextStart, duration: end - nextStart)
        case .trailing:
            let nextEnd = max(start + minimumDuration, min(end + delta, maximumEnd))
            return Self(start: start, duration: nextEnd - start)
        }
    }

    func previewFrame(from original: Self, frame: CGRect, pointsPerSecond: Double) -> CGRect {
        CGRect(
            x: frame.minX + (start - original.start) * pointsPerSecond,
            y: frame.minY,
            width: max(1, frame.width + (duration - original.duration) * pointsPerSecond),
            height: frame.height
        )
    }
}
