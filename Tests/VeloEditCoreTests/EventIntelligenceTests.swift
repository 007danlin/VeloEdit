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
    // Three protected six-second actions require at least 18 seconds.
    constraints.targetDuration = 24
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

@Test func twoCameraBuggyBlockBeatsAStrayBicycleLabel() throws {
    let cycling = p4Asset("GX010513", date: p4BaseDate, duration: 360, dateSource: .fileCreationDate)
    let buggySide = p4Asset("GX010524", date: p4BaseDate.addingTimeInterval(120), duration: 360, dateSource: .fileCreationDate)
    let buggyFront = p4Asset("GX010526", date: p4BaseDate.addingTimeInterval(240), duration: 360, dateSource: .fileCreationDate)
    let analyses = [
        p4Analysis(asset: cycling, tags: ["cycling", "cyclist", "bicycle", "trail"]),
        p4Analysis(asset: buggySide, tags: ["bicycle", "dirt_road", "road", "machine", "vehicle", "car", "automobile"]),
        p4Analysis(asset: buggyFront, tags: ["machine", "wheel", "tire", "helmet", "headgear", "people"])
    ]

    let map = SourceTimelineAnalyzer().analyze(assets: [buggyFront, cycling, buggySide], analyses: analyses)
    let buggy = try #require(map.activityGroups.last)

    #expect(buggy.assetIDs == [buggySide.id, buggyFront.id])
    #expect(buggy.title == "Багги")
    #expect(buggy.confidence >= 0.55)
}

@Test func twoMountainBikeFilesDoNotBecomeBuggyFromGenericVehicleTags() throws {
    let first = p4Asset("GX010700", date: p4BaseDate, duration: 360, dateSource: .fileCreationDate)
    let second = p4Asset("GX010702", date: p4BaseDate.addingTimeInterval(120), duration: 360, dateSource: .fileCreationDate)
    let mountainBikeTags: Set<String> = [
        "bicycle", "bike", "trail", "road", "vehicle",
        "machine", "wheel", "tire", "helmet"
    ]
    let analyses = [
        p4Analysis(asset: first, tags: mountainBikeTags),
        p4Analysis(asset: second, tags: mountainBikeTags)
    ]

    let map = SourceTimelineAnalyzer().analyze(assets: [second, first], analyses: analyses)
    let group = try #require(map.activityGroups.first)

    #expect(map.activityGroups.count == 1)
    #expect(group.assetIDs == [first.id, second.id])
    #expect(group.title == "Велопрогулка")
}

@Test func neighbouringBuggyAnglesKeepTheirLabelsWhenNotGroupedVisually() throws {
    let side = p4Asset("GX010524", date: p4BaseDate, duration: 434)
    let front = p4Asset("GX010530", date: p4BaseDate.addingTimeInterval(2878), duration: 327)
    let analyses = [
        p4Analysis(asset: side, tags: ["bicycle", "dirt_road", "machine", "car", "automobile", "land"]),
        p4Analysis(asset: front, tags: ["bicycle", "machine", "wheel", "tire", "helmet", "headgear", "people"])
    ]
    let map = SourceTimelineAnalyzer(groupingThreshold: 1).analyze(assets: [front, side], analyses: analyses)
    #expect(map.activityGroups.count == 2)
    #expect(map.activityGroups.allSatisfy { $0.title == "Багги" })
    let discovery = EventIntelligenceEngine().discover(assets: [front, side], analyses: analyses, sourceMap: map)
    #expect(discovery.events.flatMap(\.effectiveScenes).allSatisfy { $0.title == "Багги" && $0.tags.contains("buggy") })
    var nextDay = front
    nextDay.metadata.creationDate = p4BaseDate.addingTimeInterval(86400)
    let unrelated = SourceTimelineAnalyzer(groupingThreshold: 1).analyze(assets: [side, nextDay], analyses: analyses)
    #expect(!unrelated.activityGroups.contains { $0.title == "Багги" })
}

