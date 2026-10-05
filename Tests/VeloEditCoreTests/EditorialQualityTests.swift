import Foundation
import AVFoundation
import Testing
@testable import VeloEditCore

@Suite(.serialized) struct EditorialQualityTests {
    private func track(_ url: URL, duration: Double = 30) -> LocalMusicTrack {
        .init(title: "Independent fixture", author: "Fixture", bpm: 110, genres: ["disco"], moods: ["bright", "grooving"], energy: 0.78,
              duration: duration, license: .userFile(), sourceProvider: .user, sourcePageURL: url, localFileURL: url, originalFileName: url.lastPathComponent)
    }

    private func movie(_ track: LocalMusicTrack, duration: Double = 12) -> Timeline {
        Timeline(storyPlanID: UUID(), width: 160, height: 90, frameRate: 30,
                 items: [.init(kind: .title, sourceDuration: duration, timelineStart: 0, timelineDuration: duration, title: "Window")],
                 music: .init(style: .energetic, bpm: 110, volume: 0.4, trackID: track.id), audioDucking: .init(enabled: false))
    }

    @Test func shortDynamicFilmUsesAudibleWindowAndKeepsEveryVideoParameter() throws {
        let track = track(URL(fileURLWithPath: "/tmp/fixture.caf"))
        var source = movie(track)
        source.originalAudioVolume = 0.2
        source.titleItems = [.init(kind: .chapter, text: "Поездка на багги", startTime: 0, duration: 4)]
        let structure = MusicStructure(bpm: 110, beatInterval: 60 / 110, sections: [
            .init(kind: .intro, start: 0, duration: 10, energy: 0.01),
            .init(kind: .chorus, start: 10, duration: 16, energy: 0.8),
            .init(kind: .outro, start: 26, duration: 4, energy: 0.02)
        ], quietRanges: [0...9.8, 26...30], phraseBoundaries: [10, 18, 26], tempoConfidence: 0.8, phraseConfidence: 0.8, analysisIsMeasured: true)
        let after = SoundtrackEditorialPolicy.applying(track: track, structure: structure, to: source)
        #expect((after.music?.sourceStart ?? 0) >= 10)
        #expect(after.items == source.items)
        #expect(after.titleItems == source.titleItems)
        #expect(after.duration == source.duration)
        #expect(after.originalAudioVolume == 0.2)
        #expect(after.music?.selectionEvidence?.characterConfidence == nil)
    }

    @Test func unmeasuredRhythmDoesNotTrimFilmOrPretendToKnowCharacter() {
        let track = track(URL(fileURLWithPath: "/tmp/fixture.caf"))
        let source = movie(track)
        let fallback = MusicSyncEngine().analyze(bpm: 110, duration: 30)
        let after = MusicBeatSynchronizer().synchronize(source, to: track, analyzedStructure: fallback)
        #expect(after.items == source.items)
        #expect(SoundtrackEditorialPolicy.window(track: track, structure: fallback, timeline: source).sourceStart == 0)
        #expect(fallback.tempoConfidence == 0)
    }

