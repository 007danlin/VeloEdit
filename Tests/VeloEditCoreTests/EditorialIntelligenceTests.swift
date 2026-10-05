import Foundation
import Testing
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import AVFoundation
@testable import VeloEditCore

private func eiCandidate(assetID: UUID = UUID(), setup: String, start: Double = 0, duration: Double = 8, quality: Double = 0.9, progression: Bool = false) -> Candidate {
    var insight = CandidateInsights(sceneSummary: setup, dynamics: 0.8, sharpness: quality, exposureQuality: quality)
    let states: [EditorialTemporalSample] = (0..<12).map { index in
        .init(sourceTime: start + duration * Double(index) / 11, subjectKinds: [.person], actionState: [progression ? "\(setup)-phase-\(index / 4)" : setup], quality: quality, confidence: 0.95)
    }
    insight.editorialEvidence = EditorialEvidence(samples: states, usableRange: .init(start: start, end: start + duration), actionDelta: progression ? 0.7 : 0, informationGain: progression ? 0.8 : 0.05, completion: progression ? 0.85 : 0, entryQuality: quality, exitQuality: quality, unchangedSeconds: progression ? 0 : duration, cameraMount: .bodyPOV, shotScale: .wide, background: setup, confidence: 0.95, provenance: ["deterministic fixture"])
    return Candidate(assetID: assetID, sourceStart: start, sourceDuration: duration, scores: ClipScores(quality: quality, interest: quality, action: progression ? 0.8 : 0.1, stability: 0.9, uniqueness: 0.8), tags: [setup], insights: insight)
}

private func eiAnalysis(_ candidates: [Candidate]) -> [AnalysisResult] {
    Dictionary(grouping: candidates, by: \.assetID).map { id, values in
        AnalysisResult(assetID: id, schemaVersion: 1, analyzedContentHash: "fixture", sceneTags: [], candidates: values, warnings: [])
    }.sorted { $0.assetID.uuidString < $1.assetID.uuidString }
}

private func eiPlan(duration: Double = 300, mute: Bool = false) -> StoryPlan {
    StoryPlan(prompt: "Фильм ровно \(Int(duration)) секунд", preset: .story, constraints: StoryConstraints(targetDuration: duration, pacing: 0.45), chapters: [], directorBrief: DirectorBrief(requestedDuration: duration, musicPolicy: .none, sourceAudioPolicy: mute ? .mute : .preserve, titlePolicy: .none))
}

private struct EIMinerAnalyzer: EditorialEvidenceAnalyzing {
    func analyze(candidate: Candidate, asset: MediaAsset) async throws -> EditorialEvidence {
        EditorialEvidence(
            samples: [
                .init(sourceTime: candidate.sourceStart, actionState: ["start"], quality: 0.9, confidence: 0.9),
                .init(sourceTime: candidate.sourceStart + candidate.sourceDuration, actionState: ["finish"], quality: 0.9, confidence: 0.9)
            ],
            usableRange: .init(start: candidate.sourceStart, end: candidate.sourceStart + candidate.sourceDuration),
            actionDelta: 0.7,
            visualDelta: 0.7,
            informationGain: 0.8,
            completion: 0.9,
            entryQuality: 0.9,
            exitQuality: 0.9,
            atmosphereValue: 0.8,
            cameraMount: .bodyPOV,
            shotScale: .wide,
            confidence: 0.9,
            provenance: ["miner fixture"]
        )
    }
}

private struct EIFailingMinerAnalyzer: EditorialEvidenceAnalyzing {
    func analyze(candidate: Candidate, asset: MediaAsset) async throws -> EditorialEvidence {
        throw CocoaError(.fileReadCorruptFile)
    }
}

@Test func editorialBudgetNeverCountsFullSourceMetadata() {
    let candidates = (0..<4).map { eiCandidate(setup: "same fishing setup", start: Double($0) * 100, duration: 80) }
    let context = EditorialAnalysisContext(analyses: eiAnalysis(candidates))
    let decision = ContentBudgetEngine().budget(units: context.units, families: context.families, requestedDuration: 300, requestIsExplicit: true, style: DirectorStyleVector())
    #expect(decision.supportedDuration < 8)
    #expect(decision.durationConstraintStatus == .compromisedInsufficientContent)
    #expect(decision.budget.strongUnitCount == 1)
}

@Test func editorialBudgetUsesTenSecondMinimumWithoutInventingCapacity() {
    let enough = EditorialAnalysisContext(analyses: eiAnalysis([
        eiCandidate(setup: "one", duration: 8, progression: true),
        eiCandidate(setup: "two", duration: 8, progression: true)
    ]))
    let budget = ContentBudgetEngine().budget(units: enough.units, families: enough.families,
        requestedDuration: 3, requestIsExplicit: true, style: DirectorStyleVector())
    #expect(budget.requestedDuration == 10)
    #expect(budget.budget.idealDuration >= 10)
    #expect(budget.budget.safeRange.lowerBound >= 10)
    let automatic = ContentBudgetEngine().budget(units: enough.units, families: enough.families,
        requestedDuration: nil, requestIsExplicit: false, style: DirectorStyleVector())
    #expect(automatic.budget.idealDuration >= 10)
    #expect(automatic.feasibility == 1)
    let sparse = EditorialAnalysisContext(analyses: eiAnalysis([eiCandidate(setup: "only", duration: 4, progression: true)]))
    let insufficient = ContentBudgetEngine().budget(units: sparse.units, families: sparse.families,
        requestedDuration: nil, requestIsExplicit: false, style: DirectorStyleVector())
    #expect(insufficient.supportedDuration <= 4)
    #expect(insufficient.budget.absoluteCeiling <= 4)
    #expect(insufficient.durationConstraintStatus == .compromisedInsufficientContent)
    #expect(insufficient.requiresExpandedMining)
}

@Test func editorialBudgetCountsVisuallyChangingJourneyOnOneCameraMount() {
    let assetID = UUID()
    let candidates = (0..<30).map { index -> Candidate in
        var candidate = eiCandidate(
            assetID: assetID,
            setup: "journey-place-\(index)",
            start: Double(index) * 15,
            duration: 10
        )
        candidate.insights?.editorialEvidence?.informationGain = 0.45
        candidate.insights?.editorialEvidence?.atmosphereValue = 0.8
        return candidate
    }
    let units = candidates.map { EditorialUnit(candidate: $0) }
    let family = ShotFamily(
        id: "single-mounted-camera",
        unitIDs: units.map(\.id),
        representativeID: units[0].id
    )
    let decision = ContentBudgetEngine().budget(
        units: units,
        families: ShotFamilyIndex(families: [family]),
        requestedDuration: 180,
        requestIsExplicit: true,
        style: DirectorStyleVector()
    )
    #expect(decision.supportedDuration >= 180)
    #expect(decision.durationConstraintStatus == .satisfied)
}

@Test func editorialMinerUsesQualityWindowsEvenWhenBoundaryConfidenceIsOrdinary() async throws {
    let assetID = UUID()
    let original = eiCandidate(assetID: assetID, setup: "opening", duration: 4, progression: true)
    let analysis = AnalysisResult(
        assetID: assetID,
        analyzedContentHash: "fixture",
        candidates: [original],
        scenes: [
            SceneAnalysis(startTime: 0, endTime: 30, qualityScore: 0.85, boundaryConfidence: 1),
            SceneAnalysis(startTime: 30, endTime: 90, qualityScore: 0.85, boundaryConfidence: 0.35)
        ]
    )
    let asset = MediaAsset(
        id: assetID,
        originalURL: URL(fileURLWithPath: "/tmp/miner-fixture.mov"),
        kind: .video,
        byteSize: 0,
        contentHash: "fixture",
        metadata: MediaMetadata(duration: 90)
    )
    let expanded = try await EditorialCandidateMiner().expandIfNeeded(
        analyses: [analysis],
        assets: [asset],
        requestedDuration: 60,
        force: true,
        analyzer: EIMinerAnalyzer()
    )
    #expect(expanded[0].candidates.contains { $0.sourceStart >= 30 })
    #expect(expanded[0].warnings.contains(EditorialCandidateMiner.completionMarker))
}

@Test func editorialMinerProductionizesLegacyAnalysesExactlyOnce() {
    var legacy = AnalysisResult(assetID: UUID(), analyzedContentHash: "legacy", candidates: [])
    #expect(EditorialCandidateMiner.requiresProductionization([legacy]))
    legacy.warnings.append(EditorialCandidateMiner.completionMarker)
    #expect(!EditorialCandidateMiner.requiresProductionization([legacy]))
}