@Test func oneLongSourceSplitsConfirmedCyclingAndBuggyRunsIntoEventScenes() throws {
    let asset = p4Asset("single-source-two-activities", date: p4BaseDate, duration: 120)
    func candidate(_ start: Double, tags: Set<String>, action: Double) -> Candidate {
        Candidate(
            assetID: asset.id,
            sourceStart: start,
            sourceDuration: 8,
            scores: ClipScores(
                quality: 0.84,
                interest: 0.86,
                action: action,
                stability: 0.80,
                uniqueness: 0.82
            ),
            tags: tags,
            insights: CandidateInsights(
                sceneSummary: tags.sorted().joined(separator: " "),
                dynamics: action,
                visualAppeal: 0.84,
                storyValue: 0.86
            )
        )
    }
    let cycling = [
        candidate(4, tags: ["cycling", "bicycle", "forest trail"], action: 0.64),
        candidate(18, tags: ["cyclist", "mountain bike", "trail"], action: 0.70)
    ]
    let buggy = [
        candidate(66, tags: ["buggy", "utv", "dirt road"], action: 0.88),
        candidate(82, tags: ["buggy", "side by side", "helmet"], action: 0.91)
    ]
    let analysis = AnalysisResult(
        assetID: asset.id,
        schemaVersion: 4,
        analyzedContentHash: asset.contentHash,
        sceneTags: ["outdoor", "road"],
        candidates: cycling + buggy,
        completedDepth: .deep,
        deepMediaVersion: 2
    )
    let sourceGroup = SourceActivityGroup(
        id: UUID(),
        order: 0,
        title: "Активный день",
        assetIDs: [asset.id],
        confidence: 0.88,
        evidence: []
    )
    let sourceMap = SourceMap(entries: [], activityGroups: [sourceGroup])

    let firstRun = EventIntelligenceEngine().discover(
        assets: [asset], analyses: [analysis], sourceMap: sourceMap
    )
    var reorderedAnalysis = analysis
    reorderedAnalysis.candidates.reverse()
    let secondRun = EventIntelligenceEngine().discover(
        assets: [asset], analyses: [reorderedAnalysis], sourceMap: sourceMap
    )
    let event = try #require(firstRun.events.first)
    let repeatedEvent = try #require(secondRun.events.first)

    #expect(firstRun.events.count == 1)
    #expect(event.assetIDs == [asset.id])
    #expect(event.effectiveScenes.map(\.title) == ["Велопрогулка", "Багги"])
    #expect(event.effectiveScenes.map(\.candidateIDs) == [cycling.map(\.id), buggy.map(\.id)])
    #expect(event.effectiveScenes.map(\.id) == repeatedEvent.effectiveScenes.map(\.id))
    #expect(event.effectiveScenes[0].endDate! <= event.effectiveScenes[1].startDate!)
}

@Test func oneLongSourceDoesNotSplitGenericOrIsolatedActivityLabels() throws {
    let asset = p4Asset("single-source-ambiguous", date: p4BaseDate, duration: 120)
    func candidate(_ start: Double, tags: Set<String>) -> Candidate {
        Candidate(
            assetID: asset.id,
            sourceStart: start,
            sourceDuration: 5,
            scores: ClipScores(quality: 0.80, interest: 0.78, action: 0.62, stability: 0.82, uniqueness: 0.74),
            tags: tags,
            insights: CandidateInsights(sceneSummary: tags.sorted().joined(separator: " "))
        )
    }
    let candidates = [
        candidate(4, tags: ["outdoor", "road", "helmet"]),
        candidate(20, tags: ["bicycle", "trail"]),
        candidate(62, tags: ["vehicle", "machine", "wheel"]),
        candidate(78, tags: ["road", "helmet", "people"])
    ]
    let analysis = AnalysisResult(
        assetID: asset.id,
        schemaVersion: 4,
        analyzedContentHash: asset.contentHash,
        sceneTags: ["outdoor", "road"],
        candidates: candidates,
        completedDepth: .deep,
        deepMediaVersion: 2
    )
    let sourceMap = SourceMap(entries: [], activityGroups: [
        SourceActivityGroup(
            id: UUID(),
            order: 0,
            title: "Прогулка",
            assetIDs: [asset.id],
            confidence: 0.72,
            evidence: []
        )
    ])

    let result = EventIntelligenceEngine().discover(
        assets: [asset], analyses: [analysis], sourceMap: sourceMap
    )
    let event = try #require(result.events.first)

    #expect(event.effectiveScenes.count == 1)
    #expect(event.effectiveScenes[0].title == "Прогулка")
    #expect(event.effectiveScenes[0].candidateIDs == candidates.map(\.id))
}

