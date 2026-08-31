import Foundation
import Testing
@testable import VeloEditCore

private let p4BaseDate = Date(timeIntervalSince1970: 1_720_000_000)

private func p4Asset(
    _ name: String,
    date: Date,
    latitude: Double? = nil,
    longitude: Double? = nil,
    device: String = "GoPro HERO12",
    duration: Double = 30,
    dateSource: MediaDateSource = .embeddedMetadata
) -> MediaAsset {
    let parts = device.split(separator: " ", maxSplits: 1).map(String.init)
    return MediaAsset(
        originalURL: URL(fileURLWithPath: "/tmp/\(name).mov"),
        displayName: "\(name).mov",
        kind: .video,
        byteSize: 100,
        contentHash: "p4-\(name)",
        metadata: MediaMetadata(
            duration: duration,
            frameRate: 30,
            hasAudio: true,
            creationDate: date,
            modificationDate: date.addingTimeInterval(50_000),
            timeZoneIdentifier: "Europe/Moscow",
            dateSource: dateSource,
            dateConfidence: dateSource == .embeddedMetadata ? 0.98 : 0.32,
            latitude: latitude,
            longitude: longitude,
            cameraMake: parts.first,
            cameraModel: parts.count > 1 ? parts[1] : nil
        )
    )
}

private func p4Analysis(
    asset: MediaAsset,
    tags: Set<String>,
    action: Double = 0.58,
    quality: Double = 0.82,
    people: [String] = [],
    sourceStart: Double = 2,
    sourceDuration: Double = 6
) -> AnalysisResult {
    let candidate = Candidate(
        assetID: asset.id,
        sourceStart: sourceStart,
        sourceDuration: sourceDuration,
        scores: ClipScores(quality: quality, interest: min(1, quality + 0.05), action: action, stability: 0.84, uniqueness: 0.82),
        tags: tags.union(people),
        explanation: ["P4 production event fixture"],
        insights: CandidateInsights(
            sceneSummary: tags.sorted().joined(separator: " "),
            emotion: people.isEmpty ? nil : "joy",
            dynamics: action,
            visualAppeal: quality,
            composition: quality,
            sharpness: quality,
            exposureQuality: 0.84,
            originalAudioUsefulness: people.isEmpty ? 0.48 : 0.82,
            storyValue: min(1, quality + 0.04),
            roleScores: [.intro: 0.62, .setup: 0.72, .action: action, .climax: action, .outro: 0.58],
            semanticEventID: tags.sorted().joined(separator: "-")
        ),
        momentBoundary: MomentBoundary(
            anticipationStart: sourceStart,
            peakTime: sourceStart + sourceDuration * 0.42,
            completionEnd: sourceStart + sourceDuration,
            confidence: 0.91,
            evidence: ["anticipation → peak → completion"]
        )
    )
    return AnalysisResult(
        assetID: asset.id,
        schemaVersion: 4,
        analyzedContentHash: asset.contentHash,
        sceneTags: tags,
        candidates: [candidate],
        completedDepth: .deep,
        scenes: [SceneAnalysis(
            startTime: sourceStart,
            endTime: sourceStart + sourceDuration,
            semanticDescription: tags.sorted().joined(separator: " "),
            qualityScore: quality,
            motionScore: action,
            actionScore: action,
            beautyScore: quality,
            stabilityScore: 0.84,
            sharpnessScore: quality,
            audioScore: people.isEmpty ? 0.48 : 0.82,
            people: people,
            objects: Array(tags),
            highlights: action > 0.85 ? ["peak"] : [],
            recommendedUses: action > 0.85 ? ["climax"] : ["story"]
        )],
        deepMediaVersion: 2
    )
}

private func p4Quality(
    total: Double,
    usable: Double,
    story: Double,
    action: Double = 0.5,
    diversity: Double = 0.5
) -> EventQuality {
    EventQuality(
        total: total,
        visualQuality: total,
        semanticCoherence: 0.82,
        temporalCoherence: 0.88,
        usableMaterial: usable,
        emotionalValue: story,
        action: action,
        uniqueness: diversity,
        storyPotential: story,
        diversity: diversity
    )
}

