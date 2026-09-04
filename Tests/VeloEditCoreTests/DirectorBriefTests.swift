import Foundation
import Testing
@testable import VeloEditCore

@Test func directorBriefRoundTripsEveryOpeningChoice() throws {
    let trackID = UUID()
    let brief = DirectorBrief(
        canvasFormat: .portrait9x16,
        requestedDuration: 300,
        mood: .calm,
        musicPolicy: .specificTrack,
        musicTrackID: trackID,
        sourceAudioPolicy: .mute,
        titlePolicy: .keyOnly
    )
    let state = ProjectWorkspaceState(
        prompt: "Семейная поездка",
        preset: .cinematic,
        targetMinutes: 5,
        directorMusicTrackID: trackID,
        directorBrief: brief
    )

    let decoded = try JSONDecoder().decode(
        ProjectWorkspaceState.self,
        from: JSONEncoder().encode(state)
    )

    #expect(decoded.directorBrief == brief)
    #expect(decoded.directorBrief?.canvasFormat.width == 1080)
    #expect(decoded.directorBrief?.canvasFormat.height == 1920)
}

@Test func legacyStoryPlanWithoutDirectorBriefStillDecodes() throws {
    let json = """
    {
      "id": "00000000-0000-0000-0000-000000000001",
      "version": 1,
      "prompt": "legacy",
      "preset": "story",
      "constraints": {
        "targetDuration": 30,
        "targetClipCount": null,
        "includeTags": [],
        "excludeTags": [],
        "maximumTagShares": {},
        "preferPhotos": false,
        "allowSlowMotion": true,
        "transitionFrequency": 0.1,
        "pacing": 0.5,
        "preferredIntroTags": null,
        "preferredClimaxTags": null,
        "preferredOutroTags": null
      },
      "chapters": [],
      "createdAt": 0
    }
    """.data(using: .utf8)!

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .secondsSince1970
    let plan = try decoder.decode(StoryPlan.self, from: json)
    #expect(plan.directorBrief == nil)
}

@Test func displayAspectUsesVideoPreferredTransformOnlyOnceAndPhotoEXIFOnce() {
    let video = MediaAsset(
        originalURL: URL(fileURLWithPath: "/tmp/oriented.mov"),
        kind: .video,
        byteSize: 1,
        contentHash: "video-oriented",
        metadata: MediaMetadata(width: 1080, height: 1920, orientationDegrees: 90)
    )
    let photo = MediaAsset(
        originalURL: URL(fileURLWithPath: "/tmp/oriented.jpg"),
        kind: .photo,
        byteSize: 1,
        contentHash: "photo-oriented",
        metadata: MediaMetadata(width: 1920, height: 1080, orientationDegrees: 90)
    )

    #expect(video.displayDimensions?.width == 1080)
    #expect(video.displayDimensions?.height == 1920)
    #expect(photo.displayDimensions?.width == 1080)
    #expect(photo.displayDimensions?.height == 1920)
}
