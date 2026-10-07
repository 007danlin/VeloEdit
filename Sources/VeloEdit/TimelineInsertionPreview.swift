import Foundation

struct TimelineDropCoordinates {
    let canvasOrigin: CGPoint

    func canvasPoint(from viewportPoint: CGPoint) -> CGPoint {
        CGPoint(x: viewportPoint.x - canvasOrigin.x, y: viewportPoint.y - canvasOrigin.y)
    }
}

struct TimelineInsertionGeometry {
    let frames: [CGRect]

    /// Use the unchanged sequence for hit testing, so opening the gap cannot
    /// move the target out from under the pointer and make it oscillate.
    func insertionIndex(at x: CGFloat) -> Int {
        frames.firstIndex { x < $0.midX } ?? frames.count
    }

    func boundaryX(at index: Int, spacing: CGFloat) -> CGFloat {
        if index < frames.count { return frames[max(0, index)].minX }
        return frames.last.map { $0.maxX + spacing } ?? 0
    }

    func transitionIndex(at x: CGFloat) -> Int? {
        frames.indices.dropFirst().min { abs(frames[$0].minX - x) < abs(frames[$1].minX - x) }
    }

    func offset(for index: Int, insertingAt target: Int, gap: CGFloat) -> CGFloat {
        index >= target ? gap : 0
    }
}

struct TimelineInsertionPreview: Equatable {
    enum Lane { case primary, transition, title, effect, telemetry, audio }
    let lane: Lane
    let index: Int?
    let time: Double
    let x: CGFloat
    let width: CGFloat
    let label: String
    let symbol: String
    var laneIndex: Int = 0

    var gap: CGFloat { index == nil ? 0 : width + 8 }
}