@Test func sourceSequenceDetectorSupportsCameraIndependentPatterns() throws {
    let detector = SourceSequenceDetector()

    #expect(try #require(detector.detect(fileName: "GX010530.MP4")).sequenceID == 530)
    #expect(try #require(detector.detect(fileName: "GX010530.MP4")).subSequenceID == 1)
    #expect(try #require(detector.detect(fileName: "DJI_0002.MP4")).sequenceID == 2)
    #expect(try #require(detector.detect(fileName: "C0012.MP4")).sequenceID == 12)
    #expect(try #require(detector.detect(fileName: "GOPR1234.MP4")).sequenceID == 1234)
    #expect(try #require(detector.detect(fileName: "000123.MOV")).sequenceID == 123)
    #expect(try #require(detector.detect(fileName: "IMG_1234.MOV")).sequenceID == 1234)
    let cinema = try #require(detector.detect(fileName: "A001_C001_0101AB.MXF"))
    #expect(cinema.sequenceID == 1)
    #expect(cinema.subSequenceID == 101)
    #expect(cinema.seriesKey == "reel:A001")
    #expect(detector.detect(fileName: "family-holiday.MOV") == nil)
}

@Test func reliableEmbeddedTimestampsRemainAboveFilenameSequence() {
    let earlier = p4Asset("C0002", date: p4BaseDate)
    let later = p4Asset("C0001", date: p4BaseDate.addingTimeInterval(120))

    let sourceMap = SourceTimelineAnalyzer().analyze(assets: [later, earlier], analyses: [])

    #expect(sourceMap.orderedAssetIDs == [earlier.id, later.id])
    #expect(sourceMap.entries.allSatisfy { !$0.evidence.contains { $0.kind == "ordering" } })
}

@Test func sourceTimelineRestoresTest3OrderAndKeepsBuggyFilesTogether() throws {
    let definitions: [(String, TimeInterval, Set<String>)] = [
        ("GX010530", 0, ["buggy", "road", "machine", "helmet"]),
        ("GX010526", 74, ["buggy", "road", "machine", "helmet"]),
        ("GX010498", 210, ["cycling", "bicycle", "forest"]),
        ("GX010516", 16, ["people", "helmet", "preparation"]),
        ("GX010524", 136, ["buggy", "road", "machine", "helmet"]),
        ("GX010513", 110, ["people", "helmet", "preparation"])
    ]
    var assets: [MediaAsset] = []
    var analyses: [AnalysisResult] = []
    for definition in definitions {
        var asset = p4Asset(definition.0, date: p4BaseDate.addingTimeInterval(definition.1), duration: 360, dateSource: .fileCreationDate)
        asset.displayName = "\(definition.0).MP4"
        asset.metadata.dateConfidence = 0.68
        assets.append(asset)
        analyses.append(p4Analysis(asset: asset, tags: definition.2))
    }

    let result = EventIntelligenceEngine().discover(assets: assets, analyses: analyses)
    let orderedNames = result.sourceMap.entries.map(\.displayName)

    #expect(orderedNames == [
        "GX010498.MP4", "GX010513.MP4", "GX010516.MP4",
        "GX010524.MP4", "GX010526.MP4", "GX010530.MP4"
    ])
    #expect(result.sourceMap.activityGroups.map(\.assetIDs.count) == [1, 2, 3])
    let buggy = try #require(result.sourceMap.activityGroups.last)
    #expect(buggy.title == "Багги")
    #expect(buggy.assetIDs == result.sourceMap.entries.suffix(3).map(\.assetID))
    #expect(buggy.confidence > 0.70)
    #expect(result.diagnostics.sourceMap?.orderedAssetIDs == result.sourceMap.orderedAssetIDs)
    #expect(result.events.flatMap(\.effectiveScenes).contains { $0.assetIDs == buggy.assetIDs })

    var constraints = PromptInterpreter.defaults(for: .story)
    constraints.targetDuration = 15
    constraints.targetClipCount = 9
    let sourceActivityScenes = result.sourceMap.activityGroups.map { group in
        EventScene(
            id: group.id,
            title: group.title,
            assetIDs: group.assetIDs,
            candidateIDs: analyses
                .filter { group.assetIDs.contains($0.assetID) }
                .flatMap(\.candidates)
                .map(\.id),
            confidence: group.confidence
        )
    }
    let continuousEvent = Event(
        title: "Тест 3",
        assetIDs: result.sourceMap.orderedAssetIDs,
        scenes: sourceActivityScenes
    )
    let plan = StoryEngine().createPlan(
        prompt: "Собери фильм из 9 лучших моментов",
        preset: .story,
        constraints: constraints,
        assets: assets,
        analyses: analyses,
        events: [continuousEvent],
        eventDiagnostics: result.diagnostics
    )
    #expect(Set(plan.chapters.compactMap(\.eventSceneID)).count == 3)
    let timeline = TimelineComposer().compose(plan: plan, assets: assets, analyses: analyses)
    #expect(Set(timeline.items.compactMap(\.eventSceneID)).count == 3)
}

