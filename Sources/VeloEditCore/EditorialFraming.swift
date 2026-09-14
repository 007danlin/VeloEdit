import Foundation

public struct ReframeKeyframe: Codable, Hashable, Sendable {
    public var sourceTime: Double
    public var centerX: Double
    public var centerY: Double
    public var scale: Double
    public var confidence: Double
    public init(sourceTime: Double, centerX: Double, centerY: Double, scale: Double = 1, confidence: Double = 1) {
        self.sourceTime = sourceTime
        self.centerX = centerX.clamped01
        self.centerY = centerY.clamped01
        self.scale = max(1, scale)
        self.confidence = confidence.clamped01
    }
}

public struct FramingSafetyReport: Codable, Hashable, Sendable {
    public var minimumPrimaryVisibility: Double
    public var minimumFaceVisibility: Double
    public var groupCoverage: Double
    public var edgeViolationSeconds: Double
    public var centerVelocity: Double
    public var centerAcceleration: Double
    public var cropJumpAtEntry: Double
    public var cropJumpAtExit: Double
    public var passed: Bool
    public var reasons: [String]
}

extension SubjectReframePlan {
    public func interpolated(atSourceTime time: Double) -> ReframeKeyframe {
        let frames = (keyframes ?? []).sorted { $0.sourceTime < $1.sourceTime }
        guard let first = frames.first, let last = frames.last else {
            return ReframeKeyframe(sourceTime: time, centerX: startCenterX, centerY: startCenterY, scale: startScale, confidence: confidence)
        }
        if time <= first.sourceTime { return first }
        if time >= last.sourceTime { return last }
        let end = frames.firstIndex { $0.sourceTime >= time } ?? frames.count - 1
        let a = frames[end - 1], b = frames[end]
        let t = ((time - a.sourceTime) / max(0.000_001, b.sourceTime - a.sourceTime)).clamped01
        // Smoothstep removes velocity discontinuities at sampled waypoints.
        let eased = t * t * (3 - 2 * t)
        return .init(sourceTime: time, centerX: a.centerX + (b.centerX - a.centerX) * eased, centerY: a.centerY + (b.centerY - a.centerY) * eased, scale: a.scale + (b.scale - a.scale) * eased, confidence: min(a.confidence, b.confidence))
    }

    public func interpolated(progress: Double) -> ReframeKeyframe {
        if let first = keyframes?.first, let last = keyframes?.last {
            return interpolated(atSourceTime: first.sourceTime + (last.sourceTime - first.sourceTime) * progress.clamped01)
        }
        let t = progress.clamped01
        return .init(sourceTime: t, centerX: startCenterX + (endCenterX - startCenterX) * t, centerY: startCenterY + (endCenterY - startCenterY) * t, scale: startScale + (endScale - startScale) * t, confidence: confidence)
    }
}

