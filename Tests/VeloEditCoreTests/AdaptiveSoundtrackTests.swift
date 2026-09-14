import Foundation
import Testing
@testable import VeloEditCore

@Test func adaptiveSoundtrackFollowsConfidentActivityJourney() throws {
    let fixture = try AdaptiveSoundtrackFixture()
    defer { fixture.removeFiles() }
    let buggyEvent = UUID()
    let fishingEvent = UUID()
    let cyclingEvent = UUID()
    let sections: [(String, Double, StoryRole, UUID)] = [
        ("fast buggy offroad action", 0.92, .action, buggyEvent),
        ("buggy rally dust", 0.84, .climax, buggyEvent),
        ("quiet fishing lake nature", 0.16, .reaction, fishingEvent),
        ("fishing with rod on calm lake", 0.20, .setup, fishingEvent),
        ("dynamic bicycle cycling trail", 0.72, .action, cyclingEvent),
        ("mountain bike cycling finish", 0.78, .climax, cyclingEvent),
    ]
    let material = makeAdaptiveMaterial(sections: sections, transitionIndexes: [2, 4])
    let timeline = Timeline(
        storyPlanID: UUID(),
        items: material.items,
        music: MusicDirective(
            style: .energetic,
            bpm: fixture.action.bpm,
            volume: 0.2,
            trackID: fixture.action.id,
            trackTitle: fixture.action.title
        )
    )

    let directed = AdaptiveSoundtrackPlanner().applying(
        to: timeline,
        tracks: fixture.tracks,
        analyses: material.analyses,
        structures: fixture.structures
    )
    let plan = try #require(directed.effectiveAdaptiveSoundtrack)
    #expect(plan.segments.count == 3)
    #expect(plan.segments.map(\.activityKey) == ["action-vehicle", "fishing", "cycling"])
    #expect(plan.segments.map(\.timelineStart) == [0, 20, 40])
    #expect(plan.segments[1].directive.style == .calm)
    #expect(plan.segments[0].directive.trackID != plan.segments[1].directive.trackID)
    #expect(plan.segments[1].directive.trackID != plan.segments[2].directive.trackID)
    #expect(plan.segments.dropFirst().allSatisfy { $0.transitionDuration >= 0.45 })
    #expect(plan.segments.dropFirst().allSatisfy { $0.boundaryItemID != nil })
}

@Test func adaptiveSoundtrackKeepsOneTrackForOneActivity() throws {
    let fixture = try AdaptiveSoundtrackFixture()
    defer { fixture.removeFiles() }
    let sections = (0..<6).map { index in
        ("buggy offroad action camera angle \(index)", 0.48 + Double(index) * 0.08, StoryRole.action, UUID())
    }
    let material = makeAdaptiveMaterial(sections: sections, transitionIndexes: [2, 4])
    let timeline = Timeline(
        storyPlanID: UUID(),
        items: material.items,
        music: MusicDirective(style: .energetic, bpm: 132, trackID: fixture.action.id)
    )

    let directed = AdaptiveSoundtrackPlanner().applying(
        to: timeline,
        tracks: fixture.tracks,
        analyses: material.analyses,
        structures: fixture.structures
    )
    #expect(directed.adaptiveSoundtrack == nil)
    #expect(directed.music?.trackID == fixture.action.id)
}

@Test func adaptiveSoundtrackKeepsPreviousMusicWhenSemanticBoundaryIsUncertain() throws {
    let fixture = try AdaptiveSoundtrackFixture()
    defer { fixture.removeFiles() }
    let sections: [(String, Double, StoryRole, UUID)] = [
        ("morning detail", 0.42, .intro, UUID()),
        ("wide view", 0.46, .setup, UUID()),
        ("close detail", 0.50, .buildup, UUID()),
        ("evening view", 0.45, .reaction, UUID()),
    ]
    let material = makeAdaptiveMaterial(sections: sections, transitionIndexes: [2], includeEventIDs: false)
    let timeline = Timeline(
        storyPlanID: UUID(),
        items: material.items,
        music: MusicDirective(style: .cinematic, bpm: 88, trackID: fixture.cinematic.id)
    )

    let directed = AdaptiveSoundtrackPlanner().applying(
        to: timeline,
        tracks: fixture.tracks,
        analyses: material.analyses,
        structures: fixture.structures
    )
    #expect(directed.adaptiveSoundtrack == nil)
    #expect(directed.music?.trackID == fixture.cinematic.id)
}