@Test func editorialMinerInspectsTheTailBeforeMarkingALongSourceComplete() async throws {
    let asset = MediaAsset(originalURL: URL(fileURLWithPath: "/tmp/long-mining-fixture.mov"), kind: .video, byteSize: 0, contentHash: "long-fixture", metadata: MediaMetadata(duration: 600))
    let original = eiCandidate(assetID: asset.id, setup: "opening", duration: 4, progression: true)
    let analysis = AnalysisResult(assetID: asset.id, analyzedContentHash: asset.contentHash, candidates: [original], warnings: ["editorial-expanded-mining-v4-complete"], scenes: [SceneAnalysis(startTime: 0, endTime: 600, qualityScore: 0.85, boundaryConfidence: 0.35)])
    let recorder = FilmBuildProgressRecorder()
    let expanded = try await FilmBuildReporting.$handler.withValue({ await recorder.record($0) }) {
        try await EditorialCandidateMiner().expandIfNeeded(analyses: [analysis], assets: [asset], requestedDuration: 12, force: true, analyzer: EIMinerAnalyzer())
    }
    #expect(expanded[0].candidates.contains { $0.sourceStart >= 580 })
    #expect(expanded[0].warnings.contains(EditorialCandidateMiner.completionMarker))
    let final = await recorder.updates.last
    #expect((final?.total ?? 0) > 24)
    #expect(final?.completed == final?.total)
}

@Test func editorialMinerDoesNotTreatOneCompletedSourceAsACompleteArchive() {
    let candidates = [eiCandidate(setup: "first"), eiCandidate(setup: "second")]
    var analyses = eiAnalysis(candidates)
    analyses[0].warnings.append(EditorialCandidateMiner.completionMarker)
    #expect(!EditorialAnalysisContext(analyses: analyses).expandedMiningPerformed)
}

@Test func editorialMinerDoesNotMarkFailedSourceAsComplete() async throws {
    let assetID = UUID()
    let analysis = AnalysisResult(
        assetID: assetID,
        analyzedContentHash: "fixture",
        candidates: [eiCandidate(assetID: assetID, setup: "opening", duration: 2)],
        scenes: [SceneAnalysis(startTime: 0, endTime: 60, qualityScore: 0.85, boundaryConfidence: 0.35)]
    )
    let asset = MediaAsset(
        id: assetID,
        originalURL: URL(fileURLWithPath: "/tmp/unreadable.mov"),
        kind: .video,
        byteSize: 0,
        contentHash: "fixture",
        metadata: MediaMetadata(duration: 60)
    )
    let expanded = try await EditorialCandidateMiner().expandIfNeeded(
        analyses: [analysis],
        assets: [asset],
        requestedDuration: 60,
        force: true,
        analyzer: EIFailingMinerAnalyzer()
    )
    #expect(!expanded[0].warnings.contains(EditorialCandidateMiner.completionMarker))
    #expect(expanded[0].warnings.contains { $0.contains("Expanded editorial mining") })
}

@Test func editorialFamiliesIgnoreAssetIDAndSeparateReaction() {
    let a = eiCandidate(setup: "cycling behind rider")
    let b = eiCandidate(setup: "cycling behind rider")
    var reaction = eiCandidate(setup: "friend laughing close reaction", progression: true)
    reaction.insights?.editorialEvidence?.shotScale = .close
    let context = EditorialAnalysisContext(analyses: eiAnalysis([a, b, reaction]))
    #expect(context.families.familyByUnitID[a.id] == context.families.familyByUnitID[b.id])
    #expect(context.families.familyByUnitID[a.id] != context.families.familyByUnitID[reaction.id])
}

@Test func editorialHardOverlapThresholdAndRepeatedStartAreEnforced() {
    let id = UUID()
    let a = EditorialUnit(candidate: eiCandidate(assetID: id, setup: "a", start: 10, duration: 10))
    let overlap = EditorialUnit(candidate: eiCandidate(assetID: id, setup: "b", start: 18, duration: 10))
    let sameStart = EditorialUnit(candidate: eiCandidate(assetID: id, setup: "c", start: 10.04, duration: 2))
    #expect(ShotFamilyClusterer().isHardDuplicate(a, overlap))
    #expect(ShotFamilyClusterer().isHardDuplicate(a, sameStart))
}

@Test func editorialLabelsCannotInventClimaxAndEmptyFilmCannotWin() {
    let candidates = [eiCandidate(setup: "quiet river"), eiCandidate(setup: "tree canopy")]
    let context = EditorialAnalysisContext(analyses: eiAnalysis(candidates))
    let plan = EditorialStoryPlanner.applying(to: eiPlan(), context: context)
    #expect(plan.narrativeBeatPlan?.pattern == .minimalMontage)
    #expect(plan.chapters.allSatisfy { $0.role != .climax })
    let empty = Timeline(storyPlanID: plan.id, items: [])
    #expect(!EditorialQualityGate().review(timeline: empty, plan: plan, analyses: eiAnalysis(candidates)).hardGatePassed)
}

@Test func editorialMechanicalCadenceDetectsThirtyOneOfThirtyThree() {
    let candidates = (0..<33).map { eiCandidate(setup: "setup-\($0)", duration: 5, progression: true) }
    let items = candidates.enumerated().map { index, candidate in
        TimelineItem(candidateID: candidate.id, assetID: candidate.assetID, kind: .video, sourceDuration: 5, timelineStart: Double(index) * 5, timelineDuration: index < 31 ? 5 : 4.4)
    }
    let review = EditorialQualityGate().review(timeline: Timeline(storyPlanID: UUID(), items: items), plan: eiPlan(), analyses: eiAnalysis(candidates))
    #expect(review.findings.contains { $0.kind == .mechanicalCadence })
}

@Test func editorialMuteRemovesDetachedAndSurvivesDirector() {
    let c = eiCandidate(setup: "speech", duration: 4)
    let asset = MediaAsset(id: c.assetID, originalURL: URL(fileURLWithPath: "/tmp/fixture.mov"), kind: .video, byteSize: 0, contentHash: "fixture", metadata: MediaMetadata(duration: 4, hasAudio: true))
    let item = TimelineItem(candidateID: c.id, assetID: c.assetID, kind: .video, sourceDuration: 4, timelineStart: 0, timelineDuration: 4)
    let audio = TimelineAudioClip(assetID: c.assetID, title: "detached", role: .detached, sourceDuration: 4, timelineStart: 0, timelineDuration: 4)
    let source = Timeline(storyPlanID: UUID(), items: [item], audioClips: [audio])
    let timeline = AIDirectorEngine().direct(plan: eiPlan(mute: true), initialTimeline: source, assets: [asset], analyses: eiAnalysis([c]))
    #expect(timeline.effectiveOriginalAudioVolume == 0)
    #expect(timeline.effectiveAudioClips.isEmpty)
    #expect(timeline.items.allSatisfy { $0.effectiveAudioAdjustments.muted })
}

@Test func editorialExactDurationIsNotFundedByEmptySourceHandles() {
    let candidates = (0..<4).map { eiCandidate(setup: "different-scene-\($0)", duration: 10, progression: true) }
    let analyses = eiAnalysis(candidates)
    let context = EditorialAnalysisContext(analyses: analyses)
    let plan = EditorialStoryPlanner.applying(to: eiPlan(), context: context)
    #expect(plan.contentBudget?.durationConstraintStatus == .compromisedInsufficientContent)
    #expect(plan.requiresExactDuration)
    let assets = candidates.map { MediaAsset(id: $0.assetID, originalURL: URL(fileURLWithPath: "/tmp/source"), kind: .video, byteSize: 0, contentHash: "fixture", metadata: MediaMetadata(duration: 600)) }
    let timeline = TimelineComposer().compose(plan: plan, assets: assets, analyses: analyses)
    #expect(timeline.duration <= 40.01)
    #expect(timeline.items.allSatisfy { $0.sourceDuration <= 10.01 })
}

@Test func editorialBudgetRequestsSecondMiningOnlyNearFeasibleTarget() {
    let units = [EditorialUnit(candidate: eiCandidate(setup: "action", duration: 9, progression: true))]
    let decision = ContentBudgetEngine().budget(units: units, families: ShotFamilyClusterer().cluster(units: units), requestedDuration: 10, requestIsExplicit: true, style: DirectorStyleVector())
    #expect(decision.requiresExpandedMining)
    #expect(decision.feasibility == 0.9)
}

