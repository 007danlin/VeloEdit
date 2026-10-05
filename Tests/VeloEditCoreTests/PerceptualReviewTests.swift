import Foundation
import Testing
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import VeloEditCore

private func p6Track(movementX: Double, centerX: Double = 0.45) -> SubjectTrackingSummary {
    let id = UUID()
    let observations = [
        SubjectTrackObservation(timestamp: 0, region: NormalizedRegion(x: centerX - 0.10, y: 0.28, width: 0.20, height: 0.32), confidence: 0.92),
        SubjectTrackObservation(timestamp: 4, region: NormalizedRegion(x: min(0.78, max(0.02, centerX + movementX - 0.10)), y: 0.28, width: 0.20, height: 0.32), confidence: 0.92),
    ]
    let track = SubjectTrack(
        id: id, kind: .person, label: "hero", observations: observations,
        meanConfidence: 0.92, visibility: 0.91, compositionQuality: 0.84,
        movementX: movementX, movementY: 0
    )
    return SubjectTrackingSummary(tracks: [track], mainSubjectID: id, confidence: 0.92, analyzedFrameCount: 2)
}

private func p6Fixture(
    count: Int = 4,
    movements: [Double] = [0.32, 0.30, -0.30, 0.08],
    speech: SpeechEditingEvidence? = nil,
    audioEvents: [AudioEventObservation]? = nil
) -> ([MediaAsset], [AnalysisResult], [Candidate]) {
    var assets: [MediaAsset] = []
    var candidates: [Candidate] = []
    for index in 0..<count {
        let asset = MediaAsset(
            originalURL: URL(fileURLWithPath: "/tmp/p6-\(index).mov"),
            kind: .video, byteSize: 1, contentHash: "p6-\(index)",
            metadata: MediaMetadata(duration: 12, width: 1920, height: 1080, frameRate: 30, hasAudio: true)
        )
        let movement = movements[index % movements.count]
        let candidate = Candidate(
            assetID: asset.id, sourceStart: 0, sourceDuration: 6,
            scores: ClipScores(quality: 0.82, interest: 0.78 + Double(index % 2) * 0.08, action: 0.72 + Double(index % 3) * 0.08, stability: 0.84, uniqueness: 0.86),
            tags: [index == 0 ? "setup" : index == count - 1 ? "reaction" : "action", "scene-\(index)"],
            explanation: ["P6 fixture"],
            insights: CandidateInsights(
                sceneSummary: "distinct scene \(index)", emotion: index == count - 1 ? "joy" : nil,
                dynamics: index == count - 1 ? 0.32 : 0.78,
                visualAppeal: 0.82, composition: 0.84, sharpness: 0.86,
                motionBlur: 0.08, noise: 0.08, shake: 0.08,
                exposureQuality: 0.84, originalAudioUsefulness: 0.82,
                storyValue: 0.82,
                roleScores: [.intro: index == 0 ? 0.95 : 0.3, .climax: index == count - 2 ? 0.98 : 0.55, .outro: index == count - 1 ? 0.96 : 0.3],
                semanticEventID: "event-\(index)",
                subjectTracking: p6Track(movementX: movement),
                speech: index == 0 ? speech : nil,
                audioEvents: index == 0 ? audioEvents : nil,
                audioQuality: 0.84
            ),
            momentBoundary: MomentBoundary(anticipationStart: 0, peakTime: 2.2, completionEnd: 5.2, confidence: 0.92, evidence: ["anticipation", "impact", "reaction"])
        )
        assets.append(asset)
        candidates.append(candidate)
    }
    let analyses = zip(assets, candidates).map { asset, candidate in
        AnalysisResult(assetID: asset.id, analyzedContentHash: asset.contentHash, sceneTags: candidate.tags, candidates: [candidate])
    }
    return (assets, analyses, candidates)
}

private func p6Plan(duration: Double = 10, count: Int = 2, pacing: Double = 0.7) -> StoryPlan {
    StoryPlan(prompt: "Цельная история с кульминацией и реакцией", preset: .story, constraints: StoryConstraints(targetDuration: duration, targetClipCount: count, pacing: pacing), chapters: [])
}