@Test func explicitTrackPolicyDisablesAdaptiveSoundtrack() throws {
    let fixture = try AdaptiveSoundtrackFixture()
    defer { fixture.removeFiles() }
    let material = makeAdaptiveMaterial(sections: [
        ("buggy offroad", 0.9, .action, UUID()),
        ("buggy rally", 0.85, .climax, UUID()),
        ("fishing lake", 0.15, .reaction, UUID()),
        ("fishing rod", 0.2, .setup, UUID()),
    ], transitionIndexes: [2])
    let brief = DirectorBrief(
        requestedDuration: 40,
        musicPolicy: .specificTrack,
        musicTrackID: fixture.action.id
    )
    let story = StoryPlan(
        prompt: "Собери фильм",
        preset: .story,
        constraints: StoryConstraints(targetDuration: 40),
        chapters: [],
        directorBrief: brief
    )
    let timeline = Timeline(
        storyPlanID: story.id,
        items: material.items,
        music: MusicDirective(style: .energetic, bpm: 132, trackID: fixture.action.id)
    )

    let directed = AdaptiveSoundtrackPlanner().applying(
        to: timeline,
        plan: story,
        tracks: fixture.tracks,
        analyses: material.analyses,
        structures: fixture.structures
    )
    #expect(directed.adaptiveSoundtrack == nil)
}

@Test func adaptiveSoundtrackInvalidatesAfterManualTrackOrTimingChange() {
    let firstID = UUID()
    let secondID = UUID()
    let segments = [
        AdaptiveMusicSegment(
            timelineStart: 0,
            timelineDuration: 12,
            directive: MusicDirective(style: .energetic, bpm: 126, trackID: firstID),
            semanticLabel: "Экшен",
            energy: 0.8,
            confidence: 1
        ),
        AdaptiveMusicSegment(
            timelineStart: 12,
            timelineDuration: 12,
            directive: MusicDirective(style: .calm, bpm: 72, trackID: secondID),
            transitionDuration: 1,
            semanticLabel: "Природа",
            energy: 0.2,
            confidence: 0.9
        ),
    ]
    var timeline = Timeline(
        storyPlanID: UUID(),
        items: [
            TimelineItem(kind: .video, sourceDuration: 12, timelineStart: 0, timelineDuration: 12),
            TimelineItem(kind: .video, sourceDuration: 12, timelineStart: 12, timelineDuration: 12),
        ],
        music: MusicDirective(style: .energetic, bpm: 126, trackID: firstID)
    )
    timeline.adaptiveSoundtrack = AdaptiveSoundtrackPlan(
        primaryTrackID: firstID,
        timelineDuration: 24,
        timelineFingerprint: timeline.adaptiveSoundtrackFingerprint,
        segments: segments,
        confidence: 0.9
    )
    #expect(timeline.effectiveAdaptiveSoundtrack != nil)

    var trackChanged = timeline
    trackChanged.music?.trackID = UUID()
    #expect(trackChanged.effectiveAdaptiveSoundtrack == nil)

    var timingChanged = timeline
    timingChanged.items[0].timelineDuration = 13
    #expect(timingChanged.effectiveAdaptiveSoundtrack == nil)

    var reordered = timeline
    reordered.items.swapAt(0, 1)
    reordered.items = TimelineTiming.retimed(reordered.items)
    #expect(reordered.duration == timeline.duration)
    #expect(reordered.effectiveAdaptiveSoundtrack == nil)
}

private struct AdaptiveSoundtrackFixture {
    let directory: URL
    let action: LocalMusicTrack
    let calm: LocalMusicTrack
    let cycling: LocalMusicTrack
    let cinematic: LocalMusicTrack
    let tracks: [LocalMusicTrack]
    let structures: [UUID: MusicStructure]

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("veloedit-adaptive-music-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        action = try Self.track(in: directory, title: "Action Drive", bpm: 132, energy: 0.88, tags: ["energetic", "action", "dynamic"])
        calm = try Self.track(in: directory, title: "Lake Air", bpm: 72, energy: 0.18, tags: ["calm", "ambient", "soft"])
        cycling = try Self.track(in: directory, title: "Bright Ride", bpm: 118, energy: 0.68, tags: ["joyful", "upbeat", "cycling"])
        cinematic = try Self.track(in: directory, title: "Journey", bpm: 88, energy: 0.48, tags: ["cinematic", "film", "atmospheric"])
        tracks = [action, calm, cycling, cinematic]
        structures = Dictionary(uniqueKeysWithValues: tracks.map { track in
            let beat = 60 / track.bpm
            return (track.id, MusicStructure(
                bpm: track.bpm,
                beatInterval: beat,
                sections: [
                    MusicSection(kind: .intro, start: 0, duration: 8, energy: track.energy * 0.72, confidence: 0.9),
                    MusicSection(kind: .chorus, start: 8, duration: 52, energy: track.energy, confidence: 0.9),
                ],
                barBoundaries: stride(from: 0.0, through: 60.0, by: beat * 4).map { $0 },
                phraseBoundaries: stride(from: 0.0, through: 60.0, by: beat * 16).map { $0 },
                phraseConfidence: 0.9,
                analysisIsMeasured: true
            ))
        })
    }

    func removeFiles() {
        try? FileManager.default.removeItem(at: directory)
    }

