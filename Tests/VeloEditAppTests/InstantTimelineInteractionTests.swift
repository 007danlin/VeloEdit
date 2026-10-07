import Foundation
import AVFoundation
import Testing
import VeloEditCore
@testable import VeloEdit

@Suite(.serialized)
@MainActor
struct InstantTimelineInteractionTests {
    @Test func droppingTransitionUsesHoveredCutInsteadOfOldSelection() async throws {
        let fixture = try await Fixture(clipCount: 3)
        defer { fixture.remove() }
        let items = try #require(fixture.model.timeline?.items)
        fixture.model.selectTimelineItem(items[1].id)
        fixture.model.addTimelineTransition(.crossDissolve, at: 20)
        let transition = try #require(fixture.model.timeline?.effectiveTransitionItems.first)
        #expect(transition.incomingClipID == items[2].id)
        #expect(transition.outgoingClipID == items[1].id)
        fixture.model.undoTimelineEdit()
        #expect(fixture.model.timeline?.effectiveTransitionItems.isEmpty == true)
        #expect(await fixture.model.flushAutosave())
    }

    @Test func leadingTrimCutsSourceThenClosesMagneticGapAndSupportsUndo() async throws {
        let fixture = try await Fixture(clipCount: 3)
        defer { fixture.remove() }
        let model = fixture.model
        model.project?.timelines[0].items[1].sourceStart = 5
        model.project?.timelines[0].items[1].sourceDuration = 20
        model.project?.timelines[0].items[1].speed = 2
        let original = try #require(model.timeline)
        let item = original.items[1]
        let preview = TimelineTrimRange(start: item.timelineStart, duration: item.timelineDuration)
            .trimming(.leading, by: 2, minimumDuration: 0.25)
        // While dragging, the preview moves right but the saved sequence stays put.
        #expect(preview.start == 12)
        #expect(preview.end == 20)
        #expect(model.timeline == original)
        model.trimTimelineItem(id: item.id, sourceStart: 9, timelineDuration: preview.duration)
        let trimmed = try #require(model.timeline?.items[1])
        #expect(trimmed.timelineStart == 10)
        #expect(trimmed.timelineDuration == 8)
        #expect(trimmed.sourceStart == 9)
        #expect(trimmed.sourceStart + trimmed.sourceDuration == 25)
        #expect(model.timeline?.items[2].timelineStart == 18)
        let committed = model.timeline
        model.undoTimelineEdit()
        #expect(model.timeline == original)
        model.redoTimelineEdit()
        #expect(model.timeline == committed)
        #expect(await model.flushAutosave())
        let reopened = try ProjectStore(open: fixture.url)
        #expect(await reopened.manifest.timelines.last == committed)
    }

    @Test func leadingTrimOfConnectedVideoAndFastAudioKeepsTheirRightEnds() async throws {
        let fixture = try await Fixture(clipCount: 2)
        defer { fixture.remove() }
        let model = fixture.model
        let base = try #require(model.timeline?.items.first)
        var connected = TimelineItem(kind: .video, sourceStart: 5, sourceDuration: 6,
            timelineStart: 3, timelineDuration: 6)
        connected.overlay = OverlaySettings(style: .pictureInPicture, baseItemID: base.id, startOffset: 3)
        model.project?.timelines[0].items.append(connected)
        let audio = TimelineAudioClip(title: "Fast audio", role: .detached,
            sourceStart: 3, sourceDuration: 20, timelineStart: 4, timelineDuration: 10, speed: 2)
        model.project?.timelines[0].audioClips = [audio]
        model.trimTimelineItem(id: connected.id, sourceStart: 7, timelineDuration: 4, timelineStart: 5)
        let video = try #require(model.timeline?.items.first { $0.id == connected.id })
        #expect(video.timelineStart == 5)
        #expect(video.timelineStart + video.timelineDuration == 9)
        #expect(video.sourceStart + video.sourceDuration == 11)
        #expect(video.overlay?.effectiveStartOffset == 5)
        model.trimTimelineAudioClip(audio.id, timelineStart: 6, sourceStart: 7, duration: 8)
        let trimmedAudio = try #require(model.timeline?.effectiveAudioClips.first)
        #expect(trimmedAudio.timelineStart + trimmedAudio.timelineDuration == 14)
        #expect(trimmedAudio.sourceStart + trimmedAudio.sourceDuration == 23)
        #expect(trimmedAudio.effectiveSpeed == 2)
        #expect(await model.flushAutosave())
    }

