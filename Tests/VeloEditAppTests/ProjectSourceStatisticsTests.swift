import Foundation
import Testing
@testable import VeloEditCore
@testable import VeloEdit

struct ProjectSourceStatisticsTests {
    @Test func countsAllUniqueImportsAndFullSourceDurationsRegardlessOfAnalysisOrMontage() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let firstURL = root.appendingPathComponent("first.veloedit")
        let secondURL = root.appendingPathComponent("second.veloedit")
        let first = try ProjectStore(createAt: firstURL, name: "First")
        let second = try ProjectStore(createAt: secondURL, name: "Second")
        let video = asset("shared", duration: 600)
        var copy = video
        copy.id = UUID()
        copy.originalURL = root.appendingPathComponent("renamed.mov")
        let unanalysed = asset("other", duration: 120)
        let photo = asset("photo", kind: .photo, duration: 5)
        let background = asset("veloedit-background-v3-stars-1920x1080", kind: .photo, duration: 5)
        try await first.update {
            $0.assets = [video, copy, photo, background]
            let result = AnalysisResult(assetID: video.id, analyzedContentHash: video.contentHash, candidates: [])
            $0.analyses = [result, result]
            $0.timelines = [Timeline(storyPlanID: UUID(), items: [
                TimelineItem(assetID: video.id, kind: .video, sourceStart: 20,
                             sourceDuration: 10, timelineStart: 0, timelineDuration: 5)
            ])]
        }
        try await second.update {
            $0.assets = [copy, unanalysed, photo]
            $0.analyses = [AnalysisResult(assetID: unanalysed.id, analyzedContentHash: "stale", candidates: [])]
        }
        let summary = try #require(ProjectSummary.load(from: firstURL))
        #expect(summary.sourceAssets?.count == 3)
        let statistics = try ProjectLibrary.scan(urls: [firstURL, secondURL], directories: []).statistics
        #expect(statistics.projectCount == 2)
        #expect(statistics.sourceAssetCount == 3)
        #expect(statistics.sourceContentDuration == 720)
    }

    @Test func migratesOldStatisticsWithoutRewritingTheProjectOrInterruptingRunningWork() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("legacy.veloedit")
        let store = try ProjectStore(createAt: url, name: "Legacy")
        let video = asset("video", duration: 90)
        try await store.update {
            $0.assets = [video]
            $0.intentLedger = IntentLedger(entries: [IntentLedgerEntry(
                id: UUID(), projectRevision: 0, normalizedIntent: .createFilm,
                source: .prompt, status: .running, evidence: [], originalRequest: "Создай фильм"
            )])
        }
        let manifestURL = url.appendingPathComponent("project.json")
        let before = try Data(contentsOf: manifestURL)
        var summary = try #require(ProjectSummary.load(from: url))
        summary.sourceAssets = nil
        summary.statisticsVersion = 1
        summary.analyzedContentDuration = 999
        summary.analyzedAssetCount = 42
        try JSONEncoder.veloEdit.encode(summary).write(to: url.appendingPathComponent(ProjectSummary.fileName))

        let snapshot = try ProjectLibrary.scan(urls: [url], directories: [])
        #expect(snapshot.refreshedSummaries)
        #expect(snapshot.statistics.sourceAssetCount == 1)
        #expect(snapshot.statistics.sourceContentDuration == 90)
        #expect(try Data(contentsOf: manifestURL) == before)
        #expect(ProjectSummary.load(from: url)?.statisticsVersion == ProjectSummary.currentStatisticsVersion)
        #expect(try ProjectLibrary.scan(urls: [url], directories: []).refreshedSummaries == false)
    }

    @Test func mergesPortableAndIntegrityCheckedCopiesWithoutDependingOnOrder() throws {
        let video = asset("fast-original", duration: 80)
        var checked = video
        checked.fullContentHash = "full-shared"
        var copied = asset("fast-copy", duration: nil)
        copied.fullContentHash = "full-shared"
        let sources = try [video, checked, copied].map { try #require(ProjectSourceAsset(asset: $0)) }
        let durations = ProjectSourceAsset.uniqueDurations(sources)
        #expect(durations.count == 1)
        #expect(durations.values.reduce(0, +) == 80)
        #expect(ProjectSourceAsset.uniqueDurations(sources.reversed()) == durations)
    }

    @Test func invalidDurationsAndPhotosDoNotAddVideoTimeAndUnknownHashesStayDistinct() throws {
        let sources = try [
            asset("", duration: 10), asset("", duration: 20),
            asset("negative", duration: -100), asset("nan", duration: .nan),
            asset("infinite", duration: .infinity), asset("unknown", duration: nil),
            asset("photo", kind: .photo, duration: 999)
        ].map { try #require(ProjectSourceAsset(asset: $0)) }
        let durations = ProjectSourceAsset.uniqueDurations(sources)
        #expect(durations.count == 7)
        #expect(durations.values.reduce(0, +) == 30)
        #expect(ProjectSourceAsset.uniqueDurations([]).isEmpty)
    }

    private func asset(_ hash: String, kind: MediaKind = .video, duration: Double?) -> MediaAsset {
        MediaAsset(originalURL: URL(fileURLWithPath: "/unavailable/clip.mov"), kind: kind,
                   byteSize: 100, contentHash: hash, metadata: MediaMetadata(duration: duration))
    }
}
