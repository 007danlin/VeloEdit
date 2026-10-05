import Foundation
import Testing
@testable import VeloEditCore

@Suite(.serialized) struct FilmDurationRecoveryTests {
    @Test func fillsFromUnusedReadableRangesWithoutRepeatsOrExcludedFootage() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("veloedit-runtime-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("camera.mp4")
        let producer = Process()
        producer.executableURL = try #require(MediaCompatibility.converterURL)
        producer.arguments = ["-nostdin", "-loglevel", "error", "-f", "lavfi", "-i", "testsrc2=size=96x64:rate=30", "-t", "10", "-c:v", "libx264", "-pix_fmt", "yuv420p", source.path]
        try producer.run(); producer.waitUntilExit()
        #expect(producer.terminationStatus == 0)
        let asset = try await MediaImporter().makeAsset(url: source)
        var forbidden = Candidate(assetID: asset.id, sourceStart: 2, sourceDuration: 3,
            scores: .init(quality: 0.5, interest: 0.5, action: 0, stability: 0.5))
        forbidden.excluded = true
        var insights = CandidateInsights(sceneSummary: "measured fixture")
        insights.editorialEvidence = .init(usableRange: .init(start: 5, end: 10), atmosphereValue: 0.8, confidence: 0.9)
        let measured = Candidate(assetID: asset.id, sourceStart: 5, sourceDuration: 5,
            scores: .init(quality: 0.9, interest: 0.9, action: 0, stability: 0.9), insights: insights)
        let analyses = [AnalysisResult(assetID: asset.id, analyzedContentHash: asset.contentHash, candidates: [forbidden, measured])]
        let plan = StoryPlan(prompt: "Ровно 6 секунд", preset: .story, constraints: .init(targetDuration: 6), chapters: [])
        let first = TimelineItem(assetID: asset.id, kind: .video, sourceStart: 0, sourceDuration: 2, timelineStart: 0, timelineDuration: 2)
        let original = Timeline(storyPlanID: plan.id, width: 96, height: 64, frameRate: 30, items: [first])
        let repaired = try await FilmDurationRecovery.extend(original, requirement: .parse(prompt: plan.prompt),
            plan: plan, assets: [asset], analyses: analyses)
        #expect(abs(AutomaticFilmDurationPolicy.renderedDuration(of: repaired) - 6) < 1 / 30)
        #expect(repaired.items.first == first)
        #expect(repaired.items.count == 2)
        #expect(repaired.items[1].sourceStart >= 5)
        #expect(repaired.items[1].sourceStart + repaired.items[1].sourceDuration <= 10)
        #expect(repaired.items[1].candidateID == measured.id)
        let unmeasured = try await FilmDurationRecovery.extend(original, requirement: .parse(prompt: plan.prompt),
            plan: plan, assets: [asset], analyses: [])
        #expect(unmeasured == original)
        // If there is insufficient unused material, retain the playable result
        // without duplicating footage, freezing frames or claiming exactness.
        let limited = try await FilmDurationRecovery.extend(original, requirement: .parse(prompt: "Ровно 20 секунд"),
            plan: plan, assets: [asset], analyses: analyses)
        #expect(abs(AutomaticFilmDurationPolicy.renderedDuration(of: limited) - 7) < 1 / 30)
        #expect(limited.items.allSatisfy { $0.freezeFrame != true })
    }

    @Test func automaticAndMaximumRequestsDoNotPadTheExistingEdit() async throws {
        let plan = StoryPlan(prompt: "Фильм", preset: .story, constraints: .init(targetDuration: 120), chapters: [])
        let timeline = Timeline(storyPlanID: plan.id, items: [TimelineItem(assetID: UUID(), kind: .photo,
            sourceDuration: 2, timelineStart: 0, timelineDuration: 2)])
        for prompt in ["Фильм", "Не больше 120 секунд"] {
            let result = try await FilmDurationRecovery.extend(timeline, requirement: .parse(prompt: prompt),
                plan: plan, assets: [], analyses: [])
            #expect(result == timeline)
        }
    }
}
