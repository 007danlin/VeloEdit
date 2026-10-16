import AppKit
import SwiftUI
import Testing
import VeloEditCore
@testable import VeloEdit

@Suite(.serialized)
@MainActor
struct TimelineMarqueeSelectionTests {
    @Test func partialIntersectionWorksInEveryDragDirection() {
        let key = TimelineSelectionKey.item(UUID())
        let region = TimelineSelectionRegion(frame: CGRect(x: 20, y: 20, width: 80, height: 60), keys: [key])
        for (start, end) in [
            (CGPoint(x: 0, y: 0), CGPoint(x: 21, y: 21)),
            (CGPoint(x: 120, y: 0), CGPoint(x: 99, y: 21)),
            (CGPoint(x: 0, y: 100), CGPoint(x: 21, y: 79)),
            (CGPoint(x: 120, y: 100), CGPoint(x: 99, y: 79))
        ] {
            var session = TimelineMarqueeSession(anchor: start, baseline: [], regions: [region])
            #expect(session.update(to: end) == [key])
        }
    }

    @Test func shrinkingShiftMarqueePreservesOnlyTheOriginalSelection() {
        let original = TimelineSelectionKey.audio(UUID())
        let first = TimelineSelectionKey.item(UUID())
        let second = TimelineSelectionKey.title(UUID())
        var session = TimelineMarqueeSession(anchor: .zero, baseline: [original], regions: [
            .init(frame: CGRect(x: 20, y: 20, width: 30, height: 30), keys: [first]),
            .init(frame: CGRect(x: 80, y: 20, width: 30, height: 30), keys: [second])
        ])
        #expect(session.update(to: CGPoint(x: 100, y: 40)) == [original, first, second])
        #expect(session.update(to: CGPoint(x: 60, y: 40)) == [original, first])
        #expect(session.update(to: CGPoint(x: 10, y: 10)) == [original])
    }

