import Foundation
import Testing
@testable import VeloEditCore

@Test func verificationReusesUnitsWithoutChangingAnyEvidenceDomain() {
    let (timeline, plan, analyses) = verificationFixture()
    let context = EditorialAnalysisContext(analyses: analyses)
    let units = Dictionary(uniqueKeysWithValues: context.units.map { ($0.id, $0) })
    let standalone = EditorialEvidenceVerifier.verify(timeline: timeline, plan: plan, analyses: analyses, frames: [], findings: [])
    let reused = EditorialEvidenceVerifier.verify(timeline: timeline, plan: plan, analyses: analyses, frames: [], findings: [], units: units)
    #expect(standalone == reused)
    #expect(reused.contains { $0.domain == .subjectCoverage && $0.required && $0.status == .unknown })
    #expect(reused.contains { $0.domain == .renderDecode && $0.required && $0.status == .unknown })
}

private func verificationFixture(duration: Double = 12, lower: Double = 10, upper: Double = 15) -> (Timeline, StoryPlan, [AnalysisResult]) {
    let candidate = Candidate(assetID: UUID(), sourceStart: 0, sourceDuration: duration, scores: ClipScores(quality: 0.9, interest: 0.9, action: 0.8, stability: 0.9), tags: ["person"])
    let analysis = AnalysisResult(assetID: candidate.assetID, schemaVersion: 1, analyzedContentHash: "synthetic", sceneTags: [], candidates: [candidate], warnings: [])
    var plan = StoryPlan(prompt: "Без исходного звука", preset: .story, constraints: StoryConstraints(targetDuration: duration, pacing: 0.4), chapters: [], directorBrief: DirectorBrief(requestedDuration: duration, musicPolicy: .none, sourceAudioPolicy: .mute, titlePolicy: .none))
    plan.contentBudget = .init(budget: .init(idealDuration: 12, safeRange: lower...upper, absoluteCeiling: upper, strongUnitCount: 1, distinctEventCount: 1, distinctSceneCount: 1, distinctShotFamilyCount: 1, usableActionSeconds: upper, usableAtmosphereSeconds: 0, usableSpeechSeconds: 0, confidence: 0.9, limitingFactors: []), requestedDuration: duration, supportedDuration: upper, durationConstraintStatus: .satisfied, requiresExpandedMining: false, feasibility: 1, reason: "Independent synthetic budget")
    let item = TimelineItem(candidateID: candidate.id, assetID: candidate.assetID, kind: .video, sourceDuration: duration, timelineStart: 0, timelineDuration: duration, locked: true)
    let timeline = EditorialIntentEnforcer.enforce(Timeline(storyPlanID: plan.id, items: [item], originalAudioVolume: 0), plan: plan)
    return (timeline, plan, [analysis])
}

@Test func verificationEvidenceStatesRoundTripWithoutOptimisticMigration() throws {
    let (timeline, plan, analyses) = verificationFixture()
    let review = EditorialQualityGate().review(timeline: timeline, plan: plan, analyses: analyses)
    for status in [EditorialEvidenceState.passed, .failed, .unknown] {
        var record = try #require(review.evidenceDomains?.first)
        record.status = status
        let decoded = try JSONDecoder().decode(EditorialDomainEvidence.self, from: JSONEncoder().encode(record))
        #expect(decoded == record)
    }
    var legacy = review
    legacy.evidenceVersion = nil
    legacy.evidenceDomains = nil
    legacy.editorialScore = 1
    let restored = try JSONDecoder().decode(EditorialReview.self, from: JSONEncoder().encode(legacy))
    #expect(!restored.productionEligible)
}

@Test func verificationMissingEvidenceCannotBeCompensatedByScoresOrPlannerLabels() {
    let (timeline, sourcePlan, analyses) = verificationFixture()
    var plan = sourcePlan
    let id = analyses[0].candidates[0].id
    plan.narrativeBeatPlan = .init(pattern: .minimalMontage, beats: [.init(candidateID: id, purpose: .closure, viewerInformation: "planner promise", requiredChange: 0, minimumEvidence: 0, durationRange: 1...12, allocatedDuration: 12, fulfilled: true)], reasons: [])
    let yes = EditorialQualityGate().review(timeline: timeline, plan: plan, analyses: analyses)
    plan.narrativeBeatPlan?.beats[0].fulfilled = false
    let no = EditorialQualityGate().review(timeline: timeline, plan: plan, analyses: analyses)
    #expect(yes.evidenceDomains == no.evidenceDomains)
    #expect(yes.narrativeCoherence == 0)
    #expect(!yes.productionEligible)
    #expect(yes.blockingUnknowns.contains { $0.domain == .closureFulfillment })
}