@Test func editorialSignatureDetectsAudioAndIntermediateCropChanges() {
    var a = Timeline(storyPlanID: UUID(), items: [])
    a.editorialBeatPlan = NarrativeBeatPlan(pattern: .minimalMontage, beats: [], reasons: [])
    let before = EditorialRenderSignature.signature(a)
    a.editorialBeatPlan?.discardedCandidates = [UUID(): .noNarrativeFit]
    #expect(EditorialRenderSignature.signature(a) == before)
    a.originalAudioVolume = 0
    #expect(EditorialRenderSignature.signature(a) != before)
    let baseline = PreviewExportSignature(timeline: a, assets: [])
    a.originalAudioVolume = 1
    #expect(!PreviewExportConsistencyContract.issues(preview: baseline, export: PreviewExportSignature(timeline: a, assets: [])).isEmpty)
}

@Test func editorialGroupFramingPrefersPeopleAndSafeFit() throws {
    func track(_ kind: SubjectKind, x: Double, width: Double) -> SubjectTrack {
        SubjectTrack(kind: kind, label: kind.rawValue, observations: [.init(timestamp: 0, region: .init(x: x, y: 0.2, width: width, height: 0.5), confidence: 0.95)], meanConfidence: 0.95, visibility: 0.95, compositionQuality: 0.9)
    }
    let person = track(.person, x: 0.72, width: 0.1), vehicle = track(.vehicle, x: 0.2, width: 0.5)
    var tracking = SubjectTrackingSummary(tracks: [vehicle, person], mainSubjectID: vehicle.id, confidence: 0.95, analyzedFrameCount: 1)
    let plan = try #require(SubjectAwareReframeEngine().plan(tracking: tracking, sourceAspectRatio: 16.0 / 9, targetAspectRatio: 9.0 / 16))
    #expect(plan.startCenterX > 0.65)
    tracking.tracks.append(track(.person, x: 0.1, width: 0.1))
    #expect(SubjectAwareReframeEngine().plan(tracking: tracking, sourceAspectRatio: 16.0 / 9, targetAspectRatio: 9.0 / 16) == nil)
}

@Test func editorialIntermediateKeyframeFollowsCrossingAndReturns() throws {
    let track = SubjectTrack(kind: .person, label: "person", observations: [0.4, 0.7, 0.4].enumerated().map { .init(timestamp: Double($0.offset) * 3, region: .init(x: $0.element, y: 0.2, width: 0.1, height: 0.5), confidence: 0.95) }, meanConfidence: 0.95, visibility: 0.95, compositionQuality: 0.9)
    let tracking = SubjectTrackingSummary(tracks: [track], mainSubjectID: track.id, confidence: 0.95, analyzedFrameCount: 3)
    let plan = try #require(SubjectAwareReframeEngine().plan(tracking: tracking, sourceAspectRatio: 16.0 / 9, targetAspectRatio: 9.0 / 16))
    #expect(plan.keyframes?.count == 3)
    #expect(plan.interpolated(atSourceTime: 3).centerX > 0.7)
    #expect(abs(plan.startCenterX - plan.endCenterX) < 0.01)
}

@Test func editorialRenderedGateCannotBeClosedByMissingOrFailedProbes() {
    let c = eiCandidate(setup: "quiet river", duration: 3)
    let item = TimelineItem(candidateID: c.id, assetID: c.assetID, kind: .photo, sourceDuration: 3, timelineStart: 0, timelineDuration: 3)
    let timeline = Timeline(storyPlanID: UUID(), items: [item])
    let gate = EditorialQualityGate()
    #expect(!gate.review(timeline: timeline, plan: eiPlan(), analyses: eiAnalysis([c]), requireRenderedEvidence: true).hardGatePassed)
    var failed = PerceptualRenderedFrameEvidence(timelineTime: 1, meanLuma: 0.5, lumaDeviation: 0.1, isBlack: false)
    failed.decodeFailed = true
    #expect(!gate.review(timeline: timeline, plan: eiPlan(), analyses: eiAnalysis([c]), renderedFrames: [failed], requireRenderedEvidence: true).hardGatePassed)
}

@Test func editorialIntentOnlyFulfillsActualNewTitleAndEvaluatesPhoto() {
    let timeline = Timeline(storyPlanID: UUID(), items: [])
    let photoID = UUID()
    #expect(IntentLedgerEngine.validate(.addTitles, timeline: timeline, previous: nil, analyses: [], assets: []).0 != .fulfilled)
    let result = IntentLedgerEngine.validate(.evaluateNewAssets([photoID]), timeline: timeline, previous: nil, analyses: [], assets: [])
    #expect(result.1.first?.assetID == photoID)
    #expect(result.1.first?.reason.hasPrefix("analysisUnavailable:") == true)
}

@Test func editorialCancelledGenerationPersistsRecoverableLedgerAndNoTimeline() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("editorial-ledger-\(UUID()).veloedit")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try ProjectStore(createAt: root, name: "fixture")
    let ids = try await store.beginEditorialGeneration(prompt: "create film", brief: nil)
    try await store.failEditorialGeneration(ids: ids, error: EditorialGenerationError.unsatisfiedIntent("missing evidence"))
    let reopened = try ProjectStore(open: root)
    let manifest = await reopened.manifest
    #expect(manifest.timelines.isEmpty)
    #expect(manifest.intentLedger?.hasRecoverableGeneration == true)
    #expect(ProjectSummary.load(from: root)?.hasPlayableTimeline == false)
}

@Test func editorialNewOptionalFieldsDecodeOldManifests() throws {
    let old = ProjectManifest(name: "legacy")
    let data = try JSONEncoder.veloEdit.encode(old)
    let restored = try JSONDecoder.veloEdit.decode(ProjectManifest.self, from: data)
    #expect(restored.intentLedger == nil)
}

@Test func editorialGeometricCoreCannotHideZeroFraming() {
    #expect(EditorialQualityGate.geometricMean([1, 1, 1, 0, 1]) == 0)
}

private enum EditorialRegressionFixture: String, CaseIterable {
    case RepeatedPOVCyclingFixture, StaticFishingFiveMinuteFixture, BuggyGroupVerticalFixture, MultiDayChapterFixture
    case MutePolicyFixture, CalmStyleEffectFixture, ImpossibleExactDurationFixture, LongSpeechFixture
}