@Test func longSingleEventKeepsActivityBlocksAndCreatesDistinctKeyTitles() throws {
    var assets: [MediaAsset] = []
    var analyses: [AnalysisResult] = []
    for index in 0..<18 {
        let isBuggy = index >= 14
        let asset = p4Asset(
            String(format: "GX01%04d", 600 + index),
            date: p4BaseDate.addingTimeInterval(Double(index) * 31),
            duration: 30
        )
        assets.append(asset)
        analyses.append(p4Analysis(
            asset: asset,
            tags: isBuggy
                ? ["buggy", "vehicle", "dirt_road", "helmet", "tire"]
                : ["cycling", "cyclist", "bicycle", "trail"],
            action: isBuggy ? 0.86 : 0.62,
            sourceStart: 2,
            sourceDuration: 5
        ))
    }
    let candidateIDs = analyses.compactMap { $0.candidates.first?.id }
    #expect(candidateIDs.count == 18)
    let cyclingA = EventScene(
        title: "Велопрогулка",
        assetIDs: Array(assets[0..<7]).map(\.id),
        candidateIDs: Array(candidateIDs[0..<7]),
        tags: ["cycling"],
        phase: .peak,
        confidence: 0.90
    )
    let cyclingB = EventScene(
        title: "Велопрогулка",
        assetIDs: Array(assets[7..<14]).map(\.id),
        candidateIDs: Array(candidateIDs[7..<14]),
        tags: ["cycling"],
        phase: .reaction,
        confidence: 0.88
    )
    let buggy = EventScene(
        title: "Багги",
        assetIDs: Array(assets[14..<18]).map(\.id),
        candidateIDs: Array(candidateIDs[14..<18]),
        tags: ["buggy"],
        phase: .conclusion,
        confidence: 0.92
    )
    let event = Event(
        title: "Активный день",
        assetIDs: assets.map(\.id),
        confidence: 0.90,
        titleConfidence: 0.88,
        scenes: [cyclingA, cyclingB, buggy],
        quality: p4Quality(total: 0.84, usable: 0.92, story: 0.86, action: 0.82, diversity: 0.78)
    )
    var constraints = PromptInterpreter.defaults(for: .story)
    constraints.targetDuration = 90
    constraints.targetClipCount = 18
    let plan = StoryEngine().createPlan(
        prompt: "Собери фильм на 90 секунд. Титры только для ключевых активностей.",
        preset: .story,
        constraints: constraints,
        assets: assets,
        analyses: analyses,
        events: [event]
    )
    let timeline = TimelineComposer().compose(plan: plan, assets: assets, analyses: analyses)
    let titles = timeline.effectiveTitleItems.sorted { $0.startTime < $1.startTime }
    let buggyStart = try #require(timeline.items.filter { $0.eventSceneID == buggy.id }.map(\.timelineStart).min())

    #expect(plan.eventStory?.chapterCardsEnabled == true)
    #expect(Set(plan.chapters.compactMap(\.eventSceneID)).isSubset(of: Set([cyclingA.id, cyclingB.id, buggy.id])))
    #expect(plan.contentBudget?.budget.distinctShotFamilyCount == 2)
    #expect(titles.map(\.text) == ["Велопрогулка", "Багги"])
    #expect(abs((titles.last?.startTime ?? -1) - buggyStart) < 0.001)
    #expect(zip(titles, titles.dropFirst()).allSatisfy { pair in pair.0.endTime <= pair.1.startTime })
    let climaxItems = timeline.items.filter { $0.storyRole == .climax }
    #expect(climaxItems.isEmpty) // Scene phase labels alone do not prove a climax.
    #expect(plan.chapters.filter { $0.role == .climax }.allSatisfy {
        $0.coveragePlan?.sceneID == buggy.id
            && $0.coveragePlan?.requirements.map(\.purpose) == [.peak]
    })
}

