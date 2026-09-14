import Foundation
import Testing
@testable import VeloEditCore

@Suite struct AutopilotDefaultsTests {
    private func asset(_ name: String, _ date: Date, duration: Double = 60) -> MediaAsset {
        MediaAsset(originalURL: URL(fileURLWithPath: "/tmp/\(name).mp4"), kind: .video, byteSize: 1,
            contentHash: name, metadata: .init(duration: duration, width: 1920, height: 1080,
                creationDate: date, dateSource: .embeddedMetadata, dateConfidence: 0.98))
    }

    @Test func movieHeaderClockHandlesLargeBoxesBothVersionsAndInvalidData() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("clock-\(UUID()).mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        func integer(_ value: UInt64, bytes: Int) -> Data {
            Data((0..<bytes).reversed().map { UInt8((value >> ($0 * 8)) & 255) })
        }
        func box(_ type: String, _ payload: Data, large: Bool = false) -> Data {
            integer(large ? 1 : UInt64(payload.count + 8), bytes: 4) + Data(type.utf8)
                + (large ? integer(UInt64(payload.count + 16), bytes: 8) : Data()) + payload
        }
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        for version: UInt8 in [0, 1] {
            let payload = Data([version, 0, 0, 0]) + integer(UInt64(date.timeIntervalSince1970) + 2_082_844_800, bytes: version == 1 ? 8 : 4) + Data(repeating: 0, count: 12)
            try (box("ftyp", Data("isom".utf8)) + box("mdat", Data(repeating: 0, count: 100)) + box("moov", box("mvhd", payload), large: true)).write(to: url)
            #expect(MediaCaptureClock.movieDate(at: url) == date)
        }
        for data in [Data(), integer(UInt64.max, bytes: 8), box("moov", Data([0, 0, 0, 1]) + Data("mvhd".utf8))] {
            try data.write(to: url)
            #expect(MediaCaptureClock.movieDate(at: url) == nil)
        }
    }

    @Test func datesOutrankCameraNumbersAndSeparateRepeatedActivities() {
        let day = Date(timeIntervalSince1970: 1_700_000_000)
        let assets = [asset("GX010900", day), asset("GX010100", day.addingTimeInterval(300)), asset("GX010050", day.addingTimeInterval(86_400))]
        let analyses = assets.map { a in AnalysisResult(assetID: a.id, analyzedContentHash: a.contentHash, sceneTags: ["cycling"], candidates: [
            Candidate(assetID: a.id, sourceStart: 0, sourceDuration: 8, scores: .init(quality: 0.9, interest: 0.9, action: 0.8, stability: 0.9), tags: ["cycling", "bicycle"])
        ]) }
        let source = SourceTimelineAnalyzer().analyze(assets: assets.reversed(), analyses: analyses)
        #expect(source.orderedAssetIDs == assets.map(\.id))
        #expect(source.entries[0].activityGroupID != source.entries[2].activityGroupID)
        let events = EventIntelligenceEngine().discover(assets: assets.reversed(), analyses: analyses).events
        #expect(events.flatMap(\.assetIDs) == assets.map(\.id))
        #expect(events.flatMap(\.effectiveScenes).count >= 2)
    }

    @Test func requiredTitlesKeepReferenceFontThroughOCRAndRepeatedPartNames() throws {
        let candidates = [UUID(), UUID()]
        let event = UUID()
        var plan = StoryPlan(prompt: "Названия каждой части", preset: .cinematic, constraints: .init(targetDuration: 12),
            chapters: candidates.map { StoryChapter(title: "Велопрогулка", candidateIDs: [$0], eventID: event, eventSceneID: UUID()) },
            directorBrief: .init(requestedDuration: 12, mood: .cinematic, musicPolicy: .none, titlePolicy: .keyOnly))
        plan.narrativeBeatPlan = .init(pattern: .eventChapters, beats: [], reasons: [])
        let timeline = Timeline(storyPlanID: plan.id, items: candidates.enumerated().map { index, id in
            TimelineItem(candidateID: id, kind: .video, sourceDuration: 6, timelineStart: Double(index * 6), timelineDuration: 6)
        })
        var output = EditorialPresentationPolicy.ensuringChapterTitles(in: timeline, plan: plan)
        #expect(output.effectiveTitleItems.map(\.startTime) == [0, 6])
        output.titleItems = output.effectiveTitleItems.map(EditorialPresentationPolicy.hardeningReadability)
        output = EditorialIntentEnforcer.enforce(output, plan: plan)
        #expect(output.effectiveTitleItems.count == 2)
        #expect(output.effectiveTitleItems.allSatisfy { $0.style.fontFamily == "Avenir Next" && $0.style.fontSize == 72 && $0.style.alignment == .left })
        #expect(EditorialPresentationPolicy.missingChapterTitles(in: output, plan: plan).isEmpty)
    }

    @Test func cinematicBriefCannotAuthorizeFiltersOrAudioEffects() {
        let prompt = "Сделай красиво. Настроение: киношное. Звук: приглушить звук исходников."
        let plan = StoryPlan(prompt: prompt, preset: .cinematic, constraints: .init(), chapters: [])
        let clip = TimelineItem(kind: .video, sourceDuration: 8, timelineStart: 0, timelineDuration: 8,
            videoAdjustments: .init(filter: .vivid, saturation: 1.3), audioAdjustments: .init(noiseReduction: 0.8, eqPreset: .voice))
        let source = Timeline(storyPlanID: plan.id, items: [clip])
        let cleaned = EditorialIntentEnforcer.enforce(source, plan: plan)
        #expect(cleaned.items[0].effectiveVideoAdjustments.filter == .none)
        #expect(cleaned.items[0].effectiveVideoAdjustments.saturation == 1)
        #expect(cleaned.items[0].effectiveAudioAdjustments.eqPreset == .flat)
        #expect(cleaned.items[0].effectiveAudioAdjustments.noiseReduction == 0)
        let commands: [EditorCommand] = [.setFilter(.vivid, .all), .setEQ(.voice, .all), .setOriginalAudioVolume(0.3)]
        #expect(DirectorRequestContract.authorizedCommands(commands, prompt: prompt, preset: .cinematic) == [.setOriginalAudioVolume(0.2)])
        #expect(DirectorRequestContract.authorizedCommands([.setFilter(.vivid, .all)], prompt: "Сделай цвета ярче", preset: .cinematic) == [.setFilter(.vivid, .all)])
    }

    @Test func telemetryQuestionIgnoresCameraSensorsAndHUDCannotCrossDataGaps() throws {
        let sensorOnly = TelemetrySummary(hasGPMF: true, sampleCount: 20, timedSamples: (0...10).map { .init(timestamp: Double($0), gForce: 1, cameraISO: 400) })
        #expect(AutomaticTelemetryPolicy.usefulKinds(in: sensorOnly).isEmpty)
        let samples = (0...12).map { second in TelemetrySample(timestamp: Double(second), speedMetersPerSecond: (3...5).contains(second) ? 12 : nil, gForce: 1) }
        let summary = TelemetrySummary(sampleCount: samples.count, maxSpeedMetersPerSecond: 30, timedSamples: samples)
        #expect(AutomaticTelemetryPolicy.usefulKinds(in: summary).contains(.speedValue))
        let clip = TimelineItem(kind: .video, sourceDuration: 12, timelineStart: 20, timelineDuration: 12)
        let decision = try #require(SmartTelemetryEngine().decide(.init(telemetry: summary, clip: clip, explicitRequest: "Покажи скорость")))
        #expect(decision.timelineStart >= 23 - 0.000001)
        #expect(decision.timelineStart + decision.duration <= 25 + 0.000001)
        let uncovered = TimelineItem(kind: .video, sourceStart: 7, sourceDuration: 5, timelineStart: 0, timelineDuration: 5)
        let absent = SmartTelemetryEngine().decide(.init(telemetry: summary, clip: uncovered, explicitRequest: "Покажи скорость"))
        #expect(absent == nil)
        #expect(AutomaticTelemetryPolicy.usefulKinds(in: .init(sampleCount: 1, maxSpeedMetersPerSecond: 30)).isEmpty)
    }

    @Test func adaptiveMusicRequestsRespectTheSelectedMood() {
        let assets = (0..<6).map { _ in UUID() }
        let analyses = assets.enumerated().map { index, id in AnalysisResult(assetID: id, analyzedContentHash: "music", candidates: [
            Candidate(assetID: id, sourceStart: 0, sourceDuration: 10, scores: .init(quality: 0.9, interest: 0.9, action: 0.95, stability: 0.9), tags: index < 3 ? ["buggy", "offroad"] : ["cycling", "bicycle"])
        ]) }
        let items = analyses.enumerated().map { index, a in TimelineItem(candidateID: a.candidates[0].id, assetID: a.assetID, kind: .video, sourceDuration: 10, timelineStart: Double(index * 10), timelineDuration: 10) }
        for mood in [DirectorNarrativeMood.calm, .cinematic] {
            let plan = StoryPlan(prompt: "Фильм", preset: .adventure, constraints: .init(), chapters: [], directorBrief: .init(mood: mood))
            let timeline = Timeline(storyPlanID: plan.id, items: items, music: .init(style: .energetic, bpm: 120))
            let requests = AdaptiveSoundtrackPlanner().requests(for: timeline, plan: plan, analyses: analyses)
            #expect(!requests.isEmpty)
            #expect(requests.allSatisfy { $0.mood.contains(mood == .calm ? "calm" : "cinematic") })
        }
    }
}
