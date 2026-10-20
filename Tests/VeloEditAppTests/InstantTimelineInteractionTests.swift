import Foundation
import AVFoundation
import Testing
import VeloEditCore
@testable import VeloEdit

@Suite(.serialized)
@MainActor
struct InstantTimelineInteractionTests {
    @Test func zeroInlineVolumeHidesOnlyThatClipsSpeechAndRestoresItOnUndo() async throws {
        let fixture = try await Fixture(clipCount: 2); defer { fixture.remove() }
        let model = fixture.model
        var timeline = try #require(model.timeline)
        timeline.originalAudioVolume = 1
        timeline.music = .init(style: .calm, bpm: 100, volume: 0.4)
        timeline.audioDucking = .init(enabled: true)
        timeline.speechRecords = timeline.items.map { item in
            var transcript = SpeechTranscript(localeIdentifier: "ru", words: [], sentences: [], confidence: 1)
            transcript.status = .ready; transcript.speechRanges = [2...3]
            return .init(assetID: item.assetID!, transcript: transcript)
        }
        model.project?.timelines[0] = timeline
        let target = timeline.items[0]
        let originalZones = model.musicDuckingRegions
        #expect(originalZones.count == 2)

        model.setInlineClipVolume(0, id: target.id)
        // The computed collection used by the timeline updates synchronously.
        #expect(model.musicDuckingRegions.count == 1)
        #expect(model.musicDuckingRegions.allSatisfy { $0.anchors.allSatisfy { $0.itemID != target.id } })
        #expect(model.timeline?.items[0].effectiveAudioAdjustments.musicDuckingExclusions?.isEmpty != false)
        #expect(model.timeline?.music == timeline.music)
        #expect(await model.flushAutosave())
        let reopened = try ProjectStore(open: fixture.url)
        #expect(MusicSpeechDucking.regions(in: try #require(await reopened.manifest.timelines.last)) == model.musicDuckingRegions)

        model.undoTimelineEdit()
        #expect(model.musicDuckingRegions == originalZones)
        model.redoTimelineEdit()
        #expect(model.musicDuckingRegions.count == 1)
        model.setInlineClipVolume(1, id: target.id)
        #expect(model.musicDuckingRegions == originalZones)
        #expect(await model.flushAutosave())
    }

