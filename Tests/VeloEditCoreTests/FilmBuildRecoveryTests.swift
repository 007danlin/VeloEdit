import Foundation
import Testing
import CoreGraphics
import AVFoundation
import ImageIO
import UniformTypeIdentifiers
@testable import VeloEditCore

private func savedBuild(_ store: ProjectStore, phase: FilmBuildDraft.Phase = .verifying) async throws -> FilmBuildDraft {
    let request = FilmBuildRequest(kind: .create, prompt: "Собери фильм", preset: .memories)
    _ = try await store.beginEditorialGeneration(prompt: request.prompt, brief: nil)
    _ = try await store.beginFilmBuildRecovery(request)
    let plan = StoryPlan(prompt: request.prompt, preset: .memories, constraints: StoryConstraints(targetDuration: 12), chapters: [])
    let source = await store.packageURL.appendingPathComponent("source.png")
    try AutonomousOperationTests.photo(at: source)
    let asset = try await MediaImporter().makeAsset(url: source)
    try await store.updateAnalysisProgress { $0.assets = [asset] }
    let timeline = Timeline(storyPlanID: plan.id, width: 320, height: 180, frameRate: 15, items: [TimelineItem(assetID: asset.id, kind: .photo, sourceDuration: 12, timelineStart: 0, timelineDuration: 12)])
    let draft = FilmBuildDraft(phase: phase, timeline: timeline, plan: plan, analyses: [], tracks: [], sourceMap: .empty, events: [], personalTaste: PersonalTasteProfile(), checkpointReason: "Before recovery")
    try await store.checkpointFilmBuild(draft, ifRevision: await store.snapshot().revision)
    return draft
}

@Test func filmBuildRecoveryReopensAndCommitsExactWinnerOnlyOnce() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let original = try ProjectStore(createAt: root, name: "Interrupted build")
    let saved = try await savedBuild(original)
    // A new actor, decoded from disk, models termination of the original run.
    let reopened = try ProjectStore(open: root)
    #expect(await reopened.recoverableFilmBuild()?.draft?.phase == .verifying)
    let progress = FilmBuildProgressRecorder()
    let pipeline = VeloEditPipeline(store: reopened)
    let completed = try await pipeline.resumeFilmBuild { await progress.record($0) }
    #expect(completed.id == saved.timeline.id)
    #expect(completed.items == saved.timeline.items)
    #expect(await reopened.manifest.timelines.count == 1)
    #expect(await reopened.manifest.filmBuildRecovery == nil)
    let stages = await progress.updates.map(\.stage)
    #expect(stages.first == .resuming && stages.contains(.verifying) && stages.last == .saving)
    let again = try ProjectStore(open: root)
    #expect(await again.recoverableFilmBuild() == nil)
    await #expect(throws: (any Error).self) { _ = try await VeloEditPipeline(store: again).resumeFilmBuild() }
    #expect(await again.manifest.timelines.count == 1)
}

@Test func filmBuildRecoveryRejectsChangedInputsButPreservesNavigation() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try ProjectStore(createAt: root, name: "Recovery revision")
    var state = ProjectWorkspaceState(prompt: "Собери фильм", preset: .memories, targetMinutes: 1)
    try await store.updateWorkspaceState(state)
    _ = try await savedBuild(store)
    state.directorDraft = "Несохранённый вопрос"
    state.feedbackDraft = "Заметка"
    try await store.updateWorkspaceState(state)
    #expect(await store.recoverableFilmBuild() != nil)
    state.prompt = "Совсем другой монтаж"
    try await store.updateWorkspaceState(state)
    #expect(await store.recoverableFilmBuild() == nil)
    let reopened = try ProjectStore(open: root)
    #expect(await reopened.recoverableFilmBuild() == nil)
    await #expect(throws: (any Error).self) { _ = try await VeloEditPipeline(store: reopened).resumeFilmBuild() }
    #expect(await reopened.manifest.timelines.isEmpty == true)
}

@Test func filmBuildRecoveryRejectsStaleCheckpointAndRetainsCancelledWork() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try ProjectStore(createAt: root, name: "Cancellation")
    let draft = try await savedBuild(store)
    let ids = await store.manifest.intentLedger!.entries.map(\.id)
    try await store.failEditorialGeneration(ids: ids, error: CancellationError())
    #expect(await store.recoverableFilmBuild()?.draft?.timeline.id == draft.timeline.id)
    let snapshot = await store.snapshot()
    try await store.update { $0.timelines.append(draft.timeline) }
    await #expect(throws: ProjectStoreError.self) {
        try await store.checkpointFilmBuild(draft, ifRevision: snapshot.revision)
    }
    #expect(await store.recoverableFilmBuild() == nil)
}

