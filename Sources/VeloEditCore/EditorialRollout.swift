import Foundation

/// Independent evaluation remains recorded separately from feature activation.
/// The user authorized default rollout before the 20-project blind comparison.
public struct EditorialHumanComparison: Codable, Hashable, Sendable {
    public var projectID: String
    public var reviewerID: String
    public var blinded: Bool
    public var prefersNew: Bool
    public var newCriticalDefect: Bool
    public var problematicVerticalScene: Bool
    public var prefersNewVertical: Bool
    public var intentViolations: Int
}

public struct EditorialHumanEvaluation: Codable, Hashable, Sendable {
    public var comparisons: [EditorialHumanComparison]
    public var modelVersion: Int
    public var reviewedAt: Date
    public var passesReleaseCriteria: Bool {
        guard modelVersion == EditorialEvidenceCache.version, !comparisons.isEmpty,
              comparisons.allSatisfy({ $0.blinded && !$0.projectID.isEmpty && !$0.reviewerID.isEmpty && $0.intentViolations == 0 }) else { return false }
        let projects = Dictionary(grouping: comparisons, by: \.projectID)
        guard projects.count >= 20, projects.values.allSatisfy({ rows in
            Set(rows.map(\.reviewerID)).count >= 3 && Set(rows.map(\.reviewerID)).count == rows.count
        }) else { return false }
        let count = Double(comparisons.count)
        let vertical = comparisons.filter(\.problematicVerticalScene)
        return Double(comparisons.filter(\.prefersNew).count) / count >= 0.75
            && Double(comparisons.filter(\.newCriticalDefect).count) / count <= 0.05
            && !vertical.isEmpty
            && Double(vertical.filter(\.prefersNewVertical).count) / Double(vertical.count) >= 0.85
    }
}

public enum EditorialRolloutPolicy {
    public static func isEnabled(in project: ProjectManifest) -> Bool {
        // Editorial Intelligence V2 is the active production path. An explicit
        // project override remains available for diagnostics and rollback; no
        // UI control is introduced.
        project.editorialDevelopmentEnabled ?? true
    }
}