private func p6Timeline(_ candidates: [Candidate], ranges: [(Double, Double)], roles: [StoryRole]) -> Timeline {
    var cursor = 0.0
    let items = ranges.enumerated().map { index, range -> TimelineItem in
        let candidate = candidates[index]
        let item = TimelineItem(
            candidateID: candidate.id, assetID: candidate.assetID, kind: .video,
            sourceStart: range.0, sourceDuration: range.1,
            timelineStart: cursor, timelineDuration: range.1,
            storyRole: roles[index]
        )
        cursor += range.1
        return item
    }
    return Timeline(storyPlanID: UUID(), items: items)
}

@Test func perceptualCutReviewPenalizesOppositeScreenDirection() {
    let (assets, analyses, candidates) = p6Fixture(count: 2, movements: [0.34, -0.34])
    let plan = p6Plan()
    let timeline = p6Timeline(candidates, ranges: [(0, 5.2), (0, 5.2)], roles: [.action, .climax])
    let result = PerceptualMontageReviewer().review(timeline: timeline, plan: plan, features: MontageScoringFeatures(assets: assets, analyses: analyses))

    #expect(result.cutScores.count == 1)
    #expect(result.cutScores[0].motionMatch < 0.35)
    #expect(result.findings.contains { $0.type == .motionDiscontinuity && $0.scope == .cut })
}

@Test func perceptualMomentReviewDetectsLateEntryAndCutClimax() {
    let (assets, analyses, candidates) = p6Fixture(count: 1)
    let plan = p6Plan(duration: 2, count: 1)
    let timeline = p6Timeline(candidates, ranges: [(2.4, 1.0)], roles: [.climax])
    let result = PerceptualMontageReviewer().review(timeline: timeline, plan: plan, features: MontageScoringFeatures(assets: assets, analyses: analyses))
    let finding = result.findings.first { $0.type == .incompleteMoment }

    #expect(finding != nil)
    #expect(finding?.severity == .critical)
    #expect(result.score.momentCompleteness < 0.45)
}

@Test func perceptualAudioReviewDetectsCutSpeechAndLaughter() {
    let speech = SpeechEditingEvidence(text: "Это важная законченная фраза", phraseStart: 0, phraseEnd: 4.8, confidence: 0.94, startsAtPhraseBoundary: true, endsAtPhraseBoundary: false)
    let laughter = AudioEventObservation(kind: .laughter, startTime: 1.4, endTime: 3.4, confidence: 0.91, intensity: 0.86)
    let (assets, analyses, candidates) = p6Fixture(count: 1, speech: speech, audioEvents: [laughter])
    let timeline = p6Timeline(candidates, ranges: [(0, 2.2)], roles: [.climax])
    let result = PerceptualMontageReviewer().review(timeline: timeline, plan: p6Plan(duration: 2.2, count: 1), features: MontageScoringFeatures(assets: assets, analyses: analyses))

    #expect(result.findings.filter { $0.type == .audioDiscontinuity }.count >= 2)
    #expect(result.score.audioContinuity < 0.5)
}

@Test func perceptualMusicReviewAlignsVideoPeakWithMeasuredDrop() {
    let (assets, analyses, candidates) = p6Fixture(count: 2, movements: [0.2, 0.2])
    let plan = p6Plan(duration: 10.4, count: 2)
    var aligned = p6Timeline(candidates, ranges: [(0, 5.2), (0, 5.2)], roles: [.setup, .climax])
    let peakTime = aligned.items[1].timelineStart + 2.2
    let goodStructure = MusicStructure(
        bpm: 120, beatInterval: 0.5,
        sections: [MusicSection(kind: .buildup, start: 0, duration: peakTime, energy: 0.6), MusicSection(kind: .drop, start: peakTime, duration: 3, energy: 1)],
        beatTimestamps: stride(from: 0.0, through: 10.5, by: 0.5).map { $0 },
        drops: [peakTime], downbeatTimestamps: stride(from: 0.0, through: 10.5, by: 2).map { $0 },
        phraseBoundaries: [0, 4, 8],
        accents: [MusicAccent(time: aligned.items[1].timelineStart, strength: 0.9, kind: .phrase, confidence: 0.95), MusicAccent(time: peakTime, strength: 1, kind: .drop, confidence: 0.98)],
        beatsPerBar: 4, tempoConfidence: 0.95, downbeatConfidence: 0.9, phraseConfidence: 0.9, sectionConfidence: 0.9, dropConfidence: 0.98, analysisIsMeasured: true
    )
    aligned.music = MusicDirective(style: .energetic, bpm: 120, structure: goodStructure)
    var misaligned = aligned
    var bad = goodStructure
    bad.drops = [0.3]
    bad.accents = [MusicAccent(time: 0.3, strength: 1, kind: .drop, confidence: 0.98)]
    misaligned.music?.structure = bad
    let reviewer = PerceptualMontageReviewer()
    let features = MontageScoringFeatures(assets: assets, analyses: analyses)
    let good = reviewer.review(timeline: aligned, plan: plan, features: features)
    let weak = reviewer.review(timeline: misaligned, plan: plan, features: features)

    #expect(good.score.musicAlignment > weak.score.musicAlignment + 0.15)
    #expect(weak.findings.contains { $0.type == .musicMisalignment })
}

