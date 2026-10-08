import Foundation
import Testing
@testable import VeloEditCore

struct MusicExportCreditsTests {
    private func track(required: Bool?, provider: MusicSourceProvider = .openverse) -> LocalMusicTrack {
        let url = URL(fileURLWithPath: "/tmp/credits-fixture.mp3")
        return LocalMusicTrack(title: "Music", author: "Artist", bpm: 100, genres: [], moods: [],
            energy: 0.5, duration: 10,
            license: .init(name: required == false ? "CC0" : "CC BY 4.0",
                url: URL(string: "https://creativecommons.org/licenses/by/4.0/")!,
                attributionText: "Music — Artist", requiresAttribution: required),
            sourceProvider: provider, sourcePageURL: url, localFileURL: url, originalFileName: "music.mp3")
    }

    private func timeline(_ track: LocalMusicTrack?) -> Timeline {
        Timeline(storyPlanID: UUID(), items: [
            TimelineItem(kind: .title, sourceDuration: 10, timelineStart: 0, timelineDuration: 10, title: "Film")
        ], music: track.map { MusicDirective(style: .calm, bpm: 100, trackID: $0.id) })
    }

    @Test func silentAndCC0FilmsHaveNoLicenseSidecarContents() {
        let cc0 = track(required: false, provider: .bundled)
        let unused = track(required: true)
        #expect(MusicCredit.requiredForExport(timeline: timeline(nil), tracks: [cc0, unused]).isEmpty)
        #expect(MusicCredit.requiredForExport(timeline: timeline(cc0), tracks: [cc0, unused]).isEmpty)
    }

    @Test func onlyCurrentMusicIsCreditedAndLegacyAttributionIsPreserved() {
        let current = track(required: nil)
        let previous = track(required: true)
        let credits = MusicCredit.requiredForExport(timeline: timeline(current), tracks: [previous, current, current])
        #expect(credits == [MusicCredit(track: current)])
    }

    @Test func adaptiveAndIndependentAudioKeepTheirRequiredAttribution() {
        let primary = track(required: false, provider: .bundled)
        let adaptive = track(required: true)
        let independent = track(required: true)
        var film = timeline(primary)
        film.adaptiveSoundtrack = AdaptiveSoundtrackPlan(primaryTrackID: primary.id, timelineDuration: 10,
            segments: [
                AdaptiveMusicSegment(timelineStart: 0, timelineDuration: 5,
                    directive: MusicDirective(style: .calm, bpm: 100, trackID: primary.id),
                    semanticLabel: "Opening", energy: 0.5, confidence: 1),
                AdaptiveMusicSegment(timelineStart: 5, timelineDuration: 5,
                    directive: MusicDirective(style: .calm, bpm: 100, trackID: adaptive.id),
                    semanticLabel: "Ending", energy: 0.5, confidence: 1)
            ], confidence: 1)
        film.audioClips = [TimelineAudioClip(trackID: independent.id, title: "Music", role: .music,
            sourceDuration: 10, timelineStart: 0, timelineDuration: 10)]
        #expect(film.effectiveAdaptiveSoundtrack != nil)
        #expect(MusicCredit.requiredForExport(timeline: film, tracks: [primary, adaptive, independent])
            == [MusicCredit(track: adaptive), MusicCredit(track: independent)])
    }
}
