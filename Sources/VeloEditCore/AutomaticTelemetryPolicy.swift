import Foundation

/// Usable, timed measurements are required both for the question and the HUD.
/// Camera settings, elapsed time and raw IMU streams alone are not an offer.
public enum AutomaticTelemetryPolicy {
    public static func usefulKinds(in summary: TelemetrySummary) -> [TelemetryWidgetKind] {
        [.speedValue, .routeMap, .elevationProfile, .heartRate, .cadence, .power].filter { kind in
            ranges(in: summary.timedSamples ?? [], kind: kind).contains { $0.upperBound - $0.lowerBound >= 1 }
                && summary.supports(kind, presentation: kind.defaultPresentation)
        }
    }

    static func ranges(in samples: [TelemetrySample], kind: TelemetryWidgetKind) -> [ClosedRange<Double>] {
        func valid(_ value: Double?, _ lower: Double, _ upper: Double) -> Bool {
            value.map { $0.isFinite && (lower...upper).contains($0) } == true
        }
        func available(_ sample: TelemetrySample) -> Bool {
            switch kind {
            case .speedValue, .speedometer, .speedBar, .pace: return valid(sample.speedMetersPerSecond, 0, 150)
            case .routeMap, .routeProgress: return sample.coordinate.map { $0.latitude.isFinite && $0.longitude.isFinite && (-90...90).contains($0.latitude) && (-180...180).contains($0.longitude) } == true
            case .elevationProfile, .altitude: return valid(sample.altitudeMeters, -500, 12_000)
            case .heartRate: return valid(sample.heartRateBPM, 20, 250)
            case .cadence: return valid(sample.cadenceRPM, 0, 250)
            case .power: return valid(sample.powerWatts, 0, 3_000)
            case .distance: return valid(sample.distanceMeters, 0, 10_000_000)
            case .gForce: return valid(sample.gForce, -20, 20) || valid(sample.gForceX, -20, 20) || valid(sample.gForceY, -20, 20)
            default: return false
            }
        }
        var ranges: [ClosedRange<Double>] = []
        var start: Double?
        var last: Double?
        func finish() {
            if let start, let last, last > start { ranges.append(start...last) }
            start = nil; last = nil
        }
        for sample in samples.filter({ $0.timestamp.isFinite && $0.timestamp >= 0 }).sorted(by: { $0.timestamp < $1.timestamp }) {
            guard available(sample) else { finish(); continue }
            if let last, sample.timestamp - last > 2 { finish() }
            if start == nil { start = sample.timestamp }
            last = sample.timestamp
        }
        finish()
        return ranges
    }

    static func scoped(_ summary: TelemetrySummary, samples: [TelemetrySample]) -> TelemetrySummary {
        .init(sampleCount: samples.count, timedSamples: samples, streams: summary.streams, sourceFormat: summary.sourceFormat)
    }

    static func rebuilding(in source: Timeline, plan: StoryPlan, analyses: [AnalysisResult]) -> Timeline {
        var timeline = source
        timeline.telemetryItems = []
        for index in timeline.items.indices { timeline.items[index].telemetryOverlay = nil }
        guard TelemetryOverlayRequestPolicy.requestsOverlay(in: plan.prompt) else { return timeline }
        let summaries = Dictionary(analyses.compactMap { a in a.telemetry.map { (a.assetID, $0) } }, uniquingKeysWith: { a, _ in a })
        var lastEnd = -10.0
        for clip in timeline.items where clip.overlay == nil && clip.timelineStart - lastEnd >= 5.5 {
            guard let asset = clip.assetID, let summary = summaries[asset],
                  let decision = SmartTelemetryEngine().decide(.init(telemetry: summary, clip: clip, role: clip.storyRole,
                      aspectRatio: Double(timeline.width) / Double(max(1, timeline.height)), explicitRequest: plan.prompt)) else { continue }
            timeline.telemetryItems?.append(.init(targetClipID: clip.id, linkedAssetID: asset,
                sourceStart: clip.sourceStart + (decision.timelineStart - clip.timelineStart) * clip.speed,
                timelineStart: decision.timelineStart, timelineDuration: decision.duration,
                settings: decision.settings, explanation: decision.explanation))
            lastEnd = decision.timelineStart + decision.duration
        }
        return timeline
    }
}