@Test(arguments: [(15.66, 24.51, 34.88), (26.83, 30.68, 45.02)])
func verificationRecordedShortFilmRegressionsFailIndependently(_ values: (Double, Double, Double)) {
    let (timeline, plan, analyses) = verificationFixture(duration: values.0, lower: values.1, upper: values.2)
    let review = EditorialQualityGate().review(timeline: timeline, plan: plan, analyses: analyses)
    #expect(review.findings.contains { $0.kind == .durationUnderflow && $0.severity == 2 && $0.repair == .structuralReplan })
    #expect(review.duration?.requiresExpandedMining == true)
    #expect(review.evidenceDomains?.first { $0.domain == .contentBudgetLowerBound }?.status == .failed)
    #expect(!review.productionEligible)
    let (repaired, _, _) = verificationFixture(duration: values.1 + 0.5, lower: values.1, upper: values.2)
    let after = EditorialQualityGate().review(timeline: repaired, plan: plan, analyses: analyses)
    #expect(!after.findings.contains { $0.kind == .durationUnderflow })
    #expect(!after.productionEligible) // Repairing duration does not invent other evidence.
}

@Test func verificationUpperBudgetAndShortExplicitIntent() {
    let (timeline, plan, analyses) = verificationFixture(duration: 18)
    let review = EditorialQualityGate().review(timeline: timeline, plan: plan, analyses: analyses)
    #expect(review.findings.contains { $0.kind == .durationPadding })
    let context = EditorialAnalysisContext(analyses: analyses)
    let budget = ContentBudgetEngine().budget(units: context.units, families: context.families, requestedDuration: 2, requestIsExplicit: true, style: DirectorStyleVector())
    #expect(budget.requestedDuration == 10)
    #expect(budget.budget.safeRange.lowerBound == min(10, budget.supportedDuration))
}

@Test(arguments: [2, 3, 4, 8, 20]) func verificationEqualFamiliesAreMathematicallyFeasible(_ count: Int) {
    let histogram = Dictionary(uniqueKeysWithValues: (0..<count).map { (String($0), 5.0) })
    let distribution = EditorialFamilyDistribution(histogram: histogram, maximumRun: 5, atmospheric: false)
    #expect(abs(distribution.dominanceExcess) < 0.000001)
    #expect(abs(distribution.normalizedEntropy - 1) < 0.000001)
    #expect(abs(distribution.effectiveFamilyCount - Double(count)) < 0.000001)
    #expect(!distribution.excessive)
    let concentrated = EditorialFamilyDistribution(histogram: ["a": 80, "b": 10, "c": 10], maximumRun: 30, atmospheric: false)
    #expect(concentrated.excessive)
}

@Test func verificationCoverageCountsRiskZonesNotArbitraryProbeQuantity() {
    let (timeline, _, _) = verificationFixture(duration: 30)
    let required = EditorialProbeSchedule.times(timeline: timeline)
    #expect(required.contains { abs($0 - 15) < 0.01 })
    #expect(zip(required, required.dropFirst()).allSatisfy { $1 - $0 <= 2.01 })
    #expect(EditorialProbeSchedule.coverage(required: required, observed: required) == 1)
    #expect(EditorialProbeSchedule.coverage(required: required, observed: Array(repeating: required[0], count: 500)) < 0.2)
    #expect(EditorialProbeSchedule.coverage(required: required, observed: Array(required.prefix(3))) < 0.95)
}

