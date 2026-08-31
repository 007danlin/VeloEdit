import Foundation
import AVFoundation
import Testing
@testable import VeloEditCore

@Test func musicRequestSelectsMoodAndRespectsOptOut() {
    let interpreter = MusicPromptInterpreter()
    let generic = interpreter.interpret(prompt: "сделай музыку", preset: .story)
    let energetic = interpreter.interpret(prompt: "Добавь энергичную музыку с драйвом", preset: .story)
    #expect(generic == MusicDirective(style: .acoustic, bpm: 94))
    #expect(energetic?.style == .energetic)
    #expect(energetic?.bpm == 118)
    #expect(interpreter.interpret(prompt: "энергичный сайндтрек", preset: .adventure)?.style == .energetic)
    #expect(interpreter.interpret(prompt: "Сделай динамично, но без музыки", preset: .adventure) == nil)
    #expect(interpreter.interpret(
        prompt: "Сделай динамично, но без музыки",
        preset: .adventure,
        automaticDefault: true
    ) == nil)
    #expect(interpreter.interpret(prompt: "Сделай связный фильм", preset: .cinematic) == nil)
    #expect(interpreter.interpret(
        prompt: "Сделай связный фильм",
        preset: .cinematic,
        automaticDefault: true
    )?.style == .cinematic)
    #expect(interpreter.interpret(
        prompt: "Собери лучшие моменты",
        preset: .adventure,
        automaticDefault: true
    )?.style == .cinematic)
    #expect(interpreter.interpret(
        prompt: "Собери фильм\nРаспознано в кадре: bike cycling forest",
        preset: .story,
        automaticDefault: true
    )?.style == .acoustic)
    #expect(interpreter.interpret(
        prompt: "Собери фильм из high-speed гонки",
        preset: .story,
        automaticDefault: true
    )?.style == .energetic)
    #expect(interpreter.interpret(
        prompt: "Добавь спокойную музыку\nРаспознано в кадре: bike cycling",
        preset: .story,
        automaticDefault: true
    )?.style == .calm)
}

@Test func originalAudioInstructionIsExecutableAndLatestCommandWins() {
    let interpreter = OriginalAudioPromptInterpreter()
    #expect(interpreter.volume(prompt: "убери звук исходный у видео") == 0)
    #expect(interpreter.volume(prompt: "без звука исходников") == 0)
    #expect(interpreter.volume(prompt: "убери звук исходный у видео, потом верни звук исходников") == 1)
    #expect(interpreter.volume(prompt: "сделай монтаж динамичнее") == nil)
}

@Test func editorCatalogValuesSurviveProjectEncoding() throws {
    let item = TimelineItem(
        kind: .video,
        sourceDuration: 4,
        timelineStart: 0,
        timelineDuration: 4,
        transition: TransitionStyle.wipeLeft.rawValue,
        effect: ClipEffect.zoomIn.rawValue
    )
    let timeline = Timeline(
        storyPlanID: UUID(),
        items: [item],
        music: MusicDirective(style: .cinematic, bpm: 82),
        originalAudioVolume: 0
    )
    let data = try JSONEncoder.veloEdit.encode(timeline)
    let decoded = try JSONDecoder.veloEdit.decode(Timeline.self, from: data)
    #expect(decoded.items.first?.transition == TransitionStyle.wipeLeft.rawValue)
    #expect(decoded.items.first?.effect == ClipEffect.zoomIn.rawValue)
    #expect(decoded.music?.style == .cinematic)
    #expect(decoded.effectiveOriginalAudioVolume == 0)
}

