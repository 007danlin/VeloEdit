import Foundation

public struct EditorialContinuityEdge: Codable, Hashable, Sendable {
    public var from: UUID
    public var to: UUID
    public var cost: Double
    public var benefits: [String]
    public var risks: [String]
}

/// A directed edge is evaluated from evidence, never filename order.
public struct EditorialContinuityGraph: Sendable {
    public init() {}
    public func edge(from a: EditorialUnit, to b: EditorialUnit) -> EditorialContinuityEdge {
        var cost = 0.0
        var benefits: [String] = [], risks: [String] = []
        let pair = ShotFamilyClusterer().similarity(a, b)
        cost += pair.combined * 0.2
        if pair.combined >= 0.78 { risks.append("duplicate setup") }
        if a.eventID == b.eventID && a.candidate.assetID == b.candidate.assetID && b.sourceRange.start < a.sourceRange.start {
            cost += 0.35; risks.append("reverse source chronology inside event")
        }
        let left = a.candidate.insights?.subjectTracking?.mainSubject
        let right = b.candidate.insights?.subjectTracking?.mainSubject
        if let left, let right {
            if left.movementX * right.movementX < -0.01 { cost += 0.18; risks.append("screen direction conflict") }
            else if abs(left.movementX) > 0.05 && abs(right.movementX) > 0.05 { cost -= 0.1; benefits.append("movement match") }
            if let end = left.observations.last?.region, let start = right.observations.first?.region {
                let jump = hypot((end.x + end.width / 2) - (start.x + start.width / 2), (end.y + end.height / 2) - (start.y + start.height / 2))
                if jump > 0.4 { cost += 0.2; risks.append("subject position jump") }
            }
        }
        if a.evidence.shotScale == .wide && [.medium, .close, .detail].contains(b.evidence.shotScale) {
            cost -= 0.12; benefits.append("wide to detail")
        }
        if a.evidence.hasProgression && b.evidence.completion >= 0.65 { cost -= 0.12; benefits.append("action to completion") }
        let energyChange = abs(a.candidate.scores.action - b.candidate.scores.action)
        if energyChange > 0.65 && b.evidence.completion < 0.65 { cost += 0.15; risks.append("unexplained energy jump") }
        if a.speechSeconds > 0 && b.speechSeconds > 0 && a.candidate.assetID != b.candidate.assetID {
            cost += 0.1; risks.append("speech boundary requires audio bridge")
        }
        if a.evidence.background != nil && b.evidence.background != nil && a.evidence.background != b.evidence.background && a.eventID == b.eventID {
            cost += 0.1; risks.append("location change needs orientation")
        }
        return .init(from: a.id, to: b.id, cost: cost.clamped01, benefits: benefits, risks: risks)
    }
}