    @Test func nativeDragUpdatesImmediatelyAndReleaseKeepsSelectionWithoutSeeking() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let view = fixture.interaction
        let model = fixture.model
        let key = TimelineSelectionKey.item(fixture.timeline.items[1].id)
        let frame = try #require(view.regions.first { $0.keys == [key] }?.frame)
        model.selectTimelineItem(fixture.timeline.items[0].id)
        model.seekTimeline(to: 7)
        let start = CGPoint(x: frame.minX + 20, y: frame.maxY + 3)
        let end = CGPoint(x: frame.minX + 25, y: frame.maxY - 1)
        #expect(try fixture.send(.leftMouseDown, at: start))
        #expect(!model.hasTimelineSelection)
        #expect(try fixture.send(.leftMouseDragged, at: end))
        #expect(model.currentTimelineSelection == [key])
        #expect(view.session?.rectangle != nil)
        #expect(try fixture.send(.leftMouseUp, at: end))
        #expect(model.currentTimelineSelection == [key])
        #expect(view.session == nil)
        #expect(model.timelinePlayheadTime == 7)
        #expect(model.timeline == fixture.timeline)
    }

    @Test func shiftIsCapturedAtMouseDownAndEmptyClickClearsAllKinds() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let original = TimelineSelectionKey.title(fixture.timeline.effectiveTitleItems[0].id)
        let key = TimelineSelectionKey.item(fixture.timeline.items[0].id)
        fixture.model.setTimelineMarqueeSelection([original])
        let frame = try #require(fixture.interaction.regions.first { $0.keys == [key] }?.frame)
        let start = CGPoint(x: 30, y: frame.maxY + 3)
        let end = CGPoint(x: 40, y: frame.maxY - 2)
        #expect(try fixture.send(.leftMouseDown, at: start, modifiers: .shift))
        #expect(try fixture.send(.leftMouseDragged, at: end)) // Shift released mid-drag.
        #expect(try fixture.send(.leftMouseUp, at: end))
        #expect(fixture.model.currentTimelineSelection == [original, key])
        // The unused viewport after/below a short timeline is selectable too.
        let empty = CGPoint(x: 780, y: 400)
        #expect(try fixture.send(.leftMouseDown, at: empty, modifiers: .shift))
        #expect(try fixture.send(.leftMouseUp, at: CGPoint(x: 781, y: 400), modifiers: .shift))
        #expect(!fixture.model.hasTimelineSelection)
        #expect(fixture.interaction.session == nil)
    }

    @Test func objectsEdgesTransitionMenusAndRulerKeepTheirMouseSequences() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        for region in fixture.interaction.regions {
            for x in [region.frame.minX + 0.1, region.frame.midX, region.frame.maxX - 0.1] {
                let point = CGPoint(x: x, y: region.frame.midY)
                #expect(try !fixture.send(.leftMouseDown, at: point))
                #expect(try !fixture.send(.leftMouseDragged, at: CGPoint(x: x + 40, y: point.y)))
                #expect(try !fixture.send(.leftMouseUp, at: point))
            }
        }
        #expect(try !fixture.send(.leftMouseDown, at: CGPoint(x: 50, y: 5)))
        #expect(try !fixture.send(.leftMouseDragged, at: CGPoint(x: 200, y: 5)))
        #expect(try !fixture.send(.leftMouseUp, at: CGPoint(x: 200, y: 5)))
        #expect(try !fixture.send(.leftMouseDown, at: CGPoint(x: 700, y: 400), modifiers: .control))
        #expect(try !fixture.send(.rightMouseDown, at: CGPoint(x: 700, y: 400)))
        #expect(try !fixture.send(.leftMouseDown, at: CGPoint(x: 40, y: -50))) // Toolbar.
        fixture.interaction.isEnabled = false // Brush or blocked editing.
        #expect(try !fixture.send(.leftMouseDown, at: CGPoint(x: 700, y: 400)))
        #expect(fixture.interaction.hitTest(CGPoint(x: 700, y: 400)) == nil)
    }

    @Test func allObjectKindsAndGroupedEffectsUseRealCanvasFrames() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let view = fixture.interaction
        let timeline = fixture.timeline
        var expected = Set(timeline.items.map { TimelineSelectionKey.item($0.id) })
        expected.formUnion(timeline.effectiveTitleItems.map { .title($0.id) })
        expected.formUnion(timeline.effectiveEffects.map { .effect($0.id) })
        expected.formUnion(timeline.effectiveAudioClips.map { .audio($0.id) })
        expected.formUnion(timeline.effectiveTelemetryItems.map { .telemetry($0.id) })
        expected.formUnion(timeline.effectiveTransitionItems.map { .transition($0.id) })
        expected.insert(.soundtrack)
        #expect(view.regions.reduce(into: Set<TimelineSelectionKey>()) { $0.formUnion($1.keys) } == expected)
        let effectRegion = try #require(view.regions.first { $0.keys.contains(.effect(timeline.effectiveEffects[0].id)) })
        #expect(effectRegion.keys.count == 2)
        let first = try #require(view.regions.first { $0.keys == [.item(timeline.items[0].id)] })
        let second = try #require(view.regions.first { $0.keys == [.item(timeline.items[1].id)] })
        #expect(first.frame.minY == 122) // Two title lanes and one connected lane.
        #expect(second.frame.minX - first.frame.maxX == 8)
        #expect(try fixture.send(.leftMouseDown, at: CGPoint(x: 700, y: 400)))
        #expect(try fixture.send(.leftMouseDragged, at: CGPoint(x: 0, y: 15)))
        #expect(fixture.model.currentTimelineSelection == expected)
        if let path = ProcessInfo.processInfo.environment["VELOEDIT_MARQUEE_QA_PATH"] {
            try await Task.sleep(for: .milliseconds(50))
            fixture.host.layoutSubtreeIfNeeded()
            let bitmap = try #require(fixture.host.bitmapImageRepForCachingDisplay(in: fixture.host.bounds))
            fixture.host.cacheDisplay(in: fixture.host.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
        }
        #expect(try fixture.send(.leftMouseUp, at: CGPoint(x: 0, y: 15)))
        #expect(fixture.model.currentTimelineSelection == expected)
    }

    @Test func scrolledCanvasUsesBothOffsetsAndIncludesVirtualizedObjects() async throws {
        var timeline = Self.makeTimeline()
        timeline.items += (3..<100).map {
            TimelineItem(kind: .video, sourceDuration: 10, timelineStart: Double($0) * 10, timelineDuration: 10)
        }
        timeline.titleItems = (0..<12).map {
            TitleTimelineItem(kind: .title, text: "Stack \($0)", startTime: 0, duration: 5)
        }
        let fixture = try await Fixture(timeline: timeline)
        defer { fixture.remove() }
        let scroll = try #require(fixture.interaction.enclosingScrollView)
        scroll.contentView.scroll(to: CGPoint(x: 500, y: 120))
        fixture.host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        let key = TimelineSelectionKey.item(timeline.items[4].id)
        let frame = try #require(fixture.interaction.regions.first { $0.keys == [key] }?.frame)
        let start = CGPoint(x: frame.midX, y: frame.maxY + 3)
        #expect(try fixture.send(.leftMouseDown, at: start))
        let end = CGPoint(x: frame.midX + 10, y: frame.maxY - 2)
        #expect(try fixture.send(.leftMouseDragged, at: end))
        #expect(fixture.model.currentTimelineSelection == [key])
        #expect(try fixture.send(.leftMouseUp, at: end))
        #expect(fixture.interaction.regions.contains { $0.keys == [.item(timeline.items.last!.id)] })
    }

    @Test func marqueeSelectionWorksWithMixedClipboardDeleteAndUndo() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let model = fixture.model
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Marquee-edit-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ProjectStore(createAt: root.appendingPathComponent("test.veloedit"), name: "Marquee")
        let timeline = fixture.timeline
        try await store.update { $0.timelines = [timeline] }
        model.pipeline = VeloEditPipeline(store: store)
        model.project = await store.manifest
        let keys: Set<TimelineSelectionKey> = [.item(timeline.items[1].id),
            .title(timeline.effectiveTitleItems[0].id), .audio(timeline.effectiveAudioClips[0].id)]
        model.setTimelineMarqueeSelection(keys)
        model.copyTimelineSelection()
        #expect(model.canPasteTimelineElements)
        model.deleteTimelineSelection()
        #expect(model.timeline?.items.contains { $0.id == timeline.items[1].id } == false)
        #expect(model.timeline?.effectiveTitleItems.contains { $0.id == timeline.effectiveTitleItems[0].id } == false)
        #expect(model.timeline?.effectiveAudioClips.isEmpty == true)
        #expect(!model.hasTimelineSelection)
        model.undoTimelineEdit()
        #expect(model.timeline == timeline)
        model.pasteTimelineSelection(at: 0)
        #expect(model.selectedTimelineItemIDs.count == 1)
        #expect(model.selectedTitleTimelineItemIDs.count == 1)
        #expect(model.selectedTimelineAudioClipIDs.count == 1)
        #expect(model.timeline?.items.count == timeline.items.count + 1)
        #expect(await model.flushAutosave())
    }

    private nonisolated static func makeTimeline() -> Timeline {
        var items = (0..<3).map {
            TimelineItem(kind: .video, sourceDuration: 10, timelineStart: Double($0) * 10, timelineDuration: 10)
        }
        items[1].transition = TransitionStyle.crossDissolve.rawValue
        var connected = TimelineItem(kind: .video, sourceDuration: 4, timelineStart: 2, timelineDuration: 4)
        connected.overlay = OverlaySettings(style: .pictureInPicture, baseItemID: items[0].id, startOffset: 2)
        items.append(connected)
        let groupID = UUID()
        var effects = [EffectTimelineItem(effectType: .blur, startTime: 1, duration: 4),
                       EffectTimelineItem(effectType: .zoom, startTime: 1, duration: 4)]
        for index in effects.indices { effects[index].effectStackPresetInstanceID = groupID }
        return Timeline(storyPlanID: UUID(), items: items,
            audioClips: [TimelineAudioClip(title: "Audio", role: .detached, sourceDuration: 5, timelineStart: 2, timelineDuration: 5)],
            telemetryItems: [TimelineTelemetryItem(targetClipID: items[0].id, timelineStart: 1, timelineDuration: 4)],
            effects: effects,
            titleItems: [TitleTimelineItem(kind: .title, text: "A", startTime: 1, duration: 4),
                         TitleTimelineItem(kind: .title, text: "B", startTime: 2, duration: 4)],
            transitionItems: [TimelineTransitionItem(style: .crossDissolve, outgoingClipID: items[0].id,
                incomingClipID: items[1].id, startTime: 10)],
            music: MusicDirective(style: .calm, bpm: 80))
    }

    @MainActor
    private struct Fixture {
        let suite: String
        let model: AppModel
        let timeline: Timeline
        let host: NSView
        let window: NSWindow
        let interaction: TimelineMarqueeSelection.InteractionView

        init(timeline: Timeline = TimelineMarqueeSelectionTests.makeTimeline()) async throws {
            suite = "VeloEdit.marquee.\(UUID())"
            model = AppModel(defaults: UserDefaults(suiteName: suite)!, startBackgroundServices: false)
            self.timeline = timeline
            model.project = ProjectManifest(name: "Marquee", timelines: [timeline])
            let hosting = NSHostingView(rootView: MagneticTimelineView(timeline: timeline, playbackClock: model.playbackClock)
                .environmentObject(model).frame(width: 900, height: 600))
            hosting.frame = CGRect(x: 0, y: 0, width: 900, height: 600)
            host = hosting
            window = NSWindow(contentRect: hosting.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.contentView = hosting
            hosting.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(50))
            func find(in view: NSView) -> TimelineMarqueeSelection.InteractionView? {
                if let interaction = view as? TimelineMarqueeSelection.InteractionView { return interaction }
                return view.subviews.lazy.compactMap { find(in: $0) }.first
            }
            interaction = try #require(find(in: hosting))
        }

        func send(_ type: NSEvent.EventType, at point: CGPoint, modifiers: NSEvent.ModifierFlags = []) throws -> Bool {
            let event = try #require(NSEvent.mouseEvent(with: type, location: interaction.convert(point, to: nil),
                modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            return interaction.handle(event)
        }

        func remove() {
            interaction.detach()
            window.contentView = nil
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        }
    }
}