@Test(arguments: EditorialRegressionFixture.allCases)
private func editorialRegressionRunsThroughRenderedWinner(_ fixture: EditorialRegressionFixture) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("editorial-render-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    var candidates: [Candidate] = []
    var assets: [MediaAsset] = []
    for index in 0..<4 {
        let url = root.appendingPathComponent("sample-\(index).png")
        let context = try #require(CGContext(data: nil, width: 160, height: 90, bitsPerComponent: 8, bytesPerRow: 640, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.25 + Double(index) * 0.15, green: 0.5, blue: 0.7, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 160, height: 90))
        context.setFillColor(CGColor(red: 0.9, green: 0.3, blue: 0.15, alpha: 1))
        context.fill(CGRect(x: 135, y: 20, width: 12, height: 45))
        context.setFillColor(CGColor(gray: 0.8, alpha: 1))
        context.fill(CGRect(x: 15, y: 15, width: 15, height: 35))
        let image = try #require(context.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        let asset = MediaAsset(originalURL: url, kind: .photo, byteSize: 1, contentHash: "\(fixture)-\(index)", metadata: MediaMetadata(width: 160, height: 90))
        assets.append(asset)
        var candidate = eiCandidate(assetID: asset.id, setup: ["river fishing", "camp friends", "rider finish", "sunset journey"][index], duration: 3.2 + Double(index) * 0.27, quality: 0.87 + Double(index) * 0.025, progression: fixture == .LongSpeechFixture)
        if fixture == .BuggyGroupVerticalFixture {
            let person = SubjectTrack(kind: .person, label: "person", observations: [.init(timestamp: 0, region: .init(x: 0.83, y: 0.2, width: 0.12, height: 0.5), confidence: 0.95)], meanConfidence: 0.95, visibility: 0.95, compositionQuality: 0.9)
            let other = SubjectTrack(kind: .person, label: "other", observations: [.init(timestamp: 0, region: .init(x: 0.1, y: 0.2, width: 0.1, height: 0.5), confidence: 0.95)], meanConfidence: 0.95, visibility: 0.95, compositionQuality: 0.9)
            candidate.insights?.subjectTracking = SubjectTrackingSummary(tracks: [person, other], mainSubjectID: person.id, confidence: 0.95, analyzedFrameCount: 1)
        }
        if fixture == .LongSpeechFixture && index == 1 {
            candidate.insights?.speech = SpeechEditingEvidence(text: "Complete fixture phrase", phraseStart: 0, phraseEnd: candidate.sourceDuration, confidence: 0.95, startsAtPhraseBoundary: true, endsAtPhraseBoundary: true)
        }
        candidates.append(candidate)
    }
    if [.RepeatedPOVCyclingFixture, .StaticFishingFiveMinuteFixture].contains(fixture) {
        for _ in 1..<12 {
            var repeatCandidate = candidates[0]
            repeatCandidate.id = UUID()
            // The lightweight render fixture uses PNG assets. A still image
            // has no non-zero media time, so model repeated POV setups as
            // interchangeable candidates at its canonical source origin.
            repeatCandidate.sourceStart = 0
            repeatCandidate.sourceDuration = 10
            repeatCandidate.insights?.editorialEvidence?.usableRange = .init(start: 0, end: 10)
            candidates.append(repeatCandidate)
        }
    }
    let analyses = eiAnalysis(candidates)
    var seed = eiPlan(mute: fixture == .MutePolicyFixture)
    if fixture == .BuggyGroupVerticalFixture { seed.directorBrief?.canvasFormat = .portrait9x16 }
    var events: [Event] = []
    if fixture == .MultiDayChapterFixture {
        seed.directorBrief?.titlePolicy = .minimal
        for day in 0..<2 {
            let slice = Array(candidates[(day * 2)..<(day * 2 + 2)])
            let scene = EventScene(title: day == 0 ? "Рыбалка" : "Велопрогулка", assetIDs: slice.map(\.assetID), candidateIDs: slice.map(\.id), phase: .setup, confidence: 0.95)
            events.append(Event(title: scene.title, startDate: Date(timeIntervalSince1970: Double(day) * 86_400), assetIDs: slice.map(\.assetID), confidence: 0.95, titleConfidence: 0.95, scenes: [scene]))
            seed.chapters.append(StoryChapter(title: scene.title, candidateIDs: slice.map(\.id), role: .setup, eventID: events.last?.id, eventSceneID: scene.id, chapterCardTitle: scene.title))
        }
    }
    let context = EditorialAnalysisContext(analyses: analyses, events: events)
    let plan = EditorialStoryPlanner.applying(to: seed, context: context, events: events)
    var rough = TimelineComposer().compose(plan: plan, assets: assets, analyses: analyses)
    rough.width = fixture == .BuggyGroupVerticalFixture ? 180 : 320
    rough.height = fixture == .BuggyGroupVerticalFixture ? 320 : 180
    rough.frameRate = 15
    if fixture == .CalmStyleEffectFixture {
        rough.effects = [.init(effectType: .pixelate, startTime: 1, duration: 2), .init(effectType: .halftone, startTime: 1, duration: 2)]
    }
    var directed = AIDirectorEngine().direct(plan: plan, initialTimeline: rough, assets: assets, analyses: analyses)
    let playback = try await PlaybackEngine().build(timeline: directed, assets: assets, derivedMediaCacheURL: root.appendingPathComponent("derived"), forceVideoComposition: true)
    directed.editorialReview = await RenderedEditorialReviewer().review(timeline: directed, plan: plan, playback: playback, analyses: analyses)
    let winner = try #require(MontageVariantSelector().select(stories: [.init(plan: plan, strategy: fixture.rawValue, seedScore: 1)], timelines: [directed], assets: assets, analyses: analyses))
    #expect(winner.timeline.editorialReview?.hardGatePassed == true)
    #expect(winner.timeline.editorialReview?.productionEligible == false) // Rendered probes alone do not prove semantics.
    #expect(winner.timeline.editorialReview?.renderedProbeCount ?? 0 > 0)
    #expect(winner.timeline.duration < 30)
    #expect(winner.timeline.editorialReview?.duration?.durationConstraintStatus == .compromisedInsufficientContent)
    #expect(!winner.timeline.effectiveEffects.contains { $0.effectType.category == .stylized })
    if fixture == .MutePolicyFixture { #expect(winner.timeline.effectiveAudioClips.isEmpty) }
    if fixture == .BuggyGroupVerticalFixture {
        #expect(winner.timeline.items.allSatisfy { $0.effectiveVideoAdjustments.crop == .fit },
            "rasters directed=\(directed.width)x\(directed.height), winner=\(winner.timeline.width)x\(winner.timeline.height); crops=\(winner.timeline.items.map { $0.effectiveVideoAdjustments.crop }); rejected=\(directed.directorRun?.rejectedOperations ?? [])")
    }
    if fixture == .MultiDayChapterFixture { #expect(plan.narrativeBeatPlan?.pattern == .eventChapters) }
}


@Test func editorialRolloutDefaultsOnAndKeepsEvaluationIndependent() throws {
    var project = ProjectManifest(name: "Fresh project")
    #expect(EditorialRolloutPolicy.isEnabled(in: project))
    let restored = try JSONDecoder.veloEdit.decode(ProjectManifest.self, from: JSONEncoder.veloEdit.encode(project))
    #expect(restored.editorialDevelopmentEnabled == nil)
    #expect(EditorialRolloutPolicy.isEnabled(in: restored))
    project.editorialDevelopmentEnabled = false
    #expect(!EditorialRolloutPolicy.isEnabled(in: project))
    project.editorialDevelopmentEnabled = true
    #expect(EditorialRolloutPolicy.isEnabled(in: project))
    var rows = (0..<20).flatMap { project in
        (0..<3).map { reviewer in EditorialHumanComparison(projectID: "p-\(project)", reviewerID: "r-\(reviewer)", blinded: true, prefersNew: true, newCriticalDefect: false, problematicVerticalScene: project < 5, prefersNewVertical: true, intentViolations: 0) }
    }
    var evaluation = EditorialHumanEvaluation(comparisons: rows, modelVersion: EditorialEvidenceCache.version, reviewedAt: Date())
    #expect(evaluation.passesReleaseCriteria)
    rows[0].intentViolations = 1
    evaluation.comparisons = rows
    #expect(!evaluation.passesReleaseCriteria)
    rows[0].intentViolations = 0
    rows[1].reviewerID = rows[0].reviewerID
    evaluation.comparisons = rows
    #expect(!evaluation.passesReleaseCriteria)
    evaluation.comparisons = Array(rows.prefix(3))
    #expect(!evaluation.passesReleaseCriteria)
}

@Test func editorialNewGenerationSupersedesOldCommitAtomically() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("editorial-cas-\(UUID()).veloedit")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try ProjectStore(createAt: root, name: "CAS")
    let old = try await store.beginEditorialGeneration(prompt: "Создай фильм", brief: nil)
    let snapshot = await store.snapshot()
    let new = try await store.beginEditorialGeneration(prompt: "Без исходного звука", brief: nil)
    #expect(await store.isCurrentEditorialGeneration(ids: old) == false)
    #expect(await store.isCurrentEditorialGeneration(ids: new))
    await #expect(throws: ProjectStoreError.self) { try await store.update(ifRevision: snapshot.revision) { $0.name = "stale" } }
    #expect(await store.manifest.name == "CAS")
}

@Test func editorialSummaryDoesNotAdvertiseSourceAsFilm() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("editorial-summary-\(UUID()).veloedit")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try ProjectStore(createAt: root, name: "No timeline")
    try await store.update { $0.assets = [MediaAsset(originalURL: URL(fileURLWithPath: "/tmp/source.jpg"), kind: .photo, byteSize: 1, contentHash: "photo", metadata: MediaMetadata())] }
    let summary = try #require(ProjectSummary.load(from: root))
    #expect(summary.hasPlayableTimeline == false)
    #expect(summary.previewRelativePaths.isEmpty)
    #expect(summary.previewKind == nil)
}

@Test func editorialLongSpeechKeepsPhraseAndAddsRelatedCutaways() throws {
    var speech = eiCandidate(setup: "camp interview", start: 1, duration: 28)
    speech.tags = ["camp"]
    speech.insights?.speech = SpeechEditingEvidence(text: "Мы рассказываем о дороге, людях и событиях нашего путешествия.", phraseStart: 1, phraseEnd: 29, confidence: 0.95, startsAtPhraseBoundary: true, endsAtPhraseBoundary: true)
    var cutaway = eiCandidate(setup: "camp equipment closeup", duration: 4)
    cutaway.tags = ["camp", "equipment"]
    cutaway.insights?.editorialEvidence?.shotScale = .detail
    var second = eiCandidate(setup: "camp landscape", duration: 4)
    second.tags = ["camp", "landscape"]
    let analyses = eiAnalysis([speech, cutaway, second])
    let assets = [speech, cutaway, second].map { MediaAsset(id: $0.assetID, originalURL: URL(fileURLWithPath: "/tmp/\($0.assetID).mov"), kind: .video, byteSize: 1, contentHash: $0.id.uuidString, metadata: MediaMetadata(duration: 35, hasAudio: true)) }
    var plan = eiPlan(duration: 28)
    plan.chapters = [StoryChapter(title: "Рассказ", candidateIDs: [speech.id])]
    plan.narrativeBeatPlan = NarrativeBeatPlan(pattern: .minimalMontage, beats: [], reasons: [])
    let primary = TimelineItem(candidateID: speech.id, assetID: speech.assetID, kind: .video, sourceStart: 1, sourceDuration: 28, timelineStart: 0, timelineDuration: 28)
    let timeline = EditorialSpeechContinuityPolicy.applying(to: Timeline(storyPlanID: plan.id, items: [primary]), plan: plan, assets: assets, analyses: analyses)
    #expect(EditorialUnit(candidate: speech).usableDuration == 28)
    #expect(timeline.items.first?.sourceStart == 1)
    #expect(timeline.items.first?.sourceDuration == 28)
    #expect(timeline.items.filter { $0.overlay?.style == .cutaway }.count == 2)
    let findings = EditorialQualityGate().review(timeline: timeline, plan: plan, analyses: analyses).findings
    #expect(!findings.contains { [.incompleteMoment, .longSpeechWithoutVisualDevelopment].contains($0.kind) })
}

