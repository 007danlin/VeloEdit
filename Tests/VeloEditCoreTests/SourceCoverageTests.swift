import Foundation
import Testing
import AVFoundation
import ImageIO
import UniformTypeIdentifiers
@testable import VeloEditCore

@Suite struct SourceCoverageTests {
    private func fixture() -> (Timeline, StoryPlan, [AnalysisResult], [MediaAsset]) {
        let assets = (0..<3).map { index in
            MediaAsset(originalURL: URL(fileURLWithPath: "/tmp/recording-\(index).mov"), kind: .video, byteSize: 1,
                contentHash: "recording-\(index)", metadata: .init(duration: 80, width: 1920, height: 1080, creationDate: Date(timeIntervalSince1970: Double(index * 3600))))
        }
        let analyses = assets.enumerated().map { index, asset in
            let candidates = (0..<3).map { shot in
                let start = Double(shot * 20)
                let tag = "activity-\(index)-\(shot)"
                var insights = CandidateInsights(sceneSummary: tag, dynamics: 0.4, sharpness: 0.9, exposureQuality: 0.9)
                insights.editorialEvidence = .init(usableRange: .init(start: start, end: start + 10), informationGain: 0.5,
                    entryQuality: 0.8, exitQuality: 0.8, atmosphereValue: 0.8, background: tag, confidence: 0.9)
                return Candidate(assetID: asset.id, sourceStart: start, sourceDuration: 10,
                    scores: .init(quality: index == 0 ? 0.95 : 0.7, interest: 0.8, action: 0.4, stability: 0.9, uniqueness: 0.9), tags: [tag], insights: insights)
            }
            return AnalysisResult(assetID: asset.id, analyzedContentHash: asset.contentHash, sceneTags: [], candidates: candidates)
        }
        var plan = StoryPlan(prompt: "Фильм 18 секунд", preset: .story, constraints: .init(targetDuration: 18), chapters: [],
            directorBrief: .init(requestedDuration: 18, mood: .cinematic, musicPolicy: .none, titlePolicy: .none))
        plan.narrativeBeatPlan = .init(pattern: .eventChapters, beats: [], reasons: [])
        let timeline = Timeline(storyPlanID: plan.id, items: analyses[0].candidates.prefix(2).enumerated().map { index, c in
            TimelineItem(candidateID: c.id, assetID: c.assetID, kind: .video, sourceStart: c.sourceStart, sourceDuration: 9,
                timelineStart: Double(index * 9), timelineDuration: 9)
        })
        return (timeline, plan, analyses, assets)
    }

    @Test func saturatedDurationStillReservesDistinctSourcesAndPersistsEvidence() throws {
        let (timeline, plan, analyses, assets) = fixture()
        let before = EditorialQualityGate().review(timeline: timeline, plan: plan, analyses: analyses)
        #expect(before.sourceCoverage?.filter { $0.reason == .selectionGap }.count == 2)
        #expect(before.findings.contains { $0.kind == .sourceCoverageGap })
        let result = AutomaticEditorialAssembly.prepare(timeline: timeline, plan: plan, analyses: analyses, events: [], assets: assets)
        #expect(Set(result.timeline.items.compactMap(\.assetID)) == Set(assets.map(\.id)))
        #expect(abs(result.timeline.duration - 18) < 0.001)
        #expect(result.timeline.items.allSatisfy { $0.timelineDuration >= 1.5 && $0.timelineDuration <= 12 })
        let map = SourceTimelineAnalyzer().analyze(assets: assets, analyses: analyses)
        #expect(EditorialSourceCoverage.chronologyViolations(timeline: result.timeline, sourceMap: map).isEmpty)
        let review = EditorialQualityGate().review(timeline: result.timeline, plan: result.plan, analyses: analyses)
        #expect(!review.findings.contains { [.sourceCoverageGap, .hardDuplicate, .durationPadding, .shotFamilyRunTooLong].contains($0.kind) })
        let decoded = try JSONDecoder.veloEdit.decode(EditorialReview.self, from: JSONEncoder.veloEdit.encode(review))
        #expect(decoded.sourceCoverage?.allSatisfy { $0.reason == .included } == true)
    }

