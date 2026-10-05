import AppKit
import SwiftUI
import Testing
import VeloEditCore
@testable import VeloEdit

@Suite(.serialized)
@MainActor
struct TimelineViewportTests {
    @Test func renderWindowCoversViewportAndKeepsNearbyScrollsStable() {
        let window = TimelineRenderWindow(visibleRect: CGRect(x: 600, y: 0, width: 1_000, height: 400))
        let nearby = TimelineRenderWindow(visibleRect: CGRect(x: 605, y: 0, width: 1_000, height: 400))
        #expect(window == nearby)
        #expect(window.range.lowerBound <= 600)
        #expect(window.range.upperBound >= 1_600)
        #expect(window.range.upperBound - window.range.lowerBound < 2_000)
        #expect(window.intersects(x: 0, width: 10_000))
        #expect(!window.intersects(x: 3_000, width: 100))
    }

    @Test func longCanvasesDrawOnlyVisibleBarsAndPreserveTheirIndices() {
        let slice = TimelineDrawingSlice(width: 100_000, origin: 0, range: 50_000...51_200)
        #expect(slice.width == 1_200)
        #expect(slice.indices(count: 25_000, fullWidth: 100_000) == 12_500..<12_800)
        let moved = TimelineDrawingSlice(width: 100_000, origin: 0, range: 50_100...51_300)
        #expect(moved.indices(count: 25_000, fullWidth: 100_000).lowerBound == 12_525)
        let outside = TimelineDrawingSlice(width: 200, origin: 0, range: 1_000...2_000)
        #expect(outside.width == 0)
        #expect(outside.indices(count: 10, fullWidth: 200).isEmpty)
        let fallback = TimelineDrawingSlice(width: 200, origin: 80, range: nil)
        #expect(fallback.width == 200)
    }

    @Test func viewportReaderTracksNativeScrollAndResize() async throws {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 1_000, height: 400))
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 100_000, height: 400))
        let reader = TimelineViewportReader.ObserverView(frame: document.bounds)
        document.addSubview(reader)
        scroll.documentView = document
        let window = NSWindow(contentRect: scroll.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = scroll
        defer { reader.detach(); window.contentView = nil }
        var windows: [TimelineRenderWindow] = []
        reader.onChange = { windows.append($0) }
        reader.scheduleUpdate()
        try await Task.sleep(for: .milliseconds(20))
        let initial = try #require(windows.last)
        #expect(initial.range.lowerBound == 0)
        scroll.contentView.scroll(to: NSPoint(x: 25_000, y: 0))
        try await Task.sleep(for: .milliseconds(20))
        let moved = try #require(windows.last)
        #expect(moved.range.lowerBound <= 25_000)
        #expect(moved.range.lowerBound > 24_000)
        #expect(moved.range.upperBound >= 26_000)
        #expect(windows.count == 2)
    }

    /// Exercise real SwiftUI layout, rather than just timing the model setter.
    /// Keep the workload deterministic so the same test can compare builds.
    @Test func largeTimelineLayoutStudy() async throws {
        let suite = "VeloEdit.layout-study.\(UUID())"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let model = AppModel(defaults: UserDefaults(suiteName: suite)!, startBackgroundServices: false)
        let items = (0..<300).map { index in
            TimelineItem(kind: .video, sourceDuration: 10, timelineStart: Double(index) * 10, timelineDuration: 10)
        }
        let titles = (0..<900).map { index in
            TitleTimelineItem(kind: .wordLevelCaptions, text: "Субтитры \(index)", startTime: Double(index) * 3.3, duration: 2.5)
        }
        var timeline = Timeline(storyPlanID: UUID(), items: items, titleItems: titles)
        model.project = ProjectManifest(name: "Layout", timelines: [timeline])
        let makeView = { (timeline: Timeline) in
            MagneticTimelineView(timeline: timeline, playbackClock: model.playbackClock)
                .environmentObject(model).frame(width: 1_200, height: 400)
        }
        let host = NSHostingView(rootView: makeView(timeline))
        host.frame = NSRect(x: 0, y: 0, width: 1_200, height: 400)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(30))
        var samples: [Double] = []
        for index in 0..<12 {
            timeline.versionName = "Render \(index)"
            let start = ProcessInfo.processInfo.systemUptime
            host.rootView = makeView(timeline)
            host.layoutSubtreeIfNeeded()
            samples.append((ProcessInfo.processInfo.systemUptime - start) * 1_000)
            await Task.yield()
        }
        samples.sort()
        print("PERF actual-swiftui-layout clips=300 subtitles=900 median_ms=\(samples[6]) p95_ms=\(samples[11])")
        #expect(samples[6] < 50) // Catches rebuilding the entire 1,200-element document.
        #expect(host.fittingSize.width >= 1_200)
    }
}
