import Foundation

public struct RemovedMediaArchive: Codable, Identifiable, Sendable {
    public var id = UUID()
    public var asset: MediaAsset
    public var analyses: [AnalysisResult]
    public var sourceMap: SourceMap?
    public var events: [Event]
    public var plans: [StoryPlan]
    public var timelines: [Timeline]
    public var telemetry: [TelemetrySource]
    public var afterTimelines: [Timeline] = []
}

extension VeloEditPipeline {
    public func restoreRemovedMedia(id: UUID) async throws {
        try await store.update { project in
            guard let entry = project.removedMedia?.first(where: { $0.id == id }) else { return }
            guard !project.assets.contains(where: { $0.id == entry.asset.id }) else { return }
            project.assets.append(entry.asset)
            project.analyses.append(contentsOf: entry.analyses)
            project.telemetrySources = project.effectiveTelemetrySources + entry.telemetry.filter { old in
                !project.effectiveTelemetrySources.contains { $0.id == old.id }
            }
            if project.timelines == entry.afterTimelines {
                project.timelines = entry.timelines
                project.storyPlans = entry.plans
                project.events = entry.events
                project.sourceMap = entry.sourceMap
            } else {
                // New edits are authoritative. The previous composition stays
                // available as a version, and the restored asset is usable now.
                if let previous = entry.timelines.last {
                    project.timelineCheckpoints = (project.timelineCheckpoints ?? []) + [TimelineCheckpoint(name: previous.versionName ?? "Восстановленная версия", reason: "До удаления материала", timeline: previous)]
                }
                project.sourceMap = nil
            }
            project.removedMedia?.removeAll { $0.id == id }
            project.autonomousJob?.state = .cancelled
            project.autonomousJob?.explicitCancellation = true
        }
    }
}
