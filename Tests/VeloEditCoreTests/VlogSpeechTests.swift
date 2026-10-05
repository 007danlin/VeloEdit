import XCTest
import CoreGraphics
@testable import VeloEditCore

final class VlogSpeechTests: XCTestCase {
    private func transcript() -> SpeechTranscript {
        SpeechTranscript(localeIdentifier: "ru", words: [
            .init(text: "Мы", startTime: 1, duration: 0.3, confidence: 0.9),
            .init(text: "не", startTime: 1.4, duration: 0.2, confidence: 0.8),
            .init(text: "спешим.", startTime: 1.7, duration: 0.5, confidence: 0.9),
            .init(text: "Поехали!", startTime: 5, duration: 0.7, confidence: 0.9)
        ], sentences: [.init(text: "Мы не спешим.", startTime: 1, endTime: 2.2, confidence: 0.9), .init(text: "Поехали!", startTime: 5, endTime: 5.7, confidence: 0.9)], silenceBoundaries: [2.25...4.95], confidence: 0.9)
    }
    private func fixture() -> (Timeline, [SpeechSourceRecord]) {
        let asset = UUID()
        return (Timeline(storyPlanID: UUID(), items: [TimelineItem(assetID: asset, kind: .video, sourceDuration: 8, timelineStart: 0, timelineDuration: 8)]), [SpeechSourceRecord(assetID: asset, transcript: transcript())])
    }
    func testQuarterTurnCameraTransformUsesCoreImageCoordinates() {
        let av = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 2160, ty: 0)
        let ci = CoreImageVideoGeometry.transform(av, source: CGSize(width: 3840, height: 2160), target: CGSize(width: 2160, height: 3840))
        XCTAssertEqual(ci.a, 0); XCTAssertEqual(ci.b, -1); XCTAssertEqual(ci.c, 1); XCTAssertEqual(ci.d, 0)
        XCTAssertEqual(ci.tx, 0); XCTAssertEqual(ci.ty, 3840)
        XCTAssertEqual(CoreImageVideoGeometry.transform(.identity, source: CGSize(width: 1920, height: 1080), target: CGSize(width: 1920, height: 1080)), .identity)
    }
    func testLegacyBriefKeepsMissingPolicyAndVlogDoesNotChangeMood() throws {
        let data = try JSONEncoder().encode(DirectorBrief(mood: .dynamic))
        let decoded = try JSONDecoder().decode(DirectorBrief.self, from: data)
        XCTAssertNil(decoded.subtitlePolicy)
        XCTAssertNil(decoded.subtitleStyle)
        XCTAssertFalse(decoded.subtitlesEnabled(preset: .adventure))
        XCTAssertTrue(decoded.subtitlesEnabled(preset: .vlog))
        XCTAssertEqual(decoded.mood, .dynamic)
        XCTAssertEqual(try JSONDecoder().decode(FilmPreset.self, from: Data("\"vlog\"".utf8)), .vlog)
    }
    func testIndependentSubtitlesAndMutedSourceException() {
        var brief = DirectorBrief()
        brief = brief.applyingSubtitleCommand("убери только названия частей")
        XCTAssertEqual(brief.titlePolicy, .none)
        brief = brief.applyingSubtitleCommand("добавь субтитры")
        XCTAssertTrue(brief.subtitlesEnabled(preset: .vlog))
        brief.sourceAudioPolicy = .mute
        XCTAssertFalse(brief.subtitlesEnabled(preset: .vlog))
        brief = brief.applyingSubtitleCommand("оставь субтитры без звука")
        XCTAssertTrue(brief.subtitlesEnabled(preset: .vlog))
        XCTAssertFalse(brief.applyingSubtitleCommand("без титров").subtitlesEnabled(preset: .vlog))
    }
    func testRemovingChapterTitlesPreservesExplicitSpeechCaptionsInDeliveryContract() {
        let (timeline, records) = fixture()
        let captions = SpeechSubtitleBuilder.applying(to: timeline, records: records, enabled: true)
        let brief = DirectorBrief().applyingSubtitleCommand("убери только названия частей")
        let plan = StoryPlan(prompt: "убери только названия частей", preset: .vlog, constraints: StoryConstraints(targetDuration: 8), chapters: [], directorBrief: brief)
        let result = TimelineDeliveryContract().validateAndRepair(timeline: captions, plan: plan, assets: [], analyses: [])
        XCTAssertFalse(captions.effectiveTitleItems.isEmpty)
        XCTAssertTrue(brief.subtitlesEnabled(preset: .vlog))
        XCTAssertFalse(result.timeline.effectiveTitleItems.isEmpty, "\(result.issues)")
        XCTAssertFalse(result.issues.contains { $0.kind == .forbiddenTitles })
    }
    func testVlogUsesCaptureChronologyInsteadOfUnorderedImportedDictionary() {
        let first = MediaAsset(originalURL: URL(fileURLWithPath: "/tmp/IMG_1001.mov"), kind: .video, byteSize: 1, contentHash: "one", metadata: MediaMetadata(duration: 5, creationDate: Date(timeIntervalSince1970: 1_700_000_000), dateSource: .embeddedMetadata))
        let last = MediaAsset(originalURL: URL(fileURLWithPath: "/tmp/IMG_1002.mov"), kind: .video, byteSize: 1, contentHash: "two", metadata: MediaMetadata(duration: 5, creationDate: Date(timeIntervalSince1970: 1_700_000_060), dateSource: .embeddedMetadata))
        let plan = StoryPlan(prompt: "Влог", preset: .vlog, constraints: StoryConstraints(), chapters: [])
        let result = VlogAssembly.assemble(assets: [last, first], records: [], plan: plan)
        XCTAssertEqual(result.items.compactMap(\.assetID), [first.id, last.id])
    }
    func testOnlyConfirmedPauseBetweenCompleteSentencesIsShortened() {
        let ranges = VlogAssembly.retainedRanges(duration: 8, transcript: transcript())
        XCTAssertEqual(ranges.count, 2)
        XCTAssertGreaterThan(ranges[0].upperBound, 2.2)
        XCTAssertLessThan(ranges[1].lowerBound, 5)
        XCTAssertEqual(ranges.last?.upperBound, 8)
        var uncertain = transcript(); uncertain.silenceBoundaries = []
        XCTAssertEqual(VlogAssembly.retainedRanges(duration: 8, transcript: uncertain), [0...8])
        uncertain = transcript(); uncertain.sentences[0].text = "Ну, вот, короче"
        XCTAssertEqual(VlogAssembly.retainedRanges(duration: 8, transcript: uncertain), [0...8])
    }
    func testSubtitlesIdempotentAndKeepManualTextStyleDisablingDeletion() {
        let (timeline, records) = fixture()
        var first = SpeechSubtitleBuilder.applying(to: timeline, records: records, enabled: true)
        XCTAssertEqual(first.effectiveTitleItems.count, 2)
        XCTAssertFalse(first.effectiveTitleItems.contains { $0.activeWordHighlighting || !$0.words.isEmpty })
        first.titleItems![0].text = "Ручная правка"; first.titleItems![0].userEdited = true
        first.titleItems![0].style.fontSize = 71; first.titleItems![0].enabled = false
        let removed = first.titleItems!.removeLast(); SpeechSubtitleBuilder.suppress(removed, in: &first)
        let second = SpeechSubtitleBuilder.applying(to: first, records: records, enabled: true)
        XCTAssertEqual(second.effectiveTitleItems.count, 1)
        XCTAssertEqual(second.effectiveTitleItems[0].text, "Ручная правка")
        XCTAssertEqual(second.effectiveTitleItems[0].style.fontSize, 71)
        XCTAssertFalse(second.effectiveTitleItems[0].enabled)
        let hidden = SpeechSubtitleBuilder.applying(to: second, records: records, enabled: false)
        XCTAssertTrue(hidden.effectiveTitleItems.isEmpty)
        let restored = SpeechSubtitleBuilder.applying(to: hidden, records: records, enabled: true)
        XCTAssertEqual(restored.effectiveTitleItems[0].text, "Ручная правка")
        XCTAssertFalse(restored.effectiveTitleItems[0].enabled)
    }
    func testManualCaptionTimingSurvivesReconciliationAndRegeneration() {
        let (timeline, records) = fixture()
        var result = SpeechSubtitleBuilder.applying(to: timeline, records: records, enabled: true)
        let id = result.effectiveTitleItems[0].id
        TimelineMutationEngine.updateTitle(in: &result, id: id) { $0.startTime = 0.8; $0.duration = 1.7 }
        result = SpeechSubtitleBuilder.reconcile(result)
        XCTAssertEqual(result.effectiveTitleItems[0].startTime, 0.8, accuracy: 0.001)
        XCTAssertEqual(result.effectiveTitleItems[0].duration, 1.7, accuracy: 0.001)
        let regenerated = SpeechSubtitleBuilder.applying(to: result, records: records, enabled: true)
        XCTAssertEqual(regenerated.effectiveTitleItems[0].startTime, 0.8, accuracy: 0.001)
        XCTAssertTrue(SubtitleFileExporter.render(timeline: regenerated, format: .srt).contains("00:00:00,800 --> 00:00:02,500"))
    }
    func testChosenHighlightSurvivesRegenerationAndUsesMeasuredClockAfterSpeedAndTrim() throws {
        let (timeline, records) = fixture()
        var result = SpeechSubtitleBuilder.applying(to: timeline, records: records, enabled: true)
        let id = result.effectiveTitleItems[0].id
        TimelineMutationEngine.updateTitle(in: &result, id: id) {
            $0.templateID = "caption.social.v1"; $0.kind = .wordLevelCaptions; $0.activeWordHighlighting = true
        }
        result.titleItems![1].activeWordHighlighting = true
        result = SpeechSubtitleBuilder.applying(to: result, records: records, enabled: true)
        XCTAssertEqual(result.effectiveTitleItems[0].words.count, 3)
        let hidden = SpeechSubtitleBuilder.applying(to: result, records: records, enabled: false)
        result = SpeechSubtitleBuilder.applying(to: hidden, records: records, enabled: true)
        XCTAssertEqual(result.effectiveTitleItems[0].templateID, "caption.social.v1")
        result.items[0].timelineDuration = 6
        result.items[0].speedRamp = SpeedRamp(points: [.init(position: 0, rate: 1), .init(position: 0.5, rate: 1), .init(position: 1, rate: 3)])
        let retimed = SpeechSubtitleBuilder.reconcile(result)
        for caption in retimed.effectiveTitleItems {
            XCTAssertFalse(caption.words.isEmpty)
            for (word, source) in zip(caption.words, caption.speechAnchor!.words) {
                XCTAssertEqual(retimed.items[0].sourceTime(atTimelineTime: caption.startTime + word.start), source.startTime, accuracy: 0.001)
                XCTAssertEqual(retimed.items[0].sourceTime(atTimelineTime: caption.startTime + word.end), source.endTime, accuracy: 0.001)
            }
        }
        result.items[0].speedRamp = nil
        result.items[0].sourceStart = 1.35; result.items[0].sourceDuration = 0.9; result.items[0].timelineDuration = 0.9
        let trimmed = SpeechSubtitleBuilder.reconcile(result).effectiveTitleItems[0]
        XCTAssertTrue(trimmed.enabled, "Changing only a style must not disable a trimmed caption")
        XCTAssertEqual(trimmed.words.map(\.word), ["не", "спешим."])
        XCTAssertEqual(trimmed.words[0].start, 0, accuracy: 0.001)
        XCTAssertEqual(trimmed.words[1].end, 0.8, accuracy: 0.001)
        var edited = retimed; edited.titleItems![0].text = "Совсем другая фраза"
        XCTAssertTrue(SpeechSubtitleBuilder.reconcile(edited).effectiveTitleItems[0].words.isEmpty)
    }
    func testFilmSubtitleStyleAppliesWithoutReplacingPerCaptionManualEdits() {
        let (timeline, records) = fixture()
        var result = SpeechSubtitleBuilder.applying(to: timeline, records: records, enabled: true, style: .vlog)
        XCTAssertTrue(result.effectiveTitleItems.allSatisfy { $0.templateID == "caption.vlog.v1" })
        result.titleItems![0].text = "Исправлено вручную"; result.titleItems![0].userEdited = true
        let changed = SpeechSubtitleBuilder.applying(to: result, records: records, enabled: true, style: .social)
        XCTAssertEqual(changed.effectiveTitleItems[0].text, "Исправлено вручную")
        XCTAssertEqual(changed.effectiveTitleItems[0].templateID, "caption.vlog.v1")
        XCTAssertEqual(changed.effectiveTitleItems[1].templateID, "caption.social.v1")
        XCTAssertEqual(changed.effectiveTitleItems[1].words.first?.word, "Поехали!")
        XCTAssertTrue(changed.effectiveTitleItems[1].activeWordHighlighting)
    }
    func testTrimAndSplitPublishOnlyRetainedWholeWords() {
        let (timeline, records) = fixture()
        var value = SpeechSubtitleBuilder.applying(to: timeline, records: records, enabled: true)
        let original = value.items[0]
        value.items[0].sourceStart = 1.35; value.items[0].sourceDuration = 0.9; value.items[0].timelineDuration = 0.9
        let trimmed = SpeechSubtitleBuilder.reconcile(value)
        XCTAssertEqual(trimmed.effectiveTitleItems.count, 1)
        XCTAssertEqual(trimmed.effectiveTitleItems[0].text, "не спешим.")
        var right = original; right.id = UUID(); right.sourceStart = 4; right.sourceDuration = 4; right.timelineStart = 4; right.timelineDuration = 4
        value = SpeechSubtitleBuilder.applying(to: timeline, records: records, enabled: true)
        value.items[0].sourceDuration = 4; value.items[0].timelineDuration = 4; value.items.append(right)
        let split = SpeechSubtitleBuilder.reconcile(value)
        XCTAssertEqual(split.effectiveTitleItems.count, 2)
        XCTAssertEqual(Set(split.effectiveTitleItems.map(\.targetClipID)).count, 2)
        value.items[0].reversePlayback = true
        XCTAssertEqual(SpeechSubtitleBuilder.reconcile(value).effectiveTitleItems.count, 1)
    }
    func testTrimDoesNotPublishUnalignedManualTextFromRemovedSpeech() {
        let (timeline, records) = fixture()
        var edited = SpeechSubtitleBuilder.applying(to: timeline, records: records, enabled: true)
        edited.titleItems![0].text = "Ручная исправленная фраза"; edited.titleItems![0].userEdited = true
        edited.items[0].sourceStart = 1.35; edited.items[0].sourceDuration = 0.9; edited.items[0].timelineDuration = 0.9
        let trimmed = SpeechSubtitleBuilder.reconcile(edited)
        XCTAssertEqual(trimmed.effectiveTitleItems[0].text, "Ручная исправленная фраза")
        XCTAssertFalse(trimmed.effectiveTitleItems[0].enabled)
        XCTAssertFalse(SubtitleFileExporter.render(timeline: trimmed, format: .srt).contains("Ручная"))
    }
    func testPiecewiseSpeedMapAndTransitionExportClock() throws {
        let (timeline, _) = fixture()
        var value = timeline; value.items[0].timelineDuration = 6
        value.items[0].speedRamp = SpeedRamp(points: [.init(position: 0, rate: 1), .init(position: 0.5, rate: 1), .init(position: 1, rate: 3)])
        let time = try XCTUnwrap(SpeechTimeMap.timelineTime(sourceTime: 4, item: value.items[0]))
        XCTAssertEqual(time, 4, accuracy: 0.0001)
        XCTAssertEqual(value.items[0].sourceTime(atTimelineTime: time), 4, accuracy: 0.0001)
        var second = timeline.items[0]; second.id = UUID(); second.timelineStart = 6
        second.transition = TransitionStyle.crossDissolve.rawValue
        value.items.append(second)
        let anchor = SpeechCaptionAnchor(key: "test", assetID: second.assetID!, sourceStart: 1, sourceEnd: 2, words: [])
        let mapped = try XCTUnwrap(SpeechTimeMap.playbackRange(anchor: anchor, item: second, timeline: value))
        XCTAssertEqual(mapped.lowerBound, 6 - 0.65 + 1, accuracy: 0.002)
        var title = TitleTimelineItem(kind: .automaticSubtitles, text: "Не спешим", startTime: 7, duration: 1, targetClipID: second.id)
        title.speechAnchor = anchor; value.titleItems = [title]
        let srt = SubtitleFileExporter.render(timeline: value, format: .srt)
        XCTAssertTrue(srt.contains("00:00:06,350 --> 00:00:07,350"), srt)
        XCTAssertTrue(SubtitleFileExporter.render(timeline: value, format: .vtt).hasPrefix("WEBVTT\n"))
    }
    func testVlogBuildRunsSpeechWithoutVisualCandidatesAndKeepsExactDurationUnmet() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vlog-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let video = root.appendingPathComponent("voice.mp4")
        let process = Process(); process.executableURL = MediaCompatibility.converterURL
        process.arguments = ["-v", "error", "-y", "-f", "lavfi", "-i", "color=c=blue:s=160x90:r=30", "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000", "-t", "8", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", video.path]
        try process.run(); process.waitUntilExit(); XCTAssertEqual(process.terminationStatus, 0)
        let asset = try await MediaImporter().makeAsset(url: video)
        let store = try ProjectStore(createAt: root.appendingPathComponent("test.veloedit"), name: "Vlog test")
        try await store.update { project in project.assets = [asset]; project.preferences.aiPowerMode = .fast }
        let speech = CountingSpeech(transcript: transcript())
        let pipeline = VeloEditPipeline(store: store, speechRecognizer: speech)
        let brief = DirectorBrief(requestedDuration: 3, musicPolicy: .none, sourceAudioPolicy: .preserve, durationMode: .exact, effectsPolicy: DirectorEffectsPolicy.none, subtitleStyle: .social)
        let result = try await pipeline.createFilm(prompt: "Стиль: Влог", preset: .vlog, directorBrief: brief)
        let calls = await speech.calls
        XCTAssertEqual(calls, 1)
        XCTAssertFalse(result.effectiveTitleItems.isEmpty)
        XCTAssertTrue(result.effectiveTitleItems.allSatisfy { $0.templateID == "caption.social.v1" && $0.activeWordHighlighting })
        XCTAssertEqual(result.speechRecords?.count, 1)
        XCTAssertGreaterThan(result.duration, 3)
        XCTAssertTrue(result.items.allSatisfy { $0.speed == 1 })
        XCTAssertFalse(result.filmDeliveryReport?.warnings.contains { $0.contains("Не подтверждена инструкция") } == true)
        XCTAssertTrue(result.filmDeliveryReport?.warnings.contains { $0.contains("длительность") } == true)
        let project = await pipeline.snapshot()
        XCTAssertFalse(project.analyses.flatMap(\.candidates).isEmpty)
        var muted = brief; muted.sourceAudioPolicy = .mute
        let hidden = try await pipeline.enforceDirectorBrief(muted)
        XCTAssertTrue(hidden.effectiveTitleItems.isEmpty)
        let restored = try await pipeline.applySpeechCaptionSettings(muted.applyingSubtitleCommand("оставь субтитры без звука"))
        XCTAssertFalse(restored.effectiveTitleItems.isEmpty)
        let finalCalls = await speech.calls
        XCTAssertEqual(finalCalls, 1)
    }

    func testCorruptModelAndTraversalAreRejected() async throws {
        let manifest = try SpeechPackageManifest.bundled()
        XCTAssertEqual(manifest.totalBytes, 632068998)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SpeechAssetStore(root: root)
        do { try await store.verify(root, manifest: manifest); XCTFail("Missing model accepted") } catch {}
        var entry = manifest.files[0]; entry.path = "../escape"
        XCTAssertThrowsError(try manifest.validatedFileURL(entry, in: root))
    }
}

private actor CountingSpeech: LocalSpeechRecognizing {
    nonisolated let modelIdentifier = "test-local-speech"
    let transcript: SpeechTranscript
    var calls = 0
    init(transcript: SpeechTranscript) { self.transcript = transcript }
    func transcribe(url: URL, localeIdentifier: String?) async throws -> SpeechTranscript? { calls += 1; return transcript }
}
