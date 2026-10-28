import Foundation
import Testing
@testable import VeloEditCore

struct SilentFilmAudioVerificationTests {
    private func fixture() -> (Timeline, StoryPlan, MediaAsset) {
        let source = MediaAsset(originalURL: URL(fileURLWithPath: "/tmp/audio-expectation.mov"),
            kind: .video, byteSize: 1, contentHash: "fixture", metadata: MediaMetadata(duration: 10, hasAudio: false))
        let plan = StoryPlan(prompt: "Без музыки", preset: .story,
            constraints: StoryConstraints(targetDuration: 10, pacing: 0.4), chapters: [])
        let item = TimelineItem(assetID: source.id, kind: .video, sourceDuration: 10,
            timelineStart: 0, timelineDuration: 10, locked: true)
        return (Timeline(storyPlanID: plan.id, items: [item], originalAudioVolume: 1), plan, source)
    }

    @Test func absenceIsProbedInsteadOfInferredFromStaleMetadata() async {
        let (timeline, _, source) = fixture()
        #expect(await EditorialDeliveryVerifier.expectsAudio(timeline: timeline, assets: [source], sourceHasAudio: { _ in false }) == false)
        #expect(await EditorialDeliveryVerifier.expectsAudio(timeline: timeline, assets: [source], sourceHasAudio: { _ in true }))
        #expect(await EditorialDeliveryVerifier.expectsAudio(timeline: timeline, assets: [source], sourceHasAudio: { _ in throw URLError(.cannotOpenFile) }))
        #expect(await EditorialDeliveryVerifier.expectsAudio(timeline: timeline, assets: [], sourceHasAudio: { _ in false }))
    }

    @Test(arguments: [true, false]) func onlyConfirmedAbsentAudioIsOptional(_ encodedTrackExists: Bool) async throws {
        let (timeline, plan, _) = fixture()
        var frames = try await FixtureEditorialProber().frames(timeline: timeline, assets: [], tracks: [],
            telemetry: [:], cacheURL: FileManager.default.temporaryDirectory)
        for index in frames.indices {
            frames[index].exportVerification?.expectsAudio = false
            if !encodedTrackExists { frames[index].exportVerification?.encodedAudio = nil }
        }
        let records = EditorialEvidenceVerifier.verify(timeline: timeline, plan: plan, analyses: [], frames: frames, findings: [])
        for domain in [EditorialEvidenceDomain.integratedLoudness, .truePeak] {
            #expect(try #require(records.first { $0.domain == domain }).required == encodedTrackExists)
        }
    }

    @Test func missingMeasurementsInLegacyReportsRemainRequired() async throws {
        let (timeline, plan, _) = fixture()
        var frames = try await FixtureEditorialProber().frames(timeline: timeline, assets: [], tracks: [],
            telemetry: [:], cacheURL: FileManager.default.temporaryDirectory)
        for index in frames.indices { frames[index].exportVerification?.encodedAudio = nil }
        let records = EditorialEvidenceVerifier.verify(timeline: timeline, plan: plan, analyses: [], frames: frames, findings: [])
        #expect(records.contains { $0.domain == .truePeak && $0.required && !$0.isSufficient })
        #expect(records.contains { $0.domain == .integratedLoudness && $0.required && !$0.isSufficient })
    }
}