@Test func eventDiscoveryMergesOneCrossDeviceMomentAndEstimatesClockOffset() throws {
    let goPro = p4Asset("gopro-rafting", date: p4BaseDate, latitude: 55.75, longitude: 37.61, device: "GoPro HERO12")
    let phone = p4Asset("iphone-rafting", date: p4BaseDate.addingTimeInterval(42), latitude: 55.7501, longitude: 37.6101, device: "Apple iPhone 15")
    let analyses = [
        p4Analysis(asset: goPro, tags: ["rafting", "river", "action"], action: 0.92),
        p4Analysis(asset: phone, tags: ["rafting", "river", "action"], action: 0.88)
    ]

    let result = EventIntelligenceEngine().discover(assets: [goPro, phone], analyses: analyses)
    let event = try #require(result.events.first)

    #expect(result.events.count == 1)
    #expect(event.assetIDs.count == 2)
    #expect(event.effectiveCrossDeviceMatchCount >= 1)
    #expect(result.diagnostics.crossDeviceMatches >= 1)
    #expect(result.diagnostics.deviceTimeOffsets.values.contains { abs($0) >= 40 })
    #expect(event.evidence?.contains { $0.kind == "cross-device" } == true)
}

@Test func eventDiscoverySplitsFourDifferentEventsRecordedOnOneDay() {
    let definitions: [(Int, String, Double, Double)] = [
        (10, "fishing", 55.75, 37.61),
        (13, "museum", 56.20, 38.40),
        (17, "football", 54.90, 39.10),
        (22, "concert", 59.90, 30.30)
    ]
    var assets: [MediaAsset] = []
    var analyses: [AnalysisResult] = []
    let dayStart = Calendar.current.startOfDay(for: p4BaseDate)
    for (group, definition) in definitions.enumerated() {
        for clip in 0..<2 {
            let date = dayStart.addingTimeInterval(Double(definition.0 * 3_600 + clip * 24))
            let asset = p4Asset("\(definition.1)-\(group)-\(clip)", date: date, latitude: definition.2, longitude: definition.3)
            assets.append(asset)
            analyses.append(p4Analysis(asset: asset, tags: [definition.1, "context-\(group)"]))
        }
    }

    let result = EventIntelligenceEngine().discover(assets: assets, analyses: analyses)

    #expect(result.events.count == 4)
    #expect(result.events.allSatisfy { $0.assetIDs.count == 2 })
    #expect(result.diagnostics.eventsSplit >= 3)
}

@Test func eventDiscoveryKeepsAContinuousMultiDayTripAsOneEvent() throws {
    var assets: [MediaAsset] = []
    var analyses: [AnalysisResult] = []
    for day in 0..<3 {
        let asset = p4Asset(
            "altai-hike-day-\(day)",
            date: p4BaseDate.addingTimeInterval(Double(day) * 24 * 3_600),
            latitude: 51.80 + Double(day) * 0.002,
            longitude: 85.70 + Double(day) * 0.002
        )
        assets.append(asset)
        analyses.append(p4Analysis(asset: asset, tags: ["hiking", "altai", "trail", "mountain"], action: 0.64))
    }

    let result = EventIntelligenceEngine().discover(assets: assets, analyses: analyses)
    let event = try #require(result.events.first)

    #expect(result.events.count == 1)
    #expect(event.assetIDs.count == 3)
    #expect((event.endDate?.timeIntervalSince(event.startDate ?? p4BaseDate) ?? 0) >= 2 * 24 * 3_600)
}