@Test(arguments: [16.0, 60.0])
func keyTitlesNameEveryPartAcrossSeparateSourceFiles(duration: Double) throws {
    let activities: [(String, Set<String>)] = [
        ("Велопрогулка", ["cycling", "bicycle"]),
        ("Сплав", ["rafting", "kayak"]),
        ("Рыбалка", ["fishing", "fishing rod"]),
        ("Велопрогулка", ["cycling", "bicycle"])
    ]
    let assets = (0..<8).map { index in
        p4Asset(String(format: "GX01%04d", 800 + index),
                date: p4BaseDate.addingTimeInterval(Double(index) * 31),
                latitude: 43.6, longitude: 39.7)
    }
    let analyses = assets.enumerated().map { index, asset in
        p4Analysis(asset: asset, tags: activities[index / 2].1.union(["take-\(index)"]),
                   sourceDuration: duration / 8)
    }
    let discovery = EventIntelligenceEngine().discover(assets: assets, analyses: analyses)
    #expect(discovery.events.count == 1)
    #expect(discovery.events.first?.effectiveScenes.map(\.title) == activities.map(\.0))

    var constraints = PromptInterpreter.defaults(for: .story)
    constraints.targetDuration = duration
    constraints.targetClipCount = assets.count
    let plan = StoryEngine().createPlan(
        prompt: "Собери фильм из всех частей поездки", preset: .story, constraints: constraints,
        assets: assets, analyses: analyses, events: discovery.events,
        directorBrief: DirectorBrief(requestedDuration: duration, musicPolicy: .none, titlePolicy: .keyOnly)
    )
    #expect(plan.eventStory?.chapterCardsEnabled == true)
    let timeline = TimelineComposer().compose(plan: plan, assets: assets, analyses: analyses)
    let delivered = TimelineDeliveryContract().validateAndRepair(timeline: timeline, plan: plan, assets: assets).timeline
    let titles = delivered.effectiveTitleItems.sorted { $0.startTime < $1.startTime }
    #expect(titles.map(\.text) == activities.map(\.0))
    #expect(Set(titles.map(\.id)).count == 4)
    for (index, scene) in try #require(discovery.events.first).effectiveScenes.enumerated() {
        let items = delivered.items.filter { $0.eventSceneID == scene.id && $0.overlay == nil }
        let start = try #require(items.map(\.timelineStart).min())
        let end = try #require(items.map { $0.timelineStart + $0.timelineDuration }.max())
        let title = try #require(titles.first { abs($0.startTime - start) < 0.001 })
        #expect(title.text == activities[index].0)
        #expect(title.duration >= 1.25)
        #expect(title.endTime <= end + 0.001)
    }
}

@Test func keyTitlesSurviveNarrativePresentationAcrossShortShotsAndReturningParts() throws {
    let eventID = UUID()
    let labels = ["Велопрогулка", "Сплав", "Велопрогулка"]
    var chapters: [StoryChapter] = []
    var items: [TimelineItem] = []
    for (part, label) in labels.enumerated() {
        let sceneID = UUID()
        for shot in 0..<3 {
            let candidateID = UUID()
            chapters.append(StoryChapter(title: label, candidateIDs: [candidateID], role: .action,
                                         eventID: eventID, eventSceneID: sceneID, chapterCardTitle: shot == 0 ? label : nil))
            items.append(TimelineItem(candidateID: candidateID, assetID: UUID(), kind: .video,
                                      sourceDuration: 1, timelineStart: Double(part * 3 + shot), timelineDuration: 1,
                                      eventID: eventID, eventSceneID: sceneID))
        }
    }
    var plan = StoryPlan(prompt: "Добавь титры для всех частей", preset: .story,
                         constraints: StoryConstraints(targetDuration: 9), chapters: chapters,
                         directorBrief: DirectorBrief(requestedDuration: 9, musicPolicy: .none, titlePolicy: .keyOnly))
    plan.narrativeBeatPlan = NarrativeBeatPlan(pattern: .minimalMontage, beats: [], reasons: [])
    let timeline = Timeline(storyPlanID: plan.id, items: items)
    let presented = EditorialPresentationPolicy.chapters(in: timeline, plan: plan)
    let repeated = EditorialPresentationPolicy.chapters(in: presented, plan: plan)
    #expect(repeated.effectiveTitleItems == presented.effectiveTitleItems)
    let delivered = TimelineDeliveryContract().validateAndRepair(timeline: repeated, plan: plan, assets: []).timeline
    #expect(delivered.effectiveTitleItems.map(\.text) == labels)
    #expect(delivered.effectiveTitleItems.map(\.startTime) == [0, 3, 6])
    #expect(Set(delivered.effectiveTitleItems.map(\.id)).count == 3)
    #expect(delivered.effectiveTitleItems.allSatisfy { $0.duration >= 1.25 && $0.duration <= 3 })
}

