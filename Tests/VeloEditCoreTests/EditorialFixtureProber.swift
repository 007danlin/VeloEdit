import Foundation
@testable import VeloEditCore

/// Metadata-only orchestration fixtures intentionally have no media files.
/// Their decoding boundary is synthetic; EditorialIntelligenceTests and the
/// production photo test separately exercise real AVComposition decoding.
struct FixtureEditorialProber: EditorialRenderedProbing {
    func frames(timeline: Timeline, assets: [MediaAsset], tracks: [LocalMusicTrack], telemetry: [UUID: TelemetrySummary], cacheURL: URL) async throws -> [PerceptualRenderedFrameEvidence] {
        let times = EditorialProbeSchedule.times(timeline: timeline)
        let items = timeline.items.filter { $0.overlay == nil && $0.kind != .title }
        var frames = times.map { time in
            var frame = PerceptualRenderedFrameEvidence(timelineTime: time, meanLuma: 0.5, lumaDeviation: 0.2, isBlack: false, source: "Explicit synthetic orchestration fixture; not real media")
            frame.decodeFailed = false
            frame.titleReadability = 1
            return frame
        }
        guard !frames.isEmpty else { return frames }
        frames[0].editorialClaims = EditorialEvidenceDomain.allCases.map { domain in
            EditorialSemanticClaim(domain: domain, status: .passed, itemIDs: items.map(\.id), probeTimes: times.filter { time in items.contains { time >= $0.timelineStart && time < $0.timelineStart + $0.timelineDuration } }, confidence: 1, observation: "Synthetic independent semantic fixture for orchestration only", method: "FixtureEditorialProber", renderSignature: EditorialRenderSignature.signature(timeline), finding: nil)
        }
        frames[0].exportVerification = EditorialExportVerification(renderSignature: EditorialRenderSignature.signature(timeline), probes: times.map { .init(time: $0, decoded: true, hashDistance: 0, meanLumaDifference: 0, meanAbsolutePixelDifference: 0) }, durationDifference: 0, aspectRatioMatches: true, encodedAudio: .init(integratedLUFS: -16, truePeakDBTP: -2, appliedGainDB: 0, outputLUFS: -16, outputTruePeakDBTP: -2, peakLimited: false, measuredFrames: Int(timeline.duration * 48_000)), provenance: "Explicit synthetic export fixture; no claim about real encode")
        return frames
    }
}

/// Real decodable media for planner integration fixtures. Semantics remain
/// supplied by the fixture prober; production playback still opens real bytes.
func materializeEditorialFixtureMedia(_ assets: [MediaAsset], at root: URL) async throws -> [MediaAsset] {
    let image = root.appendingPathComponent("fixture.png")
    try AutonomousOperationTests.photo(at: image)
    let video = root.appendingPathComponent("fixture.mov")
    _ = try await StillImageVideoGenerator().generate(imageURL: image,
        duration: max(1, assets.compactMap { $0.metadata.duration }.max() ?? 10),
        width: 160, height: 90, frameRate: 15, destination: video, motion: nil)
    return try assets.map { asset in
        var value = asset
        let unique = root.appendingPathComponent("fixture-\(asset.id).mov")
        try FileManager.default.linkItem(at: video, to: unique)
        value.originalURL = unique
        value.bookmarkData = nil
        return value
    }
}

struct FixtureEditorialAnalyzer: VisionModelProtocol {
    let analyses: [AnalysisResult]
    func analyze(asset: MediaAsset) async throws -> AnalysisResult {
        guard let result = analyses.first(where: { $0.assetID == asset.id }) else { throw CocoaError(.fileReadCorruptFile) }
        return result
    }
}

func preparedFixtureAnalyses(_ analyses: [AnalysisResult], preferences: UserPreferences) -> [AnalysisResult] {
    let profile = AIAnalysisProfile.resolve(mode: preferences.effectiveAIPowerMode,
        advanced: preferences.effectiveAdvancedAISettings, thermalState: .nominal)
    return analyses.map { original in
        var result = original
        result.deepMediaVersion = DeepAnalysisCache.version
        result.completedDepth = profile.targetDepth
        result.analysisProfileKey = profile.cacheKey
        return result
    }
}
