import Foundation
import Testing
@testable import VeloEditCore

struct DirectorLibraryEditsTests {
    @Test func screenshotRequestIsOneExecutableInsertion() {
        let commands = EditorCommandParser().parse("добавь в начале фон небо с титром путешествие")
        #expect(commands == [.insertBackground(.init(background: "небо", title: "путешествие"))])
        #expect(DirectorLibraryEdits.background(matching: "небо") == .clouds)
        #expect(DirectorLibraryEdits.background(matching: "звёздное небо") == .stars)
        #expect(EditorCommand.supplemental([.setOverlay(.greenScreen, .first, .first), .addTitle("путешествие", .beginning)], to: commands).isEmpty)
    }

    @Test func compoundInsertionPreservesExactTextAndOtherActions() {
        let commands = EditorCommandParser().parse("Вставь фон облака на 5 секунд с титром «Путешествие, музыка и эффекты» в конце и добавь плавный наезд")
        #expect(commands == [.insertBackground(.init(background: "облака", title: "Путешествие, музыка и эффекты", duration: 5, position: .end)), .setEffect(.pushIn, .all)])
        let timeline = Timeline(storyPlanID: UUID(), items: [.init(kind: .photo, sourceDuration: 8, timelineStart: 0, timelineDuration: 8)])
        let input = NaturalLanguageDirectorInput(userRequest: "Вставь фон облака на 5 секунд с титром «Путешествие»", currentProject: .init(name: "Test", timelines: [timeline]), timeline: timeline)
        #expect(!NaturalLanguageDirector().plan(input: input).requiresBackgroundRefinement)
    }

    @Test func backgroundAndTitleCommitTogetherAndReopen() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("director-library-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ProjectStore(createAt: root, name: "Director library")
        let image = root.appendingPathComponent("source.png")
        try AutonomousOperationTests.photo(at: image)
        let asset = try await MediaImporter().makeAsset(url: image)
        let clip = TimelineItem(assetID: asset.id, kind: .photo, sourceDuration: 6, timelineStart: 0, timelineDuration: 6)
        let oldTitle = TitleTimelineItem(kind: .title, text: "Существующий титр", startTime: 1, duration: 2, targetClipID: clip.id)
        let original = Timeline(storyPlanID: UUID(), width: 640, height: 360, items: [clip], titleItems: [oldTitle])
        try await store.update { $0.assets = [asset]; $0.timelines = [original] }
        let result = try await VeloEditPipeline(store: store).applyNaturalLanguageEdit("добавь в начале фон небо с титром путешествие")
        #expect(result.committed)
        #expect(result.commandReport.ignored.isEmpty)
        #expect(result.timeline.items.count == 2)
        #expect(result.timeline.items[1].id == clip.id)
        #expect(result.timeline.items[1].timelineStart == 4)
        #expect(result.timeline.effectiveTitleItems.first { $0.id == oldTitle.id }?.startTime == 5)
        let title = try #require(result.timeline.effectiveTitleItems.first { $0.text == "путешествие" })
        #expect(title.targetClipID == result.timeline.items[0].id)
        #expect(title.startTime == 0 && title.duration == 4)
        #expect(result.userSummary.contains("Облака") && result.userSummary.contains("путешествие"))
        #expect(!result.userSummary.contains("editing tools"))
        let reopened = try ProjectStore(open: root)
        let saved = await reopened.manifest
        #expect(saved.timelines.last?.items == result.timeline.items)
        #expect(saved.timelineCheckpoints?.count == 1)
        let persistedOriginal = try JSONDecoder.veloEdit.decode(Timeline.self, from: JSONEncoder.veloEdit.encode(original))
        #expect(saved.timelineCheckpoints?.first?.timeline == persistedOriginal)
        let background = try #require(saved.assets.first { BackgroundPreset.preset(for: $0) == .clouds })
        #expect(FileManager.default.fileExists(atPath: background.originalURL.path))
        #expect(try Data(contentsOf: background.originalURL).count > 100)
        let playback = try await PlaybackEngine().build(timeline: result.timeline, assets: saved.assets)
        #expect(abs(playback.duration - 10) < 0.1)
        #expect(!playback.composition.tracks.isEmpty)
    }

    @Test func missingBackgroundDoesNotPretendToSucceedOrChangeFilm() {
        let timeline = Timeline(storyPlanID: UUID(), items: [.init(kind: .video, sourceDuration: 10, timelineStart: 0, timelineDuration: 10)])
        let input = NaturalLanguageDirectorInput(userRequest: "Добавь фон марсианский город с титром Привет", currentProject: .init(name: "Test"), timeline: timeline)
        let director = NaturalLanguageDirector()
        let result = director.execute(plan: director.plan(input: input), input: input)
        #expect(!result.committed)
        #expect(result.timeline == timeline)
        #expect(result.userSummary.contains("не найден"))
        #expect(!result.plan.requiresBackgroundRefinement)
    }