@Test func clipAdjustmentsSurviveEncodingAndOldItemsUseNeutralDefaults() throws {
    let adjusted = TimelineItem(
        kind: .video,
        sourceDuration: 4,
        timelineStart: 0,
        timelineDuration: 2,
        speed: 2,
        videoAdjustments: VideoAdjustments(crop: .fit, rotationQuarterTurns: 1, filter: .noir, brightness: 0.1),
        audioAdjustments: AudioAdjustments(volume: 0.4, fadeIn: 0.5, fadeOut: 0.75)
    )
    let decoded = try JSONDecoder.veloEdit.decode(
        TimelineItem.self,
        from: JSONEncoder.veloEdit.encode(adjusted)
    )
    #expect(decoded.speed == 2)
    #expect(decoded.effectiveVideoAdjustments.crop == .fit)
    #expect(decoded.effectiveVideoAdjustments.rotationQuarterTurns == 1)
    #expect(decoded.effectiveVideoAdjustments.filter == .noir)
    #expect(decoded.effectiveAudioAdjustments.volume == 0.4)

    var oldObject = try #require(JSONSerialization.jsonObject(with: JSONEncoder.veloEdit.encode(adjusted)) as? [String: Any])
    oldObject.removeValue(forKey: "videoAdjustments")
    oldObject.removeValue(forKey: "audioAdjustments")
    oldObject.removeValue(forKey: "titleStyle")
    let oldDecoded = try JSONDecoder.veloEdit.decode(
        TimelineItem.self,
        from: JSONSerialization.data(withJSONObject: oldObject)
    )
    #expect(oldDecoded.effectiveVideoAdjustments.crop == .fit)
    #expect(oldDecoded.effectiveVideoAdjustments.isNeutral)
    #expect(oldDecoded.effectiveAudioAdjustments.isNeutral)
}

@Test func viewerToolAdjustmentsSurviveEncodingAndTriggerRealMediaProcessing() throws {
    let video = VideoAdjustments(
        filter: .vivid,
        tint: 0.2,
        filterIntensity: 0.65,
        stabilization: 0.4,
        rollingShutterCorrection: true,
        smoothSlowMotion: true
    )
    let audio = AudioAdjustments(
        volume: 1.15,
        noiseReduction: 0.45,
        eqPreset: .voice,
        normalize: true,
        duckOthers: true,
        duckingAmount: 0.6,
        preservePitch: false,
        effect: .room
    )
    let item = TimelineItem(
        kind: .video,
        sourceDuration: 6,
        timelineStart: 0,
        timelineDuration: 12,
        speed: 0.5,
        videoAdjustments: video,
        audioAdjustments: audio
    )
    let decoded = try JSONDecoder.veloEdit.decode(TimelineItem.self, from: JSONEncoder.veloEdit.encode(item))
    #expect(decoded.effectiveVideoAdjustments.tint == 0.2)
    #expect(decoded.effectiveVideoAdjustments.filterIntensity == 0.65)
    #expect(decoded.effectiveVideoAdjustments.stabilization == 0.4)
    #expect(decoded.effectiveVideoAdjustments.rollingShutterCorrection == true)
    #expect(decoded.effectiveVideoAdjustments.smoothSlowMotion == true)
    #expect(decoded.effectiveAudioAdjustments.normalize == true)
    #expect(decoded.effectiveAudioAdjustments.duckOthers == true)
    #expect(decoded.effectiveAudioAdjustments.duckingAmount == 0.6)
    #expect(decoded.effectiveAudioAdjustments.preservePitch == false)
    #expect(decoded.effectiveAudioAdjustments.effect == .room)
    #expect(AdjustedClipGenerator.needsRender(decoded.effectiveVideoAdjustments))
    #expect(ProcessedAudioGenerator.needsRender(decoded.effectiveAudioAdjustments))
}

@Test func processedAudioRenderingStartsAndProducesSamples() async throws {
    let temporaryDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("veloedit-audio-render-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

    let sourceURL = temporaryDirectory.appendingPathComponent("source.m4a")
    let destinationURL = temporaryDirectory.appendingPathComponent("processed.caf")
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2))
    let frameCount: AVAudioFrameCount = 44_100
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
    buffer.frameLength = frameCount
    let samples = try #require(buffer.floatChannelData)
    for channel in 0..<2 {
        for frame in 0..<Int(frameCount) {
            samples[channel][frame] = sin(Float(frame) * 2 * .pi * 440 / 44_100) * 0.2
        }
    }
    var source: AVAudioFile? = try AVAudioFile(forWriting: sourceURL, settings: [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: 44_100,
        AVNumberOfChannelsKey: 2,
        AVEncoderBitRateKey: 128_000,
    ])
    try source?.write(from: buffer)
    source = nil

    let output = try await ProcessedAudioGenerator().generate(
        sourceURL: sourceURL,
        sourceStart: 0,
        sourceDuration: 0.25,
        adjustments: AudioAdjustments(noiseReduction: 0.25),
        destination: destinationURL
    )
    let attributes = try FileManager.default.attributesOfItem(atPath: output.path)
    #expect((attributes[.size] as? NSNumber)?.intValue ?? 0 > 4_096)
    #expect(try await AVURLAsset(url: output).load(.duration).seconds > 0.2)
}

