import Foundation

/// One explicitly approved film contributes at most one observation per feature.
/// This is local preference calibration, not training model weights. Automatic
/// output must never call this API without the user's approval of that example.
public struct ApprovedReferenceLearning: Sendable {
    public let fingerprint: String
    public let signals: [PreferenceSignal]

    public init?(timeline: Timeline, assets: [MediaAsset], analyses: [AnalysisResult]) {
        let items = timeline.items.filter { $0.kind != .title && $0.overlay == nil }
            .sorted { $0.timelineStart < $1.timelineStart }
        guard !items.isEmpty, items.allSatisfy({ $0.timelineDuration.isFinite && $0.timelineDuration > 0 }) else { return nil }
        let candidates = Dictionary(analyses.flatMap(\.directorCandidates).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let projectStyle = AutonomousProjectStyleEngine().infer(assets: assets, analyses: analyses, fallbackPreset: .story)
        let context = TasteContextResolver().resolve(projectStyle: projectStyle, timeline: timeline, assets: assets, analyses: analyses)
        var observations: [PreferenceSignal] = []
        func append(_ feature: String, _ value: Double) {
            guard value.isFinite else { return }
            observations.append(PreferenceSignal(feature: feature, value: min(1, max(-1, value)), confidence: 0.75, source: .acceptedEdit, contextKey: context.key))
        }
        func median(_ values: [Double]) -> Double? {
            let sorted = values.filter(\.isFinite).sorted()
            guard !sorted.isEmpty else { return nil }
            let middle = sorted.count / 2
            return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
        }
        for action in [true, false] {
            let durations = items.filter { item in
                guard let candidate = item.candidateID.flatMap({ candidates[$0] }) else { return false }
                return ((candidate.insights?.dynamics ?? candidate.scores.action) > 0.62) == action
            }.map(\.timelineDuration)
            if let value = median(durations) { append(action ? "duration.action" : "duration.calm", value / 6 - 1) }
        }
        if let value = median(items.map(\.timelineDuration)) {
            append("clipDurationPreference", (value - 1.8) / 5.8 * 2 - 1)
        }
        let titles = timeline.effectiveTitleItems.filter { $0.enabled && $0.kind == .chapter }
        if let size = median(titles.map { $0.style.fontSize }) { append("titleSize", (size - 96) / 78) }
        if let duration = median(titles.map(\.duration)) { append("titleDuration", duration / 6 - 1) }
        if let position = median(titles.map { $0.style.effectiveYPosition }) { append("titlePosition", position * 2 - 1) }
        if !titles.isEmpty {
            let animated = titles.filter { $0.animation.entrance != .none || $0.animation.exit != .none }.count
            append("titleAnimation", Double(animated) / Double(titles.count) * 2 - 1)
        }
        // Requested total duration, filters, track identity and chapter text are
        // project-specific instructions, not transferable taste observations.
        if let last = items.last, let candidate = last.candidateID.flatMap({ candidates[$0] }) {
            append("endingPreference", (candidate.insights?.dynamics ?? candidate.scores.action) * 2 - 1)
        }
        guard !observations.isEmpty else { return nil }
        signals = observations
        let hashes = Dictionary(assets.map { ($0.id, $0.contentHash) }, uniquingKeysWith: { first, _ in first })
        let ranges = items.map { "\($0.assetID.flatMap { hashes[$0] } ?? "unknown")|\($0.sourceStart)|\($0.sourceDuration)|\($0.timelineDuration)" }
        let features = observations.map { "\($0.feature)|\($0.value)" }.sorted()
        // No paths, title text or media identifiers are persisted in the receipt.
        fingerprint = EditorialIdentity.hash((["approved-reference-v1"] + ranges + features).joined(separator: "\n"))
    }
}