@Test func editorialCurrentPromptAddsTypedTitleAndMuteIntent() {
    let intents = IntentLedgerEngine.intents(prompt: "Добавь титры. Без исходного звука.", brief: nil, pending: [], newAssetIDs: [])
    #expect(intents.contains(.addTitles))
    #expect(intents.contains(.sourceAudio(.mute)))
    let create = IntentLedgerEngine.intents(prompt: "создай фильм", brief: nil, pending: ["создай фильм"], newAssetIDs: [])
    #expect(create == [.createFilm])
    let automatic = DirectorBrief(canvasFormatIsAutomatic: true, sourceAudioPolicy: .duck)
    let explicit = EditorialIntentEnforcer.updatedBrief(automatic, prompt: "Формат: Вертикальное 9:16. Звук: убрать звук исходников.")
    #expect(explicit?.canvasFormat.width == 1080)
    #expect(explicit?.canvasFormat.height == 1920)
    #expect(explicit?.usesAutomaticCanvasFormat == false)
    #expect(explicit?.sourceAudioPolicy == .mute)
    let later = EditorialIntentEnforcer.updatedBrief(explicit, prompt: "9:16\nСделай горизонтальное 16:9")
    #expect(later?.canvasFormat.width == 1920)
    #expect(later?.canvasFormat.height == 1080)
    let history = IntentLedger(entries: [
        .init(id: UUID(), projectRevision: 0, normalizedIntent: .createFilm, source: .recovery, status: .recoverableFailure, evidence: []),
        .init(id: UUID(), projectRevision: 1, normalizedIntent: .createFilm, source: .prompt, status: .fulfilled, evidence: [])
    ])
    #expect(!history.hasRecoverableGeneration)
}

@Test func editorialRenderedCacheInvalidatesReplacedMusicFile() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("editorial-music-cache-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("music.wav")
    try Data([0, 1, 2]).write(to: file)
    let track = LocalMusicTrack(title: "Fixture", author: "Fixture", bpm: 80, genres: [], moods: [], energy: 0.2, duration: 10, license: .init(name: "fixture", url: file), sourceProvider: .user, sourcePageURL: file, localFileURL: file, originalFileName: "music.wav")
    var timeline = Timeline(storyPlanID: UUID(), items: [])
    timeline.music = MusicDirective(style: .calm, bpm: 80, trackID: track.id)
    let cache = RenderedProbeCache(directory: root.appendingPathComponent("probes"))
    let frames = [PerceptualRenderedFrameEvidence(timelineTime: 0, meanLuma: 0.5, lumaDeviation: 0.1, isBlack: false)]
    try await cache.store(frames, timeline: timeline, assets: [], tracks: [track])
    #expect(await cache.load(timeline: timeline, assets: [], tracks: [track]) != nil)
    try Data([0, 1, 2, 3]).write(to: file)
    #expect(await cache.load(timeline: timeline, assets: [], tracks: [track]) == nil)
}

@Test func editorialVisionLabelFlickerDoesNotInventActionProgression() {
    let candidate = eiCandidate(setup: "steady POV", duration: 12)
    func samples(_ labels: [Set<String>]) -> [VisualFrameSample] {
        labels.enumerated().map { index, tags in
            VisualFrameSample(timestamp: Double(index), motion: 0.95, exposure: 0.8, detail: 0.8, labels: tags, labelConfidence: 0.9, faceCount: 0, jpegBase64: "", histogram: [Double(index % 2), Double((index + 1) % 2)], luminanceFingerprint: [])
        }
    }
    let flicker: [Set<String>] = (0..<12).map { index in index % 2 == 0 ? ["grass", "sky", "cycling"] : ["land", "machine", "outdoor"] }
    let staticEvidence = LocalEditorialEvidenceAnalyzer.evidence(candidate: candidate, samples: samples(flicker))
    #expect(staticEvidence.actionDelta == 0)
    #expect(!staticEvidence.hasProgression)
    #expect(staticEvidence.informationGain >= 0.18)
    #expect(staticEvidence.atmosphereValue >= 0.65)
    let action: [Set<String>] = (0..<12).map { index in index < 6 ? ["running"] : ["jumping"] }
    let progression = LocalEditorialEvidenceAnalyzer.evidence(candidate: candidate, samples: samples(action))
    #expect(progression.actionDelta >= 0.18)
    #expect(progression.hasProgression)
}

@Test func editorialUnrelatedDocumentHasDiscardEvidenceWithoutExcludingMusicCoverage() {
    var a = eiCandidate(setup: "riverside fishing"), b = eiCandidate(setup: "forest cycling")
    a.tags = ["outdoor", "fishing"]; b.tags = ["outdoor", "cycling"]
    var document = eiCandidate(setup: "printed score")
    document.tags = ["document", "printed_page", "art"]
    let context = EditorialAnalysisContext(analyses: eiAnalysis([a, b, document]))
    #expect(context.units.first { $0.id == document.id }?.usableDuration == 0)
    let plan = EditorialStoryPlanner.applying(to: eiPlan(), context: context)
    #expect(plan.narrativeBeatPlan?.discardedCandidates?[document.id] == .noNarrativeFit)
    #expect(plan.chapters.allSatisfy { !$0.candidateIDs.contains(document.id) })
    a.tags.insert("concert")
    let concert = EditorialAnalysisContext(analyses: eiAnalysis([a, b, document]))
    #expect((concert.units.first { $0.id == document.id }?.usableDuration ?? 0) > 0)
    a.tags.remove("concert"); document.locked = true
    let locked = EditorialAnalysisContext(analyses: eiAnalysis([a, b, document]))
    #expect((locked.units.first { $0.id == document.id }?.usableDuration ?? 0) > 0)
}

@Test func editorialAutomaticChapterHasNoTemplateDemoNumberAndRejectsGenericLabel() {
    #expect(SmartTitleEngine.isMeaningless("Съёмка"))
    let candidate = eiCandidate(setup: "fishing")
    var plan = EditorialStoryPlanner.applying(to: eiPlan(), context: EditorialAnalysisContext(analyses: eiAnalysis([candidate])))
    plan.prompt = "Добавь титры"
    plan.directorBrief?.titlePolicy = .minimal
    plan.chapters[0].title = "Рыбалка"
    let item = TimelineItem(candidateID: candidate.id, assetID: candidate.assetID, kind: .video, sourceDuration: 4, timelineStart: 0, timelineDuration: 4)
    let source = Timeline(storyPlanID: plan.id, items: [item])
    let titled = EditorialPresentationPolicy.chapters(in: source, plan: plan)
    #expect(titled.effectiveTitleItems.map(\.text) == ["Рыбалка"])
    #expect(titled.effectiveTitleItems.allSatisfy { $0.templateID == DirectorVisualStyle(plan: plan).templateID(for: .chapter) })
    var duplicated = titled
    var late = titled.effectiveTitleItems[0]
    late.id = UUID(); late.startTime = 2.5
    duplicated.titleItems?.append(late)
    let repaired = EditorialPresentationPolicy.chapters(in: duplicated, plan: plan)
    #expect(repaired.effectiveTitleItems.count == 1)
    #expect(repaired.effectiveTitleItems[0].id == titled.effectiveTitleItems[0].id)
    #expect(repaired.effectiveTitleItems[0].startTime == 0)
}