@Test func oldExtendedAdjustmentsDecodeWithNeutralViewerToolDefaults() throws {
    let videoJSON = Data(#"{"crop":"fill","rotationQuarterTurns":0,"filter":"none","brightness":0,"contrast":1,"saturation":1,"warmth":0,"opacity":1}"#.utf8)
    let audioJSON = Data(#"{"volume":1,"muted":false,"fadeIn":0,"fadeOut":0}"#.utf8)
    let video = try JSONDecoder.veloEdit.decode(VideoAdjustments.self, from: videoJSON)
    let audio = try JSONDecoder.veloEdit.decode(AudioAdjustments.self, from: audioJSON)
    // `fill` is now an explicit crop. Projects without a crop use `.fit`, so
    // an older serialized fill value must remain intentional and must not be
    // discarded as a neutral adjustment.
    #expect(video.crop == .fill)
    #expect(!video.isNeutral)
    #expect(audio.isNeutral)
    #expect(video.filterIntensity ?? 1 == 1)
    #expect(audio.preservePitch ?? true)
    #expect((audio.effect ?? AudioEffect.none) == AudioEffect.none)
}

@Test func extendedImageAudioAndSpeedRampCommandsAreExecutable() {
    let source = TimelineItem(kind: .video, sourceDuration: 8, timelineStart: 0, timelineDuration: 8)
    let timeline = Timeline(storyPlanID: UUID(), items: [source])
    let commands = EditorCommandParser().parse(
        "Первый клип: добавь speed ramp, экспозиция +0.7, добавь виньетку, пленочное зерно, убери шум и EQ для голоса"
    )
    #expect(commands.contains(.setSpeedRamp(.action, .first)))
    #expect(commands.contains(.setExposure(0.7, .first)))
    #expect(commands.contains(.setVignette(0.45, .first)))
    #expect(commands.contains(.setGrain(0.3, .first)))
    #expect(commands.contains(.setNoiseReduction(0.65, .first)))
    #expect(commands.contains(.setEQ(.voice, .first)))

    let result = EditorCommandExecutor().apply(commands, to: timeline)
    let item = result.timeline.items[0]
    #expect(result.report.hasChanges)
    #expect(item.speedRamp == .action)
    #expect(item.timelineDuration > item.sourceDuration)
    #expect(item.effectiveVideoAdjustments.exposure == 0.7)
    #expect(item.effectiveVideoAdjustments.vignette == 0.45)
    #expect(item.effectiveVideoAdjustments.grain == 0.3)
    #expect(item.effectiveAudioAdjustments.noiseReduction == 0.65)
    #expect(item.effectiveAudioAdjustments.eqPreset == .voice)
    #expect(ProcessedAudioGenerator.needsRender(item.effectiveAudioAdjustments))
}

@Test func expandedCatalogContainsRequestedMotionAndTransitions() {
    #expect(Set(ClipEffect.allCases).isSuperset(of: [.kenBurns, .zoomIn, .zoomOut, .pushIn, .pullOut, .panLeft, .panRight]))
    #expect(Set(TransitionStyle.allCases).isSuperset(of: [.crossDissolve, .fade, .fadeThroughBlack, .blurDissolve, .lightFlash, .wipeLeft, .wipeRight]))
}

@Test func transitionPlaybackClockMapsBackToVisibleTimelineBoundaries() {
    let first = TimelineItem(
        kind: .video,
        sourceDuration: 4,
        timelineStart: 0,
        timelineDuration: 4
    )
    let second = TimelineItem(
        kind: .video,
        sourceDuration: 5,
        timelineStart: 4,
        timelineDuration: 5,
        transition: TransitionStyle.crossDissolve.rawValue
    )
    let items = TimelineTiming.retimed([first, second])
    let overlap = TimelineTiming.transitionOverlap(incoming: items[1], previous: items[0])
    #expect(overlap == 0.65)

    let boundaryPlaybackTime = TimelineTiming.playbackTime(forTimelineTime: 4, items: items)
    #expect(abs(boundaryPlaybackTime - 3.35) < 0.0001)
    #expect(abs(TimelineTiming.timelineTime(forPlaybackTime: boundaryPlaybackTime, items: items) - 4) < 0.0001)

    let laterTimelineTime = 7.25
    let mapped = TimelineTiming.playbackTime(forTimelineTime: laterTimelineTime, items: items)
    #expect(abs(TimelineTiming.timelineTime(forPlaybackTime: mapped, items: items) - laterTimelineTime) < 0.0001)
}

@Test func shortTimelineRegionsKeepTheirRealDuration() {
    let clips = TimelineTiming.retimed([
        TimelineItem(kind: .video, sourceDuration: 0.2, timelineStart: 0, timelineDuration: 0.2),
        TimelineItem(kind: .video, sourceDuration: 0.3, timelineStart: 0.2, timelineDuration: 0.3)
    ])
    #expect(clips[0].timelineStart == 0)
    #expect(abs(clips[1].timelineStart - 0.2) < 0.0001)
    #expect(abs((clips[1].timelineStart + clips[1].timelineDuration) - 0.5) < 0.0001)
}

@Test func telemetryCommandCreatesRenderableTimelineIntent() {
    let source = TimelineItem(kind: .video, sourceDuration: 5, timelineStart: 0, timelineDuration: 5)
    let timeline = Timeline(storyPlanID: UUID(), items: [source])
    let commands = EditorCommandParser().parse("На первом клипе покажи телеметрию GPS, скорость, высоту и перегрузку")
    let result = EditorCommandExecutor().apply(commands, to: timeline)
    let settings = result.timeline.items[0].telemetryOverlay
    #expect(settings?.metrics.contains(.speed) == true)
    #expect(settings?.metrics.contains(.route) == true)
    #expect(settings?.metrics.contains(.altitude) == true)
    #expect(settings?.metrics.contains(.gForce) == true)
}

@Test func freeToUseProviderUsesTheOfficialAPIAndStoresAttribution() {
    #expect(FreeToUseMusicProvider.apiBaseURL.absoluteString == "https://api.freetouse.com/v3")
    let license = MusicLicenseRecord.freeToUse(title: "Run", author: "Artist")
    #expect(license.name == "Free To Use — Free License")
    #expect(license.attributionText?.contains("Run by Artist") == true)
    #expect(license.usageRestrictions?.contains("Коммерческий") == true)
}

@Test func freeToUseTrackDecodesOfficialTupleMetadata() throws {
    let json = #"{"id":"4054d29b-7793-3b82-2a28-bc2802323c1c","title":"Okay Energy","genre":"Electronic","is_premium":false,"duration":132,"waveform":[70,80,90],"artists":[[0,{"id":"artist-id","name":"Aylex"}]],"categories":[[0,{"id":"category-id","name":"Party"}]],"tags":[[1,"energetic"]],"files":{"mp3":"https://data.freetouse.com/music/tracks/id/file/mp3/file.mp3"}}"#
    let track = try JSONDecoder().decode(FreeToUseRemoteTrack.self, from: Data(json.utf8))
    #expect(track.author == "Aylex")
    #expect(track.categories.map(\.name) == ["Party"])
    #expect(track.tags == ["energetic"])
    #expect(track.estimatedBPM == 128)
    #expect(track.sourcePageURL.host == "freetouse.com")
}

@Test func localMusicSelectorUsesMoodBPMEnergyAndCanExcludeCurrentTrack() throws {
    let existingFile = URL(fileURLWithPath: #filePath)
    let source = URL(string: "https://freetouse.com/music/artist/calm")!
    let calm = LocalMusicTrack(
        title: "Calm", author: "A", bpm: 68, genres: ["ambient"], moods: ["calm"], energy: 0.2,
        duration: 60, license: .freeToUse(title: "Calm", author: "A"), sourceProvider: .freeToUse, sourcePageURL: source,
        localFileURL: existingFile, originalFileName: "calm.mp3"
    )
    let energetic = LocalMusicTrack(
        title: "Run", author: "B", bpm: 132, genres: ["action"], moods: ["energetic"], energy: 0.92,
        duration: 60, license: .freeToUse(title: "Run", author: "B"), sourceProvider: .freeToUse,
        sourcePageURL: URL(string: "https://freetouse.com/music/artist/run")!,
        localFileURL: existingFile, originalFileName: "run.mp3"
    )
    let directive = MusicDirective(style: .energetic, bpm: 130)
    let selector = LocalMusicSelector()
    #expect(selector.select(for: directive, from: [calm, energetic])?.id == energetic.id)
    #expect(selector.select(for: directive, from: [calm, energetic], excluding: energetic.id)?.id == calm.id)
}

@Test func conversationalMusicChangesAreRecognizedWithoutGeneratingMusic() {
    let interpreter = MusicPromptInterpreter()
    #expect(interpreter.interpret(prompt: "хочу поживее", preset: .story)?.style == .energetic)
    #expect(interpreter.interpret(prompt: "подбери другой", preset: .cinematic)?.preferDifferentTrack == true)
    #expect(interpreter.interpret(prompt: "смени музыку", preset: .story)?.preferDifferentTrack == true)
    let calmReplacement = interpreter.interpret(prompt: "поставь другую спокойную музыку", preset: .story)
    #expect(calmReplacement?.style == .calm)
    #expect(calmReplacement?.preferDifferentTrack == true)
}

@Test func generatedCutsSnapToTheSelectedLocalTracksBeatGrid() {
    let track = LocalMusicTrack(
        title: "Run", author: "B", bpm: 120, genres: ["action"], moods: ["energetic"], energy: 0.9,
        duration: 60, license: .freeToUse(title: "Run", author: "B"), sourceProvider: .freeToUse,
        sourcePageURL: URL(string: "https://freetouse.com/music/artist/run")!,
        localFileURL: URL(fileURLWithPath: #filePath), originalFileName: "run.mp3"
    )
    let timeline = Timeline(storyPlanID: UUID(), items: [
        TimelineItem(kind: .video, sourceDuration: 3.8, timelineStart: 0, timelineDuration: 3.8),
        TimelineItem(kind: .video, sourceDuration: 4.2, timelineStart: 3.8, timelineDuration: 4.2)
    ])
    let result = MusicBeatSynchronizer().synchronize(timeline, to: track)
    #expect(result.items[0].timelineDuration == 3.5)
    #expect(result.items[1].timelineDuration == 4.0)
    #expect(result.items[1].timelineStart == 3.5)
    #expect(result.items.allSatisfy { $0.explanation.contains(where: { $0.contains("120 BPM") }) })
}

@Test func changingSelectedMusicOnlyRefreshesBeatStructure() {
    let track = LocalMusicTrack(
        title: "Ride", author: "B", bpm: 138, genres: ["action"], moods: ["energetic"], energy: 0.9,
        duration: 60, license: .freeToUse(title: "Ride", author: "B"), sourceProvider: .freeToUse,
        sourcePageURL: URL(string: "https://freetouse.com/music/artist/ride")!,
        localFileURL: URL(fileURLWithPath: #filePath), originalFileName: "ride.mp3"
    )
    let items = [
        TimelineItem(kind: .video, sourceDuration: 3.8, timelineStart: 0, timelineDuration: 3.8),
        TimelineItem(kind: .video, sourceDuration: 4.2, timelineStart: 3.8, timelineDuration: 4.2)
    ]
    let timeline = Timeline(
        storyPlanID: UUID(),
        items: items,
        music: MusicDirective(style: .energetic, bpm: track.bpm, trackID: track.id)
    )
    let result = MusicBeatSynchronizer().refreshingStructure(in: timeline, for: track)
    #expect(result.items == items)
    #expect(result.music?.structure?.bpm == 138)
}

@Test func russianEditorRequestBecomesTypedCommandsAndChangesTheRequestedClip() {
    let parser = EditorCommandParser()
    let commands = parser.parse("Ускорь второй клип в 2 раза, сделай его чёрно-белым и убери звук")
    #expect(commands.contains(.setSpeed(2, .number(2))))
    #expect(commands.contains(.setFilter(.monochrome, .number(2))))
    #expect(commands.contains(.setClipMuted(true, .number(2))))

    let timeline = Timeline(
        storyPlanID: UUID(),
        items: (0..<3).map {
            TimelineItem(kind: .video, sourceDuration: 6, timelineStart: Double($0 * 6), timelineDuration: 6)
        }
    )
    let result = EditorCommandExecutor().apply(commands, to: timeline)
    #expect(result.report.hasChanges)
    #expect(result.timeline.items[0].speed == 1)
    #expect(result.timeline.items[1].speed == 2)
    #expect(result.timeline.items[1].timelineDuration == 3)
    #expect(result.timeline.items[1].effectiveVideoAdjustments.filter == .monochrome)
    #expect(result.timeline.items[1].effectiveAudioAdjustments.muted)
    #expect(result.timeline.items[2].timelineStart == 9)
}

@Test func titleSplitDuplicateAndMoveCommandsReallyRewriteTimeline() {
    let original = TimelineItem(kind: .video, sourceStart: 10, sourceDuration: 8, timelineStart: 0, timelineDuration: 8)
    let timeline = Timeline(storyPlanID: UUID(), items: [original])
    let commands: [EditorCommand] = [
        .addTitle("Лето", .beginning),
        .split(.first),
        .duplicate(.last),
        .move(.last, .beginning)
    ]
    let result = EditorCommandExecutor().apply(commands, to: timeline)
    #expect(result.report.applied.count == 4)
    #expect(result.timeline.items.count == 3)
    #expect(result.timeline.effectiveTitleItems.count == 1)
    #expect(result.timeline.effectiveTitleItems[0].templateID == "title.minimal-clean.v1")
    let videos = result.timeline.items.filter { $0.kind == .video }
    #expect(videos.count == 3)
    #expect(videos.contains { $0.sourceStart == 14 && $0.sourceDuration == 4 })
    #expect(result.timeline.duration == 12)
}

@Test func parserExtractsQuotedTitleAndGlobalMovieCommands() {
    let commands = EditorCommandParser().parse("Добавь титр «Наше лето» в конце, поставь спокойную музыку и убери звук")
    #expect(commands.contains(.addTitle("Наше лето", .end)))
    #expect(commands.contains(.setMusic(MusicDirective(style: .calm, bpm: 68))))
    #expect(commands.contains(.setOriginalAudioVolume(0)))
}

@Test func naturalAudioRequestsDistinguishMusicSpeechAndNoise() {
    let quieterMusic = EditorCommandParser().parse("Пожалуйста, приглуши музыку")
    #expect(quieterMusic.contains(.setMusicVolume(0.25)))
    #expect(!quieterMusic.contains { command in
        if case .setMusic = command { return true }
        return false
    })

    let ducking = EditorCommandParser().parse("Приглуши музыку под речь")
    #expect(ducking.contains(.setAudioDucking(true)))
    #expect(!ducking.contains(.setMusicVolume(0.25)))

    let voice = EditorCommandParser().parse("Сделай голос тише до 35%")
    #expect(voice.contains(.setClipVolume(0.35, .all)))

    let noise = EditorCommandParser().parse("Убери шум в звуке")
    #expect(noise.contains(.setNoiseReduction(0.65, .all)))
    #expect(!noise.contains { command in
        if case .setVideoDenoise = command { return true }
        return false
    })
}

@Test func multiClauseRequestKeepsTargetsSeparateAndResolvesPronouns() {
    let commands = EditorCommandParser().parse(
        "Ускорь первый клип в 2 раза, второй клип сделай чёрно-белым, убери у него звук"
    )
    #expect(commands.contains(.setSpeed(2, .first)))
    #expect(commands.contains(.setFilter(.monochrome, .number(2))))
    #expect(commands.contains(.setClipMuted(true, .number(2))))
    #expect(!commands.contains(.setFilter(.monochrome, .first)))
}

@Test func naturalCreativeRequestActuallyAddsVariedTransitionsAndMotion() {
    let commands = EditorCommandParser().parse(
        "Сделай ролик динамичнее: добавь разные эффектные переходы и разные эффекты движения на все клипы"
    )
    #expect(commands.contains(.setTransitionPattern([.lightFlash, .slideLeft, .wipeRight, .blurDissolve], .all)))
    #expect(commands.contains(.setEffectPattern([.pushIn, .panLeft, .pullOut, .panRight], .all)))

    let timeline = Timeline(
        storyPlanID: UUID(),
        items: (0..<5).map {
            TimelineItem(kind: .video, sourceDuration: 4, timelineStart: Double($0 * 4), timelineDuration: 4)
        }
    )
    let result = EditorCommandExecutor().apply(commands, to: timeline)
    #expect(result.report.hasChanges)
    #expect(result.timeline.items[0].transition == nil)
    #expect(result.timeline.items.dropFirst().allSatisfy { $0.transition != nil })
    #expect(Set(result.timeline.items.compactMap(\.transition)).count > 1)
    #expect(result.timeline.items.allSatisfy { $0.effect != nil })
    #expect(Set(result.timeline.items.compactMap(\.effect)).count > 1)
}

@Test func russianLocativeTargetAndTransitionBoundaryResolveToRenderedClip() {
    let secondClip = EditorCommandParser().parse("На втором клипе сделай плавный наезд")
    #expect(secondClip.contains(.setEffect(.pushIn, .number(2))))

    let boundary = EditorCommandParser().parse("После первого клипа добавь переход с размытием")
    #expect(boundary.contains(.setTransition(.blurDissolve, .number(2))))
}

@Test func repeatedVisualCommandIsReportedAsNoOpInsteadOfClaimingAChange() {
    let item = TimelineItem(
        kind: .video,
        sourceDuration: 4,
        timelineStart: 0,
        timelineDuration: 4,
        effect: ClipEffect.pushIn.rawValue
    )
    let timeline = Timeline(storyPlanID: UUID(), items: [item])
    let result = EditorCommandExecutor().apply([.setEffect(.pushIn, .all)], to: timeline)
    #expect(!result.report.hasChanges)
    #expect(result.report.ignored.contains(where: { $0.contains("уже было установлено") }))
}

@Test func overlayRequestCreatesARealSecondLayerWithoutLengtheningMovie() {
    let first = TimelineItem(kind: .video, sourceDuration: 8, timelineStart: 0, timelineDuration: 8)
    let second = TimelineItem(kind: .video, sourceDuration: 5, timelineStart: 8, timelineDuration: 5)
    let timeline = Timeline(storyPlanID: UUID(), items: [first, second])
    let commands = EditorCommandParser().parse("Сделай второй клип картинкой в картинке поверх первого")
    #expect(commands.contains(.setOverlay(.pictureInPicture, .number(2), .first)))
    let result = EditorCommandExecutor().apply(commands, to: timeline)
    #expect(result.report.hasChanges)
    #expect(result.timeline.items[1].overlay?.style == .pictureInPicture)
    #expect(result.timeline.items[1].overlay?.baseItemID == first.id)
    #expect(result.timeline.items[1].timelineStart == 0)
    #expect(result.timeline.duration == 8)
}

@Test func overlayStylesAndReferencesSurviveProjectEncoding() throws {
    let base = TimelineItem(kind: .video, sourceDuration: 4, timelineStart: 0, timelineDuration: 4)
    let overlay = TimelineItem(
        kind: .video,
        sourceDuration: 3,
        timelineStart: 0,
        timelineDuration: 3,
        overlay: OverlaySettings(style: .greenScreen, baseItemID: base.id, corner: .bottomLeft, scale: 0.4)
    )
    let timeline = Timeline(storyPlanID: UUID(), items: [base, overlay])
    let decoded = try JSONDecoder.veloEdit.decode(Timeline.self, from: JSONEncoder.veloEdit.encode(timeline))
    #expect(decoded.items[1].overlay?.style == .greenScreen)
    #expect(decoded.items[1].overlay?.baseItemID == base.id)
    #expect(decoded.items[1].overlay?.corner == .bottomLeft)
}

@Test func freezeFrameCommandInsertsARealTimedStill() {
    let first = TimelineItem(kind: .video, sourceStart: 10, sourceDuration: 6, timelineStart: 0, timelineDuration: 6)
    let second = TimelineItem(kind: .video, sourceStart: 20, sourceDuration: 4, timelineStart: 6, timelineDuration: 4)
    let timeline = Timeline(storyPlanID: UUID(), items: [first, second])
    let commands = EditorCommandParser().parse("После первого клипа добавь стоп-кадр на 3 секунды")
    #expect(commands.contains(.insertFreezeFrame(3, .first)))

    let result = EditorCommandExecutor().apply(commands, to: timeline)
    #expect(result.timeline.items.count == 3)
    let freeze = result.timeline.items[1]
    #expect(freeze.isFreezeFrame)
    #expect(freeze.sourceStart == 13)
    #expect(freeze.sourceDuration == 1.0 / 30.0)
    #expect(freeze.timelineDuration == 3)
    #expect(freeze.effectiveAudioAdjustments.muted)
    #expect(result.timeline.items[2].timelineStart == 9)
    #expect(result.timeline.duration == 13)
}

@Test func reverseAndAutoEnhanceCommandsChangeTheSelectedClip() {
    let first = TimelineItem(kind: .video, sourceDuration: 5, timelineStart: 0, timelineDuration: 5)
    let second = TimelineItem(kind: .video, sourceDuration: 5, timelineStart: 5, timelineDuration: 5)
    let timeline = Timeline(storyPlanID: UUID(), items: [first, second])
    let commands = EditorCommandParser().parse("Второй клип воспроизводи задом наперёд и улучши автоматически")
    #expect(commands.contains(.setReverse(true, .number(2))))
    #expect(commands.contains(.autoEnhance(.number(2))))

    let result = EditorCommandExecutor().apply(commands, to: timeline)
    #expect(!result.timeline.items[0].isReversed)
    #expect(result.timeline.items[1].isReversed)
    #expect(result.timeline.items[1].effectiveAudioAdjustments.muted)
    #expect(result.timeline.items[1].effectiveVideoAdjustments.brightness == 0.04)
    #expect(result.timeline.items[1].effectiveVideoAdjustments.contrast == 1.08)
    #expect(result.timeline.items[1].effectiveVideoAdjustments.saturation == 1.08)
}

@Test func instantReplayDuplicatesTheMomentAndSlowsOnlyTheCopy() {
    let original = TimelineItem(kind: .video, sourceStart: 8, sourceDuration: 4, timelineStart: 0, timelineDuration: 4)
    let timeline = Timeline(storyPlanID: UUID(), items: [original])
    let commands = EditorCommandParser().parse("Добавь мгновенный повтор последнего клипа в 2 раза медленнее")
    #expect(commands.contains(.insertInstantReplay(0.5, .last)))

    let result = EditorCommandExecutor().apply(commands, to: timeline)
    #expect(result.timeline.items.count == 2)
    #expect(result.timeline.items[0].speed == 1)
    #expect(result.timeline.items[1].speed == 0.5)
    #expect(result.timeline.items[1].sourceStart == 8)
    #expect(result.timeline.items[1].timelineDuration == 8)
    #expect(result.timeline.duration == 12)
}

@Test func conversationalDirectorWordingStillBecomesExecutableCommands() {
    let commands = EditorCommandParser().parse(
        "Пусть концовка пойдёт наоборот, а третий план покажи маленьким поверх первого"
    )
    #expect(commands.contains(.setReverse(true, .last)))
    #expect(commands.contains(.setOverlay(.pictureInPicture, .number(3), .first)))
}

@Test func titleAppearanceCanBeChangedByRequest() {
    let title = TimelineItem(kind: .title, sourceDuration: 3, timelineStart: 0, timelineDuration: 3, title: "Лето")
    let timeline = Timeline(storyPlanID: UUID(), items: [title])
    let commands = EditorCommandParser().parse("Сделай первый титр крупным, красный текст и чёрный фон, выровняй справа")
    #expect(commands.contains(.setTitleStyle(108, nil, nil, nil, .first)))
    #expect(commands.contains(.setTitleStyle(nil, "#FF3B30", "#111111", nil, .first)))
    #expect(commands.contains(.setTitleStyle(nil, nil, nil, .right, .first)))

    let result = EditorCommandExecutor().apply(commands, to: timeline)
    let style = result.timeline.items[0].effectiveTitleStyle
    #expect(style.fontSize == 108)
    #expect(style.textColorHex == "#FF3B30")
    #expect(style.backgroundColorHex == "#111111")
    #expect(style.alignment == .right)
}

@Test func editorCommandsCreateAndEditTemplateTitleObjects() {
    let video = TimelineItem(kind: .video, sourceDuration: 8, timelineStart: 0, timelineDuration: 8)
    let timeline = Timeline(storyPlanID: UUID(), items: [video])
    let added = EditorCommandExecutor().apply([
        .addTitle("Новый маршрут", .end),
        .setTitleStyle(96, "#FFD60A", nil, .left, .first)
    ], to: timeline)

    #expect(added.timeline.items == [video])
    #expect(added.timeline.effectiveTitleItems.count == 1)
    #expect(added.timeline.effectiveTitleItems[0].templateID == "title.end-card.v1")
    #expect(added.timeline.effectiveTitleItems[0].style.fontSize == 96)
    #expect(added.timeline.effectiveTitleItems[0].style.textColorHex == "#FFD60A")
    #expect(added.timeline.effectiveTitleItems[0].style.alignment == .left)

    let removed = EditorCommandExecutor().apply([.removeTitles], to: added.timeline)
    #expect(removed.timeline.effectiveTitleItems.isEmpty)
    #expect(removed.report.hasChanges)
}

@Test func turquoiseTitleBackgroundIsUnderstoodInRussian() {
    let commands = EditorCommandParser().parse("Сделай титры на бирюзовом фоне")
    #expect(commands.contains(.setTitleStyle(nil, nil, "#40E0D0", nil, .all)))
}