public struct EditorialReframeEngine: Sendable {
    public init() {}
    public func plan(tracking: SubjectTrackingSummary, sourceAspectRatio: Double, targetAspectRatio: Double, isPhoto: Bool = false) -> SubjectReframePlan? {
        guard sourceAspectRatio.isFinite, targetAspectRatio.isFinite, sourceAspectRatio > 0, targetAspectRatio > 0,
              isPhoto || abs(sourceAspectRatio - targetAspectRatio) > 0.04 else { return nil }
        let people: Set<SubjectKind> = [.person, .face, .cyclist]
        let humanTracks = tracking.tracks.filter { people.contains($0.kind) && $0.meanConfidence >= 0.45 }
        let tracks = humanTracks.isEmpty ? tracking.tracks.filter { $0.id == tracking.mainSubjectID && $0.meanConfidence >= 0.45 } : humanTracks
        guard !tracks.isEmpty else { return nil }
        let width = min(1, targetAspectRatio / sourceAspectRatio), height = min(1, sourceAspectRatio / targetAspectRatio)
        let times = Array(Set(tracks.flatMap { $0.observations.map(\.timestamp) })).sorted()
        var keyframes: [ReframeKeyframe] = []
        var maximumVelocity = 0.0, maximumAcceleration = 0.0
        for time in times {
            let regions = tracks.compactMap { track in
                track.observations.min { abs($0.timestamp - time) < abs($1.timestamp - time) }.map { (track.kind, $0.region) }
            }
            var minX = 1.0, maxX = 0.0, minY = 1.0, maxY = 0.0
            for (kind, region) in regions {
                // Faces require 8% of viewport short side. Body edges also
                // retain breathing room; a vehicle never displaces people.
                let marginX = width < 1 ? width * (kind == .face ? 0.08 : 0.04) : 0
                let marginY = height < 1 ? height * (kind == .face ? 0.08 : 0.04) : 0
                minX = min(minX, region.x - marginX)
                maxX = max(maxX, region.x + region.width + marginX)
                minY = min(minY, region.y - marginY)
                maxY = max(maxY, region.y + region.height + marginY)
            }
            let lowerX = max(width / 2, maxX - width / 2), upperX = min(1 - width / 2, minX + width / 2)
            let lowerY = max(height / 2, maxY - height / 2), upperY = min(1 - height / 2, minY + height / 2)
            // Unsafe fill has no valid plan. Callers choose fit or another take.
            guard lowerX <= upperX + 0.000_001, lowerY <= upperY + 0.000_001 else { return nil }
            let movement = tracks.reduce(0) { $0 + $1.movementX } / Double(tracks.count)
            let desiredX = (minX + maxX) / 2 + min(width * 0.08, max(-width * 0.08, movement * 0.2))
            let desiredY = (minY + maxY) / 2
            let x = min(upperX, max(lowerX, desiredX)), y = min(upperY, max(lowerY, desiredY))
            if let previous = keyframes.last {
                let dt = max(0.001, time - previous.sourceTime)
                let velocity = hypot(x - previous.centerX, y - previous.centerY) / dt
                let acceleration = 6 * hypot(x - previous.centerX, y - previous.centerY) / (dt * dt)
                maximumVelocity = max(maximumVelocity, velocity * 1.5)
                maximumAcceleration = max(maximumAcceleration, acceleration)
                // If a safe crop requires a sudden pan, fit preserves the real
                // movement without inventing a digital camera whip.
                guard velocity * 1.5 <= 0.45, acceleration <= 1.2 else { return nil }
            }
            keyframes.append(.init(sourceTime: time, centerX: x, centerY: y, confidence: tracking.confidence))
        }
        guard let first = keyframes.first, let last = keyframes.last else { return nil }
        var result = SubjectReframePlan(startCenterX: first.centerX, startCenterY: first.centerY, endCenterX: last.centerX, endCenterY: last.centerY, startScale: 1, endScale: 1, targetAspectRatio: targetAspectRatio, confidence: tracking.confidence, reasons: ["Все значимые люди/лица внутри безопасного viewport; учтено направление движения", "\(keyframes.count) временных keyframes; при невозможном fill используется fit"])
        result.keyframes = keyframes
        // Smooth camera interpolation can lag behind linear subject motion.
        // Verify the in-between viewport too, before claiming full visibility.
        for (a, b) in zip(keyframes, keyframes.dropFirst()) {
            for fraction in stride(from: 0.0, through: 1.0, by: 0.125) {
                let time = a.sourceTime + (b.sourceTime - a.sourceTime) * fraction
                let crop = result.interpolated(atSourceTime: time)
                for track in tracks {
                    guard let region = Self.region(track, at: time) else { continue }
                    let marginX = width < 1 ? width * (track.kind == .face ? 0.08 : 0.04) : 0
                    let marginY = height < 1 ? height * (track.kind == .face ? 0.08 : 0.04) : 0
                    guard region.x - marginX >= crop.centerX - width / 2 - 0.0001,
                          region.x + region.width + marginX <= crop.centerX + width / 2 + 0.0001,
                          region.y - marginY >= crop.centerY - height / 2 - 0.0001,
                          region.y + region.height + marginY <= crop.centerY + height / 2 + 0.0001 else { return nil }
                }
            }
        }
        result.safetyReport = FramingSafetyReport(minimumPrimaryVisibility: 1, minimumFaceVisibility: 1, groupCoverage: 1, edgeViolationSeconds: 0, centerVelocity: maximumVelocity, centerAcceleration: maximumAcceleration, cropJumpAtEntry: 0, cropJumpAtExit: 0, passed: true, reasons: result.reasons)
        return result
    }
    private static func region(_ track: SubjectTrack, at time: Double) -> NormalizedRegion? {
        let points = track.observations.sorted { $0.timestamp < $1.timestamp }
        guard let first = points.first, let last = points.last else { return nil }
        if time <= first.timestamp { return first.region }
        if time >= last.timestamp { return last.region }
        guard let next = points.firstIndex(where: { $0.timestamp >= time }), next > 0 else { return nil }
        let a = points[next - 1], b = points[next]
        let t = (time - a.timestamp) / max(0.00001, b.timestamp - a.timestamp)
        return NormalizedRegion(x: a.region.x + (b.region.x - a.region.x) * t, y: a.region.y + (b.region.y - a.region.y) * t, width: a.region.width + (b.region.width - a.region.width) * t, height: a.region.height + (b.region.height - a.region.height) * t)
    }

}