@Test func sameLocationWeeksLaterDoesNotBecomeTheSameEvent() {
    let first = p4Asset("park-spring", date: p4BaseDate, latitude: 55.73, longitude: 37.59)
    let second = p4Asset("park-summer", date: p4BaseDate.addingTimeInterval(35 * 86_400), latitude: 55.7301, longitude: 37.5901)
    let analyses = [
        p4Analysis(asset: first, tags: ["park", "family", "walk"]),
        p4Analysis(asset: second, tags: ["park", "family", "walk"])
    ]

    #expect(EventIntelligenceEngine().discover(assets: [first, second], analyses: analyses).events.count == 2)
}

@Test func sameCameraAtDifferentTimesAndPlacesDoesNotForceMerge() {
    let morning = p4Asset("morning-work", date: p4BaseDate, latitude: 55.75, longitude: 37.61)
    let evening = p4Asset("evening-race", date: p4BaseDate.addingTimeInterval(9 * 3_600), latitude: 59.93, longitude: 30.31)
    let analyses = [
        p4Analysis(asset: morning, tags: ["office", "meeting", "speech"], action: 0.12),
        p4Analysis(asset: evening, tags: ["race", "bicycle", "action"], action: 0.95)
    ]

    #expect(EventIntelligenceEngine().discover(assets: [morning, evening], analyses: analyses).events.count == 2)
}

@Test func eventScenesRecoverSetupActionPeakReactionAndConclusion() throws {
    let actions = [0.18, 0.34, 0.64, 0.98, 0.46, 0.20]
    var assets: [MediaAsset] = []
    var analyses: [AnalysisResult] = []
    for index in actions.indices {
        let asset = p4Asset(
            "rafting-phase-\(index)",
            date: p4BaseDate.addingTimeInterval(Double(index) * 5 * 60),
            latitude: 55.75 + Double(index) * 0.0001,
            longitude: 37.61 + Double(index) * 0.0001
        )
        assets.append(asset)
        analyses.append(p4Analysis(asset: asset, tags: ["rafting", "river", "team"], action: actions[index], people: ["friends"]))
    }

    let event = try #require(EventIntelligenceEngine().discover(assets: assets, analyses: analyses).events.first)
    let phases = event.effectiveScenes.map(\.phase)

    #expect(event.effectiveScenes.count >= 5)
    #expect(phases.first == .setup)
    #expect(phases.contains(.preparation))
    #expect(phases.contains(.peak))
    #expect(phases.contains(.reaction))
    #expect(phases.last == .conclusion)
}

@Test func eventDiscoveryScalesToMoreThanThreeHundredAssetsWithoutPerAssetReclustering() {
    var assets: [MediaAsset] = []
    var analyses: [AnalysisResult] = []
    for group in 0..<4 {
        for clip in 0..<80 {
            let asset = p4Asset(
                "archive-\(group)-\(clip)",
                date: p4BaseDate.addingTimeInterval(Double(group * 12) * 86_400 + Double(clip * 25)),
                latitude: 50 + Double(group) * 4,
                longitude: 30 + Double(group) * 6,
                device: clip.isMultiple(of: 2) ? "GoPro HERO12" : "Apple iPhone 15"
            )
            assets.append(asset)
            analyses.append(p4Analysis(asset: asset, tags: ["archive-group-\(group)", group.isMultiple(of: 2) ? "hiking" : "rafting"], action: 0.45 + Double(clip % 5) * 0.09))
        }
    }

    let clock = ContinuousClock()
    let start = clock.now
    let result = EventIntelligenceEngine().discover(assets: assets, analyses: analyses)
    let elapsed = start.duration(to: clock.now)

    #expect(assets.count == 320)
    #expect(result.events.count == 4)
    #expect(result.events.reduce(0) { $0 + $1.assetIDs.count } == 320)
    #expect(elapsed < .seconds(12))
}

