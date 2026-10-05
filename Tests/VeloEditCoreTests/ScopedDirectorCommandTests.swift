import Foundation
import Testing
@testable import VeloEditCore

struct ScopedDirectorCommandTests {
    private func edit(_ commands: [EditorCommand], timeline: Timeline, range: ClosedRange<Double>) async throws -> (Timeline, EditorCommandReport) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("scoped-commands-\(UUID()).veloedit")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ProjectStore(createAt: root, name: "Scoped commands")
        try await store.update { $0.timelines = [timeline] }
        let report = try await VeloEditPipeline(store: store).applyEditorCommands(commands, timelineRange: range)
        return (try #require(await store.manifest.timelines.last), report)
    }

    private func timeline() -> Timeline {
        Timeline(storyPlanID: UUID(), items: [TimelineItem(kind: .video, sourceDuration: 8, timelineStart: 0, timelineDuration: 8)])
    }

    @Test func titleCreationStylingAndRenamingExecuteInOrderWithinBrush() async throws {
        let (result, report) = try await edit([
            .addTitle("В пути", .beginning), .setTitleStyle(80, "#FF0000", nil, .left, .first),
            .setTitleText("Наша поездка", .first), .setEffect(.pushIn, .all)
        ], timeline: timeline(), range: 2...6)
        #expect(report.hasChanges)
        #expect(report.ignored.isEmpty)
        let title = try #require(result.effectiveTitleItems.first)
        #expect(title.text == "Наша поездка")
        #expect(title.startTime >= 2 && title.endTime <= 6)
        #expect(title.style.fontSize == 80 && title.style.textColorHex == "#FF0000")
        #expect(title.style.alignment == .left && title.userEdited == true)
        #expect(result.items.map(\.effect) == [nil, ClipEffect.pushIn.rawValue, nil])
    }

    @Test func splitThenSpeedAndEffectsReachBothHalvesAndKeepAudioSourceClock() async throws {
        var source = timeline()
        let owner = source.items[0].id
        source.audioClips = [TimelineAudioClip(title: "Audio", role: .naturalSound, sourceDuration: 16,
            timelineStart: 0, timelineDuration: 8, speed: 2, attachedToItemID: owner)]
        source.titleItems = [TitleTimelineItem(kind: .title, text: "Scene", startTime: 0, duration: 8, targetClipID: owner)]
        let (result, report) = try await edit([.split(.all), .setSpeed(2, .all), .setFilter(.monochrome, .all), .setClipVolume(0.2, .all)],
            timeline: source, range: 2...6)
        #expect(report.ignored.isEmpty)
        #expect(result.items.map(\.timelineDuration) == [2, 1, 1, 2])
        #expect(result.items.map(\.sourceStart) == [0, 2, 4, 6])
        #expect(result.items.map { $0.effectiveVideoAdjustments.filter } == [.none, .monochrome, .monochrome, .none])
        #expect(result.effectiveAudioClips.map(\.sourceStart) == [0, 4, 8, 12])
        #expect(result.effectiveAudioClips.map(\.timelineDuration) == [2, 1, 1, 2])
        #expect(result.effectiveAudioClips.map(\.effectiveSpeed) == [2, 4, 4, 2])
        #expect(result.effectiveTitleItems.map(\.duration) == [2, 1, 1, 2])
        for (clip, title) in zip(result.items, result.effectiveTitleItems) {
            #expect(clip.id == title.targetClipID)
            #expect(clip.timelineStart == title.startTime)
        }
    }

    @Test func localAudioRestoreDoesNotUnmuteRestOfFilm() async throws {
        var source = timeline(); source.originalAudioVolume = 0
        let (result, report) = try await edit([.setOriginalAudioVolume(0.4)], timeline: source, range: 2...6)
        #expect(report.hasChanges && report.ignored.isEmpty)
        #expect(result.items.map { result.effectiveOriginalAudioVolume * $0.effectiveAudioAdjustments.effectiveVolume } == [0, 0.4, 0])
    }

    @Test(arguments: [false, true]) func globalSplitPreservesMediaClockAndAttachedLayers(_ reverse: Bool) throws {
        var source = timeline()
        source.items[0].reversePlayback = reverse
        source.items[0].speedRamp = .action
        source.items[0].timelineDuration = SpeedRamp.action.outputDuration(sourceDuration: 8)
        let original = source.items[0]
        source.titleItems = [TitleTimelineItem(kind: .title, text: "Scene", startTime: 0,
            duration: original.timelineDuration, targetClipID: original.id)]
        let result = EditorCommandExecutor().apply([.split(.first)], to: source)
        #expect(result.report.hasChanges && result.report.ignored.isEmpty)
        #expect(result.timeline.items.count == 2)
        #expect(result.timeline.effectiveTitleItems.count == 2)
        for item in result.timeline.items {
            for fraction in [0.1, 0.5, 0.9] {
                let time = item.timelineStart + item.timelineDuration * fraction
                #expect(abs(item.sourceTime(atTimelineTime: time) - original.sourceTime(atTimelineTime: time)) < 0.01)
            }
            let title = try #require(result.timeline.effectiveTitleItems.first { $0.targetClipID == item.id })
            #expect(title.startTime == item.timelineStart)
            #expect(abs(title.duration - item.timelineDuration) < 0.001)
        }
    }

