import Foundation

/// Persisted membership, never inferred from a label, filename or a calendar day.
public struct FilmPart: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var itemIDs: [UUID]
    public var eventID: UUID?
    public var provenance: String
}

public enum FilmPartPolicy {
    /// EventStory entries are the existing user-facing sections. StoryChapter,
    /// source activity groups and scenes inside them are only editing units.
    /// Explicit manual chapter headings can subdivide those sections. An old
    /// automatic heading is text to replace, not evidence of a new section.
    public static func parts(in timeline: Timeline, plan: StoryPlan) -> [FilmPart] {
        let media = timeline.items.filter { $0.overlay == nil && $0.kind != .title }
            .sorted { $0.timelineStart < $1.timelineStart }
        let saved = timeline.filmParts ?? []
        let owners = Dictionary(saved.flatMap { part in part.itemIDs.map { ($0, part) } }, uniquingKeysWith: { first, _ in first })
        let chapters = Dictionary(plan.chapters.flatMap { chapter in chapter.candidateIDs.map { ($0, chapter) } }, uniquingKeysWith: { first, _ in first })
        let manual = timeline.effectiveTitleItems.filter {
            $0.kind == .chapter && !AutomatedTitlePolicy.isGenerated($0)
        }.sorted { $0.startTime < $1.startTime }
        var result: [FilmPart] = []
        var previousScope: String?
        var usedIDs = Set<UUID>()
        for (itemIndex, item) in media.enumerated() {
            let chapter = item.candidateID.flatMap { chapters[$0] }
            let event = chapter?.eventID ?? item.eventID
            let explicit = manual.last { $0.startTime <= item.timelineStart + 0.001 }
            let reference = item.assetID.flatMap { plan.approvedSourceChapterLabels?[$0]?.order }
            var owner = owners[item.id]
            if owner == nil, !saved.isEmpty {
                let before = media[..<itemIndex].reversed().compactMap { owners[$0.id] }.first
                let after = media.dropFirst(itemIndex + 1).compactMap { owners[$0.id] }.first
                // Replacing/inserting a shot inside one already known part
                // changes that part's inputs, not the number of user sections.
                if let before, before.eventID == event, after == nil || after?.id == before.id {
                    owner = before
                } else if before == nil, let after, after.eventID == event {
                    owner = after
                }
            }
            // Once frozen, membership wins over later changes to analysis.
            let scope = owner.map { "saved:\($0.id)" }
                ?? "event:\(event?.uuidString ?? "unresolved")|manual:\(explicit?.id.uuidString ?? "none")|reference:\(reference.map(String.init) ?? "none")"
            if scope == previousScope, !result.isEmpty {
                result[result.count - 1].itemIDs.append(item.id)
            } else {
                var id = owner?.id ?? explicit?.filmPartID
                    ?? EditorialIdentity.uuid("film-part-v1|\(timeline.storyPlanID)|\(event?.uuidString ?? "unresolved")|\(item.id)")
                // A deliberate reordering can create a second contiguous run.
                // It may share a theme, but cannot own a disjoint title interval.
                if usedIDs.contains(id) { id = EditorialIdentity.uuid("film-part-run|\(id)|\(item.id)") }
                usedIDs.insert(id)
                result.append(FilmPart(id: id, itemIDs: [item.id], eventID: owner?.eventID ?? event,
                    provenance: owner?.provenance ?? (explicit == nil ? "existing-event-membership" : "existing-event-and-user-heading")))
            }
            previousScope = scope
        }
        return result
    }

    public static func freezing(_ timeline: Timeline, plan: StoryPlan) -> Timeline {
        var result = timeline
        result.filmParts = parts(in: timeline, plan: plan)
        return result
    }
}