@Test func verificationPreliminaryRankingDoesNotReportIntentionallyMissingProductionChecks() async throws {
    let (timeline, plan, analyses) = verificationFixture()
    var frames = Array(try await FixtureEditorialProber().frames(timeline: timeline, assets: [], tracks: [], telemetry: [:], cacheURL: FileManager.default.temporaryDirectory).prefix(3))
    frames[0].exportVerification = nil
    let times = frames.map(\.timelineTime)
    frames[0].editorialClaims = frames[0].editorialClaims?.map { claim in
        var scoped = claim
        scoped.probeTimes = times
        return scoped
    }
    let preliminary = EditorialQualityGate().review(timeline: timeline, plan: plan, analyses: analyses, renderedFrames: frames, requireRenderedEvidence: true, requireCompleteEvidence: false)
    #expect(preliminary.rankingEligible)
    #expect(preliminary.findings.allSatisfy { $0.kind != .blockingEvidenceUnknown })
    #expect(!preliminary.candidateEligible)
    #expect(!preliminary.productionEligible)
    let final = EditorialQualityGate().review(timeline: timeline, plan: plan, analyses: analyses, renderedFrames: frames, requireRenderedEvidence: true)
    #expect(final.findings.contains { $0.kind == .blockingEvidenceUnknown })
    #expect(!final.candidateEligible)
    frames[1].decodeFailed = true
    let broken = EditorialQualityGate().review(timeline: timeline, plan: plan, analyses: analyses, renderedFrames: frames, requireRenderedEvidence: true, requireCompleteEvidence: false)
    #expect(!broken.rankingEligible)
    #expect(broken.findings.contains { $0.kind == .blankRenderedFrame })
}

@Test(arguments: ["Съёмка на озере", "Фильм о рыбалке", "Съёмка · 11 июля 2026", "Часть 1", "Chapter by the lake"])
func verificationDescriptiveTitlesAreNotPlaceholders(text: String) async throws {
    var (timeline, plan, analyses) = verificationFixture()
    timeline.titleItems = [TitleTimelineItem(kind: .chapter, text: text, startTime: 0, duration: 3)]
    let frames = try await FixtureEditorialProber().frames(timeline: timeline, assets: [], tracks: [], telemetry: [:], cacheURL: FileManager.default.temporaryDirectory)
    let claims = EditorialLocalSemanticVerifier.claims(timeline: timeline, plan: plan, analyses: analyses, frames: frames, tracks: [])
    #expect(claims.first { $0.domain == .titleGrounding }?.status == .passed)
}

@Test(arguments: ["Съёмка", "Глава 1", "Фильм", "Untitled", "123", "Кульминация"])
func verificationGeneratedPlaceholderTitlesAreRepairedBeforeRendering(text: String) {
    var (timeline, plan, _) = verificationFixture()
    #expect(SmartTitleEngine.isPlaceholderTitle(text))
    let generated = TitleTimelineItem(kind: .chapter, text: text, startTime: 0, duration: 3, explanation: ["Автоматический титр"])
    let manual = TitleTimelineItem(kind: .title, text: "Фильм", startTime: 4, duration: 3)
    timeline.titleItems = [generated, manual]
    let repaired = EditorialPresentationPolicy.stylingGeneratedTitles(in: timeline, plan: plan)
    #expect(!SmartTitleEngine.isPlaceholderTitle(repaired.effectiveTitleItems[0].text))
    #expect(repaired.effectiveTitleItems[0].id == generated.id)
    #expect(repaired.effectiveTitleItems[1] == manual)
}

@Test func verificationFailureMessageSummarizesDistinctProblemsWithoutDumpingEvidence() {
    let findings = (0..<10).flatMap { _ in [
        EditorialFinding(kind: .blockingEvidenceUnknown, severity: 2, itemIDs: [], repair: .none, reason: "renderDecode: coverage=0.3333333, confidence=1, status=passed"),
        EditorialFinding(kind: .unreadableTitle, severity: 2, itemIDs: [], repair: .decoration, reason: "OCR финального кадра распознал менее половины слов титра"),
        EditorialFinding(kind: .hardDuplicate, severity: 2, itemIDs: [], repair: .removeDuplicate, reason: "Найдены соседние визуально взаимозаменяемые планы без нового состояния")
    ] }
    let message = EditorialGenerationError.noPassingVariant(findings).localizedDescription
    #expect(message.count < 400)
    #expect(!message.contains("coverage="))
    #expect(!message.contains("status=passed"))
    #expect(message.components(separatedBy: "титры читаемыми").count == 2)
    #expect(message.contains("Данные проекта сохранены"))
    #expect(!message.contains("Последняя рабочая версия"))
}