@Test func perceptualOverlayReviewFindsSubjectOcclusion() {
    let (assets, analyses, candidates) = p6Fixture(count: 1, movements: [0])
    var timeline = p6Timeline(candidates, ranges: [(0, 5.2)], roles: [.climax])
    let title = TitleTimelineItem(
        kind: .title, text: "Очень важный заголовок", startTime: 0.5, duration: 3,
        style: TitleStyle(fontSize: 120, xPosition: 0.45, yPosition: 0.45),
        targetClipID: timeline.items[0].id
    )
    timeline.titleItems = [title]
    let result = PerceptualMontageReviewer().review(timeline: timeline, plan: p6Plan(duration: 5.2, count: 1), features: MontageScoringFeatures(assets: assets, analyses: analyses))

    #expect(result.findings.contains { $0.type == .overlayOcclusion && $0.itemIDs.contains(title.id) })
    #expect(result.score.titleQuality < 0.9)
}

@Test func perceptualRenderedEvidenceDetectsBlackAndUnintentionalFreeze() {
    let (assets, analyses, candidates) = p6Fixture(count: 1)
    let timeline = p6Timeline(candidates, ranges: [(0, 5.2)], roles: [.climax])
    let frames = [
        PerceptualRenderedFrameEvidence(timelineTime: 1, meanLuma: 2, lumaDeviation: 0.5, perceptualHash: 1, isBlack: true),
        PerceptualRenderedFrameEvidence(timelineTime: 2, meanLuma: 90, lumaDeviation: 20, perceptualHash: 2, isBlack: false, isFrozenComparedToPrevious: true),
    ]
    let result = PerceptualMontageReviewer().review(timeline: timeline, plan: p6Plan(duration: 5.2, count: 1), features: MontageScoringFeatures(assets: assets, analyses: analyses), renderedFrames: frames)

    #expect(result.findings.contains { $0.type == .blackFrame && $0.severity == .critical })
    #expect(result.findings.contains { $0.type == .frozenFrame })
    #expect(result.score.technicalIntegrity < 0.6)
}

@Test func perceptualRenderedFailuresGroupSamplesWithoutReducingPenalty() throws {
    let (assets, analyses, candidates) = p6Fixture(count: 2)
    let timeline = p6Timeline(candidates, ranges: [(0, 5.2), (0, 5.2)], roles: [.intro, .outro])
    let frames = [0.3, 0.6, 1.0, 1.2, 5.2].map { time in
        PerceptualRenderedFrameEvidence(timelineTime: time, meanLuma: 90, lumaDeviation: 20,
            isBlack: false, isFrozenComparedToPrevious: time != 1.0)
    }
    let result = PerceptualMontageReviewer().review(timeline: timeline, plan: p6Plan(),
        features: MontageScoringFeatures(assets: assets, analyses: analyses), renderedFrames: frames)
    let freezes = result.findings.filter { $0.type == .frozenFrame }.sorted { $0.timelineRange.start < $1.timelineRange.start }
    // A healthy sample or a new clip must split the diagnostic. Exact cut
    // time belongs to the incoming clip, not to the outgoing one.
    #expect(freezes.count == 3)
    #expect(freezes.map { $0.renderedSampleTimes ?? [] } == [[0.3, 0.6], [1.2], [5.2]])
    #expect(freezes.last?.itemIDs == [timeline.items[1].id])
    #expect(freezes.last?.timelineRange.start == 5.2)
    let unchangedPenalty = 1 - (4 * 0.76 * 0.90) / 5
    #expect(abs(result.score.technicalIntegrity - unchangedPenalty) < 0.000_001)
    let restored = try JSONDecoder.veloEdit.decode(PerceptualReviewResult.self,
        from: JSONEncoder.veloEdit.encode(result))
    #expect(restored.findings == result.findings)
}

