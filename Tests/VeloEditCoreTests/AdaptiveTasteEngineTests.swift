import Foundation
import Testing
@testable import VeloEditCore

@Test func unrelatedEditsDoNotTeachAnUnchangedEnding() {
    let (_, _, candidates) = p7Fixture()
    let before = p7Timeline(planID: UUID(), candidates: Array(candidates.values))
    var after = before
    after.music?.volume = 0.15
    let extractor = AdaptivePreferenceSignalExtractor()
    #expect(!extractor.signals(before: before, after: after, context: TasteContext(), candidates: candidates).contains { $0.feature == "endingPreference" })
    after.items.removeLast()
    #expect(extractor.signals(before: before, after: after, context: TasteContext(), candidates: candidates).contains { $0.feature == "endingPreference" })
}

@Test func approvedReferenceIsOneObservationPerFeatureAndPersistsItsReceipt() async throws {
    let (assets, analyses, candidates) = p7Fixture()
    let timeline = p7Timeline(planID: UUID(), candidates: Array(candidates.values))
    let example = try #require(ApprovedReferenceLearning(timeline: timeline, assets: assets, analyses: analyses))
    #expect(example.signals.count == Set(example.signals.map(\.feature)).count)
    #expect(!example.signals.contains { ["duration.film", "musicBPM", "colorPreference"].contains($0.feature) })
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("taste.json")
    let store = LocalPersonalTasteStore(url: url)
    let first = try await store.recordValidated(example.signals, regressionSample: nil, now: Date(timeIntervalSince1970: 1_800_000_000), approvedReferenceFingerprint: example.fingerprint)
    #expect(first.report.committed)
    #expect(first.profile.totalSignalCount == example.signals.count)
    let extractor = TimelineTasteFeatureExtractor()
    let acceptedFeatures = extractor.features(timeline: timeline, candidates: candidates)
    var rushedFeatures = acceptedFeatures
    rushedFeatures.meanShotDuration = 1
    let scorer = PersonalizedMontageScorer()
    #expect(scorer.tasteFit(features: acceptedFeatures, profile: first.profile, contextKey: nil)
        > scorer.tasteFit(features: rushedFeatures, profile: first.profile, contextKey: nil))
    let bytes = try Data(contentsOf: url)
    let second = try await LocalPersonalTasteStore(url: url).recordValidated(example.signals, regressionSample: nil, approvedReferenceFingerprint: example.fingerprint)
    #expect(!second.report.committed)
    #expect(second.profile == first.profile)
    #expect(try Data(contentsOf: url) == bytes)
    // Recreating timeline/item IDs must not turn the same film into new evidence.
    var copy = timeline
    copy.id = UUID()
    for index in copy.items.indices { copy.items[index].id = UUID() }
    #expect(ApprovedReferenceLearning(timeline: copy, assets: assets, analyses: analyses)?.fingerprint == example.fingerprint)
}

@Test func emptyAutomaticOutputCannotBeAnApprovedExample() {
    #expect(ApprovedReferenceLearning(timeline: Timeline(storyPlanID: UUID(), items: []), assets: [], analyses: []) == nil)
}

@Test func separateProjectsCannotLoseOrDoubleAnApprovedReference() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("taste.json")
    let first = LocalPersonalTasteStore(url: url), second = LocalPersonalTasteStore(url: url)
    _ = await first.profile()
    _ = await second.profile()
    let signal = PreferenceSignal(feature: "titleDuration", value: -0.4, confidence: 0.75, source: .acceptedEdit)
    async let a = first.recordValidated([signal], regressionSample: nil, approvedReferenceFingerprint: "approved-example")
    async let b = second.recordValidated([signal], regressionSample: nil, approvedReferenceFingerprint: "approved-example")
    let results = try await [a, b]
    #expect(results.filter { $0.report.committed }.count == 1)
    let updated = try await first.record([PreferenceSignal(feature: "pacing", value: 0.2, confidence: 0.75, source: .manualEdit)])
    #expect(updated.totalSignalCount == 2)
    #expect(updated.approvedReferenceFingerprints == ["approved-example"])
    // The persisted ISO date format has second precision.
    let persisted = try JSONDecoder.veloEdit.decode(PersonalTasteProfile.self, from: JSONEncoder.veloEdit.encode(updated))
    #expect(await second.profile() == persisted)
}