@Test func eventTitleAndDateFallbackAreExplainable() throws {
    let embedded = p4Asset("kayak", date: p4BaseDate, latitude: 60, longitude: 30)
    var fallback = p4Asset("fallback", date: p4BaseDate.addingTimeInterval(600))
    fallback.metadata.creationDate = nil
    fallback.metadata.modificationDate = p4BaseDate.addingTimeInterval(700)
    fallback.metadata.dateSource = .fileModificationDate
    let result = EventIntelligenceEngine().discover(
        assets: [embedded],
        analyses: [p4Analysis(asset: embedded, tags: ["rafting", "kayak", "river"])]
    )
    let event = try #require(result.events.first)

    #expect(event.title == "Сплав")
    #expect(event.titleConfidence ?? 0 > 0.85)
    #expect(embedded.metadata.effectiveCaptureDate == p4BaseDate)
    #expect(fallback.metadata.effectiveCaptureDate == fallback.metadata.modificationDate)
    #expect(result.diagnostics.clusteringReasons[event.id.uuidString]?.isEmpty == false)
}

@Test func lowConfidenceImportDatesDoNotMergeUnrelatedAssets() {
    var first = p4Asset("undated-one", date: p4BaseDate)
    var second = p4Asset("undated-two", date: p4BaseDate.addingTimeInterval(5))
    first.metadata.creationDate = nil
    first.metadata.modificationDate = nil
    first.metadata.dateSource = .importDate
    first.metadata.dateConfidence = 0.12
    first.importedAt = p4BaseDate
    second.metadata.creationDate = nil
    second.metadata.modificationDate = nil
    second.metadata.dateSource = .importDate
    second.metadata.dateConfidence = 0.12
    second.importedAt = p4BaseDate.addingTimeInterval(5)

    let result = EventIntelligenceEngine().discover(assets: [first, second], analyses: [])

    #expect(result.events.count == 2)
    #expect(result.events.allSatisfy { $0.startDate != nil })
}

@Test func eventAndSceneIdentityRemainStableAcrossRediscovery() {
    let first = p4Asset("stable-rafting-a", date: p4BaseDate, latitude: 55.75, longitude: 37.61)
    let second = p4Asset("stable-rafting-b", date: p4BaseDate.addingTimeInterval(5 * 60), latitude: 55.7502, longitude: 37.6102)
    let analyses = [
        p4Analysis(asset: first, tags: ["rafting", "river"], action: 0.35),
        p4Analysis(asset: second, tags: ["rafting", "river"], action: 0.92)
    ]
    let engine = EventIntelligenceEngine()
    let initial = engine.discover(assets: [first, second], analyses: analyses)
    let repeated = engine.discover(assets: [first, second], analyses: analyses)

    #expect(initial.events.map(\.id) == repeated.events.map(\.id))
    #expect(initial.events.flatMap(\.effectiveScenes).map(\.id) == repeated.events.flatMap(\.effectiveScenes).map(\.id))
}

@Test func goproChapterNamesJoinPartsOfOneRecordingWithoutStrongMetadata() throws {
    var first = p4Asset("GOPR0123", date: p4BaseDate)
    var second = p4Asset("GP010123", date: p4BaseDate.addingTimeInterval(4))
    var third = p4Asset("GP020123", date: p4BaseDate.addingTimeInterval(8))
    first.metadata.creationDate = nil
    first.metadata.modificationDate = nil
    first.metadata.dateSource = .importDate
    first.metadata.dateConfidence = 0.12
    first.importedAt = p4BaseDate
    second.metadata.creationDate = nil
    second.metadata.modificationDate = nil
    second.metadata.dateSource = .importDate
    second.metadata.dateConfidence = 0.12
    second.importedAt = p4BaseDate.addingTimeInterval(4)
    third.metadata.creationDate = nil
    third.metadata.modificationDate = nil
    third.metadata.dateSource = .importDate
    third.metadata.dateConfidence = 0.12
    third.importedAt = p4BaseDate.addingTimeInterval(8)

    let event = try #require(EventIntelligenceEngine().discover(assets: [first, second, third], analyses: []).events.first)

    #expect(event.assetIDs.count == 3)
    #expect(event.evidence?.contains { $0.kind == "filename" && $0.score > 0.9 } == true)
}

