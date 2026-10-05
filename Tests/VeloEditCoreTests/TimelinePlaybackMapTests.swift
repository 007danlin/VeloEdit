import Foundation
import Testing
@testable import VeloEditCore

struct TimelinePlaybackMapTests {
    @Test func cachedClockMatchesExistingMappingIncludingDisabledAndStaleTransitions() {
        let items = TimelineTiming.retimed((0..<120).map { index in
            TimelineItem(kind: .video, sourceDuration: 3, timelineStart: 0,
                         timelineDuration: 0.15 + Double(index % 11) / 3,
                         transition: index % 2 == 0 ? TransitionStyle.crossDissolve.rawValue : nil)
        })
        var timeline = Timeline(storyPlanID: UUID(), items: items)
        timeline.transitionItems = items.indices.dropFirst().filter { $0 % 3 == 0 }.map { index in
            TimelineTransitionItem(style: .crossDissolve, outgoingClipID: items[index - 1].id,
                                   incomingClipID: items[index].id, startTime: items[index].timelineStart,
                                   duration: 0.4, enabled: index % 6 != 0)
        }
        timeline.transitionItems?.append(TimelineTransitionItem(style: .crossDissolve,
            outgoingClipID: UUID(), incomingClipID: items[0].id, startTime: 0, duration: 1))
        let map = TimelineTiming.PlaybackMap(timeline: timeline)
        let times = [-1.0, timeline.duration, timeline.duration + 1]
            + items.flatMap { [$0.timelineStart, $0.timelineStart + $0.timelineDuration / 2] }
        for time in times {
            let expected = TimelineTiming.playbackTime(forTimelineTime: time, timeline: timeline)
            #expect(abs(map.playbackTime(forTimelineTime: time) - expected) < 0.000_001)
            #expect(abs(map.timelineTime(forPlaybackTime: expected)
                        - TimelineTiming.timelineTime(forPlaybackTime: expected, timeline: timeline)) < 0.000_001)
        }
    }

    @Test func emptyClockDoesNotRequireSegments() {
        let map = TimelineTiming.PlaybackMap(timeline: Timeline(storyPlanID: UUID(), items: []))
        #expect(map.playbackTime(forTimelineTime: -1) == 0)
        #expect(map.timelineTime(forPlaybackTime: 4) == 4)
    }
}
