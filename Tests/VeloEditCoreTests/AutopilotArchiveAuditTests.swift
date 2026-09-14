import Foundation
import Testing
@testable import VeloEditCore

@Suite struct AutopilotArchiveAuditTests {
    /// Optional real archive acceptance. Reads the user's project only; no
    /// timeline, preferences or cache in that project are written.
    @Test func freshAssemblyFromAnalyzedArchivePreservesCaptureOrder() throws {
        guard let input = ProcessInfo.processInfo.environment["VELOEDIT_AUTOPILOT_ARCHIVE"],
              let output = ProcessInfo.processInfo.environment["VELOEDIT_AUTOPILOT_REPORT"] else { return }
        let inputURL = URL(fileURLWithPath: input)
        let before = try Data(contentsOf: inputURL)
        let project = try JSONDecoder.veloEdit.decode(ProjectManifest.self, from: before)
        let discovery = EventIntelligenceEngine().discover(assets: project.assets, analyses: project.analyses)
        var constraints = StoryConstraints(targetDuration: 180)
        constraints.allowSlowMotion = false
        let brief = DirectorBrief(requestedDuration: 180, mood: .cinematic, musicPolicy: .none, titlePolicy: .keyOnly)
        // Build a fresh input for the final assembly stage, covering every
        // source with measured candidates. This isolates the contract from
        // the unrelated, expensive multi-variant narrative search.
        let chosen = project.analyses.flatMap { analysis in
            analysis.directorCandidates.filter { !$0.excluded && $0.insights?.editorialEvidence != nil }
                .sorted { $0.sourceStart < $1.sourceStart }.prefix(3)
        }
        let ids = Set(chosen.map(\.id))
        let chapters = discovery.events.flatMap { event in event.effectiveScenes.map { scene in
            StoryChapter(title: scene.title, candidateIDs: scene.candidateIDs.filter(ids.contains),
                eventID: event.id, eventSceneID: scene.id, chapterCardTitle: scene.title)
        } }
        var plan = StoryPlan(prompt: "Собери хронологический фильм. Названия каждой части. Без музыки.",
            preset: .cinematic, constraints: constraints, chapters: chapters, directorBrief: brief)
        plan.narrativeBeatPlan = .init(pattern: .eventChapters, beats: [], reasons: [])
        let rough = Timeline(storyPlanID: plan.id, items: chosen.reversed().enumerated().map { index, candidate in
            TimelineItem(candidateID: candidate.id, assetID: candidate.assetID, kind: .video,
                sourceStart: candidate.sourceStart, sourceDuration: min(4, candidate.sourceDuration),
                timelineStart: Double(index * 4), timelineDuration: min(4, candidate.sourceDuration))
        })
        let result = AutomaticEditorialAssembly.prepare(timeline: rough, plan: plan, analyses: project.analyses,
            events: discovery.events, assets: project.assets)
        let final = EditorialIntentEnforcer.enforce(result.timeline, plan: result.plan)
        let ranks = Dictionary(uniqueKeysWithValues: discovery.sourceMap.entries.map { ($0.assetID, $0.order) })
        let primary = final.items.filter { $0.overlay == nil && $0.kind != .title }
        #expect(!primary.isEmpty)
        for (a, b) in zip(primary, primary.dropFirst()) {
            #expect(ranks[a.assetID!, default: -1] <= ranks[b.assetID!, default: -1])
            if a.assetID == b.assetID { #expect(a.sourceStart + a.sourceDuration <= b.sourceStart + 0.001) }
        }
        #expect(EditorialPresentationPolicy.missingChapterTitles(in: final, plan: result.plan).isEmpty)
        #expect(final.effectiveTitleItems.allSatisfy { $0.style.fontFamily == "Avenir Next" && $0.style.fontSize == 72 })
        #expect(final.items.allSatisfy { $0.effectiveVideoAdjustments.filter == .none })
        #expect(final.effectiveTelemetryItems.isEmpty)
        #expect(try Data(contentsOf: inputURL) == before)
        let names = Dictionary(uniqueKeysWithValues: project.assets.map { ($0.id, $0.displayName) })
        let report: [String: Any] = [
            "mode": "source discovery and final assembly from saved source analysis, three measured candidates per file in reversed order; no project timeline reused; no export",
            "sourceCount": project.assets.count, "shotCount": primary.count, "duration": final.duration,
            "groups": discovery.sourceMap.activityGroups.map { ["title": $0.title, "files": $0.assetIDs.compactMap { names[$0] }] as [String: Any] },
            "captureOrder": discovery.sourceMap.entries.map { ["file": $0.displayName, "date": $0.captureDate.map { ISO8601DateFormatter().string(from: $0) } ?? "unknown", "confidence": $0.chronologyConfidence] as [String: Any] },
            "shots": primary.map { ["file": names[$0.assetID!] ?? "", "sourceStart": $0.sourceStart, "start": $0.timelineStart, "duration": $0.timelineDuration] as [String: Any] },
            "titles": final.effectiveTitleItems.map { ["text": $0.text, "start": $0.startTime, "font": $0.style.fontFamily ?? "", "size": $0.style.fontSize] as [String: Any] }
        ]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: output))
    }
}
