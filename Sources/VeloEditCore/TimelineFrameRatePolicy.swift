import Foundation

/// Select the film's clock from the edited motion, independently of AI and
/// encoding quality. Never reinterpret source FPS or change a clip's duration.
public enum TimelineFrameRatePolicy {
    private struct Motion {
        let family: Int
        let fractional: Bool
        let rate: Double
        let duration: Double
    }

    public static func applying(to source: Timeline, assets: [MediaAsset]) -> Timeline {
        guard source.automaticallySelectFrameRate == true else { return source }
        var result = source
        result.frameRate = automaticFrameRate(items: source.items, assets: assets, fallback: source.frameRate)
        return result
    }

    public static func automaticFrameRate(items: [TimelineItem], assets: [MediaAsset], fallback: Double = 30) -> Double {
        let byID = Dictionary(assets.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let primary = items.filter { $0.overlay == nil && $0.kind == .video && !$0.isFreezeFrame }
        // A connected camera can supply motion to an otherwise photographic film.
        let videos = primary.isEmpty ? items.filter { $0.kind == .video && !$0.isFreezeFrame } : primary
        let motion = videos.flatMap { item -> [Motion] in
            guard let id = item.assetID, let fps = byID[id]?.metadata.frameRate,
                  fps.isFinite, fps > 0, fps <= 1_000,
                  item.sourceDuration.isFinite, item.sourceDuration > 0,
                  item.timelineDuration.isFinite, item.timelineDuration > 0 else { return [] }
            let family = sourceFamily(fps)
            if let ramp = item.speedRamp {
                let points = ramp.normalizedPoints
                let rampDuration = ramp.outputDuration(sourceDuration: item.sourceDuration)
                guard rampDuration.isFinite, rampDuration > 0 else { return [] }
                // PlaybackEngine inserts each ramp segment at its mean rate,
                // then scales the complete range to timelineDuration.
                return zip(points, points.dropFirst()).compactMap { from, to in
                    let rate = max(0.1, (from.rate + to.rate) / 2)
                    let duration = item.sourceDuration * (to.position - from.position) / rate
                        * item.timelineDuration / rampDuration
                    guard duration.isFinite, duration > 0 else { return nil }
                    return Motion(family: family.0, fractional: family.1,
                                  rate: fps * rate * rampDuration / item.timelineDuration, duration: duration)
                }
            }
            return [Motion(family: family.0, fractional: family.1,
                           rate: fps * item.sourceDuration / item.timelineDuration, duration: item.timelineDuration)]
        }
        guard !motion.isEmpty else { return fallback.isFinite && fallback > 0 ? fallback : 30 }

        // Duration, not the number of files/cuts, decides the rate family.
        // Prefer the 30/60 family on ties, then 25/50, then 24/48.
        let families = [30, 25, 24]
        let family = families.dropFirst().reduce(families[0]) { best, candidate in
            weight(motion, family: candidate) > weight(motion, family: best) + 0.000_001 ? candidate : best
        }
        let selected = motion.filter { $0.family == family }
        let high = selected.filter { $0.rate >= Double(family) * 1.5 }
        // Preserve real high-rate motion even when it is a minority of the
        // film, without letting a tiny insert force an expensive HFR delivery.
        let usesHighRate = high.reduce(0) { $0 + $1.duration } >= motion.reduce(0) { $0 + $1.duration } * 0.05
        let authority = usesHighRate ? high : selected
        let fractionalDuration = authority.filter(\.fractional).reduce(0) { $0 + $1.duration }
        let integerDuration = authority.filter { !$0.fractional }.reduce(0) { $0 + $1.duration }
        let rate = Double(family * (usesHighRate ? 2 : 1))
        return fractionalDuration > integerDuration + 0.000_001 ? rate * 1000 / 1001 : rate
    }

    private static func weight(_ motion: [Motion], family: Int) -> Double {
        motion.filter { $0.family == family }.reduce(0) { $0 + $1.duration }
    }

    private static func sourceFamily(_ fps: Double) -> (Int, Bool) {
        // Fractional NTSC rates remain distinct, including 119.88/239.76.
        let candidates: [(Int, Bool)] = [(30, false), (30, true), (25, false), (24, false), (24, true)]
        func error(_ candidate: (Int, Bool)) -> Double {
            let base = Double(candidate.0) * (candidate.1 ? 1000 / 1001.0 : 1)
            let multiple = max(1, (fps / base).rounded())
            return abs(fps - base * multiple) / fps
        }
        return candidates.dropFirst().reduce(candidates[0]) { best, candidate in
            error(candidate) < error(best) - 0.000_001 ? candidate : best
        }
    }
}