    @Test func removingSpeechDuckingZoneKeepsMusicAndSupportsUndoAndSave() async throws {
        let fixture = try await Fixture(clipCount: 1); defer { fixture.remove() }
        let model = fixture.model
        var timeline = try #require(model.timeline)
        timeline.originalAudioVolume = 1
        timeline.music = .init(style: .calm, bpm: 100, volume: 0.4)
        timeline.audioDucking = .init(enabled: true)
        var transcript = SpeechTranscript(localeIdentifier: "ru", words: [], sentences: [], confidence: 1)
        transcript.status = .ready; transcript.speechRanges = [2...3, 6...7]
        timeline.speechRecords = [.init(assetID: timeline.items[0].assetID!, transcript: transcript)]
        model.project?.timelines[0] = timeline
        let zone = try #require(model.musicDuckingRegions.first)
        model.selectMusicDuckingRegion(zone.id)
        #expect(model.hasTimelineSelection)
        #expect(!model.selectedSoundtrack)
        #expect(model.selectedTimelineItemID == nil)
        model.deleteTimelineSelection()
        #expect(model.musicDuckingRegions.count == 1)
        #expect(model.timeline?.music == timeline.music)
        #expect(model.timeline?.items.count == 1)
        #expect(!model.hasTimelineSelection)
        #expect(await model.flushAutosave())
        let reopened = try ProjectStore(open: fixture.url)
        #expect(await reopened.manifest.timelines.last == model.timeline)
        model.undoTimelineEdit()
        #expect(model.musicDuckingRegions.count == 2)
        model.redoTimelineEdit()
        #expect(model.musicDuckingRegions.count == 1)
        model.selectMusicDuckingRegion(try #require(model.musicDuckingRegions.first).id)
        model.selectSoundtrack()
        #expect(model.selectedMusicDuckingRegionID == nil)
    }

    @Test func rightTrimRemovesTailPixelsInActualPlayerAndExport() async throws {
        let fixture = try await Fixture(clipCount: 1); defer { fixture.remove() }
        var cards: [MediaAsset] = []
        for (index, color) in ["#808080", "#FF0000", "#00FF00", "#0000FF"].enumerated() {
            let url = try await TitleCardVideoGenerator().generate(text: "", style: TitleStyle(backgroundColorHex: color),
                duration: 2, width: 160, height: 90, frameRate: 30,
                destination: fixture.root.appendingPathComponent("card-\(index).mov"))
            cards.append(MediaAsset(originalURL: url, kind: .video, byteSize: 1, contentHash: "card-\(index)",
                metadata: .init(duration: 2, width: 160, height: 90, frameRate: 30, hasAudio: false)))
        }
        let sourceTimeline = Timeline(storyPlanID: UUID(), width: 160, height: 90, frameRate: 30,
            items: cards.enumerated().map { index, asset in
                TimelineItem(assetID: asset.id, kind: .video, sourceDuration: 2, timelineStart: Double(index) * 2, timelineDuration: 2)
            }, originalAudioVolume: 0)
        let sourceURL = fixture.root.appendingPathComponent("source.mp4")
        _ = try await RenderEngine().render(timeline: sourceTimeline, assets: cards, quality: .maximum, destination: sourceURL)
        let asset = MediaAsset(originalURL: sourceURL, kind: .video, byteSize: 1, contentHash: "trim-pixels",
            metadata: .init(duration: 8, width: 160, height: 90, frameRate: 30, hasAudio: false))
        let item = TimelineItem(assetID: asset.id, kind: .video, sourceStart: 2, sourceDuration: 6,
            timelineStart: 0, timelineDuration: 6)
        let model = fixture.model
        model.project?.assets = [asset]
        model.project?.timelines[0] = Timeline(storyPlanID: UUID(), width: 160, height: 90, frameRate: 30,
            items: [item], originalAudioVolume: 0)
        let pipeline = try #require(model.pipeline)
        try await pipeline.store.update { $0.assets = [asset] }
        let range = TimelineTrimRange(start: 0, duration: 6).trimming(.trailing, by: -2)
        model.trimTimelineItem(id: item.id, sourceStart: item.sourceStart, timelineDuration: range.duration)
        #expect(await model.flushAutosave())
        let deadline = Date().addingTimeInterval(15)
        while model.previewPlayer?.currentItem == nil && Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let playerItem = try #require(model.previewPlayer?.currentItem)
        #expect(abs(try await playerItem.asset.load(.duration).seconds - 4) < 0.001)
        let trimmed = try #require(model.timeline)
        #expect(trimmed.items[0].sourceStart == 2 && trimmed.items[0].sourceDuration == 4)

        func dominantChannel(asset: AVAsset, composition: AVVideoComposition? = nil, time: Double) async throws -> Int {
            let generator = AVAssetImageGenerator(asset: asset)
            generator.videoComposition = composition
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            let image = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image
            var pixel = [UInt8](repeating: 0, count: 4)
            try pixel.withUnsafeMutableBytes { bytes in
                let context = try #require(CGContext(data: bytes.baseAddress, width: 1, height: 1,
                    bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
                context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            }
            let channel = (0..<3).max { pixel[$0] < pixel[$1] }!
            #expect(pixel[channel] > 150)
            return channel
        }
        // The selected original is red → green → blue. A right trim must
        // retain red and remove blue, in decoded pixels as well as metadata.
        #expect(try await dominantChannel(asset: AVURLAsset(url: sourceURL), time: 2.5) == 0)
        #expect(try await dominantChannel(asset: AVURLAsset(url: sourceURL), time: 7.5) == 2)
        #expect(try await dominantChannel(asset: playerItem.asset, composition: playerItem.videoComposition, time: 0.5) == 0)
        #expect(try await dominantChannel(asset: playerItem.asset, composition: playerItem.videoComposition, time: 3.5) == 1)
        let output = fixture.root.appendingPathComponent("right-trim.mp4")
        _ = try await RenderEngine().render(timeline: trimmed, assets: [asset], quality: .maximum, destination: output)
        #expect(try await dominantChannel(asset: AVURLAsset(url: output), time: 0.5) == 0)
        #expect(try await dominantChannel(asset: AVURLAsset(url: output), time: 3.5) == 1)
    }

    @Test func savingImmediatelyAfterSpeedChangeStillUpdatesActualPlayer() async throws {
        let fixture = try await Fixture(clipCount: 1); defer { fixture.remove() }
        let model = fixture.model
        let url = try await TitleCardVideoGenerator().generate(text: "Speed", style: TitleStyle(), duration: 4,
            width: 160, height: 90, frameRate: 30, destination: fixture.root.appendingPathComponent("speed.mov"))
        let asset = MediaAsset(originalURL: url, kind: .video, byteSize: 1, contentHash: "speed-fixture",
            metadata: .init(duration: 4, width: 160, height: 90, frameRate: 30, hasAudio: false))
        let item = TimelineItem(assetID: asset.id, kind: .video, sourceDuration: 4, timelineStart: 0, timelineDuration: 4)
        model.project?.assets = [asset]
        model.project?.timelines[0] = Timeline(storyPlanID: UUID(), width: 160, height: 90, frameRate: 30,
            items: [item], originalAudioVolume: 1)
        let pipeline = try #require(model.pipeline)
        try await pipeline.store.update { $0.assets = [asset] }
        model.setInlineClipSpeed(2, id: item.id)
        #expect(await model.flushAutosave())
        let deadline = Date().addingTimeInterval(8)
        while model.previewPlayer?.currentItem == nil && Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let playerItem = try #require(model.previewPlayer?.currentItem)
        #expect(abs(try await playerItem.asset.load(.duration).seconds - 2) < 0.001)
        #expect(model.timeline?.items[0].sourceDuration == 4)
        #expect(model.errorMessage == nil)
    }

    @Test func inlineControlsTargetTheirOwnClipAndRevealItForPlayback() async throws {
        let fixture = try await Fixture(clipCount: 3); defer { fixture.remove() }
        let model = fixture.model
        let before = try #require(model.timeline)
        let target = before.items[1]
        model.selectTimelineItem(before.items[2].id)
        model.setInlineClipVolume(0.25, id: target.id)
        #expect(model.selectedTimelineItemID == target.id)
        #expect(model.timeline?.items[1].effectiveAudioAdjustments.volume == 0.25)
        #expect(model.timeline?.items[2].effectiveAudioAdjustments.volume == 1)
        #expect(model.timelinePlayheadTime == 10)
        model.setInlineClipSpeed(2, id: target.id)
        #expect(model.timeline?.items[1].sourceStart == target.sourceStart)
        #expect(model.timeline?.items[1].sourceDuration == target.sourceDuration)
        #expect(model.timeline?.items[1].timelineDuration == 5)
        #expect(model.timeline?.items[2].timelineStart == 15)
        #expect(await model.flushAutosave())
        let reopened = try ProjectStore(open: fixture.url)
        #expect(await reopened.manifest.timelines.last == model.timeline)
        model.undoTimelineEdit()
        #expect(model.timeline?.items[1].timelineDuration == 10)
        #expect(model.timeline?.items[1].effectiveAudioAdjustments.volume == 0.25)
    }

    @Test func rightTrimOfFastVideoPreservesSourceBeginningThroughUndoAndSave() async throws {
        let fixture = try await Fixture(clipCount: 3); defer { fixture.remove() }
        let model = fixture.model
        model.project?.timelines[0].items[1].sourceStart = 5
        model.project?.timelines[0].items[1].sourceDuration = 20
        model.project?.timelines[0].items[1].speed = 2
        let original = try #require(model.timeline)
        let item = original.items[1]
        let range = TimelineTrimRange(start: item.timelineStart, duration: item.timelineDuration).trimming(.trailing, by: -2)
        model.trimTimelineItem(id: item.id, sourceStart: item.sourceStart, timelineDuration: range.duration)
        let trimmed = try #require(model.timeline)
        #expect(trimmed.items[1].sourceStart == 5)
        #expect(trimmed.items[1].sourceDuration == 16)
        #expect(trimmed.items[1].timelineStart == 10)
        #expect(trimmed.items[2].timelineStart == 18)
        model.undoTimelineEdit()
        #expect(model.timeline == original)
        model.redoTimelineEdit()
        #expect(model.timeline == trimmed)
        #expect(await model.flushAutosave())
        let reopened = try ProjectStore(open: fixture.url)
        #expect(await reopened.manifest.timelines.last == trimmed)
    }

    @Test func filmOpeningAppliesAsOneUndoableEditAndDeletionPersists() async throws {
        let fixture = try await Fixture(clipCount: 3); defer { fixture.remove() }
        let model = fixture.model
        let original = try #require(model.timeline)
        model.directorBrief = .init(musicPolicy: .none, titlePolicy: .minimal)
        let originalSettings = model.directorBrief.openingTitles
        model.project?.storyPlans = [StoryPlan(id: original.storyPlanID, prompt: "Наш фильм", preset: .cinematic,
            constraints: .init(targetDuration: 30), chapters: [], directorBrief: model.directorBrief)]
        let settings = FilmOpeningSettings(policy: .selected, title: "Наше путешествие 🏕", templateID: "title.cinematic-clean.v1")
        model.applyFilmOpeningSettings(settings)
        let opening = try #require(model.timeline?.effectiveTitleItems.first { $0.semanticRole == .filmOpening })
        #expect(model.timeline?.items == original.items && model.timeline?.duration == original.duration)
        #expect(model.timeline?.originalAudioVolume == original.originalAudioVolume)
        #expect(model.selectedTitleTimelineItem?.id == opening.id)
        model.undoTimelineEdit()
        #expect(model.timeline == original)
        #expect(model.directorBrief.openingTitles == originalSettings)
        model.redoTimelineEdit()
        #expect(model.timeline?.effectiveTitleItems.first?.id == opening.id)
        model.selectTitleTimelineItem(opening.id)
        model.setSelectedModernTitleText("Ручное название\nВторая строка")
        model.setSelectedModernTitleAdditionalText("")
        model.setSelectedModernTitleTemplate("title.elegant.v1")
        #expect(model.selectedTitleTimelineItem?.text == "Ручное название\nВторая строка")
        #expect(model.selectedTitleTimelineItem?.additionalText?.isEmpty != false)
        model.moveTitleTimelineItem(opening.id, to: 1.7)
        model.setSelectedModernTitleDuration(4.2)
        #expect(model.selectedTitleTimelineItem?.startTime == 1.7)
        #expect(model.selectedTitleTimelineItem?.duration == 4.2)
        model.deleteTimelineSelection()
        #expect(model.timeline?.openingTitles?.policy == .off)
        #expect(model.timeline?.effectiveTitleItems.contains { $0.semanticRole == .filmOpening } == false)
        #expect(await model.flushAutosave())
        let reopened = try ProjectStore(open: fixture.url)
        #expect(await reopened.manifest.timelines.last == model.timeline)
        model.undoTimelineEdit()
        #expect(model.timeline?.effectiveTitleItems.first?.text == "Ручное название\nВторая строка")
        #expect(await model.flushAutosave())
    }

    @Test func manuallyAssembledTimelineCanUseTheSameOpeningControls() async throws {
        let fixture = try await Fixture(clipCount: 2); defer { fixture.remove() }
        let model = fixture.model
        #expect(model.project?.storyPlans.isEmpty == true)
        model.applyFilmOpeningSettings(.init(policy: .selected, title: "Наш день", templateID: "title.cinematic-clean.v1"))
        #expect(model.timeline?.effectiveTitleItems.first?.semanticRole == .filmOpening)
        #expect(model.timeline?.effectiveTitleItems.first?.text == "Наш день")
        #expect(await model.flushAutosave())
    }

    @Test func movingWatchedClipKeepsPreviewAtItsNewPositionAndPreservesFinish() async throws {
        let fixture = try await Fixture(clipCount: 3); defer { fixture.remove() }
        let model = fixture.model
        model.project?.timelines[0].endingFadeDuration = 3
        model.project?.timelines[0].movieEndingAudioVersion = nil
        model.project?.timelines[0].items[2].candidateID = UUID()
        model.project?.timelines[0].items[2].audioAdjustments = .init(fadeOut: 3)
        let last = try #require(model.timeline?.items.last)
        model.seekTimeline(to: 28)
        model.movePrimaryTimelineItem(last.id, toPrimaryIndex: 1)
        #expect(model.timelinePlayheadTime == 18)
        #expect(model.timeline?.items[1].id == last.id)
        #expect(model.timeline?.items[1].effectiveAudioAdjustments.fadeOut == 0)
        #expect(model.timeline?.endingFadeDuration == 3)
        #expect(model.timeline?.movieEndingAudioVersion == 1)
        // A manually chosen clip fade after migration remains a clip property.
        model.project?.timelines[0].items[1].audioAdjustments = .init(fadeOut: 1)
        model.seekTimeline(to: 2)
        model.movePrimaryTimelineItem(last.id, toPrimaryIndex: 2)
        #expect(model.timelinePlayheadTime == 2)
        #expect(model.timeline?.items[2].effectiveAudioAdjustments.fadeOut == 1)
        #expect(await model.flushAutosave())
        let store = try ProjectStore(open: fixture.url)
        #expect(await store.manifest.timelines.last == model.timeline)
    }

    @Test func titleTypingAndClosingInspectorPreserveEveryCharacter() async throws {
        let fixture = try await Fixture(clipCount: 1); defer { fixture.remove() }
        let model = fixture.model
        let title = TitleTimelineItem(kind: .title, text: "Было", startTime: 0, duration: 5)
        model.project?.timelines[0].titleItems = [title]
        model.selectTitleTimelineItem(title.id)
        for text in ["Н", "Новый", "Новый текст 🌳\nВторая строка"] { model.setSelectedModernTitleText(text) }
        model.closeTimelineInspector()
        #expect(model.selectedTitleTimelineItem?.text == "Новый текст 🌳\nВторая строка")
        #expect(await model.flushAutosave())
        let store = try ProjectStore(open: fixture.url)
        #expect(await store.manifest.timelines.last?.effectiveTitleItems.first?.text == "Новый текст 🌳\nВторая строка")
        await model.refresh()
        model.openTimelineInspector()
        #expect(model.selectedTitleTimelineItem?.text == "Новый текст 🌳\nВторая строка")
    }

    @Test(arguments: ["clear", "escape", "command", "marquee", "all", "clip", "section", "delete"])
    func leavingTitleEditingNeverLeavesAnEmptyInspector(exit: String) async throws {
        let fixture = try await Fixture(clipCount: 1); defer { fixture.remove() }
        let model = fixture.model
        model.section = .timeline
        let title = TitleTimelineItem(kind: .title, text: "Сохрани меня", startTime: 0, duration: 5)
        model.project?.timelines[0].titleItems = [title]
        model.selectTitleTimelineItem(title.id)
        model.openTimelineInspector()
        #expect(model.isTimelineInspectorPresented)
        model.setSelectedModernTitleText("Последняя правка 🌳")
        #expect(model.isTimelineInspectorPresented)
        switch exit {
        case "clear": model.clearTimelineSelection()
        case "escape": model.handleEscape()
        case "command": model.selectTitleTimelineItem(title.id, modifiers: .command)
        case "marquee": model.setTimelineMarqueeSelection([])
        case "all": model.selectAllTimelineElements()
        case "clip": model.selectTimelineItem(model.timeline?.items.first?.id)
        case "section": model.openSection(.media)
        case "delete": model.deleteTimelineSelection()
        default: break
        }
        #expect(!model.isTimelineInspectorPresented)
        if exit == "delete" { model.undoTimelineEdit() }
        #expect(!model.isTimelineInspectorPresented)
        #expect(model.timeline?.effectiveTitleItems.first?.text == "Последняя правка 🌳")
        #expect(await model.flushAutosave())
        model.section = .timeline
        model.selectTitleTimelineItem(title.id)
        #expect(!model.isTimelineInspectorPresented)
        model.openTimelineInspector()
        #expect(model.isTimelineInspectorPresented)
    }

    @Test func inspectorRejectsMissingTitlesAndClosesWhenUndoRemovesItsTarget() async throws {
        let fixture = try await Fixture(clipCount: 1); defer { fixture.remove() }
        let model = fixture.model
        model.section = .timeline
        model.toggleTimelineInspector()
        #expect(!model.isTimelineInspectorPresented)
        model.addModernTitle("Новый", kind: .title)
        model.openTimelineInspector()
        #expect(model.isTimelineInspectorPresented)
        model.undoTimelineEdit()
        #expect(!model.isTimelineInspectorPresented)
        model.redoTimelineEdit()
        #expect(!model.isTimelineInspectorPresented)
        model.selectTitleTimelineItem(UUID())
        model.openTimelineInspector()
        #expect(!model.isTimelineInspectorPresented)
        #expect(await model.flushAutosave())
    }

    @Test func viewerIndicatorsFollowSelectionPartialResetUndoAndReopening() async throws {
        let fixture = try await Fixture(clipCount: 2); defer { fixture.remove() }
        let model = fixture.model
        let original = try #require(model.timeline)
        let clipID = original.items[0].id
        func modifiedTools() -> Set<ViewerAdjustmentTool> {
            Set(ViewerAdjustmentTool.allCases.filter { $0.isModified(in: model.selectedTimelineItem) })
        }
        model.selectTimelineItem(clipID)
        #expect(modifiedTools().isEmpty)
        model.setSelectedBrightness(0.2)
        model.setSelectedTint(0.4)
        model.setSelectedClipVolume(0.5)
        #expect(modifiedTools() == [.colorBalance, .volume])
        model.setSelectedBrightness(0)
        #expect(modifiedTools() == [.colorBalance, .volume]) // Tint still differs.
        model.selectTimelineItem(original.items[1].id)
        #expect(modifiedTools().isEmpty)
        model.selectTimelineItem(clipID)
        #expect(modifiedTools() == [.colorBalance, .volume])
        model.resetSelectedColorBalance()
        #expect(modifiedTools() == [.volume])
        #expect(model.selectedTimelineItem?.effectiveAudioAdjustments.volume == 0.5)
        model.undoTimelineEdit()
        #expect(modifiedTools() == [.colorBalance, .volume])
        model.redoTimelineEdit()
        #expect(modifiedTools() == [.volume])
        #expect(await model.flushAutosave())
        let reopened = try ProjectStore(open: fixture.url)
        let saved = try #require(await reopened.manifest.timelines.last?.items.first)
        #expect(Set(ViewerAdjustmentTool.allCases.filter { $0.isModified(in: saved) }) == [.volume])
        model.resetAllSelectedViewerAdjustments()
        #expect(modifiedTools().isEmpty)
        #expect(model.timeline?.items.count == 2)
        model.clearTimelineSelection()
        #expect(modifiedTools().isEmpty)
    }

    @Test(arguments: ["balance", "correction", "stabilization", "volume", "noise", "speed", "filters", "all"])
    func everyViewerSectionSupportsIndependentResetUndoRedoAndReopening(section: String) async throws {
        let fixture = try await Fixture(clipCount: 2); defer { fixture.remove() }
        let model = fixture.model
        let original = try #require(model.timeline)
        model.selectTimelineItem(original.items[0].id)
        model.autoEnhanceSelected()
        #expect(model.selectedTimelineItem?.effectiveVideoAdjustments.brightness ?? 0 > 0)
        #expect(model.selectedTimelineItem?.effectiveVideoAdjustments.contrast ?? 0 > 1)
        #expect(model.timeline?.items[1] == original.items[1])
        model.undoTimelineEdit()
        #expect(model.timeline == original)

        model.setSelectedBrightness(0.15)
        model.setSelectedWarmth(0.4)
        model.setSelectedTint(0.25)
        model.changeSelectedExposure(by: 0.5)
        model.setSelectedContrast(1.2)
        model.setSelectedSaturation(0.7)
        model.changeSelectedHighlights(by: -0.3)
        model.changeSelectedShadows(by: 0.2)
        model.setSelectedCropMode("ken-burns")
        model.rotateSelected(1)
        model.setSelectedStabilization(0.4)
        model.setSelectedRollingShutterCorrection(true)
        model.setSelectedClipVolume(1.5)
        model.setSelectedClipMuted(true)
        model.setSelectedAudioNormalize(true)
        model.setSelectedDuckOthers(true)
        model.setSelectedDuckingAmount(0.8)
        model.setSelectedNoiseReduction(0.6)
        model.setSelectedEQ(.voice)
        model.setSelectedSpeed(0.5)
        model.setSelectedSmoothSlowMotion(true)
        model.toggleSelectedReverse()
        model.setSelectedPreservePitch(false)
        model.setSelectedFilter(.sepia)
        model.setSelectedFilterIntensity(0.6)
        model.setSelectedAudioEffect(.room)
        let edited = try #require(model.timeline)
        let item = try #require(model.selectedTimelineItem)
        var video = item.effectiveVideoAdjustments
        var audio = item.effectiveAudioAdjustments
        let modifiedTools = Set(ViewerAdjustmentTool.allCases.filter { $0.isModified(in: item) })
        #expect(modifiedTools == Set(ViewerAdjustmentTool.allCases.filter { $0 != .information }))
        #expect(video.brightness == 0.15 && video.warmth == 0.4 && video.tint == 0.25)
        #expect(video.exposure == 0.5 && video.contrast == 1.2 && video.saturation == 0.7)
        #expect(video.highlights == -0.3 && video.shadows == 0.2)
        #expect(video.rotationQuarterTurns == 1 && item.effect == ClipEffect.kenBurns.rawValue)
        #expect(video.stabilization == 0.4 && video.rollingShutterCorrection == true)
        #expect(audio.volume == 1.5 && audio.muted && audio.normalize == true)
        #expect(audio.duckOthers == true && audio.duckingAmount == 0.8)
        #expect(audio.noiseReduction == 0.6 && audio.eqPreset == .voice)
        #expect(item.speed == 0.5 && item.isReversed && video.smoothSlowMotion == true && audio.preservePitch == false)
        #expect(item.timelineDuration == 20 && edited.items[1].timelineStart == 20)
        #expect(video.filter == .sepia && video.filterIntensity == 0.6 && audio.effect == .room)
        switch section {
        case "balance":
            model.resetSelectedColorBalance()
            video.brightness = 0; video.warmth = 0; video.tint = 0
        case "correction":
            model.resetSelectedColorCorrection()
            video.exposure = 0; video.contrast = 1; video.saturation = 1; video.highlights = 0; video.shadows = 0
        case "stabilization":
            model.resetSelectedStabilization()
            video.stabilization = 0; video.rollingShutterCorrection = false
        case "volume":
            model.resetSelectedVolume()
            audio.volume = 1; audio.muted = false; audio.normalize = false; audio.duckOthers = false; audio.duckingAmount = 0.5
        case "noise":
            model.resetSelectedNoiseProcessing()
            audio.noiseReduction = 0; audio.eqPreset = .flat
        case "speed":
            model.resetSelectedSpeed()
            video.smoothSlowMotion = false; audio.preservePitch = true
        case "filters":
            model.resetSelectedFilters()
            video.filter = .none; video.filterIntensity = 1; audio.effect = AudioEffect.none
        default:
            model.resetAllSelectedViewerAdjustments()
            video = VideoAdjustments(); audio = AudioAdjustments()
        }
        let resetTools: [String: ViewerAdjustmentTool] = [
            "balance": .colorBalance, "correction": .colorCorrection, "stabilization": .stabilization,
            "volume": .volume, "noise": .noiseReduction, "speed": .speed, "filters": .filters
        ]
        let expectedTools = resetTools[section].map { modifiedTools.subtracting([$0]) } ?? []
        #expect(Set(ViewerAdjustmentTool.allCases.filter { $0.isModified(in: model.selectedTimelineItem) }) == expectedTools)
        #expect(model.selectedTimelineItem?.effectiveVideoAdjustments == video)
        #expect(model.selectedTimelineItem?.effectiveAudioAdjustments == audio)
        #expect(model.selectedTimelineItem?.effect == (section == "all" ? nil : item.effect))
        let resetsSpeed = section == "all" || section == "speed"
        #expect(model.selectedTimelineItem?.speed == (resetsSpeed ? 1 : 0.5))
        #expect(model.selectedTimelineItem?.isReversed == !resetsSpeed)
        #expect(model.timeline?.items[1].timelineStart == (resetsSpeed ? 10 : 20))
        let reset = model.timeline
        model.undoTimelineEdit()
        #expect(model.timeline == edited)
        model.redoTimelineEdit()
        #expect(model.timeline == reset)
        #expect(await model.flushAutosave())
        let reopened = try ProjectStore(open: fixture.url)
        #expect(await reopened.manifest.timelines.last == reset)
    }

    @Test func cropModesRotationsResetUndoAndSavingPreserveUnrelatedAdjustments() async throws {
        let fixture = try await Fixture(clipCount: 1); defer { fixture.remove() }
        let model = fixture.model
        var video = VideoAdjustments(crop: .fill, rotationQuarterTurns: 1, filter: .sepia)
        video.brightness = 0.2
        video.subjectReframe = .init(startCenterX: 0.4, startCenterY: 0.5, endCenterX: 0.6, endCenterY: 0.5,
            startScale: 1.2, endScale: 1.3, targetAspectRatio: 16.0 / 9, confidence: 0.9)
        model.project?.timelines[0].items[0].videoAdjustments = video
        model.project?.timelines[0].items[0].effect = ClipEffect.kenBurns.rawValue
        model.selectTimelineItem(try #require(model.timeline?.items.first?.id))
        model.setSelectedCropMode("fit")
        #expect(model.selectedTimelineItem?.effect == nil)
        #expect(model.selectedTimelineItem?.effectiveVideoAdjustments.subjectReframe == nil)
        #expect(model.selectedTimelineItem?.effectiveVideoAdjustments.crop == .fit)
        model.setSelectedCropMode("ken-burns")
        #expect(model.selectedTimelineItem?.effect == ClipEffect.kenBurns.rawValue)
        #expect(model.selectedTimelineItem?.effectiveVideoAdjustments.crop == .fill)
        model.setSelectedCropMode("fill")
        #expect(model.selectedTimelineItem?.effect == nil)
        model.rotateSelected(-1)
        #expect(model.selectedTimelineItem?.effectiveVideoAdjustments.rotationQuarterTurns == 0)
        model.rotateSelected(-1)
        #expect(model.selectedTimelineItem?.effectiveVideoAdjustments.rotationQuarterTurns == 3)
        model.rotateSelected(1)
        #expect(model.selectedTimelineItem?.effectiveVideoAdjustments.rotationQuarterTurns == 0)
        for _ in 0..<4 { model.rotateSelected(1) }
        #expect(model.selectedTimelineItem?.effectiveVideoAdjustments.rotationQuarterTurns == 0)
        model.setSelectedCropMode("ken-burns")
        model.rotateSelected(1)
        let beforeReset = model.timeline
        #expect(ViewerAdjustmentTool.crop.isModified(in: model.selectedTimelineItem))
        model.resetSelectedCropAndRotation()
        #expect(!ViewerAdjustmentTool.crop.isModified(in: model.selectedTimelineItem))
        #expect(model.selectedTimelineItem?.effect == nil)
        #expect(model.selectedTimelineItem?.effectiveVideoAdjustments.crop == .fill)
        #expect(model.selectedTimelineItem?.effectiveVideoAdjustments.rotationQuarterTurns == 0)
        #expect(model.selectedTimelineItem?.effectiveVideoAdjustments.filter == .sepia)
        #expect(model.selectedTimelineItem?.effectiveVideoAdjustments.brightness == 0.2)
        let reset = model.timeline
        model.undoTimelineEdit()
        #expect(model.timeline == beforeReset)
        model.redoTimelineEdit()
        #expect(model.timeline == reset)
        #expect(await model.flushAutosave())
        let reopened = try ProjectStore(open: fixture.url)
        #expect(await reopened.manifest.timelines.last == reset)
    }

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
