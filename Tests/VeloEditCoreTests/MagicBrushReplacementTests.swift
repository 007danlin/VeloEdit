import Foundation
import AVFoundation
import AppKit
import Testing
@testable import VeloEditCore

@Suite(.serialized) struct MagicBrushReplacementTests {
    private func fixture() -> ProjectManifest {
        let asset = MediaAsset(originalURL: URL(fileURLWithPath: "/tmp/brush.mov"), kind: .video, byteSize: 1,
                               contentHash: "brush", metadata: .init(duration: 140))
        let candidates = [0.0, 40, 80].map { start -> Candidate in
            var insights = CandidateInsights(sceneSummary: "Велосипед на дорожке")
            insights.editorialEvidence = .init(usableRange: .init(start: start, end: start + 10), informationGain: 0.7, confidence: 0.9)
            return Candidate(assetID: asset.id, sourceStart: start, sourceDuration: 10,
                             scores: .init(quality: 0.9, interest: 0.9, action: 0.8, stability: 0.9), tags: ["cycling"], insights: insights)
        }
        let items = [candidates[0], candidates[2]].enumerated().map { i, c in
            TimelineItem(candidateID: c.id, assetID: asset.id, kind: .video, sourceStart: c.sourceStart,
                         sourceDuration: 8, timelineStart: Double(i * 8), timelineDuration: 8)
        }
        return ProjectManifest(name: "Brush", assets: [asset], analyses: [.init(assetID: asset.id, analyzedContentHash: asset.contentHash, candidates: candidates)],
                               timelines: [.init(storyPlanID: UUID(), items: items)])
    }

