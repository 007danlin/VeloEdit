import Foundation

/// Repairs attachments before rendering. Reading time is a title property,
/// not a fraction of the film's or its first shot's changing duration.
enum TitleTimelineAnchoring {
    static func reconcile(_ source: Timeline, previousItems: [UUID: TimelineItem] = [:]) -> Timeline {
        guard !source.effectiveTitleItems.isEmpty else { return source }
        var result = source
        let items = Dictionary(uniqueKeysWithValues: source.items.map { ($0.id, $0) })
        let scopes = AutomatedTitlePolicy.inferredContainmentByTitleID(source.effectiveTitleItems, timeline: source)
        result.titleItems = source.effectiveTitleItems.map { original in
            guard let id = original.effectiveAnchorClipID, let anchor = items[id] else { return original }
            var title = original
            if let old = previousItems[id] {
                title.startTime += anchor.timelineStart - old.timelineStart
            }
            let generated = AutomatedTitlePolicy.isGenerated(title)
                && ![.subtitle, .automaticSubtitles, .wordLevelCaptions].contains(title.kind)
            guard generated else { return title }
            // Legacy automatic repairs sometimes moved the clip but left the
            // old absolute title time. Its explicit anchor is authoritative.
            if title.startTime < anchor.timelineStart - 0.001 || title.startTime >= anchor.timelineStart + anchor.timelineDuration {
                title.startTime = anchor.timelineStart
            }
            let end = scopes[title.id]?.upperBound ?? anchor.timelineStart + anchor.timelineDuration
            title.startTime = max(anchor.timelineStart, min(title.startTime, end - title.duration))
            title.duration = min(title.duration, max(0.05, end - title.startTime))
            if title.endTime > anchor.timelineStart + anchor.timelineDuration + 0.001 {
                // The same confirmed scene provides the remaining reading time.
                // Keep the anchor for the next rebuild, without a visibility mask.
                title.anchorClipID = id
                title.targetClipID = nil
            } else if title.anchorClipID != nil {
                title.targetClipID = id
            }
            return title
        }
        return SpeechSubtitleBuilder.reconcile(result)
    }
}