/// Opt-in recovery acceptance on an explicitly prepared disposable copy. The
/// saved visual brief and analyses are real; an existing track keeps this
/// regression focused on editing/render verification rather than music search.
@Test(.enabled(if: ProcessInfo.processInfo.environment["VELOEDIT_RECOVERY_QA_COPY"] != nil))
func verificationRealProjectRecoveryCommitsFullyVerifiedFilm() async throws {
    let package = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["VELOEDIT_RECOVERY_QA_COPY"]))
    let store = try ProjectStore(open: package)
    let initial = await store.manifest
    let pipeline = VeloEditPipeline(store: store,
        musicLibrary: LocalMusicLibrary(rootURL: package.appendingPathComponent("MusicLibrary")),
        musicSelectionHistory: LocalMusicSelectionHistoryStore(url: package.appendingPathComponent("qa-music-history.json")),
        personalTasteStore: LocalPersonalTasteStore(url: package.appendingPathComponent("qa-taste.json")))
    let timeline = try await pipeline.createFilm(
        prompt: initial.workspaceState?.prompt ?? initial.storyPlans.last?.prompt ?? "Создай фильм",
        preset: initial.workspaceState?.preset ?? .story,
        targetDuration: initial.workspaceState?.directorBrief?.requestedDuration,
        preferredMusicTrackID: initial.timelines.last?.music?.trackID,
        directorBrief: initial.workspaceState?.directorBrief)
    #expect(timeline.editorialReview?.productionEligible == true)
    #expect(timeline.editorialReview?.blockingUnknowns.isEmpty == true)
    #expect(await store.manifest.timelines.last?.id == timeline.id)
    #expect(await store.manifest.timelines.count == initial.timelines.count + 1)
    let playback = try await pipeline.makePlayback(interactiveQuality: .preview720p)
    #expect(playback.warnings.isEmpty)
    #expect(playback.skippedItemIDs.isEmpty)
}

@Test func verificationScopedClaimsNeedDecodedFramesAndMatchingSignature() async throws {
    let (timeline, plan, analyses) = verificationFixture()
    var frames = try await FixtureEditorialProber().frames(timeline: timeline, assets: [], tracks: [], telemetry: [:], cacheURL: FileManager.default.temporaryDirectory)
    let good = EditorialQualityGate().review(timeline: timeline, plan: plan, analyses: analyses, renderedFrames: frames, requireRenderedEvidence: true)
    #expect(good.candidateEligible)
    #expect(!good.productionEligible) // Pending intent awaits CAS commit.
    frames[0].editorialClaims = frames[0].editorialClaims?.map { claim in var c = claim; c.renderSignature = "stale"; return c }
    let stale = EditorialQualityGate().review(timeline: timeline, plan: plan, analyses: analyses, renderedFrames: frames, requireRenderedEvidence: true)
    #expect(!stale.candidateEligible)
    #expect(stale.blockingUnknowns.contains { $0.domain == .hookFulfillment })
}

@Test(arguments: [-28.0, -9.0]) func verificationEncodedLoudnessFailsBothBounds(_ lufs: Double) async throws {
    var (timeline, plan, analyses) = verificationFixture()
    timeline.originalAudioVolume = 0.5
    plan.directorBrief?.sourceAudioPolicy = .preserve
    plan.prompt = "С исходным звуком"
    timeline.items[0].audioAdjustments?.muted = false
    var frames = try await FixtureEditorialProber().frames(timeline: timeline, assets: [], tracks: [], telemetry: [:], cacheURL: FileManager.default.temporaryDirectory)
    frames[0].exportVerification?.encodedAudio?.outputLUFS = lufs
    let review = EditorialQualityGate().review(timeline: timeline, plan: plan, analyses: analyses, renderedFrames: frames, requireRenderedEvidence: true)
    #expect(review.evidenceDomains?.first { $0.domain == .integratedLoudness }?.status == .failed)
    #expect(!review.candidateEligible)
}

@Test func verificationAcceptsOnlyMeasuredPeakLimitedDynamicLoudnessException() {
    #expect(EditorialLoudnessPolicy.accepts(lufs: -20.6, truePeak: -1.2))
    #expect(!EditorialLoudnessPolicy.accepts(lufs: -20.6, truePeak: -4.5))
    #expect(!EditorialLoudnessPolicy.accepts(lufs: -28, truePeak: -1.2))
    #expect(!EditorialLoudnessPolicy.accepts(lufs: -9, truePeak: -1.2))
}

