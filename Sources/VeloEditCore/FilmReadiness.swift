import Foundation

/// One readiness calculation shared by the UI and regression tests.
/// An existing montage is deliberately not counted when a newer brief has
/// not been applied yet: it remains playable, but it is not the requested film.
public enum FilmReadinessCalculator {
    public static func value(
        assetCount: Int,
        analyzedCount: Int,
        hasMontage: Bool,
        hasPlayback: Bool,
        hasPendingChanges: Bool,
        activeBuildProgress: Double? = nil
    ) -> Double {
        if let activeBuildProgress {
            return min(1, max(0, activeBuildProgress))
        }
        guard assetCount > 0 else { return 0 }
        let analysisFraction = min(1, max(0, Double(analyzedCount) / Double(assetCount)))
        var result = 0.15 + analysisFraction * 0.50
        if !hasPendingChanges {
            if hasMontage { result += 0.25 }
            if hasPlayback { result += 0.10 }
        }
        return min(1, max(0, result))
    }
}