    @Test func localMoveKeepsOutsideClipsAndAttachedTitles() async throws {
        let clips = (0..<4).map { TimelineItem(kind: .video, sourceStart: Double($0) * 2, sourceDuration: 2, timelineStart: Double($0) * 2, timelineDuration: 2) }
        let titles = clips.map { TitleTimelineItem(kind: .title, text: "\($0.sourceStart)", startTime: $0.timelineStart, duration: 2, targetClipID: $0.id) }
        let source = Timeline(storyPlanID: UUID(), items: clips, titleItems: titles)
        let (result, report) = try await edit([.move(.last, .beginning), .setFilter(.noir, .first)], timeline: source, range: 0...6)
        #expect(report.ignored.isEmpty)
        #expect(result.items.map(\.id) == [clips[2].id, clips[0].id, clips[1].id, clips[3].id])
        #expect(result.items[0].effectiveVideoAdjustments.filter == .noir)
        #expect(result.items[3] == clips[3])
        for title in result.effectiveTitleItems {
            #expect(title.startTime == result.items.first { $0.id == title.targetClipID }?.timelineStart)
            #expect(title.duration == 2)
        }
    }

    @Test func overlayUsesOnlyClipsInsideSelection() async throws {
        let clips = (0..<4).map { TimelineItem(kind: .video, sourceStart: Double($0) * 2, sourceDuration: 2, timelineStart: Double($0) * 2, timelineDuration: 2) }
        let (result, report) = try await edit([.setOverlay(.pictureInPicture, .last, .first)],
            timeline: Timeline(storyPlanID: UUID(), items: clips), range: 2...6)
        #expect(report.hasChanges && report.ignored.isEmpty)
        #expect(result.items.first { $0.id == clips[2].id }?.overlay?.baseItemID == clips[1].id)
        #expect(result.items[0] == clips[0])
        #expect(result.items.last?.sourceStart == clips[3].sourceStart)
    }

    @Test func musicGainMuteAndDuckingPreserveOutsideRegionsAndRoundTrip() throws {
        var source = timeline()
        source.music = MusicDirective(style: .calm, bpm: 68, volume: 0.4, trackID: UUID())
        var result = try #require(LocalizedSoundtrackEditing.apply(.setMusicVolume(0.1), to: source, range: 2...6))
        result = try #require(LocalizedSoundtrackEditing.apply(.setAudioDucking(true), to: result, range: 2...6))
        #expect(result.effectiveAdaptiveSoundtrack?.segments.map(\.directive.volume) == [0.4, 0.1, 0.4])
        #expect(result.effectiveAdaptiveSoundtrack?.segments.map(\.duckingEnabled) == [nil, true, nil])
        let decoded = try JSONDecoder().decode(Timeline.self, from: JSONEncoder().encode(result))
        #expect(decoded.effectiveAdaptiveSoundtrack == result.effectiveAdaptiveSoundtrack)
        result = try #require(LocalizedSoundtrackEditing.apply(.setMusic(nil), to: result, range: 2...6))
        #expect(result.effectiveAdaptiveSoundtrack?.segments.map(\.directive.volume) == [0.4, 0, 0.4])
        #expect(result.effectiveAdaptiveSoundtrack?.segments.map(\.sourceStart) == [0, 2, 6])
        let global = EditorCommandExecutor().apply([.setMusicVolume(0.3), .setAudioDucking(false)], to: result).timeline
        #expect(global.effectiveAdaptiveSoundtrack?.segments.allSatisfy { $0.directive.volume == 0.3 && $0.duckingEnabled == nil } == true)
        #expect(!SourceAudioMixPolicy.musicDucking(in: global).enabled)
    }

    @Test func manualMusicRegionsFollowSpeedChange() async throws {
        var source = timeline()
        source.music = MusicDirective(style: .calm, bpm: 68, volume: 0.4, trackID: UUID())
        source = try #require(LocalizedSoundtrackEditing.apply(.setMusicVolume(0.1), to: source, range: 2...6))
        let (result, _) = try await edit([.setSpeed(2, .all)], timeline: source, range: 2...6)
        let plan = try #require(result.effectiveAdaptiveSoundtrack)
        #expect(plan.segments.map(\.timelineStart) == [0, 2, 4])
        #expect(plan.segments.map(\.timelineDuration) == [2, 2, 2])
        #expect(plan.segments.map(\.directive.volume) == [0.4, 0.1, 0.4])
    }
}