@Test(arguments: [-32.0, -9.0]) func verificationRespectsRequestedAttenuationWithoutAllowingLoudMixes(_ lufs: Double) async throws {
    var (timeline, plan, analyses) = verificationFixture()
    plan.prompt = "Приглушить звук исходников"
    plan.directorBrief?.sourceAudioPolicy = .duck
    timeline.originalAudioVolume = 0.2
    timeline.items[0].audioAdjustments = .init()
    var frames = try await FixtureEditorialProber().frames(timeline: timeline, assets: [], tracks: [], telemetry: [:], cacheURL: FileManager.default.temporaryDirectory)
    frames[0].exportVerification?.encodedAudio?.outputLUFS = lufs
    frames[0].audioMasteringReport = frames[0].exportVerification?.encodedAudio
    let review = EditorialQualityGate().review(timeline: timeline, plan: plan, analyses: analyses, renderedFrames: frames, requireRenderedEvidence: true)
    #expect(review.evidenceDomains?.first { $0.domain == .integratedLoudness }?.status == (lufs < -20 ? .passed : .failed))
    #expect(review.findings.contains { $0.kind == .audioLoudnessViolation } == (lufs > -12))
    #expect(!EditorialLoudnessPolicy.accepts(lufs: .nan, truePeak: -2, allowsQuietMix: true))
    #expect(!EditorialLoudnessPolicy.accepts(lufs: -.infinity, truePeak: -2, allowsQuietMix: true))
}

@Test func verificationEveryRequiredUnknownAndEvidenceRemovalBlocksProduction() async throws {
    let (timeline, plan, analyses) = verificationFixture()
    let frames = try await FixtureEditorialProber().frames(timeline: timeline, assets: [], tracks: [], telemetry: [:], cacheURL: FileManager.default.temporaryDirectory)
    var review = EditorialQualityGate().review(timeline: timeline, plan: plan, analyses: analyses, renderedFrames: frames, requireRenderedEvidence: true)
    let pending = try #require(review.evidenceDomains?.firstIndex { $0.domain == .pendingIntentSatisfaction })
    review.evidenceDomains?[pending].status = .passed
    review.evidenceDomains?[pending].confidence = 1
    review.evidenceDomains?[pending].coverage = 1
    review.evidenceDomains?[pending].provenance = ["explicit transaction fixture"]
    #expect(review.productionEligible)
    for i in review.evidenceDomains!.indices where review.evidenceDomains![i].required {
        var missing = review
        missing.evidenceDomains?[i].status = .unknown
        missing.editorialScore = 1
        #expect(!missing.productionEligible)
        missing = review
        missing.evidenceDomains?.remove(at: i)
        #expect(!missing.productionEligible)
    }
    review.findings.append(.init(kind: .foregroundOcclusion, severity: 3, itemIDs: [], repair: .framing, reason: "Independent hard defect"))
    #expect(!review.productionEligible)
}

@Test func verificationParityUsesNormalizedPixelsAndRejectsMissingComparison() {
    // Observed sub-byte compression difference from the real control exports.
    let match = EditorialExportProbeComparison(time: 1, decoded: true, hashDistance: 11, meanLumaDifference: 0.532 / 255, meanAbsolutePixelDifference: 0.01)
    #expect(match.passed)
    let codecNormalized = EditorialExportProbeComparison(time: 1, decoded: true, hashDistance: 17, meanLumaDifference: 0.01, meanAbsolutePixelDifference: 0.063)
    #expect(codecNormalized.passed)
    let mismatch = EditorialExportProbeComparison(time: 1, decoded: true, hashDistance: 0, meanLumaDifference: 0.01, meanAbsolutePixelDifference: 0.3)
    #expect(!mismatch.passed)
    let legacy = EditorialExportProbeComparison(time: 1, decoded: true, hashDistance: 0, meanLumaDifference: 0)
    #expect(!legacy.passed)
}