@Test(arguments: [true, false]) func editorialConnectedClipNeverShiftsPrimaryMediaSegments(hasBase: Bool) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("editorial-connected-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    var assets: [MediaAsset] = []
    for index in 0..<3 {
        let context = try #require(CGContext(data: nil, width: 160, height: 90, bitsPerComponent: 8, bytesPerRow: 640, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: index == 0 ? 0.8 : 0.2, green: index == 1 ? 0.8 : 0.2, blue: index == 2 ? 0.8 : 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 160, height: 90))
        let url = root.appendingPathComponent("\(index).png")
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        try #require(CGImageDestinationFinalize(destination))
        assets.append(MediaAsset(originalURL: url, kind: .photo, byteSize: 0, contentHash: "fixture-\(index)", metadata: MediaMetadata(width: 160, height: 90)))
    }
    let first = TimelineItem(assetID: assets[0].id, kind: .photo, sourceDuration: 3, timelineStart: 0, timelineDuration: 3)
    let second = TimelineItem(assetID: assets[1].id, kind: .photo, sourceDuration: 3, timelineStart: 3, timelineDuration: 3)
    var connected = TimelineItem(assetID: assets[2].id, kind: .photo, sourceDuration: 2, timelineStart: 1.5, timelineDuration: 2)
    connected.overlay = OverlaySettings(style: .cutaway, baseItemID: hasBase ? first.id : nil, startOffset: 1.5)
    let timeline = Timeline(storyPlanID: UUID(), width: 320, height: 180, frameRate: 24, items: [first, second, connected], originalAudioVolume: 0)
    let playback = try await PlaybackEngine().build(timeline: timeline, assets: assets, forceVideoComposition: true)
    #expect(abs(playback.composition.duration.seconds - 6) < 0.01)
    let generator = AVAssetImageGenerator(asset: playback.composition)
    generator.videoComposition = playback.videoComposition
    let frame = try await generator.image(at: CMTime(seconds: 4.5, preferredTimescale: 600)).image
    #expect(!FrameQualityInspector.assess(image: frame).isBlack)
}

@Test func editorialChapterSearchNeverReopensAClosedSceneAfterContinuityChanges() {
    let asset = UUID(), event = UUID(), firstScene = UUID(), secondScene = UUID()
    let first = eiCandidate(assetID: asset, setup: "forest ride", start: 100, quality: 0.95)
    let earlier = eiCandidate(assetID: asset, setup: "lakeside departure", start: 0, quality: 0.8)
    let next = eiCandidate(setup: "car and passengers", quality: 0.9)
    var source = eiPlan(duration: 60)
    source.chapters = [first, earlier, next].map { candidate in
        StoryChapter(title: candidate.id == next.id ? "Поездка" : "Прогулка", candidateIDs: [candidate.id], eventID: event, eventSceneID: candidate.id == next.id ? secondScene : firstScene)
    }
    let plan = EditorialStoryPlanner.applying(to: source, context: EditorialAnalysisContext(analyses: eiAnalysis([first, earlier, next])), strategy: "quiet-observational", priority: [first.id: 2])
    #expect(plan.chapters.flatMap(\.candidateIDs) == [first.id, next.id])
    #expect(plan.narrativeBeatPlan?.discardedCandidates?[earlier.id] == .noNarrativeFit)
}

@Test func editorialFallbackPreservesVerifiedEventOrderWithoutEventObjects() {
    let first = UUID(), second = UUID()
    let candidates = (0..<6).map { eiCandidate(setup: "unique-event-view-\($0)", quality: $0 % 2 == 0 ? 0.75 : 0.96) }
    var source = eiPlan(duration: 60)
    source.chapters = candidates.enumerated().map { index, candidate in
        StoryChapter(title: index < 3 ? "У реки" : "В лесу", candidateIDs: [candidate.id], eventID: index < 3 ? first : second, chapterCardTitle: index < 3 ? "У реки" : "В лесу")
    }
    let plan = EditorialStoryPlanner.applying(to: source, context: EditorialAnalysisContext(analyses: eiAnalysis(candidates)), strategy: "quiet-observational")
    #expect(plan.narrativeBeatPlan?.pattern == .eventChapters)
    let order = plan.chapters.compactMap(\.eventID).reduce(into: [UUID]()) { if $0.last != $1 { $0.append($1) } }
    #expect(order == [first, second])
    #expect(plan.chapters.count == 6)
    // A single trip can contain several activities. Their scene scopes are
    // equally important even though all footage shares the same event ID.
    for index in source.chapters.indices {
        source.chapters[index].eventSceneID = source.chapters[index].eventID
        source.chapters[index].eventID = first
    }
    let trip = EditorialStoryPlanner.applying(to: source, context: EditorialAnalysisContext(analyses: eiAnalysis(candidates)), strategy: "quiet-observational")
    let scenes = trip.chapters.compactMap(\.eventSceneID).reduce(into: [UUID]()) { if $0.last != $1 { $0.append($1) } }
    #expect(scenes == [first, second])
}

@Test(arguments: [false, true]) func chapterSearchReservesSpaceForLaterActivities(useScenes: Bool) {
    let scopes = (0..<5).map { _ in UUID() }
    let candidates = (0..<50).map { eiCandidate(setup: "distinct-view-\($0)", quality: 0.9) }
    var units = candidates.enumerated().map { index, candidate in
        var unit = EditorialUnit(candidate: candidate)
        unit.eventID = useScenes ? scopes[0] : scopes[index / 10]
        unit.sceneID = useScenes ? scopes[index / 10] : nil
        return unit
    }
    // The first activity alone has enough footage for the entire request.
    // A five-shot cap must still leave one shot for every activity.
    let hypothesis = NarrativeHypothesis(eventOrder: useScenes ? nil : scopes, sceneOrder: useScenes ? scopes : nil,
        pattern: .eventChapters, evidenceCoverage: 1, reasons: [])
    for limit in [nil, 5] as [Int?] {
        let result = EditorialSequenceSearch().sequence(hypothesis: hypothesis, units: units,
            families: ShotFamilyClusterer().cluster(units: units), target: 60, pacing: 0.5, maximumCount: limit)
        let order = result.units.compactMap { useScenes ? $0.sceneID : $0.eventID }.reduce(into: [UUID]()) {
            if $0.last != $1 { $0.append($1) }
        }
        #expect(order == scopes)
        #expect(result.beatPlan.beats.reduce(0) { $0 + $1.allocatedDuration } <= 60.05)
    }
    // Empty/failed activities must not reserve phantom time.
    units.removeAll { (useScenes ? $0.sceneID : $0.eventID) == scopes[2] }
    let result = EditorialSequenceSearch().sequence(hypothesis: hypothesis, units: units,
        families: ShotFamilyClusterer().cluster(units: units), target: 60, pacing: 0.5)
    #expect(Set(result.units.compactMap { useScenes ? $0.sceneID : $0.eventID }) == Set(scopes.filter { $0 != scopes[2] }))
}

@Test func editorialTemporalPeopleProtectFramingBeyondOldSparseTracking() throws {
    let old = SubjectTrackingSummary(tracks: [], mainSubjectID: nil, confidence: 0.4, analyzedFrameCount: 1)
    let people: [NormalizedRegion] = [.init(x: 0.05, y: 0.2, width: 0.2, height: 0.6), .init(x: 0.75, y: 0.2, width: 0.2, height: 0.6)]
    let evidence = EditorialEvidence(samples: [.init(sourceTime: 1, subjectRegions: people, subjectKinds: [.person, .person], confidence: 0.9)], usableRange: .init(start: 0, end: 3), confidence: 0.9)
    let refreshed = try #require(LocalEditorialEvidenceAnalyzer.tracking(existing: old, evidence: evidence))
    #expect(refreshed.tracks.count == 2)
    #expect(SubjectAwareReframeEngine().plan(tracking: refreshed, sourceAspectRatio: 16.0 / 9, targetAspectRatio: 9.0 / 16) == nil)
    #expect(LocalEditorialEvidenceAnalyzer.tracking(existing: refreshed, evidence: evidence)?.tracks.count == 2)
}

private actor RecoveringEditorialProber: EditorialRenderedProbing {
    enum Failure: Error { case temporarilyUnavailable }
    var calls = 0
    let failures: Int
    let emptyFirst: Bool
    init(failures: Int = 1, emptyFirst: Bool = false) {
        self.failures = failures
        self.emptyFirst = emptyFirst
    }
    func frames(timeline: Timeline, assets: [MediaAsset], tracks: [LocalMusicTrack], telemetry: [UUID: TelemetrySummary], cacheURL: URL) async throws -> [PerceptualRenderedFrameEvidence] {
        calls += 1
        if calls <= failures {
            if emptyFirst { return [] }
            throw Failure.temporarilyUnavailable
        }
        return try await FixtureEditorialProber().frames(timeline: timeline, assets: assets, tracks: tracks, telemetry: telemetry, cacheURL: cacheURL)
    }
}

