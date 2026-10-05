import Foundation
import Testing
@testable import VeloEditCore

/// Opt-in replay on a complete study copy. It runs the real chapter naming
/// path while holding cuts, title placement and audio fixed for export review.
@Test(.enabled(if: ProcessInfo.processInfo.environment["VELOEDIT_TITLE_EVIDENCE_STUDY"] != nil))
func replayTitleEvidenceOnSavedDevelopmentEdit() throws {
    let path = try #require(ProcessInfo.processInfo.environment["VELOEDIT_TITLE_EVIDENCE_STUDY"])
    let package = URL(fileURLWithPath: path)
    try #require(FileManager.default.fileExists(atPath: package.appendingPathComponent("study-input.json").path))
    let file = package.appendingPathComponent("project.json")
    var project = try JSONDecoder.veloEdit.decode(ProjectManifest.self, from: Data(contentsOf: file))
    let source = try #require(project.timelines.last)
    let originalPlan = try #require(project.storyPlans.first { $0.id == source.storyPlanID })
    var plan = AutomaticEditorialAssembly.reconcile(timeline: source, plan: originalPlan,
        analyses: project.analyses, events: project.events)
    plan.id = UUID()
    struct Change: Codable { var time: Double; var before: String; var after: String }
    var changes: [Change] = []
    var revised = source
    revised.id = UUID()
    revised.storyPlanID = plan.id
    revised.versionName = "Подписи по подтверждённому содержанию — фиксированный монтаж"
    revised.titleItems = source.effectiveTitleItems.map { title in
        guard AutomatedTitlePolicy.isGenerated(title), title.kind == .chapter,
              let item = source.items.first(where: {
                  $0.timelineStart <= title.startTime + 0.000_001 && $0.timelineStart + $0.timelineDuration > title.startTime + 0.000_001
              }), let candidate = item.candidateID,
              let chapter = plan.chapters.first(where: { $0.candidateIDs.contains(candidate) }) else { return title }
        var copy = title
        copy.text = chapter.chapterCardTitle ?? chapter.title
        if copy.text != title.text { changes.append(Change(time: title.startTime, before: title.text, after: copy.text)) }
        return copy
    }
    revised.editorialReview = nil
    revised.filmDeliveryReport = nil
    #expect(revised.items == source.items)
    #expect(revised.music == source.music)
    #expect(revised.adaptiveSoundtrack == source.adaptiveSoundtrack)
    #expect(revised.originalAudioVolume == source.originalAudioVolume)
    #expect(revised.effectiveTitleItems.count == source.effectiveTitleItems.count)
    for (before, after) in zip(source.effectiveTitleItems, revised.effectiveTitleItems) {
        var comparison = after
        comparison.text = before.text
        #expect(comparison == before)
    }
    #expect(!changes.isEmpty)
    #expect(!revised.effectiveTitleItems.contains { ["У моря", "Скалолазание"].contains($0.text) })
    project.storyPlans.append(plan)
    project.timelines.append(revised)
    try JSONEncoder.veloEdit.encode(project).write(to: file, options: .atomic)
    try JSONEncoder.veloEdit.encode(changes).write(to: package.appendingPathComponent("title-evidence-changes.json"), options: .atomic)
}
