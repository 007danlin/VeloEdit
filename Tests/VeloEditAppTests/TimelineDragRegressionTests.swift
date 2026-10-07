import AppKit
import SwiftUI
import Testing
import VeloEditCore
@testable import VeloEdit

@Suite(.serialized)
@MainActor
struct TimelineDragRegressionTests {
    @Test func libraryCommandsUseNativeTextInsteadOfAFilePromise() async throws {
        let payload = "title:title:" + Data("Новый маршрут 🚲".utf8).base64EncodedString()
        let provider = LibraryDragSession.provider(for: payload)
        #expect(LibraryDragSession.type == .utf8PlainText)
        #expect(provider.canLoadObject(ofClass: NSString.self))
        #expect(provider.registeredTypeIdentifiers == [LibraryDragSession.type.identifier])
        #expect(!provider.hasItemConformingToTypeIdentifier("public.file-url"))
        let loaded = await withCheckedContinuation { continuation in
            LibraryDragSession.load(provider) { continuation.resume(returning: $0) }
        }
        #expect(loaded == payload)
    }

    @Test func sameLibraryProviderCanBeDroppedRepeatedlyWithoutSourceGlobalState() async {
        let provider = LibraryDragSession.provider(for: "title:title:VGVzdA==")
        let session = LibraryTimelineDropSession()
        var drops: [String] = []
        for index in 0..<3 {
            await withCheckedContinuation { continuation in
                let accepted = session.perform(provider: provider, at: CGPoint(x: index * 10, y: 40)) { payload, point in
                    drops.append(payload)
                    #expect(point.x == CGFloat(index * 10))
                    continuation.resume()
                    return true
                }
                #expect(accepted)
            }
        }
        #expect(drops == Array(repeating: "title:title:VGVzdA==", count: 3))
    }