private func p7Fixture(count: Int = 12) -> ([MediaAsset], [AnalysisResult], [UUID: Candidate]) {
    let assets = (0..<3).map { index in
        MediaAsset(
            originalURL: URL(fileURLWithPath: "/tmp/p7-\(index).mov"),
            kind: .video,
            byteSize: 100,
            contentHash: "p7-\(index)",
            metadata: MediaMetadata(duration: 160, frameRate: index == 0 ? 60 : 30, hasAudio: true)
        )
    }
    var grouped: [UUID: [Candidate]] = [:]
    for index in 0..<count {
        let asset = assets[index % assets.count]
        let start = Double(index * 9)
        let action = index.isMultiple(of: 2) ? 0.86 : 0.24
        let tokens: Set<String> = index.isMultiple(of: 2) ? ["cycling", "pov", "action"] : ["water", "sunset", "scenic"]
        let candidate = Candidate(
            assetID: asset.id,
            sourceStart: start,
            sourceDuration: 7,
            scores: ClipScores(quality: 0.82, interest: 0.78, action: action, stability: 0.84, uniqueness: 0.80),
            tags: tokens,
            insights: CandidateInsights(
                sceneSummary: tokens.sorted().joined(separator: " "),
                dynamics: action,
                visualAppeal: 0.84,
                composition: 0.82,
                sharpness: 0.86,
                exposureQuality: 0.84,
                slowMotionSuitability: action,
                storyValue: 0.80,
                roleScores: [.action: action, .climax: index == count - 2 ? 0.98 : action, .intro: index < 2 ? 0.88 : 0.35, .outro: index == count - 1 ? 0.94 : 0.35],
                visualEmbedding: VisualEmbedding(modelIdentifier: "p7", values: index.isMultiple(of: 2) ? [1, 0, 0] : [0, 1, 0], confidence: 0.9),
                semanticEventID: "p7-event-\(index)",
                audioQuality: 0.82
            ),
            momentBoundary: MomentBoundary(anticipationStart: start, peakTime: start + 2.8, completionEnd: start + 6.6, confidence: 0.88)
        )
        grouped[asset.id, default: []].append(candidate)
    }
    let analyses = assets.map { asset in
        AnalysisResult(assetID: asset.id, schemaVersion: 4, analyzedContentHash: asset.contentHash, sceneTags: Set(grouped[asset.id, default: []].flatMap(\.tags)), candidates: grouped[asset.id, default: []], completedDepth: .deep, deepMediaVersion: 2)
    }
    return (assets, analyses, Dictionary(uniqueKeysWithValues: grouped.values.flatMap { $0 }.map { ($0.id, $0) }))
}

private func p7Timeline(planID: UUID, candidates: [Candidate], actionFirst: Bool = true, duration: Double = 4) -> Timeline {
    let action = candidates.filter { ($0.insights?.dynamics ?? $0.scores.action) > 0.62 }.sorted { $0.sourceStart < $1.sourceStart }
    let calm = candidates.filter { ($0.insights?.dynamics ?? $0.scores.action) <= 0.62 }.sorted { $0.sourceStart < $1.sourceStart }
    let ordered = actionFirst
        ? Array(action.prefix(4)) + Array(calm.prefix(2))
        : Array(calm.prefix(4)) + Array(action.prefix(2))
    let items = ordered.prefix(6).enumerated().map { index, candidate in
        TimelineItem(
            candidateID: candidate.id,
            assetID: candidate.assetID,
            kind: .video,
            sourceStart: candidate.sourceStart,
            sourceDuration: duration,
            timelineStart: Double(index) * duration,
            timelineDuration: duration,
            storyRole: index == 0 ? .intro : index == 4 ? .climax : index == 5 ? .outro : ((candidate.insights?.dynamics ?? 0) > 0.6 ? .action : .bRoll)
        )
    }
    return Timeline(storyPlanID: planID, items: items, music: MusicDirective(style: .cinematic, bpm: 112))
}

