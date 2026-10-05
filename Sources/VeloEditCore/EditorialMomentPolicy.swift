import Foundation

public struct EditorialMomentDecision: Codable, Hashable, Sendable {
    public var algorithmVersion: Int = 1
    public var sourceRange: EditorialSourceRange
    public var protectedRange: EditorialSourceRange?
    public var openingValue: Double?
    public var closingValue: Double?
    public var reasons: [String]
}

enum EditorialMomentPolicy {
    static func protectedRange(_ unit: EditorialUnit) -> EditorialSourceRange? {
        var starts: [Double] = [], ends: [Double] = []
        if let speech = unit.candidate.insights?.speech, speech.confidence >= 0.65 {
            starts.append(speech.phraseStart); ends.append(speech.phraseEnd)
        }
        if let boundary = unit.candidate.momentBoundary, boundary.confirmedActionConfidence >= 0.65 {
            starts.append(boundary.anticipationStart); ends.append(boundary.completionEnd)
        }
        if unit.evidence.hasProgression && unit.evidence.completion >= 0.65 {
            starts.append(unit.evidence.usableRange.start); ends.append(unit.evidence.usableRange.end)
        }
        guard let start = starts.min(), let end = ends.max(), end > start else { return nil }
        // Keep the actual evidence contract. Clamping to a short candidate
        // used to silently redefine an interrupted action/phrase as complete.
        // Assembly must find a candidate that contains the entire range.
        return .init(start: max(0, start), end: end)
    }

    static func openingValue(_ unit: EditorialUnit) -> Double {
        let evidence = unit.evidence
        guard evidence.confidence >= 0.55, !evidence.hasHardOcclusion else { return 0 }
        let samples = evidence.samples.filter { $0.sourceTime <= evidence.usableRange.start + 4 && $0.confidence >= 0.55 }
        let people = samples.contains { $0.subjectKinds.contains(.person) }
        let action = samples.contains { !$0.actionState.isEmpty }
        let contextual = evidence.shotScale == .wide && evidence.atmosphereValue >= 0.65
        let detail = evidence.shotScale == .detail || evidence.shotScale == .close
        var value = evidence.entryQuality * 0.15 + evidence.informationGain * 0.25
        if people { value += 0.3 }
        if action { value += 0.3 }
        if contextual { value += 0.25 }
        if evidence.intentionalReveal { value += 0.25 }
        if detail && !people && !action && !evidence.intentionalReveal { value -= 0.25 }
        return value.clamped01
    }

    static func closingValue(_ unit: EditorialUnit) -> Double {
        guard unit.evidence.confidence >= 0.55 else { return 0 }
        let confirmedEnd = unit.evidence.samples.suffix(4).contains {
            $0.confidence >= 0.65 && !$0.actionState.isDisjoint(with: ["landing", "arriving", "catching", "waving", "hugging", "laughing"])
        }
        let complete = unit.evidence.hasProgression ? unit.evidence.completion : 0
        let atmosphere = unit.evidence.shotScale == .wide ? unit.evidence.atmosphereValue * 0.65 : 0
        return max(complete, confirmedEnd ? 0.75 : 0, atmosphere) * unit.evidence.exitQuality
    }
}
