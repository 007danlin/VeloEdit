import Testing
@testable import VeloEditCore

@Test func pendingBriefInvalidatesOldMontageAndPlaybackReadiness() {
    let current = FilmReadinessCalculator.value(
        assetCount: 3,
        analyzedCount: 3,
        hasMontage: true,
        hasPlayback: true,
        hasPendingChanges: false
    )
    let pending = FilmReadinessCalculator.value(
        assetCount: 3,
        analyzedCount: 3,
        hasMontage: true,
        hasPlayback: true,
        hasPendingChanges: true
    )

    #expect(current == 1)
    #expect(pending == 0.65)
}

@Test func activeFilmBuildUsesItsRealProgress() {
    let readiness = FilmReadinessCalculator.value(
        assetCount: 3,
        analyzedCount: 3,
        hasMontage: true,
        hasPlayback: true,
        hasPendingChanges: true,
        activeBuildProgress: 0.42
    )
    #expect(readiness == 0.42)
}