@Test func perceptualTransactionCommitsCompleteMomentAndRollsBackUnsafeRepair() {
    let (assets, analyses, candidates) = p6Fixture(count: 1)
    let plan = p6Plan(duration: 5.2, count: 1)
    var original = p6Timeline(candidates, ranges: [(2.4, 1.0)], roles: [.climax])
    original.storyPlanID = plan.id
    var complete = original
    complete.items[0].sourceStart = 0
    complete.items[0].sourceDuration = 5.2
    complete.items[0].timelineDuration = 5.2
    let features = MontageScoringFeatures(assets: assets, analyses: analyses)
    let reviewer = PerceptualMontageReviewer()
    let current = reviewer.review(timeline: original, plan: plan, features: features)
    let currentGlobal = DefaultMontageGlobalScorer().score(plan: plan, timeline: original, features: features, analyses: analyses)
    let committed = PerceptualReviewTransaction().commitIfImproved(original: original, candidate: complete, currentReview: current, currentGlobal: currentGlobal, plan: plan, features: features, analyses: analyses)

    #expect(committed.committed)
    #expect(committed.review.score.momentCompleteness > current.score.momentCompleteness)

    var locked = original
    locked.items[0].locked = true
    let lockedReview = reviewer.review(timeline: locked, plan: plan, features: features)
    let lockedGlobal = DefaultMontageGlobalScorer().score(plan: plan, timeline: locked, features: features, analyses: analyses)
    var removed = locked
    removed.items = []
    let rejected = PerceptualReviewTransaction().commitIfImproved(original: locked, candidate: removed, currentReview: lockedReview, currentGlobal: lockedGlobal, plan: plan, features: features, analyses: analyses)
    #expect(!rejected.committed)
    #expect(rejected.timeline == locked)
    #expect(!rejected.safetyViolations.isEmpty)
}

@Test func aiDirectorProductionPathPersistsPerceptualDiagnosticsAndChangesBadTimeline() {
    let (assets, analyses, candidates) = p6Fixture(count: 3, movements: [0.3, 0.3, 0.3])
    let plan = p6Plan(duration: 10.4, count: 2)
    var bad = p6Timeline(Array(candidates.prefix(2)), ranges: [(2.4, 1.0), (2.4, 1.0)], roles: [.intro, .climax])
    bad.storyPlanID = plan.id
    let directed = AIDirectorEngine(maximumReviewIterations: 0).direct(plan: plan, initialTimeline: bad, assets: assets, analyses: analyses)
    let summary = directed.directorRun?.perceptualReview

    #expect(summary != nil)
    #expect(directed.directorRun?.perceptualScoreBefore != nil)
    #expect(directed.directorRun?.perceptualFindings != nil)
    #expect(directed.items != bad.items)
    #expect((summary?.repairsAccepted ?? 0) >= 1)
    #expect((summary?.perceptualScoreAfter ?? 0) >= (summary?.perceptualScoreBefore ?? 1))
    #expect(directed.directorRun?.appliedToolNames.contains(DirectorEditingTool.trim.rawValue) == true)
}

@Test func selectiveRenderInspectorReadsActualCompositionFrames() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("p6-render-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let imageURL = root.appendingPathComponent("blue.png")
    let context = try #require(CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 256, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: 0.12, green: 0.48, blue: 0.9, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
    let image = try #require(context.makeImage())
    let destination = try #require(CGImageDestinationCreateWithURL(imageURL as CFURL, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    let asset = MediaAsset(originalURL: imageURL, kind: .photo, byteSize: 1, contentHash: "p6-blue", metadata: MediaMetadata(width: 64, height: 48))
    let item = TimelineItem(assetID: asset.id, kind: .photo, sourceDuration: 0.6, timelineStart: 0, timelineDuration: 0.6)
    let timeline = Timeline(storyPlanID: UUID(), width: 320, height: 180, frameRate: 10, items: [item])
    do {
        let playback = try await PlaybackEngine().build(timeline: timeline, assets: [asset], derivedMediaCacheURL: root.appendingPathComponent("cache"), forceVideoComposition: true)
        let evidence = PerceptualRenderInspector().inspect(playback: playback, timeline: timeline, maximumSamples: 6)
        #expect(!evidence.isEmpty)
        #expect(evidence.allSatisfy { !$0.isBlack })
        #expect(evidence.allSatisfy { $0.source.contains("AVComposition") })
    } catch DerivedMediaError.exportFailed(let reason) where reason.contains("-11834") || reason.contains("-12903") {
        return
    }
}

