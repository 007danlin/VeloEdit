import Foundation
import Testing
@testable import VeloEditCore

/// Optional real-media check on an explicitly prepared audit copy. Manual
/// labels come from separately reviewed frames, never production filename rules.
@Test(.enabled(if: ProcessInfo.processInfo.environment["VELOEDIT_DIRECTOR_AUDIT_COPY"] != nil))
func directorRealProjectRepairAndRenderOnCopy() async throws {
    let path = try #require(ProcessInfo.processInfo.environment["VELOEDIT_DIRECTOR_AUDIT_COPY"])
    let package = URL(fileURLWithPath: path).standardizedFileURL
    let root = package.deletingLastPathComponent()
    try #require(FileManager.default.fileExists(atPath: root.appendingPathComponent("audit-copy-marker").path))
    let store = try ProjectStore(open: package)
    let original = await store.manifest
    var timeline = try #require(original.timelines.last)
    var plan = try #require(original.storyPlans.first { $0.id == timeline.storyPlanID })
    let labels = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: root.appendingPathComponent("verified-activity-labels.json")))
    let byCandidate = Dictionary(original.analyses.flatMap(\.directorCandidates).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    for index in plan.chapters.indices {
        let label = plan.chapters[index].candidateIDs.compactMap { byCandidate[$0]?.assetID.uuidString }.compactMap { labels[$0] }.first
        if let label { plan.chapters[index].title = label; plan.chapters[index].chapterCardTitle = label }
    }
    plan.prompt += "\nБез перебивок, эффектов и цветокоррекции. Титры в начале каждой части."
    plan.directorBrief?.titlePolicy = .keyOnly
    timeline = EditorialIntentEnforcer.enforce(timeline, plan: plan)
    timeline.effects = []
    for index in timeline.items.indices {
        var video = timeline.items[index].effectiveVideoAdjustments
        video.filter = .none; video.exposure = 0; video.brightness = 0
        video.contrast = 1; video.saturation = 1; video.warmth = 0
        video.tint = 0; video.highlights = 0; video.shadows = 0; video.vignette = 0; video.grain = 0
        timeline.items[index].videoAdjustments = video.isNeutral ? nil : video
    }
    #expect(EditorialPresentationPolicy.missingChapterTitles(in: timeline, plan: plan).isEmpty)
    #expect(timeline.effectiveTitleItems.first?.startTime == 0)
    #expect(!timeline.items.contains { $0.overlay != nil })
    #expect(timeline.effectiveOriginalAudioVolume == 0.20)
    #expect(timeline.audioDucking?.enabled == false)
    timeline.editorialReview = nil // An edited copy cannot reuse an old render certificate.
    timeline.directorRun = nil
    timeline.versionName = "Проверка исправлений режиссёра"
    try await store.update { project in
        project.storyPlans = [plan]
        project.timelines = [timeline]
        project.workspaceState?.prompt = plan.prompt
        project.workspaceState?.directorBrief = plan.directorBrief
        project.workspaceState?.pendingDirectorInstructions = []
        project.workspaceState?.hasPendingFilmChanges = false
    }
    let pipeline = VeloEditPipeline(store: store, musicLibrary: LocalMusicLibrary(rootURL: package.appendingPathComponent("MusicLibrary")),
                                   musicSelectionHistory: LocalMusicSelectionHistoryStore(url: root.appendingPathComponent("music-history.json")),
                                   personalTasteStore: LocalPersonalTasteStore(url: root.appendingPathComponent("taste.json")))
    if let trackPath = ProcessInfo.processInfo.environment["VELOEDIT_DIRECTOR_AUDIT_TRACK"] {
        let track = try JSONDecoder.veloEdit.decode(LocalMusicTrack.self, from: Data(contentsOf: URL(fileURLWithPath: trackPath)))
        let imported = try await LocalMusicLibrary(rootURL: package.appendingPathComponent("MusicLibrary")).importExistingTrack(track)
        try await pipeline.updateMusic(MusicDirective(style: imported.suggestedStyle, bpm: imported.bpm, trackID: imported.id, trackTitle: imported.title))
    } else {
        try await pipeline.updateMusic(MusicDirective(style: .cinematic, bpm: 90, preferDifferentTrack: true))
    }
    let current = await store.manifest
    let fixed = try #require(current.timelines.last)
    #expect(fixed.effectiveOriginalAudioVolume == 0.20)
    #expect(fixed.audioDucking?.enabled == false)
    let tracks = try await pipeline.musicTracks()
    let selected = try #require(tracks.first { $0.id == fixed.music?.trackID })
    let output = root.appendingPathComponent("corrected-preview.mp4")
    _ = try await RenderEngine().render(timeline: fixed, assets: current.assets, musicTracks: tracks,
        quality: .preview720p, destination: output)
    struct Report: Codable {
        var duration: Double
        var titleTimes: [Double]
        var titles: [String]
        var track: String
        var provider: String
        var musicNotice: String?
        var output: String
    }
    let report = Report(duration: fixed.duration, titleTimes: fixed.effectiveTitleItems.map(\.startTime), titles: fixed.effectiveTitleItems.map(\.text),
                        track: selected.title, provider: selected.sourceProvider.rawValue, musicNotice: await pipeline.musicSearchNotice(), output: output.path)
    try JSONEncoder.veloEdit.encode(report).write(to: root.appendingPathComponent("result.json"), options: .atomic)
}