    @Test func oneUnsafeShotDoesNotCondemnWholeRecording() {
        let (timeline, plan, original, assets) = fixture()
        var analyses = original
        analyses[1].candidates[0].insights?.editorialEvidence?.foregroundOcclusion = 0.8
        let (_, evidence, _) = IntentLedgerEngine.validate(.evaluateNewAssets([assets[1].id]), timeline: timeline, previous: nil, analyses: analyses, assets: assets)
        #expect(evidence.first?.reason.hasPrefix("selectionGap:") == true)
        #expect(evidence.first?.candidateIDs?.isEmpty == false)
        let result = AutomaticEditorialAssembly.prepare(timeline: timeline, plan: plan, analyses: analyses, events: [], assets: assets, excluded: [analyses[1].candidates[1].id])
        #expect(result.timeline.items.contains { $0.candidateID == analyses[1].candidates[2].id })
        #expect(!result.timeline.items.contains { $0.candidateID == analyses[1].candidates[0].id || $0.candidateID == analyses[1].candidates[1].id })
    }

    @Test func duplicateAndExcludedSourcesAreNotInsertedForCoverage() {
        let (timeline, plan, original, originalAssets) = fixture()
        var analyses = original, assets = originalAssets
        assets[2].excluded = true
        let prior = analyses[0].candidates[0]
        analyses[1].candidates = [prior]
        analyses[1].candidates[0].id = UUID()
        analyses[1].candidates[0].assetID = assets[1].id
        analyses[1].candidates[0].insights?.editorialEvidence?.informationGain = 0
        let result = AutomaticEditorialAssembly.prepare(timeline: timeline, plan: plan, analyses: analyses, events: [], assets: assets)
        #expect(Set(result.timeline.items.compactMap(\.assetID)) == [assets[0].id])
        let decisions = EditorialSourceCoverage.decisions(timeline: result.timeline, context: .init(analyses: analyses), assets: assets, plan: plan)
        #expect(decisions.first { $0.assetID == assets[1].id }?.reason == .duplicate)
        #expect(decisions.first { $0.assetID == assets[1].id }?.relatedCandidateIDs.isEmpty == false)
        #expect(decisions.first { $0.assetID == assets[2].id }?.reason == .excludedByUser)
    }

    @Test func clipLimitReplacesExtraShotsWithoutLosingExistingSource() {
        let (timeline, original, analyses, assets) = fixture()
        var plan = original
        plan.constraints.targetClipCount = 2
        let result = AutomaticEditorialAssembly.prepare(timeline: timeline, plan: plan, analyses: analyses, events: [], assets: assets)
        #expect(result.timeline.items.count == 2)
        #expect(Set(result.timeline.items.compactMap(\.assetID)).count == 2)
        #expect(result.timeline.items.contains { $0.assetID == assets[0].id })
        #expect(abs(result.timeline.duration - 18) < 0.001)
        let decisions = EditorialSourceCoverage.decisions(timeline: result.timeline, context: .init(analyses: analyses), assets: assets, plan: plan)
        #expect(decisions.filter { $0.reason == .clipLimit }.count == 1)
    }

    @Test func chronologyCheckDetectsReversalAcrossFilesAndInsideFile() {
        let (timeline, _, analyses, originalAssets) = fixture()
        var assets = originalAssets
        var reversed = timeline
        reversed.items[0].sourceStart = 30
        let unknownMap = SourceTimelineAnalyzer().analyze(assets: assets, analyses: analyses)
        #expect(EditorialSourceCoverage.chronologyViolations(timeline: reversed, sourceMap: unknownMap) == [reversed.items[1].id])
        reversed.items[0].assetID = assets[2].id
        reversed.items[1].assetID = assets[0].id
        // Legacy dates without provenance cannot establish cross-file truth.
        #expect(EditorialSourceCoverage.chronologyViolations(timeline: reversed, sourceMap: unknownMap).isEmpty)
        for index in assets.indices {
            assets[index].metadata.dateSource = .embeddedMetadata
            assets[index].metadata.dateConfidence = 0.98
        }
        let map = SourceTimelineAnalyzer().analyze(assets: assets, analyses: analyses)
        #expect(EditorialSourceCoverage.chronologyViolations(timeline: reversed, sourceMap: map) == [reversed.items[1].id])
    }

    @Test func coverageUsesTrimmedRangesWhenOriginalCandidatesOverlap() {
        let (original, plan, originalAnalyses, assets) = fixture()
        var timeline = original, analyses = originalAnalyses
        analyses[0].candidates[1].sourceStart = 5
        analyses[0].candidates[1].insights?.editorialEvidence?.usableRange = .init(start: 5, end: 15)
        timeline.items[0].sourceDuration = 5
        timeline.items[0].timelineDuration = 5
        timeline.items[1].sourceStart = 5
        timeline.items[1].timelineStart = 5
        let result = AutomaticEditorialAssembly.prepare(timeline: timeline, plan: plan, analyses: analyses, events: [], assets: assets)
        #expect(Set(result.timeline.items.compactMap(\.assetID)) == Set(assets.map(\.id)))
        #expect(abs(result.timeline.duration - 18) < 0.001)
        let sameSource = result.timeline.items.filter { $0.assetID == assets[0].id }
        for (left, right) in zip(sameSource, sameSource.dropFirst()) {
            #expect(left.sourceStart + left.sourceDuration <= right.sourceStart + 0.001)
        }
    }