@Test(arguments: [false, true]) func editorialRenderedProbeRecoversTransientFailure(emptyFirst: Bool) async throws {
    let candidate = eiCandidate(setup: "river", duration: 4, progression: true)
    let analyses = eiAnalysis([candidate])
    let plan = eiPlan(duration: 4)
    let timeline = Timeline(storyPlanID: plan.id, items: [TimelineItem(candidateID: candidate.id, assetID: candidate.assetID, kind: .video, sourceDuration: 4, timelineStart: 0, timelineDuration: 4)])
    let cache = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: cache) }
    let prober = RecoveringEditorialProber(emptyFirst: emptyFirst)
    let result = await VeloEditPipeline.editorialRenderReview(timeline: timeline, plan: plan, assets: [], analyses: analyses, tracks: [], telemetry: [:], cacheURL: cache, prober: prober)
    #expect(await prober.calls == 2)
    #expect(result.editorialReview?.renderedProbeCount == EditorialProbeSchedule.times(timeline: timeline).count)
    #expect(result.editorialReview?.findings.contains { $0.kind == .renderedEvidenceUnavailable && $0.severity == 1 } == false)
    #expect(result.editorialReview?.findings.contains { $0.kind == .renderedEvidenceUnavailable && $0.severity >= 3 } == false)
}

@Test func editorialRenderedProbePersistentFailureIsBoundedAndVisible() async {
    let plan = eiPlan(duration: 4)
    let prober = RecoveringEditorialProber(failures: 10)
    let cache = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: cache) }
    let result = await VeloEditPipeline.editorialRenderReview(timeline: Timeline(storyPlanID: plan.id, items: []), plan: plan, assets: [], analyses: [], tracks: [], telemetry: [:], cacheURL: cache, prober: prober)
    #expect(await prober.calls == 2)
    #expect(result.editorialReview?.productionEligible == false)
    #expect(result.editorialReview?.findings.contains { $0.kind == .renderedEvidenceUnavailable && $0.severity >= 3 } == true)
}

@Test func editorialFallbackSearchContinuesWithoutPriorDecodedFrames() {
    let candidates = (0..<4).map { eiCandidate(setup: "distinct-view-\($0)", duration: 4, progression: true) }
    let analyses = eiAnalysis(candidates)
    let assets = candidates.map { MediaAsset(id: $0.assetID, originalURL: URL(fileURLWithPath: "/tmp/source"), kind: .video, byteSize: 0, contentHash: "fixture", metadata: MediaMetadata(duration: 4)) }
    let plan = EditorialStoryPlanner.applying(to: eiPlan(duration: 16), context: EditorialAnalysisContext(analyses: analyses))
    let timeline = TimelineComposer().compose(plan: plan, assets: assets, analyses: analyses)
    let results = ConservativeFallbackBuilder().candidates(stories: [.init(plan: plan, strategy: "fixture", seedScore: 0)], reviewed: [timeline], assets: assets, analyses: analyses, limit: 3)
    #expect(!results.isEmpty)
    #expect(results.allSatisfy { $0.timeline.duration + 0.1 >= (plan.contentBudget?.budget.safeRange.lowerBound ?? 0) })
    #expect(results.count <= 3)
    #expect(results.allSatisfy { $0.timeline.transitionItems?.isEmpty != false })
}

@Test func enrichedBudgetSafeFloorBecomesTheSequenceTarget() {
    let candidates = (0..<10).map { index in
        eiCandidate(setup: "progressive-scene-\(index)", duration: 6, progression: true)
    }
    let seed = StoryPlan(
        prompt: "Собери законченный фильм из лучших моментов",
        preset: .story,
        constraints: StoryConstraints(targetDuration: 8, targetClipCount: 10, pacing: 0.45),
        chapters: []
    )
    let plan = EditorialStoryPlanner.applying(
        to: seed,
        context: EditorialAnalysisContext(analyses: eiAnalysis(candidates))
    )
    let floor = plan.contentBudget?.budget.safeRange.lowerBound ?? 0
    let allocated = plan.narrativeBeatPlan?.beats.reduce(0) { $0 + $1.allocatedDuration } ?? 0
    #expect(plan.constraints.targetDuration + 0.001 >= floor)
    #expect(allocated + 0.05 >= floor)
}

@Test func fullyMinedSequenceCapacityReconcilesAnUnreachableGlobalFloor() throws {
    let candidates = (0..<10).map { _ in
        eiCandidate(setup: "same-mounted-camera", duration: 8, progression: true)
    }
    var analyses = eiAnalysis(candidates)
    for index in analyses.indices { analyses[index].warnings.append(EditorialCandidateMiner.completionMarker) }
    let seed = StoryPlan(
        prompt: "Точная длительность: 5 мин.",
        preset: .story,
        constraints: StoryConstraints(targetDuration: 300, pacing: 0.4),
        chapters: [],
        directorBrief: DirectorBrief(
            canvasFormat: .portrait9x16,
            requestedDuration: 300,
            mood: .calm,
            musicPolicy: .matchVideo,
            sourceAudioPolicy: .mute,
            titlePolicy: .keyOnly
        )
    )
    let plan = EditorialStoryPlanner.applying(
        to: seed,
        context: EditorialAnalysisContext(analyses: analyses)
    )
    let decision = try #require(plan.contentBudget)
    let allocated = plan.narrativeBeatPlan?.beats.reduce(0) { $0 + $1.allocatedDuration } ?? 0
    #expect(decision.durationConstraintStatus == .compromisedInsufficientContent)
    #expect(decision.requiresExpandedMining == false)
    #expect(decision.supportedDuration <= allocated + 0.001)
    #expect(decision.budget.safeRange.lowerBound <= allocated + 0.05)
    #expect(plan.exactDurationRequirement == 300)
}

private actor CancelledEditorialProber: EditorialRenderedProbing {
    var calls = 0
    func frames(timeline: Timeline, assets: [MediaAsset], tracks: [LocalMusicTrack], telemetry: [UUID: TelemetrySummary], cacheURL: URL) async throws -> [PerceptualRenderedFrameEvidence] {
        calls += 1
        throw CancellationError()
    }
}

private actor FramingRecordingEditorialProber: EditorialRenderedProbing {
    var observedCrop: CropStyle?
    func frames(timeline: Timeline, assets: [MediaAsset], tracks: [LocalMusicTrack], telemetry: [UUID: TelemetrySummary], cacheURL: URL) async throws -> [PerceptualRenderedFrameEvidence] {
        observedCrop = timeline.items.first?.effectiveVideoAdjustments.crop
        return try await FixtureEditorialProber().frames(timeline: timeline, assets: assets, tracks: tracks, telemetry: telemetry, cacheURL: cacheURL)
    }
}

@Test func editorialReviewMaterializesAutomaticFramingBeforeProbeAndPersistence() async {
    let candidate = eiCandidate(setup: "legacy-wide", duration: 4, progression: true)
    let asset = MediaAsset(id: candidate.assetID, originalURL: URL(fileURLWithPath: "/tmp/wide.mov"), kind: .video, byteSize: 0, contentHash: "wide", metadata: MediaMetadata(duration: 4, width: 1920, height: 1080))
    let plan = StoryPlan(prompt: "Вертикальный фильм", preset: .story, constraints: StoryConstraints(targetDuration: 4), chapters: [])
    let timeline = Timeline(storyPlanID: plan.id, width: 1080, height: 1920, items: [TimelineItem(candidateID: candidate.id, assetID: candidate.assetID, kind: .video, sourceDuration: 4, timelineStart: 0, timelineDuration: 4)])
    let cache = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: cache) }
    let prober = FramingRecordingEditorialProber()
    let result = await VeloEditPipeline.editorialRenderReview(timeline: timeline, plan: plan, assets: [asset], analyses: eiAnalysis([candidate]), tracks: [], telemetry: [:], cacheURL: cache, prober: prober)
    #expect(await prober.observedCrop == .fit)
    #expect(result.items.first?.effectiveVideoAdjustments.crop == .fit)
}