@Test func shortActivityBlockOmitsUnreadableTitleAndKeepsNeighborsInsideTheirScenes() throws {
    let cycling = p4Asset("short-card-cycling", date: p4BaseDate)
    let buggy = p4Asset("short-card-buggy", date: p4BaseDate.addingTimeInterval(31))
    let rafting = p4Asset("short-card-rafting", date: p4BaseDate.addingTimeInterval(62))
    let assets = [cycling, buggy, rafting]
    let analyses = [
        p4Analysis(asset: cycling, tags: ["cycling", "bicycle"], sourceDuration: 10),
        p4Analysis(asset: buggy, tags: ["buggy", "dirt_road", "car"], sourceDuration: 1),
        p4Analysis(asset: rafting, tags: ["rafting", "kayak"], sourceDuration: 10)
    ]
    let scenes = [
        EventScene(
            title: "Велопрогулка",
            assetIDs: [cycling.id],
            candidateIDs: analyses[0].candidates.map(\.id),
            phase: .setup,
            confidence: 0.92
        ),
        EventScene(
            title: "Багги",
            assetIDs: [buggy.id],
            candidateIDs: analyses[1].candidates.map(\.id),
            phase: .action,
            confidence: 0.94
        ),
        EventScene(
            title: "Сплав",
            assetIDs: [rafting.id],
            candidateIDs: analyses[2].candidates.map(\.id),
            phase: .conclusion,
            confidence: 0.93
        )
    ]
    let event = Event(
        title: "Активный день",
        assetIDs: assets.map(\.id),
        confidence: 0.92,
        titleConfidence: 0.90,
        scenes: scenes,
        quality: p4Quality(total: 0.82, usable: 0.90, story: 0.80, action: 0.78, diversity: 0.86)
    )
    var constraints = PromptInterpreter.defaults(for: .story)
    constraints.targetDuration = 21
    constraints.targetClipCount = 3

    let plan = StoryEngine().createPlan(
        prompt: "Собери фильм на 21 секунду. Титры только для активностей.",
        preset: .story,
        constraints: constraints,
        assets: assets,
        analyses: analyses,
        events: [event]
    )
    let timeline = TimelineComposer().compose(plan: plan, assets: assets, analyses: analyses)
    let titles = timeline.effectiveTitleItems

    #expect(plan.eventStory?.chapterCardsEnabled == true)
    #expect(Set(titles.map(\.text)) == ["Велопрогулка", "Сплав"])
    let titledSceneIDs = ["Велопрогулка": scenes[0].id, "Сплав": scenes[2].id]
    for title in titles {
        guard let sceneID = titledSceneIDs[title.text] else { continue }
        let blockItems = timeline.items.filter { $0.eventSceneID == sceneID }
        let blockStart = try #require(blockItems.map(\.timelineStart).min())
        let blockEnd = try #require(blockItems.map { $0.timelineStart + $0.timelineDuration }.max())
        #expect(title.startTime >= blockStart - 0.001)
        #expect(title.endTime <= blockEnd + 0.001)
    }
}

@Test func structuralScenePhasesDoNotBecomeActivityTitles() {
    let definitions: [(String, EventScenePhase)] = [
        ("Знакомство с местом", .setup),
        ("Подготовка", .preparation),
        ("В движении", .action),
        ("Пик маршрута", .peak),
        ("Реакция", .reaction),
        ("Дорога домой", .conclusion)
    ]
    let assets = definitions.indices.map { index in
        p4Asset("unknown-phase-\(index)", date: p4BaseDate.addingTimeInterval(Double(index) * 31))
    }
    let analyses = assets.map { asset in
        p4Analysis(asset: asset, tags: ["outdoor", "land"], sourceStart: 2, sourceDuration: 5)
    }
    let scenes = definitions.enumerated().map { index, definition in
        EventScene(
            title: definition.0,
            assetIDs: [assets[index].id],
            candidateIDs: analyses[index].candidates.map(\.id),
            phase: definition.1,
            confidence: 0.82
        )
    }
    let event = Event(
        title: "Съёмка",
        assetIDs: assets.map(\.id),
        confidence: 0.82,
        titleConfidence: 0.72,
        scenes: scenes,
        quality: p4Quality(total: 0.72, usable: 0.82, story: 0.68)
    )
    var constraints = PromptInterpreter.defaults(for: .story)
    constraints.targetDuration = 30
    constraints.targetClipCount = 6

    let plan = StoryEngine().createPlan(
        prompt: "Собери фильм на 30 секунд. Титры только для ключевых активностей.",
        preset: .story,
        constraints: constraints,
        assets: assets,
        analyses: analyses,
        events: [event]
    )
    let timeline = TimelineComposer().compose(plan: plan, assets: assets, analyses: analyses)

    #expect(plan.eventStory?.chapterCardsEnabled == false)
    #expect(plan.chapters.allSatisfy { $0.chapterCardTitle == nil })
    #expect(timeline.effectiveTitleItems.isEmpty)
}