    @Test func replacementIntentIsNotMusicOrNegativeInstruction() {
        let replacements = [
            "Замени этот фрагмент", "замени фрагмент на другой", "Подбери другой кадр", "replace selected clip", "замени",
            "замени фрагмент, не меняй музыку", "подбери другой момент", "этот кусок не подходит, возьми другой",
            "хочу другой дубль", "покажи что-нибудь другое", "здесь нужен другой эпизод", "поменяй этот участок",
            "вместо этого поставь что-то другое", "выбери иной отрывок", "переподбери видео", "поменяй его",
            "давай другой кусочек", "этот фрагмент мне не нравится", "swap this footage", "use another shot",
            "замени выбранный неудачный эпизод", "можешь заменить этот кусок?", "замени фрагмент без изменения длительности"
        ]
        for text in replacements { #expect(LocalShotReplacement.requestsReplacement(text), "\(text)") }
        let otherEdits = [
            "замени музыку", "смени титр", "не заменяй фрагмент, сделай ярче", "не меняй кадры", "замени музыку в этом фрагменте",
            "другой трек для этого фрагмента", "измени цвет этого куска", "не нравится цвет этого кадра", "удали этот фрагмент",
            "замени текст", "поменяй голос", "не заменяй", "не хочу другой кадр", "не надо заменять этот клип",
            "don't replace this clip", "сохрани исходный фрагмент", "кадры не трогай", "добавь другой кадр в конец",
            "поменяй местами два кадра", "хочу другой цвет этого кадра", "сделай кадр ярче"
        ]
        for text in otherEdits { #expect(!LocalShotReplacement.requestsReplacement(text), "\(text)") }
    }

    @Test func semanticModelReplacementUsesTheSameScopedOperationAndRespectsNegation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("brush-semantic-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let project = fixture(), before = project.timelines[0]
        let store = try ProjectStore(createAt: root, name: project.name)
        try await store.update { $0 = project }
        let pipeline = VeloEditPipeline(store: store)
        _ = try await pipeline.applyEditorCommands("не заменяй этот фрагмент", timelineRange: 0...8, modelRequestsReplacement: true)
        #expect(await store.manifest.timelines.last == before)
        let prompt = "Вместо того, что тут стоит, возьми более удачную запись"
        #expect(!LocalShotReplacement.requestsReplacement(prompt))
        let report = try await pipeline.applyEditorCommands(prompt, timelineRange: 0...8,
            supplementalCommands: [.setEQ(.presence, .all)], modelRequestsReplacement: true)
        let after = try #require(await store.manifest.timelines.last)
        #expect(report.hasChanges)
        #expect(after.items[0].candidateID == project.analyses[0].candidates[1].id)
        #expect(after.items[0].audioAdjustments == before.items[0].audioAdjustments)
        #expect(after.items[1] == before.items[1])
        #expect(after.duration == before.duration)
    }

    @Test func partialReplacementPersistsSourceChangeAndKeepsOutsideRange() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("brush-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let project = fixture(), before = project.timelines[0]
        let store = try ProjectStore(createAt: root, name: project.name)
        try await store.update { $0 = project }
        let report = try await VeloEditPipeline(store: store).applyEditorCommands("Замени фрагмент на другой", timelineRange: 2...6,
            supplementalCommands: [.setEQ(.presence, .all), .setClipFades(0.5, 0.5, .all)])
        let after = try #require(await store.manifest.timelines.last)
        #expect(report.hasChanges)
        #expect(after.duration == before.duration)
        #expect(after.items.last == before.items.last)
        let replacement = try #require(after.items.first { $0.timelineStart == 2 })
        #expect(replacement.candidateID == project.analyses[0].candidates[1].id)
        #expect(replacement.sourceStart >= 40 && replacement.sourceStart + replacement.sourceDuration <= 50)
        #expect(replacement.audioAdjustments == before.items[0].audioAdjustments)
        for time in [0.5, 1.5, 6.5, 7.5, 9] {
            let old = before.items.first { $0.timelineStart <= time && $0.timelineStart + $0.timelineDuration > time }!
            let new = after.items.first { $0.timelineStart <= time && $0.timelineStart + $0.timelineDuration > time }!
            #expect(old.assetID == new.assetID)
            #expect(abs(old.sourceTime(atTimelineTime: time) - new.sourceTime(atTimelineTime: time)) < 0.0001)
        }
        #expect(await store.manifest.timelineCheckpoints?.last?.timeline == before)
        let reopened = try ProjectStore(open: root)
        let persisted = try JSONDecoder.veloEdit.decode(Timeline.self, from: JSONEncoder.veloEdit.encode(after))
        #expect(await reopened.manifest.timelines.last == persisted)
    }

    @Test func failedReplacementIsAtomicEvenWithModelAudioCommands() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("brush-fail-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        var project = fixture()
        project.analyses[0].candidates.remove(at: 1)
        let store = try ProjectStore(createAt: root, name: project.name)
        try await store.update { $0 = project }
        let before = await store.snapshot()
        await #expect(throws: LocalEditorialEditError.self) {
            try await VeloEditPipeline(store: store).applyEditorCommands("замени фрагмент", timelineRange: 0...8,
                supplementalCommands: [.setClipFades(0.5, 0.5, .all)])
        }
        #expect(await store.snapshot().revision == before.revision)
        #expect(await store.manifest.timelines == before.manifest.timelines)
        #expect(await store.manifest.timelineCheckpoints == before.manifest.timelineCheckpoints)
    }

    @Test func replacementRejectsLeadInToTheSameUnwantedEpisode() throws {
        var project = fixture()
        var nearby = project.analyses[0].candidates[1]
        nearby.id = UUID()
        nearby.sourceStart = 12
        nearby.insights?.editorialEvidence?.usableRange = .init(start: 12, end: 22)
        nearby.scores.quality = 1
        project.analyses[0].candidates.append(nearby)
        let before = project.timelines[0]
        let after = try LocalShotReplacement.apply(to: before, itemIDs: [before.items[0].id], original: before, project: project)
        #expect(after.items[0].candidateID == project.analyses[0].candidates[1].id)
        #expect(after.items[0].candidateID != nearby.id)
    }

    @Test func savedTest7RepairReopensWithOriginalMusicAndUndo() async throws {
        guard let input = ProcessInfo.processInfo.environment["VELOEDIT_BRUSH_VERIFY_SAVED"] else { return }
        let root = URL(fileURLWithPath: input)
        let data = try Data(contentsOf: root.appendingPathComponent("project.json"))
        let store = try ProjectStore(open: root)
        let project = await store.manifest
        let timeline = try #require(project.timelines.last)
        let targetID = UUID(uuidString: "E7E1F636-7074-4AAF-AE08-943B51A61ECF")!
        let item = try #require(timeline.items.first { $0.id == targetID })
        #expect(abs(item.sourceStart - 353.2951456989247) < 0.00001)
        #expect(abs(item.timelineStart - 40.266666666666666) < 0.00001)
        #expect(abs(item.timelineDuration - 6.96666666666664) < 0.00001)
        #expect(abs(timeline.duration - 300) < 0.00001)
        let checkpoint = try #require(project.timelineCheckpoints?.last)
        #expect(abs(try #require(checkpoint.timeline.items.first { $0.id == targetID }).sourceStart - 393.6666666666667) < 0.00001)
        #expect(timeline.items.filter { $0.id != targetID } == checkpoint.timeline.items.filter { $0.id != targetID })
        #expect(timeline.effectiveTitleItems.filter { $0.startTime >= 134 && $0.startTime < 205 }.map(\.text) == ["Багги", "Багги"])
        let music = try JSONDecoder.veloEdit.decode([LocalMusicTrack].self, from: Data(contentsOf: root.appendingPathComponent("MusicLibrary/tracks.json")))
        let playback = try await PlaybackEngine().build(timeline: timeline, assets: project.assets, musicTracks: music, forceVideoComposition: true)
        #expect(playback.skippedItemIDs.isEmpty)
        #expect(playback.renderedItemCount == timeline.items.count)
        #expect(playback.duration > 299 && playback.duration <= 300)
        #expect(try Data(contentsOf: root.appendingPathComponent("project.json")) == data)
    }

    @Test func realTest7ReplacementAndBuggyLabels() async throws {
        guard let input = ProcessInfo.processInfo.environment["VELOEDIT_BRUSH_PROJECT"],
              let output = ProcessInfo.processInfo.environment["VELOEDIT_BRUSH_OUTPUT"] else { return }
        let inputURL = URL(fileURLWithPath: input)
        let originalData = try Data(contentsOf: inputURL.appendingPathComponent("project.json"))
        var project = try JSONDecoder.veloEdit.decode(ProjectManifest.self, from: originalData)
        let before = try #require(project.timelines.last)
        let target = try #require(before.items.first { $0.timelineStart > 40 && $0.timelineStart < 41 })
        let outputURL = URL(fileURLWithPath: output)
        let store = try ProjectStore(createAt: outputURL, name: project.name)
        try await store.update { $0 = project }
        let replacementStarted = Date()
        let report = try await VeloEditPipeline(store: store).applyEditorCommands("замени этот фрагмент", timelineRange: target.timelineStart...(target.timelineStart + target.timelineDuration))
        print("TEST7 REPLACEMENT INCLUDING SAVE: \(Date().timeIntervalSince(replacementStarted)) seconds")
        #expect(report.hasChanges)
        project = await store.manifest
        let replaced = try #require(project.timelines.last)
        let newItem = try #require(replaced.items.first { $0.id == target.id })
        #expect(newItem.candidateID != target.candidateID)
        #expect(newItem.assetID != target.assetID || newItem.sourceStart + newItem.sourceDuration <= target.sourceStart || newItem.sourceStart >= target.sourceStart + target.sourceDuration)
        #expect(newItem.assetID != target.assetID || newItem.sourceStart + newItem.sourceDuration <= target.sourceStart - 25 || newItem.sourceStart >= target.sourceStart + target.sourceDuration + 25)
        #expect(abs(replaced.duration - 300) < 0.001)
        #expect(replaced.items.filter { $0.id != target.id } == before.items.filter { $0.id != target.id })
        let discovery = EventIntelligenceEngine().discover(assets: project.assets, analyses: project.analyses)
        let buggyIDs = Set(project.assets.filter { ["GX010524.MP4", "GX010530.MP4"].contains($0.displayName) }.map(\.id))
        #expect(buggyIDs.count == 2)
        #expect(discovery.sourceMap.entries.filter { buggyIDs.contains($0.assetID) }.allSatisfy { $0.activityTitle == "Багги" })
        let planIndex = try #require(project.storyPlans.firstIndex { $0.id == replaced.storyPlanID })
        let plan = AutomaticEditorialAssembly.reconcile(timeline: replaced, plan: project.storyPlans[planIndex], analyses: project.analyses,
                                                        events: discovery.events, sourceMap: discovery.sourceMap)
        let repaired = EditorialPresentationPolicy.ensuringChapterTitles(in: replaced, plan: plan, preserveExistingPresentation: true)
        for item in replaced.items.filter({ buggyIDs.contains($0.assetID ?? UUID()) }) {
            #expect(plan.chapters.first { $0.candidateIDs.contains(item.candidateID ?? UUID()) }?.title == "Багги")
        }
        #expect(repaired.effectiveTitleItems.filter { $0.startTime >= 134 && $0.startTime < 205 }.allSatisfy { $0.text == "Багги" })
        project.sourceMap = discovery.sourceMap
        project.events = discovery.events
        project.storyPlans[planIndex] = plan
        project.timelines[project.timelines.count - 1] = repaired
        try await store.update { $0 = project }
        let reopened = try ProjectStore(open: outputURL)
        let persisted = try JSONDecoder.veloEdit.decode(Timeline.self, from: JSONEncoder.veloEdit.encode(repaired))
        #expect(await reopened.manifest.timelines.last == persisted)
        #expect(try Data(contentsOf: inputURL.appendingPathComponent("project.json")) == originalData)
        let music = try JSONDecoder.veloEdit.decode([LocalMusicTrack].self, from: Data(contentsOf: inputURL.appendingPathComponent("MusicLibrary/tracks.json")))
        let originalPlayback = try await PlaybackEngine().build(timeline: before, assets: project.assets, musicTracks: music, forceVideoComposition: true)
        let playback = try await PlaybackEngine().build(timeline: repaired, assets: project.assets, musicTracks: music, forceVideoComposition: true)
        #expect(playback.skippedItemIDs.isEmpty)
        #expect(playback.renderedItemCount == repaired.items.count)
        #expect(abs(playback.duration - originalPlayback.duration) < 0.001)
        let generator = AVAssetImageGenerator(asset: playback.composition)
        generator.videoComposition = playback.videoComposition
        generator.maximumSize = CGSize(width: 960, height: 540)
        for (name, time) in [("replacement", 43.0), ("buggy-side-title", 135.5), ("buggy-front-title", 174.5)] {
            let frame = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image
            let data = try #require(NSBitmapImageRep(cgImage: frame).representation(using: .jpeg, properties: [:]))
            try data.write(to: outputURL.deletingLastPathComponent().appendingPathComponent(name + ".jpg"))
        }
        var sampleItem = newItem
        sampleItem.timelineStart = 0
        sampleItem.transition = nil
        let sample = Timeline(storyPlanID: repaired.storyPlanID, width: repaired.width, height: repaired.height, frameRate: repaired.frameRate, items: [sampleItem])
        let sampleURL = outputURL.deletingLastPathComponent().appendingPathComponent("replacement-full.mp4")
        try? FileManager.default.removeItem(at: sampleURL)
        let samplePlayback = try await PlaybackEngine().build(timeline: sample, assets: project.assets, forceVideoComposition: true)
        let exporter = try #require(AVAssetExportSession(asset: samplePlayback.composition, presetName: AVAssetExportPreset1280x720))
        exporter.outputURL = sampleURL
        exporter.outputFileType = .mp4
        exporter.videoComposition = samplePlayback.videoComposition
        exporter.audioMix = samplePlayback.audioMix
        await exporter.export()
        #expect(exporter.status == .completed)
        let sampleDuration = try await AVURLAsset(url: sampleURL).load(.duration).seconds
        #expect(abs(sampleDuration - newItem.timelineDuration) < 1 / repaired.frameRate)
        try originalData.write(to: outputURL.deletingLastPathComponent().appendingPathComponent("input-project.json"))
        print("TEST7 BRUSH: \(target.sourceStart) -> \(newItem.sourceStart), duration \(repaired.duration); titles \(repaired.effectiveTitleItems.map(\.text))")
    }
}