@Test func phoneLivePhotoAndTimestampNamesProvideConservativeEventEvidence() throws {
    var photo = p4Asset("IMG_4321", date: p4BaseDate, device: "Apple iPhone 15")
    photo.kind = .photo
    photo.displayName = "IMG_4321.HEIC"
    photo.metadata.creationDate = nil
    photo.metadata.modificationDate = nil
    photo.metadata.dateSource = .importDate
    photo.metadata.dateConfidence = 0.12
    photo.importedAt = p4BaseDate
    var liveVideo = p4Asset("IMG_4321", date: p4BaseDate.addingTimeInterval(2), device: "Apple iPhone 15")
    liveVideo.displayName = "IMG_4321.MOV"
    liveVideo.metadata.creationDate = nil
    liveVideo.metadata.modificationDate = nil
    liveVideo.metadata.dateSource = .importDate
    liveVideo.metadata.dateConfidence = 0.12
    liveVideo.importedAt = p4BaseDate.addingTimeInterval(2)

    let liveEvent = try #require(EventIntelligenceEngine().discover(assets: [photo, liveVideo], analyses: []).events.first)
    #expect(liveEvent.assetIDs.count == 2)

    var first = p4Asset("VID_20260824_120000", date: p4BaseDate, device: "Google Pixel 9")
    var second = p4Asset("VID_20260824_120045", date: p4BaseDate, device: "Google Pixel 9")
    first.metadata.creationDate = nil
    first.metadata.modificationDate = nil
    first.metadata.dateSource = .importDate
    first.metadata.dateConfidence = 0.12
    second.metadata.creationDate = nil
    second.metadata.modificationDate = nil
    second.metadata.dateSource = .importDate
    second.metadata.dateConfidence = 0.12

    let timestampEvent = try #require(EventIntelligenceEngine().discover(assets: [first, second], analyses: []).events.first)
    #expect(timestampEvent.assetIDs.count == 2)
}

@Test func eventDurationAllocationFavorsStrongMaterialAndCapsWeakEvents() {
    let strong = Event(title: "Strong", assetIDs: [UUID()], quality: p4Quality(total: 0.91, usable: 0.95, story: 0.92, action: 0.88, diversity: 0.84))
    let medium = Event(title: "Medium", assetIDs: [UUID()], quality: p4Quality(total: 0.61, usable: 0.62, story: 0.66))
    let weak = Event(title: "Weak", assetIDs: [UUID()], quality: p4Quality(total: 0.18, usable: 0.10, story: 0.14))

    let values = EventDurationAllocator().allocate(events: [strong, medium, weak], totalDuration: 60, strategy: "story")

    #expect(values[strong.id, default: 0] > values[medium.id, default: 0])
    #expect(values[medium.id, default: 0] > values[weak.id, default: 0])
    #expect(values[weak.id, default: 0] <= 4.1)
}

@Test func eventDurationAllocationUsesTheStoryTargetForOneMultiActivityEvent() {
    let scenes = (0..<3).map { index in
        EventScene(title: "Activity \(index)", assetIDs: [UUID()], candidateIDs: [UUID()], confidence: 0.8)
    }
    let event = Event(
        title: "Continuous day",
        assetIDs: scenes.flatMap(\.assetIDs),
        scenes: scenes,
        quality: p4Quality(total: 0.72, usable: 0.66, story: 0.74)
    )

    let values = EventDurationAllocator().allocate(events: [event], totalDuration: 15, strategy: "story")

    #expect(abs(values[event.id, default: 0] - 15) < 0.001)
}

