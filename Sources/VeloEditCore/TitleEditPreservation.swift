import Foundation

/// Carries authored titles with surviving footage when the director rebuilds
/// the story. Automatic replacements cannot erase an inspector edit.
enum TitleEditPreservation {
    static func applying(from previous: Timeline, to generated: Timeline,
                         clipIDs: [UUID: UUID]) -> Timeline {
        var result = generated
        if let parts = previous.filmParts {
            let carried = parts.compactMap { part -> FilmPart? in
                var value = part
                value.itemIDs = part.itemIDs.compactMap { clipIDs[$0] }
                return value.itemIDs.isEmpty ? nil : value
            }
            if !carried.isEmpty {
                result.filmParts = carried
                result.chapterTitleDecisions = previous.chapterTitleDecisions
            }
        }
        result.openingTitles = previous.openingTitles ?? generated.openingTitles
        result.openingTitleDecision = previous.openingTitleDecision ?? generated.openingTitleDecision
        var titles = generated.effectiveTitleItems
        if previous.openingTitles?.policy == .off { titles.removeAll { $0.semanticRole == .filmOpening } }
        else if var opening = previous.effectiveTitleItems.first(where: { $0.semanticRole == .filmOpening }) {
            opening.targetClipID = nil; opening.anchorClipID = nil
            opening.duration = min(opening.duration, max(0.05, result.duration - opening.startTime))
            titles.removeAll { $0.semanticRole == .filmOpening }
            titles.append(opening)
        }
        result.titleItems = titles
        let edited = previous.effectiveTitleItems.filter { !AutomatedTitlePolicy.isGenerated($0) }
        guard !edited.isEmpty else { return result }
        for original in edited {
            if original.semanticRole == .filmOpening {
                var title = original
                title.targetClipID = nil; title.anchorClipID = nil
                title.duration = min(title.duration, max(0.05, result.duration - title.startTime))
                titles.removeAll { $0.semanticRole == .filmOpening }
                if previous.openingTitles?.policy != .off { titles.append(title) }
                continue
            }
            let oldAnchor = previous.items.first { item in
                item.overlay == nil && item.kind != .title &&
                    original.startTime >= item.timelineStart &&
                    original.startTime < item.timelineStart + item.timelineDuration
            }
            let newAnchor = oldAnchor.flatMap { old in
                clipIDs[old.id].flatMap { id in result.items.first { $0.id == id } }
            }
            let matching = titles.filter {
                AutomatedTitlePolicy.isGenerated($0) && ($0.text == original.text || (original.filmPartID != nil && $0.filmPartID == original.filmPartID)) && $0.track == original.track
            }.min { abs($0.startTime - (newAnchor?.timelineStart ?? original.startTime)) < abs($1.startTime - (newAnchor?.timelineStart ?? original.startTime)) }
            var title = original
            if let target = original.targetClipID {
                guard let newTarget = clipIDs[target] else { continue }
                title.targetClipID = newTarget
            }
            if let oldAnchor, let newAnchor {
                title.startTime = newAnchor.timelineStart + original.startTime - oldAnchor.timelineStart
            } else if let matching {
                title.startTime = matching.startTime
            } else if oldAnchor != nil {
                // The source part was removed, so its annotation has no anchor.
                continue
            }
            guard title.startTime < result.duration else { continue }
            title.duration = min(title.duration, result.duration - title.startTime)
            title.userEdited = true
            titles.removeAll { candidate in
                candidate.id == title.id || candidate.id == matching?.id || (AutomatedTitlePolicy.isGenerated(candidate) &&
                    candidate.track == title.track &&
                    candidate.startTime < title.endTime && candidate.endTime > title.startTime)
            }
            titles.append(title)
        }
        result.titleItems = titles.sorted { $0.startTime < $1.startTime }
        return result
    }
}
