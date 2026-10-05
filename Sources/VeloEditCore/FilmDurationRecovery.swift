import Foundation

/// Completes an explicit runtime with unused, decodable material after quality
/// repairs have exhausted the semantic shortlist. Existing edits stay intact.
enum FilmDurationRecovery {
    static func extend(_ original: Timeline, requirement: FilmDurationRequirement,
                       plan: StoryPlan, assets: [MediaAsset], analyses: [AnalysisResult]) async throws -> Timeline {
        let frame = 1 / max(1, original.frameRate)
        guard requirement.mode != .automatic, requirement.mode != .maximum,
              let target = requirement.target,
              target > AutomaticFilmDurationPolicy.renderedDuration(of: original) + frame,
              !requirement.accepts(duration: AutomaticFilmDurationPolicy.renderedDuration(of: original), frameRate: original.frameRate) else { return original }
        struct Window {
            var asset: MediaAsset
            var start: Double
            var end: Double
            var candidateID: UUID
            var protected: EditorialSourceRange?
        }
        var windows: [Window] = []
        let candidates = analyses.flatMap(\.directorCandidates)
        let sourceMap = SourceTimelineAnalyzer().analyze(assets: assets, analyses: analyses)
        let ranks = Dictionary(uniqueKeysWithValues: sourceMap.entries.map { ($0.assetID, $0.order) })
        let last = original.items.filter { $0.overlay == nil && $0.kind != .title }.max { $0.timelineStart < $1.timelineStart }
        let lastRank = last?.assetID.flatMap { ranks[$0] }
        for asset in assets where !asset.excluded && !asset.missing {
            if let lastRank, let rank = ranks[asset.id], rank < lastRank { continue }
            let used = original.items.filter { $0.assetID == asset.id }
            let forbidden = candidates.filter { $0.assetID == asset.id && ($0.excluded || !plan.constraints.excludeTags.isDisjoint(with: $0.tags)) }
            let measured = candidates.filter { $0.assetID == asset.id && !$0.excluded && plan.constraints.excludeTags.isDisjoint(with: $0.tags) }
                .map { EditorialUnit(candidate: $0) }.filter { $0.evidence.confidence >= 0.55 && $0.quality >= 0.55 && !$0.evidence.hasHardOcclusion }
            // Requested runtime is not evidence that unselected raw footage is
            // useful. Only independently measured ranges can extend the film.
            for unit in measured {
            let lower = max(unit.sourceRange.start, unit.evidence.usableRange.start, used.map { $0.sourceStart + $0.sourceDuration }.max() ?? 0)
            let upper = min(unit.sourceRange.end, unit.evidence.usableRange.end, lower + unit.usableDuration)
            guard upper > lower else { continue }
            var ranges = [lower..<upper]
            let occupied = used.map { $0.sourceStart..<($0.sourceStart + $0.sourceDuration) }
                + forbidden.map { $0.sourceStart..<($0.sourceStart + $0.sourceDuration) }
            for cut in occupied {
                ranges = ranges.flatMap { range -> [Range<Double>] in
                    let low = max(range.lowerBound, cut.lowerBound), high = min(range.upperBound, cut.upperBound)
                    guard high > low else { return [range] }
                    var pieces: [Range<Double>] = []
                    if low > range.lowerBound { pieces.append(range.lowerBound..<low) }
                    if high < range.upperBound { pieces.append(high..<range.upperBound) }
                    return pieces
                }
            }
            let protected = EditorialMomentPolicy.protectedRange(unit)
            windows += ranges.filter { range in
                range.countedSeconds >= 1 && (protected.map { required in range.lowerBound <= required.start + frame && range.upperBound >= required.end - frame } ?? true)
            }.map { Window(asset: asset, start: $0.lowerBound, end: $0.upperBound, candidateID: unit.id, protected: protected) }
            }
        }
        windows.sort { (ranks[$0.asset.id, default: Int.max], $0.start) < (ranks[$1.asset.id, default: Int.max], $1.start) }
        var timeline = original
        var attempts = 0
        while !windows.isEmpty, attempts < 1_000 {
            try Task.checkCancellation()
            let remaining = target - AutomaticFilmDurationPolicy.renderedDuration(of: timeline)
            if remaining <= frame { break }
            var window = windows.removeFirst()
            let lastEnd = timeline.items.filter { $0.assetID == window.asset.id }.map { $0.sourceStart + $0.sourceDuration }.max() ?? 0
            window.start = max(window.start, lastEnd)
            let length = min(window.protected.map { $0.end - window.start } ?? 6, remaining, window.end - window.start)
            if let required = window.protected, window.start > required.start + frame || window.start + length < required.end - frame { continue }
            guard length >= frame else { continue }
            let item = TimelineItem(candidateID: window.candidateID, assetID: window.asset.id,
                kind: window.asset.kind == .photo ? .photo : .video,
                sourceStart: window.start, sourceDuration: length, timelineStart: 0, timelineDuration: length,
                videoAdjustments: .init(crop: .fit), explanation: ["Дополнительный исходный материал до запрошенной длительности"])
            attempts += 1
            let probe = Timeline(storyPlanID: timeline.storyPlanID, width: 640, height: 360, frameRate: timeline.frameRate, items: [item])
            do {
                let playback = try await PlaybackEngine().build(timeline: probe, assets: [window.asset], forceVideoComposition: true)
                let frames = await PerceptualRenderInspector().inspectAsync(playback: playback, timeline: probe, maximumSamples: 3)
                try Task.checkCancellation()
                guard playback.skippedItemIDs.isEmpty, !frames.isEmpty, frames.allSatisfy({ $0.decodeFailed != true }) else { continue }
            } catch is CancellationError { throw CancellationError() }
            catch { continue }
            // Append without a new transition overlap, retaining the existing
            // source windows, titles and clip IDs exactly as they were selected.
            TimelineMutationEngine.insertPrimaryItem(in: &timeline, item: item)
            window.start += length
            if window.protected == nil, window.asset.kind == .video, window.end - window.start >= 1 { windows.insert(window, at: 0) }
        }
        if timeline.items != original.items {
            timeline.editorialReview = nil
            timeline.filmDeliveryReport = nil
        }
        return timeline
    }
}

private extension Range where Bound == Double {
    var countedSeconds: Double { upperBound - lowerBound }
}