@Test func verificationLowerBoundRepairUsesOnlyMeasuredSelectedHandles() {
    let candidates = (0..<3).map { index -> Candidate in
        let evidence = EditorialEvidence(usableRange: .init(start: 2, end: 8), entryQuality: 0.9, exitQuality: 0.9, confidence: 0.9, provenance: ["measured fixture"])
        var insights = CandidateInsights()
        insights.editorialEvidence = evidence
        return Candidate(assetID: UUID(), sourceStart: 0, sourceDuration: 10, scores: .init(quality: 0.9, interest: 0.9, action: 0.1, stability: 0.9), tags: ["scene-\(index)"], insights: insights)
    }
    let analyses = candidates.map { AnalysisResult(assetID: $0.assetID, analyzedContentHash: "fixture", sceneTags: $0.tags, candidates: [$0]) }
    let assets = candidates.map { MediaAsset(id: $0.assetID, originalURL: URL(fileURLWithPath: "/tmp/synthetic.mov"), kind: .video, byteSize: 0, contentHash: "fixture", metadata: MediaMetadata(duration: 10)) }
    let (_, seed, _) = verificationFixture(duration: 300, lower: 12, upper: 18)
    var plan = seed
    plan.chapters = candidates.map { StoryChapter(title: "", candidateIDs: [$0.id]) }
    plan.narrativeBeatPlan = .init(pattern: .minimalMontage, beats: [], reasons: [])
    let timeline = TimelineComposer().compose(plan: plan, assets: assets, analyses: analyses)
    #expect(timeline.duration >= 12 - 0.05)
    #expect(timeline.items.filter { $0.kind == .video }.allSatisfy { $0.sourceStart >= 2 && $0.sourceStart + $0.sourceDuration <= 8.001 })
    #expect(timeline.items.filter { $0.kind == .video }.count == 3)
}

@Test func verificationDetectsNarrowHighContrastVerticalOccluder() {
    let flat = Array(repeating: Float(0.5), count: 32 * 32)
    var obstructed = Array(repeating: Float(0.82), count: 32 * 32)
    for y in 0..<32 {
        for x in 14...18 { obstructed[y * 32 + x] = 0.04 }
    }
    let person = FrameSubjectObservation(kind: .person, label: "person", region: .init(x: 0.32, y: 0.12, width: 0.38, height: 0.82), confidence: 0.9)
    #expect(PerceptualRenderInspector.verticalOccluderScore(flat, subjects: [person]) < 0.2)
    #expect(PerceptualRenderInspector.verticalOccluderScore(obstructed, subjects: [person]) >= 0.58)
}

@Test func verificationDoesNotTreatBackgroundOrClothingBoundaryAsOcclusion() {
    let person = FrameSubjectObservation(kind: .person, label: "person", region: .init(x: 0.55, y: 0.12, width: 0.38, height: 0.82), confidence: 0.9)
    var backgroundPole = Array(repeating: Float(0.82), count: 32 * 32)
    for y in 0..<32 { for x in 6...10 { backgroundPole[y * 32 + x] = 0.04 } }
    #expect(PerceptualRenderInspector.verticalOccluderScore(backgroundPole, subjects: [person]) < 0.2)
    var boundary = Array(repeating: Float(0.82), count: 32 * 32)
    for y in 0..<32 { for x in 16..<32 { boundary[y * 32 + x] = 0.04 } }
    let centered = FrameSubjectObservation(kind: .person, label: "person", region: .init(x: 0.25, y: 0.1, width: 0.5, height: 0.8), confidence: 0.9)
    #expect(PerceptualRenderInspector.verticalOccluderScore(boundary, subjects: [centered]) < 0.2)
    let fullFrameNoise = FrameSubjectObservation(kind: .person, label: "person", region: .init(x: 0, y: 0, width: 1, height: 1), confidence: 0.9)
    #expect(PerceptualRenderInspector.verticalOccluderScore(backgroundPole, subjects: [fullFrameNoise]) == 0)
}