    @Test func cancelledPreviewCannotReplaceTheNextDragAndLatestPointerWins() async {
        var loads: [(String?) -> Void] = []
        let session = LibraryTimelineDropSession { _, completion in loads.append(completion) }
        let first = LibraryDragSession.provider(for: "first")
        let second = LibraryDragSession.provider(for: "second")
        var previews: [(String, CGPoint)] = []
        session.update(provider: first, at: .zero) { previews.append(($0, $1)) }
        session.reset()
        session.update(provider: second, at: CGPoint(x: 20, y: 30)) { previews.append(($0, $1)) }
        session.update(provider: second, at: CGPoint(x: 75, y: 50)) { previews.append(($0, $1)) }
        #expect(loads.count == 2)
        loads[1]("second")
        loads[0]("first")
        for _ in 0..<20 { await Task.yield() }
        #expect(previews.count == 1)
        #expect(previews.first?.0 == "second")
        #expect(previews.first?.1 == CGPoint(x: 75, y: 50))
        var dropped: String?
        #expect(session.perform(provider: second, at: CGPoint(x: 80, y: 50)) { payload, _ in
            dropped = payload
            return true
        })
        #expect(dropped == "second")
        #expect(loads.count == 2)
    }

    @Test func mouseUpBeforePayloadLoadsCommitsOnceAndDoesNotResurrectPreview() async {
        var loads: [(String?) -> Void] = []
        let session = LibraryTimelineDropSession { _, completion in loads.append(completion) }
        let provider = LibraryDragSession.provider(for: "title")
        var previews = 0
        var drops = 0
        session.update(provider: provider, at: .zero) { _, _ in previews += 1 }
        let accepted = session.perform(provider: provider, at: CGPoint(x: 120, y: 60)) { payload, point in
            #expect(payload == "title")
            #expect(point == CGPoint(x: 120, y: 60))
            drops += 1
            return true
        }
        #expect(accepted)
        loads[0]("title")
        loads[1]("title")
        for _ in 0..<20 { await Task.yield() }
        #expect(previews == 0)
        #expect(drops == 1)
    }

    @Test func dropCoordinatesIncludeCanvasPaddingAndBothScrollOffsets() {
        let initial = TimelineDropCoordinates(canvasOrigin: CGPoint(x: 16, y: 7))
        #expect(initial.canvasPoint(from: CGPoint(x: 116, y: 250)) == CGPoint(x: 100, y: 243))
        let scrolled = TimelineDropCoordinates(canvasOrigin: CGPoint(x: -484, y: -53))
        #expect(scrolled.canvasPoint(from: CGPoint(x: 116, y: 250)) == CGPoint(x: 600, y: 303))
    }

    @Test func actualScrollViewReportsTheCanvasOriginUsedByDrops() async throws {
        let suite = "VeloEdit.drop-scroll.\(UUID())"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let model = AppModel(defaults: UserDefaults(suiteName: suite)!, startBackgroundServices: false)
        let timeline = Timeline(storyPlanID: UUID(), items: [
            TimelineItem(kind: .video, sourceDuration: 100, timelineStart: 0, timelineDuration: 100)
        ])
        model.project = ProjectManifest(name: "Drop coordinates", timelines: [timeline])
        let host = NSHostingView(rootView: MagneticTimelineView(timeline: timeline, playbackClock: model.playbackClock)
            .environmentObject(model)
            .frame(width: 900, height: 400))
        host.frame = CGRect(x: 0, y: 0, width: 900, height: 400)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        func reader(in view: NSView) -> TimelineViewportReader.ObserverView? {
            if let reader = view as? TimelineViewportReader.ObserverView { return reader }
            return view.subviews.lazy.compactMap { reader(in: $0) }.first
        }
        let observer = try #require(reader(in: host))
        let initial = try #require(observer.canvasOrigin)
        #expect(abs(initial.x - 16) < 0.001)
        #expect(abs(initial.y - 7) < 0.001)
        func scrollView(in view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView { return scroll }
            return view.subviews.lazy.compactMap { scrollView(in: $0) }.first
        }
        let scroll = try #require(scrollView(in: host))
        scroll.contentView.scroll(to: CGPoint(x: 500, y: 0))
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        #expect(abs((observer.canvasOrigin?.x ?? 0) - (initial.x - 500)) < 0.001)
    }

    @Test func titleEdgesAlignWithClipsAndSpanAllInternalGapsAtEveryZoom() {
        let geometry = TimelineLayoutSnapshot(timeline: timeline()).geometry
        for scale in [6.0, 18.0, 64.0] {
            let frame = geometry.rangeFrame(start: 10, duration: 10, pointsPerSecond: scale, spacing: 8)
            #expect(abs(Double(frame.minX) - (10 * scale + 8)) < 0.000001)
            #expect(abs(Double(frame.maxX) - (20 * scale + 8)) < 0.000001)
            let spanning = geometry.rangeFrame(start: 5, duration: 20, pointsPerSecond: scale, spacing: 8)
            #expect(abs(Double(spanning.minX) - 5 * scale) < 0.000001)
            #expect(abs(Double(spanning.maxX) - (25 * scale + 16)) < 0.000001)
            #expect(abs(Double(spanning.width) - (20 * scale + 16)) < 0.000001)
            let short = geometry.rangeFrame(start: 1, duration: 0.1, pointsPerSecond: scale, spacing: 8)
            #expect(short.width <= max(1, scale * 0.1) + 0.000001)
        }
    }

    @Test func draggingAcrossSeveralCutsUsesTheSameGeometryAsLibraryPlacement() {
        let geometry = TimelineLayoutSnapshot(timeline: timeline()).geometry
        for scale in [6.0, 18.0, 64.0] {
            for start in [0.0, 5, 10, 22] {
                for end in [0.0, 5, 10, 20, 25] {
                    let fromX = geometry.xPosition(for: start, pointsPerSecond: scale, spacing: 8, edge: .leading)
                    let toX = geometry.xPosition(for: end, pointsPerSecond: scale, spacing: 8, edge: .leading)
                    let moved = geometry.movedTime(from: start, translation: toX - fromX, pointsPerSecond: scale, spacing: 8)
                    #expect(abs(moved - end) < 0.000001)
                }
            }
        }
    }

    @Test func titlesAndEffectsAreSnapTargetsForLibraryDrops() {
        var timeline = timeline()
        timeline.titleItems = [TitleTimelineItem(kind: .title, text: "Title", startTime: 3, duration: 4)]
        timeline.effects = [EffectTimelineItem(effectType: .blur, startTime: 12, duration: 2)]
        let geometry = TimelineLayoutSnapshot(timeline: timeline).geometry
        for boundary in [3.0, 7, 12, 14] {
            #expect(geometry.snapped(boundary + 0.1, threshold: 0.3, frameRate: 30, playhead: nil) == boundary)
        }
    }

    @Test func fractionalClipBoundarySurvivesPreviewInsertionAndMoving() throws {
        var timeline = timeline()
        let cut = 10.013
        timeline.items[0].timelineDuration = cut
        timeline.items[1].timelineStart = cut
        timeline.items[1].timelineDuration = 20 - cut
        let geometry = TimelineLayoutSnapshot(timeline: timeline).geometry
        let snapped = geometry.snapped(cut - 0.1, threshold: 0.3, frameRate: 30, playhead: nil)
        let previewTime = TimelineTiming.editingTime(snapped, in: timeline, maximum: timeline.duration - 0.05)
        #expect(previewTime == cut)
        let title = TitleTimelineItem(kind: .title, text: "At cut", startTime: previewTime, duration: 3)
        #expect(TimelineMutationEngine.insertTitle(in: &timeline, title: title))
        #expect(timeline.effectiveTitleItems.first?.startTime == cut)
        #expect(TimelineMutationEngine.updateTitle(in: &timeline, id: title.id) { $0.startTime = 1.0123 })
        #expect(timeline.effectiveTitleItems.first?.startTime == 1)
        #expect(TimelineMutationEngine.updateTitle(in: &timeline, id: title.id) { $0.startTime = snapped })
        let committed = try #require(timeline.effectiveTitleItems.first)
        #expect(committed.startTime == cut)
        let x = geometry.rangeFrame(start: committed.startTime, duration: committed.duration,
            pointsPerSecond: 64, spacing: 8).minX
        #expect(abs(Double(x) - (cut * 64 + 8)) < 0.000001)
    }

    private func timeline() -> Timeline {
        Timeline(storyPlanID: UUID(), items: (0..<3).map {
            TimelineItem(kind: .video, sourceDuration: 10, timelineStart: Double($0) * 10, timelineDuration: 10)
        })
    }
}