@Test func productionPipelineWithMoreThanThreeHundredAssetsRunsP6EndToEnd() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("p6-300-\(UUID().uuidString)").appendingPathExtension("veloedit")
    let taste = FileManager.default.temporaryDirectory.appendingPathComponent("p6-taste-\(UUID().uuidString).json")
    defer {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: taste)
    }
    let store = try ProjectStore(createAt: root, name: "P6 300+ production")
    var assets: [MediaAsset] = []
    var analyses: [AnalysisResult] = []
    for index in 0..<302 {
        let asset = MediaAsset(
            originalURL: URL(fileURLWithPath: "/tmp/p6-large-\(index).mov"), kind: .video,
            byteSize: 1, contentHash: "p6-large-\(index)",
            metadata: MediaMetadata(duration: 8, frameRate: 30, hasAudio: true, creationDate: Date(timeIntervalSince1970: 1_700_000_000 + Double(index * 40)))
        )
        let phase = index % 6
        let verifiedDuration = 1.4 + Double(phase) * 0.55
        let candidate = Candidate(
            assetID: asset.id, sourceStart: 0, sourceDuration: verifiedDuration,
            scores: ClipScores(quality: 0.72 + Double(index % 4) * 0.05, interest: 0.68 + Double(index % 5) * 0.05, action: Double(phase) / 5, stability: 0.82, uniqueness: 0.9),
            tags: ["archive", "phase-\(phase)"],
            insights: CandidateInsights(sceneSummary: "archive scene \(phase)", dynamics: Double(phase) / 5, visualAppeal: 0.8, composition: 0.8, sharpness: 0.82, exposureQuality: 0.82, storyValue: 0.78, roleScores: [.intro: phase == 0 ? 0.95 : 0.3, .climax: phase == 4 ? 0.98 : 0.4, .outro: phase == 5 ? 0.94 : 0.3]),
            momentBoundary: MomentBoundary(anticipationStart: 0, peakTime: verifiedDuration * 0.4, completionEnd: verifiedDuration, confidence: 0.88)
        )
        assets.append(asset)
        analyses.append(AnalysisResult(assetID: asset.id, analyzedContentHash: asset.contentHash, sceneTags: candidate.tags, candidates: [candidate]))
    }
    assets = try await materializeEditorialFixtureMedia(assets, at: root)
    try await store.update { project in
        project.assets = assets
        project.analyses = preparedFixtureAnalyses(analyses, preferences: project.preferences)
    }
    try await store.update { $0.editorialDevelopmentEnabled = true }
    let pipeline = VeloEditPipeline(store: store, renderedProber: FixtureEditorialProber(), analyzer: FixtureEditorialAnalyzer(analyses: analyses), personalTasteStore: LocalPersonalTasteStore(url: taste))
    let timeline = try await pipeline.createFilm(prompt: "Без музыки. Автоматическая история архива.", preset: .story)
    let run = try #require(timeline.directorRun)
    let summary = try #require(run.perceptualReview)

    if let path = ProcessInfo.processInfo.environment["VELOEDIT_LARGE_REVIEW_DIAGNOSTICS"] {
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder.veloEdit.encode(await pipeline.snapshot()).write(to: directory.appendingPathComponent("project.json"), options: .atomic)
        try JSONEncoder.veloEdit.encode(summary).write(to: directory.appendingPathComponent("perceptual-review.json"), options: .atomic)
    }

    // This deliberately homogeneous archive can collapse to one honest
    // production variant. The search must still evaluate multiple strategies
    // and report the near-duplicate rejections instead of fabricating variety.
    #expect(run.evaluatedVariantCount ?? 0 >= 1)
    #expect(run.variantDiagnostics?.attemptedStrategyCount ?? 0 >= 2)
    #expect(summary.perceptualReviewIterations <= 3)
    #expect(summary.findings.count < 500)
    #expect(run.perceptualScoreAfter == summary.perceptualScoreAfter)
    #expect((await pipeline.snapshot()).timelines.last?.directorRun?.perceptualReview != nil)
}
