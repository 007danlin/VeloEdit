import Foundation

/// A source-timeline event derived from synchronized camera telemetry.
public struct TelemetryMoment: Codable, Hashable, Sendable {
    public let timestamp: Double
    public let score: Double
    public let speedMetersPerSecond: Double?
    public let accelerationMetersPerSecondSquared: Double
    public let gForce: Double?
    public let verticalSpeedMetersPerSecond: Double
    public let turnIntensity: Double
    public let tags: Set<String>

    public init(
        timestamp: Double,
        score: Double,
        speedMetersPerSecond: Double? = nil,
        accelerationMetersPerSecondSquared: Double = 0,
        gForce: Double? = nil,
        verticalSpeedMetersPerSecond: Double = 0,
        turnIntensity: Double = 0,
        tags: Set<String> = []
    ) {
        self.timestamp = timestamp
        self.score = min(1, max(0, score))
        self.speedMetersPerSecond = speedMetersPerSecond
        self.accelerationMetersPerSecondSquared = max(0, accelerationMetersPerSecondSquared)
        self.gForce = gForce
        self.verticalSpeedMetersPerSecond = max(0, verticalSpeedMetersPerSecond)
        self.turnIntensity = min(1, max(0, turnIntensity))
        self.tags = tags
    }

    public var explanation: String {
        var parts: [String] = []
        if let speedMetersPerSecond, tags.contains("high-speed") {
            parts.append(String(format: "скорость %.0f км/ч", speedMetersPerSecond * 3.6))
        }
        if tags.contains("acceleration") {
            parts.append(String(format: "ускорение %.1f м/с²", accelerationMetersPerSecondSquared))
        }
        if let gForce, tags.contains("g-force") { parts.append(String(format: "перегрузка %.1f g", gForce)) }
        if tags.contains("elevation-change") {
            parts.append(String(format: "перепад %.1f м/с", verticalSpeedMetersPerSecond))
        }
        if tags.contains("turn") { parts.append("резкая смена направления") }
        return parts.isEmpty ? "выраженный пик телеметрии" : parts.joined(separator: ", ")
    }
}

/// Converts raw, timestamped GPMF readings into comparable highlight scores.
/// Absolute safety floors prevent tiny changes in an otherwise static clip
/// from being promoted merely because they are the largest values available.
public struct TelemetryHighlightDetector: Sendable {
    public init() {}

    public func moments(from telemetry: TelemetrySummary?, duration: Double? = nil) -> [TelemetryMoment] {
        guard let samples = telemetry?.timedSamples?.sorted(by: { $0.timestamp < $1.timestamp }), !samples.isEmpty else { return [] }
        let filtered = samples.filter { sample in
            guard sample.timestamp.isFinite, sample.timestamp >= 0 else { return false }
            return duration.map { sample.timestamp <= $0 + 0.5 } ?? true
        }
        guard !filtered.isEmpty else { return [] }

        var accelerations = [Double](repeating: 0, count: filtered.count)
        var verticalSpeeds = [Double](repeating: 0, count: filtered.count)
        var turns = [Double](repeating: 0, count: filtered.count)
        for index in filtered.indices where index > 0 {
            let previous = filtered[index - 1]
            let current = filtered[index]
            let deltaTime = current.timestamp - previous.timestamp
            guard deltaTime >= 0.02, deltaTime <= 8 else { continue }
            if let left = previous.speedMetersPerSecond, let right = current.speedMetersPerSecond {
                accelerations[index] = abs(right - left) / deltaTime
            }
            if let left = previous.altitudeMeters, let right = current.altitudeMeters {
                verticalSpeeds[index] = abs(right - left) / deltaTime
            }
            if index + 1 < filtered.count,
               let first = previous.coordinate,
               let middle = current.coordinate,
               let last = filtered[index + 1].coordinate {
                let firstBearing = bearing(from: first, to: middle)
                let secondBearing = bearing(from: middle, to: last)
                let delta = abs(firstBearing - secondBearing).truncatingRemainder(dividingBy: 360)
                turns[index] = min(delta, 360 - delta) / 90
            }
        }

        let speedScale = robustScale(filtered.compactMap(\.speedMetersPerSecond), floor: 8)
        let accelerationScale = robustScale(accelerations, floor: 4)
        let impactValues = filtered.map { abs(($0.gForce ?? 1) - 1) }
        let impactScale = robustScale(impactValues, floor: 0.75)
        let verticalScale = robustScale(verticalSpeeds, floor: 3)

        return filtered.indices.map { index in
            let sample = filtered[index]
            let speed = normalized(sample.speedMetersPerSecond ?? 0, scale: speedScale)
            let acceleration = normalized(accelerations[index], scale: accelerationScale)
            let impact = normalized(impactValues[index], scale: impactScale)
            let vertical = normalized(verticalSpeeds[index], scale: verticalScale)
            let turn = min(1, max(0, turns[index]))
            let weighted = 0.25 * speed + 0.28 * acceleration + 0.27 * impact + 0.10 * vertical + 0.10 * turn
            let event = max(acceleration, impact, vertical, turn)
            let score = min(1, weighted * 0.68 + event * 0.32)
            var tags = Set<String>()
            if speed >= 0.65 { tags.insert("high-speed") }
            if acceleration >= 0.55 { tags.insert("acceleration") }
            if impact >= 0.50 { tags.insert("g-force") }
            if vertical >= 0.55 { tags.insert("elevation-change") }
            if turn >= 0.55 { tags.insert("turn") }
            if score >= 0.35 { tags.insert("telemetry-event") }
            return TelemetryMoment(
                timestamp: sample.timestamp,
                score: score,
                speedMetersPerSecond: sample.speedMetersPerSecond,
                accelerationMetersPerSecondSquared: accelerations[index],
                gForce: sample.gForce,
                verticalSpeedMetersPerSecond: verticalSpeeds[index],
                turnIntensity: turn,
                tags: tags
            )
        }
    }

    public func rankedMoments(
        from telemetry: TelemetrySummary?,
        duration: Double? = nil,
        limit: Int,
        minimumGap: Double
    ) -> [TelemetryMoment] {
        guard limit > 0 else { return [] }
        var selected: [TelemetryMoment] = []
        for moment in moments(from: telemetry, duration: duration).sorted(by: { $0.score > $1.score }) where moment.score >= 0.12 {
            if selected.allSatisfy({ abs($0.timestamp - moment.timestamp) >= minimumGap }) {
                selected.append(moment)
                if selected.count == limit { break }
            }
        }
        return selected
    }

    public func strongestMoment(in range: ClosedRange<Double>, moments: [TelemetryMoment]) -> TelemetryMoment? {
        moments.filter { range.contains($0.timestamp) }.max { $0.score < $1.score }
    }

    private func normalized(_ value: Double, scale: Double) -> Double {
        min(1, max(0, value / max(0.0001, scale)))
    }

    private func robustScale(_ values: [Double], floor: Double) -> Double {
        let finite = values.filter { $0.isFinite && $0 >= 0 }.sorted()
        guard !finite.isEmpty else { return floor }
        let index = min(finite.count - 1, Int((Double(finite.count - 1) * 0.90).rounded()))
        return max(floor, finite[index])
    }

    private func bearing(from lhs: TelemetryCoordinate, to rhs: TelemetryCoordinate) -> Double {
        let lat1 = lhs.latitude * .pi / 180
        let lat2 = rhs.latitude * .pi / 180
        let deltaLongitude = (rhs.longitude - lhs.longitude) * .pi / 180
        let y = sin(deltaLongitude) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(deltaLongitude)
        return atan2(y, x) * 180 / .pi
    }
}
