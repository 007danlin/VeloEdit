import Foundation

/// User-approved chapter names are annotations of source content, not a copy
/// of the reference montage. New edits still select and verify their own shots.
public struct ChapterTitleReference: Codable, Hashable, Sendable {
    public struct Label: Codable, Hashable, Sendable {
        public var text: String
        public var order: Int
    }
    public var name: String
    public var style: TitleStyle
    public var animation: TitleAnimation
    public var duration: Double
    public var labelsByContentHash: [String: Label]

    public init?(name: String, timeline: Timeline, assets: [MediaAsset]) {
        let titles = timeline.effectiveTitleItems.filter { $0.enabled && $0.kind == .chapter }
            .sorted { $0.startTime < $1.startTime }
        guard let first = titles.first, titles.allSatisfy({ $0.style == first.style && $0.animation == first.animation }) else { return nil }
        self.name = name
        style = first.style
        animation = first.animation
        duration = first.duration
        labelsByContentHash = [:]
        for asset in assets where !asset.contentHash.isEmpty {
            let items = timeline.items.filter { $0.assetID == asset.id && $0.overlay == nil }
            let total = items.reduce(0) { $0 + $1.timelineDuration }
            guard total > 0 else { continue }
            let coverage = titles.indices.map { index in
                let start = titles[index].startTime
                let end = index + 1 < titles.count ? titles[index + 1].startTime : timeline.duration
                return items.reduce(0) { $0 + max(0, min(end, $1.timelineStart + $1.timelineDuration) - max(start, $1.timelineStart)) }
            }
            // Mixed-activity sources need fresh analysis, not a misleading
            // blanket label learned from a small excerpt.
            guard let best = coverage.indices.max(by: { coverage[$0] < coverage[$1] }),
                  coverage[best] / total >= 0.8 else { continue }
            labelsByContentHash[asset.contentHash] = Label(text: titles[best].text, order: best)
        }
    }

    func applying(to source: StoryPlan, assets: [MediaAsset]) -> StoryPlan {
        var plan = source
        plan.chapterTitleReference = self
        plan.approvedSourceChapterLabels = Dictionary(uniqueKeysWithValues: assets.compactMap { asset in
            labelsByContentHash[asset.contentHash].map { (asset.id, $0) }
        })
        return plan
    }
}