@Test func verificationLocalSemanticClaimsAreBoundToExactRenderAndRequiredScopes() async throws {
    let (timeline, plan, analyses) = verificationFixture()
    let schedule = EditorialProbeSchedule.times(timeline: timeline)
    let itemID = try #require(timeline.items.first?.id)
    var frames = schedule.map { time -> PerceptualRenderedFrameEvidence in
        var frame = PerceptualRenderedFrameEvidence(timelineTime: time, meanLuma: 0.55, lumaDeviation: 0.2, perceptualHash: UInt64((time * 100).rounded()), isBlack: false)
        frame.lumaFingerprint = (0..<(32 * 32)).map { Float(($0 + Int(time * 10)) % 31) / 31 }
        frame.renderedSubjects = [.init(kind: .person, label: "person", region: .init(x: 0.25, y: 0.1, width: 0.5, height: 0.82), confidence: 0.91)]
        frame.renderedSalientRegions = []
        frame.verticalOccluderScore = 0
        frame.decodeFailed = false
        return frame
    }
    // Prevent the test fixture's single clip from being interpreted as frozen.
    for index in frames.indices { frames[index].perceptualHash = UInt64(index * 97 + 1) }
    let claims = EditorialLocalSemanticVerifier.claims(timeline: timeline, plan: plan, analyses: analyses, frames: frames, tracks: [])
    let expected: Set<EditorialEvidenceDomain> = [.subjectCoverage, .faceSafety, .bodySafety, .foregroundOcclusion, .dominantForegroundObject, .shotFamilyIdentity, .visualNovelty, .actionProgression, .momentCompletion, .hookFulfillment, .closureFulfillment, .eventBridge]
    #expect(expected.isSubset(of: Set(claims.map { $0.domain })))
    #expect(claims.allSatisfy { $0.renderSignature == EditorialRenderSignature.signature(timeline) })
    #expect(claims.allSatisfy { !$0.itemIDs.isEmpty && $0.itemIDs.allSatisfy { $0 == itemID } })
    #expect(claims.allSatisfy { !$0.probeTimes.isEmpty && $0.method == "LocalRenderedSemanticVerifier-v3" })
}

@Test func verificationIgnoresOneFrameVisionNoiseButRejectsPersistentOcclusion() {
    let (timeline, plan, analyses) = verificationFixture()
    let schedule = EditorialProbeSchedule.times(timeline: timeline)
    func baseFrames() -> [PerceptualRenderedFrameEvidence] {
        schedule.enumerated().map { index, time in
            var frame = PerceptualRenderedFrameEvidence(timelineTime: time, meanLuma: 0.55, lumaDeviation: 0.2, perceptualHash: UInt64(index + 1), isBlack: false)
            frame.lumaFingerprint = Array(repeating: 0.5, count: 32 * 32)
            frame.renderedSubjects = [.init(kind: .person, label: "person", region: .init(x: 0.25, y: 0.1, width: 0.5, height: 0.82), confidence: 0.91)]
            frame.renderedSalientRegions = []
            frame.renderedLabels = []
            frame.verticalOccluderScore = 0
            frame.decodeFailed = false
            return frame
        }
    }

    var noisy = baseFrames()
    noisy[0].renderedSubjects = [.init(kind: .person, label: "person", region: .init(x: 0, y: 0.1, width: 0.45, height: 0.82), confidence: 0.91)]
    noisy[0].renderedLabels = ["vehicle"]
    noisy[0].renderedSalientRegions = [.init(kind: .vehicle, label: "vehicle", region: .init(x: 0, y: 0, width: 0.8, height: 1), confidence: 0.9)]
    noisy[0].verticalOccluderScore = 0.9
    let noiseClaims = EditorialLocalSemanticVerifier.claims(timeline: timeline, plan: plan, analyses: analyses, frames: noisy, tracks: [])
    #expect(noiseClaims.filter { [.bodySafety, .foregroundOcclusion, .dominantForegroundObject].contains($0.domain) }.allSatisfy { $0.status == .passed })

    var persistent = baseFrames()
    for index in persistent.indices {
        persistent[index].renderedSubjects = [.init(kind: .person, label: "person", region: .init(x: 0, y: 0.1, width: 0.45, height: 0.82), confidence: 0.91)]
        persistent[index].renderedLabels = ["vehicle"]
        persistent[index].renderedSalientRegions = [.init(kind: .vehicle, label: "vehicle", region: .init(x: 0, y: 0, width: 0.8, height: 1), confidence: 0.9)]
        persistent[index].verticalOccluderScore = 0.9
    }
    let persistentClaims = EditorialLocalSemanticVerifier.claims(timeline: timeline, plan: plan, analyses: analyses, frames: persistent, tracks: [])
    #expect(persistentClaims.filter { [.bodySafety, .foregroundOcclusion, .dominantForegroundObject].contains($0.domain) }.allSatisfy { $0.status == .failed })
}