    @Test func copiedEffectsAppearImmediatelyAsIndependentObjects() async throws {
        let fixture = try await Fixture(clipCount: 1)
        defer { fixture.remove() }
        let model = fixture.model
        var effect = EffectTimelineItem(effectType: .blur, startTime: 1, duration: 2)
        effect.effectStackPresetID = "fixture-preset"
        effect.effectStackPresetInstanceID = UUID()
        model.project?.timelines[0].effects = [effect]
        model.selectEffectTimelineItem(effect.id)
        model.copySelectedEffectTimelineItem()
        model.duplicateSelectedEffectTimelineItem()
        let duplicate = try #require(model.selectedEffectTimelineItem)
        #expect(duplicate.id != effect.id)
        #expect(duplicate.effectStackPresetID == nil)
        #expect(duplicate.effectStackPresetInstanceID == nil)
        #expect(duplicate.startTime > effect.startTime)
        model.pasteEffectTimelineItem(at: 5)
        let pasted = try #require(model.selectedEffectTimelineItem)
        #expect(pasted.id != duplicate.id)
        #expect(pasted.effectStackPresetID == nil)
        #expect(pasted.effectStackPresetInstanceID == nil)
        #expect(pasted.startTime == 5)
        #expect(model.timeline?.effectiveEffects.count == 3)
        #expect(!model.isWorking)
        #expect(await model.flushAutosave())
    }

    @Test func deleteCutPasteDuplicateAndUndoApplyBeforeReturningAndPersist() async throws {
        let fixture = try await Fixture(clipCount: 120)
        defer { fixture.remove() }
        let model = fixture.model
        let original = try #require(model.timeline)
        let first = original.items[0]
        model.selectTimelineItem(first.id)
        let started = ProcessInfo.processInfo.systemUptime
        model.deleteTimelineSelection()
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        #expect(elapsed < 0.1)
        #expect(model.timeline?.items.count == 119)
        #expect(model.timeline?.items.contains { $0.id == first.id } == false)
        #expect(model.timeline?.items.first?.timelineStart == 0)
        #expect(!model.isWorking)
        #expect(!model.hasTimelineSelection)
        #expect(model.canUndoTimelineEdit)
        model.undoTimelineEdit()
        #expect(model.timeline == original)
        model.redoTimelineEdit()
        #expect(model.timeline?.items.count == 119)

        model.selectTimelineItem(original.items[1].id)
        model.cutTimelineSelection()
        #expect(model.timeline?.items.count == 118)
        model.pasteTimelineSelection(at: 0)
        #expect(model.timeline?.items.count == 119)
        let pastedID = try #require(model.selectedTimelineItemID)
        #expect(pastedID != original.items[1].id)
        model.duplicateTimelineSelection()
        #expect(model.timeline?.items.count == 120)
        #expect(model.selectedTimelineItemID != pastedID)
        #expect(!model.isWorking)
        let expected = model.timeline
        #expect(await model.flushAutosave())
        let reopened = try ProjectStore(open: fixture.url)
        #expect(await reopened.manifest.timelines.last == expected)
        print("PERF instant-delete clips=120 state_ms=\(elapsed * 1000)")
    }

    @Test func rapidDeletesAndRefreshNeverResurrectClips() async throws {
        let fixture = try await Fixture(clipCount: 32)
        defer { fixture.remove() }
        let model = fixture.model
        let original = try #require(model.timeline)
        for item in original.items.prefix(24) {
            model.selectTimelineItem(item.id)
            model.deleteTimelineSelection()
            #expect(model.timeline?.items.contains { $0.id == item.id } == false)
        }
        let expected = model.timeline
        // This refresh races the coalesced save's 25 ms delay.
        await model.refresh()
        #expect(model.timeline == expected)
        #expect(await model.flushAutosave())
        let reopened = try ProjectStore(open: fixture.url)
        #expect(await reopened.manifest.timelines.last == expected)
        #expect(model.timeline?.items.count == 8)
    }

    @Test func deletingLastClipClearsAttachedObjectsAndPreviewImmediately() async throws {
        let fixture = try await Fixture(clipCount: 1)
        defer { fixture.remove() }
        let model = fixture.model
        let item = try #require(model.timeline?.items.first)
        var original = try #require(model.timeline)
        original.telemetryItems = [TimelineTelemetryItem(targetClipID: item.id, timelineStart: 0, timelineDuration: 10)]
        original.audioClips = [TimelineAudioClip(assetID: item.assetID, title: "Attached", role: .detached,
            sourceDuration: 10, timelineStart: 0, timelineDuration: 10, attachedToItemID: item.id)]
        model.project?.timelines = [original]
        model.previewPlayer = AVPlayer()
        model.seekTimeline(to: 8)
        model.selectTimelineItem(item.id)
        model.deleteTimelineSelection()
        #expect(model.timeline?.items.isEmpty == true)
        #expect(model.timeline?.effectiveTelemetryItems.isEmpty == true)
        #expect(model.timeline?.effectiveAudioClips.isEmpty == true)
        #expect(model.previewPlayer == nil)
        #expect(model.timelinePlayheadTime == 0)
        model.undoTimelineEdit()
        #expect(model.timeline == original)
        #expect(await model.flushAutosave())
    }

