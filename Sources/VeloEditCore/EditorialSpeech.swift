import Foundation

/// Keep the complete audio phrase while changing the picture with related,
/// previously unused material. A missing cutaway is reported by the gate.
public enum EditorialSpeechContinuityPolicy {
    public static func applying(to source: Timeline, plan: StoryPlan, assets: [MediaAsset], analyses: [AnalysisResult]) -> Timeline {
        guard plan.narrativeBeatPlan != nil, ExplicitDeliveryRequirements(plan: plan).originalAudioVolume != 0 else { return source }
        var timeline = source
        let context = EditorialAnalysisContext(analyses: analyses)
        let candidates = Dictionary(uniqueKeysWithValues: context.units.map { ($0.id, $0) })
        let byAsset = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) })
        var used = Set(timeline.items.compactMap(\.candidateID))
        for primary in source.items where primary.overlay == nil && primary.kind == .video && primary.timelineDuration > 20 {
            guard let id = primary.candidateID, let speech = candidates[id], speech.speechSeconds > 20 else { continue }
            var choices = context.units.filter { unit in
                !used.contains(unit.id) && unit.usableDuration >= 2
                    && !unit.candidate.tags.isDisjoint(with: speech.candidate.tags)
                    && !ShotFamilyClusterer().isHardDuplicate(speech, unit)
            }.sorted { $0.quality == $1.quality ? $0.id.uuidString < $1.id.uuidString : $0.quality > $1.quality }
            for offset in stride(from: 10.0, to: primary.timelineDuration - 3, by: 12) {
                let absolute = primary.timelineStart + offset
                if timeline.items.contains(where: { $0.overlay?.baseItemID == primary.id && $0.timelineStart <= absolute && $0.timelineStart + $0.timelineDuration >= absolute }) { continue }
                guard !choices.isEmpty else { break }
                let selected = choices.removeFirst()
                guard let asset = byAsset[selected.candidate.assetID] else { continue }
                let length = min(4.5, selected.usableDuration, primary.timelineDuration - offset)
                timeline.items.append(TimelineItem(candidateID: selected.id, assetID: asset.id, kind: asset.kind == .photo ? .photo : .video, sourceStart: selected.sourceRange.start, sourceDuration: length, timelineStart: absolute, timelineDuration: length, audioAdjustments: AudioAdjustments(volume: 0, muted: true), overlay: OverlaySettings(style: .cutaway, baseItemID: primary.id, startOffset: offset), storyRole: .bRoll, editorialPurpose: "Related cutaway preserves continuous speech", explanation: ["Полная речевая фраза сохранена; связанный cutaway меняет визуальную информацию"]))
                used.insert(selected.id)
            }
        }
        timeline.items = TimelineTiming.retimed(timeline.items)
        return timeline
    }
}