@Test func storyHierarchyQualityGateRestoresFlattenedActivityBoundaries() throws {
    let cyclingAsset = p4Asset("quality-gate-cycling", date: p4BaseDate)
    let buggyAsset = p4Asset("quality-gate-buggy", date: p4BaseDate.addingTimeInterval(31))
    let analyses = [
        p4Analysis(asset: cyclingAsset, tags: ["cycling", "bicycle"], sourceDuration: 5),
        p4Analysis(asset: buggyAsset, tags: ["buggy", "dirt_road", "helmet"], sourceDuration: 5)
    ]
    let cyclingID = try #require(analyses[0].candidates.first?.id)
    let buggyID = try #require(analyses[1].candidates.first?.id)
    let cycling = EventScene(
        title: "Велопрогулка",
        assetIDs: [cyclingAsset.id],
        candidateIDs: [cyclingID],
        tags: ["cycling"],
        phase: .setup,
        confidence: 0.92
    )
    let buggy = EventScene(
        title: "Багги",
        assetIDs: [buggyAsset.id],
        candidateIDs: [buggyID],
        tags: ["buggy"],
        phase: .action,
        confidence: 0.94
    )
    let event = Event(
        title: "Съёмка",
        assetIDs: [cyclingAsset.id, buggyAsset.id],
        scenes: [cycling, buggy]
    )
    let flattened = StoryChapter(
        title: "Кульминация",
        candidateIDs: [cyclingID, buggyID],
        role: .climax,
        eventID: event.id,
        eventSceneID: cycling.id,
        chapterCardTitle: "Ключевой момент",
        allocatedDuration: 10,
        coveragePlan: SceneCoveragePlan(
            eventID: event.id,
            sceneID: cycling.id,
            requirements: [],
            explanation: "legacy flattened chapter"
        )
    )
    let candidateByID = Dictionary(uniqueKeysWithValues: analyses.flatMap(\.candidates).map { ($0.id, $0) })
    let review = StoryHierarchyQualityGate().repair(
        chapters: [flattened],
        events: [event],
        candidates: candidateByID,
        chapterCardsEnabled: true
    )

    #expect(review.chapters.count == 2)
    #expect(review.chapters.map(\.eventSceneID) == [cycling.id, buggy.id])
    #expect(review.chapters.map(\.chapterCardTitle) == ["Велопрогулка", "Багги"])
    #expect(review.chapters.map { $0.coveragePlan?.sceneID } == [cycling.id, buggy.id])
    #expect(review.chapters[0].allocatedDuration == 10)
    #expect(review.chapters[1].allocatedDuration == nil)
    #expect(review.diagnostics.contains { $0.code == "restored-scene-boundary" })
    #expect(review.diagnostics.contains { $0.code == "repaired-title-provenance" })
}