@Test func adaptiveConfidencePolarityAndDecayAreCalibrated() {
    let engine = PreferenceLearningEngine()
    let start = Date(timeIntervalSince1970: 10_000)
    let positive = PreferenceSignal(feature: "pacingPreference", value: 0.8, confidence: 1, source: .trim)
    var profile = engine.updating(PersonalTasteProfile(), with: [positive], now: start)
    let first = profile.pacingPreference
    #expect(first?.sampleCount == 1)
    #expect(first?.positiveCount == 1)
    #expect((first?.confidence ?? 0) > 0.14)
    #expect((first?.confidence ?? 1) < 0.19)

    profile = engine.updating(profile, with: Array(repeating: positive, count: 19), now: start.addingTimeInterval(100))
    #expect(profile.pacingPreference?.sampleCount == 20)
    #expect((profile.pacingPreference?.confidence ?? 0) > 0.75)
    let decayed = profile.pacingPreference?.decayed(at: start.addingTimeInterval(360 * 86_400))
    #expect((decayed?.confidence ?? 1) < (profile.pacingPreference?.confidence ?? 0))
    #expect((decayed?.value ?? 1) < (profile.pacingPreference?.value ?? 0))
}

@Test func adaptiveSignalsCaptureSemanticDeleteTrimEffectsMusicAndStructure() {
    let (_, analyses, candidates) = p7Fixture()
    let all = Array(candidates.values)
    let planID = UUID()
    let before = p7Timeline(planID: planID, candidates: all, actionFirst: true, duration: 5)
    var after = before
    let removed = after.items.removeFirst()
    after.items[0].sourceDuration = 7
    after.items[0].timelineDuration = 7
    after.items[1].speedRamp = .action
    after.items[1].effect = ClipEffect.zoomIn.rawValue
    after.items[2].videoAdjustments = VideoAdjustments(filter: .warm)
    after.items.swapAt(2, 3)
    after.items = TimelineTiming.retimed(after.items)
    after.music?.bpm = 128
    let project = AutonomousProjectStyleEngine().infer(assets: [], analyses: analyses, fallbackPreset: .story)
    let context = TasteContextResolver().resolve(projectStyle: project, timeline: after, analyses: analyses)
    let signals = AdaptivePreferenceSignalExtractor().signals(before: before, after: after, context: context, candidates: candidates)

    #expect(signals.contains { $0.feature == "actionPreference" && $0.value < 0 && $0.semanticTokens?.isEmpty == false })
    #expect(signals.contains { $0.feature == "duration.action" || $0.feature == "duration.calm" })
    #expect(signals.contains { $0.feature == "speedRamp" && $0.value > 0 })
    #expect(signals.contains { $0.feature == "zoom" && $0.value > 0 })
    #expect(signals.contains { $0.feature == "colorPreference" && $0.value > 0 })
    #expect(signals.contains { $0.feature == "musicBPM" })
    #expect(signals.contains { $0.feature.hasPrefix("structure:") })
    #expect(removed.candidateID != nil)
}