    @Test func styleSignalsPersistAreScopedAndCanBeRemovedWithoutNegativeResidue() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ExplicitEditorialPreferenceStore(url: root.appendingPathComponent("preferences.json"))
        let track = track(root.appendingPathComponent("track.caf")), project = UUID()
        let source = movie(track)
        let vote = ExplicitEditorialPreference(aspect: .music, scope: .mood, projectID: project, timeline: source, track: track, value: -1)
        try await store.record([vote])
        let reloaded = await ExplicitEditorialPreferenceStore(url: store.url).snapshot()
        #expect(reloaded.musicAdjustment(track, style: .energetic) < 0)
        #expect(reloaded.musicAdjustment(track, style: .calm) == 0)
        #expect(!reloaded.excludes(track))
        let ban = ExplicitEditorialPreference(aspect: .music, scope: .track, projectID: project, timeline: source, track: track, excluded: true)
        try await store.record([ban])
        #expect(await store.snapshot().excludes(track))
        try await store.remove(ids: [vote.id, ban.id])
        #expect(await store.snapshot().signals.isEmpty)
    }

    @Test func localDurationUsesOnlyOneNeighbourAndRespectsLocksAndAnalysis() throws {
        let asset = UUID()
        let candidates = (0..<3).map { index -> Candidate in
            let start = Double(index * 20)
            var insights = CandidateInsights(sceneSummary: "Scene \(index)")
            insights.editorialEvidence = .init(usableRange: .init(start: start, end: start + 12), informationGain: 0.5, confidence: 0.9)
            return Candidate(assetID: asset, sourceStart: start, sourceDuration: 12, scores: .init(quality: 0.9, interest: 0.9, action: 0.5, stability: 0.9), insights: insights)
        }
        let items = candidates.enumerated().map { i, c in TimelineItem(candidateID: c.id, assetID: asset, kind: .video, sourceStart: c.sourceStart, sourceDuration: 4, timelineStart: Double(i * 4), timelineDuration: 4) }
        let before = Timeline(storyPlanID: UUID(), items: items)
        let project = ProjectManifest(name: "Local", analyses: [.init(assetID: asset, analyzedContentHash: "fixture", sceneTags: [], candidates: candidates)])
        let edit = try LocalEditorialEditPlanner.duration(itemID: items[0].id, longer: true, timeline: before, project: project)
        #expect(edit.after.duration == before.duration)
        #expect(edit.after.items[0].timelineDuration > 4)
        #expect(edit.after.items[1].timelineDuration < 4)
        #expect(edit.after.items[2] == before.items[2])
        #expect(edit.affectedItemIDs == Array(items.prefix(2)).map(\.id))
        var connected = before
        connected.telemetryItems = [.init(targetClipID: items[1].id, linkedAssetID: asset, sourceStart: 20, timelineStart: 4, timelineDuration: 4)]
        connected.titleItems = [.init(kind: .chapter, text: "Реакция", startTime: 4, duration: 2, targetClipID: items[1].id)]
        let linkedEdit = try LocalEditorialEditPlanner.duration(itemID: items[0].id, longer: true, timeline: connected, project: project)
        #expect(linkedEdit.after.effectiveTelemetryItems[0].timelineStart == linkedEdit.after.items[1].timelineStart)
        #expect(linkedEdit.after.effectiveTelemetryItems[0].timelineDuration == linkedEdit.after.items[1].timelineDuration)
        #expect(linkedEdit.after.effectiveTelemetryItems[0].sourceStart == 20)
        #expect(linkedEdit.after.effectiveTitleItems[0].startTime == linkedEdit.after.items[1].timelineStart)
        #expect(linkedEdit.after.items[2] == before.items[2])
        connected.telemetryItems?[0].locked = true
        #expect(throws: LocalEditorialEditError.self) { try LocalEditorialEditPlanner.duration(itemID: items[0].id, longer: true, timeline: connected, project: project) }
        var locked = before; locked.items[1].locked = true
        #expect(throws: LocalEditorialEditError.self) { try LocalEditorialEditPlanner.duration(itemID: items[0].id, longer: true, timeline: locked, project: project) }
    }

    @Test func completedReactionCannotBeShortenedByLocalEdit() {
        let asset = UUID()
        var candidate = Candidate(assetID: asset, sourceStart: 0, sourceDuration: 10, scores: .init(quality: 0.9, interest: 0.9, action: 0.5, stability: 0.9))
        candidate.momentBoundary = .init(anticipationStart: 0, peakTime: 4, reactionEnd: 9.8, completionEnd: 10, confidence: 0.9)
        let required = EditorialMomentPolicy.protectedRange(EditorialUnit(candidate: candidate))
        #expect(required?.end == 10)
        #expect(AutomaticEditorialAssembly.protected(EditorialUnit(candidate: candidate)))
    }

    @Test func musicCommitPersistsOneUndoCheckpointAndRejectsAnOlderClient() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".veloedit")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ProjectStore(createAt: root, name: "Undo")
        let track = track(root.appendingPathComponent("track.caf"))
        let before = try JSONDecoder.veloEdit.decode(Timeline.self, from: JSONEncoder.veloEdit.encode(movie(track)))
        try await store.update { $0.timelines = [before] }
        let library = LocalMusicLibrary(rootURL: store.musicLibraryURL)
        let pipeline = VeloEditPipeline(store: store, musicLibrary: library, musicSystem: MusicLibrary(localLibrary: library, providers: []))
        var after = before; after.music?.sourceStart = 10
        #expect(try await pipeline.commitLatestTimeline(after, clientRevision: 2, checkpointReason: "Другая музыка"))
        #expect(try await !pipeline.commitLatestTimeline(before, clientRevision: 1, checkpointReason: "Устаревшая правка"))
        let reopened = try ProjectStore(open: root)
        let saved = await reopened.manifest
        #expect(saved.timelineCheckpoints?.count == 1)
        #expect(saved.timelineCheckpoints?.first?.timeline == before)
        #expect(saved.timelines.last == after)
    }

    @Test func audioContentReplacementInvalidatesCacheEvenWithSameSizeAndTimestamp() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("audio.caf")
        try writeAudio(url, silentPrefix: 10)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let track = track(url)
        let cache = MusicStructureCache()
        let first = await cache.structure(for: track)
        let renderTimeline = movie(track)
        let stableRenderKey = EditorialRenderDependencies.signature(timeline: renderTimeline, assets: [], tracks: [track])
        try writeAudio(url, silentPrefix: 0)
        try FileManager.default.setAttributes([.modificationDate: attributes[.modificationDate]!], ofItemAtPath: url.path)
        #expect((try FileManager.default.attributesOfItem(atPath: url.path))[.size] as? NSNumber == attributes[.size] as? NSNumber)
        let second = await cache.structure(for: track)
        #expect(first != second)
        #expect(stableRenderKey != EditorialRenderDependencies.signature(timeline: renderTimeline, assets: [], tracks: [track]))
    }

    @Test func unavailableExactSongCannotBeReplacedByAnAutomaticFallback() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("audio.caf")
        try writeAudio(url, silentPrefix: 0)
        let library = LocalMusicLibrary(rootURL: root.appendingPathComponent("library"))
        _ = try await library.importUserTrack(url)
        let system = MusicLibrary(localLibrary: library, providers: [])
        let intent = MusicIntent(directive: .init(style: .energetic, bpm: 110,
            searchRequests: [.init(query: "An unavailable exact recording", exactTrack: true)]))
        let result = await system.resolve(intent)
        #expect(result.track == nil)
        #expect(!result.failures.isEmpty)
        let store = try ProjectStore(createAt: root.appendingPathComponent("film.veloedit"), name: "Exact song")
        let before = try JSONDecoder.veloEdit.decode(Timeline.self, from: JSONEncoder.veloEdit.encode(movie(track(url))))
        try await store.update { $0.timelines = [before] }
        let pipeline = VeloEditPipeline(store: store, musicLibrary: library, musicSystem: system)
        do {
            try await pipeline.updateMusic(.init(style: .energetic, bpm: 110,
                searchRequests: [.init(query: "An unavailable exact recording", exactTrack: true)]))
            Issue.record("Exact missing song must not silently replace the current soundtrack")
        } catch is DirectorBriefFulfillmentError { }
        #expect(await store.manifest.timelines.last == before)
    }

    @Test func selectedMusicStartIsActuallyDecodedByPreviewAndExport() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("audio.caf")
        try writeAudio(url, silentPrefix: 10)
        let track = track(url)
        var timeline = movie(track, duration: 4)
        timeline.music?.sourceStart = 12
        let playback = try await PlaybackEngine().build(timeline: timeline, assets: [], musicTracks: [track])
        let audio = try #require(playback.composition.tracks(withMediaType: .audio).first)
        #expect(abs(audio.segments[0].timeMapping.source.start.seconds - 12) < 0.01)
        let exported = root.appendingPathComponent("window.mp4")
        _ = try await RenderEngine().render(timeline: timeline, assets: [], musicTracks: [track], quality: .maximum, destination: exported)
        let decoded = try await LocalAudioAnalyzer().analyze(url: exported, level: .deep)
        #expect((decoded?.waveform.max() ?? 0) > 0.01)
        #expect(abs(try await AVURLAsset(url: exported).load(.duration).seconds - 4) < 0.04)
    }

    private func writeAudio(_ url: URL, silentPrefix: Double) throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 240_000))
        buffer.frameLength = buffer.frameCapacity
        for i in 0..<Int(buffer.frameLength) {
            let t = Double(i) / 8_000
            buffer.floatChannelData![0][i] = t < silentPrefix ? 0 : Float(0.2 * sin(2 * .pi * 440 * t))
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }
}