    @Test func splitThenDeleteAndInspectorChangesUseTheVisibleTimeline() async throws {
        let fixture = try await Fixture(clipCount: 2)
        defer { fixture.remove() }
        let model = fixture.model
        let original = try #require(model.timeline)
        let first = original.items[0]
        model.selectTimelineItem(first.id)
        model.seekTimeline(to: 4)
        model.splitSelectedTimelineItem()
        #expect(model.timeline?.items.count == 3)
        #expect(model.selectedTimelineItem?.sourceStart == 4)
        #expect(model.selectedTimelineItem?.timelineDuration == 6)
        model.deleteTimelineSelection()
        #expect(model.timeline?.items.count == 2)
        #expect(model.timeline?.items.first?.timelineDuration == 4)
        model.selectTimelineItem(first.id)
        model.setSelectedCropMode("fit")
        #expect(model.selectedTimelineItem?.effectiveVideoAdjustments.crop == .fit)
        model.rotateSelected(1)
        #expect(model.selectedTimelineItem?.effectiveVideoAdjustments.rotationQuarterTurns == 1)
        model.setSelectedSpeedRamp("action")
        #expect(model.selectedTimelineItem?.speedRamp == .action)
        model.resetSelectedSpeed()
        #expect(model.selectedTimelineItem?.speedRamp == nil)
        model.selectTimelineItem(original.items[1].id)
        model.setSelectedTransition(TransitionStyle.crossDissolve.rawValue)
        let transition = try #require(model.timeline?.effectiveTransitionItems.first)
        model.selectTransitionTimelineItem(transition.id)
        model.setSelectedTransitionDuration(0.8)
        #expect(model.selectedTransitionTimelineItem?.duration == 0.8)
        model.setSelectedTransitionStyle(.cut)
        #expect(model.timeline?.effectiveTransitionItems.isEmpty == true)
        #expect(!model.isWorking)
        let expected = model.timeline
        #expect(await model.flushAutosave())
        let reopened = try ProjectStore(open: fixture.url)
        #expect(await reopened.manifest.timelines.last == expected)
    }

    @Test func splitSpedUpAudioPreservesTheSourceWindowAndUndo() async throws {
        let fixture = try await Fixture(clipCount: 1)
        defer { fixture.remove() }
        let model = fixture.model
        let audio = TimelineAudioClip(title: "Fast audio", role: .detached, sourceStart: 3,
            sourceDuration: 20, timelineStart: 0, timelineDuration: 10, speed: 2)
        model.project?.timelines[0].audioClips = [audio]
        let original = model.timeline
        model.selectTimelineAudioClip(audio.id)
        model.seekTimeline(to: 4)
        model.splitSelectedTimelineItem()
        let clips = try #require(model.timeline?.effectiveAudioClips)
        #expect(clips.count == 2)
        #expect(clips[0].sourceDuration == 8)
        #expect(clips[1].sourceStart == 11)
        #expect(clips[1].sourceDuration == 12)
        #expect(clips.allSatisfy { $0.effectiveSpeed == 2 })
        model.undoTimelineEdit()
        #expect(model.timeline == original)
        #expect(await model.flushAutosave())
    }

    @Test func queuedSelectionIsNotSilentlyRetargetedAfterClipRemoval() async throws {
        let fixture = try await Fixture(clipCount: 2)
        defer { fixture.remove() }
        let model = fixture.model
        let original = try #require(model.timeline)
        model.selectTimelineItem(original.items[0].id)
        model.isWorking = true
        model.submitTimelineAIEdit("убери звук выделенного клипа")
        #expect(model.queuedTimelineAIEditCount == 1)
        model.project?.timelines[0].items.removeFirst()
        model.selectTimelineItem(original.items[1].id)
        model.isWorking = false
        model.submitTimelineAIEdit("громкость музыки 20%")
        // The first queued command is rejected immediately against its captured
        // ID; the newly selected clip is not used as a substitute.
        #expect(model.status.contains("клип удалён"))
        #expect(model.timeline?.items.first?.effectiveAudioAdjustments.muted == false)
        #expect(model.queuedTimelineAIEditCount == 1)
        let deadline = Date().addingTimeInterval(8)
        while model.queuedTimelineAIEditCount > 0 || model.isWorking {
            guard Date() < deadline else { Issue.record("Queue did not drain"); break }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private struct Fixture {
        let root: URL
        let url: URL
        let suite: String
        let model: AppModel

        @MainActor init(clipCount: Int) async throws {
            suite = "VeloEdit.instant-timeline.\(UUID().uuidString)"
            root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
            url = root.appendingPathComponent("test.veloedit")
            let store = try ProjectStore(createAt: url, name: "Instant timeline")
            let items = (0..<clipCount).map { index in
                TimelineItem(assetID: UUID(), kind: .video, sourceDuration: 10,
                    timelineStart: Double(index) * 10, timelineDuration: 10)
            }
            try await store.update { $0.timelines = [Timeline(storyPlanID: UUID(), items: items, originalAudioVolume: 0)] }
            model = AppModel(defaults: UserDefaults(suiteName: suite)!, startBackgroundServices: false,
                personalTasteStore: LocalPersonalTasteStore(url: root.appendingPathComponent("taste.json")))
            let openedStore = try ProjectStore(open: url)
            model.pipeline = VeloEditPipeline(store: openedStore)
            model.projectURL = url
            model.project = await openedStore.manifest
        }

        func remove() {
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
    }
}
