import Foundation
import VeloEditCore

struct AppUsageStatistics: Equatable, Sendable {
    var sourceContentDuration: Double = 0
    var projectCount: Int = 0
    var sourceAssetCount: Int = 0
}

/// The statistics library outlives the bounded list of recent-project cards.
enum ProjectLibrary {
    struct OpeningPresentation: Sendable {
        let preview: ProjectOpeningPreview
        let thumbnails: [UUID: URL]
        let music: [LocalMusicTrack]

        static func load(from url: URL) -> Self? {
            guard let preview = ProjectOpeningPreview.load(from: url) else { return nil }
            let paths = CachePaths(root: url.appendingPathComponent("Cache"))
            let thumbnails = Dictionary(preview.assets.map { ($0.id, paths.thumbnail(for: $0)) },
                                        uniquingKeysWith: { first, _ in first })
            let musicURL = url.appendingPathComponent("MusicLibrary/tracks.json")
            let music = (try? Data(contentsOf: musicURL)).flatMap {
                try? JSONDecoder.veloEdit.decode([LocalMusicTrack].self, from: $0)
            } ?? []
            return Self(preview: preview, thumbnails: thumbnails, music: music)
        }
    }

    struct Snapshot: Sendable {
        var urls: [URL]
        var statistics: AppUsageStatistics
        var refreshedSummaries: Bool
    }

    static func uniqueURLs(_ urls: [URL]) -> [URL] {
        var paths = Set<String>()
        return urls.map(\.standardizedFileURL).filter { paths.insert($0.path).inserted }
    }

    /// Inspect project folders, without traversing media trees or package caches.
    /// This also recovers older projects dropped by the former 12-entry history.
    /// Call off MainActor: legacy summary migration can decode large manifests.
    static func scan(urls: [URL], directories: [URL]) throws -> Snapshot {
        let fileManager = FileManager.default
        var candidates = uniqueURLs(urls)
        let folders = uniqueURLs(directories + candidates.map { $0.deletingLastPathComponent() })
        for folder in folders {
            try Task.checkCancellation()
            let children = (try? fileManager.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            )) ?? []
            candidates += children.filter { $0.pathExtension.lowercased() == ProjectStore.packageExtension }
                .sorted { $0.path < $1.path }
        }

        var knownURLs = uniqueURLs(urls)
        var projectIDs = Set<UUID>()
        var statistics = AppUsageStatistics()
        var sourceAssets: [ProjectSourceAsset] = []
        var refreshedSummaries = false
        for url in uniqueURLs(candidates) {
            try Task.checkCancellation()
            guard fileManager.fileExists(atPath: url.appendingPathComponent("project.json").path) else { continue }
            var summary = ProjectSummary.load(from: url)
            if summary?.statisticsVersion != ProjectSummary.currentStatisticsVersion || summary?.sourceAssets == nil {
                try? ProjectStore.refreshSummary(at: url)
                summary = ProjectSummary.load(from: url)
                refreshedSummaries = true
            }
            guard let summary else { continue }
            knownURLs.append(url)
            guard projectIDs.insert(summary.projectID).inserted else { continue }
            statistics.projectCount += 1
            sourceAssets += summary.sourceAssets ?? []
        }
        let durations = ProjectSourceAsset.uniqueDurations(sourceAssets)
        statistics.sourceAssetCount = durations.count
        statistics.sourceContentDuration = durations.values.sorted().reduce(0, +)
        return Snapshot(urls: uniqueURLs(knownURLs), statistics: statistics,
                        refreshedSummaries: refreshedSummaries)
    }
}