@Test func filmBuildRecoveryKeepsRequestAfterReusableAnalysisIsSaved() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try ProjectStore(createAt: root, name: "Analysis checkpoint")
    let request = FilmBuildRequest(kind: .create, prompt: "Собери фильм", preset: .memories)
    _ = try await store.beginFilmBuildRecovery(request)
    let analyses = [AnalysisResult(assetID: UUID(), analyzedContentHash: "sample", sceneTags: ["river", "forest", "sky"], candidates: [])]
    try await store.updateFilmBuildAnalyses(analyses, ifRevision: await store.snapshot().revision)
    let reopened = try ProjectStore(open: root)
    #expect(await reopened.recoverableFilmBuild()?.request == request)
    #expect(await reopened.manifest.analyses.first?.sceneTags == analyses.first?.sceneTags)
}

@Test func filmBuildProgressDrainsNestedUpdatesBeforeReturning() async throws {
    let recorder = FilmBuildProgressRecorder()
    let observer: FilmBuildProgressHandler = { await recorder.record($0) }
    try await FilmBuildReporting.$handler.withValue(observer) {
        try await FilmBuildReporting.forwarding { report in
            report(FilmBuildProgress(.previewFrames, completed: 1, total: 3))
            try await Task.sleep(for: .milliseconds(20))
            report(FilmBuildProgress(.previewFrames, completed: 3, total: 3))
        }
    }
    let updates = await recorder.updates
    #expect(updates.first?.fraction == 1.0 / 3.0)
    #expect(updates.last?.fraction == 1)
    #expect(FilmBuildProgress(.audioCheck).fraction == nil)
}

@Test func filmBuildRecoveryReusesOnlyCompletedControlExports() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let imageURL = root.appendingPathComponent("source.png")
    let context = try #require(CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 256, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: 0.1, green: 0.4, blue: 0.9, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
    let image = try #require(context.makeImage())
    let destination = try #require(CGImageDestinationCreateWithURL(imageURL as CFURL, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    let asset = MediaAsset(originalURL: imageURL, kind: .photo, byteSize: 1, contentHash: "recovery-blue", metadata: MediaMetadata(width: 64, height: 48))
    let item = TimelineItem(assetID: asset.id, kind: .photo, sourceDuration: 0.6, timelineStart: 0, timelineDuration: 0.6)
    let timeline = Timeline(storyPlanID: UUID(), width: 320, height: 180, frameRate: 15, items: [item])
    let cache = root.appendingPathComponent("Cache/Preview/DerivedMedia")
    let prober = LocalEditorialRenderedProber(maximumSamples: 4)
    let first = FilmBuildProgressRecorder()
    let frames = try await FilmBuildReporting.$handler.withValue({ await first.record($0) }) {
        try await prober.frames(timeline: timeline, assets: [asset], tracks: [], telemetry: [:], cacheURL: cache)
    }
    #expect(!frames.isEmpty && frames.allSatisfy { $0.decodeFailed != true })
    #expect(await first.updates.contains { $0.stage == .previewFrames && $0.completed == 1 })
    #expect(await first.updates.contains { $0.stage == .controlExport && $0.fraction != nil })
    let directory = cache.appendingPathComponent("EditorialControlExports")
    let output = try #require(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first { $0.pathExtension == "mp4" })
    let originalBytes = try Data(contentsOf: output)
    let originalDate = try FileManager.default.attributesOfItem(atPath: output.path)[.modificationDate] as? Date
    let resumed = FilmBuildProgressRecorder()
    let again = try await FilmBuildReporting.$handler.withValue({ await resumed.record($0) }) {
        try await prober.frames(timeline: timeline, assets: [asset], tracks: [], telemetry: [:], cacheURL: cache)
    }
    #expect(again.count == frames.count)
    #expect(try Data(contentsOf: output) == originalBytes)
    #expect(try FileManager.default.attributesOfItem(atPath: output.path)[.modificationDate] as? Date == originalDate)
    #expect(await resumed.updates.contains { $0.stage == .previewFrames && $0.detail != nil })
    #expect(await resumed.updates.filter { $0.stage == .controlExport }.allSatisfy { $0.fraction == nil })

    // A leftover/truncated file must not be accepted just because it exists.
    try Data("partial export".utf8).write(to: output, options: .atomic)
    _ = try await prober.frames(timeline: timeline, assets: [asset], tracks: [], telemetry: [:], cacheURL: cache)
    #expect(try Data(contentsOf: output).count > 100)
}

