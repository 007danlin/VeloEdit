import Foundation
import Testing
@testable import VeloEdit

struct TimelineTrimRangeTests {
    @Test func leadingTrimFollowsPointerWithoutMovingRightEdge() {
        let original = TimelineTrimRange(start: 10, duration: 8)
        let frame = CGRect(x: 188, y: 0, width: 144, height: 76)
        let trimmed = original.trimming(.leading, by: 2)
        let preview = trimmed.previewFrame(from: original, frame: frame, pointsPerSecond: 18)
        #expect(trimmed.start == 12)
        #expect(trimmed.end == original.end)
        #expect(preview.minX == frame.minX + 36)
        #expect(preview.maxX == frame.maxX)
        #expect(original == TimelineTrimRange(start: 10, duration: 8))
    }

    @Test func leadingExtensionStopsAtAvailableSourceAndPreservesEnd() {
        let original = TimelineTrimRange(start: 10, duration: 8)
        let extended = original.trimming(.leading, by: -20, minimumStart: 7)
        #expect(extended.start == 7)
        #expect(extended.end == 18)
        let shortest = original.trimming(.leading, by: 20, minimumDuration: 0.25)
        #expect(shortest.duration == 0.25)
        #expect(shortest.end == 18)
    }

    @Test func rightTrimKeepsLeftEdgeAndRespectsSourceEnd() {
        let original = TimelineTrimRange(start: 10, duration: 8)
        let frame = CGRect(x: 188, y: 0, width: 144, height: 28)
        let shortened = original.trimming(.trailing, by: -3)
        let preview = shortened.previewFrame(from: original, frame: frame, pointsPerSecond: 18)
        #expect(preview.minX == frame.minX)
        #expect(preview.maxX == frame.maxX - 54)
        let extended = original.trimming(.trailing, by: 20, maximumEnd: 21)
        #expect(extended.start == 10)
        #expect(extended.end == 21)
    }

    @Test func shortDecorativeObjectsKeepTheirRightEdgeDuringLeftTrim() {
        let original = TimelineTrimRange(start: 2, duration: 0.5)
        for width: CGFloat in [28, 42] {
            let frame = CGRect(x: 36, y: 0, width: width, height: 28)
            let trimmed = original.trimming(.leading, by: 0.25)
            let preview = trimmed.previewFrame(from: original, frame: frame, pointsPerSecond: 18)
            #expect(preview.minX == 40.5)
            #expect(preview.maxX == frame.maxX)
        }
    }
}
