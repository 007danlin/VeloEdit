import Foundation

extension VeloEditPipeline {
    /// Import once, then insert the resolved assets in one undoable timeline
    /// edit. Receipt IDs make re-drops and differently named duplicates work.
    public func importMediaIntoTimeline(
        _ urls: [URL], atPrimaryIndex index: Int, audioStart: Double,
        progress: (@Sendable (ImportProgress) -> Void)? = nil
    ) async throws -> [String] {
        let failures = try await importMedia(urls, progress: progress)
        try Task.checkCancellation()
        let project = await store.manifest
        let entries = project.lastImportReport?.entries.filter { $0.outcome != .failed } ?? []
        let tracks = try await musicTracks()
        let inputOrder = Dictionary(urls.enumerated().map { ($0.element.standardizedFileURL, $0.offset) },
                                    uniquingKeysWith: { first, _ in first })
        let ordered = entries.sorted {
            let lhs = inputOrder[$0.url.standardizedFileURL] ?? Int.max
            let rhs = inputOrder[$1.url.standardizedFileURL] ?? Int.max
            return lhs == rhs ? $0.url.path < $1.url.path : lhs < rhs
        }
        guard ordered.contains(where: { $0.assetID != nil || $0.musicTrackID != nil }) else { return failures }
        if project.timelines.isEmpty { try await createManualTimeline() }
        try await store.update { project in
            guard let timelineIndex = project.timelines.indices.last else { return }
            var timeline = project.timelines[timelineIndex]
            var insertionIndex = min(max(0, index), timeline.items.filter { $0.overlay == nil }.count)
            for entry in ordered {
                guard let assetID = entry.assetID, let asset = project.assets.first(where: { $0.id == assetID }) else { continue }
                let duration = asset.kind == .video ? max(0.25, asset.metadata.duration ?? 5) : 4
                let item = TimelineItem(assetID: asset.id, kind: asset.kind == .video ? .video : .photo,
                    sourceDuration: duration, timelineStart: 0, timelineDuration: duration,
                    explanation: ["Файл перетащен на монтажную линию"])
                if TimelineMutationEngine.insertPrimaryItem(in: &timeline, item: item, atPrimaryIndex: insertionIndex) {
                    insertionIndex += 1
                }
            }
            var audioTime = min(max(0, audioStart), max(0, timeline.duration - 0.05))
            for entry in ordered {
                guard let id = entry.musicTrackID, let track = tracks.first(where: { $0.id == id }),
                      audioTime < timeline.duration else { continue }
                let duration = min(track.duration, timeline.duration - audioTime)
                let clip = TimelineAudioClip(trackID: id, title: track.title, role: .music,
                    sourceStart: 0, sourceDuration: duration, timelineStart: audioTime, timelineDuration: duration,
                    adjustments: AudioAdjustments(volume: 1))
                if TimelineMutationEngine.insertAudioClip(in: &timeline, clip: clip) { audioTime += duration }
            }
            project.timelines[timelineIndex] = timeline
        }
        return failures
    }
}