@Test func timelineSafetyRejectsDirectorRepairThatDropsAPlannedSceneBlock() {
    let eventID = UUID()
    let cyclingSceneID = UUID()
    let buggySceneID = UUID()
    let cycling = TimelineItem(
        candidateID: UUID(),
        kind: .video,
        sourceStart: 0,
        sourceDuration: 3,
        timelineStart: 0,
        timelineDuration: 3,
        eventID: eventID,
        eventSceneID: cyclingSceneID
    )
    let buggy = TimelineItem(
        candidateID: UUID(),
        kind: .video,
        sourceStart: 0,
        sourceDuration: 3,
        timelineStart: 3,
        timelineDuration: 3,
        eventID: eventID,
        eventSceneID: buggySceneID
    )
    let plan = StoryPlan(
        prompt: "Фильм из двух активностей",
        preset: .story,
        constraints: StoryConstraints(targetDuration: 6),
        chapters: [
            StoryChapter(title: "Велопрогулка", candidateIDs: [cycling.candidateID!], eventID: eventID, eventSceneID: cyclingSceneID),
            StoryChapter(title: "Багги", candidateIDs: [buggy.candidateID!], eventID: eventID, eventSceneID: buggySceneID)
        ],
        eventStory: EventStoryPlan(
            entries: [EventStoryEntry(eventID: eventID, title: "Активный день", startDate: nil, endDate: nil, allocatedDuration: 6, quality: 0.8, sceneIDs: [cyclingSceneID, buggySceneID])]
        )
    )
    let original = Timeline(storyPlanID: plan.id, items: [cycling, buggy])
    let repair = Timeline(storyPlanID: plan.id, items: [cycling])
    let issues = TimelineSafetyValidator().violations(
        candidate: repair,
        comparedTo: original,
        plan: plan,
        analyses: []
    )

    #expect(issues.contains("Repair удаляет подтверждённый scene block"))
}

@Test func overlappingEventScenesConsumeEachCandidateOnlyOnce() {
    let first = p4Asset("overlap-scene-a", date: p4BaseDate)
    let second = p4Asset("overlap-scene-b", date: p4BaseDate.addingTimeInterval(31))
    let analyses = [
        p4Analysis(asset: first, tags: ["cycling", "bicycle"], sourceDuration: 5),
        p4Analysis(asset: second, tags: ["cycling", "bicycle"], sourceDuration: 5)
    ]
    let firstID = analyses[0].candidates[0].id
    let secondID = analyses[1].candidates[0].id
    let firstScene = EventScene(
        title: "Велопрогулка",
        assetIDs: [first.id],
        candidateIDs: [firstID],
        phase: .setup,
        confidence: 0.9
    )
    let overlappingScene = EventScene(
        title: "Велопрогулка",
        assetIDs: [first.id, second.id],
        candidateIDs: [firstID, secondID],
        phase: .action,
        confidence: 0.9
    )
    let event = Event(
        title: "Велопрогулка",
        assetIDs: [first.id, second.id],
        scenes: [firstScene, overlappingScene],
        quality: p4Quality(total: 0.78, usable: 0.86, story: 0.74)
    )
    var constraints = PromptInterpreter.defaults(for: .story)
    constraints.targetDuration = 10
    constraints.targetClipCount = 2

    let plan = StoryEngine().createPlan(
        prompt: "Собери фильм на 10 секунд",
        preset: .story,
        constraints: constraints,
        assets: [first, second],
        analyses: analyses,
        events: [event]
    )
    let plannedIDs = plan.chapters.flatMap(\.candidateIDs)
    let timeline = TimelineComposer().compose(plan: plan, assets: [first, second], analyses: analyses)

    #expect(!plannedIDs.isEmpty)
    #expect(plannedIDs.filter { $0 == firstID }.count <= 1)
    #expect(plannedIDs.filter { $0 == secondID }.count <= 1)
    #expect(timeline.items.compactMap(\.candidateID).filter { $0 == firstID }.count <= 1)
    #expect(timeline.items.compactMap(\.candidateID).filter { $0 == secondID }.count <= 1)
}

@Test func eventDiscoveryMergesNearbyCrossDeviceMomentWithoutGuessingClockOffset() throws {
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
    #expect(result.diagnostics.deviceTimeOffsets.isEmpty)
    #expect(event.evidence?.contains { $0.kind == "cross-device" } == true)
}

