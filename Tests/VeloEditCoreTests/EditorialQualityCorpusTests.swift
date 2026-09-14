import Foundation
import CryptoKit
import Testing
@testable import VeloEditCore

/// Opt-in real-media run. The paired project copies are prepared separately;
/// the source project and shared soundtrack audio files are never modified.
@Test(.enabled(if: ProcessInfo.processInfo.environment["VELOEDIT_EDITORIAL_CORPUS_PROJECT"] != nil))
func editorialQualityRealCorpusCase() async throws {
    let package = URL(fileURLWithPath: ProcessInfo.processInfo.environment["VELOEDIT_EDITORIAL_CORPUS_PROJECT"]!)
    let store = try ProjectStore(open: package)
    let initial = await store.manifest
    try #require(initial.timelines.isEmpty && initial.storyPlans.isEmpty && initial.filmBuildRecovery == nil)
    let library = LocalMusicLibrary(rootURL: store.musicLibraryURL)
    // No online provider, reusable global cache or automatic history from
    // another case can change the comparison's frozen local music pool.
    let music = MusicLibrary(localLibrary: library, providers: [LocalMusicProvider(library: library)])
    let pipeline = VeloEditPipeline(store: store, musicLibrary: library, musicSystem: music,
        musicSelectionHistory: LocalMusicSelectionHistoryStore(url: package.appendingPathComponent("qa-history.json")),
        personalTasteStore: LocalPersonalTasteStore(url: package.appendingPathComponent("qa-taste.json")))
    let prompt = try #require(initial.workspaceState?.prompt)
    let started = ProcessInfo.processInfo.systemUptime
    let timeline: Timeline
    do {
        timeline = try await pipeline.createFilm(prompt: prompt, preset: .adventure,
            targetDuration: initial.workspaceState?.directorBrief?.explicitRequestedDuration,
            directorBrief: initial.workspaceState?.directorBrief,
            progress: { progress in print("CORPUS \(progress)") })
    } catch {
        let failure: [String: String] = ["status": "generation-failed", "error": error.localizedDescription,
            "elapsedSeconds": String(ProcessInfo.processInfo.systemUptime - started), "humanReview": "not-performed"]
        try JSONEncoder().encode(failure).write(to: package.appendingPathComponent("quality-result.json"), options: .atomic)
        throw error
    }
    let created = ProcessInfo.processInfo.systemUptime
    let destination = package.deletingLastPathComponent().appendingPathComponent(package.deletingPathExtension().lastPathComponent + ".mp4")
    _ = try await pipeline.render(to: destination, quality: .preview720p)
    let hash = SHA256.hash(data: try Data(contentsOf: destination)).map { String(format: "%02x", $0) }.joined()
    let result: [String: String] = ["status": "rendered-awaiting-full-human-review", "output": destination.path,
        "sha256": hash, "creationSeconds": String(created - started), "exportSeconds": String(ProcessInfo.processInfo.systemUptime - created),
        "duration": String(timeline.duration), "track": timeline.music?.trackTitle ?? "none", "timelineID": timeline.id.uuidString,
        "humanReview": "not-performed", "musicPool": "fixed-local", "inputTimelineCount": "0"]
    try JSONEncoder().encode(result).write(to: package.appendingPathComponent("quality-result.json"), options: .atomic)
    #expect(timeline.music?.trackID != nil)
    #expect(timeline.effectiveOriginalAudioVolume == 0.2)
    #expect(abs(timeline.duration - (initial.workspaceState?.directorBrief?.requestedDuration ?? 0)) <= 1 / timeline.frameRate)
}