    @Test func sourceSearchFindsUnusedDogAndRejectsUnrelatedSelection() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("director-source-\(UUID()).mov")
        try Data("source lookup fixture".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let asset = MediaAsset(originalURL: file, kind: .video, byteSize: 0, contentHash: "fixture", metadata: .init(duration: 30))
        let scores = ClipScores(quality: 0.9, interest: 0.9, action: 0.5, stability: 0.9)
        let road = Candidate(assetID: asset.id, sourceStart: 0, sourceDuration: 6, scores: scores, tags: ["road"])
        let dog = Candidate(assetID: asset.id, sourceStart: 12, sourceDuration: 5, scores: scores, tags: ["dog"], insights: .init(sceneSummary: "A dog running"))
        let clip = TimelineItem(candidateID: road.id, assetID: asset.id, kind: .video, sourceDuration: 6, timelineStart: 0, timelineDuration: 6)
        let timeline = Timeline(storyPlanID: UUID(), items: [clip])
        let project = ProjectManifest(name: "Search", assets: [asset], analyses: [.init(assetID: asset.id, analyzedContentHash: "fixture", candidates: [road, dog])], timelines: [timeline])
        let director = NaturalLanguageDirector()
        let input = NaturalLanguageDirectorInput(userRequest: "добавь кусок из видео где была собака", currentProject: project, timeline: timeline, selectedItemID: clip.id, playheadTime: 0)
        let result = director.execute(plan: director.plan(input: input), input: input)
        #expect(!result.plan.requiresBackgroundRefinement)
        #expect(result.committed)
        #expect(result.timeline.items.last?.candidateID == dog.id)
        #expect(result.timeline.items.last?.sourceStart == 12)
        #expect(result.timeline.items.last?.sourceDuration == 5)
        #expect(result.timeline.items.first == clip)
        var missing = input
        missing.userRequest = "добавь кусок из видео где была кошка"
        let absent = director.execute(plan: director.plan(input: missing), input: missing)
        #expect(!absent.committed && absent.timeline == timeline)
        #expect(absent.userSummary.contains("не найден"))
        var alreadyUsed = input
        alreadyUsed.timeline = result.timeline
        #expect(!director.execute(plan: director.plan(input: alreadyUsed), input: alreadyUsed).committed)
    }

    @Test(arguments: TimelineEffectType.allCases) func fullEffectCatalogCreatesEditableObjects(_ type: TimelineEffectType) {
        let clip = TimelineItem(kind: .video, sourceDuration: 6, timelineStart: 0, timelineDuration: 6)
        let timeline = Timeline(storyPlanID: UUID(), items: [clip])
        let result = EditorCommandExecutor().apply([.addLibraryEffect(type, .first)], to: timeline)
        #expect(result.report.hasChanges)
        #expect(result.timeline.effectiveEffects.contains { $0.effectType == type && $0.targetClipID == clip.id && $0.duration == 6 })
        #expect(result.timeline.items == timeline.items)
    }

    @Test func insertionKeepsSectionMusicAndExistingLayersAttached() {
        let clip = TimelineItem(kind: .video, sourceDuration: 6, timelineStart: 0, timelineDuration: 6)
        let music = MusicDirective(style: .calm, bpm: 70, trackID: UUID())
        let second = MusicDirective(style: .joyful, bpm: 110, trackID: UUID())
        var timeline = Timeline(storyPlanID: UUID(), items: [clip], music: music)
        timeline.adaptiveSoundtrack = .init(primaryTrackID: music.trackID!, timelineDuration: 6,
            timelineFingerprint: timeline.adaptiveSoundtrackFingerprint, segments: [
                .init(timelineStart: 0, timelineDuration: 3, directive: music, semanticLabel: "A", energy: 0.3, confidence: 1),
                .init(timelineStart: 3, timelineDuration: 3, directive: second, semanticLabel: "B", energy: 0.8, confidence: 1)
            ], confidence: 1)
        let insert = TimelineItem(kind: .photo, sourceDuration: 4, timelineStart: 0, timelineDuration: 4)
        DirectorLibraryEdits.insert(insert, at: .beginning, into: &timeline)
        #expect(timeline.effectiveAdaptiveSoundtrack?.segments.map(\.timelineStart) == [0, 7])
        #expect(timeline.effectiveAdaptiveSoundtrack?.segments.map(\.directive.trackID) == [music.trackID, second.trackID])
        #expect(timeline.effectiveAdaptiveSoundtrack?.timelineDuration == 10)
    }

    @Test(arguments: TitleTemplateRegistry.all.map(\.id)) func titleTemplatesPreserveTextAndAnchor(_ templateID: String) {
        let clip = TimelineItem(kind: .photo, sourceDuration: 6, timelineStart: 0, timelineDuration: 6)
        let title = TitleTimelineItem(kind: .title, text: "Путешествие", startTime: 1, duration: 4, targetClipID: clip.id)
        let timeline = Timeline(storyPlanID: UUID(), items: [clip], titleItems: [title])
        let result = EditorCommandExecutor().apply([.applyTitleTemplate(templateID, .first)], to: timeline)
        #expect(result.timeline.effectiveTitleItems.first?.text == "Путешествие")
        #expect(result.timeline.effectiveTitleItems.first?.templateID == templateID)
        #expect(result.timeline.effectiveTitleItems.first?.targetClipID == clip.id)
        #expect(result.timeline.effectiveTitleItems.first?.startTime == 1)
    }
}