@Test func oneContinuousOutingKeepsDifferentActivitiesAsScenesInsideOneMacroEvent() throws {
    let cycling = p4Asset("GOPR0456", date: p4BaseDate)
    let buggy = p4Asset("GP010456", date: p4BaseDate.addingTimeInterval(120))
    let analyses = [
        p4Analysis(asset: cycling, tags: ["cycling", "cyclist", "bicycle", "forest"]),
        p4Analysis(asset: buggy, tags: ["buggy", "utv", "dirt_road", "helmet"])
    ]

    let result = EventIntelligenceEngine().discover(assets: [buggy, cycling], analyses: analyses)
    let event = try #require(result.events.first)

    #expect(result.events.count == 1)
    #expect(event.assetIDs.count == 2)
    #expect(event.effectiveScenes.count == 2)
    #expect(Set(event.effectiveScenes.map(\.title)) == Set(["Велопрогулка", "Багги"]))
}

@Test func incompatibleActivitiesRejectUncorroboratedLegacyIDWithWeakClockAndNoGPS() {
    var cycling = p4Asset("legacy-weak-cycling", date: p4BaseDate)
    var buggy = p4Asset("legacy-weak-buggy", date: p4BaseDate.addingTimeInterval(5))
    cycling.metadata.creationDate = nil
    cycling.metadata.modificationDate = nil
    cycling.metadata.dateSource = .importDate
    cycling.metadata.dateConfidence = 0.12
    cycling.importedAt = p4BaseDate
    buggy.metadata.creationDate = nil
    buggy.metadata.modificationDate = nil
    buggy.metadata.dateSource = .importDate
    buggy.metadata.dateConfidence = 0.12
    buggy.importedAt = p4BaseDate.addingTimeInterval(5)
    let embedding = VisualEmbedding(
        modelIdentifier: "legacy-fixture",
        values: [1] + Array(repeating: 0, count: 63),
        confidence: 0.99
    )
    var analyses = [
        p4Analysis(asset: cycling, tags: ["cycling", "bicycle", "outdoor"]),
        p4Analysis(asset: buggy, tags: ["buggy", "utv", "outdoor"])
    ]
    for index in analyses.indices {
        analyses[index].candidates[0].insights?.semanticEventID = "legacy-mixed-outdoor-event"
        analyses[index].candidates[0].insights?.visualEmbedding = embedding
    }

    let result = EventIntelligenceEngine().discover(assets: [cycling, buggy], analyses: analyses)

    #expect(result.events.count == 2)
    #expect(result.events.allSatisfy { $0.assetIDs.count == 1 })
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
    #expect(fallback.metadata.effectiveCaptureDate == nil)
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

@Test func exactEventDurationAllocationPreservesTheRequestedTotalDespiteQualityCaps() {
    let first = Event(
        title: "First",
        assetIDs: [UUID()],
        quality: p4Quality(total: 0.82, usable: 0.80, story: 0.84)
    )
    let second = Event(
        title: "Second",
        assetIDs: [UUID()],
        quality: p4Quality(total: 0.82, usable: 0.82, story: 0.84)
    )

    let values = EventDurationAllocator().allocate(
        events: [first, second],
        totalDuration: 300,
        strategy: "cinematic-motion",
        requiresExactTotal: true
    )

    #expect(abs(values.values.reduce(0, +) - 300) < 0.001)
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
        if let path = ProcessInfo.processInfo.environment["VELOEDIT_EVENT_INTEGRATION_DIAGNOSTICS"] {
            let directory = URL(fileURLWithPath: path, isDirectory: true)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? FileManager.default.copyItem(at: root, to: directory.appendingPathComponent(root.lastPathComponent))
        }
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: tasteURL)
    }
    let store = try ProjectStore(createAt: root, name: "P4 event production")
    let (fixtureAssets, analyses) = p4ProductionFixture()
    let assets = try await materializeEditorialFixtureMedia(fixtureAssets, at: root)
    try await store.update { project in
        project.assets = assets
        project.analyses = analyses
    }
    try await store.update { $0.editorialDevelopmentEnabled = true }
    let pipeline = VeloEditPipeline(store: store, renderedProber: FixtureEditorialProber(), analyzer: FixtureEditorialAnalyzer(analyses: analyses), personalTasteStore: LocalPersonalTasteStore(url: tasteURL))
    let timeline = try await pipeline.createFilm(
        prompt: "Без музыки. Собери цельную хронологическую историю поездки.",
        preset: .summerFilm
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
    #expect(timeline.effectiveTitleItems.allSatisfy { !SmartTitleEngine.isMeaningless($0.text) })
    #expect(timeline.effectiveTitleItems.filter { $0.kind == .chapter }.count >= 3)
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