@Test func contextualTasteDoesNotLeakStronglyAcrossDifferentActivities() {
    let updater = PreferenceLearningEngine()
    let cycling = Array(repeating: PreferenceSignal(feature: "pacingPreference", value: 1, confidence: 0.9, source: .trim, contextKey: "cycling"), count: 18)
    let family = Array(repeating: PreferenceSignal(feature: "pacingPreference", value: -1, confidence: 0.9, source: .trim, contextKey: "family"), count: 18)
    let profile = updater.updating(updater.updating(PersonalTasteProfile(), with: cycling), with: family)
    let cyclingValue = profile.adaptiveEstimate(for: "pacingPreference", contextKey: "cycling")?.value ?? 0
    let familyValue = profile.adaptiveEstimate(for: "pacingPreference", contextKey: "family")?.value ?? 0
    #expect(cyclingValue > familyValue + 0.55)
    #expect(profile.adaptiveContexts?.count == 2)
}

@Test func learnedDurationAndMusicInfluenceRealAutonomousDecisionGradually() {
    let (assets, analyses, _) = p7Fixture()
    let signals = Array(repeating: [
        PreferenceSignal(feature: "duration.film", value: -0.45, confidence: 0.9, source: .trim),
        PreferenceSignal(feature: "clipDurationPreference", value: 0.75, confidence: 0.9, source: .trim),
        PreferenceSignal(feature: "musicBPM", value: 0.6, confidence: 0.9, source: .music)
    ], count: 24).flatMap { $0 }
    let profile = PreferenceLearningEngine().updating(PersonalTasteProfile(), with: signals)
    let base = AutonomousDirectorEngine().decide(prompt: "Сделай лучший фильм", fallbackPreset: .story, requestedDuration: nil, assets: assets, analyses: analyses, personalProfile: PersonalTasteProfile())
    let learned = AutonomousDirectorEngine().decide(prompt: "Сделай лучший фильм", fallbackPreset: .story, requestedDuration: nil, assets: assets, analyses: analyses, personalProfile: profile)
    #expect(learned.duration.seconds <= learned.duration.safeRange.upperBound)
    #expect(learned.duration.seconds != base.duration.seconds)
    #expect(learned.grammar.meanShotDuration > base.grammar.meanShotDuration)
    #expect(learned.music.desiredBPM > base.music.desiredBPM)
}

@Test func personalizedScorerRewardsTasteButCannotHideTechnicalFailure() {
    let (_, _, candidates) = p7Fixture()
    let planID = UUID()
    let calm = p7Timeline(planID: planID, candidates: Array(candidates.values), actionFirst: false, duration: 6)
    let action = p7Timeline(planID: planID, candidates: Array(candidates.values), actionFirst: true, duration: 2.5)
    let signals = Array(repeating: [
        PreferenceSignal(feature: "actionPreference", value: -1, confidence: 0.95, source: .deletion),
        PreferenceSignal(feature: "calmMomentPreference", value: 1, confidence: 0.95, source: .restoration),
        PreferenceSignal(feature: "clipDurationPreference", value: 1, confidence: 0.95, source: .trim)
    ], count: 30).flatMap { $0 }
    let profile = PreferenceLearningEngine().updating(PersonalTasteProfile(), with: signals)
    let base = MontageGlobalScore(total: 0.76, highlightQuality: 0.8, storyArc: 0.8, diversity: 0.8, durationFit: 0.8, musicalAlignment: 0.8, reviewQuality: 0.8, technicalQuality: 0.82, projectStyleFit: 0.75)
    let scorer = PersonalizedMontageScorer()
    let calmScore = scorer.personalize(base: base, timeline: calm, candidates: candidates, profile: profile, context: TasteContext()).1
    let actionScore = scorer.personalize(base: base, timeline: action, candidates: candidates, profile: profile, context: TasteContext()).1
    #expect(calmScore.personalTaste > actionScore.personalTaste + 0.12)
    #expect(calmScore.combined > actionScore.combined)

    var unsafe = base
    unsafe.technicalQuality = 0.05
    unsafe.total = 0.30
    let unsafeScore = scorer.personalize(base: unsafe, timeline: calm, candidates: candidates, profile: profile, context: TasteContext()).1
    #expect(unsafeScore.combined < actionScore.combined)
}