private func p4ProductionFixture() -> ([MediaAsset], [AnalysisResult]) {
    let definitions: [(String, Set<String>, Double, Double, Double)] = [
        ("hiking", ["hiking", "mountain", "trail"], 51.8, 85.7, 0),
        ("rafting", ["rafting", "river", "action"], 55.7, 37.6, 7 * 3_600),
        ("family", ["family", "people", "campfire"], 59.9, 30.3, 30 * 3_600)
    ]
    var assets: [MediaAsset] = []
    var analyses: [AnalysisResult] = []
    for (eventIndex, definition) in definitions.enumerated() {
        for scene in 0..<4 {
            for take in 0..<2 {
                let device = take == 0 ? "GoPro HERO12" : "Apple iPhone 15"
                let date = p4BaseDate.addingTimeInterval(definition.4 + Double(scene * 5 * 60 + take * 36))
                let asset = p4Asset(
                    "production-\(definition.0)-\(scene)-\(take)",
                    date: date,
                    latitude: definition.2 + Double(scene) * 0.0001,
                    longitude: definition.3 + Double(scene) * 0.0001,
                    device: device
                )
                let action = scene == 2 ? 0.94 - Double(take) * 0.04 : 0.24 + Double(scene) * 0.16 + Double(eventIndex) * 0.03
                assets.append(asset)
                analyses.append(p4Analysis(
                    asset: asset,
                    tags: definition.1.union(["scene-\(scene)", "take-\(take)"]),
                    action: action,
                    quality: 0.72 + Double((scene + take) % 3) * 0.09,
                    people: eventIndex == 2 ? ["family"] : []
                ))
            }
        }
    }
    return (assets, analyses)
}

@Test func productionPipelineUsesEventsBeforeScenesAndPersistsEventAwareScoring() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("veloedit")
    let tasteURL = FileManager.default.temporaryDirectory.appendingPathComponent("p4-taste-\(UUID().uuidString).json")
    defer {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: tasteURL)
    }
    let store = try ProjectStore(createAt: root, name: "P4 event production")
    let (assets, analyses) = p4ProductionFixture()
    try await store.update { project in
        project.assets = assets
        project.analyses = analyses
    }
    let pipeline = VeloEditPipeline(store: store, personalTasteStore: LocalPersonalTasteStore(url: tasteURL))
    let timeline = try await pipeline.createFilm(
        prompt: "Без музыки. Собери цельную хронологическую историю поездки.",
        preset: .summerFilm,
        targetDuration: 48
    )
    let snapshot = await pipeline.snapshot()
    let plan = try #require(snapshot.storyPlans.last)
    let eventStory = try #require(plan.eventStory)
    let run = try #require(timeline.directorRun)
    let diagnostics = try #require(run.eventDiagnostics)
    let variantDiagnostics = try #require(run.variantDiagnostics)
    let primaryItems = timeline.items.filter { $0.kind != .title && $0.overlay == nil }
    let sequence = primaryItems.compactMap(\.eventID).reduce(into: [UUID]()) { result, eventID in
        if result.last != eventID { result.append(eventID) }
    }

    #expect(snapshot.events.count == 3)
    #expect(eventStory.entries.count == 3)
    #expect(eventStory.entries.map(\.eventID) == sequence)
    #expect(eventStory.entries.map(\.startDate) == eventStory.entries.map(\.startDate).sorted { ($0 ?? .distantFuture) < ($1 ?? .distantFuture) })
    #expect(Set(primaryItems.compactMap(\.eventSceneID)).count >= 6)
    #expect(timeline.items.allSatisfy { $0.kind != .title })
    #expect(timeline.effectiveTitleItems.contains { $0.text == "Моё лето" })
    #expect(timeline.effectiveTitleItems.filter { $0.templateID == "title.chapter.v1" }.count == 3)
    #expect(diagnostics.eventsDetected == 3)
    #expect(diagnostics.sceneCount >= 6)
    #expect(diagnostics.crossDeviceMatches >= 3)
    #expect(variantDiagnostics.variantEvaluations?.allSatisfy {
        $0.score.eventOrder > 0.75 && $0.score.chronology > 0.75 && $0.score.eventCoverage > 0.60
    } == true)
    #expect(run.globalScore != nil)

    let reopened = try ProjectStore(open: root)
    let persisted = await reopened.manifest
    #expect(persisted.events.count == 3)
    #expect(persisted.timelines.last?.directorRun?.eventDiagnostics?.eventsDetected == 3)
}