private actor RepairAwareEditorialProber: EditorialRenderedProbing {
    func frames(timeline: Timeline, assets: [MediaAsset], tracks: [LocalMusicTrack], telemetry: [UUID: TelemetrySummary], cacheURL: URL) async throws -> [PerceptualRenderedFrameEvidence] {
        var frames = try await FixtureEditorialProber().frames(timeline: timeline, assets: assets, tracks: tracks, telemetry: telemetry, cacheURL: cacheURL)
        guard !frames.isEmpty else { return frames }
        let primaries = timeline.items.filter { $0.overlay == nil && $0.kind != .title }
        let bodySafe = primaries.first?.effectiveVideoAdjustments.crop == .fit
        let novel = primaries.count == 1
        frames[0].editorialClaims = frames[0].editorialClaims?.map { claim in
            var value = claim
            if claim.domain == .bodySafety {
                value.status = bodySafe ? .passed : .failed
                value.itemIDs = bodySafe ? primaries.map(\.id) : Array(primaries.prefix(1)).map(\.id)
                value.probeTimes = frames.map(\.timelineTime).filter { time in primaries.contains { value.itemIDs.contains($0.id) && time >= $0.timelineStart && time < $0.timelineStart + $0.timelineDuration } }
                value.finding = bodySafe ? nil : EditorialFinding(kind: .unsafeReframe, severity: 3, itemIDs: value.itemIDs, repair: .framing, reason: "fixture rendered crop")
            } else if claim.domain == .visualNovelty {
                value.status = novel ? .passed : .failed
                value.itemIDs = novel ? primaries.map(\.id) : Array(primaries.dropFirst().prefix(1)).map(\.id)
                value.probeTimes = frames.map(\.timelineTime).filter { time in primaries.contains { value.itemIDs.contains($0.id) && time >= $0.timelineStart && time < $0.timelineStart + $0.timelineDuration } }
                value.finding = novel ? nil : EditorialFinding(kind: .hardDuplicate, severity: 3, itemIDs: value.itemIDs, repair: .removeDuplicate, reason: "fixture rendered duplicate")
            }
            value.renderSignature = EditorialRenderSignature.signature(timeline)
            return value
        }
        return frames
    }
}

@Test func editorialRenderedRepairFitsUnsafeBodyAndRemovesMeasuredDuplicate() async {
    // The remaining shot must still satisfy the minimum film duration after
    // all measured duplicates are removed.
    let shotDuration = AutomaticFilmDurationPolicy.minimumDuration + 2
    let candidates = [
        eiCandidate(setup: "person-wide-a", duration: shotDuration, progression: true),
        eiCandidate(setup: "person-wide-b", duration: shotDuration, progression: true),
        eiCandidate(setup: "person-wide-c", duration: shotDuration, progression: true),
        eiCandidate(setup: "person-wide-d", duration: shotDuration, progression: true)
    ]
    let plan = StoryPlan(prompt: "Короткая история", preset: .story, constraints: StoryConstraints(targetDuration: shotDuration), chapters: [])
    var timeline = Timeline(storyPlanID: plan.id, items: candidates.enumerated().map { index, candidate in
        TimelineItem(candidateID: candidate.id, assetID: candidate.assetID, kind: .video, sourceDuration: shotDuration, timelineStart: Double(index) * shotDuration, timelineDuration: shotDuration)
    })
    timeline.editorialBeatPlan = NarrativeBeatPlan(pattern: .minimalMontage, beats: candidates.map {
        EditorialNarrativeBeat(candidateID: $0.id, purpose: .development, viewerInformation: "fixture progression", requiredChange: 0, familyID: nil, minimumEvidence: 0.38, durationRange: 0.5...shotDuration, allocatedDuration: shotDuration, fulfilled: true)
    }, reasons: [])
    let cache = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: cache) }
    let result = await VeloEditPipeline.editorialRenderReview(
        timeline: timeline,
        plan: plan,
        assets: [],
        analyses: eiAnalysis(candidates),
        tracks: [],
        telemetry: [:],
        cacheURL: cache,
        prober: RepairAwareEditorialProber()
    )
    #expect(result.items.filter { $0.overlay == nil }.count == 1)
    #expect(result.editorialBeatPlan?.beats.count == 1)
    #expect(result.items.first?.effectiveVideoAdjustments.crop == .fit)
    #expect(result.editorialReview?.findings.contains { [.unsafeReframe, .hardDuplicate].contains($0.kind) } == false)
}

@Test func editorialRenderedProbeDoesNotRetryCancellation() async {
    let plan = eiPlan(duration: 4)
    let prober = CancelledEditorialProber()
    let cache = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: cache) }
    _ = await VeloEditPipeline.editorialRenderReview(timeline: Timeline(storyPlanID: plan.id, items: []), plan: plan, assets: [], analyses: [], tracks: [], telemetry: [:], cacheURL: cache, prober: prober)
    #expect(await prober.calls == 1)
}

@Test func incrementalDuplicateEvaluationMatchesEveryFullPrefix() {
    let asset = UUID()
    var units: [EditorialUnit] = []
    for index in 0..<36 {
        let source = index % 3 == 0 ? asset : UUID()
        let candidate = eiCandidate(assetID: source, setup: "setup-\(index % 7)",
            start: Double(index % 9) * 2, progression: index % 5 == 0)
        units.append(EditorialUnit(candidate: candidate))
    }
    var memo = SequenceDuplicateMemo()
    for length in 0...units.count {
        let selected = Array(units.prefix(length))
        for unit in units {
            #expect(memo.containsDuplicate(of: unit, in: selected) == selected.contains {
                ShotFamilyClusterer().isHardDuplicate($0, unit, adjacent: false)
            })
        }
    }
}

@Test func incrementalSequenceSearchMatchesOriginalCompleteAlgorithm() {
    let events = [UUID(), UUID(), UUID()]
    let source = UUID()
    var units: [EditorialUnit] = []
    for index in 0..<40 {
        let candidate = eiCandidate(assetID: index % 4 == 0 ? source : UUID(),
            setup: "view-\(index % 9)", start: Double(index % 13),
            duration: index % 11 == 0 ? 0.3 : 4, progression: index % 3 == 0)
        var unit = EditorialUnit(candidate: candidate)
        unit.eventID = index % 7 == 0 ? nil : events[index % 3]
        unit.sceneID = events[(index / 3) % 3]
        units.append(unit)
    }
    let index = ShotFamilyClusterer().cluster(units: units)
    for pattern in [EditorialNarrativePattern.minimalMontage, .eventChapters, .rapidHighlight] {
        for target in [12.0, 60.0, 150.0] {
            for limit in [nil, 5] as [Int?] {
                for families in [index, ShotFamilyIndex(families: [])] {
                    let hypothesis = NarrativeHypothesis(eventOrder: events, sceneOrder: target == 60 ? events : nil,
                        pattern: pattern, evidenceCoverage: 1, reasons: ["equivalence fixture"])
                    let priorities = [units[4].id: 0.7, units[9].id: 0.4]
                    let expected = BaselineEditorialSequenceSearch().sequence(hypothesis: hypothesis, units: units,
                        families: families, target: target, pacing: 0.5, priority: priorities, maximumCount: limit)
                    let result = EditorialSequenceSearch().sequence(hypothesis: hypothesis, units: units,
                        families: families, target: target, pacing: 0.5, priority: priorities, maximumCount: limit)
                    #expect(result.units == expected.units)
                    #expect(result.beatPlan == expected.beatPlan)
                    #expect(result.discarded == expected.discarded)
                }
            }
        }
    }
}

@Test func sequenceCacheInvalidatesInputsAndReturnsIndependentValues() throws {
    let units = (0..<8).map { EditorialUnit(candidate: eiCandidate(setup: "cache-view-\($0)", progression: true)) }
    let families = ShotFamilyClusterer().cluster(units: units)
    let hypothesis = NarrativeHypothesis(pattern: .rapidHighlight, evidenceCoverage: 1, reasons: [])
    let search = EditorialSequenceSearch()
    let original = search.sequence(hypothesis: hypothesis, units: units, families: families, target: 20, pacing: 0.5)
    var copy = search.sequence(hypothesis: hypothesis, units: units, families: families, target: 20, pacing: 0.5)
    copy.units.removeAll()
    #expect(search.sequence(hypothesis: hypothesis, units: units, families: families, target: 20, pacing: 0.5).units == original.units)
    let preferred = try #require(units.first { candidate in !original.units.contains { $0.id == candidate.id } })
    let reordered = search.sequence(hypothesis: hypothesis, units: units, families: families, target: 20, pacing: 0.5, priority: [preferred.id: 100])
    let expectedReordered = BaselineEditorialSequenceSearch().sequence(hypothesis: hypothesis, units: units, families: families,
        target: 20, pacing: 0.5, priority: [preferred.id: 100])
    #expect(reordered.units.contains { $0.id == preferred.id })
    #expect(reordered.units == expectedReordered.units)
    #expect(reordered.beatPlan == expectedReordered.beatPlan)
    var changed = units
    changed[0].candidate.sourceStart = 10
    changed[0].candidate.sourceDuration = 0.1
    let actual = search.sequence(hypothesis: hypothesis, units: changed, families: families, target: 20, pacing: 0.5)
    let expected = BaselineEditorialSequenceSearch().sequence(hypothesis: hypothesis, units: changed, families: families, target: 20, pacing: 0.5)
    #expect(actual.units == expected.units)
    #expect(actual.beatPlan == expected.beatPlan)
    #expect(actual.discarded == expected.discarded)
}