    @Test func explicitContentExclusionSurvivesCoverageAndQualityReview() {
        let (timeline, original, analyses, assets) = fixture()
        var plan = original
        plan.constraints.excludeTags = Set(analyses[1].candidates.flatMap(\.tags))
        let result = AutomaticEditorialAssembly.prepare(timeline: timeline, plan: plan, analyses: analyses, events: [], assets: assets)
        #expect(!result.timeline.items.contains { $0.assetID == assets[1].id })
        let review = EditorialQualityGate().review(timeline: result.timeline, plan: result.plan, analyses: analyses)
        #expect(!review.findings.contains { $0.kind == .sourceCoverageGap })
    }
}

/// Raw decoding only: never open the user's package with ProjectStore, which
/// may migrate it. Reassembly and evidence are written solely to the QA root.
@Test(.enabled(if: ProcessInfo.processInfo.environment["VELOEDIT_SOURCE_COVERAGE_PROJECT"] != nil))
func sourceCoverageRealProjectReadOnlyAudit() async throws {
    let env = ProcessInfo.processInfo.environment
    let input = URL(fileURLWithPath: try #require(env["VELOEDIT_SOURCE_COVERAGE_PROJECT"]))
    let output = URL(fileURLWithPath: try #require(env["VELOEDIT_SOURCE_COVERAGE_OUTPUT"]))
    let bytes = try Data(contentsOf: input)
    let project = try JSONDecoder.veloEdit.decode(ProjectManifest.self, from: bytes)
    let timeline = try #require(project.timelineCheckpoints?.first?.timeline ?? project.timelines.first)
    let plan = try #require(project.storyPlans.first { $0.id == timeline.storyPlanID })
    let context = EditorialAnalysisContext(analyses: project.analyses, events: project.events)
    let result = AutomaticEditorialAssembly.prepare(timeline: timeline, plan: plan, analyses: project.analyses, events: project.events, assets: project.assets)
    let before = EditorialSourceCoverage.decisions(timeline: timeline, context: context, assets: project.assets, plan: plan)
    let after = EditorialSourceCoverage.decisions(timeline: result.timeline, context: context, assets: project.assets, plan: result.plan)
    let map = SourceTimelineAnalyzer().analyze(assets: project.assets, analyses: project.analyses)
    #expect(before.contains { $0.reason == .selectionGap })
    #expect(after.allSatisfy { $0.reason != .selectionGap })
    #expect(abs(result.timeline.duration - timeline.duration) < 1 / timeline.frameRate)
    #expect(EditorialSourceCoverage.chronologyViolations(timeline: result.timeline, sourceMap: map).isEmpty)
    let review = EditorialQualityGate().review(timeline: result.timeline, plan: result.plan, analyses: project.analyses, context: context)
    #expect(!review.findings.contains { [.sourceCoverageGap, .hardDuplicate, .durationPadding, .sourceChronologyViolation].contains($0.kind) })
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    struct Report: Codable { var before: [SourceCoverageDecision]; var after: [SourceCoverageDecision]; var timeline: Timeline; var review: EditorialReview }
    try JSONEncoder.veloEdit.encode(Report(before: before, after: after, timeline: result.timeline, review: review)).write(to: output.appendingPathComponent("reassembly.json"))
    // Inspect real source frames from the newly recovered ranges. Decode at
    // start, middle and end to catch a good thumbnail hiding an unusable shot.
    let missing = Set(before.filter { $0.reason == .selectionGap }.map(\.assetID))
    for item in result.timeline.items where item.assetID.map(missing.contains) == true {
        let asset = try #require(project.assets.first { $0.id == item.assetID })
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: asset.originalURL))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 360)
        for (index, fraction) in [0.05, 0.5, 0.95].enumerated() {
            let frame = try await generator.image(at: CMTime(seconds: item.sourceStart + item.sourceDuration * fraction, preferredTimescale: 600)).image
            let path = output.appendingPathComponent("\(asset.displayName)-\(index).jpg")
            let destination = try #require(CGImageDestinationCreateWithURL(path as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(destination, frame, nil)
            #expect(CGImageDestinationFinalize(destination))
        }
    }
    #expect(try Data(contentsOf: input) == bytes)
}
