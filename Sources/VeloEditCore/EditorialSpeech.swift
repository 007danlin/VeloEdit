import Foundation

/// Audible source audio is not a request to turn a visual montage into a vlog.
/// Phrase protection belongs to the film's intent, independently of AI power.
public enum SpeechEditingPolicy {
    public static func requiresCompletePhrases(plan: StoryPlan) -> Bool {
        requiresCompletePhrases(preset: plan.preset, prompt: plan.prompt)
    }

    public static func requiresCompletePhrases(preset: FilmPreset, prompt: String) -> Bool {
        if preset == .vlog { return true }
        var required = false
        for clause in prompt.lowercased().components(separatedBy: CharacterSet(charactersIn: ".!?;\n")) {
            // "Речной пейзаж" and "условия" are not speech requests.
            guard clause.range(of: #"\b(?:реч(?:ь|и|ью|ев\p{L}*)|реплик\p{L}*|фраз\p{L}*|слов(?:о|а|у|ом|е|ам|ами|ах)?|диалог\p{L}*|speech|sentences?|phrases?|dialogues?|words?)\b"#,
                               options: .regularExpression) != nil else { continue }
            let negative = ["не сохраня", "не надо сохраня", "не нужно сохраня", "без сохранения", "можно обрез", "можно преры", "don't preserve", "do not preserve", "can cut"].contains(where: clause.contains)
            if negative { required = false; continue }
            let preserve = ["сохрани", "сохранить", "оставь", "оставить", "preserve", "keep"].contains(where: clause.contains)
            let complete = ["целиком", "полностью", "без обрыв", "без обрез", "не обрывай", "не обрезай", "не прерывай", "complete", "whole", "without cutting", "don't cut", "do not cut"].contains(where: clause.contains)
            if preserve || complete { required = true }
        }
        return required
    }
}

/// Keep the complete audio phrase while changing the picture with related,
/// previously unused material. A missing cutaway is reported by the gate.
public enum EditorialSpeechContinuityPolicy {
    public static func applying(to source: Timeline, plan: StoryPlan, assets: [MediaAsset], analyses: [AnalysisResult]) -> Timeline {
        guard plan.narrativeBeatPlan != nil, SpeechEditingPolicy.requiresCompletePhrases(plan: plan),
              ExplicitDeliveryRequirements(plan: plan).originalAudioVolume != 0 else { return source }
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