    private static func track(
        in directory: URL,
        title: String,
        bpm: Double,
        energy: Double,
        tags: [String]
    ) throws -> LocalMusicTrack {
        let url = directory.appendingPathComponent("\(title).m4a")
        try Data([0]).write(to: url)
        return LocalMusicTrack(
            title: title,
            author: "VeloEdit Tests",
            bpm: bpm,
            genres: tags,
            moods: tags,
            energy: energy,
            duration: 60,
            license: MusicLicenseRecord.userFile(),
            sourceProvider: .user,
            sourcePageURL: URL(string: "about:blank")!,
            localFileURL: url,
            originalFileName: url.lastPathComponent,
            tags: tags,
            musicalKey: "C major"
        )
    }
}

private func makeAdaptiveMaterial(
    sections: [(String, Double, StoryRole, UUID)],
    transitionIndexes: Set<Int>,
    includeEventIDs: Bool = true
) -> (items: [TimelineItem], analyses: [AnalysisResult]) {
    let assetID = UUID()
    var candidates: [Candidate] = []
    var items: [TimelineItem] = []
    for (index, section) in sections.enumerated() {
        let candidate = Candidate(
            assetID: assetID,
            sourceStart: Double(index) * 10,
            sourceDuration: 10,
            scores: ClipScores(quality: 0.8, interest: 0.8, action: section.1, stability: 0.8),
            tags: Set(section.0.components(separatedBy: " ")),
            insights: CandidateInsights(
                sceneSummary: section.0,
                dynamics: section.1,
                visualAppeal: 0.8,
                storyValue: 0.8
            )
        )
        candidates.append(candidate)
        items.append(TimelineItem(
            candidateID: candidate.id,
            assetID: assetID,
            kind: .video,
            sourceStart: Double(index) * 10,
            sourceDuration: 10,
            timelineStart: Double(index) * 10,
            timelineDuration: 10,
            transition: transitionIndexes.contains(index) ? TransitionStyle.crossDissolve.rawValue : nil,
            storyRole: section.2,
            editorialPurpose: section.0,
            incomingEditDecision: transitionIndexes.contains(index)
                ? EditorialBoundaryDecision(choice: .transition, motivation: "Новая часть", confidence: 0.9, transitionStyle: .crossDissolve)
                : nil,
            eventID: includeEventIDs ? section.3 : nil
        ))
    }
    let analysis = AnalysisResult(
        assetID: assetID,
        analyzedContentHash: "adaptive-soundtrack",
        candidates: candidates
    )
    return (items, [analysis])
}

@Test func dynamicMusicAcquisitionUsesSceneBoundariesBeforeTracksExist() throws {
    let sections: [(String, Double, StoryRole, UUID)] = [
        ("fast buggy offroad action", 0.92, .action, UUID()),
        ("buggy rally dust", 0.84, .climax, UUID()),
        ("quiet fishing lake nature", 0.16, .reaction, UUID()),
        ("fishing with rod on calm lake", 0.20, .setup, UUID()),
        ("dynamic bicycle cycling trail", 0.72, .action, UUID()),
        ("mountain bike cycling finish", 0.78, .climax, UUID())
    ]
    let material = makeAdaptiveMaterial(sections: sections, transitionIndexes: [2, 4])
    let searches = MusicSearchRequest.parse("Для багги агрессивная rock музыка; для рыбалки спокойная атмосферная музыка; для велосипеда лёгкий летний трек")
    let timeline = Timeline(storyPlanID: UUID(), items: material.items,
        music: MusicDirective(style: .energetic, bpm: 128, searchRequests: searches))
    let requests = AdaptiveSoundtrackPlanner().requests(for: timeline, analyses: material.analyses)
    #expect(requests.count == 3)
    #expect(requests.map(\.sceneType) == ["action-vehicle", "fishing", "cycling"])
    #expect(requests[0].searchQuery.contains("rock"))
    #expect(requests[1].searchQuery.contains("calm"))
    #expect(requests[2].searchQuery.contains("summer"))
}

@Test func dynamicMusicUsesSeveralNamedSongsEvenWithinOneActivity() throws {
    let fixture = try AdaptiveSoundtrackFixture()
    defer { fixture.removeFiles() }
    let material = makeAdaptiveMaterial(sections: (0..<6).map {
        ("buggy action camera angle \($0)", 0.8, StoryRole.action, UUID())
    }, transitionIndexes: [])
    let requests = [fixture.action, fixture.calm, fixture.cycling].map {
        MusicSearchRequest(query: $0.author + " — " + $0.title, exactTrack: true)
    }
    let timeline = Timeline(storyPlanID: UUID(), items: material.items,
        music: MusicDirective(style: .energetic, bpm: 128, trackID: fixture.action.id, searchRequests: requests))
    let result = AdaptiveSoundtrackPlanner().applying(to: timeline, tracks: fixture.tracks, analyses: material.analyses, structures: fixture.structures)
    #expect(result.effectiveAdaptiveSoundtrack?.segments.map(\.directive.trackID) == [fixture.action.id, fixture.calm.id, fixture.cycling.id])
    var single = timeline
    single.music?.searchRequests = [requests[0]]
    #expect(AdaptiveSoundtrackPlanner().applying(to: single, tracks: fixture.tracks, analyses: material.analyses).adaptiveSoundtrack == nil)
}