@Test func explorationPolicyIsDeterministicAndNearTheExploitationStyle() {
    let profile = PersonalTasteProfile(totalSignalCount: 20, pacingPreference: AdaptiveTasteEstimate(value: 0.5, confidence: 0.7, sampleCount: 20, evidenceWeight: 20))
    let policy = TasteExplorationPolicy()
    let values = (0..<400).map { policy.shouldExplore(profile: profile, projectFingerprint: "project-\($0)") }
    let count = values.filter { $0 }.count
    #expect(count >= 25)
    #expect(count <= 55)
    #expect(policy.shouldExplore(profile: profile, projectFingerprint: "stable") == policy.shouldExplore(profile: profile, projectFingerprint: "stable"))
    let base = DirectorStyleVector.neutral
    #expect(policy.exploratoryStyle(from: base, profile: profile).distance(to: base) < 0.12)
}

@Test func automaticRegressionGateRejectsDegradingModelWithoutHumanRatings() {
    let preferred = TimelineTasteFeatures(duration: 60, meanShotDuration: 6, actionShare: 0.15, calmShare: 0.85, transitionShare: 0.05, effectShare: 0.02, slowMotionShare: 0.05, telemetryShare: 0, titleDensity: 0.05, originalAudioShare: 0.8, chronologicalOrder: 1, endingEnergy: 0.2)
    let proposed = TimelineTasteFeatures(duration: 60, meanShotDuration: 2, actionShare: 0.9, calmShare: 0.1, transitionShare: 0.7, effectShare: 0.6, slowMotionShare: 0.5, telemetryShare: 0.7, titleDensity: 0.5, originalAudioShare: 0.2, chronologicalOrder: 0.3, endingEnergy: 0.9)
    let sample = TasteRegressionSample(contextKey: "travel", proposedFeatures: proposed, acceptedFeatures: preferred, proposedAutomaticQuality: 0.80, acceptedAutomaticQuality: 0.79)
    let calmSignals = Array(repeating: PreferenceSignal(feature: "calmMomentPreference", value: 1, confidence: 1, source: .restoration, contextKey: "travel"), count: 30)
    let actionSignals = Array(repeating: PreferenceSignal(feature: "calmMomentPreference", value: -1, confidence: 1, source: .deletion, contextKey: "travel"), count: 30)
    let previous = PreferenceLearningEngine().updating(PersonalTasteProfile(), with: calmSignals)
    let degrading = PreferenceLearningEngine().updating(previous, with: actionSignals)
    let report = TasteRegressionGuard().evaluate(previous: previous, proposed: degrading, samples: [sample])
    #expect(report.committed == false)
    #expect(report.proposedAgreement < report.previousAgreement)
    #expect(report.qualityFloorPassed)
}

@Test func tasteStorePersistsExportsAndResetsEntirelyOffline() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("p7-store-\(UUID().uuidString)")
    let url = root.appendingPathComponent("taste.json")
    let exported = root.appendingPathComponent("exported.json")
    let importedURL = root.appendingPathComponent("imported.json")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = LocalPersonalTasteStore(url: url)
    _ = try await store.record(Array(repeating: PreferenceSignal(feature: "transitionPreference", value: -1, confidence: 0.9, source: .transition), count: 8))
    try await store.export(to: exported)
    #expect(FileManager.default.fileExists(atPath: exported.path))
    let restored = await LocalPersonalTasteStore(url: exported).profile()
    #expect(restored.transitionPreference?.sampleCount == 8)
    let importedStore = LocalPersonalTasteStore(url: importedURL)
    let imported = try await importedStore.importProfile(from: exported)
    #expect(imported.transitionPreference?.sampleCount == 8)
    #expect((await importedStore.profile()).totalSignalCount == restored.totalSignalCount)
    let empty = try await store.reset()
    #expect(empty.totalSignalCount == 0)
    #expect(!FileManager.default.fileExists(atPath: url.path))
}