@Test func filmBuildRecoveryFailureRetainsChosenFilmInsteadOfPublishingEarlySourceFallback() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try ProjectStore(createAt: root, name: "Exact failed composition")
    var saved = try await savedBuild(store, phase: .readyForPlayback)
    let valid = saved.timeline.items[0]
    var broken = valid; broken.id = UUID(); broken.assetID = UUID(); broken.timelineStart = 12
    saved.timeline.items.append(broken)
    saved.timeline.music = MusicDirective(style: .calm, bpm: 90, volume: 0.18, trackID: UUID())
    saved.timeline.titleItems = [TitleTimelineItem(kind: .chapter, text: "Позднее событие поездки",
        startTime: 12, duration: 5, targetClipID: broken.id)]
    try await store.checkpointFilmBuild(saved, ifRevision: await store.snapshot().revision)
    let reopened = try ProjectStore(open: root)
    do {
        _ = try await VeloEditPipeline(store: reopened, renderedProber: FixtureEditorialProber()).resumeFilmBuild()
        Issue.record("A missing selected clip must fail, not deliver another film")
    } catch {
        #expect(error.localizedDescription.contains("пропущено 1"))
        #expect(error.localizedDescription.contains("Выбранный монтаж сохранён"))
    }
    let after = await reopened.manifest
    #expect(after.timelines.isEmpty)
    #expect(after.autonomousJob?.state == .failed)
    let draft = try #require(after.filmBuildRecovery?.draft)
    #expect(draft.phase == .readyForPlayback)
    #expect(draft.timeline.items == saved.timeline.items)
    #expect(draft.timeline.music == saved.timeline.music)
    #expect(draft.timeline.titleItems == saved.timeline.titleItems)
    #expect(draft.events == saved.events && draft.sourceMap == saved.sourceMap)
    let again = try ProjectStore(open: root)
    #expect(await again.recoverableFilmBuild()?.draft?.timeline.items == saved.timeline.items)
}

@Test func filmBuildRecoveryReadyPhasePreservesTheSelectedSoundtrackAndTitles() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try ProjectStore(createAt: root, name: "Exact soundtrack recovery")
    var saved = try await savedBuild(store, phase: .readyForPlayback)
    let audio = root.appendingPathComponent("music.caf")
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 96_000))
    buffer.frameLength = buffer.frameCapacity
    for i in 0..<Int(buffer.frameLength) { buffer.floatChannelData![0][i] = Float(0.1 * sin(2 * .pi * 220 * Double(i) / 48_000)) }
    try AVAudioFile(forWriting: audio, settings: format.settings).write(from: buffer)
    let track = LocalMusicTrack(title: "Selected track", author: "Fixture", bpm: 90, genres: [], moods: [], energy: 0.3,
        duration: 2, license: .userFile(), sourceProvider: .user, sourcePageURL: audio, localFileURL: audio, originalFileName: "music.caf")
    saved.tracks = [track]
    saved.timeline.music = MusicDirective(style: .calm, bpm: 90, volume: 0.18, trackID: track.id)
    saved.timeline.titleItems = [TitleTimelineItem(kind: .chapter, text: "Лесная дорога", startTime: 1, duration: 5)]
    try await store.checkpointFilmBuild(saved, ifRevision: await store.snapshot().revision)
    let reopened = try ProjectStore(open: root)
    let completed = try await VeloEditPipeline(store: reopened, renderedProber: FixtureEditorialProber()).resumeFilmBuild()
    #expect(completed.items == saved.timeline.items)
    #expect(completed.music == saved.timeline.music)
    #expect(completed.titleItems == saved.timeline.titleItems)
    let playback = try await PlaybackEngine().build(timeline: completed, assets: await reopened.manifest.assets, musicTracks: saved.tracks, forceVideoComposition: true)
    #expect(try await playback.composition.loadTracks(withMediaType: .audio).isEmpty == false)
    #expect(playback.warnings.isEmpty)
}

@Test func filmBuildRecoveryCannotCommitWithoutItsSelectedMusicOrVerification() async throws {
    struct UnavailableProber: EditorialRenderedProbing {
        func frames(timeline: Timeline, assets: [MediaAsset], tracks: [LocalMusicTrack], telemetry: [UUID: TelemetrySummary], cacheURL: URL) async throws -> [PerceptualRenderedFrameEvidence] {
            throw CocoaError(.fileReadCorruptFile)
        }
    }
    for missingMusic in [true, false] {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ProjectStore(createAt: root, name: "Unavailable verification")
        var saved = try await savedBuild(store, phase: .readyForPlayback)
        if missingMusic { saved.timeline.music = MusicDirective(style: .calm, bpm: 90, volume: 0.18, trackID: UUID()) }
        try await store.checkpointFilmBuild(saved, ifRevision: await store.snapshot().revision)
        let reopened = try ProjectStore(open: root)
        do {
            _ = try await VeloEditPipeline(store: reopened, renderedProber: UnavailableProber()).resumeFilmBuild()
            Issue.record("Recovery must not publish without the selected audio and completed verification")
        } catch {
            #expect(error.localizedDescription.contains(missingMusic ? "Музыка сохранённого монтажа недоступна" : "Не удалось проверить сохранённый монтаж"))
        }
        let after = await reopened.manifest
        #expect(after.timelines.isEmpty)
        #expect(after.filmBuildRecovery?.draft?.timeline.items == saved.timeline.items)
        #expect(after.filmBuildRecovery?.draft?.timeline.music == saved.timeline.music)
        #expect(after.autonomousJob?.state == .failed)
    }
}