@Test func tenIndependentEditContextsInfluenceFullDirectorVariantSelection() throws {
    let (assets, analyses, candidates) = p7Fixture(count: 16)
    let projectStyle = AutonomousProjectStyleEngine().infer(assets: assets, analyses: analyses, fallbackPreset: .story)
    var allSignals: [PreferenceSignal] = []
    for index in 0..<10 {
        let before = p7Timeline(planID: UUID(), candidates: Array(candidates.values), actionFirst: true, duration: 3)
        var after = before
        after.items.removeAll { item in
            item.candidateID.flatMap { candidates[$0] }.map { ($0.insights?.dynamics ?? $0.scores.action) > 0.62 } == true
        }
        for itemIndex in after.items.indices {
            after.items[itemIndex].sourceDuration = min(6.5, after.items[itemIndex].sourceDuration + 1.5)
            after.items[itemIndex].timelineDuration = after.items[itemIndex].sourceDuration
        }
        after.items = TimelineTiming.retimed(after.items)
        let context = TasteContext(activity: index.isMultiple(of: 2) ? "travel" : "cycling", projectType: projectStyle.internalLabel, eventType: "project-\(index)")
        allSignals += AdaptivePreferenceSignalExtractor().signals(before: before, after: after, context: context, candidates: candidates)
    }
    let learnedProfile = PreferenceLearningEngine().updating(PersonalTasteProfile(), with: allSignals)
    #expect(learnedProfile.totalSignalCount >= 20)
    #expect((learnedProfile.actionPreference?.value ?? 0) < 0)
    #expect((learnedProfile.clipDurationPreference?.value ?? 0) > 0)

    // Eleventh project enters the complete production director path: search,
    // composition, P0/P6 directing, global + pairwise personalized selection.
    let autonomous = AutonomousDirectorEngine().decide(prompt: "Сделай лучший фильм сам", fallbackPreset: .story, requestedDuration: nil, assets: assets, analyses: analyses, personalProfile: learnedProfile)
    var constraints = PromptInterpreter().interpret(prompt: "Сделай лучший фильм сам", preset: .story)
    constraints.targetDuration = autonomous.duration.seconds
    constraints.pacing = autonomous.finalStyle.pacing
    constraints.transitionFrequency = autonomous.grammar.transitionDensity
    constraints.allowSlowMotion = autonomous.grammar.slowMotionDensity > 0.025
    let search = StoryEngine().createPlanVariantSearch(prompt: "Сделай лучший фильм сам", preset: .story, constraints: constraints, assets: assets, analyses: analyses, limit: 10, autonomousDecision: autonomous)
    let directed = search.variants.map { variant in
        AIDirectorEngine().direct(plan: variant.plan, initialTimeline: TimelineComposer().compose(plan: variant.plan, assets: assets, analyses: analyses), assets: assets, analyses: analyses)
    }
    let context = TasteContextResolver().resolve(projectStyle: autonomous.projectStyle, assets: assets, analyses: analyses)
    let result = try #require(MontageVariantSelector().select(stories: search.variants, timelines: directed, assets: assets, analyses: analyses, searchDiagnostics: search.diagnostics, personalTasteProfile: learnedProfile, tasteContext: context))
    let diagnostics = try #require(result.timeline.directorRun?.personalTasteDiagnostics)
    #expect(diagnostics.profileConfidence > 0.25)
    #expect(search.diagnostics.attemptedStrategyCount > 1)
    #expect(diagnostics.variantScores.count == search.variants.count)
    #expect(result.timeline.directorRun?.decisionReasons.contains { $0.contains("Personal Taste") } == true)
    #expect(result.timeline.directorRun?.autonomousDecision?.personalConfidence ?? 0 > 0.25)
}
